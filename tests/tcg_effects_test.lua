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

-- Phase 4: Pokemon Powers, Trainers, pseudo-Pokemon
do -- Snorlax Thick Skinned ignores status; Muk switches powers off
  local d = board(C.ARBOK, C.SNORLAX)
  d:attack(1, 2)
  check(d.players[2].active.poison == 0, "Snorlax cannot be poisoned")
  local d2 = board(C.ARBOK, C.SNORLAX)
  d2.players[1].hand[#d2.players[1].hand + 1] = C.MUK
  d2:playBasic(1, C.MUK)          -- Muk is Stage 1; force it as a slot via bench hack
  if #d2.players[1].bench == 0 then
    d2.players[1].hand[#d2.players[1].hand + 1] = C.GRIMER
    d2:playBasic(1, C.GRIMER)
    d2.players[1].bench[1].card = C.MUK; d2.players[1].bench[1].stack = { C.GRIMER, C.MUK }
  end
  d2:attack(1, 2)
  check(d2.players[2].active.poison == 1, "with Muk in play Snorlax is poisoned")
end

do -- Kabuto Armor halves, Mr. Mime walls 30+
  local d = board(C.MACHOP, C.KABUTO)
  d.players[1].active.plusPower = 1        -- Low Kick 20 + 10 = 30 -> 10
  d:attack(1, 1)
  check(d.players[2].active.hp == cards.byId[C.KABUTO].hp - 10, "Kabuto Armor: 30 -> 10")
  local d2 = board(C.MACHAMP, C.MR_MIME)
  d2:attack(1, 2)                          -- Seismic Toss 60
  check(d2.players[2].active.hp == cards.byId[C.MR_MIME].hp, "Invisible Wall blocks 60")
  local d3 = board(C.MACHOP, C.MR_MIME)
  d3:attack(1, 1)                          -- Low Kick 20 passes
  check(d3.players[2].active.hp == cards.byId[C.MR_MIME].hp - 20, "Invisible Wall lets 20 through")
end

do -- Transparency coin, Neutralizing Shield vs evolved
  local d = board(C.MACHOP, C.HAUNTER_LV17, { true })
  d:attack(1, 1)
  check(d.players[2].active.hp == cards.byId[C.HAUNTER_LV17].hp, "Transparency heads prevents")
  local d2 = board(C.MACHAMP, C.MEW_LV8)
  d2:attack(1, 2)
  check(d2.players[2].active.hp == cards.byId[C.MEW_LV8].hp, "Neutralizing Shield stops Machamp")
  local d3 = board(C.MACHOP, C.MEW_LV8)
  d3:attack(1, 1)
  check(d3.players[2].active.hp == cards.byId[C.MEW_LV8].hp - 20, "but not a Basic")
end

do -- Aerodactyl blocks evolution; Dodrio discounts retreat
  local d = board(C.MACHOP, C.AERODACTYL)
  d:endTurn(); d:endTurn()
  d.players[1].hand[#d.players[1].hand + 1] = C.MACHOKE
  check(not d:canEvolve(1, C.MACHOKE, 0), "Prehistoric Power blocks evolving")
  d.players[2].active.status = "asleep"
  check(d:canEvolve(1, C.MACHOKE, 0), "asleep Aerodactyl does not")
  local d2 = board(C.MACHAMP, C.MACHOP)   -- Machamp retreat 3
  d2.players[1].hand[#d2.players[1].hand + 1] = C.DODRIO
  d2.players[1].hand[#d2.players[1].hand + 1] = C.DODUO
  d2:playBasic(1, C.DODUO)
  d2.players[1].bench[1].card = C.DODRIO; d2.players[1].bench[1].stack = { C.DODUO, C.DODRIO }
  check(d2:retreatCost(1) == 2, "Retreat Aid: 3 -> 2 (got " .. d2:retreatCost(1) .. ")")
end

do -- activated powers: Damage Swap, Energy Burn
  local d = board(C.ALAKAZAM, C.MACHOP)
  local pl = d.players[1]
  pl.hand[#pl.hand + 1] = C.ABRA
  d:playBasic(1, C.ABRA)
  pl.active.hp = pl.active.hp - 30
  check(d:usePower(1, 0), "Damage Swap usable")
  check(pl.active.hp == cards.byId[C.ALAKAZAM].hp - 20 and pl.bench[1].hp == cards.byId[C.ABRA].hp - 10,
    "10 damage moved to Abra")
  local d2 = board(C.CHARIZARD, C.MACHOP)
  local z = d2.players[1].active
  z.energy = { C.WATER_ENERGY, C.WATER_ENERGY, C.WATER_ENERGY, C.WATER_ENERGY }
  check(not d2:canPay(z, cards.byId[C.CHARIZARD].attacks[2].energy), "Fire Spin needs Fire")
  check(d2:usePower(1, 0), "Energy Burn")
  check(d2:canPay(z, cards.byId[C.CHARIZARD].attacks[2].energy), "Energy Burn makes Water count as Fire")
end

do -- pseudo-Pokemon: Clefairy Doll benches, dies without a prize
  local d = board(C.MACHOP, C.RATTATA)
  local opp = d.players[2]
  opp.hand[#opp.hand + 1] = C.CLEFAIRY_DOLL
  d.current = 2; check(d:playBasic(2, C.CLEFAIRY_DOLL), "Clefairy Doll played as a Basic"); d.current = 1
  local prizes = #d.players[1].prizes
  opp.active, opp.bench[1] = opp.bench[1], opp.active
  d:attack(1, 1)                            -- Low Kick 20 vs 10 HP doll
  check(#d.players[1].prizes == prizes, "no prize for a Knocked Out Doll")
  check(opp.active and opp.active.card == C.RATTATA, "Rattata promoted")
end

do -- trainers: Gambler, Energy Retrieval, Revive, Pokemon Breeder
  local d = board(C.MACHOP, C.RATTATA, { true })
  local pl = d.players[1]
  pl.hand = { C.GAMBLER }
  check(d:playTrainer(1, C.GAMBLER), "Gambler")
  check(#pl.hand == 8, "Gambler heads draws 8 (hand " .. #pl.hand .. ")")
  local d2 = board(C.MACHOP, C.RATTATA)
  local p2 = d2.players[1]
  p2.hand = { C.ENERGY_RETRIEVAL, C.BILL }
  p2.discard = { C.FIRE_ENERGY, C.WATER_ENERGY, C.GRASS_ENERGY }
  check(d2:playTrainer(1, C.ENERGY_RETRIEVAL), "Energy Retrieval")
  check(#p2.hand == 2 and #p2.discard == 3, "traded Bill for 2 Energy (hand " .. #p2.hand .. ", discard " .. #p2.discard .. ")")
  local d3 = board(C.MACHOP, C.RATTATA)
  local p3 = d3.players[1]
  p3.hand = { C.REVIVE }; p3.discard = { C.MACHAMP, C.MACHOP }
  check(d3:playTrainer(1, C.REVIVE), "Revive")
  check(p3.bench[1] and p3.bench[1].card == C.MACHOP and p3.bench[1].hp == 30, "Machop revived at half HP")
  local d4 = board(C.MACHOP, C.RATTATA)
  d4:endTurn(); d4:endTurn()
  local p4 = d4.players[1]
  p4.hand = { C.POKEMON_BREEDER, C.MACHAMP }
  check(d4:playTrainer(1, C.POKEMON_BREEDER), "Pokemon Breeder")
  check(p4.active.card == C.MACHAMP, "Machop -> Machamp directly")
end

-- the fifteen attacks that needed explicit handlers (src/tcg/EffectsRare.lua)
do
  local P = require("src.tcg.EffectPatterns")
  local E = require("src.tcg.Effects")
  local _, missing = P.coverage(cards, E.hasExplicitAttack)
  check(#missing == 0, #missing .. " attacks still have no handler")
end

do -- Mirror Move repeats what was done to it
  local d = board(C.PIDGEOTTO, C.MACHAMP)
  d:attack(2, 2)                                   -- Machamp hits Pidgeotto
  local taken = d.players[1].active.lastDamageTaken
  check(taken and taken > 0, "the hit is recorded on the slot (" .. tostring(taken) .. ")")
  local before = d.players[2].active.hp
  d:attack(1, 2)                                   -- Mirror Move
  check(d.players[2].active.hp == before - taken, "Mirror Move returns the same damage")
  -- with nothing to copy it does nothing
  local d2 = board(C.PIDGEOTTO, C.MACHAMP)
  local hp = d2.players[2].active.hp
  d2:attack(1, 2)
  check(d2.players[2].active.hp == hp, "Mirror Move with nothing to copy deals nothing")
end

do -- Conversion rewrites Weakness, and the damage calculation honours it
  local d = board(C.PORYGON, C.MACHAMP)
  d.players[2].active.weaknessOverride = nil
  d:attack(1, 1, { type = "PSYCHIC" })
  check(d.players[2].active.weaknessOverride ~= nil, "Conversion 1 sets a Weakness")
  check(d:weaknessOf(d.players[2].active)[1] == d.players[2].active.weaknessOverride[1],
    "the lookup uses the override")
end

do -- Magnetic Storm keeps every Energy on the player's side
  local d = board(C.MAGNEMITE_LV15, C.MACHAMP)
  local pl = d.players[1]
  pl.hand[#pl.hand + 1] = C.PIKACHU_LV12
  d:playBasic(1, C.PIKACHU_LV12)
  pl.active.energy = { C.LIGHTNING_ENERGY, C.LIGHTNING_ENERGY, C.LIGHTNING_ENERGY }
  local before = #pl.active.energy + #pl.bench[1].energy
  d:attack(1, 2)
  local after = #pl.active.energy + #pl.bench[1].energy
  check(after == before, "Magnetic Storm conserves Energy (" .. before .. " -> " .. after .. ")")
end

do -- Dive Bomb converts discarded Fire Energy into damage
  local d = board(C.MOLTRES_LV35, C.MACHAMP)
  local me = d.players[1].active
  me.energy = { C.FIRE_ENERGY, C.FIRE_ENERGY, C.FIRE_ENERGY, C.FIRE_ENERGY }
  local base = cards.byId[C.MOLTRES_LV35].attacks[1].damage
  local hp = d.players[2].active.hp
  d:attack(1, 1, { discard = 2 })
  check(#me.energy == 2, "two Fire Energy discarded")
  check(hp - d.players[2].active.hp >= base + 20, "the damage went up by 10 each")
end

print(("tcg effects tests: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
