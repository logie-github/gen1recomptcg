-- Trainer card ports beyond the practice-deck set in Effects.lua
-- (docs/tcg-phase1.md, Phase 4).  Same handler shape:
--   { can = function(duel, p, id) -> bool, play = function(duel, p, id, args) }
-- Choices default to the first legal candidate unless `args` names one; a
-- `play` returning false refunds the card to the hand.

local Effects = require("src.tcg.Effects")

local reg = Effects.registerTrainer

local function maxHp(duel, slot) return duel:card(slot.card).hp end
local function damaged(duel, slot) return slot.hp < maxHp(duel, slot) end
local function isBasicEnergy(c) return c.kind == "energy" and c.type ~= "TYPE_ENERGY_DOUBLE_COLORLESS" end
local function isPokemonCard(c) return c.kind == "pokemon" end

local function removeFirst(list, pred, skipId)
  local skipped = false
  for i, id in ipairs(list) do
    if id == skipId and not skipped then
      skipped = true
    elseif pred(id) then
      return table.remove(list, i)
    end
  end
end

-- discard `n` other cards from hand (not the trainer itself); returns count
local function discardOthers(duel, p, self, n, preferred)
  local pl = duel.players[p]
  local done = 0
  local chosen = preferred or {}
  for _, id in ipairs(chosen) do
    if done >= n then break end
    for i, h in ipairs(pl.hand) do
      if h == id and h ~= self then table.remove(pl.hand, i); pl.discard[#pl.discard + 1] = h; done = done + 1; break end
    end
  end
  -- default: discard energy first, then anything
  while done < n do
    local id = removeFirst(pl.hand, function(x) return x ~= self and duel:card(x).kind == "energy" end)
      or removeFirst(pl.hand, function(x) return x ~= self end)
    if not id then break end
    pl.discard[#pl.discard + 1] = id
    done = done + 1
  end
  return done
end

local function othersInHand(duel, p, self)
  local n = 0
  for _, id in ipairs(duel.players[p].hand) do if id ~= self then n = n + 1 end end
  return n
end

-- ---------------------------------------------------------------------

reg("IMPOSTER_PROFESSOR_OAK", {
  can = function() return true end,
  play = function(duel, p)
    local o = duel:opponentOf(p)
    local opp = duel.players[o]
    for _, h in ipairs(opp.hand) do opp.deck[#opp.deck + 1] = h end
    opp.hand = {}
    duel:shuffle(o)
    duel:draw(o, 7)
  end })

reg("MR_FUJI", {
  can = function(duel, p) return #duel.players[p].bench > 0 end,
  play = function(duel, p, id, args)
    local pl = duel.players[p]
    local slot = table.remove(pl.bench, args.location or 1)
    for _, c in ipairs(slot.stack) do pl.deck[#pl.deck + 1] = c end
    for _, e in ipairs(slot.energy) do pl.deck[#pl.deck + 1] = e end
    duel:shuffle(p)
    duel:say("  %s is shuffled into the deck", duel:card(slot.card).name)
  end })

reg("LASS", {
  can = function() return true end,
  play = function(duel, p, id)
    for q = 1, 2 do
      local pl = duel.players[q]
      local kept = {}
      for _, h in ipairs(pl.hand) do
        if h ~= id and duel:card(h).kind == "trainer" and not duel:card(h).pseudoPokemon then
          pl.deck[#pl.deck + 1] = h
        else kept[#kept + 1] = h end
      end
      pl.hand = kept
      duel:shuffle(q)
    end
  end })

reg("IMAKUNI_CARD", {
  can = function(duel, p) return duel.players[p].active ~= nil end,
  play = function(duel, p) duel:setStatus(duel.players[p].active, "confused") end })

reg("POKEMON_TRADER", {
  can = function(duel, p, id)
    local pl = duel.players[p]
    local inHand, inDeck = false, false
    for _, h in ipairs(pl.hand) do if h ~= id and isPokemonCard(duel:card(h)) then inHand = true end end
    for _, d in ipairs(pl.deck) do if isPokemonCard(duel:card(d)) then inDeck = true end end
    return inHand and inDeck
  end,
  play = function(duel, p, id, args)
    local pl = duel.players[p]
    local give = args.give and removeFirst(pl.hand, function(x) return x == args.give end)
      or removeFirst(pl.hand, function(x) return x ~= id and isPokemonCard(duel:card(x)) end)
    if not give then return false, "nothing to trade" end
    -- default pick: an evolution whose pre-evolution is in play, else any
    local want = args.want
    local function evolvable(x)
      local c = duel:card(x)
      if c.kind ~= "pokemon" or c.stage == "BASIC" then return false end
      for _, s in ipairs(duel:slots(p)) do if duel:card(s.card).name == c.preEvolutionName then return true end end
      return false
    end
    local get = (want and removeFirst(pl.deck, function(x) return x == want end))
      or removeFirst(pl.deck, evolvable)
      or removeFirst(pl.deck, function(x) return isPokemonCard(duel:card(x)) end)
    pl.deck[#pl.deck + 1] = give
    pl.hand[#pl.hand + 1] = get
    duel:shuffle(p)
    duel:say("  traded %s for %s", duel:card(give).name, duel:card(get).name)
  end })

reg("POKEMON_BREEDER", {
  can = function(duel, p, id)
    if duel.turn == 1 then return false end
    for _, h in ipairs(duel.players[p].hand) do
      local c = duel:card(h)
      if c.kind == "pokemon" and c.stage == "STAGE2" then
        for _, s in ipairs(duel:slots(p)) do
          local base = duel:card(s.card)
          -- pre-evolution of the Stage 2 must itself evolve from the basic in play
          if base.stage == "BASIC" and s.turnPlayed ~= duel.turn then
            for _, s1 in pairs(duel.cards.byId) do
              if s1.kind == "pokemon" and s1.stage == "STAGE1" and s1.name == c.preEvolutionName
                and s1.preEvolutionName == base.name then return true end
            end
          end
        end
      end
    end
    return false
  end,
  play = function(duel, p, id, args)
    local pl = duel.players[p]
    for i, h in ipairs(pl.hand) do
      local c = duel:card(h)
      if c.kind == "pokemon" and c.stage == "STAGE2" then
        for loc = 0, #pl.bench do
          local s = duel:slotAt(p, loc)
          local base = duel:card(s.card)
          if base.stage == "BASIC" and s.turnPlayed ~= duel.turn then
            for _, s1 in pairs(duel.cards.byId) do
              if s1.kind == "pokemon" and s1.stage == "STAGE1" and s1.name == c.preEvolutionName
                and s1.preEvolutionName == base.name then
                table.remove(pl.hand, i)
                local dmg = base.hp - s.hp
                s.stack[#s.stack + 1] = h
                s.card = h
                s.hp = math.max(0, c.hp - dmg)
                s.turnEvolved = duel.turn
                duel:cure(s); duel:clearSubs(s)
                duel:say("  %s evolves straight into %s", base.name, c.name)
                return true
              end
            end
          end
        end
      end
    end
    return false, "no legal Stage 2"
  end })

local function energyRetrieval(tradeCount, maxEnergy)
  return {
    can = function(duel, p, id)
      if othersInHand(duel, p, id) < tradeCount then return false end
      for _, d in ipairs(duel.players[p].discard) do if isBasicEnergy(duel:card(d)) then return true end end
      return false
    end,
    play = function(duel, p, id, args)
      local pl = duel.players[p]
      if discardOthers(duel, p, id, tradeCount, args.discard) < tradeCount then return false end
      local got = 0
      for i = #pl.discard, 1, -1 do
        if got >= maxEnergy then break end
        if isBasicEnergy(duel:card(pl.discard[i])) then
          pl.hand[#pl.hand + 1] = table.remove(pl.discard, i); got = got + 1
        end
      end
      duel:say("  %d Energy back to hand", got)
    end }
end
reg("ENERGY_RETRIEVAL", energyRetrieval(1, 2))
reg("SUPER_ENERGY_RETRIEVAL", energyRetrieval(2, 4))

reg("ENERGY_SEARCH", {
  can = function(duel, p)
    for _, d in ipairs(duel.players[p].deck) do if isBasicEnergy(duel:card(d)) then return true end end
    return false
  end,
  play = function(duel, p, id, args)
    local pl = duel.players[p]
    local want = args.energyType
    local e = (want and removeFirst(pl.deck, function(x) return duel:card(x).type == want end))
      or removeFirst(pl.deck, function(x) return isBasicEnergy(duel:card(x)) end)
    pl.hand[#pl.hand + 1] = e
    duel:shuffle(p)
  end })

reg("SUPER_ENERGY_REMOVAL", {
  can = function(duel, p)
    local mine, theirs = false, false
    for _, s in ipairs(duel:slots(p)) do if #s.energy > 0 then mine = true end end
    for _, s in ipairs(duel:slots(duel:opponentOf(p))) do if #s.energy > 0 then theirs = true end end
    return mine and theirs
  end,
  play = function(duel, p, id, args)
    local o = duel:opponentOf(p)
    local mine = duel:slotAt(p, args.location or -1)
    if not (mine and #mine.energy > 0) then
      -- default: pay from the bench Pokemon with the most energy, else the active
      for _, s in ipairs(duel:slots(p)) do if #s.energy > 0 and (not mine or (s ~= duel.players[p].active and #s.energy > #mine.energy)) then mine = s end end
    end
    duel.players[p].discard[#duel.players[p].discard + 1] = table.remove(mine.energy)
    local target = duel:slotAt(o, args.target or -1)
    if not (target and #target.energy > 0) then
      for _, s in ipairs(duel:slots(o)) do if #s.energy > 0 and (not target or #s.energy > #target.energy) then target = s end end
    end
    for _ = 1, 2 do
      local e = table.remove(target.energy)
      if not e then break end
      duel.players[o].discard[#duel.players[o].discard + 1] = e
    end
    duel:say("  %s loses up to 2 Energy", duel:card(target.card).name)
  end })

reg("POKEMON_CENTER", {
  can = function(duel, p)
    for _, s in ipairs(duel:slots(p)) do if damaged(duel, s) then return true end end
    return false
  end,
  play = function(duel, p)
    local pl = duel.players[p]
    for _, s in ipairs(duel:slots(p)) do
      if damaged(duel, s) then
        s.hp = maxHp(duel, s)
        for _, e in ipairs(s.energy) do pl.discard[#pl.discard + 1] = e end
        s.energy = {}
      end
    end
  end })

reg("POKE_BALL", {
  can = function(duel, p)
    for _, d in ipairs(duel.players[p].deck) do if isPokemonCard(duel:card(d)) then return true end end
    return false
  end,
  play = function(duel, p, id, args)
    if not duel:coin("Poke Ball") then return end
    local pl = duel.players[p]
    local function evolvable(x)
      local c = duel:card(x)
      if c.kind ~= "pokemon" or c.stage == "BASIC" then return false end
      for _, s in ipairs(duel:slots(p)) do if duel:card(s.card).name == c.preEvolutionName then return true end end
      return false
    end
    local got = (args.want and removeFirst(pl.deck, function(x) return x == args.want end))
      or removeFirst(pl.deck, evolvable)
      or removeFirst(pl.deck, function(x) local c = duel:card(x) return c.kind == "pokemon" and c.stage == "BASIC" end)
      or removeFirst(pl.deck, function(x) return isPokemonCard(duel:card(x)) end)
    if got then pl.hand[#pl.hand + 1] = got; duel:say("  found %s", duel:card(got).name) end
    duel:shuffle(p)
  end })

reg("SCOOP_UP", {
  can = function(duel, p) return #duel:slots(p) >= 2 end,
  play = function(duel, p, id, args)
    local pl = duel.players[p]
    local slot = duel:slotAt(p, args.location or -1)
    if not slot then
      -- default: most damaged
      local worst = -1
      for _, s in ipairs(duel:slots(p)) do
        local d = maxHp(duel, s) - s.hp
        if d > worst then slot, worst = s, d end
      end
    end
    if slot == pl.active and #pl.bench == 0 then return false, "no bench to promote" end
    for _, e in ipairs(slot.energy) do pl.discard[#pl.discard + 1] = e end
    for i = 2, #slot.stack do pl.discard[#pl.discard + 1] = slot.stack[i] end
    pl.hand[#pl.hand + 1] = slot.stack[1]
    if pl.active == slot then pl.active = table.remove(pl.bench, 1)
    else for i, s in ipairs(pl.bench) do if s == slot then table.remove(pl.bench, i) break end end end
    duel:say("  %s is scooped up", duel:card(slot.stack[1]).name)
  end })

reg("COMPUTER_SEARCH", {
  can = function(duel, p, id) return othersInHand(duel, p, id) >= 2 and #duel.players[p].deck > 0 end,
  play = function(duel, p, id, args)
    local pl = duel.players[p]
    if discardOthers(duel, p, id, 2, args.discard) < 2 then return false end
    local got = (args.want and removeFirst(pl.deck, function(x) return x == args.want end))
      or removeFirst(pl.deck, function(x) local c = duel:card(x) return c.kind == "pokemon" and c.stage ~= "BASIC" end)
      or table.remove(pl.deck, 1)
    pl.hand[#pl.hand + 1] = got
    duel:shuffle(p)
  end })

reg("POKEDEX", {   -- look at 5 and rearrange: headless default keeps the order
  can = function(duel, p) return #duel.players[p].deck > 0 end,
  play = function(duel, p, id, args)
    local pl = duel.players[p]
    if args.order then
      local top = {}
      for i = 1, math.min(5, #pl.deck) do top[i] = table.remove(pl.deck, 1) end
      for i = #args.order, 1, -1 do table.insert(pl.deck, 1, top[args.order[i]]) end
    end
  end })

reg("ITEM_FINDER", {
  can = function(duel, p, id)
    if othersInHand(duel, p, id) < 2 then return false end
    for _, d in ipairs(duel.players[p].discard) do
      local c = duel:card(d)
      if c.kind == "trainer" and not c.pseudoPokemon then return true end
    end
    return false
  end,
  play = function(duel, p, id, args)
    local pl = duel.players[p]
    if discardOthers(duel, p, id, 2, args.discard) < 2 then return false end
    for i = #pl.discard, 1, -1 do
      local c = duel:card(pl.discard[i])
      if c.kind == "trainer" and not c.pseudoPokemon and (not args.want or pl.discard[i] == args.want) then
        pl.hand[#pl.hand + 1] = table.remove(pl.discard, i)
        return
      end
    end
  end })

reg("DEVOLUTION_SPRAY", {
  can = function(duel, p)
    for _, s in ipairs(duel:slots(p)) do if #s.stack > 1 then return true end end
    return false
  end,
  play = function(duel, p, id, args)
    local pl = duel.players[p]
    local slot = duel:slotAt(p, args.location or -1)
    if not (slot and #slot.stack > 1) then
      for _, s in ipairs(duel:slots(p)) do if #s.stack > 1 then slot = s; break end end
    end
    local keep = math.max(1, math.min(#slot.stack - 1, args.keep or (#slot.stack - 1)))
    local dmg = maxHp(duel, slot) - slot.hp
    while #slot.stack > keep do pl.discard[#pl.discard + 1] = table.remove(slot.stack) end
    slot.card = slot.stack[#slot.stack]
    slot.hp = maxHp(duel, slot) - dmg     -- may drop to 0 or below: a KO
    duel:say("  %s devolves", duel:card(slot.card).name)
  end })

reg("REVIVE", {
  can = function(duel, p)
    if #duel.players[p].bench >= 5 then return false end
    for _, d in ipairs(duel.players[p].discard) do
      local c = duel:card(d)
      if c.kind == "pokemon" and c.stage == "BASIC" then return true end
    end
    return false
  end,
  play = function(duel, p, id, args)
    local pl = duel.players[p]
    local got = removeFirst(pl.discard, function(x)
      local c = duel:card(x)
      return c.kind == "pokemon" and c.stage == "BASIC" and (not args.want or x == args.want)
    end)
    pl.hand[#pl.hand + 1] = got
    duel:playBasic(p, got)
    local slot = pl.bench[#pl.bench]
    slot.hp = maxHp(duel, slot) - math.floor(maxHp(duel, slot) / 20) * 10
  end })

reg("MAINTENANCE", {
  can = function(duel, p, id) return othersInHand(duel, p, id) >= 2 and #duel.players[p].deck > 0 end,
  play = function(duel, p, id, args)
    local pl = duel.players[p]
    local moved = 0
    for _ = 1, 2 do
      local x = (args.shuffle and removeFirst(pl.hand, function(h) return h == args.shuffle[moved + 1] end))
        or removeFirst(pl.hand, function(h) return h ~= id and duel:card(h).kind == "energy" end)
        or removeFirst(pl.hand, function(h) return h ~= id end)
      if x then pl.deck[#pl.deck + 1] = x; moved = moved + 1 end
    end
    duel:shuffle(p)
    duel:draw(p, 1)
  end })

reg("POKEMON_FLUTE", {
  can = function(duel, p)
    local o = duel:opponentOf(p)
    if #duel.players[o].bench >= 5 then return false end
    for _, d in ipairs(duel.players[o].discard) do
      local c = duel:card(d)
      if c.kind == "pokemon" and c.stage == "BASIC" then return true end
    end
    return false
  end,
  play = function(duel, p, id, args)
    local o = duel:opponentOf(p)
    local opp = duel.players[o]
    -- default: the weakest Basic in their discard
    local pick, worst
    for i, d in ipairs(opp.discard) do
      local c = duel:card(d)
      if c.kind == "pokemon" and c.stage == "BASIC" and (not args.want or d == args.want) then
        if not worst or c.hp < worst then pick, worst = i, c.hp end
      end
    end
    local got = table.remove(opp.discard, pick)
    opp.hand[#opp.hand + 1] = got
    local saved = duel.current; duel.current = o
    duel:playBasic(o, got)
    duel.current = saved
  end })

reg("GAMBLER", {
  can = function(duel, p) return #duel.players[p].deck > 0 end,
  play = function(duel, p, id)
    local pl = duel.players[p]
    for _, h in ipairs(pl.hand) do pl.deck[#pl.deck + 1] = h end
    pl.hand = {}
    duel:shuffle(p)
    duel:draw(p, duel:coin("Gambler") and 8 or 1)
  end })

reg("RECYCLE", {
  can = function(duel, p) return #duel.players[p].discard > 0 end,
  play = function(duel, p, id, args)
    if not duel:coin("Recycle") then return end
    local pl = duel.players[p]
    local x = (args.want and removeFirst(pl.discard, function(d) return d == args.want end))
      or removeFirst(pl.discard, function(d) return duel:card(d).kind == "pokemon" end)
      or table.remove(pl.discard)
    table.insert(pl.deck, 1, x)
  end })

-- Clefairy Doll / Mysterious Fossil are played through Duel:playBasic
-- (Duel.new marks them pseudoPokemon); they are never "played as Trainers".
reg("CLEFAIRY_DOLL", { can = function() return false end, play = function() return false end })
reg("MYSTERIOUS_FOSSIL", { can = function() return false end, play = function() return false end })

return true
