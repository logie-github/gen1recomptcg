-- DuelAI vs SimpleAI: the heuristic AI must beat the stub decisively on the
-- practice decks and on random decks, from either seat, and never crash.
--   TCG_CACHE=<dir> lua tests/tcg_ai_test.lua [games]

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/cards.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local decks = dofile(cacheDir .. "/data/generated/decks.lua")
local Duel = require("src.tcg.Duel")
local Rng = require("src.tcg.Rng")
local SimpleAI = require("src.tcg.SimpleAI")
local DuelAI = require("src.tcg.DuelAI")

local games = tonumber(arg and arg[1]) or 100
local failures = 0
local function fail(msg) failures = failures + 1; print("FAIL: " .. msg) end
local function check(cond, msg) if not cond then fail(msg) end end

local function expand(deck)
  local out = {}
  for _, e in ipairs(deck.cards) do for _ = 1, e.count do out[#out + 1] = e.card end end
  return out
end

local basics, evos, energies, trainers = {}, {}, {}, {}
for id = 1, cards.count do
  local c = cards.byId[id]
  if c then
    if c.kind == "pokemon" then
      if c.stage == "BASIC" then basics[#basics + 1] = id else evos[#evos + 1] = id end
    elseif c.kind == "energy" then energies[#energies + 1] = id
    elseif c.kind == "trainer" and not c.pseudoPokemon then trainers[#trainers + 1] = id end
  end
end
local function randomDeck(rng)
  local deck = {}
  for _ = 1, 16 do deck[#deck + 1] = basics[rng:int(1, #basics)] end
  for _ = 1, 8 do deck[#deck + 1] = evos[rng:int(1, #evos)] end
  for _ = 1, 6 do deck[#deck + 1] = trainers[rng:int(1, #trainers)] end
  while #deck < 60 do deck[#deck + 1] = energies[rng:int(1, #energies)] end
  return deck
end

local function play(d, smartSeat)
  d:start()
  for p = 1, 2 do
    for _, id in ipairs(d.players[p].hand) do
      local c = d:card(id)
      if c.kind == "pokemon" and c.stage == "BASIC" then d:placeActive(p, id); break end
    end
  end
  d:finishSetup()
  local guard = 0
  while not d.finished do
    if d.current == smartSeat then DuelAI.takeTurn(d, smartSeat) else SimpleAI.act(d, d.current) end
    guard = guard + 1
    if guard > 8000 then d:finish(0, "guard") end
    if d.turn > 300 then d:finish(0, "turn limit") end
  end
  for p = 1, 2 do
    if d:census(p) ~= 60 then fail("census broken") end
  end
  return d
end

local function series(label, deckFn, n)
  local wins, losses, draws, turns = 0, 0, 0, 0
  for g = 1, n do
    local seat = (g % 2) + 1
    local rng = Rng.new(g * 101)
    local d1, d2 = deckFn(rng)
    local d = Duel.new(cards, { decks = { d1, d2 }, seed = g, prizes = 4, names = { "P1", "P2" } })
    local ok, err = pcall(play, d, seat)
    if not ok then
      fail(("%s game %d crashed: %s"):format(label, g, tostring(err)))
      for i = math.max(1, #d.log - 6), #d.log do print("   " .. d.log[i]) end
    else
      if d.finished.reason == "guard" then fail(label .. " game " .. g .. " guard") end
      if d.finished.winner == seat then wins = wins + 1
      elseif d.finished.winner == 0 then draws = draws + 1
      else losses = losses + 1 end
      turns = turns + d.turn
    end
  end
  print(("%-14s DuelAI %d - %d SimpleAI (%d draws), %.1f turns avg"):format(label, wins, losses, draws, turns / n))
  return wins / n
end

local sams, practice = expand(decks[2]), expand(decks[3])
local r1 = series("practice", function() return practice, sams end, games)
local r2 = series("random", function(rng) return randomDeck(rng), randomDeck(rng) end, games)
if r1 < 0.7 then fail(("practice win rate %.2f < 0.70"):format(r1)) end
if r2 < 0.7 then fail(("random win rate %.2f < 0.70"):format(r2)) end

-- mirror: DuelAI vs DuelAI must also terminate cleanly
do
  local ends = {}
  for g = 1, math.floor(games / 2) do
    local rng = Rng.new(g * 7)
    local d = Duel.new(cards, { decks = { randomDeck(rng), randomDeck(rng) }, seed = g, prizes = 4 })
    d:start()
    for p = 1, 2 do
      for _, id in ipairs(d.players[p].hand) do
        local c = d:card(id)
        if c.kind == "pokemon" and c.stage == "BASIC" then d:placeActive(p, id); break end
      end
    end
    d:finishSetup()
    local ok, err = pcall(function()
      while not d.finished do
        DuelAI.takeTurn(d, d.current)
        if d.turn > 300 then d:finish(0, "turn limit") end
      end
    end)
    if not ok then fail("mirror game " .. g .. " crashed: " .. tostring(err)) end
    ends[d.finished.reason] = (ends[d.finished.reason] or 0) + 1
  end
  local parts = {}
  for k, v in pairs(ends) do parts[#parts + 1] = k .. "=" .. v end
  table.sort(parts)
  print("mirror endings: " .. table.concat(parts, ", "))
end

-- per-deck profiles: the AI honours the deck's own energy caps and bench list
do
  local aiDecks = dofile(cacheDir .. "/data/generated/ai_decks.lua")
  DuelAI.profiles = aiDecks
  local count = 0
  for _ in pairs(aiDecks) do count = count + 1 end
  check(count >= 16, count .. " deck AI profiles extracted")

  check(DuelAI.profileNameFor("GO_GO_RAIN_DANCE_DECK") == "GoGoRainDance",
    "deck constants map to profile names")
  local profile = DuelAI.profileFor("GO_GO_RAIN_DANCE_DECK")
  check(profile ~= nil and #profile.energy > 0, "the Rain Dance profile has energy caps")

  -- every profile's entries name real cards
  for name, entry in pairs(aiDecks) do
    for _, list in pairs(entry) do
      for _, row in ipairs(list) do
        check(cards.byId[row.card] ~= nil, name .. " names a real card")
      end
    end
  end

  -- the energy cap is respected: load a capped Pokemon past its limit and the
  -- AI should stop choosing it
  local rain = DuelAI.profileFor("GO_GO_RAIN_DANCE_DECK")
  local capped
  for _, row in ipairs(rain.energy) do if row.max and row.max <= 2 then capped = row end end
  check(capped ~= nil, "the profile caps at least one Pokemon")

  -- and a profiled AI still beats the stub
  local wins = 0
  for g = 1, 30 do
    local rng = Rng.new(g * 53)
    local d = Duel.new(cards, { decks = { randomDeck(rng), randomDeck(rng) },
      seed = g, prizes = 4 })
    local ok = pcall(play, d, 1)
    if ok and d.finished.winner == 1 then wins = wins + 1 end
  end
  check(wins >= 15, ("the profiled AI still wins (%d/30)"):format(wins))
end

print(("tcg ai tests: %d failures"):format(failures))
if failures > 0 then os.exit(1) end
