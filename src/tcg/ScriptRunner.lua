-- Overworld script interpreter (docs/tcg-phase1.md, Phase 12).
--
-- Runs the decoded scripts from data/generated/npcs.lua: the player talks to
-- an NPC, the script steps until it wants to show text, ask a question or
-- start a duel, and yields; the caller (Overworld / the UI) advances it.
--
-- Commands are executed by name.  Anything not implemented is skipped and
-- recorded in `unhandled`, so an unported command degrades to "nothing
-- happens" instead of stopping the script -- the same policy the duel
-- effects use.
--
-- Event flags live in a plain table (`events`), keyed by the event number the
-- script references, so a save can carry them.

local ScriptRunner = {}
ScriptRunner.__index = ScriptRunner

-- opts: { script = decoded steps, npc = npc entry, events = table,
--         collection = Collection (optional, for the card commands),
--         player = { x, y, facing } (optional, for the movement commands),
--         onDuel = fn(spec), onBoosters = fn(count), onCard = fn(id) }
function ScriptRunner.new(opts)
  return setmetatable({
    script = assert(opts.script),
    npc = opts.npc,
    events = opts.events or {},
    onDuel = opts.onDuel,
    onBoosters = opts.onBoosters,
    onCard = opts.onCard,
    collection = opts.collection,
    -- event ids the game itself uses for medals and the Hall of Honor
    -- (constants/script_constants.asm, carried in the manifest)
    eventByName = opts.eventByName or {},
    multichoice = opts.multichoice or {},   -- data/generated/multichoice.lua
    medalEvents = opts.medalEvents,         -- medal bit -> EVENT_BEAT_* id
    cardsByConstant = opts.cardsByConstant, -- for the legendary card picks
    onSave = opts.onSave,
    onMove = opts.onMove,   -- fn(who, directions, npc): walk a path
    boosterIds = opts.boosterIds,   -- booster id -> BOOSTER_* constant
    medalBits = opts.medalBits or {},
    player = opts.player,
    requestedCard = nil,      -- the card the Man1/challenge-hall NPCs ask for
    pc = 1,
    finished = false,
    pending = nil,        -- { kind = "text"|"question"|"duel", ... }
    unhandled = {},
    log = {},
  }, ScriptRunner)
end

function ScriptRunner:say(fmt, ...) self.log[#self.log + 1] = fmt:format(...) end

function ScriptRunner:event(id) return self.events[id] or 0 end
function ScriptRunner:setEvent(id, value) self.events[id] = value end

-- Scripts jump by ROM address; the decoded steps carry theirs.
function ScriptRunner:jumpTo(address)
  -- `test_if_event_*` compiles to a conditional jump with a NULL target
  -- (macros/scripts.asm): the branch is a flag test the caller reads, so a
  -- null or non-ROMX target means "carry on", not "leave the script"
  if not address or address < 0x4000 or address >= 0x8000 then
    self.lastTest = true
    return false
  end
  for index, step in ipairs(self.script) do
    if step.address == address then self.pc = index; return true end
  end
  -- a jump outside the decoded window ends the script rather than looping
  self.finished = true
  self:say("jump to $%04x is outside the decoded script", address)
  return false
end

local function arg16(step, i)
  return (step.args[i] or 0) + (step.args[i + 1] or 0) * 0x100
end

-- Run until the script yields something to show, or finishes.
function ScriptRunner:run()
  local guard = 0
  while not self.finished and not self.pending do
    guard = guard + 1
    if guard > 200 then
      self.finished = true
      self:say("script guard tripped")
      break
    end
    local step = self.script[self.pc]
    if not step then self.finished = true; break end
    self.pc = self.pc + 1
    local name = step.name

    if name:find("^EndScript") or name == "QuitScriptFully" then
      self.finished = true
    elseif name:find("^Print") then
      self.pending = { kind = "text", text = step.text, textId = step.textId,
        name = self.npc and self.npc.name }
      if name == "PrintTextQuitFully" then self.quitAfterText = true end
    elseif name == "AskQuestionJump" or name == "AskQuestionJumpDefaultYes" then
      self.pending = { kind = "question", text = step.text,
        name = self.npc and self.npc.name, target = step.target }
    elseif name == "StartDuel" then
      local spec = { prizes = step.prizes, deck = step.deck,
        deckConstant = step.deckConstant, music = step.music,
        npc = self.npc }
      self.pending = { kind = "duel", duel = spec }
      if self.onDuel then self.onDuel(spec) end
    elseif name == "Jump" then
      self:jumpTo(step.target or arg16(step, 1))
    elseif name == "JumpIfEventTrue" then
      local id = step.args[1] or 0
      if self:event(id) ~= 0 then self:jumpTo(arg16(step, 2)) end
    elseif name == "JumpIfEventFalse" then
      local id = step.args[1] or 0
      if self:event(id) == 0 then self:jumpTo(arg16(step, 2)) end
    elseif name == "JumpIfEventGreaterOrEqual" then
      local id, value = step.args[1] or 0, step.args[2] or 0
      if self:event(id) >= value then self:jumpTo(arg16(step, 3)) end
    elseif name == "JumpIfEventEqual" then
      local id, value = step.args[1] or 0, step.args[2] or 0
      if self:event(id) == value then self:jumpTo(arg16(step, 3)) end
    elseif name == "JumpIfEventNotEqual" then
      local id, value = step.args[1] or 0, step.args[2] or 0
      if self:event(id) ~= value then self:jumpTo(arg16(step, 3)) end
    elseif name == "JumpIfEventLessThan" then
      local id, value = step.args[1] or 0, step.args[2] or 0
      if self:event(id) < value then self:jumpTo(arg16(step, 3)) end
    elseif name == "JumpIfEventZero" then
      if self:event(step.args[1] or 0) == 0 then self:jumpTo(arg16(step, 2)) end
    elseif name == "JumpIfEventNonzero" or name == "JumpIfEventNotZero" then
      if self:event(step.args[1] or 0) ~= 0 then self:jumpTo(arg16(step, 2)) end
    elseif name == "ZeroOutEventValue" then
      self:setEvent(step.args[1] or 0, 0)
    elseif name == "IncrementEventValue" then
      local id = step.args[1] or 0
      self:setEvent(id, math.min(0xff, self:event(id) + 1))
    elseif name == "SetEventValue" or name == "SetEventTrue" then
      self:setEvent(step.args[1] or 0, step.args[2] or 1)
    elseif name == "SetEventFalse" then
      self:setEvent(step.args[1] or 0, 0)
    elseif name == "MaxOutEventValue" then
      self:setEvent(step.args[1] or 0, 0xff)
    elseif name == "GiveBoosterPacks" then
      -- three booster ids, NO_BOOSTER ($ff) for the unused slots; the ids
      -- name which pack, so pass them on rather than only a count
      local packs = {}
      for _, id in ipairs(step.args) do
        if id and id ~= 0xff then
          packs[#packs + 1] = { id = id, constant = self.boosterIds and self.boosterIds[tostring(id)] }
        end
      end
      if #packs > 0 and self.onBoosters then self.onBoosters(#packs, packs) end
      self:say("received %d booster pack(s)", #packs)
    elseif name == "GiveOneOfEachTrainerBooster" then
      if self.onBoosters then self.onBoosters(3, nil, "trainer") end
    elseif name == "GiveCard" or name == "ShowCardReceivedScreen" then
      -- give_card VARIABLE_CARD hands over whatever PickLegendaryCard chose
      local card = arg16(step, 1)
      if card == 0 or card == 0xffff then card = self.variableCard or 0 end
      if card > 0 and self.collection then self.collection:add(card, 1) end
      if self.onCard then self.onCard(card) end
      self:say("received card %d", card)
    elseif name == "TakeCard" then
      local card = arg16(step, 1)
      if self.collection and self.collection:count(card) > 0 then
        self.collection.collection[card] = self.collection:count(card) - 1
      end
      self:say("gave away card %d", card)
    elseif name == "JumpIfCardOwned" or name == "JumpIfCardInCollection" then
      local card = arg16(step, 1)
      local owned = self.collection and self.collection:count(card) > 0
      if owned then self:jumpTo(arg16(step, 3)) end
    elseif name == "JumpIfMan1RequestedCardInCollection" then
      local card = self.requestedCard
      local owned = card and self.collection and self.collection:count(card) > 0
      if owned then self:jumpTo(arg16(step, 1)) end
    elseif name == "LoadMan1RequestedCardIntoTxRamSlot"
      or name == "LoadChallengeHallNPCIntoTxRamSlot" then
      -- these fill a text substitution slot; nothing to show until the text
      -- system supports {RAM} substitution, but remember the card asked for
      self.requestedCard = self.requestedCard or arg16(step, 1)
    elseif name == "TryGivePCPack" or name == "TryGiveMedalPCPacks" then
      local packs = name == "TryGiveMedalPCPacks" and 2 or 1
      if self.onBoosters then self.onBoosters(packs, nil, "pc") end
      self:say("%d pack(s) sent to the PC", packs)
    elseif name == "SetPlayerDirection" then
      if self.player then self.player.facing = step.args[1] or self.player.facing end
    elseif name == "MovePlayer" then
      -- move_player is direction and speed, one step per call; the world
      -- moves two tiles at a time, which is one permission block
      if self.player and self.onMove then
        self.onMove("player", { step.args[1] or 0 })
      end
    elseif name == "MoveActiveNPC" or name == "MoveArbitraryNPC"
      or name == "MoveActiveNPCByDirection" then
      -- the decoded step carries the movement table as a list of directions
      if step.path and self.onMove then
        self.onMove(step.npc or "active", step.path, self.npc)
      end
    elseif name == "JumpIfPlayerCoordsMatch" then
      local x, y = step.args[1], step.args[2]
      if self.player and self.player.x == x and self.player.y == y then
        self:jumpTo(arg16(step, 3))
      end
    elseif name == "ShowMedalReceivedScreen" then
      -- the game keeps medals as a bitmask in EVENT_MEDAL_FLAGS with a
      -- running total in EVENT_MEDAL_COUNT, so the port writes both
      -- the argument is the EVENT_BEAT_* id, not a bit index: MedalEvents
      -- maps medal bit -> event, so invert it (falling back to the order the
      -- events are declared in, which is the same order)
      local eventId = step.args[1] or 0
      local bit
      for index, id in pairs(self.medalEvents or {}) do
        if id == eventId then bit = tonumber(index) end
      end
      if not bit then
        local first = self.eventByName.EVENT_BEAT_NIKKI
        bit = first and (eventId - first) or eventId
      end
      bit = math.max(0, math.min(7, bit))
      local flagsId = self.eventByName.EVENT_MEDAL_FLAGS
      local countId = self.eventByName.EVENT_MEDAL_COUNT
      if flagsId then
        local flags = self:event(flagsId)
        local mask = math.floor(2 ^ bit)   -- integer: 2^n is a float in 5.4
        if math.floor(flags / mask) % 2 == 0 then
          self:setEvent(flagsId, flags + mask)
          if countId then self:setEvent(countId, self:event(countId) + 1) end
        end
      end
      if self.collection then self.collection:giveMedal(bit) end
      self:say("received medal %d", bit)
    elseif name == "JumpIfMan1RequestedCardOwned" then
      local card = self.requestedCard
      if card and self.collection and self.collection:count(card) > 0 then
        self:jumpTo(arg16(step, 1))
      end
    elseif name == "PickNextMan1RequestedCard" then
      -- the game rolls a card it wants next; headless play keeps the current
      -- one rather than inventing a roll the save cannot reproduce
      self.requestedCard = self.requestedCard or nil
    elseif name == "JumpBasedOnFightingClubPupilStatus" then
      -- three-way jump on how far the Fighting Club pupils have got; the
      -- event value stands in for that status
      local status = self:event(step.args[1] or 0)
      local target = arg16(step, 2 + status * 2)
      if target and target >= 0x4000 then self:jumpTo(target) end
    elseif name:find("Multichoice$") then
      -- the menu's own options and prompt, read from the command's arg block
      -- (data/generated/multichoice.lua); the two Sam menus take theirs from
      -- a config table that is not extracted, so those fall back to a single
      -- acknowledgement rather than to invented option text
      local menu = self.multichoice[name]
      local options = {}
      for _, option in ipairs(menu and menu.options or {}) do
        options[#options + 1] = option.text or "?"
      end
      if #options == 0 then options = { "OK" } end
      self.pending = { kind = "choice", command = name, options = options,
        name = (menu and menu.title) or (self.npc and self.npc.name),
        text = menu and menu.prompt,
        cancelValue = menu and menu.cancelValue }
    elseif name == "SetNextNPCAndScript" then
      self.nextNpc = { npc = step.args[1], script = arg16(step, 2) }
    elseif name == "JumpIfEnoughCardsOwned" then
      -- args: card, count, target
      local card, want = step.args[1] or 0, step.args[2] or 1
      local owned = self.collection and self.collection:count(card) or 0
      if owned >= want then self:jumpTo(arg16(step, 3)) end
    elseif name == "PlayCredits" then
      -- the ending: the caller shows the credits and the run is over
      self.pending = { kind = "credits", name = self.npc and self.npc.name }
      self.finished = true
    elseif name == "SaveGame" then
      if self.onSave then self.onSave() end
      self:say("game saved")
    elseif name == "PickLegendaryCard" then
      -- picks one of the four legendary cards the player is still missing;
      -- the chosen card is what a following GiveCard hands over
      local remaining = {}
      for _, constant in ipairs({ "ZAPDOS_LV68", "MOLTRES_LV37", "ARTICUNO_LV37", "DRAGONITE_LV41" }) do
        local id = self.cardsByConstant and self.cardsByConstant[constant]
        if id and (not self.collection or self.collection:count(id) == 0) then
          remaining[#remaining + 1] = id
        end
      end
      self.variableCard = remaining[1]
    elseif name == "OpenDeckMachine" then
      self.pending = { kind = "deckMachine", machine = step.args[1],
        name = self.npc and self.npc.name }
    elseif name == "FlashScreen" or name == "ShakeScreen" then
      -- visual flourish
      self.nextNpc = { npc = step.args[1], script = arg16(step, 2) }
    elseif name == "DoFrames" or name == "CloseTextBox" or name == "CloseAdvancedTextBox"
      or name == "SetDefaultSong" or name == "PlaySong" or name == "PlaySFX"
      or name == "WaitForSongToFinish" then
      -- timing, text-box and audio housekeeping: nothing for a headless run
    else
      self.unhandled[name] = (self.unhandled[name] or 0) + 1
    end
  end
  return self.pending
end

-- The caller answers whatever was pending.  `yes` matters only for questions.
function ScriptRunner:advance(yes)
  local pending = self.pending
  self.pending = nil
  if not pending then return self:run() end
  if pending.kind == "text" and self.quitAfterText then
    self.quitAfterText = nil
    self.finished = true
    return nil
  end
  if pending.kind == "question" then
    if yes and pending.target then self:jumpTo(pending.target) end
  end
  if pending.kind == "choice" then
    -- `yes` carries the option index (true means the first, false a cancel)
    local index = (yes == true and 1) or (yes == false and nil) or tonumber(yes)
    self.lastChoice = index or pending.cancelValue
    -- the game stores the pick in an event so later branches can read it
    local eventName = ({
      ChooseDeckToDuelAgainstMultichoice = "EVENT_AARON_DECK_MENU_CHOICE",
      ShowSamNormalMultichoice = "EVENT_SAM_MENU_CHOICE",
    })[pending.command]
    local id = eventName and self.eventByName[eventName]
    if id then self:setEvent(id, index and (index - 1) or (pending.cancelValue or 0)) end
  end
  if pending.kind == "duel" then
    -- the duel's outcome is the caller's business; the script continues after
    self.lastDuel = pending.duel
  end
  return self:run()
end

return ScriptRunner
