-- A scripted playthrough: start a new game, then for each club leader talk
-- to them, duel with the real engine and AI, and check that winning leads to
-- a medal and that eight medals open the Hall of Honor.
--
-- What this harness supplies itself, and why: the game records a win in
-- EVENT_BEAT_* from the after-duel map script slot, which the extractor does
-- not decode yet, so the harness sets that event when the duel is won. Every
-- other step -- the dialogue branch, the duel, the medal award, the event
-- bookkeeping, the save -- is the port's own code.
--
--   TCG_CACHE=<dir> lua tests/tcg_playthrough_test.lua

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/npcs.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local decks = dofile(cacheDir .. "/data/generated/decks.lua")
local boosters = dofile(cacheDir .. "/data/generated/boosters.lua")
local npcData = dofile(cacheDir .. "/data/generated/npcs.lua")
local maps = dofile(cacheDir .. "/data/generated/maps.lua")
local multichoice = dofile(cacheDir .. "/data/generated/multichoice.lua")
local constants = dofile(cacheDir .. "/data/generated/constants.lua")

local Duel = require("src.tcg.Duel")
local DuelAI = require("src.tcg.DuelAI")
local SimpleAI = require("src.tcg.SimpleAI")
local Collection = require("src.tcg.Collection")
local ScriptRunner = require("src.tcg.ScriptRunner")
local Overworld = require("src.tcg.Overworld")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. msg) end
end

local eventByName = constants.eventByName
local medalEvents = constants.medalEvents

-- new game
local saved
local collection = Collection.new(cards)
collection:giveStarter("charmander", decks)
check(collection.decks[1] and #collection.decks[1].cards == 60, "new game gives a legal deck")
local events = collection.events

-- The club chain: each club map has an after-duel dispatch table naming its
-- opponents and the scripts that run on a win or a loss.  The medal awards
-- live behind the win scripts, so a playthrough is: for each club, duel the
-- master with the real engine and AI, then run the win script.
local clubs = {}
for i = 0, maps.count - 1 do
  local map = maps.maps[i]
  if map.afterDuel then
    for _, entry in ipairs(map.afterDuel.entries) do
      for _, step in ipairs(entry.win or {}) do
        if step.name == "ShowMedalReceivedScreen" then
          clubs[#clubs + 1] = { map = map, entry = entry, medalEvent = step.args[1] }
          break
        end
      end
    end
  end
end
check(#clubs == 8, ("%d clubs award a medal"):format(#clubs))

-- The duel a master starts: usually a StartDuel in their own script, but
-- several clubs start it from a script the master's header points at
-- indirectly, so the NPC header's own deck field is the fallback -- that is
-- what the game loads for a duelling NPC either way.
local function duelSpecFor(npcId)
  local npc = npcData.npcs[npcId] or npcData.npcs[tostring(npcId)]
  if not npc then return nil end
  for _, step in ipairs(npc.script or {}) do
    if step.name == "StartDuel" and step.deckConstant then return step, npc end
  end
  if npc.deckConstant then
    return { prizes = 6, deck = npc.deck, deckConstant = npc.deckConstant }, npc
  end
end

local duelsPlayed, duelsWon, medalsAwarded = 0, 0, 0
for _, club in ipairs(clubs) do
  local spec, npc = duelSpecFor(club.entry.npc)
  local won = false
  if spec then
    local theirs = Collection.builtinDeck(decks, spec.deckConstant)
    if theirs then
      while #theirs > 60 do table.remove(theirs) end
      -- the player AI retries as a player would; the starter deck beats the
      -- later masters only about one duel in four, so the cap has to allow
      -- for that rather than treating a losing streak as a failure
      for attempt = 1, 25 do
        local duel = Duel.new(cards, { decks = { collection.decks[1].cards, theirs },
          prizes = spec.prizes, seed = attempt * 131 + club.medalEvent,
          names = { "YOU", club.entry.constant or "MASTER" } })
        duel:start()
        for p = 1, 2 do
          for _, id in ipairs(duel.players[p].hand) do
            local c = duel:card(id)
            if c.kind == "pokemon" and c.stage == "BASIC" then duel:placeActive(p, id); break end
          end
        end
        duel:finishSetup()
        local turns = 0
        while not duel.finished and turns < 4000 do
          turns = turns + 1
          if duel.current == 1 then DuelAI.takeTurn(duel, 1) else SimpleAI.act(duel, 2) end
          if duel.turn > 300 then duel:finish(0, "turn limit") end
        end
        duelsPlayed = duelsPlayed + 1
        if duel.finished.winner == 1 then won = true; duelsWon = duelsWon + 1; break end
      end
    end
  end
  check(spec ~= nil, (club.entry.constant or "?") .. " has a duel in their script")
  check(won, (club.entry.constant or "?") .. " was beaten by the player AI")

  if won then
    -- the win script: awards the medal, hands out packs, sets the beat event
    local runner = ScriptRunner.new({
      script = club.entry.win, npc = npc, events = events, collection = collection,
      multichoice = multichoice, eventByName = eventByName, medalEvents = medalEvents,
    })
    local pending, guard = runner:run(), 0
    while pending and guard < 60 do guard = guard + 1; pending = runner:advance(true) end
    local before = medalsAwarded
    medalsAwarded = collection:medalCount()
    check(medalsAwarded > before,
      (club.entry.constant or "?") .. "'s win script awarded a medal")
  end
end

print(("clubs: %d duels played, %d won, %d medals awarded")
  :format(duelsPlayed, duelsWon, medalsAwarded))

local flagsId = eventByName.EVENT_MEDAL_FLAGS
local countId = eventByName.EVENT_MEDAL_COUNT
check(collection:medalCount() == 8, ("%d medals held"):format(collection:medalCount()))
check(events[flagsId] == 255, ("EVENT_MEDAL_FLAGS is %s"):format(tostring(events[flagsId])))
check(events[countId] == 8, ("EVENT_MEDAL_COUNT is %s"):format(tostring(events[countId])))
check(collection:hasAllMedals(), "the Hall of Honor condition is met")

-- the run survives a save
collection.events = events
local reloaded = Collection.deserialize(cards, collection:serialize())
check(reloaded and reloaded:hasAllMedals(), "medals survive the save")
check(reloaded and (reloaded.events[flagsId] or 0) == 255, "event flags survive the save")

-- and the Hall of Honor map exists to walk into
local hall
for i = 0, maps.count - 1 do
  if maps.maps[i].constant == "HALL_OF_HONOR" then hall = maps.maps[i] end
end
check(hall ~= nil, "the Hall of Honor map is present")
if hall then
  local world = Overworld.new({ maps = maps, map = hall.index, npcs = npcData,
    events = events, collection = collection, eventByName = eventByName })
  check(world.map.constant == "HALL_OF_HONOR", "the player can be placed there")
end

-- The ending: with all eight medals, the Hall of Honor's legendary-card
-- object hands over the four birds and rolls the credits.
do
  local hallMap
  for i = 0, maps.count - 1 do
    if maps.maps[i].constant == "HALL_OF_HONOR" then hallMap = maps.maps[i] end
  end
  check(hallMap ~= nil, "the Hall of Honor map is present")
  local ending
  for _, object in ipairs(hallMap and hallMap.objects or {}) do
    for _, step in ipairs(object.script or {}) do
      if step.name == "PlayCredits" then ending = object; break end
    end
    if ending then break end
  end
  check(ending ~= nil, "an object in the Hall of Honor rolls the credits")

  if ending then
    local saved = false
    local runner = ScriptRunner.new({
      script = ending.script, events = events, collection = collection,
      eventByName = eventByName, medalEvents = medalEvents,
      cardsByConstant = cards.byConstant,
      onSave = function() saved = true end,
    })
    local pending, guard = runner:run(), 0
    local sawCredits = false
    while pending and guard < 40 do
      guard = guard + 1
      if pending.kind == "credits" then sawCredits = true end
      pending = runner:advance(true)
    end
    check(sawCredits or runner.finished, "the ending script runs to the credits")
    check(saved, "the ending saves the game")
    for _, name in ipairs({ "ZAPDOS_LV68", "MOLTRES_LV37", "ARTICUNO_LV37", "DRAGONITE_LV41" }) do
      local id = cards.byConstant[name]
      check(id and collection:count(id) > 0, name .. " was awarded")
    end
  end
end

-- the credits sequence the ending hands off to
do
  local credits = dofile(cacheDir .. "/data/generated/credits.lua")
  check(credits.available, "the credits sequence extracted")
  check(#credits.steps > 300, #credits.steps .. " credits commands decoded")
  local names, withText = {}, 0
  for _, step in ipairs(credits.steps) do
    names[step.name] = true
    if step.textId then withText = withText + 1 end
  end
  check(names.DisableLCD and names.FadeIn and names.FadeOut,
    "the sequence uses the display commands")
  check(withText >= 20, withText .. " credits steps carry a text id")
  check(credits.steps[1].name == "DisableLCD", "it starts by disabling the LCD")

  -- the roll actually plays: run every frame of it headlessly
  local CreditsSequence = require("src.tcg.CreditsSequence")
  local text = dofile(cacheDir .. "/data/generated/text.lua")
  local sequence = CreditsSequence.new({ credits = credits,
    textFor = function(id) return text.byId[id] end })
  local frames = sequence:runToEnd()
  check(sequence.finished, "the credits sequence runs to the end")
  check(frames > 3000 and frames < 40000,
    ("it lasts %d frames (%.0f seconds)"):format(frames, frames / 60.24))
  check(sequence.shown >= 20, sequence.shown .. " text lines were shown")
  check(sequence.fade >= 0 and sequence.fade <= 1, "the fade level stays in range")
end

print(("tcg playthrough: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  print("INCOMPLETE: the run reaches " .. collection:medalCount() .. " of 8 medals.")
end

-- The run completes, so this is a real test again rather than a report.
if failed > 0 then os.exit(1) end
