-- Pokemon Powers (docs/tcg-phase1.md, Phase 4).
--
-- Four hook families, all consulted by Duel.lua:
--   passive   immuneToStatus, incomingDamage, preventsAttack, evolutionBlocked,
--             retreatDiscount, and the Muk switch (`active`) that silences every
--             other power while Muk is in play
--   onPlay    Firegiver, Quickfreeze, Peal of Thunder, Healing Wind
--   activated `use` powers exposed as { kind = "usePower", location } actions:
--             Solar Power, Energy Trans, Heal, Energy Burn, Rain Dance,
--             Cowardice, Damage Swap, Strange Behavior, Curse, Step In
--   defender  Strikes Back lives in Effects.lua (fires after damage lands)
--
-- Powers stop working while the Pokemon is Asleep, Confused or Paralyzed
-- (every card says so); `working` centralises that plus Muk.  Choices in
-- headless play take the first legal target; `args` lets a UI override.

local Powers = {}

local registry = {}   -- constant -> spec

function Powers.register(constant, spec) registry[constant] = spec end

local function spec(duel, slot)
  return registry[duel:card(slot.card).constant]
end

-- Muk's Toxic Gas: ignore all other Pokemon Powers while a working Muk is in play
function Powers.active(duel)
  for p = 1, 2 do
    for _, s in ipairs(duel:slots(p)) do
      if duel:card(s.card).constant == "MUK" and s.status == "none" then return false end
    end
  end
  return true
end

local function working(duel, slot, ignoreMuk)
  if slot.status ~= "none" then return false end
  local sp = spec(duel, slot)
  if not sp then return false end
  if not ignoreMuk and not sp.mukImmune and not Powers.active(duel) then return false end
  return sp
end

-- ---------------------------------------------------------------------
-- passive
-- ---------------------------------------------------------------------

function Powers.immuneToStatus(duel, slot)
  local sp = working(duel, slot)
  return sp and sp.immuneToStatus or false
end

-- Applied after weakness/resistance and substatuses, before damage lands.
function Powers.incomingDamage(duel, defender, attacker, damage)
  if damage <= 0 then return 0 end
  local sp = working(duel, defender)
  if sp and sp.incomingDamage then return sp.incomingDamage(duel, defender, attacker, damage) end
  return damage
end

-- Whole-attack prevention (Transparency's coin, Neutralizing Shield).
function Powers.preventsAttack(duel, defender, attacker)
  local sp = working(duel, defender)
  if sp and sp.preventsAttack then return sp.preventsAttack(duel, defender, attacker) end
  return false
end

function Powers.evolutionBlocked(duel)
  for p = 1, 2 do
    for _, s in ipairs(duel:slots(p)) do
      local sp = working(duel, s)
      if sp and sp.blocksEvolution then return true end
    end
  end
  return false
end

function Powers.retreatDiscount(duel, p)
  local n = 0
  for _, s in ipairs(duel.players[p].bench) do
    local sp = working(duel, s)
    if sp and sp.retreatDiscount then n = n + sp.retreatDiscount end
  end
  return n
end

-- ---------------------------------------------------------------------
-- on play
-- ---------------------------------------------------------------------

function Powers.onPlay(duel, p, slot)
  local sp = working(duel, slot)
  if sp and sp.onPlay then sp.onPlay(duel, p, slot) end
end

-- ---------------------------------------------------------------------
-- activated
-- ---------------------------------------------------------------------

function Powers.canUse(duel, p, slot)
  if duel.finished or duel.current ~= p then return false end
  if duel.players[p].flags.attacked then return false end
  local sp = working(duel, slot)
  if not (sp and sp.use) then return false end
  if sp.oncePerTurn and slot.powerUsedTurn == duel.turn then return false end
  if sp.can and not sp.can(duel, p, slot) then return false end
  return true
end

function Powers.use(duel, p, slot, args)
  local sp = working(duel, slot)
  local name = "power"
  for _, atk in ipairs(duel:card(slot.card).attacks) do
    if atk.category == "POKEMON_POWER" then name = atk.name end
  end
  duel:say("%s uses %s", duel:card(slot.card).name, name)
  local ok, err = sp.use(duel, p, slot, args or {})
  if ok ~= false and sp.oncePerTurn then slot.powerUsedTurn = duel.turn end
  return ok, err
end

function Powers.has(constant) return registry[constant] ~= nil end

-- ---------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------

local function maxHp(duel, slot) return duel:card(slot.card).hp end
local function damaged(duel, slot) return slot.hp < maxHp(duel, slot) end

local function moveEnergy(from, to, id)
  for i, e in ipairs(from.energy) do
    if e == id then table.remove(from.energy, i); to.energy[#to.energy + 1] = id; return true end
  end
  return false
end

local function firstDamaged(duel, p, exclude)
  for _, s in ipairs(duel:slots(p)) do
    if s ~= exclude and damaged(duel, s) then return s end
  end
end

local function isEvolved(duel, slot) return duel:card(slot.card).stage ~= "BASIC" end

-- ---------------------------------------------------------------------
-- the cards
-- ---------------------------------------------------------------------

-- Muk: Toxic Gas (see Powers.active); immune to its own effect
Powers.register("MUK", { mukImmune = true })

-- Snorlax: Thick Skinned
Powers.register("SNORLAX", { immuneToStatus = true })

-- Kabuto: Kabuto Armor -- half damage, rounded down to 10
Powers.register("KABUTO", { incomingDamage = function(duel, defender, attacker, damage)
  return math.floor(damage / 20) * 10
end })

-- Mr. Mime: Invisible Wall -- prevent 30 or more
Powers.register("MR_MIME", { incomingDamage = function(duel, defender, attacker, damage)
  if damage >= 30 then duel:say("  Invisible Wall prevents the damage"); return 0 end
  return damage
end })

-- Haunter LV17: Transparency -- coin; heads prevents everything
Powers.register("HAUNTER_LV17", { preventsAttack = function(duel, defender, attacker)
  return duel:coin("Transparency")
end })

-- Mew LV8: Neutralizing Shield -- nothing from evolved Pokemon
Powers.register("MEW_LV8", { preventsAttack = function(duel, defender, attacker)
  return isEvolved(duel, attacker)
end })

-- Aerodactyl: Prehistoric Power
Powers.register("AERODACTYL", { blocksEvolution = true })

-- Dodrio: Retreat Aid
Powers.register("DODRIO", { retreatDiscount = 1 })

-- Omanyte: Clairvoyance, Mankey: Peek -- information only; no engine effect
Powers.register("OMANYTE", {})
Powers.register("MANKEY", {})
-- Venomoth: Shift (type change) -- deferred; registered so it is not "unported"
Powers.register("VENOMOTH", {})

-- Moltres LV37: Firegiver -- 1-4 Fire energy from deck to hand
Powers.register("MOLTRES_LV37", { onPlay = function(duel, p, slot)
  local pl = duel.players[p]
  local want = duel.rng:int(1, 4)
  local got = 0
  for i = #pl.deck, 1, -1 do
    if got >= want then break end
    if duel:card(pl.deck[i]).type == "TYPE_ENERGY_FIRE" then
      pl.hand[#pl.hand + 1] = table.remove(pl.deck, i); got = got + 1
    end
  end
  duel:shuffle(p)
  duel:say("  Firegiver: %d Fire Energy to hand", got)
end })

-- Articuno LV37: Quickfreeze
Powers.register("ARTICUNO_LV37", { onPlay = function(duel, p, slot)
  local opp = duel.players[duel:opponentOf(p)]
  if opp.active and duel:coin("Quickfreeze") then duel:setStatus(opp.active, "paralyzed") end
end })

-- Zapdos LV68: Peal of Thunder -- 30 to a random other Pokemon, no W/R
Powers.register("ZAPDOS_LV68", { onPlay = function(duel, p, slot)
  local targets = {}
  for q = 1, 2 do
    for _, s in ipairs(duel:slots(q)) do
      if s ~= slot then targets[#targets + 1] = { q, s } end
    end
  end
  if #targets == 0 then return end
  local t = targets[duel.rng:int(1, #targets)]
  duel:dealDamage(t[1], t[2], 30, "Peal of Thunder")
  duel:checkKnockouts()
end })

-- Dragonite LV41: Healing Wind -- 20 off each of your Pokemon
Powers.register("DRAGONITE_LV41", { onPlay = function(duel, p, slot)
  for _, s in ipairs(duel:slots(p)) do
    s.hp = math.min(maxHp(duel, s), s.hp + 20)
  end
  duel:say("  Healing Wind")
end })

-- Venusaur LV64: Solar Power -- cure both actives, once per turn
Powers.register("VENUSAUR_LV64", { oncePerTurn = true,
  can = function(duel, p)
    local a, b = duel.players[p].active, duel.players[duel:opponentOf(p)].active
    local function ill(s) return s and (s.status ~= "none" or s.poison > 0) end
    return ill(a) or ill(b)
  end,
  use = function(duel, p)
    duel:cure(duel.players[p].active)
    local o = duel.players[duel:opponentOf(p)].active
    if o then duel:cure(o) end
  end })

-- Venusaur LV67: Energy Trans -- move a Grass energy between your Pokemon
Powers.register("VENUSAUR_LV67", {
  can = function(duel, p)
    local slots = duel:slots(p)
    if #slots < 2 then return false end
    for _, s in ipairs(slots) do
      for _, e in ipairs(s.energy) do
        if duel:card(e).type == "TYPE_ENERGY_GRASS" then return true end
      end
    end
    return false
  end,
  use = function(duel, p, slot, args)
    local from = duel:slotAt(p, args.from or 0)
    local to = duel:slotAt(p, args.to or 1)
    if not (from and to) or from == to then
      -- headless default: bench -> active
      to = duel.players[p].active
      for _, s in ipairs(duel.players[p].bench) do
        for _, e in ipairs(s.energy) do
          if duel:card(e).type == "TYPE_ENERGY_GRASS" then from = s end
        end
      end
      if not from then return false, "no Grass Energy to move" end
    end
    for _, e in ipairs(from.energy) do
      if duel:card(e).type == "TYPE_ENERGY_GRASS" then
        moveEnergy(from, to, e)
        duel:say("  Grass Energy moved to %s", duel:card(to.card).name)
        return true
      end
    end
    return false, "no Grass Energy there"
  end })

-- Vileplume: Heal -- coin, heads removes a damage counter, once per turn
Powers.register("VILEPLUME", { oncePerTurn = true,
  can = function(duel, p) return firstDamaged(duel, p) ~= nil end,
  use = function(duel, p, slot, args)
    local target = duel:slotAt(p, args.location or -1) or firstDamaged(duel, p)
    if duel:coin("Heal") then target.hp = math.min(maxHp(duel, target), target.hp + 10) end
  end })

-- Charizard: Energy Burn -- all attached energy is Fire for the turn
Powers.register("CHARIZARD", {
  can = function(duel, p, slot) return not duel:sub(slot, "energyBurn") and #slot.energy > 0 end,
  use = function(duel, p, slot) duel:setSub(slot, "energyBurn", true, duel.turn) end })

-- Blastoise: Rain Dance -- extra Water energy attachments to Water Pokemon
Powers.register("BLASTOISE", {
  can = function(duel, p)
    for _, id in ipairs(duel.players[p].hand) do
      if duel:card(id).type == "TYPE_ENERGY_WATER" then
        for _, s in ipairs(duel:slots(p)) do
          if duel:card(s.card).type == "TYPE_PKMN_WATER" then return true end
        end
      end
    end
    return false
  end,
  use = function(duel, p, slot, args)
    local pl = duel.players[p]
    local target = duel:slotAt(p, args.location or -1)
    if not target or duel:card(target.card).type ~= "TYPE_PKMN_WATER" then
      for _, s in ipairs(duel:slots(p)) do
        if duel:card(s.card).type == "TYPE_PKMN_WATER" then target = s; break end
      end
    end
    for i, id in ipairs(pl.hand) do
      if duel:card(id).type == "TYPE_ENERGY_WATER" then
        table.remove(pl.hand, i)
        target.energy[#target.energy + 1] = id
        duel:say("  Rain Dance attaches Water Energy to %s", duel:card(target.card).name)
        return true
      end
    end
    return false
  end })

-- Tentacool: Cowardice -- return to hand (not the turn it was played)
Powers.register("TENTACOOL", {
  can = function(duel, p, slot)
    return slot.turnPlayed ~= duel.turn and (slot ~= duel.players[p].active or #duel.players[p].bench > 0)
  end,
  use = function(duel, p, slot)
    local pl = duel.players[p]
    for _, e in ipairs(slot.energy) do pl.discard[#pl.discard + 1] = e end
    for i = 1, #slot.stack - 1 do pl.discard[#pl.discard + 1] = slot.stack[i] end
    pl.hand[#pl.hand + 1] = slot.stack[#slot.stack]
    if pl.active == slot then
      pl.active = table.remove(pl.bench, 1)
    else
      for i, s in ipairs(pl.bench) do if s == slot then table.remove(pl.bench, i) break end end
    end
    duel:say("  Tentacool returns to the hand")
  end })

-- Alakazam: Damage Swap -- move 10 damage between your Pokemon without KO
local function moveDamage(duel, from, to)
  if from.hp >= maxHp(duel, from) then return false end
  if to.hp <= 10 then return false end
  from.hp = from.hp + 10
  to.hp = to.hp - 10
  duel:say("  10 damage moved from %s to %s", duel:card(from.card).name, duel:card(to.card).name)
  return true
end

Powers.register("ALAKAZAM", {
  can = function(duel, p)
    local from = firstDamaged(duel, p)
    if not from then return false end
    for _, s in ipairs(duel:slots(p)) do if s ~= from and s.hp > 10 then return true end end
    return false
  end,
  use = function(duel, p, slot, args)
    local from = duel:slotAt(p, args.from or -1) or firstDamaged(duel, p)
    local to = duel:slotAt(p, args.to or -1)
    if not to or to == from or to.hp <= 10 then
      to = nil
      local best = 0
      for _, s in ipairs(duel:slots(p)) do
        if s ~= from and s.hp > best then to, best = s, s.hp end
      end
    end
    if not (from and to) then return false, "no legal move" end
    return moveDamage(duel, from, to)
  end })

-- Slowbro: Strange Behavior -- move 10 damage from another Pokemon onto Slowbro
Powers.register("SLOWBRO", {
  can = function(duel, p, slot) return slot.hp > 10 and firstDamaged(duel, p, slot) ~= nil end,
  use = function(duel, p, slot, args)
    local from = duel:slotAt(p, args.from or -1) or firstDamaged(duel, p, slot)
    if not from or from == slot then return false, "nothing to move" end
    return moveDamage(duel, from, slot)
  end })

-- Gengar: Curse -- move 10 damage between opponent's Pokemon, once per turn
Powers.register("GENGAR", { oncePerTurn = true,
  can = function(duel, p)
    local o = duel:opponentOf(p)
    return firstDamaged(duel, o) ~= nil and #duel:slots(o) >= 2
  end,
  use = function(duel, p, slot, args)
    local o = duel:opponentOf(p)
    local from = duel:slotAt(o, args.from or -1) or firstDamaged(duel, o)
    local to = duel:slotAt(o, args.to or -1)
    if not to or to == from then
      to = duel.players[o].active ~= from and duel.players[o].active or duel.players[o].bench[1]
    end
    if not (from and to) or to == from then return false, "no target" end
    from.hp = from.hp + 10
    to.hp = to.hp - 10    -- Curse may Knock Out
    duel:say("  Curse moves 10 damage to %s", duel:card(to.card).name)
    return true
  end })

-- Dragonite LV45: Step In -- swap benched Dragonite into the Arena
Powers.register("DRAGONITE_LV45", { oncePerTurn = true,
  can = function(duel, p, slot) return slot ~= duel.players[p].active end,
  use = function(duel, p, slot)
    local pl = duel.players[p]
    for i, s in ipairs(pl.bench) do
      if s == slot then
        pl.bench[i] = pl.active
        duel:cure(pl.active)
        duel:clearSubs(pl.active)
        pl.active = slot
        duel:say("  Dragonite steps in")
        return true
      end
    end
    return false
  end })

return Powers
