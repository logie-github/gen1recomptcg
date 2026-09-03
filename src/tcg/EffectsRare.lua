-- Explicit handlers for the attacks whose rules text no pattern matches
-- (docs/tcg-phase1.md).  Each of these needs game state the text-inference
-- layer has no way to express: an opponent's hand, a previous turn's damage,
-- another card's attack, or a random redistribution.
--
-- Choices default the way the rest of the engine does -- first legal target
-- unless `args` names one -- and each handler says what it defaults to.

local Effects = require("src.tcg.Effects")

local register = Effects.registerAttack

local function slots(duel, p) return duel:slots(p) end

local function isBasic(duel, id)
  local c = duel:card(id)
  return c.kind == "pokemon" and c.stage == "BASIC"
end

-- Ninetales LV35, Lure: the opponent shuffles a Basic or Evolution from hand
-- into their deck if they have one.  Headless default: the first such card.
register("NINETALES_LV35", 1, { after = function(ctx)
  local opp = ctx.duel.players[ctx.opponent]
  for i, id in ipairs(opp.hand) do
    if ctx.duel:card(id).kind == "pokemon" then
      table.remove(opp.hand, i)
      opp.deck[#opp.deck + 1] = id
      ctx.duel:shuffle(ctx.opponent)
      ctx.duel:say("  a Pokemon card is shuffled back into the deck")
      return
    end
  end
end })

-- Moltres LV35, Dive Bomb: discard any number of Fire Energy for +10 each.
-- Default: discard nothing, since spending energy is a judgement call the
-- caller should make; args.discard says how many to spend.
register("MOLTRES_LV35", 1, { before = function(ctx)
  local want = ctx.args and ctx.args.discard or 0
  local pl = ctx.duel.players[ctx.player]
  local discarded = 0
  for i = #ctx.attacker.energy, 1, -1 do
    if discarded >= want then break end
    local id = ctx.attacker.energy[i]
    if ctx.duel:card(id).type == "TYPE_ENERGY_FIRE" then
      table.remove(ctx.attacker.energy, i)
      pl.discard[#pl.discard + 1] = id
      discarded = discarded + 1
    end
  end
  ctx.damage = ctx.damage + discarded * 10
end })

-- Magnemite LV15, Magnetic Storm: pool every Energy on your side and deal it
-- back out at random.
register("MAGNEMITE_LV15", 2, { after = function(ctx)
  local duel = ctx.duel
  local mine = slots(duel, ctx.player)
  local pool = {}
  for _, slot in ipairs(mine) do
    for _, id in ipairs(slot.energy) do pool[#pool + 1] = id end
    slot.energy = {}
  end
  for _, id in ipairs(pool) do
    local target = mine[duel.rng:int(1, #mine)]
    target.energy[#target.energy + 1] = id
  end
  duel:say("  Energy is reattached at random")
end })

-- Zapdos LV40, Thunderstorm: a coin per benched opponent, 20 to each head,
-- then 10 to Zapdos for each tail.
register("ZAPDOS_LV40", 1, { after = function(ctx)
  local duel = ctx.duel
  local tails = 0
  for _, slot in ipairs(duel.players[ctx.opponent].bench) do
    if duel:coin("Thunderstorm") then
      duel:dealDamage(ctx.opponent, slot, 20, "bench")
    else
      tails = tails + 1
    end
  end
  if tails > 0 then
    duel:dealDamage(ctx.player, ctx.attacker, tails * 10, "recoil")
  end
end })

-- Marowak LV32, Call for Friend: both players fill their Bench with random
-- Basics from their decks.
register("MAROWAK_LV32", 2, { after = function(ctx)
  local duel = ctx.duel
  for _, p in ipairs({ ctx.player, ctx.opponent }) do
    local pl = duel.players[p]
    duel:shuffle(p)
    while #pl.bench < 5 do
      local picked
      for i, id in ipairs(pl.deck) do
        if isBasic(duel, id) then picked = i; break end
      end
      if not picked then break end
      local id = table.remove(pl.deck, picked)
      pl.hand[#pl.hand + 1] = id
      local saved = duel.current
      duel.current = p
      duel:playBasic(p, id)
      duel.current = saved
    end
    duel:shuffle(p)
  end
end })

-- Hypno, Prophecy: look at up to 3 cards from the top of either deck and
-- reorder them.  Headless default: leave the order alone; args.order and
-- args.player let a caller rearrange.
register("HYPNO", 1, { after = function(ctx)
  local duel = ctx.duel
  local p = (ctx.args and ctx.args.player) or ctx.player
  local order = ctx.args and ctx.args.order
  if not order then return end
  local pl = duel.players[p]
  local top = {}
  for i = 1, math.min(3, #pl.deck) do top[i] = table.remove(pl.deck, 1) end
  for i = #order, 1, -1 do
    if top[order[i]] then table.insert(pl.deck, 1, top[order[i]]) end
  end
end })

-- Mew LV15, Psywave: random damage in 10s up to 60, and a random condition.
register("MEW_LV15", 1, { before = function(ctx)
  ctx.damage = ctx.duel.rng:int(0, 6) * 10
end, after = function(ctx)
  local roll = ctx.duel.rng:int(1, 4)
  local status = ({ "asleep", "confused", "paralyzed" })[roll]
  if status then ctx.duel:setStatus(ctx.defender, status) end
end })

-- Mew LV23, Devolution Beam: return the top evolution card of a chosen
-- evolved Pokemon to its owner's hand.  Default: the opponent's active if it
-- is evolved, else the first evolved Pokemon in play.
register("MEW_LV23", 2, { after = function(ctx)
  local duel = ctx.duel
  local function evolved(slot) return slot and #slot.stack > 1 end
  local target, owner
  local chosen = ctx.args and ctx.args.location
  if chosen then
    owner = ctx.args.player or ctx.opponent
    target = duel:slotAt(owner, chosen)
  end
  if not evolved(target) then
    target, owner = nil, nil
    for _, p in ipairs({ ctx.opponent, ctx.player }) do
      for _, slot in ipairs(slots(duel, p)) do
        if evolved(slot) then target, owner = slot, p; break end
      end
      if target then break end
    end
  end
  if not target then return end
  local pl = duel.players[owner]
  local damage = duel:card(target.card).hp - target.hp
  local top = table.remove(target.stack)
  pl.hand[#pl.hand + 1] = top
  target.card = target.stack[#target.stack]
  target.hp = math.max(0, duel:card(target.card).hp - damage)
  duel:cure(target)
  duel:clearSubs(target)
  duel:say("  %s devolves", duel:card(target.card).name)
end })

-- Mirror Move (Pidgeotto, Spearow): repeat the last attack's final result on
-- this Pokemon back at the defender.  Duel.lua records that on each slot.
local mirrorMove = { before = function(ctx)
  local taken = ctx.attacker.lastDamageTaken
  if not taken or taken <= 0 then
    ctx.cancelled = true
    ctx.duel:say("  there was nothing to copy")
    return
  end
  ctx.damage = taken
  ctx.ignoreWR = true
end }
register("PIDGEOTTO", 2, mirrorMove)
register("SPEAROW", 2, mirrorMove)

-- Pidgeot LV40, Hurricane: unless it Knocks Out, the defender and everything
-- on it go back to the owner's hand.
register("PIDGEOT_LV40", 2, { after = function(ctx)
  local duel = ctx.duel
  local defender = ctx.defender
  if defender.hp <= 0 then return end
  local opp = duel.players[ctx.opponent]
  if opp.active ~= defender or #opp.bench == 0 then return end
  for _, id in ipairs(defender.energy) do opp.hand[#opp.hand + 1] = id end
  for _, id in ipairs(defender.stack) do opp.hand[#opp.hand + 1] = id end
  opp.active = table.remove(opp.bench, 1)
  duel:say("  the Defending Pokemon returns to the hand")
end })

-- Metronome (Clefairy, Clefable): copy one of the defender's attacks, paying
-- this attack's cost instead.  Default: the defender's highest-damage attack.
local function metronome(ctx)
  local duel = ctx.duel
  local card = duel:card(ctx.defender.card)
  local pick, best = nil, -1
  local wanted = ctx.args and ctx.args.attack
  for i, atk in ipairs(card.attacks) do
    if atk.category ~= "POKEMON_POWER" then
      if wanted == i then pick = atk end
      if not wanted and atk.damage > best then pick, best = atk, atk.damage end
    end
  end
  if not pick then
    ctx.cancelled = true
    duel:say("  there was no attack to copy")
    return
  end
  duel:say("  Metronome copies %s", pick.name)
  ctx.damage = pick.damage
  -- the copied attack's own effect runs through the same dispatcher
  ctx.copied = pick
end
register("CLEFAIRY", 2, { before = metronome })
register("CLEFABLE", 1, { before = metronome })

-- Porygon, Conversion 1 and 2: change the defender's Weakness, or Porygon's
-- own Resistance, to a chosen type.  Default: the attacker's own type for
-- weakness, and Colorless-avoiding first choice for resistance.
local TYPES = { "FIRE", "GRASS", "LIGHTNING", "WATER", "FIGHTING", "PSYCHIC" }

register("PORYGON", 1, { after = function(ctx)
  local defender = ctx.defender
  if #(defender.weaknessOverride or ctx.duel:card(defender.card).weakness) == 0 then
    ctx.duel:say("  it has no Weakness to change")
    return
  end
  local want = (ctx.args and ctx.args.type) or TYPES[ctx.duel.rng:int(1, #TYPES)]
  defender.weaknessOverride = { want }
  ctx.duel:say("  Weakness becomes %s", want)
end })

register("PORYGON", 2, { after = function(ctx)
  local want = (ctx.args and ctx.args.type) or TYPES[ctx.duel.rng:int(1, #TYPES)]
  ctx.attacker.resistanceOverride = { want }
  ctx.duel:say("  Resistance becomes %s", want)
end })

return true
