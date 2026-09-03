-- Two-player duels over the engine's link layer (docs/tcg-phase1.md,
-- Phase 35).
--
-- Both sides build the same Duel from the same seed and the two decks, then
-- exchange actions rather than state: the duel engine is deterministic (one
-- seeded RNG, no wall-clock, no host-only choices), so applying the same
-- action sequence on both sides keeps them identical.  Every applied action
-- carries a running digest of the local duel, and a mismatch stops the duel
-- rather than letting the two sides drift apart silently.
--
-- Transport is anything with :send(message) and :poll() returning a list --
-- the engine's Session, or the loopback used in the tests.

local Duel = require("src.tcg.Duel")

local LinkDuel = {}
LinkDuel.__index = LinkDuel

LinkDuel.PROTOCOL = "tcg-duel-1"

-- A cheap order-sensitive digest of the visible duel state.  Enough to catch
-- divergence; not a security measure.
function LinkDuel.digest(duel)
  local parts = { duel.turn, duel.current }
  for p = 1, 2 do
    local pl = duel.players[p]
    parts[#parts + 1] = #pl.deck
    parts[#parts + 1] = #pl.hand
    parts[#parts + 1] = #pl.discard
    parts[#parts + 1] = #pl.prizes
    for _, slot in ipairs(duel:slots(p)) do
      parts[#parts + 1] = slot.card
      parts[#parts + 1] = slot.hp
      parts[#parts + 1] = #slot.energy
      parts[#parts + 1] = slot.status
      parts[#parts + 1] = slot.poison
    end
  end
  local h = 5381
  for _, part in ipairs(parts) do
    local text = tostring(part)
    for i = 1, #text do
      h = (h * 33 + text:byte(i)) % 4294967296
    end
  end
  return h
end

-- opts: { transport, cards, deck, host = bool, name = string, seed = n }
function LinkDuel.new(opts)
  return setmetatable({
    transport = assert(opts.transport),
    cards = assert(opts.cards),
    deck = assert(opts.deck),
    host = opts.host and true or false,
    name = opts.name or (opts.host and "HOST" or "GUEST"),
    seed = opts.seed,
    prizes = opts.prizes or 6,
    state = "handshake",     -- handshake | ready | playing | over | failed
    duel = nil,
    seat = nil,              -- which player number this side controls
    failure = nil,
    log = {},
  }, LinkDuel)
end

function LinkDuel:say(fmt, ...) self.log[#self.log + 1] = fmt:format(...) end

function LinkDuel:fail(reason)
  self.state = "failed"
  self.failure = reason
  self:say("link duel failed: %s", reason)
end

function LinkDuel:start()
  self.transport:send({
    kind = "hello", protocol = LinkDuel.PROTOCOL, name = self.name,
    deck = self.deck, seed = self.host and (self.seed or os.time()) or nil,
  })
end

function LinkDuel:begin(theirDeck, theirName, seed)
  -- the host is always player 1, so both sides agree on seating
  local decks = self.host and { self.deck, theirDeck } or { theirDeck, self.deck }
  self.seat = self.host and 1 or 2
  self.duel = Duel.new(self.cards, {
    decks = decks, seed = seed, prizes = self.prizes,
    names = self.host and { self.name, theirName } or { theirName, self.name },
  })
  self.duel:start()
  self.state = "ready"
  self:say("linked with %s, seat %d, seed %d", theirName, self.seat, seed)
end

-- Apply an action locally and tell the other side about it.
function LinkDuel:act(kind, args)
  if self.state ~= "playing" then return false, "not playing" end
  if self.duel.current ~= self.seat then return false, "not your turn" end
  local ok, err = self:apply(kind, args)
  if not ok then return false, err end
  self.transport:send({ kind = "action", action = kind, args = args,
    digest = LinkDuel.digest(self.duel) })
  return true
end

local APPLY = {
  playBasic = function(duel, seat, args) return duel:playBasic(seat, args.card) end,
  evolve = function(duel, seat, args) return duel:evolve(seat, args.card, args.location) end,
  attachEnergy = function(duel, seat, args) return duel:attachEnergy(seat, args.card, args.location) end,
  playTrainer = function(duel, seat, args) return duel:playTrainer(seat, args.card, args) end,
  usePower = function(duel, seat, args) return duel:usePower(seat, args.location, args) end,
  retreat = function(duel, seat, args) return duel:retreat(seat, args.location) end,
  attack = function(duel, seat, args) return duel:attack(seat, args.index, args) end,
  promote = function(duel, seat, args) return duel:promote(seat, args.location) end,
  endTurn = function(duel, seat) return duel:endTurn() end,
}

function LinkDuel:apply(kind, args)
  local fn = APPLY[kind]
  if not fn then return false, "unknown action " .. tostring(kind) end
  local seat = self.duel.current
  local ok, err = fn(self.duel, seat, args or {})
  if ok == false then return false, err end
  if self.duel.finished then self.state = "over" end
  return true
end

function LinkDuel:handle(message)
  if type(message) ~= "table" then return end
  if message.kind == "hello" then
    if message.protocol ~= LinkDuel.PROTOCOL then
      return self:fail("protocol mismatch")
    end
    local seed = self.host and (self.seed or message.seed) or message.seed
    if not seed then return self:fail("no seed agreed") end
    self.seed = seed
    self:begin(message.deck, message.name or "RIVAL", seed)
    if self.host then
      -- the guest needs the seed the host settled on
      self.transport:send({ kind = "ready", seed = seed })
    else
      self.transport:send({ kind = "ready", seed = seed })
    end
  elseif message.kind == "ready" then
    if self.state == "ready" then
      self.state = "playing"
      self:say("duel begins")
    end
  elseif message.kind == "action" then
    if self.state ~= "playing" then return self:fail("action before start") end
    if self.duel.current == self.seat then
      return self:fail("action out of turn")
    end
    local ok, err = self:apply(message.action, message.args)
    if not ok then return self:fail("rejected action: " .. tostring(err)) end
    if message.digest and message.digest ~= LinkDuel.digest(self.duel) then
      return self:fail("state diverged")
    end
  elseif message.kind == "quit" then
    self.state = "over"
    self:say("the other player left")
  end
end

function LinkDuel:update()
  if self.state == "failed" then return end
  local messages = self.transport:poll() or {}
  for _, message in ipairs(messages) do
    self:handle(message)
    if self.state == "failed" then return end
  end
  if self.state == "ready" and self.duel and self.duel.phase == "play" then
    self.state = "playing"
  end
end

function LinkDuel:quit()
  self.transport:send({ kind = "quit" })
  self.state = "over"
end

return LinkDuel
