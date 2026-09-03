-- Pokemon Trading Card Game (US, GBC) importer.  Counterpart to RomExtractor
-- (Gen 1) and RomExtractorGen2, driven by tools/rom_manifest_tcg.json which
-- tools/make_tcg_manifest.py derives from pret/poketcg + poketcg.sym.
--
-- What it reads from the user's ROM:
--   cards      CardPointers -> per-card structs (card_data_constants.asm)
--   text       TextOffsets  -> every text entry, decoded through the
--                              half-width charmap; control codes become
--                              {RAM1}/{RAM2}/{RAM3}/{SYM:xx} markers
--   card art   CardGraphics -> 64x48 2bpp + CGB palette, one PNG per card
--   decks      DeckPointers -> (count, cardId) lists + name text id
--   boosters   BoosterDataJumptable -> set, energy rule, type weights
--   fonts      half-width 1bpp, symbols 2bpp
--   duel gfx   card headers, symbols, box messages, misc
--
-- Output layout matches the other extractors: data/generated/*.lua and
-- assets/generated/**/*.png under the version's cache prefix.
--
-- The `backend` argument abstracts file/image output so the same extractor
-- runs under LÖVE (CacheFs + love.image) and under plain Lua
-- (tools/tcg_extract_cli.lua with PngWriter + io.*).  Bit manipulation is
-- done arithmetically for LuaJIT/5.1 compatibility.

local Rom = require("src.import.Rom")

local RomExtractorTcg = {}
RomExtractorTcg.__index = RomExtractorTcg

local STAGES = {
  "constants", "text", "cards", "card_art", "decks", "boosters", "fonts", "duel_gfx", "audio",
}
local STAGE_COUNT = #STAGES
local BANK_SIZE = 0x4000

-- ---------------------------------------------------------------------
-- backends
-- ---------------------------------------------------------------------

local function loveBackend()
  local LuaWriter = require("src.import.LuaWriter")
  local CacheFs = require("src.import.CacheFs")
  return {
    writeLua = function(rel, value) LuaWriter.write(rel, value) end,
    newImage = function(w, h) return love.image.newImageData(w, h) end,
    setPixel = function(img, x, y, r, g, b, a)
      img:setPixel(x, y, r / 255, g / 255, b / 255, (a or 255) / 255)
    end,
    savePng = function(img, rel)
      local fileData = img:encode("png")
      local ok, err = CacheFs.write(rel, fileData:getString())
      if not ok then error("could not write " .. rel .. ": " .. tostring(err)) end
    end,
    writeBinary = function(rel, data)
      local ok, err = CacheFs.write(rel, data)
      if not ok then error("could not write " .. rel .. ": " .. tostring(err)) end
    end,
  }
end

function RomExtractorTcg.headlessBackend(root)
  local LuaWriter = require("src.import.LuaWriter")
  local PngWriter = require("src.import.PngWriter")
  local function ensureDir(path)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then os.execute(('mkdir -p "%s"'):format(dir)) end
  end
  local function writeFile(rel, data)
    local path = root .. "/" .. rel
    ensureDir(path)
    local f = assert(io.open(path, "wb"))
    f:write(data); f:close()
  end
  return {
    writeLua = function(rel, value) writeFile(rel, LuaWriter.encode(value)) end,
    newImage = PngWriter.newImage,
    setPixel = PngWriter.setPixel,
    savePng = function(img, rel) writeFile(rel, PngWriter.encode(img)) end,
    writeBinary = writeFile,
  }
end

-- ---------------------------------------------------------------------
-- construction / progress
-- ---------------------------------------------------------------------

function RomExtractorTcg.new(romData, manifest, progress, romSha1, backend)
  local self = setmetatable({
    rom = Rom.new(romData),
    manifest = manifest,
    symbols = manifest.symbols,
    progress = progress,
    romSha1 = romSha1,
    backend = backend or loveBackend(),
    stage = 0,
    stats = {},
  }, RomExtractorTcg)
  -- charmap keys arrive as strings from JSON
  self.charmap = {}
  for k, v in pairs(manifest.charmap) do self.charmap[tonumber(k)] = v end
  self.tx = manifest.textControl
  return self
end

function RomExtractorTcg:symbol(name)
  local location = self.symbols[name]
  if not location then error("required symbol is missing: " .. tostring(name)) end
  return { bank = location[1], address = location[2], name = name }
end

function RomExtractorTcg:beginStage(name)
  self.stage = self.stage + 1
  if self.progress then self.progress(self.stage - 1, STAGE_COUNT, name, 0, 1) end
end

function RomExtractorTcg:tick(name, current, total)
  if self.progress then
    self.progress(self.stage - 1 + current / total, STAGE_COUNT, name, current, total)
  end
end

function RomExtractorTcg:write(name, value)
  self.backend.writeLua("data/generated/" .. name .. ".lua", value)
end

-- absolute ROM offset <-> (bank, address)
local function absolute(bank, address)
  if bank == 0 then return address end
  return bank * BANK_SIZE + (address - BANK_SIZE)
end

local function located(abs)
  local bank = math.floor(abs / BANK_SIZE)
  local address = abs % BANK_SIZE
  if bank > 0 then address = address + BANK_SIZE end
  return bank, address
end

function RomExtractorTcg:byteAbs(abs)
  local value = self.rom.data:byte(abs + 1)
  assert(value, ("ROM read past end at abs %06X"):format(abs))
  return value
end

-- Name lookups from manifest enum tables (string keys).
local function enumName(tbl, value, fallback)
  return tbl[tostring(value)] or fallback or ("UNKNOWN_" .. tostring(value))
end

local function flagNames(tbl, value)
  local out = {}
  for bitValue, name in pairs(tbl) do
    local b = tonumber(bitValue)
    if math.floor(value / b) % 2 == 1 then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

-- ---------------------------------------------------------------------
-- text
-- ---------------------------------------------------------------------

function RomExtractorTcg:textBase()
  local t = self:symbol("TextOffsets")
  return absolute(t.bank, t.address)
end

-- Decode one text entry at absolute offset `abs`.  Returns string.
-- Line breaks are "\n"; RAM substitutions become {RAM1}/{RAM2}/{RAM3};
-- symbol-font glyphs become {SYM:xx}; full-width (Japanese) sequences are
-- preserved as {FW:n:xx} so nothing is silently lost.
function RomExtractorTcg:decodeText(abs, limit)
  local tx, charmap = self.tx, self.charmap
  local out = {}
  local pos = abs
  local fullwidth = false
  for _ = 1, limit or 4096 do
    local b = self:byteAbs(pos); pos = pos + 1
    if b == tx.TX_END then
      return table.concat(out), pos - abs
    elseif b == tx.TX_HALFWIDTH then
      fullwidth = false
    elseif b == tx.TX_HALF2FULL then
      fullwidth = true
    elseif b == tx.TX_LINE then
      out[#out + 1] = "\n"
    elseif b == tx.TX_RAM1 then
      out[#out + 1] = "{RAM1}"
    elseif b == tx.TX_RAM2 then
      out[#out + 1] = "{RAM2}"
    elseif b == tx.TX_RAM3 then
      out[#out + 1] = "{RAM3}"
    elseif b == tx.TX_SYMBOL then
      local sym = self:byteAbs(pos); pos = pos + 1
      out[#out + 1] = ("{SYM:%02X}"):format(sym)
    elseif b <= 0x04 then
      -- TX_FULLWIDTH0..4: next byte is a full-width glyph index
      local g = self:byteAbs(pos); pos = pos + 1
      out[#out + 1] = ("{FW:%d:%02X}"):format(b, g)
    elseif b == 0x0e or b == 0x0f then
      out[#out + 1] = ("{CTRL:%02X}"):format(b)
    elseif fullwidth then
      local g = self:byteAbs(pos); pos = pos + 1
      out[#out + 1] = ("{FW:%02X%02X}"):format(b, g)
    else
      out[#out + 1] = charmap[b] or ("{BYTE:%02X}"):format(b)
    end
  end
  error(("unterminated text at abs %06X"):format(abs))
end

function RomExtractorTcg:textOffset(id)
  -- 3-byte little-endian offset relative to TextOffsets, entry size 3
  local base = self:textBase()
  local e = base + id * 3
  return self:byteAbs(e) + self:byteAbs(e + 1) * 0x100 + self:byteAbs(e + 2) * 0x10000
end

function RomExtractorTcg:textById(id)
  if id == 0 then return nil end
  if not self.textCache then self.textCache = {} end
  local cached = self.textCache[id]
  if cached then return cached end
  local s = self:decodeText(self:textBase() + self:textOffset(id))
  self.textCache[id] = s
  return s
end

function RomExtractorTcg:extractText()
  self:beginStage("text")
  local labels = self.manifest.textLabels
  local byId, byLabel = {}, {}
  local total = #labels - 1
  for id = 1, total do
    local label = labels[id + 1]  -- Lua 1-based; entry 0 is the null row
    local s = self:textById(id)
    byId[id] = s
    if label and label ~= "NULL" then byLabel[label] = id end
    if id % 64 == 0 then self:tick("text", id, total) end
  end
  self:write("text", { byId = byId, byLabel = byLabel, count = total })
  self.stats.texts = total
end

-- ---------------------------------------------------------------------
-- cards
-- ---------------------------------------------------------------------

local function energyCost(bytes)
  -- 4 bytes, one nybble per type in order FIRE,GRASS,LIGHTNING,WATER,
  -- FIGHTING,PSYCHIC,COLORLESS,UNUSED (see `energy` macro: type t lives in
  -- byte t/2, high nybble when t is even, low when odd).
  local names = { "FIRE", "GRASS", "LIGHTNING", "WATER", "FIGHTING", "PSYCHIC", "COLORLESS", "UNUSED" }
  local cost = {}
  for t = 0, 7 do
    local byte = bytes[math.floor(t / 2) + 1]
    local n = (t % 2 == 0) and math.floor(byte / 16) or (byte % 16)
    if n > 0 then cost[names[t + 1]] = n end
  end
  return cost
end

function RomExtractorTcg:readAttack(abs)
  local b = function(o) return self:byteAbs(abs + o) end
  local w = function(o) return b(o) + b(o + 1) * 0x100 end
  local nameId = w(4)
  if nameId == 0 and w(6) == 0 and b(11) == 0 then return nil end
  local enums = self.manifest.enums
  local category = b(11)
  return {
    energy = energyCost({ b(0), b(1), b(2), b(3) }),
    name = self:textById(nameId),
    nameId = nameId,
    description = self:textById(w(6)),
    descriptionCont = self:textById(w(8)),
    damage = b(10),
    category = enumName(enums.categories, category % 128),
    residual = category >= 128,
    effectCommands = w(12),        -- ROM pointer (bank-local); resolved later by the duel engine port
    flags1 = flagNames(enums.attackFlag1, b(14)),
    flags2 = flagNames(enums.attackFlag2, b(15)),
    flags3 = flagNames(enums.attackFlag3, b(16)),
    effectParam = b(17),
    animation = b(18),
  }
end

function RomExtractorTcg:readCard(id, label)
  local cp = self:symbol("CardPointers")
  local ptr = self.rom:word(cp.bank, cp.address + id * 2)
  if ptr == 0 then return nil end
  local abs = absolute(cp.bank, ptr)
  local b = function(o) return self:byteAbs(abs + o) end
  local w = function(o) return b(o) + b(o + 1) * 0x100 end
  local enums = self.manifest.enums
  local typeByte = b(0)
  local card = {
    id = id,
    label = label,
    constant = self.manifest.cardIds[tostring(id)],
    type = enumName(enums.cardTypes, typeByte),
    gfxIndex = w(1),
    gfxLabel = self.manifest.cardGfxLabels[tostring(w(1))],
    nameId = w(3),
    name = self:textById(w(3)),
    rarity = enumName(enums.rarity, b(5)),
    set = enumName(enums.sets, math.floor(b(6) / 16)),
    set2 = enumName(enums.sets2, b(6) % 16, "NONE"),
  }
  if typeByte < 8 then
    card.kind = "pokemon"
    card.hp = b(8)
    card.stage = enumName(enums.stages, b(9))
    card.preEvolutionNameId = w(10)
    card.preEvolutionName = self:textById(w(10))
    card.attacks = {}
    local a1 = self:readAttack(abs + 0x0c)
    local a2 = self:readAttack(abs + 0x1f)
    if a1 then card.attacks[1] = a1 end
    if a2 then card.attacks[#card.attacks + 1] = a2 end
    card.retreatCost = b(0x32)
    card.weakness = flagNames(self:wrTable(), b(0x33))
    card.resistance = flagNames(self:wrTable(), b(0x34))
    card.category = self:textById(w(0x35))
    card.pokedexNumber = b(0x37)
    card.level = b(0x39)
    card.length = { feet = b(0x3a), inches = b(0x3b) }
    card.weight = w(0x3c)
    card.description = self:textById(w(0x3e))
    card.aiInfo = b(0x40)
  else
    card.kind = typeByte >= 16 and "trainer" or "energy"
    card.effectCommands = w(8)
    card.description = self:textById(w(10))
    card.descriptionCont = self:textById(w(12))
  end
  return card
end

function RomExtractorTcg:wrTable()
  if not self._wr then
    self._wr = {}
    for name, value in pairs(self.manifest.enums.weaknessBits) do
      self._wr[tostring(value)] = name:gsub("^WR_", "")
    end
  end
  return self._wr
end

function RomExtractorTcg:extractCards()
  self:beginStage("cards")
  local labels = self.manifest.cardLabels
  local cards, byConstant = {}, {}
  local total = #labels - 1
  for id = 1, total do
    local card = self:readCard(id, labels[id + 1])
    cards[id] = card
    if card and card.constant then byConstant[card.constant] = id end
    if id % 16 == 0 then self:tick("cards", id, total) end
  end
  self.cards = cards
  self:write("cards", { byId = cards, byConstant = byConstant, count = total })
  self.stats.cards = total
end

-- ---------------------------------------------------------------------
-- card art
-- ---------------------------------------------------------------------

local function cgbColor(lo, hi)
  local v = lo + hi * 0x100
  local r = v % 32
  local g = math.floor(v / 32) % 32
  local b = math.floor(v / 1024) % 32
  -- 5-bit to 8-bit
  return math.floor(r * 255 / 31 + 0.5), math.floor(g * 255 / 31 + 0.5), math.floor(b * 255 / 31 + 0.5)
end

-- `columns` = true for data built with `rgbgfx --columns` (card art), where
-- tiles run top-to-bottom within each 8px column before the next column.
function RomExtractorTcg:decode2bppPaletted(abs, width, height, palette, columns)
  local be = self.backend
  local img = be.newImage(width, height)
  local tilesPerRow = width / 8
  local tilesPerCol = height / 8
  local tiles = tilesPerRow * tilesPerCol
  for tile = 0, tiles - 1 do
    local tileX, tileY
    if columns then
      tileX = math.floor(tile / tilesPerCol) * 8
      tileY = (tile % tilesPerCol) * 8
    else
      tileX = (tile % tilesPerRow) * 8
      tileY = math.floor(tile / tilesPerRow) * 8
    end
    for y = 0, 7 do
      local low = self:byteAbs(abs + tile * 16 + y * 2)
      local high = self:byteAbs(abs + tile * 16 + y * 2 + 1)
      for x = 0, 7 do
        local divisor = 2 ^ (7 - x)
        local shade = math.floor(high / divisor) % 2 * 2 + math.floor(low / divisor) % 2
        local c = palette[shade + 1]
        be.setPixel(img, tileX + x, tileY + y, c[1], c[2], c[3], 255)
      end
    end
  end
  return img
end

local GRAY = { { 255, 255, 255 }, { 170, 170, 170 }, { 85, 85, 85 }, { 0, 0, 0 } }

function RomExtractorTcg:extractCardArt()
  self:beginStage("card_art")
  local cg = self:symbol("CardGraphics")
  local base = absolute(cg.bank, cg.address)
  local art = self.manifest.layout.cardArt
  local tileBytes = art.tiles * 16
  local total = #self.cards
  local index = {}
  for id = 1, total do
    local card = self.cards[id]
    if card then
      local abs = base + card.gfxIndex * 8
      local palette = {}
      for i = 0, 3 do
        local lo = self:byteAbs(abs + tileBytes + i * 2)
        local hi = self:byteAbs(abs + tileBytes + i * 2 + 1)
        palette[i + 1] = { cgbColor(lo, hi) }
      end
      local img = self:decode2bppPaletted(abs, art.width, art.height, palette, true)
      local rel = ("cards/%03d.png"):format(id)
      self.backend.savePng(img, "assets/generated/" .. rel)
      index[id] = { file = rel, palette = palette, gfxLabel = card.gfxLabel }
    end
    if id % 8 == 0 then self:tick("card_art", id, total) end
  end
  self:write("card_art", index)
  self.stats.cardArt = total
end

-- ---------------------------------------------------------------------
-- decks and boosters
-- ---------------------------------------------------------------------

function RomExtractorTcg:extractDecks()
  self:beginStage("decks")
  local dp = self:symbol("DeckPointers")
  local labels = self.manifest.deckLabels
  local decks = {}
  for i, label in ipairs(labels) do
    local deckIndex = i - 1
    local ptr = (label ~= "NULL") and self.rom:word(dp.bank, dp.address + deckIndex * 2) or 0
    if ptr ~= 0 then
    local abs = absolute(dp.bank, ptr)
    local cards, pos, totalCards = {}, abs, 0
    while true do
      local count = self:byteAbs(pos)
      if count == 0 then pos = pos + 1; break end
      local cardId = self:byteAbs(pos + 1)
      cards[#cards + 1] = { count = count, card = cardId,
        constant = self.manifest.cardIds[tostring(cardId)] }
      totalCards = totalCards + count
      pos = pos + 2
    end
    -- UnnamedDeck/UnnamedDeck2 (data/decks.asm) are runs of several
    -- unnamed lists with no trailing `tx`; every other deck ends with a
    -- text pointer to its name.
    local nameId = 0
    if not label:match("^Unnamed") then
      nameId = self:byteAbs(pos) + self:byteAbs(pos + 1) * 0x100
      if nameId >= #self.manifest.textLabels then
        error(("deck %s: name text id %d out of range"):format(label, nameId))
      end
    end
    decks[deckIndex] = {
      index = deckIndex,
      label = label,
      constant = self.manifest.deckIds[tostring(deckIndex)],
      nameId = nameId,
      name = self:textById(nameId),
      cards = cards,
      total = totalCards,
    }
    end
    self:tick("decks", i, #labels)
  end
  self:write("decks", decks)
  self.stats.decks = #labels
end

function RomExtractorTcg:extractBoosters()
  self:beginStage("boosters")
  local jt = self:symbol("BoosterDataJumptable")
  local rarity = self:symbol("BoosterSetRarityAmountsTable")
  local enums = self.manifest.enums
  local typeNames = { "GRASS", "FIRE", "WATER", "LIGHTNING", "FIGHTING", "PSYCHIC", "COLORLESS", "TRAINER", "ENERGY" }
  local boosters = {}
  local count = self.manifest.layout.numBoosters
  for i = 0, count - 1 do
    local ptr = self.rom:word(jt.bank, jt.address + i * 2)
    local abs = absolute(jt.bank, ptr)
    local set = self:byteAbs(abs)
    local energy = self:byteAbs(abs + 1) + self:byteAbs(abs + 2) * 0x100
    local chances = {}
    for t = 1, 9 do chances[typeNames[t]] = self:byteAbs(abs + 2 + t) end
    local energyRule
    if energy == 0 then energyRule = { kind = "none" }
    elseif energy < 0x100 then energyRule = { kind = "card", card = energy,
      constant = self.manifest.cardIds[tostring(energy)] }
    else energyRule = { kind = "function", address = energy } end
    boosters[i] = {
      index = i,
      constant = enumName(enums.boosters, i),
      set = enumName(enums.boosterSets, set),
      energy = energyRule,
      typeChances = chances,
    }
  end
  local rarityAmounts = {}
  for s = 0, 3 do
    rarityAmounts[enumName(enums.boosterSets, s)] = {
      energies = self.rom:byte(rarity.bank, rarity.address + s * 4),
      commons = self.rom:byte(rarity.bank, rarity.address + s * 4 + 1),
      uncommons = self.rom:byte(rarity.bank, rarity.address + s * 4 + 2),
      rares = self.rom:byte(rarity.bank, rarity.address + s * 4 + 3),
    }
  end
  self:write("boosters", { packs = boosters, rarityAmounts = rarityAmounts,
    cardsPerPack = self.manifest.layout.boosterCards })
  self.stats.boosters = count
end

-- ---------------------------------------------------------------------
-- fonts and duel graphics
-- ---------------------------------------------------------------------

function RomExtractorTcg:decode1bpp(abs, width, height)
  local be = self.backend
  local img = be.newImage(width, height)
  local tilesPerRow = width / 8
  local tiles = (width / 8) * (height / 8)
  for tile = 0, tiles - 1 do
    local tileX = (tile % tilesPerRow) * 8
    local tileY = math.floor(tile / tilesPerRow) * 8
    for y = 0, 7 do
      local row = self:byteAbs(abs + tile * 8 + y)
      for x = 0, 7 do
        local on = math.floor(row / 2 ^ (7 - x)) % 2 == 1
        if on then be.setPixel(img, tileX + x, tileY + y, 0, 0, 0, 255)
        else be.setPixel(img, tileX + x, tileY + y, 255, 255, 255, 0) end
      end
    end
  end
  return img
end

function RomExtractorTcg:extractFonts()
  self:beginStage("fonts")
  local half = self:symbol("HalfWidthFont")
  -- half_width.png is 64x96 (8x12 tiles, 1bpp)
  self.backend.savePng(self:decode1bpp(absolute(half.bank, half.address), 64, 96),
    "assets/generated/fonts/half_width.png")
  local sym = self:symbol("SymbolsFont")
  -- symbols.png is 64x56 (8x7 tiles, 2bpp)
  self.backend.savePng(self:decode2bppPaletted(absolute(sym.bank, sym.address), 64, 56, GRAY),
    "assets/generated/fonts/symbols.png")
  self:write("fonts", {
    halfWidth = { file = "fonts/half_width.png", tileWidth = 8, tileHeight = 8,
      -- glyph index = byte - 0x20 for the printable half-width range
      firstCode = 0x20 },
    symbols = { file = "fonts/symbols.png", tileWidth = 8, tileHeight = 8 },
  })
end

function RomExtractorTcg:extractDuelGraphics()
  self:beginStage("duel_gfx")
  -- (symbol, width, height) for raw 2bpp blocks whose png dimensions are
  -- known from poketcg/src/gfx/duel/*.png
  local blocks = {
    { "DuelCardHeaderGraphics", 64, 48, "duel/card_headers.png" },
    { "DuelDmgSgbSymbolGraphics", 64, 136, "duel/dmg_sgb_symbols.png" },
    { "DuelCgbSymbolGraphics", 64, 136, "duel/cgb_symbols.png" },
    { "DuelOtherGraphics", 64, 56, "duel/other.png" },
    { "DuelBoxMessages", 80, 224, "duel/box_messages.png" },
  }
  local written = {}
  for i, spec in ipairs(blocks) do
    local name, w, h, rel = spec[1], spec[2], spec[3], spec[4]
    local sizes = self.manifest.duelGfxSizes and self.manifest.duelGfxSizes[name]
    if sizes then w, h = sizes[1], sizes[2] end
    if self.symbols[name] then
      local s = self:symbol(name)
      local ok, err = pcall(function()
        local img = self:decode2bppPaletted(absolute(s.bank, s.address), w, h, GRAY)
        self.backend.savePng(img, "assets/generated/" .. rel)
      end)
      if ok then written[name] = rel else written[name] = "ERROR: " .. tostring(err) end
    end
    self:tick("duel_gfx", i, #blocks)
  end
  self:write("duel_gfx", written)
end

-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- audio (audio/music1.asm)
-- ---------------------------------------------------------------------

-- Song programs live in whole ROM banks and jump/call within them, so the
-- banks a song's channels point into are copied verbatim into the cache the
-- way the Gen 1 importer copies audio program banks; the driver
-- (src/tcg/audio/MusicPlayer.lua) interprets them at run time.
function RomExtractorTcg:audioTables(engine)
  local suffix = engine == 2 and "Music2_" or "Music1_"
  local function sym(name) return self:symbol(suffix .. name) end
  local function bytesAt(s, n)
    local out = {}
    for i = 0, n - 1 do out[i] = self.rom:byte(s.bank, s.address + i) end
    return out
  end
  local octaveOffsets = bytesAt(sym("OctaveOffsets"), 8)
  local pitchSym, waveSym = sym("Pitches"), sym("WaveInstruments")
  local pitches = {}
  for i = 0, math.floor((waveSym.address - pitchSym.address) / 2) - 1 do
    pitches[i] = self.rom:word(pitchSym.bank, pitchSym.address + i * 2)
  end
  local waves = {}
  for i = 0, 4 do
    local ptr = self.rom:word(waveSym.bank, waveSym.address + i * 2)
    local samples = {}
    for b = 0, 15 do
      local byte = self.rom:byte(waveSym.bank, ptr + b)
      samples[#samples + 1] = math.floor(byte / 16)
      samples[#samples + 1] = byte % 16
    end
    waves[i] = samples
  end
  local noiseSym = sym("NoiseInstruments")
  local noise = {}
  for i = 0, 11 do
    local ptr = self.rom:word(noiseSym.bank, noiseSym.address + i * 2)
    local bytes = {}
    for offset = 0, 63 do
      local b = self.rom:byte(noiseSym.bank, ptr + offset)
      if b == 0xff then break end
      bytes[#bytes + 1] = b
    end
    noise[i] = bytes
  end
  local vibSym = sym("VibratoTypes")
  local vibrato = {}
  for i = 0, 10 do
    local ptr = self.rom:word(vibSym.bank, vibSym.address + i * 2)
    local bytes = {}
    for offset = 0, 63 do
      local b = self.rom:byte(vibSym.bank, ptr + offset)
      bytes[#bytes + 1] = b
      if b == 0x80 then break end
    end
    vibrato[i] = bytes
  end
  return { octaveOffsets = octaveOffsets, pitches = pitches, waves = waves,
    noise = noise, vibrato = vibrato }
end

-- Song programs live in whole ROM banks and jump/call within them, so every
-- bank a song points into is copied verbatim into the cache; the driver
-- (src/tcg/audio/MusicPlayer.lua) interprets them at run time.  poketcg has
-- two sound engines with identical command sets but their own pitch, wave,
-- noise and vibrato tables (audio/music1.asm and music2.asm); a song is
-- owned by whichever engine's header table has a non-NULL entry for it.
function RomExtractorTcg:extractAudio()
  self:beginStage("audio")
  local labels1 = self.manifest.songLabels or {}
  local labels2 = self.manifest.songLabels2 or {}
  local count = math.max(#labels1, #labels2)
  if count == 0 or not self.symbols.SongBanks1 then
    self:write("audio", { songs = {}, available = false })
    return
  end
  local songs, needed = {}, {}
  local function readHeader(engine, index)
    local banks = self:symbol(engine == 2 and "SongBanks2" or "SongBanks1")
    local ptrs = self:symbol(engine == 2 and "SongHeaderPointers2" or "SongHeaderPointers1")
    local bank = self.rom:byte(banks.bank, banks.address + index)
    local address = self.rom:word(ptrs.bank, ptrs.address + index * 2)
    if address < 0x4000 or address >= 0x8000 then return nil end
    local mask = self.rom:byte(bank, address)
    if mask == 0 then return nil end
    local channels, cursor = {}, address + 1
    for ch = 1, 4 do
      if math.floor(mask / 2 ^ (ch - 1)) % 2 == 1 then
        channels[ch] = self.rom:word(bank, cursor)
        cursor = cursor + 2
      end
    end
    return { bank = bank, address = address, mask = mask, channels = channels }
  end

  for i = 0, count - 1 do
    local label1, label2 = labels1[i + 1], labels2[i + 1]
    local engine, header, label
    if label1 and label1 ~= "NULL" then
      header, engine, label = readHeader(1, i), 1, label1
    end
    if not header and label2 and label2 ~= "NULL" then
      header, engine, label = readHeader(2, i), 2, label2
    end
    local song = { index = i, label = label or "NULL", engine = engine or 1 }
    if header then
      song.bank, song.address, song.mask, song.channels =
        header.bank, header.address, header.mask, header.channels
      needed[header.bank] = true
    else
      song.channels = {}
    end
    songs[i] = song
  end

  local bankList, blob, order = {}, {}, {}
  for bank in pairs(needed) do order[#order + 1] = bank end
  table.sort(order)
  for index, bank in ipairs(order) do
    bankList[bank] = index - 1
    local first = bank * 0x4000 + 1
    blob[#blob + 1] = self.rom.data:sub(first, first + 0x4000 - 1)
    self:tick("audio", index, #order)
  end
  self.backend.writeBinary("assets/generated/audio/music_banks.bin", table.concat(blob))

  -- sound effects (audio/sfx.asm): headers are a channel mask plus a command
  -- pointer per active channel, all inside the SFX bank, which is copied the
  -- same way the song banks are.
  local sfx = {}
  if self.symbols.SFXHeaderPointers then
    local ptrs = self:symbol("SFXHeaderPointers")
    local labels = self.manifest.sfxLabels or {}
    for i = 0, #labels - 1 do
      local address = self.rom:word(ptrs.bank, ptrs.address + i * 2)
      local entry = { index = i, label = labels[i + 1],
        constant = (self.manifest.sfxIds or {})[tostring(i)], bank = ptrs.bank }
      if address >= 0x4000 and address < 0x8000 then
        local mask = self.rom:byte(ptrs.bank, address)
        entry.mask = mask
        entry.channels = {}
        local cursor = address + 1
        -- SFX_Play advances the source pointer only for channels the mask
        -- selects (the skip path bumps the destination, not the source)
        for ch = 1, 4 do
          if math.floor(mask / 2 ^ (ch - 1)) % 2 == 1 then
            entry.channels[ch] = self.rom:word(ptrs.bank, cursor)
            cursor = cursor + 2
          end
        end
      end
      sfx[i] = entry
    end
    if not bankList[ptrs.bank] then
      bankList[ptrs.bank] = #order
      local first = ptrs.bank * 0x4000 + 1
      blob[#blob + 1] = self.rom.data:sub(first, first + 0x4000 - 1)
      self.backend.writeBinary("assets/generated/audio/music_banks.bin", table.concat(blob))
    end
    -- SFX wave instruments: 5 pointers, 16 bytes each
    local waveSym = self:symbol("SFX_WaveInstruments")
    local sfxWaves = {}
    for i = 0, 4 do
      local ptr = self.rom:word(waveSym.bank, waveSym.address + i * 2)
      local samples = {}
      for b = 0, 15 do
        local byte = self.rom:byte(waveSym.bank, ptr + b)
        samples[#samples + 1] = math.floor(byte / 16)
        samples[#samples + 1] = byte % 16
      end
      sfxWaves[i] = samples
    end
    self.sfxWaves = sfxWaves
  end
  self.sfx = sfx

  self:write("audio", {
    available = true,
    songs = songs,
    songCount = count,
    bankIndex = bankList,
    bankSize = 0x4000,
    engines = { self:audioTables(1), self:audioTables(2) },
    sfx = self.sfx,
    sfxWaves = self.sfxWaves,
    frameRate = 60.24,             -- home/time.asm: every 4th 16 kHz timer tick
  })
  self.stats.songs = count
end

function RomExtractorTcg:extractConstants()
  self:beginStage("constants")
  self:write("constants", {
    game = "tcg",
    romSha1 = self.romSha1,
    cardIds = self.manifest.cardIds,
    cardOrder = self.manifest.cardOrder,
    deckIds = self.manifest.deckIds,
    enums = self.manifest.enums,
    layout = self.manifest.layout,
  })
end

function RomExtractorTcg:run()
  self:extractConstants()
  self:extractText()
  self:extractCards()
  self:extractCardArt()
  self:extractDecks()
  self:extractBoosters()
  self:extractFonts()
  self:extractDuelGraphics()
  self:extractAudio()
  self:write("manifest_stats", self.stats)
  return self.stats
end

return RomExtractorTcg
