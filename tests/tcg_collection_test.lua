-- Boosters, collection, deck rules and save round-trip.
--   TCG_CACHE=<dir> lua tests/tcg_collection_test.lua

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/cards.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local decks = dofile(cacheDir .. "/data/generated/decks.lua")
local boosters = dofile(cacheDir .. "/data/generated/boosters.lua")
local Boosters = require("src.tcg.Boosters")
local Collection = require("src.tcg.Collection")
local Rng = require("src.tcg.Rng")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. msg) end
end

-- 1. boosters: every pack type, many draws, structural rules
local rng = Rng.new(99)
local packKeys = {}
for k in pairs(boosters.packs) do packKeys[#packKeys + 1] = k end
table.sort(packKeys)
local rarityHist = {}
for _, k in ipairs(packKeys) do
  local pack = boosters.packs[k]
  for trial = 1, 40 do
    local drawn = Boosters.generate(pack, boosters, cards, rng)
    check(#drawn == boosters.cardsPerPack, pack.constant .. " has 10 cards (" .. #drawn .. ")")
    local seen, energies, byRarity = {}, 0, { STAR = 0, DIAMOND = 0, CIRCLE = 0 }
    local ok = true
    for _, id in ipairs(drawn) do
      local c = cards.byId[id]
      byRarity[c.rarity] = (byRarity[c.rarity] or 0) + 1
      if c.kind == "energy" then energies = energies + 1
      else
        if seen[id] then ok = false end
        seen[id] = true
        if ("BOOSTER_" .. c.set) ~= pack.set then ok = false end
      end
    end
    check(ok, pack.constant .. " trial " .. trial .. ": no duplicate non-energies, all from the set")
    local amounts = boosters.rarityAmounts[pack.set]
    if pack.energy.kind ~= "function" or pack.energy.address == 0x6387 then
      -- the fixed/random energy is a CIRCLE card on top of the set's amounts;
      -- Energy-type chances (Mystery Trainer/Colorless) draw energies inside
      -- the rarity loop, Double Colorless being a DIAMOND
      check(byRarity.STAR == amounts.rares and byRarity.DIAMOND == amounts.uncommons
        and byRarity.CIRCLE == amounts.commons + amounts.energies,
        pack.constant .. " rarity amounts match the set table")
      check(energies >= amounts.energies, pack.constant .. " has its fixed energy")
    else
      check(energies == 10, pack.constant .. " is an all-energy pack")
    end
    for r, n in pairs(byRarity) do rarityHist[r] = (rarityHist[r] or 0) + n end
  end
end
-- type weighting: a Grass pack should skew Grass
do
  local grass, other = 0, 0
  local pack
  for _, k in ipairs(packKeys) do if boosters.packs[k].constant == "BOOSTER_COLOSSEUM_GRASS" then pack = boosters.packs[k] end end
  for _ = 1, 200 do
    for _, id in ipairs(Boosters.generate(pack, boosters, cards, rng)) do
      local c = cards.byId[id]
      if c.kind == "pokemon" then
        if c.type == "TYPE_PKMN_GRASS" then grass = grass + 1 else other = other + 1 end
      end
    end
  end
  check(grass > other / 6 * 2, ("Grass pack skews Grass (%d grass vs %d other)"):format(grass, other))
end

-- 2. collection + starter + deck rules
do
  local col = Collection.new(cards)
  local main = col:giveStarter("charmander", decks)
  check(#main == 60 and col.decks[1] and #col.decks[1].cards == 60, "starter deck saved in slot 1")
  check(col:totalOwned() > 60, "extra cards added to the collection")
  local ok, errs = col:validateDeck(main)
  check(ok, "starter deck is legal: " .. table.concat(errs, "; "))
  local C = cards.byConstant
  -- 5 of the same name is illegal
  local bad = {}
  for i, id in ipairs(main) do bad[i] = id end
  col:add(C.CHARMANDER, 10)
  local idx = 1
  for i, id in ipairs(bad) do if cards.byId[id].kind == "energy" then idx = i; break end end
  for _ = 1, 5 do bad[idx] = C.CHARMANDER; idx = idx + 1 end
  ok, errs = col:validateDeck(bad)
  check(not ok, "5 Charmander rejected")
  -- basic energy unlimited
  local energyHeavy = {}
  for i = 1, 59 do energyHeavy[i] = C.FIRE_ENERGY end
  energyHeavy[60] = C.CHARMANDER
  col:add(C.FIRE_ENERGY, 60)
  ok = col:validateDeck(energyHeavy)
  check(ok, "59 Fire Energy + 1 Basic is legal")
  -- ownership
  local unowned = {}
  for i = 1, 60 do unowned[i] = C.MEWTWO_LV53 end
  ok, errs = col:validateDeck(unowned)
  check(not ok, "unowned cards rejected")
  -- canAddToDeck
  local work = {}
  for _ = 1, 4 do work[#work + 1] = C.CHARMANDER end
  local can, why = col:canAddToDeck(work, C.CHARMANDER)
  check(not can, "5th Charmander refused: " .. tostring(why))
  can = col:canAddToDeck(work, C.FIRE_ENERGY)
  check(can, "energy can be added")
  -- save round trip
  col.stats.wins = 3
  local text = col:serialize()
  local back, err = Collection.deserialize(cards, text)
  check(back ~= nil, "deserialize: " .. tostring(err))
  if back then
    check(back:count(C.CHARMANDER) == col:count(C.CHARMANDER) and back.stats.wins == 3
      and back.decks[1].name == col.decks[1].name and #back.decks[1].cards == 60, "round trip preserves data")
    check(back.starter == "charmander", "starter remembered")
  end
  check(Collection.deserialize(cards, "garbage(") == nil, "corrupt save rejected")
end

-- built-in deck sizes, including the three the data itself makes over-size
do
  local expected = { UNNAMED_2_DECK = 62, GRASS_AND_PSYCHIC_DECK = 61, RESHUFFLE_DECK = 63 }
  local odd = 0
  for i = 0, 55 do
    local deck = decks[i]
    if deck and deck.constant then
      local want = expected[deck.constant] or 60
      check(deck.total == want,
        ("%s has %d cards (expected %d)"):format(deck.constant, deck.total, want))
      if deck.total ~= 60 then odd = odd + 1 end
    end
  end
  check(odd == 3, "exactly three built-in decks are over-size (" .. odd .. ")")
end

print(("tcg collection tests: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
