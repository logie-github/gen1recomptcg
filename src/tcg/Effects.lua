-- Attack and Trainer effect handlers for the duel engine.
--
-- poketcg implements every card effect as a small effect-command program
-- (engine/duel/effect_functions.asm, ~200 routines); this file is the Lua
-- home for those ports, keyed by card constant and attack index.  A card
-- without a handler deals its printed damage and logs that the effect is
-- unported, so unfinished coverage degrades to "vanilla damage" instead of
-- crashing a duel.
--
-- Handler shape (attacks):
--   before = function(ctx)  -- may set ctx.damage, ctx.cancelled, ctx.ignoreWR
--   after  = function(ctx)  -- runs once damage has landed (ctx.dealt)
-- ctx: duel, player, opponent, attacker (slot), defender (slot), attack,
--      card, damage, cancelled, dealt.
--
-- Trainers: { can = function(duel, p, id) -> bool, play = function(duel, p, id, args) }

local Effects = {}

local attacks = {}     -- "CONSTANT:index" -> handler
local trainers = {}    -- "CONSTANT" -> handler
local warned = {}

local function key(constant, index) return constant .. ":" .. index end

function Effects.registerAttack(constant, index, handler) attacks[key(constant, index)] = handler end
function Effects.registerTrainer(constant, handler) trainers[constant] = handler end

local function attackIndex(ctx)
  for i, a in ipairs(ctx.card.attacks) do if a == ctx.attack then return i end end
end

local function handlerFor(ctx)
  local h = attacks[key(ctx.card.constant, attackIndex(ctx))]
  if not h and (ctx.attack.description or "") ~= "" then
    local k = key(ctx.card.constant, attackIndex(ctx))
    if not warned[k] then
      warned[k] = true
      ctx.duel:say("  (effect of %s not ported; plain damage)", ctx.attack.name)
    end
  end
  return h
end

function Effects.beforeDamage(ctx)
  local h = handlerFor(ctx)
  if h and h.before then h.before(ctx) end
end

function Effects.afterDamage(ctx)
  local h = handlerFor(ctx)
  if h and h.after then h.after(ctx) end
  -- Machamp's Strikes Back is a defender-side power: see registerPower below
  local power = Effects.defenderPower(ctx)
  if power and ctx.dealt and ctx.dealt > 0 then power(ctx) end
end

-- ---------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------

local function inflict(ctx, status, label)
  local d = ctx.defender
  local name = ctx.duel:card(d.card).name
  if status == "poison" then
    d.poison = math.max(d.poison, 1)
  elseif status == "doublePoison" then
    d.poison = 2
  else
    d.status = status
  end
  ctx.duel:say("  %s is now %s", name, label or status)
end

local function coinInflict(status, label)
  return { after = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then inflict(ctx, status, label) end
  end }
end

local function coinPlus(extra)
  return { before = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then ctx.damage = ctx.damage + extra end
  end }
end

-- ---------------------------------------------------------------------
-- attack handlers (practice decks first; extend freely)
-- ---------------------------------------------------------------------

Effects.registerAttack("ABRA", 1, coinInflict("paralyzed", "Paralyzed"))
Effects.registerAttack("DEWGONG", 2, coinInflict("paralyzed", "Paralyzed"))
Effects.registerAttack("DROWZEE", 2, coinInflict("confused", "Confused"))
Effects.registerAttack("LAPRAS", 2, coinInflict("confused", "Confused"))
Effects.registerAttack("ALAKAZAM", 2, coinInflict("confused", "Confused"))
Effects.registerAttack("STARMIE", 2, coinInflict("paralyzed", "Paralyzed"))
Effects.registerAttack("EEVEE", 2, coinPlus(20))
Effects.registerAttack("JOLTEON_LV29", 1, coinPlus(20))

-- Super Fang: half the Defending Pokemon's remaining HP, rounded up to 10
Effects.registerAttack("RATICATE", 2, { before = function(ctx)
  local hp = ctx.defender.hp
  ctx.damage = math.ceil(hp / 20) * 10
end })

-- Water Gun: +10 per extra Water energy beyond the cost, max +20
Effects.registerAttack("LAPRAS", 1, { before = function(ctx)
  local have = ctx.duel:energyProvided(ctx.attacker).WATER
  local extra = math.max(0, have - (ctx.attack.energy.WATER or 0))
  ctx.damage = ctx.damage + math.min(20, extra * 10)
end })

-- Dark Mind: 10 to one benched Pokemon (first bench slot when no choice is given)
Effects.registerAttack("HYPNO", 2, { after = function(ctx)
  local opp = ctx.duel.players[ctx.opponent]
  local target = opp.bench[ctx.benchTarget or 1]
  if target then ctx.duel:dealDamage(ctx.opponent, target, 10, "Dark Mind bench") end
end })

-- Ram: 20 to self (no W/R), then the opponent switches the Defending Pokemon
Effects.registerAttack("RHYDON", 2, { after = function(ctx)
  ctx.duel:dealDamage(ctx.player, ctx.attacker, 20, "Ram recoil")
  local opp = ctx.duel.players[ctx.opponent]
  if #opp.bench > 0 and opp.active.hp > 0 then
    local slot = table.remove(opp.bench, 1)
    opp.bench[#opp.bench + 1] = opp.active
    opp.active = slot
    ctx.duel:say("  %s is switched in", ctx.duel:card(slot.card).name)
  end
end })

-- Pin Missile: 20 x number of heads out of 4
Effects.registerAttack("JOLTEON_LV29", 2, { before = function(ctx)
  local heads = 0
  for _ = 1, 4 do if ctx.duel:coin("Pin Missile") then heads = heads + 1 end end
  ctx.damage = 20 * heads
end })

-- Earthquake: 10 to each of your own benched Pokemon
Effects.registerAttack("DUGTRIO", 2, { after = function(ctx)
  for _, s in ipairs(ctx.duel.players[ctx.player].bench) do
    ctx.duel:dealDamage(ctx.player, s, 10, "Earthquake")
  end
end })

-- Submission: 20 to self
Effects.registerAttack("MACHOKE", 2, { after = function(ctx)
  ctx.duel:dealDamage(ctx.player, ctx.attacker, 20, "Submission recoil")
end })

-- Thunder: tails -> 30 to self
Effects.registerAttack("RAICHU_LV40", 2, { after = function(ctx)
  if not ctx.duel:coin("Thunder") then
    ctx.duel:dealDamage(ctx.player, ctx.attacker, 30, "Thunder recoil")
  end
end })

-- Thunder Jolt: tails -> 10 to self
Effects.registerAttack("PIKACHU_LV12", 2, { after = function(ctx)
  if not ctx.duel:coin("Thunder Jolt") then
    ctx.duel:dealDamage(ctx.player, ctx.attacker, 10, "Thunder Jolt recoil")
  end
end })

-- Thundershock / Thunderpunch (Electabuzz Lv35)
Effects.registerAttack("ELECTABUZZ_LV35", 1, coinInflict("paralyzed", "Paralyzed"))
Effects.registerAttack("ELECTABUZZ_LV35", 2, { before = function(ctx)
  if ctx.duel:coin("Thunderpunch") then ctx.damage = ctx.damage + 10
  else ctx.selfDamage = 10 end
end, after = function(ctx)
  if ctx.selfDamage then ctx.duel:dealDamage(ctx.player, ctx.attacker, ctx.selfDamage, "Thunderpunch recoil") end
end })

-- Special Punch, Jab, Low Kick, Bite, Slash, Horn Attack, Headbutt, Pound,
-- Slap, Seismic Toss, Aurora Beam, Karate Chop: plain damage, no handler.

-- Recover (Kadabra/Starmie): discard 1 Psychic/Water energy, heal all damage
local function recover(energyType)
  return { before = function(ctx)
    ctx.cancelled = true
    local a = ctx.attacker
    for i, id in ipairs(a.energy) do
      local c = ctx.duel:card(id)
      if c.type == energyType then
        table.remove(a.energy, i)
        ctx.duel.players[ctx.player].discard[#ctx.duel.players[ctx.player].discard + 1] = id
        break
      end
    end
    a.hp = ctx.duel:card(a.card).hp
    ctx.duel:say("  %s recovers all its HP", ctx.duel:card(a.card).name)
  end }
end
Effects.registerAttack("KADABRA", 1, recover("TYPE_ENERGY_PSYCHIC"))
Effects.registerAttack("STARMIE", 1, recover("TYPE_ENERGY_WATER"))

-- ---------------------------------------------------------------------
-- defender-side powers
-- ---------------------------------------------------------------------

local powers = {}
function Effects.registerPower(constant, fn) powers[constant] = fn end

function Effects.defenderPower(ctx)
  local d = ctx.defender
  if not d or d.hp == nil then return nil end
  local c = ctx.duel:card(d.card)
  local fn = powers[c.constant]
  if fn and d.status == "none" then return fn end
  return nil
end

-- Strikes Back: 10 to the attacker whenever Machamp is damaged (no W/R)
Effects.registerPower("MACHAMP", function(ctx)
  ctx.duel:say("  Strikes Back!")
  ctx.duel:dealDamage(ctx.player, ctx.attacker, 10, "Strikes Back")
end)

-- ---------------------------------------------------------------------
-- trainers
-- ---------------------------------------------------------------------

local function damaged(slot, duel) return slot.hp < duel:card(slot.card).hp end

Effects.registerTrainer("BILL", {
  can = function(duel, p) return #duel.players[p].deck > 0 end,
  play = function(duel, p) duel:draw(p, 2) end,
})

Effects.registerTrainer("PROFESSOR_OAK", {
  can = function(duel, p) return #duel.players[p].deck > 0 end,
  play = function(duel, p, id)
    local pl = duel.players[p]
    for _, h in ipairs(pl.hand) do pl.discard[#pl.discard + 1] = h end
    pl.hand = {}
    duel:draw(p, 7)
  end,
})

local function heal(amount)
  return {
    can = function(duel, p)
      for _, s in ipairs(duel:slots(p)) do if damaged(s, duel) then return true end end
      return false
    end,
    play = function(duel, p, id, args)
      local slot = duel:slotAt(p, args.location or 0)
      if not slot or not damaged(slot, duel) then
        for _, s in ipairs(duel:slots(p)) do if damaged(s, duel) then slot = s; break end end
      end
      local max = duel:card(slot.card).hp
      slot.hp = math.min(max, slot.hp + amount)
      duel:say("  %s is healed to %d", duel:card(slot.card).name, slot.hp)
    end,
  }
end
Effects.registerTrainer("POTION", heal(20))

Effects.registerTrainer("SUPER_POTION", {
  can = function(duel, p)
    for _, s in ipairs(duel:slots(p)) do
      if damaged(s, duel) and #s.energy > 0 then return true end
    end
    return false
  end,
  play = function(duel, p, id, args)
    local slot = duel:slotAt(p, args.location or 0)
    if not (slot and damaged(slot, duel) and #slot.energy > 0) then
      for _, s in ipairs(duel:slots(p)) do
        if damaged(s, duel) and #s.energy > 0 then slot = s; break end
      end
    end
    local e = table.remove(slot.energy)
    duel.players[p].discard[#duel.players[p].discard + 1] = e
    slot.hp = math.min(duel:card(slot.card).hp, slot.hp + 40)
    duel:say("  %s is healed to %d", duel:card(slot.card).name, slot.hp)
  end,
})

Effects.registerTrainer("FULL_HEAL", {
  can = function(duel, p)
    local a = duel.players[p].active
    return a.status ~= "none" or a.poison > 0
  end,
  play = function(duel, p)
    local a = duel.players[p].active
    a.status, a.poison = "none", 0
    duel:say("  %s is cured", duel:card(a.card).name)
  end,
})

Effects.registerTrainer("SWITCH", {
  can = function(duel, p) return #duel.players[p].bench > 0 end,
  play = function(duel, p, id, args)
    local pl = duel.players[p]
    local loc = args.location or 1
    local slot = table.remove(pl.bench, loc)
    pl.bench[#pl.bench + 1] = pl.active
    pl.active.status, pl.active.poison = "none", 0
    pl.active = slot
    duel:say("  %s switches in", duel:card(slot.card).name)
  end,
})

Effects.registerTrainer("GUST_OF_WIND", {
  can = function(duel, p) return #duel.players[duel:opponentOf(p)].bench > 0 end,
  play = function(duel, p, id, args)
    local opp = duel.players[duel:opponentOf(p)]
    local slot = table.remove(opp.bench, args.location or 1)
    opp.bench[#opp.bench + 1] = opp.active
    opp.active.status, opp.active.poison = "none", 0
    opp.active = slot
    duel:say("  %s is dragged into the Arena", duel:card(slot.card).name)
  end,
})

Effects.registerTrainer("PLUSPOWER", {
  can = function() return true end,
  play = function(duel, p) duel.players[p].active.plusPower = duel.players[p].active.plusPower + 1 end,
})

Effects.registerTrainer("DEFENDER", {
  can = function() return true end,
  play = function(duel, p, id, args)
    local slot = duel:slotAt(p, args.location or 0)
    slot.defender = slot.defender + 1
  end,
})

Effects.registerTrainer("ENERGY_REMOVAL", {
  can = function(duel, p)
    for _, s in ipairs(duel:slots(duel:opponentOf(p))) do if #s.energy > 0 then return true end end
    return false
  end,
  play = function(duel, p, id, args)
    local opp = duel:opponentOf(p)
    local slot = duel:slotAt(opp, args.location or 0)
    if not (slot and #slot.energy > 0) then
      for _, s in ipairs(duel:slots(opp)) do if #s.energy > 0 then slot = s; break end end
    end
    local e = table.remove(slot.energy)
    duel.players[opp].discard[#duel.players[opp].discard + 1] = e
    duel:say("  %s loses %s", duel:card(slot.card).name, duel:card(e).name)
  end,
})

-- ---------------------------------------------------------------------

function Effects.canPlayTrainer(duel, p, id)
  local c = duel:card(id)
  local h = trainers[c.constant]
  if not h then return false end       -- unported trainers are unplayable, not silently no-ops
  return h.can(duel, p, id)
end

function Effects.playTrainer(duel, p, id, args)
  local h = trainers[duel:card(id).constant]
  return h.play(duel, p, id, args)
end

function Effects.hasTrainer(constant) return trainers[constant] ~= nil end
function Effects.hasAttack(constant, index) return attacks[key(constant, index)] ~= nil end

return Effects
