-- NPC headers, decoded scripts and the script interpreter.
--   TCG_CACHE=<dir> lua tests/tcg_script_test.lua

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/npcs.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local npcData = dofile(cacheDir .. "/data/generated/npcs.lua")
local maps = dofile(cacheDir .. "/data/generated/maps.lua")
local ScriptRunner = require("src.tcg.ScriptRunner")
local Overworld = require("src.tcg.Overworld")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. msg) end
end

-- 1. extraction
check(npcData.decoded >= 100, npcData.decoded .. " NPC scripts decoded")
check(npcData.clean >= 70, npcData.clean .. " decode to a clean end")
local named, withText, duels = 0, 0, 0
for id, npc in pairs(npcData.npcs) do
  if npc.name and #npc.name > 0 then named = named + 1 end
  for _, step in ipairs(npc.script or {}) do
    if step.text then withText = withText + 1 end
    if step.name == "StartDuel" then
      duels = duels + 1
      check(step.prizes and step.prizes >= 1 and step.prizes <= 6,
        ("%s duel prize count %s is 1-6"):format(npc.constant or id, tostring(step.prizes)))
    end
  end
end
check(named >= 90, named .. " NPCs have names")
check(withText >= 200, withText .. " script steps carry dialogue")
check(duels >= 20, duels .. " scripts start duels")

-- Dr Mason's script, checked against src/scripts/mason_laboratory.asm
do
  local mason = npcData.npcs[1]
  check(mason.constant == "NPC_DRMASON", "NPC 1 is Dr Mason")
  check(mason.scriptBank == 3, "his script is in bank 3")
  local first = mason.script[1]
  check(first.name == "JumpIfEventTrue", "starts with a conditional jump")
  check(mason.script[2].name == "PrintTextQuitFully", "then prints and quits")
  check(mason.script[3].name == "TryGiveMedalPCPacks", "the branch target gives medal packs")
end

-- 2. interpreter: branching on events
do
  local mason = npcData.npcs[1]
  local runner = ScriptRunner.new({ script = mason.script, npc = mason, events = {} })
  local pending = runner:run()
  check(pending and pending.kind == "text" and pending.text, "an unflagged player gets the first line")
  local firstLine = pending.text
  local id = mason.script[1].args[1]
  local runner2 = ScriptRunner.new({ script = mason.script, npc = mason, events = { [id] = 1 } })
  local pending2 = runner2:run()
  check(pending2 and pending2.text and pending2.text ~= firstLine,
    "setting the event takes the other branch")
  -- advancing a quit-fully text ends the script
  runner:advance()
  check(runner.finished, "print-and-quit ends the script")
end

-- 3. interpreter: questions and duels somewhere in the data
do
  local questioned, duelled = false, false
  for _, npc in pairs(npcData.npcs) do
    if npc.script then
      for seed = 0, 3 do
        local events = {}
        for _, step in ipairs(npc.script) do
          if step.name:find("^JumpIfEvent") and seed % 2 == 1 then
            events[step.args[1] or 0] = 1
          end
        end
        local runner = ScriptRunner.new({ script = npc.script, npc = npc, events = events })
        local guard = 0
        local pending = runner:run()
        while pending and guard < 40 do
          guard = guard + 1
          if pending.kind == "question" then questioned = true end
          if pending.kind == "duel" then
            duelled = true
            check(pending.duel.prizes and pending.duel.deck, "a duel spec carries prizes and a deck")
          end
          pending = runner:advance(seed >= 2)
        end
        check(guard < 40, (npc.constant or "?") .. " script terminates")
      end
    end
  end
  check(questioned, "some script asks a question")
  check(duelled, "some script starts a duel")
end

-- 4. through the overworld
do
  local talked = 0
  local ow = Overworld.new({ maps = maps, map = 1, npcs = npcData,
    onTalk = function() talked = talked + 1 end })
  local mason
  for _, n in ipairs(maps.maps[1].npcs) do if n.constant == "NPC_DRMASON" then mason = n end end
  ow.x, ow.y = mason.x, mason.y + 2
  ow.facing = Overworld.NORTH
  check(ow:interact(), "talking runs the script")
  check(talked == 1 and ow.message and ow.message.text, "the message carries script dialogue")
  check(ow.runner ~= nil, "a runner is attached while the script is live")
  local guard = 0
  while ow.message and guard < 30 do guard = guard + 1; ow:interact() end
  check(ow.message == nil and ow.runner == nil, "the conversation ends")
  -- B closes an open box
  ow:interact()
  check(ow.message ~= nil, "talked again")
  ow:press("b")
  check(ow.message == nil, "B closes the box")
end

-- 5. a script duel actually runs: the spec names a deck the game has, and a
-- duel built from it plays to a finish, after which the script resumes
do
  local cards = dofile(cacheDir .. "/data/generated/cards.lua")
  local decks = dofile(cacheDir .. "/data/generated/decks.lua")
  local Duel = require("src.tcg.Duel")
  local SimpleAI = require("src.tcg.SimpleAI")
  local Collection = require("src.tcg.Collection")

  local function expand(deck)
    local out = {}
    for _, e in ipairs(deck.cards) do for _ = 1, e.count do out[#out + 1] = e.card end end
    return out
  end
  local mine = expand(decks[3])

  local specs = {}
  for _, npc in pairs(npcData.npcs) do
    for _, step in ipairs(npc.script or {}) do
      if step.name == "StartDuel" then
        specs[#specs + 1] = { npc = npc, step = step }
      end
    end
  end
  check(#specs >= 20, #specs .. " duel specs in the scripts")
  local playable = 0
  for _, entry in ipairs(specs) do
    local theirs = entry.step.deckConstant
      and Collection.builtinDeck(decks, entry.step.deckConstant)
    if theirs then
      playable = playable + 1
      -- three built-in decks are over-size in the data itself (see
      -- docs/tcg-phase1.md); everything else must be exactly 60
      local known = entry.step.deckConstant == "RESHUFFLE_DECK"
        or entry.step.deckConstant == "GRASS_AND_PSYCHIC_DECK"
        or entry.step.deckConstant == "UNNAMED_2_DECK"
      check(#theirs == 60 or known,
        (entry.step.deckConstant or "?") .. " is a 60-card deck (" .. #theirs .. ")")
    end
  end
  check(playable >= #specs * 0.8,
    ("%d of %d duel specs name a deck the game has"):format(playable, #specs))

  -- play one of them end to end
  local spec = nil
  for _, entry in ipairs(specs) do
    if entry.step.deckConstant and Collection.builtinDeck(decks, entry.step.deckConstant) then
      spec = entry; break
    end
  end
  local theirs = Collection.builtinDeck(decks, spec.step.deckConstant)
  while #theirs > 60 do table.remove(theirs) end
  local duel = Duel.new(cards, { decks = { mine, theirs },
    prizes = spec.step.prizes, seed = 5, names = { "YOU", "NPC" } })
  SimpleAI.playout(duel)
  check(duel.finished ~= nil, "a script duel plays to a finish")
  check(#duel.players[1].prizes == 0 or #duel.players[2].prizes == 0
    or duel.finished.reason ~= nil, "it ends by the rules")

  -- and the script continues past the duel
  local runner = ScriptRunner.new({ script = spec.npc.script, npc = spec.npc, events = {} })
  local pending, guard = runner:run(), 0
  local sawDuel = false
  while pending and guard < 40 do
    guard = guard + 1
    if pending.kind == "duel" then sawDuel = true end
    pending = runner:advance(true)
  end
  check(runner.finished, "the script finishes after the duel")
end

-- 6. command coverage: no script command executes unhandled, medals and
-- card grants reach the collection, and event comparisons branch correctly
do
  local Collection = require("src.tcg.Collection")
  local cards = dofile(cacheDir .. "/data/generated/cards.lua")
  local unhandled, executed, choices, medals, granted = 0, {}, 0, 0, 0
  for _, npc in pairs(npcData.npcs) do
    if npc.script then
      for seed = 0, 1 do
        local events = {}
        if seed == 1 then
          for _, step in ipairs(npc.script) do
            if step.name:find("^JumpIfEvent") then events[step.args[1] or 0] = 1 end
          end
        end
        local collection = Collection.new(cards)
        local runner = ScriptRunner.new({ script = npc.script, npc = npc,
          events = events, collection = collection,
          player = { x = 0, y = 0, facing = 0 } })
        local pending, guard = runner:run(), 0
        while pending and guard < 40 do
          guard = guard + 1
          if pending.kind == "choice" then choices = choices + 1 end
          pending = runner:advance(true)
        end
        for name, n in pairs(runner.unhandled) do unhandled = unhandled + n end
        for _, step in ipairs(npc.script) do executed[step.name] = true end
        medals = medals + collection:medalCount()
        granted = granted + collection:totalOwned()
      end
    end
  end
  check(unhandled == 0, unhandled .. " script commands executed unhandled")
  local distinct = 0
  for _ in pairs(executed) do distinct = distinct + 1 end
  check(distinct >= 50, distinct .. " distinct commands appear in the scripts")
  check(choices > 0, "multichoice commands yield a choice to the caller")
  check(medals > 0, "some script awards a medal")
  check(granted > 0, "some script grants a card")
end

-- event comparisons take the right branch
do
  local step = { name = "JumpIfEventEqual", args = { 7, 3, 0x00, 0x50 }, address = 0x4000 }
  local target = { name = "PrintText", args = { 1, 0 }, address = 0x5000, text = "at the target" }
  local fall = { name = "PrintText", args = { 2, 0 }, address = 0x4005, text = "fell through" }
  local script = { step, fall, target }
  local hit = ScriptRunner.new({ script = script, events = { [7] = 3 } }):run()
  check(hit and hit.text == "at the target", "equal value jumps")
  local miss = ScriptRunner.new({ script = script, events = { [7] = 2 } }):run()
  check(miss and miss.text == "fell through", "unequal value falls through")
end

-- 7. medals go through the game's own event flags, and the save carries them
do
  local Collection = require("src.tcg.Collection")
  local cards = dofile(cacheDir .. "/data/generated/cards.lua")
  local manifest = { EVENT_MEDAL_FLAGS = 16, EVENT_MEDAL_COUNT = 46,
    EVENT_HALL_OF_HONOR_DOORS_OPEN = 99 }
  local collection = Collection.new(cards)
  local events = {}
  local script = {}
  for bit = 0, 7 do
    script[#script + 1] = { name = "ShowMedalReceivedScreen", args = { bit },
      address = 0x4000 + bit }
  end
  script[#script + 1] = { name = "EndScript", args = {}, address = 0x4100 }
  local runner = ScriptRunner.new({ script = script, events = events,
    collection = collection, eventByName = manifest })
  runner:run()
  check(events[16] == 255, "all eight medal bits set in EVENT_MEDAL_FLAGS (" .. tostring(events[16]) .. ")")
  check(events[46] == 8, "EVENT_MEDAL_COUNT reached 8 (" .. tostring(events[46]) .. ")")
  check(collection:medalCount() == 8 and collection:hasAllMedals(), "the collection agrees")
  -- awarding the same medal twice must not double-count
  local again = ScriptRunner.new({ script = { script[1], script[#script] }, events = events,
    collection = collection, eventByName = manifest })
  again:run()
  check(events[46] == 8, "re-awarding a medal does not raise the count")
  collection.events = events
  local back = Collection.deserialize(cards, collection:serialize())
  check(back and back:medalCount() == 8, "medals survive a save round trip")
  check(back and back.events[16] == 255, "event values survive a save round trip")
end

-- 8. multichoice menus carry the game's own options
do
  local menus = dofile(cacheDir .. "/data/generated/multichoice.lua")
  local withOptions = 0
  for name, menu in pairs(menus) do
    check(menu.command == name, name .. " is keyed by its command")
    if #menu.options > 0 then
      withOptions = withOptions + 1
      for _, option in ipairs(menu.options) do
        check(option.text and #option.text > 0, name .. " option has text")
      end
    end
  end
  check(withOptions == 4, withOptions .. " of 4 menus have their options")
  local sam = menus.ShowSamNormalMultichoice
  check(sam and #sam.options == 4 and sam.cursorMax == 4,
    "Sam's menu has its four options from the config table")
  local rules = menus.ShowSamRulesMultichoice
  check(rules and #rules.options == rules.cursorMax and #rules.options >= 8,
    "Sam's rules menu options match its cursor range")

  local starter = menus.ChooseStarterDeckMultichoice
  check(starter and #starter.options == 3, "the starter menu offers three decks")

  -- a script hitting a multichoice yields those options and records the pick
  local script = {
    { name = "ChooseDeckToDuelAgainstMultichoice", args = {}, address = 0x4000 },
    { name = "EndScript", args = {}, address = 0x4001 },
  }
  local events = {}
  local runner = ScriptRunner.new({ script = script, events = events,
    multichoice = menus, eventByName = { EVENT_AARON_DECK_MENU_CHOICE = 118 } })
  local pending = runner:run()
  check(pending and pending.kind == "choice", "the command yields a choice")
  check(#pending.options == 3, "with the three deck options (" .. #pending.options .. ")")
  runner:advance(2)
  check(events[118] == 1, "the pick is stored in the event (" .. tostring(events[118]) .. ")")
end

-- 9. scripted movement
do
  local Overworld = require("src.tcg.Overworld")
  -- paths decode out of the movement tables
  local paths, steps = 0, 0
  local function scan(list)
    for _, step in ipairs(list or {}) do
      if step.path then
        paths = paths + 1
        steps = steps + #step.path
        for _, direction in ipairs(step.path) do
          check(direction >= 0 and direction <= 3, "a path step is a direction")
        end
      end
    end
  end
  for _, npc in pairs(npcData.npcs) do scan(npc.script) end
  for i = 0, maps.count - 1 do
    local map = maps.maps[i]
    for _, code in pairs(map.scriptCode or {}) do scan(code.steps) end
    for _, object in ipairs(map.objects or {}) do scan(object.script) end
    if map.afterDuel then
      for _, entry in ipairs(map.afterDuel.entries) do scan(entry.win); scan(entry.lose) end
    end
  end
  check(paths >= 10, paths .. " movement paths decoded")
  check(steps >= 40, steps .. " movement steps in total")

  -- walking the player along a path moves them and respects collision
  local ow = Overworld.new({ maps = maps, map = 1, npcs = npcData })
  local sx, sy = ow.x, ow.y
  ow:walkPath("player", { Overworld.EAST, Overworld.EAST })
  check(ow.x ~= sx or ow.y ~= sy, "the player moved along the path")
  check(ow:walkable(ow.x, ow.y), "and landed somewhere walkable")
  check(ow.x % 2 == 0 and ow.y % 2 == 0, "staying on the movement grid")

  -- a path into a wall stops rather than walking through it
  local blocked = Overworld.new({ maps = maps, map = 1, npcs = npcData })
  blocked.x, blocked.y = blocked:firstWalkable()
  local far = {}
  for _ = 1, 20 do far[#far + 1] = Overworld.NORTH end
  blocked:walkPath("player", far)
  check(blocked:walkable(blocked.x, blocked.y), "a blocked path stops on a walkable tile")
  check(blocked.y >= 0, "and does not leave the map")

  -- an NPC path moves that NPC's placement
  local world = Overworld.new({ maps = maps, map = 1, npcs = npcData })
  local mover = world.map.npcs[1]
  local mx, my = mover.x, mover.y
  world:walkPath(mover.npc, { Overworld.SOUTH })
  check(mover.x ~= mx or mover.y ~= my, "the NPC moved")
end

-- 10. scripts award the booster packs they name, not a stand-in
do
  local constants = dofile(cacheDir .. "/data/generated/constants.lua")
  local boosterIds = constants.enums and constants.enums.boosters
  check(boosterIds ~= nil, "the booster id table is in the cache")

  local awarded, distinct = 0, {}
  local function runScript(script, npc)
    if not script then return end
    local runner = ScriptRunner.new({ script = script, npc = npc, events = {},
      boosterIds = boosterIds,
      onBoosters = function(count, packs)
        for _, pack in ipairs(packs or {}) do
          awarded = awarded + 1
          distinct[pack.constant or ("id" .. pack.id)] = true
          check(pack.id ~= 0xff, "NO_BOOSTER slots are not awarded")
          check(pack.constant ~= nil, "the pack id resolves to a constant")
        end
      end })
    local pending, guard = runner:run(), 0
    while pending and guard < 40 do guard = guard + 1; pending = runner:advance(true) end
  end

  for _, npc in pairs(npcData.npcs) do runScript(npc.script, npc) end
  for i = 0, maps.count - 1 do
    local map = maps.maps[i]
    if map.afterDuel then
      for _, entry in ipairs(map.afterDuel.entries) do runScript(entry.win) end
    end
  end
  local kinds = 0
  for _ in pairs(distinct) do kinds = kinds + 1 end
  check(awarded >= 30, awarded .. " packs awarded across the scripts")
  check(kinds >= 10, kinds .. " distinct pack types, so clubs give their own")
end

print(("tcg script tests: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
