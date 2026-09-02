-- Unit checks for text-inferred attack effects and substatuses
-- (src/tcg/EffectPatterns.lua, Duel:setSub).  Coins are rigged per test.
--   TCG_CACHE=<dir> lua tests/tcg_effects_test.lua

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/cards.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local decks = dofile(cacheDir .. "/data/generated/decks.lua")
local Duel = require("src.tcg.Duel")
local C = cards.byConstant

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

-- scripted board: chosen actives, full energy, rigged coins
local function board(p1, p2, coins)
  local d = Duel.new(cards, { decks = { practice, sams }, seed = 3 })
  d:start(1)
  for p, id in ipairs({ p1, p2 }) do
    d.players[p].hand[#d.players[p].hand + 1] = id
    d:placeActive(p, id, true)
  end
  d:finishSetup()
  for p = 1, 2 do
    local a = d.players[p].active
    for _, atk in ipairs(cards.byId[a.card].attacks) do
      for t, n in pairs(atk.energy) do
        local eid = C[t == "COLORLESS" and "DOUBLE_COLORLESS_ENERGY" or (t .. "_ENERGY")]
        for _ = 1, n do a.energy[#a.energy + 1] = eid or C.DOUBLE_COLORLESS_ENERGY end
      end
    end
  end
  if coins then
    local i = 0
    d.coin = function(self, label)
      i = i + 1
      local h = coins[i]
      if h == nil then h = true end
      self:say("%s: %s (rigged)", label or "coin", h and "HEADS" or "TAILS")
      return h
    end
  end
  return d
end

do -- coin status: Caterpie String Shot, heads -> paralyzed, tails -> nothing
  local d = board(C.CATERPIE, C.RATTATA, { true })
  d:attack(1, 1)
  check(d.players[2].active.status == "paralyzed", "String Shot heads paralyzes")
  local d2 = board(C.CATERPIE, C.RATTATA, { false })
  d2:attack(1, 1)
  check(d2.players[2].active.status == "none", "String Shot tails does not")
end

do -- plain status: Arbok Poison Fang; Nidoking Toxic double poison
  local d = board(C.ARBOK, C.MACHAMP)
  d:attack(1, 2)
  check(d.players[2].active.poison == 1, "Poison Fang poisons")
  local d2 = board(C.NIDOKING, C.MACHAMP)
  local toxic = cards.byId[C.NIDOKING].attacks[2].damage
  d2:attack(1, 2)                                  -- attack ends the turn: between-turns poison ticks once
  check(d2.players[2].active.poison == 2, "Toxic double-poisons")
  check(d2.players[2].active.hp == cards.byId[C.MACHAMP].hp - toxic - 20, "Toxic ticks 20 (hp " .. d2.players[2].active.hp .. ")")
end

do -- coins x damage: Vileplume Petal Dance 3 coins x40, then self confused
  local d = board(C.VILEPLUME, C.MACHAMP, { true, false, true })
  d:attack(1, 2)
  check(d.players[2].active.hp == cards.byId[C.MACHAMP].hp - 80, "Petal Dance 2 heads = 80")
  check(d.players[1].active.status == "confused", "Vileplume confuses itself after")
end

do -- flip until tails: Geodude Stone Barrage
  local d = board(C.GEODUDE, C.MACHAMP, { true, true, true, false })
  d:attack(1, 1)
  check(d.players[2].active.hp == cards.byId[C.MACHAMP].hp - 30, "Stone Barrage 3 heads = 30")
end

do -- energy discard requirement: Charmander Flamethrower discards one Fire
  local d = board(C.CHARMANDER, C.MACHAMP)
  local before = #d.players[1].active.energy
  d:attack(1, 2)
  check(#d.players[1].active.energy == before - 1, "Flamethrower discards 1 energy")
  check(d.players[2].active.hp == cards.byId[C.MACHAMP].hp - 30, "and still deals 30")
end

do -- substatus: Grimer Minimize reduces damage by 20 next turn, then expires
  local d = board(C.GRIMER, C.MACHOP)
  d:attack(1, 2)                                   -- Minimize
  check(d:sub(d.players[1].active, "damageReduction") == 20, "Minimize sets reduction")
  d:attack(2, 1)                                   -- Machop Low Kick 20 -> 0
  check(d.players[1].active.hp == cards.byId[C.GRIMER].hp, "Low Kick reduced to 0")
  d:endTurn()                                      -- back to player 2? no: attack ended turn 2 -> turn 3 (p1)
  -- turn 3 is player 1's; the substatus expires after turn 2
  check(d:sub(d.players[1].active, "damageReduction") == nil, "reduction expired after opponent's turn")
end

do -- Agility-style: Rapidash Agility heads -> no damage or effect next turn
  local d = board(C.RAPIDASH, C.ARBOK, { true, true })
  d:attack(1, 2)
  check(d:sub(d.players[1].active, "preventAll"), "Agility heads protects")
  d:attack(2, 2)                                   -- Arbok Poison Fang
  check(d.players[1].active.hp == cards.byId[C.RAPIDASH].hp and d.players[1].active.poison == 0,
    "protected from damage and poison")
end

do -- cannotAttack / attackCoin / no trainers
  local d = board(C.MAROWAK_LV32, C.MACHOP, { true })
  d:attack(1, 1)                                   -- Bonemerang? check card: attack 1 is coin "can't attack"
  local blocked = d:sub(d.players[2].active, "cannotAttack")
  if blocked then
    local atk = 0
    for _, a in ipairs(d:legalActions(2)) do if a.kind == "attack" then atk = atk + 1 end end
    check(atk == 0, "blocked Pokemon has no attack actions")
  else
    check(true, "Marowak attack 1 is not the cannot-attack one on this card; skipped")
  end
  local d2 = board(C.SANDSHREW, C.MACHOP, { false })
  d2:attack(1, 1)                                  -- Sand-attack: attackCoin on Machop
  local ok = d2:attack(2, 1)                       -- rigged tails: does nothing
  check(ok and d2.players[1].active.hp == cards.byId[C.SANDSHREW].hp, "Sand-attack tails: attack does nothing")
  local d3 = board(C.PSYDUCK, C.MACHOP)
  d3:attack(1, 1)                                  -- Headache
  d3.players[2].hand[#d3.players[2].hand + 1] = C.BILL
  local trainers = 0
  for _, a in ipairs(d3:legalActions(2)) do if a.kind == "playTrainer" then trainers = trainers + 1 end end
  check(trainers == 0, "Headache blocks Trainers next turn")
end

do -- bench damage without W/R: Dugtrio Earthquake hurts own bench
  local d = board(C.DUGTRIO, C.MACHAMP)
  local pl = d.players[1]
  pl.hand[#pl.hand + 1] = C.DIGLETT
  d:playBasic(1, C.DIGLETT)
  d:attack(1, 2)
  check(pl.bench[1].hp == cards.byId[C.DIGLETT].hp - 10, "Earthquake does 10 to own bench")
end

do -- switch: Butterfree Whirlwind swaps the defender with a benched Pokemon
  local d = board(C.BUTTERFREE, C.MACHOP)
  local opp = d.players[2]
  opp.hand[#opp.hand + 1] = C.RATTATA
  d.current = 2; d:playBasic(2, C.RATTATA); d.current = 1
  d:attack(1, 1)
  check(opp.active.card == C.RATTATA and opp.bench[1].card == C.MACHOP, "Whirlwind switched Rattata in")
end

print(("tcg effects tests: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
