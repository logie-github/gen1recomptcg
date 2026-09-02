-- Card collection, deck configurations and the save file (Phase 7).
--
-- poketcg keeps sCardCollection (one count byte per card id, CARD_COUNT_MASK
-- $7f, bit 7 = never owned) and four deck slots (DECK_NAME_SIZE + DECK_SIZE
-- bytes each).  This is the same model as a Lua table:
--   { collection = { [id] = count }, decks = { [1..4] = { name, cards = {ids} } | false },
--     starter = "charmander"|..., stats = { wins, losses, boosters }, seed = n }
--
-- Deck rules (engine/menus/deck_configuration.asm): exactly 60 cards, at
-- most MAX_NUM_SAME_NAME_CARDS (4) cards sharing a name, basic Energy
-- exempt (Double Colorless is not), at least one Basic Pokemon (the duel
-- would mulligan forever otherwise), and every card must be owned with the
-- copies in other decks not double-counted -- poketcg lets a card be in
-- several decks at once, so ownership is checked per deck, and the
-- collection screen shows cards "in use" separately.

local LuaWriter = require("src.import.LuaWriter")

local Collection = {}
Collection.__index = Collection

Collection.DECK_SIZE = 60
Collection.MAX_SAME_NAME = 4
Collection.DECK_SLOTS = 4
Collection.MAX_COUNT = 99

-- starter decks: main deck id + extra cards deck id (starter_deck.asm)
Collection.STARTERS = {
  charmander = { main = "CHARMANDER_AND_FRIENDS_DECK", extra = "CHARMANDER_EXTRA_DECK", label = "Charmander & Friends" },
  squirtle = { main = "SQUIRTLE_AND_FRIENDS_DECK", extra = "SQUIRTLE_EXTRA_DECK", label = "Squirtle & Friends" },
  bulbasaur = { main = "BULBASAUR_AND_FRIENDS_DECK", extra = "BULBASAUR_EXTRA_DECK", label = "Bulbasaur & Friends" },
}

function Collection.new(cards)
  return setmetatable({
    cards = cards,
    collection = {},
    decks = { false, false, false, false },
    stats = { wins = 0, losses = 0, boosters = 0, duels = 0 },
    starter = nil,
  }, Collection)
end

-- ---------------------------------------------------------------------
-- collection
-- ---------------------------------------------------------------------

function Collection:count(id) return self.collection[id] or 0 end

function Collection:add(id, n)
  self.collection[id] = math.min(Collection.MAX_COUNT, self:count(id) + (n or 1))
end

function Collection:addAll(ids)
  for _, id in ipairs(ids) do self:add(id, 1) end
end

function Collection:totalOwned()
  local n = 0
  for _, c in pairs(self.collection) do n = n + c end
  return n
end

function Collection:distinctOwned()
  local n = 0
  for _, c in pairs(self.collection) do if c > 0 then n = n + 1 end end
  return n
end

-- ---------------------------------------------------------------------
-- decks
-- ---------------------------------------------------------------------

local function deckFromData(deckEntry)
  local out = {}
  for _, e in ipairs(deckEntry.cards) do for _ = 1, e.count do out[#out + 1] = e.card end end
  return out
end

-- decksData: data/generated/decks.lua; returns the card list for a *_DECK constant
function Collection.builtinDeck(decksData, constant)
  for _, d in pairs(decksData) do
    if d.constant == constant then return deckFromData(d), d end
  end
  return nil
end

function Collection:giveStarter(which, decksData)
  local st = assert(Collection.STARTERS[which], "unknown starter " .. tostring(which))
  local main, entry = Collection.builtinDeck(decksData, st.main)
  local extra = Collection.builtinDeck(decksData, st.extra)
  assert(main and extra, "starter decks missing from decks.lua")
  self:addAll(main)
  self:addAll(extra)
  self.decks[1] = { name = st.label, cards = main }
  self.starter = which
  return main
end

-- Validation of a deck list against the rules and this collection.
-- Returns ok, { errors... }
function Collection:validateDeck(ids)
  local errors = {}
  if #ids ~= Collection.DECK_SIZE then
    errors[#errors + 1] = ("%d cards; a deck needs %d"):format(#ids, Collection.DECK_SIZE)
  end
  local byName, byId, basic = {}, {}, false
  for _, id in ipairs(ids) do
    local c = self.cards.byId[id]
    byId[id] = (byId[id] or 0) + 1
    if c.kind == "pokemon" and c.stage == "BASIC" then basic = true end
    local exempt = c.kind == "energy" and c.type ~= "TYPE_ENERGY_DOUBLE_COLORLESS"
    if not exempt then byName[c.name] = (byName[c.name] or 0) + 1 end
  end
  for name, n in pairs(byName) do
    if n > Collection.MAX_SAME_NAME then
      errors[#errors + 1] = ("%d x %s; at most %d with the same name"):format(n, name, Collection.MAX_SAME_NAME)
    end
  end
  for id, n in pairs(byId) do
    if n > self:count(id) then
      errors[#errors + 1] = ("%s: %d in deck, %d owned"):format(self.cards.byId[id].name, n, self:count(id))
    end
  end
  if not basic then errors[#errors + 1] = "no Basic Pokemon" end
  table.sort(errors)
  return #errors == 0, errors
end

-- Can one more copy of `id` be added to the working list?  Mirrors the
-- deck configuration screen's TryAddCardToDeck checks.
function Collection:canAddToDeck(ids, id)
  if #ids >= Collection.DECK_SIZE then return false, "deck is full" end
  local c = self.cards.byId[id]
  local inDeck = 0
  for _, x in ipairs(ids) do if x == id then inDeck = inDeck + 1 end end
  if inDeck >= self:count(id) then return false, "no more copies owned" end
  local exempt = c.kind == "energy" and c.type ~= "TYPE_ENERGY_DOUBLE_COLORLESS"
  if not exempt then
    local sameName = 0
    for _, x in ipairs(ids) do if self.cards.byId[x].name == c.name then sameName = sameName + 1 end end
    if sameName >= Collection.MAX_SAME_NAME then
      return false, ("only %d %s allowed"):format(Collection.MAX_SAME_NAME, c.name)
    end
  end
  return true
end

function Collection:saveDeck(slot, name, ids)
  assert(slot >= 1 and slot <= Collection.DECK_SLOTS, "bad deck slot")
  local ok, errors = self:validateDeck(ids)
  if not ok then return false, errors end
  local copy = {}
  for i, id in ipairs(ids) do copy[i] = id end
  self.decks[slot] = { name = name, cards = copy }
  return true
end

function Collection:deleteDeck(slot)
  self.decks[slot] = false
end

-- ---------------------------------------------------------------------
-- serialization (plain Lua table text; the caller owns the file)
-- ---------------------------------------------------------------------

Collection.SAVE_VERSION = 1

function Collection:serialize()
  local decks = {}
  for i = 1, Collection.DECK_SLOTS do
    local d = self.decks[i]
    decks[i] = d and { name = d.name, cards = d.cards } or false
  end
  return LuaWriter.encode({
    version = Collection.SAVE_VERSION,
    starter = self.starter,
    collection = self.collection,
    decks = decks,
    stats = self.stats,
  })
end

function Collection.deserialize(cards, text)
  local loader = loadstring or load
  local chunk, err = loader(text, "=tcg_save")
  if not chunk then return nil, err end
  local ok, data = pcall(chunk)
  if not ok or type(data) ~= "table" then return nil, "corrupt save" end
  local self = Collection.new(cards)
  self.starter = data.starter
  for k, v in pairs(data.collection or {}) do
    local id = tonumber(k)
    if id and cards.byId[id] and type(v) == "number" then self.collection[id] = v end
  end
  for i = 1, Collection.DECK_SLOTS do
    local d = data.decks and data.decks[i]
    if type(d) == "table" and type(d.cards) == "table" then
      self.decks[i] = { name = tostring(d.name or ("Deck " .. i)), cards = d.cards }
    end
  end
  for k, v in pairs(data.stats or {}) do if type(v) == "number" then self.stats[k] = v end end
  return self
end

return Collection
