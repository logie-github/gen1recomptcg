-- Headless duel engine tests.  Needs an extracted TCG cache
-- (TCG_CACHE=/path or ./tcg-cache); skips when absent, like the T3 tier.
--   lua tests/tcg_duel_test.lua

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/cards.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local decks = dofile(cacheDir .. "/data/generated/decks.lua")
local Duel = require("src.tcg.Duel")
local SimpleAI = require("src.tcg.SimpleAI")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. msg) end
end

local function expand(deck)
  local out = {}
  for _, e in ipairs(deck.cards) do for _ = 1, e.count do out[#out + 1] = e.card end end
  return out
end
local sams, practice = expand(decks[2]), expand(decks[3])
check(#sams == 60 and #practice == 60, "practice decks are 60 cards")

local C = cards.byConstant

-- 1. deterministic full playouts, invariants
for seed = 1, 20 do
  local d = Duel.new(cards, { decks = { practice, sams }, seed = seed, names = { "YOU", "SAM" } })
  SimpleAI.playout(d)
  check(d.finished ~= nil, "duel " .. seed .. " finished")
  check(d.finished.reason ~= "turn limit" and d.finished.reason ~= "playout guard tripped",
    "duel " .. seed .. " ended by rules (" .. tostring(d.finished.reason) .. ")")
  check(d:census(1) == 60 and d:census(2) == 60,
    ("duel %d conserves cards (%d/%d)"):format(seed, d:census(1), d:census(2)))
end
do
  local a = Duel.new(cards, { decks = { practice, sams }, seed = 7 }); SimpleAI.playout(a)
  local b = Duel.new(cards, { decks = { practice, sams }, seed = 7 }); SimpleAI.playout(b)
  check(table.concat(a.log, "\n") == table.concat(b.log, "\n"), "same seed reproduces the log")
end

-- 2. rules unit checks on a scripted board
local function board(p1Active, p2Active, seed)
  local d = Duel.new(cards, { decks = { practice, sams }, seed = seed or 3 })
  d:start(1)
  -- force chosen actives regardless of hand
  for p, id in ipairs({ p1Active, p2Active }) do
    local pl = d.players[p]
    pl.hand[#pl.hand + 1] = id
    d:placeActive(p, id, true)
  end
  d:finishSetup()
  return d
end

do -- weakness doubles, resistance -30 (Machop is Fighting; Rattata? use known cards)
  local d = board(C.MACHOP, C.RATTATA)           -- Rattata: weak to Fighting, resists Psychic
  local dmg, eff = d:modifiedDamage(d.players[1].active, d.players[2].active, 20)
  check(dmg == 40 and eff.weakness, "Fighting vs Rattata doubles (got " .. dmg .. ")")
  local d2 = board(C.ABRA, C.RATTATA)            -- Psychic vs Rattata: resistance
  local dmg2, eff2 = d2:modifiedDamage(d2.players[1].active, d2.players[2].active, 40)
  check(dmg2 == 10 and eff2.resistance, "Psychic vs Rattata resists 30 (got " .. dmg2 .. ")")
  check(select(1, d2:modifiedDamage(d2.players[1].active, d2.players[2].active, 10)) == 0,
    "resistance never goes below 0")
end

do -- energy cost accounting incl. Double Colorless
  local d = board(C.MACHAMP, C.RATTATA)
  local a = d.players[1].active
  local atk = cards.byId[C.MACHAMP].attacks[2]   -- Seismic Toss FFF C
  check(not d:canPay(a, atk.energy), "no energy -> cannot pay")
  a.energy = { C.FIGHTING_ENERGY, C.FIGHTING_ENERGY, C.FIGHTING_ENERGY, C.DOUBLE_COLORLESS_ENERGY }
  check(d:canPay(a, atk.energy), "FFF + DCE pays FFFC")
  a.energy = { C.FIGHTING_ENERGY, C.FIGHTING_ENERGY, C.FIGHTING_ENERGY }
  check(not d:canPay(a, atk.energy), "FFF alone cannot pay FFFC")
  a.energy = { C.FIGHTING_ENERGY, C.FIGHTING_ENERGY, C.FIGHTING_ENERGY, C.WATER_ENERGY }
  check(d:canPay(a, atk.energy), "off-colour energy pays colourless")
end

do -- one energy per turn, attack ends the turn, knockout takes a prize
  local d = board(C.MACHOP, C.RATTATA)
  local pl = d.players[1]
  pl.hand[#pl.hand + 1] = C.FIGHTING_ENERGY
  pl.hand[#pl.hand + 1] = C.FIGHTING_ENERGY
  check(d:attachEnergy(1, C.FIGHTING_ENERGY, 0), "first attach ok")
  check(not d:attachEnergy(1, C.FIGHTING_ENERGY, 0), "second attach refused")
  local prizesBefore = #pl.prizes
  d.players[2].bench[1] = { card = C.RATTATA, stack = { C.RATTATA }, hp = 30, energy = {}, status = "none", poison = 0, plusPower = 0, defender = 0, turnPlayed = 0 }
  d.players[2].deck[#d.players[2].deck + 1] = nil
  check(d:attack(1, 1), "Low Kick attacks")
  check(#pl.prizes == prizesBefore - 1, "KO takes a prize")
  check(d.current == 2, "attack ended the turn")
  check(d.players[2].active and d.players[2].active.card == C.RATTATA, "bench Pokemon promoted")
end

do -- status: paralysis blocks attack and clears between turns; poison ticks
  local d = board(C.MACHOP, C.RATTATA)
  local rat = d.players[2].active
  rat.status = "paralyzed"; rat.poison = 1
  d:endTurn()                       -- player 1's turn ends; between-turns runs
  check(rat.hp == 20, "poison dealt 10 between turns (hp " .. rat.hp .. ")")
  check(rat.status == "paralyzed", "paralysis persists into the paralyzed player's own turn end")
  check(#d:legalActions(2) > 0, "player 2 to act")
  local attacks = 0
  for _, a in ipairs(d:legalActions(2)) do if a.kind == "attack" then attacks = attacks + 1 end end
  check(attacks == 0, "paralyzed Pokemon cannot attack")
  d:endTurn()
  check(rat.status == "none", "paralysis cured at end of own turn")
end

do -- evolution: not on the turn played, keeps damage, cures status
  local d = board(C.MACHOP, C.RATTATA)
  local pl = d.players[1]
  pl.hand[#pl.hand + 1] = C.MACHOKE
  check(not d:canEvolve(1, C.MACHOKE, 0), "no evolving on turn 1")
  d:endTurn(); d:endTurn()
  pl.active.hp = pl.active.hp - 20
  pl.active.status = "confused"
  check(d:evolve(1, C.MACHOKE, 0), "evolve Machop -> Machoke")
  check(pl.active.hp == cards.byId[C.MACHOKE].hp - 20, "damage carried over")
  check(pl.active.status == "none", "evolving cures status")
  pl.hand[#pl.hand + 1] = C.MACHAMP
  check(not d:canEvolve(1, C.MACHAMP, 0), "cannot evolve twice in a turn")
end

do -- trainers: Bill draws 2, Potion heals 20, Gust of Wind switches
  local d = board(C.MACHOP, C.RATTATA)
  local pl = d.players[1]
  local handBefore = #pl.hand
  pl.hand[#pl.hand + 1] = C.BILL
  check(d:playTrainer(1, C.BILL), "Bill plays")
  check(#pl.hand == handBefore + 2, "Bill drew 2 (" .. #pl.hand .. " vs " .. handBefore .. ")")
  pl.active.hp = 10
  pl.hand[#pl.hand + 1] = C.POTION
  check(d:playTrainer(1, C.POTION) and pl.active.hp == 30, "Potion heals 20")
end

do -- Super Fang and Strikes Back
  local d = board(C.RATICATE, C.MACHAMP)
  local a = d.players[1].active
  a.energy = { C.DOUBLE_COLORLESS_ENERGY, C.WATER_ENERGY }
  d.players[2].active.hp = 70
  check(d:attack(1, 2), "Super Fang attacks")
  check(d.players[2].active.hp == 30, "Super Fang halves 70 -> 40 dealt (hp " .. d.players[2].active.hp .. ")")
  check(a.hp == cards.byId[C.RATICATE].hp - 10, "Strikes Back returned 10")
end

print(("tcg duel tests: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
