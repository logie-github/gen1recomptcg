-- Booster pack generation (docs/tcg-phase1.md, Phase 7), ported from
-- poketcg engine/booster_packs.asm:
--
--   GenerateBoosterPack: energies first (a fixed card, a random energy, or
--   one of the all-energy packs), then non-energies by rarity STAR ->
--   DIAMOND -> CIRCLE using the set's rarity amounts
--   (BoosterSetRarityAmountsTable).  For each non-energy card the type is
--   drawn from the pack's weighted type table restricted to types that still
--   have unpicked viable cards, then a uniform card of that type from the
--   set; after a draw the type's weight drops to max(1, weight - average
--   weight) (UpdateBoosterCardTypesChanceByte).  No card appears twice in a
--   pack (CheckCardAlreadyDrawn), and a pack that runs out of viable cards
--   is regenerated from scratch.
--
-- Inputs are the extracted data/generated/boosters.lua and cards.lua tables
-- and a src/tcg/Rng.lua instance.

local Boosters = {}

local RARITY_ORDER = { "STAR", "DIAMOND", "CIRCLE" }   -- wBoosterCurrentRarity 2,1,0
local RARITY_KEY = { STAR = "rares", DIAMOND = "uncommons", CIRCLE = "commons" }

-- CardTypeTable: card type -> booster card type name
local BOOSTER_TYPE = {
  TYPE_PKMN_FIRE = "FIRE", TYPE_PKMN_GRASS = "GRASS", TYPE_PKMN_LIGHTNING = "LIGHTNING",
  TYPE_PKMN_WATER = "WATER", TYPE_PKMN_FIGHTING = "FIGHTING", TYPE_PKMN_PSYCHIC = "PSYCHIC",
  TYPE_PKMN_COLORLESS = "COLORLESS", TYPE_PKMN_UNUSED = "TRAINER",
  TYPE_TRAINER = "TRAINER", TYPE_TRAINER_UNUSED = "TRAINER",
}
local TYPE_ORDER = { "GRASS", "FIRE", "WATER", "LIGHTNING", "FIGHTING", "PSYCHIC", "COLORLESS", "TRAINER", "ENERGY" }

-- energy generation routines by ROM address (bank 7), see poketcg.sym
local ENERGY_FUNCTIONS = {
  [0x6387] = "random1", [0x6390] = "random10",
  [0x639c] = "lightningFire", [0x63a1] = "waterFighting", [0x63a6] = "grassPsychic",
}
local COLORED = { "GRASS_ENERGY", "FIRE_ENERGY", "WATER_ENERGY", "LIGHTNING_ENERGY", "FIGHTING_ENERGY", "PSYCHIC_ENERGY" }

local function boosterType(card)
  if card.kind == "energy" then return "ENERGY" end
  return BOOSTER_TYPE[card.type] or "TRAINER"
end

-- pack: entry from boosters.lua (`packs[i]`), data: whole boosters.lua
function Boosters.generate(pack, data, cards, rng)
  assert(pack and data and cards and rng, "Boosters.generate(pack, data, cards, rng)")
  local C = cards.byConstant
  for _ = 1, 50 do
    local drawn, seen = {}, {}
    local function add(id) drawn[#drawn + 1] = id; seen[id] = true end

    -- energies (GenerateBoosterEnergies)
    local amounts = data.rarityAmounts[pack.set]
    local rarityLeft = { STAR = amounts.rares, DIAMOND = amounts.uncommons, CIRCLE = amounts.commons }
    local e = pack.energy
    if e.kind == "card" then
      add(e.card)
    elseif e.kind == "function" then
      local fn = ENERGY_FUNCTIONS[e.address]
      if fn == "random1" then
        add(C[COLORED[rng:int(1, #COLORED)]])
      elseif fn == "random10" then
        for _ = 1, data.cardsPerPack do add(C[COLORED[rng:int(1, #COLORED)]]) end
        rarityLeft = { STAR = 0, DIAMOND = 0, CIRCLE = 0 }
      elseif fn then
        local pair = ({ lightningFire = { "LIGHTNING_ENERGY", "FIRE_ENERGY" },
          waterFighting = { "WATER_ENERGY", "FIGHTING_ENERGY" },
          grassPsychic = { "GRASS_ENERGY", "PSYCHIC_ENERGY" } })[fn]
        for _, name in ipairs(pair) do for _ = 1, data.cardsPerPack / 2 do add(C[name]) end end
        rarityLeft = { STAR = 0, DIAMOND = 0, CIRCLE = 0 }
      end
    end
    -- non-energies (GenerateBoosterNonEnergies)
    local chances = {}
    local sum, n = 0, 0
    for _, t in ipairs(TYPE_ORDER) do
      chances[t] = pack.typeChances[t] or 0
      if chances[t] > 0 then sum = sum + chances[t]; n = n + 1 end
    end
    local averaged = n > 0 and math.floor(sum / n) or 0
    local failed = false

    for _, rarity in ipairs(RARITY_ORDER) do
      while rarityLeft[rarity] > 0 and not failed do
        -- FindCardsInSetAndRarity
        local viable, count = {}, {}
        for id = 1, cards.count do
          local card = cards.byId[id]
          if card and not seen[id] and card.rarity == rarity then
            local bt = boosterType(card)
            local setName = card.set and card.set:gsub("^CARD_SET_", "")
            if bt == "ENERGY" or ("BOOSTER_" .. setName) == pack.set then
              viable[#viable + 1] = { id = id, type = bt }
              count[bt] = (count[bt] or 0) + 1
            end
          end
        end
        -- CalculateTypeChances
        local total, temp = 0, {}
        for _, t in ipairs(TYPE_ORDER) do
          if (count[t] or 0) > 0 and chances[t] > 0 then temp[t] = chances[t]; total = total + chances[t] end
        end
        if total == 0 then failed = true; break end
        -- DetermineBoosterCardType
        local r = rng:int(1, total) - 1
        local picked = "ENERGY"
        for _, t in ipairs(TYPE_ORDER) do
          if temp[t] then
            r = r - temp[t]
            if r < 0 then picked = t; break end
          end
        end
        -- DetermineBoosterCard: uniform among viable cards of that type
        local k = rng:int(1, count[picked] or 1) - 1
        local chosen
        for _, v in ipairs(viable) do
          if v.type == picked then
            if k == 0 then chosen = v.id; break end
            k = k - 1
          end
        end
        if not chosen then failed = true; break end
        add(chosen)
        -- UpdateBoosterCardTypesChanceByte
        chances[picked] = math.max(1, chances[picked] - averaged)
        rarityLeft[rarity] = rarityLeft[rarity] - 1
      end
      if failed then break end
    end
    if not failed then return drawn end
  end
  error("booster generation could not find viable cards for " .. tostring(pack.constant))
end

Boosters.boosterType = boosterType

return Boosters
