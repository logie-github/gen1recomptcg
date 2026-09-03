-- Human-vs-AI duel session (docs/tcg-phase1.md, Phase 6).
--
-- Everything a duel screen needs except drawing: which menu is open, what
-- the cursor is on, which prompt is pending, and the paced log.  Input is
-- fed as Game Boy buttons ("up", "down", "left", "right", "a", "b",
-- "start", "select") through DuelSession:press, so the session is unit
-- tested headless (tests/tcg_session_test.lua) and the LÖVE screen
-- (src/tcg/ui/DuelScreen.lua) is only a renderer.
--
-- Flow: setup (choose active, optional bench) -> turns.  On the human's
-- turn the main menu offers HAND / ATTACK / RETREAT / POWER / CHECK / END.
-- Choices the engine would default (evolution target, energy target, retreat
-- target, promotion, Trainer targets) are asked through `prompt`.  The AI
-- seat runs DuelAI.takeTurn in one go and its log lines are then paced out
-- three at a time with A.

local DuelAI = require("src.tcg.DuelAI")
local Effects = require("src.tcg.Effects")
local Powers = require("src.tcg.Powers")

local DuelSession = {}
DuelSession.__index = DuelSession

DuelSession.LOG_LINES = 3

-- opts: { duel = Duel, human = 1|2 }
function DuelSession.new(opts)
  local self = setmetatable({
    duel = assert(opts.duel),
    human = opts.human or 1,
    aiProfile = opts.aiProfile,
    ai = (opts.human or 1) == 1 and 2 or 1,
    mode = "setup",          -- setup | log | main | hand | attack | retreat | power | check | prompt | over
    cursor = 1,
    menu = {},               -- current list of { label, action } rows
    prompt = nil,            -- { title, options = { {label, value} }, onPick = fn, cancel = bool }
    logShown = 0,            -- log lines already presented
    pageLines = {},          -- lines on screen while mode == "log"
    afterLog = nil,          -- mode to return to once the log is caught up
    setupStage = "active",
  }, DuelSession)
  self.duel.autoPromote = { [self.human] = false, [self.ai] = true }
  return self
end

-- ---------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------

function DuelSession:me() return self.duel.players[self.human] end
function DuelSession:foe() return self.duel.players[self.ai] end
function DuelSession:card(id) return self.duel:card(id) end
function DuelSession:name(slot) return slot and self:card(slot.card).name or "-" end

function DuelSession:isHumanTurn()
  return self.duel.current == self.human and not self.duel.finished
end

-- Present unshown log lines; returns true if there was something to show.
function DuelSession:catchUpLog(nextMode)
  local log = self.duel.log
  if self.logShown >= #log then return false end
  self.afterLog = nextMode or self.afterLog or "main"
  self.pageLines = {}
  for i = self.logShown + 1, math.min(#log, self.logShown + DuelSession.LOG_LINES) do
    self.pageLines[#self.pageLines + 1] = log[i]
  end
  self.logShown = self.logShown + #self.pageLines
  self.mode = "log"
  return true
end

function DuelSession:skipLog()
  self.logShown = #self.duel.log
end

-- Where control should go next, given the duel state.
function DuelSession:resume()
  local d = self.duel
  if d.finished then
    if not self:catchUpLog("over") then self.mode = "over" end
    return
  end
  if self:me().needsPromotion then
    if self:catchUpLog("promote") then return end
    return self:promptPromotion()
  end
  if d.current == self.ai then
    -- the opponent plays with its own deck's profile when one is known
    DuelAI.takeTurn(d, self.ai, self.aiProfile)
    return self:resume()
  end
  if not self:catchUpLog("main") then self:openMain() end
end

-- ---------------------------------------------------------------------
-- prompts
-- ---------------------------------------------------------------------

function DuelSession:ask(title, options, onPick, cancellable)
  self.prompt = { title = title, options = options, onPick = onPick, cancel = cancellable ~= false }
  self.cursor = 1
  self.mode = "prompt"
end

function DuelSession:slotOptions(p, locations, labeler)
  local out = {}
  for _, loc in ipairs(locations) do
    local slot = self.duel:slotAt(p, loc)
    if slot then
      local label = (loc == 0 and "[A] " or ("[B" .. loc .. "] ")) .. self:name(slot)
        .. " " .. slot.hp .. "HP"
      if labeler then label = labeler(slot, loc, label) end
      out[#out + 1] = { label = label, value = loc }
    end
  end
  return out
end

function DuelSession:promptPromotion()
  local pl = self:me()
  local locs = {}
  for i = 1, #pl.bench do locs[#locs + 1] = i end
  self:ask("Choose a new Active Pokemon", self:slotOptions(self.human, locs), function(loc)
    self.duel:promote(self.human, loc)
    self:resume()
  end, false)
end

-- ---------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------

function DuelSession:start()
  local d = self.duel
  if d.phase ~= "setup" then d:start() end
  self:skipLog()
  self:setupActive()
end

function DuelSession:handBasics()
  local out = {}
  for _, id in ipairs(self:me().hand) do
    local c = self:card(id)
    if (c.kind == "pokemon" or c.pseudoPokemon) and c.stage == "BASIC" then
      out[#out + 1] = { label = c.name .. " " .. c.hp .. "HP", value = id }
    end
  end
  return out
end

function DuelSession:setupActive()
  self.mode = "setup"
  self:ask("Choose your Active Pokemon", self:handBasics(), function(id)
    self.duel:placeActive(self.human, id, false)
    self:setupBench()
  end, false)
end

function DuelSession:setupBench()
  local opts = self:handBasics()
  if #opts == 0 or #self:me().bench >= 5 then return self:finishSetup() end
  opts[#opts + 1] = { label = "Done", value = false }
  self:ask("Bench Basic Pokemon?", opts, function(id)
    if not id then return self:finishSetup() end
    self.duel:placeBench(self.human, id)
    self:setupBench()
  end, false)
end

function DuelSession:finishSetup()
  local d = self.duel
  -- AI's own setup: active = first Basic, bench everything else it can
  local ai = self:foe()
  for _, id in ipairs(ai.hand) do
    local c = self:card(id)
    if c.kind == "pokemon" and c.stage == "BASIC" then d:placeActive(self.ai, id); break end
  end
  local i = 1
  while i <= #ai.hand do
    local c = self:card(ai.hand[i])
    if c.kind == "pokemon" and c.stage == "BASIC" and #ai.bench < 5 then
      d:placeBench(self.ai, ai.hand[i])
    else i = i + 1 end
  end
  self:skipLog()
  d:finishSetup()
  self:resume()
end

-- ---------------------------------------------------------------------
-- main menu and submenus
-- ---------------------------------------------------------------------

function DuelSession:openMain()
  self.mode = "main"
  self.menu = {
    { label = "HAND", action = "hand" },
    { label = "ATTACK", action = "attack" },
    { label = "RETREAT", action = "retreat" },
    { label = "PKMN POWER", action = "power" },
    { label = "CHECK", action = "check" },
    { label = "END TURN", action = "endTurn" },
  }
  self.cursor = 1
end

function DuelSession:openHand()
  local pl = self:me()
  self.menu = {}
  for _, id in ipairs(pl.hand) do
    local c = self:card(id)
    local tag = c.kind == "energy" and "E" or (c.kind == "trainer" and not c.pseudoPokemon) and "T" or "P"
    self.menu[#self.menu + 1] = { label = ("%s %s"):format(tag, c.name), card = id }
  end
  if #self.menu == 0 then self.menu[1] = { label = "(no cards)" } end
  self.mode = "hand"
  self.cursor = 1
end

function DuelSession:legal(kind)
  local out = {}
  for _, a in ipairs(self.duel:legalActions(self.human)) do if a.kind == kind then out[#out + 1] = a end end
  return out
end

-- Play the selected hand card, asking for a target when there is a choice.
function DuelSession:playCard(id)
  local d, p = self.duel, self.human
  local c = self:card(id)
  if (c.kind == "pokemon" or c.pseudoPokemon) and c.stage == "BASIC" then
    local ok, err = d:playBasic(p, id)
    if not ok then return self:notice(err) end
    return self:afterAction()
  elseif c.kind == "pokemon" then
    local locs = {}
    for _, a in ipairs(self:legal("evolve")) do if a.card == id then locs[#locs + 1] = a.location end end
    if #locs == 0 then return self:notice("Cannot evolve that now") end
    if #locs == 1 then d:evolve(p, id, locs[1]); return self:afterAction() end
    return self:ask("Evolve which Pokemon?", self:slotOptions(p, locs), function(loc)
      d:evolve(p, id, loc); self:afterAction()
    end)
  elseif c.kind == "energy" then
    local locs = {}
    for _, a in ipairs(self:legal("attachEnergy")) do if a.card == id then locs[#locs + 1] = a.location end end
    if #locs == 0 then return self:notice("Already attached Energy this turn") end
    return self:ask("Attach to which Pokemon?", self:slotOptions(p, locs), function(loc)
      d:attachEnergy(p, id, loc); self:afterAction()
    end)
  else
    if not Effects.canPlayTrainer(d, p, id) or (self:me().noTrainersUntil and d.turn <= self:me().noTrainersUntil) then
      return self:notice("Cannot play that now")
    end
    return self:trainerArgs(id, function(args)
      local ok, err = d:playTrainer(p, id, args)
      if not ok then return self:notice(err or "No effect") end
      self:afterAction()
    end)
  end
end

-- Targets for the Trainers whose handlers read args.location / args.target.
local TRAINER_TARGETS = {
  POTION = { side = "me", key = "location", title = "Heal which Pokemon?" },
  SUPER_POTION = { side = "me", key = "location", title = "Heal which Pokemon?" },
  DEFENDER = { side = "me", key = "location", title = "Attach to which Pokemon?" },
  SWITCH = { side = "me", key = "location", title = "Switch with which?", benchOnly = true },
  MR_FUJI = { side = "me", key = "location", title = "Shuffle in which?", benchOnly = true },
  SCOOP_UP = { side = "me", key = "location", title = "Scoop up which?" },
  DEVOLUTION_SPRAY = { side = "me", key = "location", title = "Devolve which?" },
  GUST_OF_WIND = { side = "foe", key = "location", title = "Drag out which?", benchOnly = true },
  ENERGY_REMOVAL = { side = "foe", key = "location", title = "Remove Energy from?" },
}

function DuelSession:trainerArgs(id, done)
  local spec = TRAINER_TARGETS[self:card(id).constant]
  if not spec then return done({}) end
  local side = spec.side == "me" and self.human or self.ai
  local locs = {}
  for loc = spec.benchOnly and 1 or 0, #self.duel.players[side].bench do locs[#locs + 1] = loc end
  local opts = self:slotOptions(side, locs)
  if #opts <= 1 then return done({ [spec.key] = locs[1] }) end
  self:ask(spec.title, opts, function(loc) done({ [spec.key] = loc }) end)
end

function DuelSession:openAttack()
  local pl = self:me()
  local card = self:card(pl.active.card)
  local legal = self:legal("attack")
  self.menu = {}
  for i, atk in ipairs(card.attacks) do
    if atk.category ~= "POKEMON_POWER" then
      local ok = false
      for _, a in ipairs(legal) do if a.index == i then ok = true end end
      self.menu[#self.menu + 1] = {
        label = ("%s%s %s"):format(ok and "" or "x ", atk.name, atk.damage > 0 and tostring(atk.damage) or ""),
        index = ok and i or nil,
      }
    end
  end
  if #self.menu == 0 then self.menu[1] = { label = "(no attacks)" } end
  self.mode = "attack"
  self.cursor = 1
end

function DuelSession:openRetreat()
  local legal = self:legal("retreat")
  if #legal == 0 then return self:notice("Cannot retreat now") end
  local locs = {}
  for _, a in ipairs(legal) do locs[#locs + 1] = a.location end
  self:ask(("Retreat (cost %d) to:"):format(self.duel:retreatCost(self.human)),
    self:slotOptions(self.human, locs), function(loc)
      self.duel:retreat(self.human, loc); self:afterAction()
    end)
end

function DuelSession:openPower()
  local legal = self:legal("usePower")
  if #legal == 0 then return self:notice("No Pokemon Power to use") end
  local locs = {}
  for _, a in ipairs(legal) do locs[#locs + 1] = a.location end
  self:ask("Use which Pokemon Power?", self:slotOptions(self.human, locs), function(loc)
    local ok, err = self.duel:usePower(self.human, loc)
    if not ok then return self:notice(err or "No effect") end
    self:afterAction()
  end)
end

function DuelSession:openCheck()
  self.mode = "check"
  self.cursor = 1
end

function DuelSession:notice(text)
  self.duel:say("  %s", tostring(text))
  self:catchUpLog("main")
end

-- after any human action: show what happened, then continue
function DuelSession:afterAction()
  self:resume()
end

-- ---------------------------------------------------------------------
-- input
-- ---------------------------------------------------------------------

local function move(self, n, delta)
  if n == 0 then return end
  self.cursor = ((self.cursor - 1 + delta) % n) + 1
end

function DuelSession:press(btn)
  local mode = self.mode
  if mode == "log" then
    if btn == "a" or btn == "b" or btn == "start" then
      local next = self.afterLog
      if not self:catchUpLog(next) then
        self.afterLog = nil
        if next == "over" then self.mode = "over"
        elseif next == "promote" then self:promptPromotion()
        elseif next == "main" then
          if self.duel.finished then self.mode = "over" else self:resume() end
        else self.mode = next end
      end
    end
  elseif mode == "prompt" then
    local pr = self.prompt
    if btn == "up" then move(self, #pr.options, -1)
    elseif btn == "down" then move(self, #pr.options, 1)
    elseif btn == "a" then
      local opt = pr.options[self.cursor]
      self.prompt = nil
      if opt then pr.onPick(opt.value) end
    elseif btn == "b" and pr.cancel then
      self.prompt = nil
      self:openMain()
    end
  elseif mode == "main" then
    if btn == "up" then move(self, #self.menu, -1)
    elseif btn == "down" then move(self, #self.menu, 1)
    elseif btn == "a" then
      local act = self.menu[self.cursor].action
      if act == "hand" then self:openHand()
      elseif act == "attack" then self:openAttack()
      elseif act == "retreat" then self:openRetreat()
      elseif act == "power" then self:openPower()
      elseif act == "check" then self:openCheck()
      elseif act == "endTurn" then self.duel:endTurn(); self:resume() end
    elseif btn == "start" then
      self.duel:endTurn(); self:resume()
    end
  elseif mode == "hand" then
    if btn == "up" then move(self, #self.menu, -1)
    elseif btn == "down" then move(self, #self.menu, 1)
    elseif btn == "b" then self:openMain()
    elseif btn == "a" then
      local row = self.menu[self.cursor]
      if row and row.card then self:playCard(row.card) end
    end
  elseif mode == "attack" then
    if btn == "up" then move(self, #self.menu, -1)
    elseif btn == "down" then move(self, #self.menu, 1)
    elseif btn == "b" then self:openMain()
    elseif btn == "a" then
      local row = self.menu[self.cursor]
      if row and row.index then
        self.duel:attack(self.human, row.index)
        self:resume()
      else
        self:notice("Cannot use that attack")
      end
    end
  elseif mode == "check" then
    if btn == "b" or btn == "a" then self:openMain() end
  elseif mode == "over" then
    -- the screen decides what to do (return to browser); nothing here
  end
end

-- Snapshot for renderers and tests.
function DuelSession:view()
  local d = self.duel
  local function side(p)
    local pl = d.players[p]
    local function slotView(s)
      if not s then return nil end
      return { name = self:name(s), hp = s.hp, maxHp = self:card(s.card).hp, status = s.status,
        poison = s.poison, energy = #s.energy, card = s.card }
    end
    local bench = {}
    for i, s in ipairs(pl.bench) do bench[i] = slotView(s) end
    return { name = pl.name, active = slotView(pl.active), bench = bench,
      hand = #pl.hand, deck = #pl.deck, prizes = #pl.prizes, discard = #pl.discard }
  end
  return {
    mode = self.mode, cursor = self.cursor, menu = self.menu, prompt = self.prompt,
    pageLines = self.pageLines, turn = d.turn, current = d.current, finished = d.finished,
    me = side(self.human), foe = side(self.ai), human = self.human,
  }
end

return DuelSession
