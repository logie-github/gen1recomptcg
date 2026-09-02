-- Game flow outside duels (Phase 7): title -> starter -> home menu ->
-- deck editor / collection / boosters / duel -> rewards.  Pure state driven
-- by Game Boy buttons, like DuelSession; src/tcg/ui/HomeScreen.lua draws
-- it.  Persistence goes through opts.save(text) / opts.load() so the
-- LÖVE app (save_tcg.lua in the save directory) and the tests (a string)
-- share one implementation.
--
-- Simplifications versus the GB game, which has a whole overworld around
-- these screens: opponents are picked from the built-in deck list instead
-- of walking to a club; a win pays two booster packs drawn from the four
-- neutral packs (the clubs hand out specific packs); the deck editor works
-- on one list at a time with per-card add/remove and a card-list filter.

local Duel = require("src.tcg.Duel")
local DuelSession = require("src.tcg.DuelSession")
local Collection = require("src.tcg.Collection")
local Boosters = require("src.tcg.Boosters")
local Rng = require("src.tcg.Rng")

local HomeSession = {}
HomeSession.__index = HomeSession

HomeSession.PRIZES = 4
HomeSession.WIN_PACKS = 2
local NEUTRAL_PACKS = { "BOOSTER_COLOSSEUM_NEUTRAL", "BOOSTER_EVOLUTION_NEUTRAL",
  "BOOSTER_MYSTERY_NEUTRAL", "BOOSTER_LABORATORY_NEUTRAL" }

-- opts: { cards, decks, boosters, load = fn() -> text|nil, save = fn(text), seed = n }
function HomeSession.new(opts)
  local self = setmetatable({
    cards = assert(opts.cards), decksData = assert(opts.decks), boostersData = assert(opts.boosters),
    loadFn = opts.load or function() return nil end,
    saveFn = opts.save or function() end,
    rng = Rng.new(opts.seed or os.time()),
    mode = "title",       -- title | starter | home | collection | editor | editorPick | packs | opponent | duel | reward | message
    cursor = 1,
    menu = {},
    collection = nil,
    unopened = {},        -- pack constants waiting to be opened
    lastPack = nil,       -- cards from the last opened pack (for display)
    duelSession = nil,
    message = nil,
    editor = nil,         -- { slot, name, cards = {ids}, filter }
  }, HomeSession)
  self:openTitle()
  return self
end

-- ---------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------

function HomeSession:persist()
  if self.collection then self.saveFn(self.collection:serialize()) end
end

function HomeSession:tryLoad()
  local text = self.loadFn()
  if type(text) ~= "string" then return nil end
  return Collection.deserialize(self.cards, text)
end

-- ---------------------------------------------------------------------
-- menus
-- ---------------------------------------------------------------------

local function move(self, n, delta)
  if n == 0 then return end
  self.cursor = ((self.cursor - 1 + delta) % n) + 1
end

function HomeSession:setMenu(mode, rows)
  self.mode = mode
  self.menu = rows
  self.cursor = 1
end

function HomeSession:openTitle()
  local rows = {}
  if self:tryLoad() then rows[#rows + 1] = { label = "CONTINUE", action = "continue" } end
  rows[#rows + 1] = { label = "NEW GAME", action = "new" }
  self:setMenu("title", rows)
end

function HomeSession:openStarter()
  self:setMenu("starter", {
    { label = "Charmander & Friends (Fire)", starter = "charmander" },
    { label = "Squirtle & Friends (Water)", starter = "squirtle" },
    { label = "Bulbasaur & Friends (Grass)", starter = "bulbasaur" },
  })
end

function HomeSession:openHome()
  local col = self.collection
  local rows = {
    { label = "DUEL", action = "duel" },
    { label = ("DECKS (%d)"):format(self:deckCount()), action = "decks" },
    { label = ("COLLECTION %d/%d"):format(col:distinctOwned(), self.cards.count), action = "collection" },
    { label = ("PACKS (%d unopened)"):format(#self.unopened), action = "packs" },
    { label = "SAVE", action = "save" },
    { label = "QUIT", action = "quit" },
  }
  self:setMenu("home", rows)
end

function HomeSession:deckCount()
  local n = 0
  for i = 1, Collection.DECK_SLOTS do if self.collection.decks[i] then n = n + 1 end end
  return n
end

function HomeSession:openDecks()
  local rows = {}
  for i = 1, Collection.DECK_SLOTS do
    local d = self.collection.decks[i]
    rows[#rows + 1] = { label = ("%d: %s"):format(i, d and d.name or "(empty)"), slot = i }
  end
  self:setMenu("decks", rows)
end

function HomeSession:openCollection()
  local rows = {}
  for id = 1, self.cards.count do
    local n = self.collection:count(id)
    if n > 0 then
      rows[#rows + 1] = { label = ("%2dx %s"):format(n, self.cards.byId[id].name), card = id }
    end
  end
  if #rows == 0 then rows[1] = { label = "(nothing yet)" } end
  self:setMenu("collection", rows)
end

function HomeSession:openPacks()
  if #self.unopened == 0 then return self:say("No packs to open.", "home") end
  local rows = {}
  for i, constant in ipairs(self.unopened) do
    rows[#rows + 1] = { label = constant:gsub("^BOOSTER_", ""):gsub("_", " "), index = i }
  end
  self:setMenu("packs", rows)
end

function HomeSession:openOpponents()
  local rows = {}
  local keys = {}
  for k in pairs(self.decksData) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local d = self.decksData[k]
    if d.total == 60 and d.name and not d.label:match("^Unnamed") then
      rows[#rows + 1] = { label = d.name, deckKey = k }
    end
  end
  self:setMenu("opponent", rows)
end

function HomeSession:say(text, nextMode)
  self.message = { text = text, next = nextMode or "home" }
  self.mode = "message"
end

-- ---------------------------------------------------------------------
-- packs
-- ---------------------------------------------------------------------

function HomeSession:packByConstant(constant)
  for _, p in pairs(self.boostersData.packs) do if p.constant == constant then return p end end
end

function HomeSession:openPack(index)
  local constant = table.remove(self.unopened, index)
  if not constant then return end
  local drawn = Boosters.generate(self:packByConstant(constant), self.boostersData, self.cards, self.rng)
  self.collection:addAll(drawn)
  self.collection.stats.boosters = self.collection.stats.boosters + 1
  self.lastPack = drawn
  self:persist()
  local rows = {}
  for _, id in ipairs(drawn) do
    local c = self.cards.byId[id]
    rows[#rows + 1] = { label = ("%s [%s]"):format(c.name, c.rarity:sub(1, 1)), card = id }
  end
  self:setMenu("packResult", rows)
end

-- ---------------------------------------------------------------------
-- deck editor
-- ---------------------------------------------------------------------

function HomeSession:openEditor(slot)
  local d = self.collection.decks[slot]
  local cardsCopy = {}
  if d then for i, id in ipairs(d.cards) do cardsCopy[i] = id end end
  self.editor = { slot = slot, name = d and d.name or ("Deck " .. slot), cards = cardsCopy, filter = "all" }
  self:refreshEditor()
end

local function countIn(list, id)
  local n = 0
  for _, x in ipairs(list) do if x == id then n = n + 1 end end
  return n
end

function HomeSession:refreshEditor()
  local ed = self.editor
  local ok, errors = self.collection:validateDeck(ed.cards)
  local rows = {
    { label = ("%s  %d/60%s"):format(ed.name, #ed.cards, ok and " OK" or ""), action = "info" },
    { label = "ADD CARDS", action = "add" },
    { label = "SAVE DECK", action = "save", enabled = ok },
    { label = "CLEAR", action = "clear" },
    { label = "BACK", action = "back" },
  }
  -- current contents grouped
  local seen, groups = {}, {}
  for _, id in ipairs(ed.cards) do
    if not seen[id] then seen[id] = true; groups[#groups + 1] = id end
  end
  table.sort(groups)
  for _, id in ipairs(groups) do
    rows[#rows + 1] = { label = ("  %dx %s"):format(countIn(ed.cards, id), self.cards.byId[id].name), remove = id }
  end
  ed.errors = errors
  self:setMenu("editor", rows)
end

function HomeSession:openEditorPick()
  local ed = self.editor
  local rows = {}
  for id = 1, self.cards.count do
    local owned = self.collection:count(id)
    if owned > 0 then
      local c = self.cards.byId[id]
      local keep = ed.filter == "all"
        or (ed.filter == "pokemon" and c.kind == "pokemon")
        or (ed.filter == "trainer" and c.kind == "trainer")
        or (ed.filter == "energy" and c.kind == "energy")
      if keep then
        rows[#rows + 1] = { label = ("%s %d/%d"):format(c.name, countIn(ed.cards, id), owned), card = id }
      end
    end
  end
  if #rows == 0 then rows[1] = { label = "(no cards)" } end
  self:setMenu("editorPick", rows)
end

function HomeSession:cycleFilter()
  local order = { "all", "pokemon", "trainer", "energy" }
  for i, f in ipairs(order) do
    if self.editor.filter == f then self.editor.filter = order[i % #order + 1]; break end
  end
  local cursor = self.cursor
  self:openEditorPick()
  self.cursor = math.min(cursor, #self.menu)
end

-- ---------------------------------------------------------------------
-- duels
-- ---------------------------------------------------------------------

function HomeSession:startDuel(opponentKey)
  local mine = self.collection.decks[self.activeDeck or 1]
  if not mine then return self:say("Build a deck first.", "home") end
  local opp = self.decksData[opponentKey]
  local theirs = Collection.builtinDeck(self.decksData, opp.constant)
  local duel = Duel.new(self.cards, {
    decks = { mine.cards, theirs }, prizes = HomeSession.PRIZES,
    seed = self.rng:next(), names = { "YOU", (opp.name or opp.label):sub(1, 10):upper() },
  })
  self.duelSession = DuelSession.new({ duel = duel, human = 1 })
  self.duelSession:start()
  self.mode = "duel"
end

function HomeSession:finishDuel()
  local d = self.duelSession.duel
  local st = self.collection.stats
  st.duels = st.duels + 1
  local text
  if d.finished.winner == 1 then
    st.wins = st.wins + 1
    for _ = 1, HomeSession.WIN_PACKS do
      self.unopened[#self.unopened + 1] = NEUTRAL_PACKS[self.rng:int(1, #NEUTRAL_PACKS)]
    end
    text = ("You won! %d booster packs added."):format(HomeSession.WIN_PACKS)
  elseif d.finished.winner == 0 then
    text = "The duel was a draw."
  else
    st.losses = st.losses + 1
    text = "You lost."
  end
  self.duelSession = nil
  self:persist()
  self:say(text, "home")
end

-- ---------------------------------------------------------------------
-- input
-- ---------------------------------------------------------------------

function HomeSession:press(btn)
  local mode = self.mode
  if mode == "duel" then
    local s = self.duelSession
    if s.mode == "over" then
      if btn == "a" or btn == "b" or btn == "start" then self:finishDuel() end
    else s:press(btn) end
    return
  end
  if mode == "message" then
    if btn == "a" or btn == "b" or btn == "start" then
      local nextMode = self.message.next
      self.message = nil
      if nextMode == "home" then self:openHome() else self.mode = nextMode end
    end
    return
  end
  local rows = self.menu
  if mode ~= "editorPick" then self.notice = nil end
  if btn == "up" then return move(self, #rows, -1) end
  if btn == "down" then return move(self, #rows, 1) end
  if btn == "left" then return move(self, #rows, -8) end
  if btn == "right" then return move(self, #rows, 8) end
  local row = rows[self.cursor]

  if mode == "title" then
    if btn == "a" and row then
      if row.action == "continue" then
        self.collection = self:tryLoad()
        self:openHome()
      else self:openStarter() end
    end
  elseif mode == "starter" then
    if btn == "a" and row then
      self.collection = Collection.new(self.cards)
      self.collection:giveStarter(row.starter, self.decksData)
      self.activeDeck = 1
      self:persist()
      self:say("You received the " .. Collection.STARTERS[row.starter].label .. " deck!", "home")
    elseif btn == "b" then self:openTitle() end
  elseif mode == "home" then
    if btn == "a" and row then
      local a = row.action
      if a == "duel" then self:openOpponents()
      elseif a == "decks" then self:openDecks()
      elseif a == "collection" then self:openCollection()
      elseif a == "packs" then self:openPacks()
      elseif a == "save" then self:persist(); self:say("Saved.", "home")
      elseif a == "quit" then self.mode = "quit" end
    end
  elseif mode == "decks" then
    if btn == "a" and row then self:openEditor(row.slot)
    elseif btn == "select" and row and self.collection.decks[row.slot] then
      self.activeDeck = row.slot
      self:say(("Deck %d is now your duel deck."):format(row.slot), "home")
    elseif btn == "b" then self:openHome() end
  elseif mode == "collection" then
    if btn == "b" then self:openHome() end
  elseif mode == "packs" then
    if btn == "a" and row and row.index then self:openPack(row.index)
    elseif btn == "b" then self:openHome() end
  elseif mode == "packResult" then
    if btn == "a" or btn == "b" then
      if #self.unopened > 0 then self:openPacks() else self:openHome() end
    end
  elseif mode == "opponent" then
    if btn == "a" and row then self:startDuel(row.deckKey)
    elseif btn == "b" then self:openHome() end
  elseif mode == "editor" then
    if btn == "a" and row then
      if row.remove then
        for i, id in ipairs(self.editor.cards) do
          if id == row.remove then table.remove(self.editor.cards, i); break end
        end
        local c = self.cursor
        self:refreshEditor()
        self.cursor = math.min(c, #self.menu)
      elseif row.action == "add" then self:openEditorPick()
      elseif row.action == "save" then
        local ok, errors = self.collection:saveDeck(self.editor.slot, self.editor.name, self.editor.cards)
        if ok then
          self.activeDeck = self.activeDeck or self.editor.slot
          self:persist()
          self:say("Deck saved.", "decksReturn")
        else
          self:say(errors[1] or "Deck is not legal.", "editorReturn")
        end
      elseif row.action == "clear" then
        self.editor.cards = {}
        self:refreshEditor()
      elseif row.action == "back" then self:openDecks() end
    elseif btn == "b" then self:openDecks() end
  elseif mode == "editorPick" then
    if btn == "a" and row and row.card then
      local ok, why = self.collection:canAddToDeck(self.editor.cards, row.card)
      local c = self.cursor
      if ok then
        self.editor.cards[#self.editor.cards + 1] = row.card
        self.notice = nil
      else
        self.notice = why       -- shown inline by the renderer; cursor stays put
      end
      self:openEditorPick()
      self.cursor = c
    elseif btn == "select" then self:cycleFilter()
    elseif btn == "b" then self:refreshEditor() end
  elseif mode == "decksReturn" then
    self:openDecks()
  elseif mode == "editorReturn" then
    self:refreshEditor()
  end
end

-- message "next" modes that are really callbacks
local RETURN_MODES = { decksReturn = "openDecks", editorReturn = "refreshEditor" }
local rawPress = HomeSession.press
function HomeSession:press(btn)
  rawPress(self, btn)
  local fn = RETURN_MODES[self.mode]
  if fn then self[fn](self) end
end

return HomeSession
