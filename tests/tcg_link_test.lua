-- Link duels and Card Pop! over a loopback transport.
package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/cards.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local decks = dofile(cacheDir .. "/data/generated/decks.lua")
local LinkDuel = require("src.tcg.LinkDuel")
local CardPop = require("src.tcg.CardPop")
local Collection = require("src.tcg.Collection")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. msg) end
end

-- a pair of transports that hand messages to each other
local function loopback()
  local a, b = { out = {} }, { out = {} }
  a.send = function(self, m) b.out[#b.out + 1] = m end
  b.send = function(self, m) a.out[#a.out + 1] = m end
  local function poll(self)
    local got = self.out
    self.out = {}
    return got
  end
  a.poll, b.poll = poll, poll
  return a, b
end

local function expand(deck)
  local out = {}
  for _, e in ipairs(deck.cards) do for _ = 1, e.count do out[#out + 1] = e.card end end
  return out
end

-- 1. a linked duel: both sides build the same duel and stay in step
do
  local ta, tb = loopback()
  local host = LinkDuel.new({ transport = ta, cards = cards, deck = expand(decks[3]),
    host = true, name = "HOST", seed = 4242, prizes = 4 })
  local guest = LinkDuel.new({ transport = tb, cards = cards, deck = expand(decks[2]),
    host = false, name = "GUEST", prizes = 4 })
  host:start(); guest:start()
  for _ = 1, 4 do host:update(); guest:update() end

  check(host.duel ~= nil and guest.duel ~= nil, "both sides built a duel")
  check(host.seat == 1 and guest.seat == 2, "seats agree")
  check(host.state == "playing" and guest.state == "playing",
    ("both are playing (%s / %s)"):format(host.state, guest.state))
  check(LinkDuel.digest(host.duel) == LinkDuel.digest(guest.duel),
    "the two duels start identical")

  -- set up both sides the way a duel starts, then play actions across the link
  for _, side in ipairs({ host, guest }) do
    for p = 1, 2 do
      local pl = side.duel.players[p]
      if not pl.active then
        for _, id in ipairs(pl.hand) do
          local c = side.duel:card(id)
          if c.kind == "pokemon" and c.stage == "BASIC" then
            side.duel:placeActive(p, id); break
          end
        end
      end
    end
    side.duel:finishSetup()
  end
  check(LinkDuel.digest(host.duel) == LinkDuel.digest(guest.duel),
    "still identical after setup")

  -- the side whose turn it is acts; the other applies it from the message
  local acted = 0
  for _ = 1, 8 do
    local mover = (host.duel.current == host.seat) and host or guest
    local other = (mover == host) and guest or host
    local ok = mover:act("endTurn", {})
    if ok then acted = acted + 1 end
    other:update(); mover:update()
    check(host.state ~= "failed" and guest.state ~= "failed",
      "no divergence after an action")
    check(LinkDuel.digest(host.duel) == LinkDuel.digest(guest.duel),
      "the duels match after each action")
  end
  check(acted >= 6, acted .. " actions crossed the link")

  -- acting out of turn is refused locally
  local waiting = (host.duel.current == host.seat) and guest or host
  local ok, err = waiting:act("endTurn", {})
  check(not ok and err ~= nil, "acting out of turn is refused")
end

-- 2. divergence is caught rather than ignored
do
  local ta, tb = loopback()
  local host = LinkDuel.new({ transport = ta, cards = cards, deck = expand(decks[3]),
    host = true, seed = 7, prizes = 4 })
  local guest = LinkDuel.new({ transport = tb, cards = cards, deck = expand(decks[2]),
    host = false, prizes = 4 })
  host:start(); guest:start()
  for _ = 1, 4 do host:update(); guest:update() end
  -- forge an action carrying a digest that cannot match, on the side that is
  -- waiting (an out-of-turn action is refused before the digest is checked)
  local waiting = (host.duel.current == host.seat) and guest or host
  waiting:handle({ kind = "action", action = "endTurn", args = {}, digest = 1 })
  check(waiting.state == "failed" and waiting.failure == "state diverged",
    "a mismatched digest stops the duel (" .. tostring(waiting.failure) .. ")")
end

-- 3. a protocol mismatch fails cleanly
do
  local ta = { send = function() end, poll = function() return {} end }
  local side = LinkDuel.new({ transport = ta, cards = cards, deck = expand(decks[3]) })
  side:handle({ kind = "hello", protocol = "something-else" })
  check(side.state == "failed", "a foreign protocol is refused")
end

-- 4. Card Pop!: both sides derive the same card, once per pairing
do
  local ta, tb = loopback()
  local one = Collection.new(cards); one:giveStarter("charmander", decks)
  local two = Collection.new(cards); two:giveStarter("squirtle", decks)
  local a = CardPop.new({ transport = ta, cards = cards, collection = one,
    name = "ONE", salt = "aaa" })
  local b = CardPop.new({ transport = tb, cards = cards, collection = two,
    name = "TWO", salt = "bbb" })
  a:start(); b:start()
  a:update(); b:update()
  check(a.state == "done" and b.state == "done",
    ("both sides popped (%s / %s)"):format(a.state, b.state))
  check(a.received ~= nil and a.received == b.received,
    "both received the same card")
  check(one:count(a.received) > 0 and two:count(b.received) > 0,
    "the card reached both collections")

  -- the same pairing does not pay out twice
  local ta2, tb2 = loopback()
  local a2 = CardPop.new({ transport = ta2, cards = cards, collection = one,
    name = "ONE", salt = "aaa" })
  local b2 = CardPop.new({ transport = tb2, cards = cards, collection = two,
    name = "TWO", salt = "bbb" })
  a2:start(); b2:start()
  a2:update(); b2:update()
  check(a2.state == "duplicate" and b2.state == "duplicate",
    "a repeated pairing is refused")

  -- and the record survives the save
  local back = Collection.deserialize(cards, one:serialize())
  local pops = 0
  for _ in pairs(back.cardPops or {}) do pops = pops + 1 end
  check(pops > 0, "popped pairings persist")

  -- a different partner pays out again
  local ta3, tb3 = loopback()
  local three = Collection.new(cards); three:giveStarter("bulbasaur", decks)
  local a3 = CardPop.new({ transport = ta3, cards = cards, collection = one,
    name = "ONE", salt = "aaa" })
  local b3 = CardPop.new({ transport = tb3, cards = cards, collection = three,
    name = "THREE", salt = "ccc" })
  a3:start(); b3:start()
  a3:update(); b3:update()
  check(a3.state == "done" and a3.received == b3.received, "a new partner pays out")
end

print(("tcg link tests: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
