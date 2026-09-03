-- Pokemon TCG duel engine core (docs/tcg-phase1.md, "Phase 2").
--
-- Pure Lua, no LÖVE.  Consumes the extracted cards table
-- (data/generated/cards.lua) and drives a full duel: setup with mulligans,
-- turn structure, playing/evolving Pokemon, energy attachment, retreat,
-- attacks with weakness/resistance/PlusPower/Defender, status conditions,
-- between-turn poison/sleep/paralysis handling, knockouts, prizes and the
-- three win conditions.  Attack and Trainer effects are dispatched through
-- src/tcg/Effects.lua; anything not ported yet falls back to plain damage.
--
-- Rule provenance is cited inline against pret/poketcg (home/duel.asm and
-- engine/duel/core.asm).  Every mutation goes through Duel methods so a UI
-- or AI can replay the log.
--
-- Coin flips come from an injectable RNG (src/tcg/Rng.lua) so a duel with a
-- given seed and action sequence is reproducible.

local Rng = require("src.tcg.Rng")
local Effects = require("src.tcg.Effects")
local Powers = require("src.tcg.Powers")

local Duel = {}
Duel.__index = Duel

Duel.MAX_BENCH = 5                    -- duel_constants.asm MAX_BENCH_POKEMON
Duel.STARTING_HAND = 7                -- STARTING_HAND_SIZE
Duel.PSN_DAMAGE, Duel.DBLPSN_DAMAGE = 10, 20
Duel.CONFUSION_SELF_DAMAGE = 20       -- home/duel.asm HandleConfusionDamageToSelf
Duel.RESISTANCE_REDUCTION = 30        -- ApplyDamageModifiers_DamageToTarget

local ENERGY_TYPES = { "FIRE", "GRASS", "LIGHTNING", "WATER", "FIGHTING", "PSYCHIC", "COLORLESS" }
local ENERGY_CARD_TYPE = {   -- card.type -> energy provided
  TYPE_ENERGY_FIRE = "FIRE", TYPE_ENERGY_GRASS = "GRASS", TYPE_ENERGY_LIGHTNING = "LIGHTNING",
  TYPE_ENERGY_WATER = "WATER", TYPE_ENERGY_FIGHTING = "FIGHTING", TYPE_ENERGY_PSYCHIC = "PSYCHIC",
  TYPE_ENERGY_DOUBLE_COLORLESS = "COLORLESS",
}
local POKEMON_COLOR = {      -- card.type -> weakness/resistance colour name
  TYPE_PKMN_FIRE = "FIRE", TYPE_PKMN_GRASS = "GRASS", TYPE_PKMN_LIGHTNING = "LIGHTNING",
  TYPE_PKMN_WATER = "WATER", TYPE_PKMN_FIGHTING = "FIGHTING", TYPE_PKMN_PSYCHIC = "PSYCHIC",
  TYPE_PKMN_COLORLESS = "COLORLESS",
}

-- ---------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------

-- cards: the extracted cards table ({ byId = ..., byConstant = ... })
-- opts: { decks = { {ids...}, {ids...} }, prizes = 6, seed = n,
--         names = { "PLAYER", "OPP" }, first = 1|2|nil (coin) }
function Duel.new(cards, opts)
  assert(cards and cards.byId, "cards table required")
  opts = opts or {}
  -- Clefairy Doll and Mysterious Fossil are Trainers played as Basics with
  -- 10 HP, no attacks, no weakness/resistance, no retreat, and no prize when
  -- Knocked Out (their own rules text).  data/cards.asm gives them no
  -- Pokemon fields, so fill in the ones the engine reads.
  for _, constant in ipairs({ "CLEFAIRY_DOLL", "MYSTERIOUS_FOSSIL" }) do
    local id = cards.byConstant and cards.byConstant[constant]
    local c = id and cards.byId[id]
    if c and not c.pseudoPokemon then
      c.pseudoPokemon = true
      c.hp, c.stage, c.attacks = 10, "BASIC", {}
      c.weakness, c.resistance, c.retreatCost = {}, {}, 99
    end
  end
  local self = setmetatable({
    cards = cards,
    rng = Rng.new(opts.seed or 1),
    prizeCount = opts.prizes or 6,
    turn = 0,
    current = 1,
    finished = nil,          -- nil | { winner = 1|2|0 (tie), reason = ... }
    log = {},
    players = {},
  }, Duel)
  for p = 1, 2 do
    local deck = assert(opts.decks and opts.decks[p], "deck " .. p .. " required")
    assert(#deck == 60, ("deck %d has %d cards, expected 60"):format(p, #deck))
    self.players[p] = {
      index = p,
      name = opts.names and opts.names[p] or ("DUELIST " .. p),
      deck = (function() local c = {} for i, id in ipairs(deck) do c[i] = id end return c end)(),
      hand = {},
      discard = {},
      prizes = {},
      active = nil,          -- slot
      bench = {},            -- slots
      flags = {},            -- per-turn flags
    }
  end
  return self
end

-- Duel events for a UI to react to: sounds and attack animations.  Headless
-- callers leave `onEvent` unset and nothing changes.
function Duel:emit(kind, data)
  if self.onEvent then self.onEvent(kind, data or {}) end
end

function Duel:say(fmt, ...)
  self.log[#self.log + 1] = fmt:format(...)
end

function Duel:card(id) return self.cards.byId[id] end
function Duel:opponentOf(p) return p == 1 and 2 or 1 end
function Duel:player(p) return self.players[p] end
function Duel:coin(label)
  local heads = self.rng:coin()
  self:say("%s: %s", label or "coin", heads and "HEADS" or "TAILS")
  self:emit("coin", { heads = heads, label = label })
  return heads
end

-- ---------------------------------------------------------------------
-- card movement
-- ---------------------------------------------------------------------

local function removeValue(list, value)
  for i, v in ipairs(list) do
    if v == value then table.remove(list, i); return true end
  end
  return false
end

function Duel:shuffle(p)
  self:emit("shuffle", { player = p })
  local deck = self.players[p].deck
  for i = #deck, 2, -1 do
    local j = self.rng:int(1, i)
    deck[i], deck[j] = deck[j], deck[i]
  end
end

-- returns card id or nil when the deck is empty
function Duel:draw(p, n)
  local pl = self.players[p]
  local drawn = {}
  for _ = 1, n or 1 do
    local id = table.remove(pl.deck, 1)
    if not id then break end
    pl.hand[#pl.hand + 1] = id
    drawn[#drawn + 1] = id
  end
  return drawn
end

function Duel:discardFromHand(p, id)
  local pl = self.players[p]
  assert(removeValue(pl.hand, id), "card not in hand")
  pl.discard[#pl.discard + 1] = id
end

-- ---------------------------------------------------------------------
-- slots (Pokemon in play)
-- ---------------------------------------------------------------------

local function newSlot(self, id, turn)
  local card = self:card(id)
  return {
    card = id,               -- top card of the evolution stack
    stack = { id },          -- evolution history, bottom first
    hp = card.hp,
    energy = {},             -- attached energy card ids
    status = "none",         -- none | confused | asleep | paralyzed
    poison = 0,              -- 0 | 1 | 2 (double)
    plusPower = 0,
    defender = 0,
    turnPlayed = turn,       -- for the "no evolving the turn it was played" rule
    turnEvolved = nil,
    sub = {},                -- substatuses: key -> { value, untilTurn } (see Duel:setSub)
    powerUsedTurn = nil,     -- once-per-turn Pokemon Powers
  }
end

function Duel:isPseudo(slot) return self:card(slot.card).pseudoPokemon == true end

-- ---------------------------------------------------------------------
-- special conditions: single write path so immunities (Snorlax's Thick
-- Skinned) and future logging apply everywhere
-- ---------------------------------------------------------------------

local STATUS_LABEL = { confused = "Confused", asleep = "Asleep", paralyzed = "Paralyzed" }

function Duel:setStatus(slot, status)
  if self:isPseudo(slot) then return false end
  if Powers.immuneToStatus(self, slot) then
    self:say("  %s is unaffected", self:card(slot.card).name)
    return false
  end
  slot.status = status
  if status ~= "none" then self:say("  %s is now %s", self:card(slot.card).name, STATUS_LABEL[status]) end
  return true
end

function Duel:setPoison(slot, level)
  if self:isPseudo(slot) then return false end
  if level > 0 and Powers.immuneToStatus(self, slot) then
    self:say("  %s is unaffected", self:card(slot.card).name)
    return false
  end
  slot.poison = level
  if level > 0 then self:say("  %s is now %s", self:card(slot.card).name, level == 2 and "badly Poisoned" or "Poisoned") end
  return true
end

function Duel:cure(slot)
  slot.status, slot.poison = "none", 0
end

-- ---------------------------------------------------------------------
-- substatuses (poketcg wDuelist*Substatus1/2/3 and the AttackDisabled /
-- CannotAttack / CannotRetreat family).  A substatus lives on a slot until
-- the end of `untilTurn`; the checks read through Duel:sub so expiry is
-- lazy.  Benching, retreating and evolving clear them, matching the "ends
-- this effect" clauses on the cards.
-- ---------------------------------------------------------------------

function Duel:setSub(slot, key, value, untilTurn)
  slot.sub[key] = { value = value, untilTurn = untilTurn }
end

function Duel:sub(slot, key)
  local entry = slot and slot.sub[key]
  if not entry then return nil end
  if entry.untilTurn and self.turn > entry.untilTurn then
    slot.sub[key] = nil
    return nil
  end
  return entry.value
end

function Duel:clearSubs(slot)
  slot.sub = {}
end

-- "during your opponent's next turn" from the current player's perspective
function Duel:opponentNextTurn() return self.turn + 1 end
-- "during your next turn"
function Duel:ownNextTurn() return self.turn + 2 end

-- Damage to a Benched Pokemon: no weakness/resistance (every bench-damage
-- card says so explicitly).
function Duel:damageBench(p, amount, filter)
  local pl = self.players[p]
  for _, slot in ipairs(pl.bench) do
    if not filter or filter(slot) then
      self:dealDamage(p, slot, amount, "bench")
    end
  end
end

function Duel:slots(p)
  local pl = self.players[p]
  local out = {}
  if pl.active then out[#out + 1] = pl.active end
  for _, s in ipairs(pl.bench) do out[#out + 1] = s end
  return out
end

function Duel:slotAt(p, location)
  -- location: 0 = arena, 1..5 = bench (PLAY_AREA_* convention)
  local pl = self.players[p]
  if location == 0 then return pl.active end
  return pl.bench[location]
end

function Duel:energyProvided(slot)
  local total = {}
  for _, t in ipairs(ENERGY_TYPES) do total[t] = 0 end
  for _, id in ipairs(slot.energy) do
    local card = self:card(id)
    local kind = ENERGY_CARD_TYPE[card.type]
    if kind then
      total[kind] = total[kind] + (card.type == "TYPE_ENERGY_DOUBLE_COLORLESS" and 2 or 1)
    end
  end
  return self:energyProvidedBurn(slot, total)
end

-- Charizard's Energy Burn: every attached energy counts as Fire for the turn
function Duel:energyProvidedBurn(slot, total)
  if self:sub(slot, "energyBurn") then
    local n = 0
    for _, v in pairs(total) do n = n + v end
    for k in pairs(total) do total[k] = 0 end
    total.FIRE = n
  end
  return total
end

function Duel:energyCount(slot)
  local n = 0
  for _, v in pairs(self:energyProvided(slot)) do n = n + v end
  return n
end

-- Can `slot` pay `cost` ({ FIRE = 2, COLORLESS = 1, ... })?
-- Coloured requirements consume matching energy first; anything left over
-- (of any colour) pays the colourless part.  (core.asm
-- CheckEnergyNeededForAttack does the same accounting.)
function Duel:canPay(slot, cost)
  local have = self:energyProvided(slot)
  local spare = 0
  for _, t in ipairs(ENERGY_TYPES) do
    if t ~= "COLORLESS" then
      local need = cost[t] or 0
      if have[t] < need then return false end
      spare = spare + (have[t] - need)
    end
  end
  spare = spare + have.COLORLESS
  return spare >= (cost.COLORLESS or 0)
end

-- ---------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------

function Duel:hasBasic(p)
  for _, id in ipairs(self.players[p].hand) do
    local c = self:card(id)
    if c.kind == "pokemon" and c.stage == "BASIC" then return true end
  end
  return false
end

-- Shuffle, draw 7, mulligan until a Basic is present (core.asm .ensure_*
-- loops: the GB game redraws, no bonus draw for the opponent), lay prizes.
function Duel:start(first)
  for p = 1, 2 do
    local pl = self.players[p]
    self:shuffle(p)
    self:draw(p, Duel.STARTING_HAND)
    local mulligans = 0
    while not self:hasBasic(p) do
      mulligans = mulligans + 1
      for _, id in ipairs(pl.hand) do pl.deck[#pl.deck + 1] = id end
      pl.hand = {}
      self:shuffle(p)
      self:draw(p, Duel.STARTING_HAND)
      if mulligans > 100 then error("deck " .. p .. " has no Basic Pokemon") end
    end
    if mulligans > 0 then self:say("%s mulliganed %d time(s)", pl.name, mulligans) end
    for _ = 1, self.prizeCount do
      pl.prizes[#pl.prizes + 1] = table.remove(pl.deck, 1)
    end
  end
  self.current = first or (self:coin("first turn") and 1 or 2)
  self.phase = "setup"
  self:say("%s goes first", self.players[self.current].name)
end

-- Setup placement: a Basic from hand becomes the arena card; further Basics
-- may go to the bench.  Both players call this before beginTurn.
-- `force` skips the Basic check (tests and scripted boards only).
function Duel:placeActive(p, id, force)
  local pl, c = self.players[p], self:card(id)
  assert(self.phase == "setup", "not in setup")
  assert(not pl.active, "active already placed")
  assert(force or (c.kind == "pokemon" and c.stage == "BASIC"), "must be a Basic Pokemon")
  assert(removeValue(pl.hand, id), "card not in hand")
  pl.active = newSlot(self, id, 0)
  self:say("%s puts %s in the Arena", pl.name, c.name)
end

-- Setup placement onto the bench (no on-play Powers; turnPlayed = 0 so it
-- can evolve on turn 2 like a starting Pokemon).
function Duel:placeBench(p, id)
  local pl, c = self.players[p], self:card(id)
  assert(self.phase == "setup", "not in setup")
  assert(pl.active, "place the active first")
  assert((c.kind == "pokemon" or c.pseudoPokemon) and c.stage == "BASIC", "must be a Basic Pokemon")
  if #pl.bench >= Duel.MAX_BENCH then return false, "bench full" end
  assert(removeValue(pl.hand, id), "card not in hand")
  pl.bench[#pl.bench + 1] = newSlot(self, id, 0)
  self:say("%s benches %s", pl.name, c.name)
  return true
end

function Duel:finishSetup()
  for p = 1, 2 do assert(self.players[p].active, "player " .. p .. " has no active") end
  self.phase = "play"
  self:beginTurn()
end

-- ---------------------------------------------------------------------
-- turn structure
-- ---------------------------------------------------------------------

function Duel:beginTurn()
  self.turn = self.turn + 1
  local p = self.current
  local pl = self.players[p]
  pl.flags = { attachedEnergy = false, retreated = false, attacked = false }
  -- draw; decking out loses (core.asm: DrawCardFromDeck empty -> lose)
  if #pl.deck == 0 then
    self:say("%s cannot draw a card", pl.name)
    return self:finish(self:opponentOf(p), "deck out")
  end
  local drawn = self:draw(p, 1)
  self:say("--- Turn %d: %s draws %s", self.turn, pl.name, self:card(drawn[1]).name)
end

-- Returns list of { kind = ..., ... } the current player can legally take.
function Duel:legalActions(p)
  p = p or self.current
  if self.finished or p ~= self.current then return {} end
  local pl = self.players[p]
  local acts = {}
  if not pl.active then
    for loc = 1, #pl.bench do acts[#acts + 1] = { kind = "promote", location = loc } end
    return acts
  end
  for _, id in ipairs(pl.hand) do
    local c = self:card(id)
    if c.kind == "pokemon" or c.pseudoPokemon then
      if c.stage == "BASIC" and #pl.bench < Duel.MAX_BENCH then
        acts[#acts + 1] = { kind = "playBasic", card = id }
      elseif c.stage ~= "BASIC" then
        for loc = 0, #pl.bench do
          if self:canEvolve(p, id, loc) then
            acts[#acts + 1] = { kind = "evolve", card = id, location = loc }
          end
        end
      end
    elseif c.kind == "energy" and not pl.flags.attachedEnergy then
      for loc = 0, #pl.bench do
        acts[#acts + 1] = { kind = "attachEnergy", card = id, location = loc }
      end
    elseif c.kind == "trainer" then
      if not (pl.noTrainersUntil and self.turn <= pl.noTrainersUntil)
        and Effects.canPlayTrainer(self, p, id) then
        acts[#acts + 1] = { kind = "playTrainer", card = id }
      end
    end
  end
  for loc = 0, #pl.bench do
    local slot = self:slotAt(p, loc)
    if slot and Powers.canUse(self, p, slot) then
      acts[#acts + 1] = { kind = "usePower", location = loc }
    end
  end
  if not pl.flags.retreated and #pl.bench > 0 and self:canRetreat(p) then
    for loc = 1, #pl.bench do
      acts[#acts + 1] = { kind = "retreat", location = loc }
    end
  end
  if not pl.flags.attacked then
    local active = pl.active
    local card = self:card(active.card)
    if active.status ~= "asleep" and active.status ~= "paralyzed"
      and not self:sub(active, "cannotAttack") then
      for i, atk in ipairs(card.attacks) do
        if atk.category ~= "POKEMON_POWER" and self:canPay(active, atk.energy)
          and self:sub(active, "disabledAttack") ~= i then
          acts[#acts + 1] = { kind = "attack", index = i }
        end
      end
    end
  end
  acts[#acts + 1] = { kind = "endTurn" }
  return acts
end

function Duel:playBasic(p, id)
  local pl, c = self.players[p], self:card(id)
  if not (c.kind == "pokemon" or c.pseudoPokemon) or c.stage ~= "BASIC" then return false, "not a Basic" end
  if #pl.bench >= Duel.MAX_BENCH then return false, "bench full" end
  if not removeValue(pl.hand, id) then return false, "not in hand" end
  local slot = newSlot(self, id, self.turn)
  pl.bench[#pl.bench + 1] = slot
  self:say("%s benches %s", pl.name, c.name)
  if self.phase == "play" then Powers.onPlay(self, p, slot) end
  return true
end

function Duel:canEvolve(p, id, location)
  local slot = self:slotAt(p, location)
  if not slot then return false end
  local evo = self:card(id)
  if evo.kind ~= "pokemon" or evo.stage == "BASIC" then return false end
  local base = self:card(slot.card)
  -- pre-evolution name must match the card currently on top
  if evo.preEvolutionName ~= base.name then return false end
  -- no evolving a Pokemon put into play or evolved this turn (core.asm
  -- CheckAbleToEvolve: turn 1 of the game and the placement turn are barred)
  if slot.turnPlayed == self.turn or slot.turnEvolved == self.turn then return false end
  if self.turn == 1 then return false end
  if Powers.evolutionBlocked(self) then return false end
  return true
end

function Duel:evolve(p, id, location)
  if not self:canEvolve(p, id, location) then return false, "cannot evolve" end
  local pl, slot = self.players[p], self:slotAt(p, location)
  removeValue(pl.hand, id)
  local old, new = self:card(slot.card), self:card(id)
  -- damage carries over: new HP = new max - damage taken
  local damage = old.hp - slot.hp
  slot.stack[#slot.stack + 1] = id
  slot.card = id
  slot.hp = math.max(0, new.hp - damage)
  slot.turnEvolved = self.turn
  -- evolving cures all special conditions (core.asm EvolvePokemonCard)
  slot.status, slot.poison = "none", 0
  self:clearSubs(slot)
  self:say("%s evolves %s into %s", pl.name, old.name, new.name)
  Powers.onPlay(self, p, slot)
  return true
end

function Duel:attachEnergy(p, id, location)
  local pl, slot = self.players[p], self:slotAt(p, location)
  if pl.flags.attachedEnergy then return false, "already attached energy this turn" end
  if not slot then return false, "no Pokemon there" end
  local c = self:card(id)
  if c.kind ~= "energy" then return false, "not an energy card" end
  if not removeValue(pl.hand, id) then return false, "not in hand" end
  slot.energy[#slot.energy + 1] = id
  pl.flags.attachedEnergy = true
  self:say("%s attaches %s to %s", pl.name, c.name, self:card(slot.card).name)
  return true
end

function Duel:canRetreat(p)
  local pl = self.players[p]
  local active = pl.active
  if active.status == "asleep" or active.status == "paralyzed" then return false end
  if self:sub(active, "cannotRetreat") then return false end
  if self:isPseudo(active) then return false end
  return self:energyCount(active) >= self:retreatCost(p)
end

-- Printed retreat cost minus Dodrio's Retreat Aid (one per benched Dodrio)
function Duel:retreatCost(p)
  local pl = self.players[p]
  local cost = self:card(pl.active.card).retreatCost
  return math.max(0, cost - Powers.retreatDiscount(self, p))
end

-- Retreat: discard `retreatCost` energy (caller may pass which ids; default
-- discards from the end), then swap with bench slot `location`.  Confused
-- Pokemon flip a coin after paying; tails means the retreat fails
-- (core.asm AttemptRetreat).
function Duel:retreat(p, location, energyIds)
  local pl = self.players[p]
  if pl.flags.retreated then return false, "already retreated this turn" end
  if not self:canRetreat(p) then return false, "cannot retreat" end
  local bench = pl.bench[location]
  if not bench then return false, "no bench Pokemon there" end
  local active = pl.active
  local cost = self:retreatCost(p)
  local chosen = energyIds or {}
  if #chosen == 0 then
    -- default: discard the last attached cards until cost is covered
    local paid = 0
    for i = #active.energy, 1, -1 do
      if paid >= cost then break end
      chosen[#chosen + 1] = active.energy[i]
      local c = self:card(active.energy[i])
      paid = paid + (c.type == "TYPE_ENERGY_DOUBLE_COLORLESS" and 2 or 1)
    end
  end
  for _, id in ipairs(chosen) do
    assert(removeValue(active.energy, id), "energy not attached")
    pl.discard[#pl.discard + 1] = id
  end
  pl.flags.retreated = true
  if active.status == "confused" and not self:coin("confused retreat") then
    self:say("%s's %s is confused and fails to retreat", pl.name, self:card(active.card).name)
    return true
  end
  pl.bench[location] = active
  pl.active = bench
  -- leaving the arena clears special conditions (core.asm SwapArenaWithBenchPokemon)
  active.status, active.poison = "none", 0
  self:clearSubs(active)
  self:say("%s retreats %s for %s", pl.name, self:card(active.card).name, self:card(bench.card).name)
  return true
end

function Duel:playTrainer(p, id, args)
  local pl = self.players[p]
  if not Effects.canPlayTrainer(self, p, id) then return false, "cannot play that now" end
  removeValue(pl.hand, id)
  self:say("%s plays %s", pl.name, self:card(id).name)
  local ok, err = Effects.playTrainer(self, p, id, args or {})
  if ok == false then
    -- refund
    pl.hand[#pl.hand + 1] = id
    return false, err
  end
  pl.discard[#pl.discard + 1] = id
  self:checkKnockouts()
  return true
end

function Duel:usePower(p, location, args)
  local slot = self:slotAt(p, location)
  if not slot then return false, "no Pokemon there" end
  if not Powers.canUse(self, p, slot) then return false, "cannot use that power now" end
  local ok, err = Powers.use(self, p, slot, args or {})
  if ok ~= false then self:checkKnockouts() end
  return ok ~= false, err
end

-- ---------------------------------------------------------------------
-- attacking and damage
-- ---------------------------------------------------------------------

-- Porygon's Conversion attacks rewrite a Pokemon's Weakness or Resistance,
-- so the slot's override wins over the card's printed value
function Duel:weaknessOf(slot)
  return slot.weaknessOverride or self:card(slot.card).weakness or {}
end

function Duel:resistanceOf(slot)
  return slot.resistanceOverride or self:card(slot.card).resistance or {}
end

local function has(list, value)
  for _, v in ipairs(list) do if v == value then return true end end
  return false
end

-- home/duel.asm ApplyDamageModifiers_DamageToTarget: weakness doubles,
-- resistance -30, then +10 per PlusPower on the attacker and -20 per
-- Defender on the target; never below 0.
function Duel:modifiedDamage(attacker, target, base, opts)
  opts = opts or {}
  local damage = base
  local effect = { weakness = false, resistance = false }
  if damage > 0 and not opts.ignoreWR then
    local color = POKEMON_COLOR[self:card(attacker.card).type]
    if color and has(self:weaknessOf(target), color) then
      damage = damage * 2; effect.weakness = true
    end
    if color and has(self:resistanceOf(target), color) then
      damage = damage - Duel.RESISTANCE_REDUCTION; effect.resistance = true
    end
  end
  if damage > 0 then
    damage = damage + attacker.plusPower * 10 - target.defender * 20
  end
  return math.max(0, damage), effect
end

-- Damage-taken substatuses on the defender, applied after weakness and
-- resistance the way every card's text specifies.
function Duel:applyDefenderSubs(defender, damage)
  if damage <= 0 then return 0 end
  local reduce = self:sub(defender, "damageReduction")
  if reduce then damage = math.max(0, damage - reduce) end
  if self:sub(defender, "halveDamage") then
    damage = math.floor(damage / 20) * 10
  end
  local threshold = self:sub(defender, "preventUpTo")
  if threshold and damage <= threshold then
    self:say("  the damage is prevented")
    damage = 0
  end
  return damage
end

function Duel:dealDamage(p, target, amount, source)
  if amount <= 0 then return 0 end
  -- Mirror Move (Pidgeotto, Spearow) repeats the final result of the last
  -- attack that hit this Pokemon, so attack damage is recorded on the slot
  if source == nil or source == "attack" then target.lastDamageTaken = amount end
  local before = target.hp
  target.hp = math.max(0, target.hp - amount)
  self:emit("damage", { target = target, amount = amount, source = source,
    big = amount >= 40 })
  self:say("  %s takes %d damage (%d -> %d)%s", self:card(target.card).name,
    amount, before, target.hp, source and (" [" .. source .. "]") or "")
  return before - target.hp
end

-- `args` carries the choices an attack's effect may need (how much Energy to
-- discard, which attack to copy, which type to switch to); handlers default
-- sensibly when it is absent.
function Duel:attack(p, index, args)
  local pl = self.players[p]
  if pl.flags.attacked then return false, "already attacked" end
  local active = pl.active
  local card = self:card(active.card)
  local atk = card.attacks[index]
  if not atk then return false, "no such attack" end
  if atk.category == "POKEMON_POWER" then return false, "that is a Pokemon Power" end
  if active.status == "asleep" or active.status == "paralyzed" then
    return false, "asleep or paralyzed"
  end
  if not self:canPay(active, atk.energy) then return false, "not enough energy" end
  if self:sub(active, "cannotAttack") then return false, "cannot attack this turn" end
  if self:sub(active, "disabledAttack") == index then return false, "that attack is disabled" end
  pl.flags.attacked = true
  local opp = self:opponentOf(p)
  local defender = self.players[opp].active
  self:say("%s's %s uses %s", pl.name, card.name, atk.name)
  self:emit("attack", { player = p, attack = atk, card = card,
    animation = atk.animation, animationName = atk.animationName })

  -- Smokescreen-style: "If the Defending Pokemon tries to attack during your
  -- opponent's next turn, flip a coin.  If tails, that attack does nothing."
  if self:sub(active, "attackCoin") and not self:coin("attack check") then
    self:say("  the attack does nothing")
    self:endTurn()
    return true
  end

  -- confusion: tails -> 20 to self, attack ends (HandleConfusionDamageToSelf)
  if active.status == "confused" and not self:coin("confusion") then
    self:say("  %s is confused and hurts itself", card.name)
    self:dealDamage(p, active, Duel.CONFUSION_SELF_DAMAGE, "confusion")
    self:endTurn()
    return true
  end

  local ctx = {
    duel = self, player = p, opponent = opp,
    attacker = active, defender = defender,
    attack = atk, card = card,
    damage = atk.damage,       -- effects may modify before it lands
    cancelled = false,
    args = args or {},
  }
  Effects.beforeDamage(ctx)
  -- doubled base damage set up by a previous attack (Scyther Swords Dance,
  -- Vaporeon Focus Energy): keyed by attack name
  if self:sub(active, "doubleBase") == atk.name then
    ctx.damage = ctx.damage * 2
    active.sub.doubleBase = nil
  end
  -- Agility / Rapidash-style: prevent all effects of attacks, including damage
  if self:sub(defender, "preventAll") then
    self:say("  %s is protected; no damage or effect", self:card(defender.card).name)
    ctx.cancelled = true
  end
  if not ctx.cancelled and Powers.preventsAttack(self, defender, active) then
    self:say("  %s's Pokemon Power protects it", self:card(defender.card).name)
    ctx.cancelled = true
  end
  if not ctx.cancelled then
    local final = self:modifiedDamage(active, defender, ctx.damage, ctx)
    final = self:applyDefenderSubs(defender, final)
    final = Powers.incomingDamage(self, defender, active, final)
    if final > 0 then
      ctx.dealt = self:dealDamage(p, defender, final, ctx.effectiveness)
    else
      ctx.dealt = 0
    end
    Effects.afterDamage(ctx)
  end
  self:checkKnockouts()
  if not self.finished then self:endTurn() end
  return true
end

-- ---------------------------------------------------------------------
-- knockouts, prizes, win conditions
-- ---------------------------------------------------------------------

function Duel:knockOut(p, slot)
  local pl = self.players[p]
  local name = self:card(slot.card).name
  self:emit("knockOut", { player = p, slot = slot, name = name })
  self:say("  %s's %s is Knocked Out", pl.name, name)
  for _, id in ipairs(slot.stack) do pl.discard[#pl.discard + 1] = id end
  for _, id in ipairs(slot.energy) do pl.discard[#pl.discard + 1] = id end
  if pl.active == slot then
    pl.active = nil
  else
    removeValue(pl.bench, slot)
  end
end

function Duel:takePrize(p, n)
  local pl = self.players[p]
  for _ = 1, n or 1 do
    local id = table.remove(pl.prizes, 1)
    if id then
      pl.hand[#pl.hand + 1] = id
      self:say("  %s takes a prize (%s), %d left", pl.name, self:card(id).name, #pl.prizes)
    end
  end
end

function Duel:checkKnockouts()
  if self.finished then return end
  local kos = { 0, 0 }
  for p = 1, 2 do
    for _, slot in ipairs(self:slots(p)) do
      if slot.hp <= 0 then
        local pseudo = self:isPseudo(slot)
        self:knockOut(p, slot)
        if not pseudo then kos[p] = kos[p] + 1 end
      end
    end
  end
  for p = 1, 2 do
    if kos[p] > 0 then self:takePrize(self:opponentOf(p), kos[p]) end
  end
  self:checkWin()
  if self.finished then return end
  -- a player with no active must promote from the bench; no bench = loss
  for p = 1, 2 do
    local pl = self.players[p]
    if not pl.active then
      if #pl.bench == 0 then return self:finish(self:opponentOf(p), "no Pokemon left") end
      pl.needsPromotion = true
      -- Headless default: the first bench Pokemon steps up at once, so a KO
      -- from a Power, Trainer or Curse mid-turn never leaves the Arena empty.
      -- A UI sets duel.autoPromote = false and calls promote() itself.
      if self:autoPromotes(p) then self:promote(p, 1) end
    end
  end
end

-- duel.autoPromote: true/false for both players, or { [1] = bool, [2] = bool }
-- (a UI sets its own seat to false and prompts; AI seats stay automatic)
function Duel:autoPromotes(p)
  local v = self.autoPromote
  if type(v) == "table" then v = v[p] end
  return v ~= false
end

function Duel:promote(p, location)
  local pl = self.players[p]
  if pl.active then return false, "active already present" end
  local slot = table.remove(pl.bench, location)
  if not slot then return false, "no bench Pokemon there" end
  pl.active = slot
  pl.needsPromotion = nil
  self:say("%s sends out %s", pl.name, self:card(slot.card).name)
  return true
end

function Duel:checkWin()
  if self.finished then return end
  local won = {}
  for p = 1, 2 do
    won[p] = #self.players[p].prizes == 0
  end
  if won[1] and won[2] then return self:finish(0, "both took their last prize") end
  if won[1] then return self:finish(1, "all prizes taken") end
  if won[2] then return self:finish(2, "all prizes taken") end
end

function Duel:finish(winner, reason)
  self.finished = { winner = winner, reason = reason }
  if winner == 0 then self:say("=== Draw: %s", reason)
  else self:say("=== %s wins: %s", self.players[winner].name, reason) end
end

-- ---------------------------------------------------------------------
-- end of turn / between turns
-- ---------------------------------------------------------------------

-- engine/duel/core.asm HandleBetweenTurnsEvents: for the player who just
-- finished, poison damage, sleep coin, paralysis cured, PlusPowers
-- discarded; then for the other player poison damage and sleep coin,
-- Defenders discarded; then knockouts.
function Duel:betweenTurns(p)
  local function poisonAndSleep(slot, owner)
    if not slot then return end
    local name = self:card(slot.card).name
    if slot.poison > 0 then
      self:dealDamage(owner, slot,
        slot.poison == 2 and Duel.DBLPSN_DAMAGE or Duel.PSN_DAMAGE, "poison")
    end
    if slot.status == "asleep" then
      if self:coin("asleep " .. name) then
        slot.status = "none"
        self:say("  %s wakes up", name)
      end
    end
  end
  local mine, theirs = self.players[p], self.players[self:opponentOf(p)]
  poisonAndSleep(mine.active, p)
  if mine.active and mine.active.status == "paralyzed" then
    mine.active.status = "none"
    self:say("  %s is cured of paralysis", self:card(mine.active.card).name)
  end
  for _, s in ipairs(self:slots(p)) do
    if s.plusPower > 0 then
      s.plusPower = 0
      self:say("  PlusPower wears off")
    end
  end
  poisonAndSleep(theirs.active, self:opponentOf(p))
  for _, s in ipairs(self:slots(self:opponentOf(p))) do s.defender = 0 end
  self:checkKnockouts()
end

function Duel:endTurn()
  if self.finished then return end
  local p = self.current
  self:betweenTurns(p)
  if self.finished then return end
  -- promotions are forced before play resumes
  for q = 1, 2 do
    local pl = self.players[q]
    if pl.needsPromotion and self:autoPromotes(q) then
      -- default: first bench Pokemon; a UI seat with autoPromote = false is
      -- left with needsPromotion set and only `promote` actions legal
      self:promote(q, 1)
    end
  end
  self.current = self:opponentOf(p)
  self:beginTurn()
end

-- Card-count invariant for tests: every card is in exactly one zone.
function Duel:census(p)
  local pl = self.players[p]
  local n = #pl.deck + #pl.hand + #pl.discard + #pl.prizes
  for _, s in ipairs(self:slots(p)) do n = n + #s.stack + #s.energy end
  return n
end

return Duel
