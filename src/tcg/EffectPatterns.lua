-- Attack effects inferred from rules text.
--
-- poketcg encodes each attack effect as a hand-written routine, but the
-- English text on the cards follows a small set of stock phrasings ("Flip a
-- coin. If heads, the Defending Pokémon is now Paralyzed.", "Flip 3 coins.
-- This attack does 20 damage times the number of heads.", ...).  This module
-- turns those phrasings into handlers so the common cases are covered
-- without a per-card port, and so any card with the same wording gets the
-- same behaviour.  Explicit handlers registered in Effects.lua win over an
-- inferred one; an attack whose text matches nothing here still deals its
-- printed damage.
--
-- Every inferred behaviour is a composition of the same primitives the
-- explicit ports use (coin, status, substatus, bench damage, energy
-- discard), so the semantics stay in Duel.lua.  Text-derived matching is a
-- heuristic: docs/tcg-phase1.md lists what it covers, and the test suite
-- reports which attacks resolve through it.

local Patterns = {}
local unpack = table.unpack or unpack

-- é in UTF-8 is two bytes; "Pok..mon" matches either encoding.
local POKEMON = "Pok..mon"

local STATUS = {
  Paralyzed = { "paralyzed", "Paralyzed" },
  Confused = { "confused", "Confused" },
  Asleep = { "asleep", "Asleep" },
  Poisoned = { "poison", "Poisoned" },
}

local function norm(text)
  -- collapse line breaks and double spaces so patterns see one sentence run
  return (text or ""):gsub("\n", " "):gsub("  +", " ")
end

local function applyStatus(ctx, name)
  local s = STATUS[name]
  if not s then return end
  local d = ctx.defender
  if s[1] == "poison" then d.poison = math.max(d.poison, 1) else d.status = s[1] end
  ctx.duel:say("  %s is now %s", ctx.duel:card(d.card).name, s[2])
end

local function selfStatus(ctx, name)
  local s = STATUS[name]
  if not s then return end
  local a = ctx.attacker
  if s[1] == "poison" then a.poison = math.max(a.poison, 1) else a.status = s[1] end
  ctx.duel:say("  %s is now %s", ctx.duel:card(a.card).name, s[2])
end

local function discardOwnEnergy(ctx, count, energyType)
  local duel, a = ctx.duel, ctx.attacker
  local pl = duel.players[ctx.player]
  local removed = 0
  for i = #a.energy, 1, -1 do
    if removed >= count then break end
    local c = duel:card(a.energy[i])
    if not energyType or c.type == energyType then
      pl.discard[#pl.discard + 1] = table.remove(a.energy, i)
      removed = removed + 1
    end
  end
  return removed
end

local ENERGY_SYMBOL = {   -- {SYM:0n} glyph -> energy card type
  ["01"] = "TYPE_ENERGY_FIRE", ["02"] = "TYPE_ENERGY_GRASS", ["03"] = "TYPE_ENERGY_LIGHTNING",
  ["04"] = "TYPE_ENERGY_WATER", ["05"] = "TYPE_ENERGY_FIGHTING", ["06"] = "TYPE_ENERGY_PSYCHIC",
}

local function energyTypeCount(duel, slot, energyType)
  local n = 0
  for _, id in ipairs(slot.energy) do
    local c = duel:card(id)
    if not energyType or c.type == energyType then
      n = n + (c.type == "TYPE_ENERGY_DOUBLE_COLORLESS" and 2 or 1)
    end
  end
  return n
end

local function damageCounters(duel, slot)
  return math.floor((duel:card(slot.card).hp - slot.hp) / 10)
end

-- Each rule: { pattern, build(captures) -> partial handler }.  Handlers are
-- merged so an attack can match several clauses (e.g. "Flip 3 coins ... times
-- the number of heads. Vileplume is now Confused (after doing damage)").
local RULES = {}
-- family: at most one rule per family matches an attack (the first listed),
-- so "Poisoned and Confused" is not also matched by the plain "Poisoned" rule.
local function rule(pattern, build, family)
  RULES[#RULES + 1] = { pattern = pattern, build = build,
    family = family or (pattern:find("is now") and "status") or nil }
end

-- --- status conditions ---------------------------------------------------

rule("Flip a coin%. If heads, the Defending " .. POKEMON .. " is now (%a+) and (%a+)%.",
  function(a, b) return { after = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then applyStatus(ctx, a); applyStatus(ctx, b) end
  end } end)

rule("Flip a coin%. If heads, the Defending " .. POKEMON .. " is now (%a+); if tails, it is now (%a+)%.",
  function(a, b) return { after = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then applyStatus(ctx, a) else applyStatus(ctx, b) end
  end } end)

rule("Flip a coin%. If heads, the Defending " .. POKEMON .. " is now (%a+)%. If tails, this attack does nothing %(not even damage%)%.",
  function(a) return { before = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then ctx.flag_heads = true
    else ctx.cancelled = true; ctx.duel:say("  the attack does nothing") end
  end, after = function(ctx) if ctx.flag_heads then applyStatus(ctx, a) end end } end)

rule("Flip a coin%. If heads, the Defending " .. POKEMON .. " is now (%a+)%.",
  function(a) return { after = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then applyStatus(ctx, a) end
  end } end)

rule("^The Defending " .. POKEMON .. " is now Poisoned%. It now takes 20 Poison damage",
  function() return { after = function(ctx)
    ctx.defender.poison = 2
    ctx.duel:say("  %s is now badly Poisoned", ctx.duel:card(ctx.defender.card).name)
  end } end)

rule("^The Defending " .. POKEMON .. " is now (%a+)%.",
  function(a) return { after = function(ctx) applyStatus(ctx, a) end } end)

rule("Both the Defending " .. POKEMON .. " and %S+ are now (%a+) %(after doing damage%)",
  function(a) return { after = function(ctx) applyStatus(ctx, a); selfStatus(ctx, a) end } end)

rule("Flip a coin%. If tails, %S+ is now (%a+) %(after doing damage%)",
  function(a) return { after = function(ctx)
    if not ctx.duel:coin(ctx.attack.name) then selfStatus(ctx, a) end
  end } end)

rule("[^%.]* is now (%a+) %(after doing damage%)%.$",
  function(a) return { after = function(ctx) selfStatus(ctx, a) end } end)

-- --- coin-scaled damage ---------------------------------------------------

rule("Flip (%d+) coins?%. This attack does (%d+) damage times the number of heads%.",
  function(n, per) return { before = function(ctx)
    local heads = 0
    for _ = 1, tonumber(n) do if ctx.duel:coin(ctx.attack.name) then heads = heads + 1 end end
    ctx.damage = heads * tonumber(per)
    ctx.duel:say("  %d heads", heads)
  end } end)

rule("Flip a number of coins equal to the number of Energy attached to %S+%. This attack does (%d+) damage times the number of heads%.",
  function(per) return { before = function(ctx)
    local n = energyTypeCount(ctx.duel, ctx.attacker)
    local heads = 0
    for _ = 1, n do if ctx.duel:coin(ctx.attack.name) then heads = heads + 1 end end
    ctx.damage = heads * tonumber(per)
  end } end)

rule("Flip a coin until you get tails%. This attack does (%d+) damage times the number of heads%.",
  function(per) return { before = function(ctx)
    local heads = 0
    while ctx.duel:coin(ctx.attack.name) do heads = heads + 1 end
    ctx.damage = heads * tonumber(per)
  end } end)

rule("Flip a coin%. If heads, this attack does (%d+) damage plus (%d+) more damage; if tails, this attack does (%d+) damage%.",
  function(base, extra) return { before = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then ctx.damage = tonumber(base) + tonumber(extra) end
  end } end)

rule("Flip a coin%. If tails, this attack does nothing%.",
  function() return { before = function(ctx)
    if not ctx.duel:coin(ctx.attack.name) then
      ctx.cancelled = true; ctx.duel:say("  the attack does nothing")
    end
  end } end)

-- --- scaled damage --------------------------------------------------------

rule("Does (%d+) damage plus (%d+) more damage for each {SYM:(%d%d)} Energy attached to",
  function(base, per, sym) return { before = function(ctx)
    local extra = energyTypeCount(ctx.duel, ctx.attacker, ENERGY_SYMBOL[sym])
    ctx.damage = tonumber(base) + extra * tonumber(per)
  end } end)

rule("Does (%d+) damage plus (%d+) more damage for each Energy attached to",
  function(base, per) return { before = function(ctx)
    ctx.damage = tonumber(base) + energyTypeCount(ctx.duel, ctx.attacker) * tonumber(per)
  end } end)

rule("Does (%d+) damage plus (%d+) more damage for each damage counter on the Defending",
  function(base, per) return { before = function(ctx)
    ctx.damage = tonumber(base) + damageCounters(ctx.duel, ctx.defender) * tonumber(per)
  end } end)

rule("Does (%d+) damage plus (%d+) more damage for each damage counter on",
  function(base, per) return { before = function(ctx)
    ctx.damage = tonumber(base) + damageCounters(ctx.duel, ctx.attacker) * tonumber(per)
  end } end)

rule("Does (%d+) damage minus (%d+) damage for each damage counter on",
  function(base, per) return { before = function(ctx)
    ctx.damage = math.max(0, tonumber(base) - damageCounters(ctx.duel, ctx.attacker) * tonumber(per))
  end } end)

rule("Does (%d+) damage times the number of damage counters on",
  function(per) return { before = function(ctx)
    ctx.damage = damageCounters(ctx.duel, ctx.attacker) * tonumber(per)
  end } end)

rule("Don't apply Weakness and Resistance for this attack%.",
  function() return { before = function(ctx) ctx.ignoreWR = true end } end)

-- --- self damage / bench damage ------------------------------------------

rule("%S+ does (%d+) damage to itself%.",
  function(n) return { after = function(ctx)
    ctx.duel:dealDamage(ctx.player, ctx.attacker, tonumber(n), "recoil")
  end } end)

rule("Does (%d+) damage to each of your opponent's Benched " .. POKEMON,
  function(n) return { after = function(ctx) ctx.duel:damageBench(ctx.opponent, tonumber(n)) end } end)

rule("Does (%d+) damage to each of your own Benched " .. POKEMON,
  function(n) return { after = function(ctx) ctx.duel:damageBench(ctx.player, tonumber(n)) end } end)

rule("Flip a coin%. If heads, this attack does (%d+) damage to each of your opponent's Benched " .. POKEMON ..
  "%. If tails, this attack does (%d+) damage to each of your own Benched",
  function(n, m) return { after = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then ctx.duel:damageBench(ctx.opponent, tonumber(n))
    else ctx.duel:damageBench(ctx.player, tonumber(m)) end
  end } end)

rule("If your opponent has any Benched " .. POKEMON .. ", choose 1 of them and this attack does (%d+) damage to it%.",
  function(n) return { after = function(ctx)
    local bench = ctx.duel.players[ctx.opponent].bench
    if bench[1] then ctx.duel:dealDamage(ctx.opponent, bench[1], tonumber(n), "bench") end
  end } end)

rule("Choose (%d+) of your opponent's Benched " .. POKEMON .. " and this attack does (%d+) damage to each of them%.",
  function(count, n) return { after = function(ctx)
    local bench = ctx.duel.players[ctx.opponent].bench
    for i = 1, math.min(tonumber(count), #bench) do
      ctx.duel:dealDamage(ctx.opponent, bench[i], tonumber(n), "bench")
    end
  end } end)

-- --- healing --------------------------------------------------------------

rule("Remove a number of damage counters from %S+ equal to half the damage done to the Defending",
  function() return { after = function(ctx)
    local heal = math.ceil((ctx.dealt or 0) / 20) * 10
    local a = ctx.attacker
    a.hp = math.min(ctx.duel:card(a.card).hp, a.hp + heal)
    if heal > 0 then ctx.duel:say("  %s heals %d", ctx.duel:card(a.card).name, heal) end
  end } end)

rule("Remove a number of damage counters from %S+ equal to the damage done to the Defending",
  function() return { after = function(ctx)
    local a = ctx.attacker
    local heal = ctx.dealt or 0
    a.hp = math.min(ctx.duel:card(a.card).hp, a.hp + heal)
    if heal > 0 then ctx.duel:say("  %s heals %d", ctx.duel:card(a.card).name, heal) end
  end } end)

rule("Remove all damage counters from %S+%.",
  function() return { after = function(ctx)
    ctx.attacker.hp = ctx.duel:card(ctx.attacker.card).hp
    ctx.duel:say("  %s is fully healed", ctx.duel:card(ctx.attacker.card).name)
  end } end)

-- --- energy costs and discards --------------------------------------------

rule("Discard (%d+) {SYM:(%d%d)} Energy cards? attached to %S+ in order to use this attack%.",
  function(n, sym) return { before = function(ctx)
    if discardOwnEnergy(ctx, tonumber(n), ENERGY_SYMBOL[sym]) < tonumber(n) then
      ctx.cancelled = true; ctx.duel:say("  not enough Energy to discard")
    end
  end } end)

rule("Discard (%d+) Energy cards? attached to %S+ in order to use this attack%.",
  function(n) return { before = function(ctx)
    if discardOwnEnergy(ctx, tonumber(n)) < tonumber(n) then
      ctx.cancelled = true; ctx.duel:say("  not enough Energy to discard")
    end
  end } end)

rule("Discard all Energy cards attached to %S+ in order to use this attack%.",
  function() return { before = function(ctx) discardOwnEnergy(ctx, 99) end } end)

rule("If the Defending " .. POKEMON .. " has any Energy cards attached to it, choose 1 of them and discard it%.",
  function() return { after = function(ctx)
    local d = ctx.defender
    if #d.energy > 0 then
      local pl = ctx.duel.players[ctx.opponent]
      local id = table.remove(d.energy)
      pl.discard[#pl.discard + 1] = id
      ctx.duel:say("  %s is discarded from %s", ctx.duel:card(id).name, ctx.duel:card(d.card).name)
    end
  end } end)

-- --- next-turn substatuses -------------------------------------------------

rule("Flip a coin%. If heads, the Defending " .. POKEMON .. " can't attack during your opponent's next turn%.",
  function() return { after = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then
      ctx.duel:setSub(ctx.defender, "cannotAttack", true, ctx.duel:opponentNextTurn())
      ctx.duel:say("  %s can't attack next turn", ctx.duel:card(ctx.defender.card).name)
    end
  end } end)

rule("Flip a coin%. If heads, the Defending " .. POKEMON .. " can't retreat during your opponent's next turn%.",
  function() return { after = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then
      ctx.duel:setSub(ctx.defender, "cannotRetreat", true, ctx.duel:opponentNextTurn())
    end
  end } end)

rule("^The Defending " .. POKEMON .. " can't retreat during your opponent's next turn%.",
  function() return { after = function(ctx)
    ctx.duel:setSub(ctx.defender, "cannotRetreat", true, ctx.duel:opponentNextTurn())
  end } end)

rule("Choose 1 of the Defending " .. POKEMON .. "'s attacks%. That " .. POKEMON .. " can't use that attack during your opponent's next turn%.",
  function() return { after = function(ctx)
    -- headless default: disable the strongest attack
    local card = ctx.duel:card(ctx.defender.card)
    local best, bestDamage = 1, -1
    for i, atk in ipairs(card.attacks) do
      if atk.category ~= "POKEMON_POWER" and atk.damage > bestDamage then best, bestDamage = i, atk.damage end
    end
    ctx.duel:setSub(ctx.defender, "disabledAttack", best, ctx.duel:opponentNextTurn())
  end } end)

rule("If the Defending " .. POKEMON .. " tries to attack during your opponent's next turn, your opponent flips a coin%. If tails, that attack does nothing%.",
  function() return { after = function(ctx)
    ctx.duel:setSub(ctx.defender, "attackCoin", true, ctx.duel:opponentNextTurn())
  end } end)

rule("Flip a coin%. If heads, during your opponent's next turn, prevent all effects of attacks, including damage, done to %S+%.[^I]*If tails, this attack does nothing",
  function() return { before = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then
      ctx.duel:setSub(ctx.attacker, "preventAll", true, ctx.duel:opponentNextTurn())
    else
      ctx.cancelled = true; ctx.duel:say("  the attack does nothing")
    end
  end } end)

rule("Flip a coin%. If heads, during your opponent's next turn, prevent all ?effects of attacks, including damage, done to",
  function() return { after = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then
      ctx.duel:setSub(ctx.attacker, "preventAll", true, ctx.duel:opponentNextTurn())
      ctx.duel:say("  %s is protected next turn", ctx.duel:card(ctx.attacker.card).name)
    end
  end } end)

rule("Flip a coin%. If heads, prevent all damage done to %S+ during your opponent's next turn%.",
  function() return { after = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then
      ctx.duel:setSub(ctx.attacker, "preventUpTo", 9999, ctx.duel:opponentNextTurn())
    end
  end } end)

rule("All damage done by attacks to %S+ during your opponent's next turn is reduced by (%d+)",
  function(n) return { after = function(ctx)
    ctx.duel:setSub(ctx.attacker, "damageReduction", tonumber(n), ctx.duel:opponentNextTurn())
  end } end)

rule("If the Defending " .. POKEMON .. " attacks %S+ during your opponent's next turn, any damage done by the attack is reduced by (%d+)",
  function(n) return { after = function(ctx)
    ctx.duel:setSub(ctx.attacker, "damageReduction", tonumber(n), ctx.duel:opponentNextTurn())
  end } end)

rule("During your opponent's next turn, whenever (%d+) or less damage is done to %S+ %(after applying Weakness and Resistance%), prevent that damage%.",
  function(n) return { after = function(ctx)
    ctx.duel:setSub(ctx.attacker, "preventUpTo", tonumber(n), ctx.duel:opponentNextTurn())
  end } end)

rule("Whenever an attack does damage to %S+ %(after applying Weakness and Resistance%) during your opponent's next turn, that attack only does half the damage",
  function() return { after = function(ctx)
    ctx.duel:setSub(ctx.attacker, "halveDamage", true, ctx.duel:opponentNextTurn())
  end } end)

rule("During your next turn, %S+'s (%S+) attack's base damage is doubled%.",
  function(attackName) return { after = function(ctx)
    ctx.duel:setSub(ctx.attacker, "doubleBase", attackName, ctx.duel:ownNextTurn())
  end } end)

rule("Your opponent can't play Trainer cards during his or her next turn%.",
  function() return { after = function(ctx)
    ctx.duel.players[ctx.opponent].noTrainersUntil = ctx.duel:opponentNextTurn()
  end } end)

-- --- switching --------------------------------------------------------------

local function switchDefender(ctx)
    local opp = ctx.duel.players[ctx.opponent]
    if opp.active == ctx.defender and #opp.bench > 0 then
      local incoming = table.remove(opp.bench, 1)
      opp.bench[#opp.bench + 1] = opp.active
      opp.active.status, opp.active.poison = "none", 0
      ctx.duel:clearSubs(opp.active)
      opp.active = incoming
      ctx.duel:say("  %s is switched in", ctx.duel:card(incoming.card).name)
    end
end

rule("If your opponent has any Benched " .. POKEMON .. ", he or she chooses 1 of them and switches it with the Defending",
  function() return { after = switchDefender } end, "switch")
rule("If your opponent has any Benched " .. POKEMON .. ", choose 1 of them and switch it with the Defending",
  function() return { after = switchDefender } end, "switch")
rule("If your opponent has any Benched " .. POKEMON .. ", choose 1 of them and switch it with his or her Active",
  function() return { after = switchDefender } end, "switch")

rule("Flip a coin%. If heads and if your opponent has any Benched " .. POKEMON .. ", he or she chooses 1 of them and switches it with the Defending",
  function() return { after = function(ctx)
    local opp = ctx.duel.players[ctx.opponent]
    if ctx.duel:coin(ctx.attack.name) and opp.active == ctx.defender and #opp.bench > 0 then
      local incoming = table.remove(opp.bench, 1)
      opp.bench[#opp.bench + 1] = opp.active
      opp.active.status, opp.active.poison = "none", 0
      ctx.duel:clearSubs(opp.active)
      opp.active = incoming
      ctx.duel:say("  %s is switched in", ctx.duel:card(incoming.card).name)
    end
  end } end)

rule("^Switch %S+ with 1 of your Benched " .. POKEMON,
  function() return { after = function(ctx)
    local pl = ctx.duel.players[ctx.player]
    if #pl.bench > 0 then
      local incoming = table.remove(pl.bench, 1)
      pl.bench[#pl.bench + 1] = pl.active
      pl.active.status, pl.active.poison = "none", 0
      ctx.duel:clearSubs(pl.active)
      pl.active = incoming
      ctx.duel:say("  %s switches out", ctx.duel:card(pl.bench[#pl.bench].card).name)
    end
  end } end)

-- --- deck searches ----------------------------------------------------------

rule("Search your deck for a Basic " .. POKEMON .. " named ([^%s]+) and put it onto your Bench%.",
  function(name) return { before = function(ctx)
    local duel, pl = ctx.duel, ctx.duel.players[ctx.player]
    if #pl.bench >= 5 then ctx.cancelled = true; return end
    for i, id in ipairs(pl.deck) do
      local c = duel:card(id)
      if c.kind == "pokemon" and c.stage == "BASIC" and c.name == name then
        table.remove(pl.deck, i)
        pl.hand[#pl.hand + 1] = id
        duel:playBasic(ctx.player, id)
        break
      end
    end
    duel:shuffle(ctx.player)
  end } end)

-- --- second batch: variants surfaced by Patterns.coverage ------------------

rule("Flip a coin%. If heads, the Defending " .. POKEMON .. " can't attack %S+ during your opponent's next turn%.",
  function() return { after = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then
      ctx.duel:setSub(ctx.defender, "cannotAttack", true, ctx.duel:opponentNextTurn())
    end
  end } end)

rule("All damage done to %S+ during your opponent's next turn is reduced by (%d+)",
  function(n) return { after = function(ctx)
    ctx.duel:setSub(ctx.attacker, "damageReduction", tonumber(n), ctx.duel:opponentNextTurn())
  end } end)

rule("^Remove (%d+) damage counters? from %S+%.$",
  function(n) return { after = function(ctx)
    local a = ctx.attacker
    a.hp = math.min(ctx.duel:card(a.card).hp, a.hp + tonumber(n) * 10)
  end } end)

rule("Unless all damage from this attack is prevented, you may remove 1 damage counter from",
  function() return { after = function(ctx)
    if (ctx.dealt or 0) > 0 then
      local a = ctx.attacker
      a.hp = math.min(ctx.duel:card(a.card).hp, a.hp + 10)
    end
  end } end)

rule("Flip a coin%. If heads, remove a damage counter from %S+%.",
  function() return { before = function(ctx)
    local a = ctx.attacker
    if a.hp >= ctx.duel:card(a.card).hp then ctx.cancelled = true; return end
    if ctx.duel:coin(ctx.attack.name) then a.hp = math.min(ctx.duel:card(a.card).hp, a.hp + 10) end
  end } end)

rule("^Draw a card%.$",
  function() return { after = function(ctx) ctx.duel:draw(ctx.player, 1) end } end)

rule("^Flip a coin%. If heads, draw a card%.$",
  function() return { after = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then ctx.duel:draw(ctx.player, 1) end
  end } end)

rule("Does (%d+) damage plus (%d+) more damage for each Energy card attached to the Defending",
  function(base, per) return { before = function(ctx)
    ctx.damage = tonumber(base) + #ctx.defender.energy * tonumber(per)
  end } end)

rule("Does (%d+) damage times the number of Energy cards attached to the Defending",
  function(per) return { before = function(ctx)
    ctx.damage = #ctx.defender.energy * tonumber(per)
  end } end)

rule("Does (%d+) damage plus (%d+) more damage for each of your Benched",
  function(base, per) return { before = function(ctx)
    ctx.damage = tonumber(base) + #ctx.duel.players[ctx.player].bench * tonumber(per)
  end } end)

rule("Does (%d+) damage plus (%d+) more damage for each (%S+) you have in play%.",
  function(base, per, name) return { before = function(ctx)
    local n = 0
    for _, slot in ipairs(ctx.duel:slots(ctx.player)) do
      if ctx.duel:card(slot.card).name == name then n = n + 1 end
    end
    ctx.damage = tonumber(base) + n * tonumber(per)
  end } end)

rule("You can't use this attack unless the Defending " .. POKEMON .. " is Asleep%.",
  function() return { before = function(ctx)
    if ctx.defender.status ~= "asleep" then ctx.cancelled = true; ctx.duel:say("  no effect") end
  end } end)

rule("If the Defending " .. POKEMON .. " isn't Colorless, this attack does (%d+) damage to each Benched " .. POKEMON .. " of the same type as the Defending",
  function(n) return { after = function(ctx)
    local dtype = ctx.duel:card(ctx.defender.card).type
    if dtype == "TYPE_PKMN_COLORLESS" then return end
    local same = function(slot) return ctx.duel:card(slot.card).type == dtype end
    ctx.duel:damageBench(ctx.opponent, tonumber(n), same)
    ctx.duel:damageBench(ctx.player, tonumber(n), same)
  end } end)

rule("For each of your opponent's Benched " .. POKEMON .. ", flip a coin%. If heads, this attack does (%d+) damage to that " .. POKEMON .. "%.[^%.]*%. Then, %S+ does (%d+) damage times the number of tails to itself%.",
  function(n, per) return { after = function(ctx)
    local tails = 0
    for _, slot in ipairs(ctx.duel.players[ctx.opponent].bench) do
      if ctx.duel:coin(ctx.attack.name) then ctx.duel:dealDamage(ctx.opponent, slot, tonumber(n), "bench")
      else tails = tails + 1 end
    end
    if tails > 0 then ctx.duel:dealDamage(ctx.player, ctx.attacker, tails * tonumber(per), "recoil") end
  end } end)

local function searchBasicToBench(ctx, accept)
  local duel, pl = ctx.duel, ctx.duel.players[ctx.player]
  if #pl.bench >= 5 then ctx.cancelled = true; return end
  for i, id in ipairs(pl.deck) do
    local c = duel:card(id)
    if c.kind == "pokemon" and c.stage == "BASIC" and accept(c) then
      table.remove(pl.deck, i)
      pl.hand[#pl.hand + 1] = id
      duel:playBasic(ctx.player, id)
      break
    end
  end
  duel:shuffle(ctx.player)
end

rule("Search your deck for a Basic " .. POKEMON .. " named (%S+) or (%S+) and put it onto your Bench%.",
  function(a, b) return { before = function(ctx)
    searchBasicToBench(ctx, function(c) return c.name == a or c.name == b end)
  end } end)

rule("Search your deck for a {SYM:(%d%d)} Basic " .. POKEMON .. " card and put it onto your Bench%.",
  function(sym) return { before = function(ctx)
    local want = ({ ["01"] = "TYPE_PKMN_FIRE", ["02"] = "TYPE_PKMN_GRASS", ["03"] = "TYPE_PKMN_LIGHTNING",
      ["04"] = "TYPE_PKMN_WATER", ["05"] = "TYPE_PKMN_FIGHTING", ["06"] = "TYPE_PKMN_PSYCHIC" })[sym]
    searchBasicToBench(ctx, function(c) return c.type == want end)
  end } end)

rule("Flip a coin%. If heads, put a Basic " .. POKEMON .. " card chosen at random from your deck onto your Bench%.",
  function() return { before = function(ctx)
    if ctx.duel:coin(ctx.attack.name) then
      ctx.duel:shuffle(ctx.player)
      searchBasicToBench(ctx, function() return true end)
    end
  end } end)

rule("Search your deck for a basic Energy card and attach it to 1 of your " .. POKEMON,
  function() return { after = function(ctx)
    local duel, pl = ctx.duel, ctx.duel.players[ctx.player]
    for i, id in ipairs(pl.deck) do
      local c = duel:card(id)
      if c.kind == "energy" and c.type ~= "TYPE_ENERGY_DOUBLE_COLORLESS" then
        table.remove(pl.deck, i)
        ctx.attacker.energy[#ctx.attacker.energy + 1] = id
        duel:say("  %s is attached", c.name)
        break
      end
    end
    duel:shuffle(ctx.player)
  end } end)

rule("Choose up to (%d+) Energy cards from your discard pile and attach them to",
  function(n) return { after = function(ctx)
    local duel, pl = ctx.duel, ctx.duel.players[ctx.player]
    local moved = 0
    for i = #pl.discard, 1, -1 do
      if moved >= tonumber(n) then break end
      if duel:card(pl.discard[i]).kind == "energy" then
        ctx.attacker.energy[#ctx.attacker.energy + 1] = table.remove(pl.discard, i)
        moved = moved + 1
      end
    end
  end } end)

-- ---------------------------------------------------------------------------

local cache = {}

-- Returns a merged handler ({ before = fn|nil, after = fn|nil, rules = {...} })
-- or nil when no clause matched.
function Patterns.infer(card, index)
  local k = card.constant .. ":" .. index
  if cache[k] ~= nil then return cache[k] or nil end
  local text = norm(card.attacks[index].description)
  local befores, afters, matched = {}, {}, {}
  local usedFamily = {}
  for _, r in ipairs(RULES) do
    local caps = (not (r.family and usedFamily[r.family])) and { text:match(r.pattern) } or {}
    if #caps > 0 then
      if r.family then usedFamily[r.family] = true end
      local h = r.build(unpack(caps))
      if h.before then befores[#befores + 1] = h.before end
      if h.after then afters[#afters + 1] = h.after end
      matched[#matched + 1] = r.pattern
    end
  end
  if #matched == 0 then cache[k] = false; return nil end
  local handler = { rules = matched }
  if #befores > 0 then
    handler.before = function(ctx) for _, f in ipairs(befores) do f(ctx); if ctx.cancelled then return end end end
  end
  if #afters > 0 then
    handler.after = function(ctx) for _, f in ipairs(afters) do f(ctx) end end
  end
  cache[k] = handler
  return handler
end

-- Coverage report for tests/docs: which attacks with rules text resolve
-- through inference, and which match nothing.
function Patterns.coverage(cards, hasExplicit)
  local inferred, missing = {}, {}
  for id = 1, cards.count do
    local card = cards.byId[id]
    if card and card.kind == "pokemon" then
      for i, atk in ipairs(card.attacks) do
        if (atk.description or "") ~= "" and atk.category ~= "POKEMON_POWER"
          and not (hasExplicit and hasExplicit(card.constant, i)) then
          local label = card.constant .. "/" .. i
          if Patterns.infer(card, i) then inferred[#inferred + 1] = label
          else missing[#missing + 1] = label end
        end
      end
    end
  end
  return inferred, missing
end

return Patterns
