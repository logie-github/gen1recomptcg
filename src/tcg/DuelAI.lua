-- Heuristic duelist AI (docs/tcg-phase1.md, Phase 5).
--
-- Not a port of poketcg's per-deck AI (engine/duel/ai/decks/*), which is
-- 30-odd hand-tuned scripts; this is one general policy that follows the
-- same turn order as AIMainTurnLoop and borrows the shape of its attack
-- scoring (engine/duel/ai/attacks.asm: start at a base score, +20 if the
-- attack Knocks Out, +1 per damage counter dealt, penalties for recoil and
-- energy discards, bonuses for status and bench damage) and its retreat
-- scoring (retreat.asm: status, low HP, and a better attacker on the bench).
-- Attack outcomes involving coins use the expected value.
--
-- Everything goes through Duel's public actions, so the AI is also a
-- reference for what a UI must supply in `args`.

local Effects = require("src.tcg.Effects")

local DuelAI = {}

local ENERGY_OF = {
  TYPE_ENERGY_FIRE = "FIRE", TYPE_ENERGY_GRASS = "GRASS", TYPE_ENERGY_LIGHTNING = "LIGHTNING",
  TYPE_ENERGY_WATER = "WATER", TYPE_ENERGY_FIGHTING = "FIGHTING", TYPE_ENERGY_PSYCHIC = "PSYCHIC",
  TYPE_ENERGY_DOUBLE_COLORLESS = "COLORLESS",
}
local COLOR_OF = {
  TYPE_PKMN_FIRE = "FIRE", TYPE_PKMN_GRASS = "GRASS", TYPE_PKMN_LIGHTNING = "LIGHTNING",
  TYPE_PKMN_WATER = "WATER", TYPE_PKMN_FIGHTING = "FIGHTING", TYPE_PKMN_PSYCHIC = "PSYCHIC",
  TYPE_PKMN_COLORLESS = "COLORLESS",
}

local function has(list, v) for _, x in ipairs(list or {}) do if x == v then return true end end return false end
local function maxHp(duel, slot) return duel:card(slot.card).hp end

-- ---------------------------------------------------------------------
-- damage estimation
-- ---------------------------------------------------------------------

-- Expected damage of `atk` from `attacker` into `defender`, after W/R,
-- PlusPower/Defender and the defender's substatuses.  Coin-flip text is
-- averaged rather than simulated.
function DuelAI.expectedDamage(duel, attacker, defender, atk)
  local text = (atk.description or ""):gsub("\n", " ")
  local base = atk.damage
  local n, per = text:match("Flip (%d+) coins?%. This attack does (%d+) damage times the number of heads")
  if n then base = tonumber(n) * tonumber(per) / 2
  elseif text:match("Flip a coin until you get tails") then
    per = text:match("does (%d+) damage times the number of heads"); base = tonumber(per) or 0
  elseif text:match("If tails, this attack does nothing") then base = base / 2
  else
    local b, e = text:match("If heads, this attack does (%d+) damage plus (%d+) more damage")
    if b then base = tonumber(b) + tonumber(e) / 2 end
    local pb, pe = text:match("Does (%d+) damage plus (%d+) more damage for each Energy attached")
    if pb then base = tonumber(pb) + tonumber(pe) * #attacker.energy end
    local db, de = text:match("Does (%d+) damage plus (%d+) more damage for each damage counter on")
    if db then base = tonumber(db) + tonumber(de) * math.floor((maxHp(duel, attacker) - attacker.hp) / 10) end
    local tp = text:match("Does (%d+) damage times the number of damage counters on")
    if tp then base = tonumber(tp) * math.floor((maxHp(duel, attacker) - attacker.hp) / 10) end
  end
  if atk.category == "POKEMON_POWER" then return 0 end
  local ignoreWR = text:find("Don't apply Weakness and Resistance", 1, true) ~= nil
  local dmg = select(1, duel:modifiedDamage(attacker, defender, base, { ignoreWR = ignoreWR }))
  dmg = duel:applyDefenderSubs(defender, dmg)
  if duel:sub(defender, "preventAll") then dmg = 0 end
  return dmg
end

-- ---------------------------------------------------------------------
-- attack scoring (attacks.asm GetAIScoreOfAttack)
-- ---------------------------------------------------------------------

function DuelAI.scoreAttack(duel, p, atk, index)
  local pl = duel.players[p]
  local me, foe = pl.active, duel.players[duel:opponentOf(p)].active
  if not duel:canPay(me, atk.energy) then return -1 end
  if atk.category == "POKEMON_POWER" then return -1 end
  local text = (atk.description or ""):gsub("\n", " ")
  local score = 0x50
  local dmg = DuelAI.expectedDamage(duel, me, foe, atk)
  if dmg >= foe.hp then score = score + 20 end            -- KO
  score = score + dmg / 10                                 -- damage counters
  if dmg == 0 then score = score - 1 end
  -- status and lasting effects
  if text:find("is now") then score = score + (text:find("Flip a coin") and 2 or 4) end
  if text:find("Benched") then score = score + 2 end
  if text:find("can't attack") or text:find("attack does nothing") then score = score + 2 end
  if text:find("prevent all") then score = score + 3 end
  -- costs
  local rn = text:match("does (%d+) damage to itself")
  if rn then
    score = score - tonumber(rn) / 10
    if tonumber(rn) >= me.hp then score = score - 10 end
  end
  local dn = text:match("Discard (%d+) [^%.]*Energy cards? attached to %S+ in order")
  if dn then score = score - tonumber(dn) * 2 end
  if text:find("Discard all Energy") then score = score - #me.energy * 2 end
  if text:find("is now Confused %(after") or text:find("%S+ is now Confused %(after") then score = score - 3 end
  -- healing attacks (Recover and friends) are only worth it when hurt
  local taken = maxHp(duel, me) - me.hp
  if text:find("Remove all damage counters from") then
    score = score + taken / 10 * 2 - 12
  elseif text:find("remove (%d+) damage counters?") or text:find("Remove a number of damage counters") then
    score = score + math.min(taken, 40) / 10
  end
  -- Haunter/Mew style total prevention makes damage attacks pointless
  if dmg == 0 and not text:find("is now") and not text:find("Benched") and not text:find("damage counters") then
    score = score - 20
  end
  return score, dmg
end

-- ---------------------------------------------------------------------
-- energy attachment (energy.asm)
-- ---------------------------------------------------------------------

-- energy still missing for `atk` on `slot`: { type = count }
local function missingEnergy(duel, slot, atk)
  local have = duel:energyProvided(slot)
  local missing, spare = {}, 0
  for t, need in pairs(atk.energy) do
    if t ~= "COLORLESS" then
      if have[t] < need then missing[t] = need - have[t] else spare = spare + have[t] - need end
    end
  end
  for t, v in pairs(have) do if not atk.energy[t] and t ~= "COLORLESS" then spare = spare + v end end
  spare = spare + have.COLORLESS
  local cl = (atk.energy.COLORLESS or 0) - spare
  if cl > 0 then missing.COLORLESS = cl end
  return missing
end

local function bestAttack(duel, slot)
  local card = duel:card(slot.card)
  local best, bestDmg
  for _, atk in ipairs(card.attacks) do
    if atk.category ~= "POKEMON_POWER" and (not bestDmg or atk.damage > bestDmg) then best, bestDmg = atk, atk.damage end
  end
  return best
end

-- Which energy card in hand to attach where; nil if nothing sensible.
function DuelAI.chooseEnergy(duel, p)
  local pl = duel.players[p]
  if pl.flags.attachedEnergy then return nil end
  local hand = {}
  for _, id in ipairs(pl.hand) do if duel:card(id).kind == "energy" then hand[#hand + 1] = id end end
  if #hand == 0 then return nil end
  local best, bestScore
  for loc = 0, #pl.bench do
    local slot = duel:slotAt(p, loc)
    local card = duel:card(slot.card)
    if not card.pseudoPokemon then
      for _, atk in ipairs(card.attacks) do
        if atk.category ~= "POKEMON_POWER" then
          local missing = missingEnergy(duel, slot, atk)
          local total = 0
          for _, v in pairs(missing) do total = total + v end
          for _, id in ipairs(hand) do
            local t = ENERGY_OF[duel:card(id).type]
            local fits = (missing[t] or 0) > 0 or (t == "COLORLESS" and (missing.COLORLESS or 0) > 0)
              or (total > 0 and next(missing) == "COLORLESS" and missing.COLORLESS)
            -- a coloured card can always pay colourless; prefer exact colour matches
            if total > 0 then
              local score = (loc == 0 and 30 or 15) + atk.damage / 10 - total * 5
              if fits then score = score + 10 end
              if total == 1 and fits then score = score + 15 end   -- this attachment enables the attack
              if (missing[t] or 0) > 0 then score = score + 5 end
              -- build one attacker at a time rather than spreading energy
              score = score + math.min(3, #slot.energy) * 4
              -- an evolved bench Pokemon is the next attacker; a fully powered
              -- active makes the bench the priority
              if card.stage ~= "BASIC" and loc ~= 0 then score = score + 6 end
              if loc == 0 then
                local active = pl.active
                local bestA = bestAttack(duel, active)
                if bestA and duel:canPay(active, bestA.energy) then score = score - 20 end
              end
              if not bestScore or score > bestScore then best, bestScore = { card = id, location = loc }, score end
            end
          end
        end
      end
    end
  end
  if not best then
    -- everything is powered: stack on the active (PlusPower-ish, future retreats)
    return { card = hand[1], location = 0 }
  end
  return best
end

-- ---------------------------------------------------------------------
-- retreat scoring (retreat.asm)
-- ---------------------------------------------------------------------

function DuelAI.retreatChoice(duel, p)
  local pl = duel.players[p]
  if pl.flags.retreated or #pl.bench == 0 or not duel:canRetreat(p) then return nil end
  local me = pl.active
  local foe = duel.players[duel:opponentOf(p)].active
  local score = 0
  if me.status ~= "none" then score = score + 3 end
  if me.poison > 0 then score = score + 2 end
  if duel:sub(me, "cannotAttack") then score = score + 3 end
  local myBest = -1
  for i, atk in ipairs(duel:card(me.card).attacks) do
    local s = DuelAI.scoreAttack(duel, p, atk, i)
    if s > myBest then myBest = s end
  end
  if myBest < 0 then score = score + 4 end                 -- cannot attack at all
  -- about to be Knocked Out?
  local threat = 0
  for _, atk in ipairs(duel:card(foe.card).attacks) do
    if atk.category ~= "POKEMON_POWER" and duel:canPay(foe, atk.energy) then
      threat = math.max(threat, DuelAI.expectedDamage(duel, foe, me, atk))
    end
  end
  if threat >= me.hp then score = score + 3 end
  local foeHp = foe.hp
  local myDmg = 0
  for _, atk in ipairs(duel:card(me.card).attacks) do
    if atk.category ~= "POKEMON_POWER" and duel:canPay(me, atk.energy) then
      myDmg = math.max(myDmg, DuelAI.expectedDamage(duel, me, foe, atk))
    end
  end
  -- best bench candidate: can attack now, healthy, not weak to the foe
  local bestLoc, bestVal
  for loc, s in ipairs(pl.bench) do
    local card = duel:card(s.card)
    if not card.pseudoPokemon then
      local val = s.hp / 10
      local atkVal = -5
      for _, atk in ipairs(card.attacks) do
        if atk.category ~= "POKEMON_POWER" and duel:canPay(s, atk.energy) then
          atkVal = math.max(atkVal, DuelAI.expectedDamage(duel, s, foe, atk) / 10)
        end
      end
      val = val + atkVal * 2
      if has(card.weakness, COLOR_OF[duel:card(foe.card).type]) then val = val - 4 end
      if atkVal * 10 >= myDmg + 20 then val = val + 6 end          -- hits noticeably harder
      if atkVal * 10 >= foeHp and myDmg < foeHp then val = val + 8 end  -- can Knock Out now
      if not bestVal or val > bestVal then bestLoc, bestVal = loc, val end
    end
  end
  if not bestLoc then return nil end
  local cost = duel:retreatCost(p)
  score = score - cost
  if bestVal >= 14 then score = score + 3 end
  if score >= 5 then return bestLoc end
  return nil
end

-- ---------------------------------------------------------------------
-- trainers
-- ---------------------------------------------------------------------

local function damaged(duel, s) return s.hp < maxHp(duel, s) end

-- Returns true if the trainer is worth playing now.  Cards not listed are
-- played whenever legal (the engine's `can` already guards usefulness).
local TRAINER_WANTS = {
  POTION = function(duel, p) for _, s in ipairs(duel:slots(p)) do if maxHp(duel, s) - s.hp >= 20 then return true end end end,
  SUPER_POTION = function(duel, p) for _, s in ipairs(duel:slots(p)) do if maxHp(duel, s) - s.hp >= 40 and #s.energy >= 3 then return true end end end,
  BILL = function(duel, p) return #duel.players[p].hand <= 6 and #duel.players[p].deck > 8 end,
  PROFESSOR_OAK = function(duel, p) return #duel.players[p].hand <= 3 and #duel.players[p].deck > 14 end,
  GAMBLER = function(duel, p) return #duel.players[p].hand <= 2 and #duel.players[p].deck > 12 end,
  PLUSPOWER = function(duel, p)
    local foe = duel.players[duel:opponentOf(p)].active
    for i, atk in ipairs(duel:card(duel.players[p].active.card).attacks) do
      local _, dmg = DuelAI.scoreAttack(duel, p, atk, i)
      if dmg and dmg > 0 and dmg < foe.hp and dmg + 10 >= foe.hp then return true end
    end
  end,
  DEFENDER = function(duel, p)
    local me, foe = duel.players[p].active, duel.players[duel:opponentOf(p)].active
    for _, atk in ipairs(duel:card(foe.card).attacks) do
      if duel:canPay(foe, atk.energy) then
        local d = DuelAI.expectedDamage(duel, foe, me, atk)
        if d >= me.hp and d - 20 < me.hp then return true end
      end
    end
  end,
  SWITCH = function(duel, p) return DuelAI.retreatChoice(duel, p) ~= nil or (duel.players[p].active.status ~= "none" and #duel.players[p].bench > 0) end,
  GUST_OF_WIND = function(duel, p)
    -- pull a benched Pokemon we can Knock Out this turn
    local me = duel.players[p].active
    for loc, s in ipairs(duel.players[duel:opponentOf(p)].bench) do
      for _, atk in ipairs(duel:card(me.card).attacks) do
        if atk.category ~= "POKEMON_POWER" and duel:canPay(me, atk.energy)
          and DuelAI.expectedDamage(duel, me, s, atk) >= s.hp then return true, { location = loc } end
      end
    end
  end,
  ENERGY_REMOVAL = function(duel, p)
    local foe = duel.players[duel:opponentOf(p)].active
    return #foe.energy >= 2
  end,
  SUPER_ENERGY_REMOVAL = function(duel, p)
    local foe = duel.players[duel:opponentOf(p)].active
    return #foe.energy >= 3
  end,
  FULL_HEAL = function(duel, p) local a = duel.players[p].active return a.status ~= "none" or a.poison > 0 end,
  POKEMON_CENTER = function(duel, p)
    local gain, loss = 0, 0
    for _, s in ipairs(duel:slots(p)) do if damaged(duel, s) then gain = gain + maxHp(duel, s) - s.hp; loss = loss + #s.energy end end
    return gain >= 60 and loss <= 3
  end,
  IMAKUNI_CARD = function() return false end,
  LASS = function(duel, p) local n = 0 for _, id in ipairs(duel.players[p].hand) do if duel:card(id).kind == "trainer" then n = n + 1 end end return n <= 1 end,
  MAINTENANCE = function(duel, p) return #duel.players[p].hand >= 5 end,
  MR_FUJI = function() return false end,
  DEVOLUTION_SPRAY = function() return false end,
  SCOOP_UP = function(duel, p)
    local a = duel.players[p].active
    return #duel.players[p].bench > 0 and a.hp <= 20 and #a.energy <= 1
  end,
  RECYCLE = function(duel, p) return #duel.players[p].deck < 10 end,
  POKEMON_FLUTE = function() return false end,
}

function DuelAI.chooseTrainer(duel, p)
  local pl = duel.players[p]
  for _, id in ipairs(pl.hand) do
    local c = duel:card(id)
    if c.kind == "trainer" and not c.pseudoPokemon and Effects.canPlayTrainer(duel, p, id)
      and not (pl.noTrainersUntil and duel.turn <= pl.noTrainersUntil) then
      local want = TRAINER_WANTS[c.constant]
      if not want then return id, {} end
      local ok, args = want(duel, p)
      if ok then return id, args or {} end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------
-- the turn (core.asm AIMainTurnLoop order: hand Pokemon, evolutions,
-- energy, trainers, powers, retreat, attack)
-- ---------------------------------------------------------------------

local function actionsOfKind(duel, p, kind)
  local out = {}
  for _, a in ipairs(duel:legalActions(p)) do if a.kind == kind then out[#out + 1] = a end end
  return out
end

-- One step of the AI's turn.  Returns false once it has ended the turn.
function DuelAI.act(duel, p)
  if duel.finished or duel.current ~= p then return false end
  local pl = duel.players[p]
  pl.flags.aiTrainers = pl.flags.aiTrainers or 0
  pl.flags.aiPowers = pl.flags.aiPowers or 0

  -- 1. bench Basics (keep one hand Basic back only when the bench is full)
  local basics = actionsOfKind(duel, p, "playBasic")
  if #basics > 0 then
    local best = basics[1]
    for _, a in ipairs(basics) do if duel:card(a.card).hp > duel:card(best.card).hp then best = a end end
    duel:playBasic(p, best.card); return true
  end
  -- 2. evolve, active first
  local evos = actionsOfKind(duel, p, "evolve")
  if #evos > 0 then
    table.sort(evos, function(a, b) return a.location < b.location end)
    duel:evolve(p, evos[1].card, evos[1].location); return true
  end
  -- 3. energy
  local e = DuelAI.chooseEnergy(duel, p)
  if e then duel:attachEnergy(p, e.card, e.location); return true end
  -- 4. trainers (bounded per turn so Item Finder loops cannot spin)
  if pl.flags.aiTrainers < 6 then
    local id, args = DuelAI.chooseTrainer(duel, p)
    if id then pl.flags.aiTrainers = pl.flags.aiTrainers + 1; duel:playTrainer(p, id, args); return true end
  end
  -- 5. powers
  if pl.flags.aiPowers < 3 then
    local powers = actionsOfKind(duel, p, "usePower")
    if #powers > 0 then pl.flags.aiPowers = pl.flags.aiPowers + 1; duel:usePower(p, powers[1].location); return true end
  end
  -- 6. retreat
  local loc = DuelAI.retreatChoice(duel, p)
  if loc then duel:retreat(p, loc); return true end
  -- 7. attack
  local best, bestScore = nil, 0
  for i, atk in ipairs(duel:card(pl.active.card).attacks) do
    local ok = false
    for _, a in ipairs(actionsOfKind(duel, p, "attack")) do if a.index == i then ok = true end end
    if ok then
      local s = DuelAI.scoreAttack(duel, p, atk, i)
      if s > bestScore then best, bestScore = i, s end
    end
  end
  if best then duel:attack(p, best); return true end
  duel:endTurn()
  return false
end

function DuelAI.takeTurn(duel, p)
  local guard = 0
  while duel.current == p and not duel.finished do
    DuelAI.act(duel, p)
    guard = guard + 1
    if guard > 60 then duel:endTurn() end
  end
end

return DuelAI
