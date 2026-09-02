-- Fuzz tier for the duel engine: random 60-card decks drawn from the whole
-- card pool (so the text-inferred effects in src/tcg/EffectPatterns.lua get
-- exercised), many seeds, invariants checked after every single action.
--   TCG_CACHE=<dir> lua tests/tcg_fuzz_test.lua [seeds]

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/cards.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local Duel = require("src.tcg.Duel")   -- marks Clefairy Doll / Mysterious Fossil as pseudo Basics
local Rng = require("src.tcg.Rng")
local SimpleAI = require("src.tcg.SimpleAI")
local Patterns = require("src.tcg.EffectPatterns")
local Effects = require("src.tcg.Effects")

local seeds = tonumber(arg and arg[1]) or 150
local failures = 0
local function fail(msg) failures = failures + 1; print("FAIL: " .. msg) end

-- pools
local basics, evos, energies, trainers = {}, {}, {}, {}
for id = 1, cards.count do
  local c = cards.byId[id]
  if c then
    if c.kind == "pokemon" then
      if c.stage == "BASIC" then basics[#basics + 1] = id else evos[#evos + 1] = id end
    elseif c.kind == "energy" then energies[#energies + 1] = id
    elseif c.pseudoPokemon then basics[#basics + 1] = id
    elseif Effects.hasTrainer(c.constant) then trainers[#trainers + 1] = id end
  end
end

-- a random but playable deck: 16 basics, 8 evolutions, 8 trainers, rest energy
local function randomDeck(rng)
  local deck = {}
  for _ = 1, 16 do deck[#deck + 1] = basics[rng:int(1, #basics)] end
  for _ = 1, 8 do deck[#deck + 1] = evos[rng:int(1, #evos)] end
  for _ = 1, 8 do deck[#deck + 1] = trainers[rng:int(1, #trainers)] end
  while #deck < 60 do deck[#deck + 1] = energies[rng:int(1, #energies)] end
  return deck
end

local function invariants(d, seed)
  for p = 1, 2 do
    if d:census(p) ~= 60 then fail(("seed %d: player %d census %d"):format(seed, p, d:census(p))) end
    for _, s in ipairs(d:slots(p)) do
      local max = d:card(s.card).hp
      if s.hp < 0 or s.hp > max then fail(("seed %d: hp %d out of range 0..%d"):format(seed, s.hp, max)) end
      if s.poison < 0 or s.poison > 2 then fail("seed " .. seed .. ": poison out of range") end
    end
  end
end

local used = {}
local start = os.clock()
for seed = 1, seeds do
  local rng = Rng.new(seed * 7919)
  local d = Duel.new(cards, { decks = { randomDeck(rng), randomDeck(rng) }, seed = seed, prizes = 4 })
  -- track which inferred effects fired by watching the log
  local ok, err = pcall(function()
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
      local active = d.players[d.current].active
      if active then
        local c = d:card(active.card)
        for i in ipairs(c.attacks) do
          if Patterns.infer(c, i) then used[c.constant .. "/" .. i] = true end
        end
      end
      SimpleAI.act(d, d.current)
      invariants(d, seed)
      guard = guard + 1
      if guard > 6000 then d:finish(0, "guard") end
      if d.turn > 300 then d:finish(0, "turn limit") end
    end
  end)
  if not ok then
    fail(("seed %d crashed: %s"):format(seed, tostring(err)))
    for i = math.max(1, #d.log - 8), #d.log do print("   " .. d.log[i]) end
  elseif d.finished.reason == "guard" then
    fail("seed " .. seed .. " tripped the action guard")
  end
end

local n = 0
for _ in pairs(used) do n = n + 1 end
local inferred, missing = Patterns.coverage(cards, Effects.hasExplicitAttack)
print(("tcg fuzz: %d seeds, %d failures, %.1fs; inferred attacks %d, unmatched %d, exercised in play %d"):format(
  seeds, failures, os.clock() - start, #inferred, #missing, n))
if failures > 0 then os.exit(1) end
