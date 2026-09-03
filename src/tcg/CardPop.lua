-- Card Pop! (docs/tcg-phase1.md, Phase 35).
--
-- Two players touch consoles and each receives a card chosen from both of
-- their identities, so the same pairing gives the same card to both sides.
-- The port keeps that property: each side sends a small fingerprint (name,
-- starter, a per-save salt and a nonce), and both derive the same card id
-- from the combined pair, so neither side can pick unilaterally.
--
-- The original limits how often a given pairing pays out; that bookkeeping
-- lives in the save here as a record of pairings already popped.

local CardPop = {}
CardPop.__index = CardPop

CardPop.PROTOCOL = "tcg-cardpop-1"

local function hashString(text, seed)
  local h = seed or 5381
  for i = 1, #text do
    h = (h * 33 + text:byte(i)) % 4294967296
  end
  return h
end

-- The pair's shared value: order-independent, so both sides agree.
function CardPop.pairKey(a, b)
  local first, second = a, b
  if first > second then first, second = second, first end
  return first .. "/" .. second
end

-- Identity only.  An earlier version mixed in the collection size, which
-- changes the moment a pop lands, so the same pair produced a different key
-- on a second attempt and the once-per-pairing rule never fired.
function CardPop.fingerprint(collection, name)
  return table.concat({ name or "PLAYER",
    collection and collection.starter or "none" }, ":")
end

-- opts: { transport, cards, collection, name, salt, eligible = { ids } }
function CardPop.new(opts)
  local self = setmetatable({
    transport = assert(opts.transport),
    cards = assert(opts.cards),
    collection = opts.collection,
    name = opts.name or "PLAYER",
    salt = opts.salt or tostring(os.time()),
    state = "waiting",     -- waiting | done | failed | duplicate
    received = nil,
    failure = nil,
    log = {},
  }, CardPop)
  self.eligible = opts.eligible or CardPop.defaultEligible(opts.cards)
  return self
end

-- Card Pop! hands out ordinary cards; the port offers every non-energy card
-- the set has unless the caller narrows it.
function CardPop.defaultEligible(cards)
  local out = {}
  for id = 1, cards.count do
    local card = cards.byId[id]
    if card and card.kind ~= "energy" and not card.pseudoPokemon then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

function CardPop:say(fmt, ...) self.log[#self.log + 1] = fmt:format(...) end

function CardPop:start()
  self.transport:send({
    kind = "pop", protocol = CardPop.PROTOCOL,
    fingerprint = CardPop.fingerprint(self.collection, self.name),
    salt = self.salt,
  })
end

-- Both sides run this on the same pair and get the same answer.
function CardPop:chooseCard(mine, theirs)
  local key = CardPop.pairKey(mine, theirs)
  local index = hashString(key) % #self.eligible + 1
  return self.eligible[index]
end

function CardPop:handle(message)
  if type(message) ~= "table" or message.kind ~= "pop" then return end
  if message.protocol ~= CardPop.PROTOCOL then
    self.state = "failed"
    self.failure = "protocol mismatch"
    return
  end
  local mine = CardPop.fingerprint(self.collection, self.name) .. "#" .. self.salt
  local theirs = tostring(message.fingerprint) .. "#" .. tostring(message.salt)
  local key = CardPop.pairKey(mine, theirs)

  if self.collection then
    self.collection.cardPops = self.collection.cardPops or {}
    if self.collection.cardPops[key] then
      -- the same pairing does not pay out twice
      self.state = "duplicate"
      self:say("this pairing has already been popped")
      return
    end
    self.collection.cardPops[key] = true
  end

  local card = self:chooseCard(mine, theirs)
  self.received = card
  if self.collection and card then self.collection:add(card, 1) end
  self.state = "done"
  self:say("received %s", card and self.cards.byId[card].name or "nothing")
end

function CardPop:update()
  if self.state ~= "waiting" then return end
  for _, message in ipairs(self.transport:poll() or {}) do
    self:handle(message)
    if self.state ~= "waiting" then return end
  end
end

return CardPop
