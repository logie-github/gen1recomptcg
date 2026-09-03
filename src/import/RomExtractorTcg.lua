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
  "maps",
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
    animationName = (self.manifest.attackAnimations or {})[tostring(b(18))],
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

-- ---------------------------------------------------------------------
-- overworld maps
-- ---------------------------------------------------------------------

-- poketcg's own LZ (home/decompress.asm, tools/compressor.c): a 256-byte
-- ring buffer seeded at $ef, MSB-first command bits, a set bit copying one
-- literal byte and a clear bit starting a run of (nybble + 2) bytes read
-- back from an offset in the buffer, the run length alternating between the
-- high and low nybble of a shared length byte.
function RomExtractorTcg:decompressLz(bank, address, size)
  local buffer = {}
  for i = 0, 255 do buffer[i] = 0 end
  local out = {}
  local src = address
  local bufferPtr = 0xef
  local bitsLeft, commandByte = 1, 0
  local repeatToggle, repeatLengths, bytesToRepeat, repeatOffset = false, 0, 0, 0

  local function emitFromBuffer()
    local value = buffer[repeatOffset % 256]
    repeatOffset = (repeatOffset + 1) % 256
    buffer[bufferPtr] = value
    bufferPtr = (bufferPtr + 1) % 256
    return value
  end

  while #out < size do
    if bytesToRepeat > 0 then
      bytesToRepeat = bytesToRepeat - 1
      out[#out + 1] = emitFromBuffer()
    else
      bitsLeft = bitsLeft - 1
      if bitsLeft == 0 then
        bitsLeft = 8
        commandByte = self.rom:byte(bank, src); src = src + 1
      end
      local bit = math.floor(commandByte / 128) % 2
      commandByte = (commandByte * 2) % 256
      local value = self.rom:byte(bank, src); src = src + 1
      if bit == 1 then
        buffer[bufferPtr] = value
        bufferPtr = (bufferPtr + 1) % 256
        out[#out + 1] = value
      else
        repeatOffset = value
        local nybble
        if not repeatToggle then
          repeatToggle = true
          repeatLengths = self.rom:byte(bank, src); src = src + 1
          nybble = math.floor(repeatLengths / 16)
        else
          repeatToggle = false
          nybble = repeatLengths % 16
        end
        bytesToRepeat = nybble + 1
        out[#out + 1] = emitFromBuffer()
      end
    end
  end
  return out, src - address
end

-- Tilemaps/Tilesets are reached through GfxTablePointers: 4-byte entries of
-- pointer, bank offset (plus BANK(GfxTablePointers)) and tileset id.
function RomExtractorTcg:gfxEntry(tableName, index)
  local t = self:symbol(tableName)
  local base = t.address + index * 4
  local pointer = self.rom:word(t.bank, base)
  local bank = self.rom:byte(t.bank, base + 2) + (self.manifest.mapLayout.gfxBankBase or 0x20)
  local extra = self.rom:byte(t.bank, base + 3)
  return { bank = bank, address = pointer, extra = extra }
end

function RomExtractorTcg:readWarps(mapIndex)
  local ptrs = self:symbol("WarpDataPointers")
  local pointer = self.rom:word(ptrs.bank, ptrs.address + mapIndex * 2)
  if pointer < 0x4000 or pointer >= 0x8000 then return {} end
  local warps = {}
  local cursor = pointer
  for _ = 1, 32 do
    local x = self.rom:byte(ptrs.bank, cursor)
    local y = self.rom:byte(ptrs.bank, cursor + 1)
    if x == 0 and y == 0 then break end
    warps[#warps + 1] = {
      x = x, y = y,
      map = self.rom:byte(ptrs.bank, cursor + 2),
      destX = self.rom:byte(ptrs.bank, cursor + 3),
      destY = self.rom:byte(ptrs.bank, cursor + 4),
    }
    cursor = cursor + 5
  end
  return warps
end

function RomExtractorTcg:readNpcs(bank, pointer)
  -- several maps point their script slots at RAM routines rather than at a
  -- data list; only ROMX addresses are lists
  if not pointer or pointer < 0x4000 or pointer >= 0x8000 then return {} end
  local npcs = {}
  local cursor = pointer
  for _ = 1, 32 do
    local id = self.rom:byte(bank, cursor)
    if id == 0 or id == 0xff then break end
    npcs[#npcs + 1] = {
      npc = id,
      constant = (self.manifest.npcIds or {})[tostring(id)],
      x = self.rom:byte(bank, cursor + 1),
      y = self.rom:byte(bank, cursor + 2),
      direction = self.rom:byte(bank, cursor + 3),
      preload = self.rom:word(bank, cursor + 4),
    }
    cursor = cursor + 6
  end
  return npcs
end

function RomExtractorTcg:readObjects(bank, pointer)
  -- several maps point their script slots at RAM routines rather than at a
  -- data list; only ROMX addresses are lists
  if not pointer or pointer < 0x4000 or pointer >= 0x8000 then return {} end
  local objects = {}
  local cursor = pointer
  local texts = #(self.manifest.textLabels or {})
  for _ = 1, 32 do
    -- data/map_objects.asm terminates each list with $ff
    local direction = self.rom:byte(bank, cursor)
    if direction == 0xff or direction > 3 then break end
    local textId = self.rom:word(bank, cursor + 5)
    local nameId = self.rom:word(bank, cursor + 7)
    objects[#objects + 1] = {
      direction = direction,
      x = self.rom:byte(bank, cursor + 1),
      y = self.rom:byte(bank, cursor + 2),
      routine = self.rom:word(bank, cursor + 3),
      -- an object's routine is a script (the Hall of Honor's legendary-card
      -- scene hangs off two of them), so it gets the same decode
      script = nil,
      textId = textId, text = textId < texts and self:textById(textId) or nil,
      nameId = nameId, name = nameId < texts and self:textById(nameId) or nil,
    }
    local object = objects[#objects]
    if object.routine and object.routine >= 0x4000 and object.routine < 0x8000 then
      local steps, scriptBank = self:decodeScriptAnyBank(object.routine,
        { bank - 1, bank, bank + 1 })
      if steps and #steps > 0 then
        object.script = steps
        object.scriptBank = scriptBank
      end
    end
    cursor = cursor + 9
  end
  return objects
end

-- Tilesets are raw 2bpp preceded by a two-byte tile count (gfx.asm), reached
-- through the same GfxTablePointers table as the tilemaps; the fourth entry
-- byte is the tile count the loader uses.
-- ---------------------------------------------------------------------
-- NPCs and overworld scripts
-- ---------------------------------------------------------------------

-- data/npcs.asm header: id, sprite, two animation ids, a spare byte, the
-- script pointer, the name text id, then the duel fields (pic, deck id,
-- music, match-start music) that only duelling NPCs fill in.
RomExtractorTcg.NPC_HEADER_SIZE = 13

-- Decode a script starting at `address`.  Command widths come from the
-- manifest's scriptCommands table (derived from macros/scripts.asm); the
-- walk stops at EndScript, at an opcode outside the table, or at the step
-- limit, and reports which so the caller can tell a good decode from a bad
-- one.  Scripts are labelled in a different bank from the NPC headers that
-- point at them and the pointer carries no bank, so the caller tries the
-- candidate banks and keeps the one that decodes cleanly.
function RomExtractorTcg:decodeScript(bank, address, limit)
  local commands = self.manifest.scriptCommands or {}
  if address < 0x4000 or address >= 0x8000 then return nil, "not in ROMX" end
  -- Scripts branch, and a branch target usually holds the interesting part
  -- (the duel, the reward), so the walk follows every jump target it decodes
  -- instead of stopping at the first terminator on the fall-through path.
  local out = {}
  local seen = {}
  local queue = { address }
  local head = 1
  local cursor = address
  -- `start_script` (macros/scripts.asm) is `rst $20`, and the label sits on
  -- that byte, so a script begins with $e7 before its first command
  if self.rom:byte(bank, cursor) == 0xe7 then cursor = cursor + 1 end
  for _ = 1, limit or 400 do
    local opcode = self.rom:byte(bank, cursor)
    local command = commands[opcode + 1]
    if not command then return out, "unknown opcode" end
    local args = {}
    for i = 1, command.args do
      args[i] = self.rom:byte(bank, cursor + i)
    end
    local step = { op = opcode, name = command.name, args = args,
      address = cursor }
    -- decorate the commands a player actually sees
    if command.name:find("^Print") and command.args >= 2 then
      step.textId = args[1] + args[2] * 0x100
      local texts = #(self.manifest.textLabels or {})
      if step.textId > 0 and step.textId < texts then step.text = self:textById(step.textId) end
    elseif command.name == "StartDuel" then
      step.prizes, step.deck, step.music = args[1], args[2], args[3]
      step.deckConstant = (self.manifest.deckIds or {})[tostring((args[2] or 0) + 2)]
    elseif command.name == "AskQuestionJump" then
      step.textId = args[1] + args[2] * 0x100
      local texts = #(self.manifest.textLabels or {})
      if step.textId > 0 and step.textId < texts then step.text = self:textById(step.textId) end
      -- ask_question_jump: text pointer then jump target (4 bytes)
      step.target = (args[3] or 0) + (args[4] or 0) * 0x100
    elseif command.name == "Jump" then
      step.target = args[1] + args[2] * 0x100
    elseif command.name == "MoveActiveNPC" or command.name == "MoveArbitraryNPC"
      or command.name == "MoveActiveNPCByDirection" then
      -- the argument is a movement table: a list of direction bytes ending
      -- in $ff (NPCMovement_* in the map scripts)
      local tableAddress = args[1] + (args[2] or 0) * 0x100
      if command.name == "MoveArbitraryNPC" then
        step.npc = args[1]
        tableAddress = (args[2] or 0) + (args[3] or 0) * 0x100
      end
      if tableAddress >= 0x4000 and tableAddress < 0x8000 then
        local path = {}
        for i = 0, 63 do
          local direction = self.rom:byte(bank, tableAddress + i)
          if direction == 0xff then break end
          if direction > 3 then break end
          path[#path + 1] = direction
        end
        if #path > 0 then step.path = path end
      end
    end
    if not seen[step.address] then
      seen[step.address] = true
      out[#out + 1] = step
    end
    if step.target and step.target >= 0x4000 and step.target < 0x8000
      and not seen[step.target] then
      queue[#queue + 1] = step.target
    end
    cursor = cursor + 1 + command.args

    local ended = command.name:find("^EndScript") or command.name == "QuitScriptFully"
    if ended or cursor >= 0x8000 or seen[cursor] then
      head = head + 1
      local nextAddress = queue[head]
      if not nextAddress then
        table.sort(out, function(a, b) return a.address < b.address end)
        return out, nil
      end
      cursor = nextAddress
      if self.rom:byte(bank, cursor) == 0xe7 then cursor = cursor + 1 end
    end
  end
  table.sort(out, function(a, b) return a.address < b.address end)
  return out, "step limit"
end

-- Try each candidate bank and score the decodes: a clean termination is
-- worth most, then length, then how much of it is content a player would
-- see.  A wrong bank usually lands on a $00 byte and "terminates" after one
-- step, so length matters as much as termination.
function RomExtractorTcg:decodeScriptAnyBank(address, banks)
  local best, bestBank, bestScore
  for _, bank in ipairs(banks) do
    local steps, err = self:decodeScript(bank, address)
    if steps and #steps > 0 then
      local content = 0
      for _, step in ipairs(steps) do
        if step.text or step.name == "StartDuel" then content = content + 1 end
      end
      local score = (err and 0 or 50) + #steps + content * 10
      if not bestScore or score > bestScore then
        best, bestBank, bestScore = steps, bank, score
      end
    end
  end
  return best, bestBank
end

-- Multichoice menus (engine/overworld/scripting.asm): each command keeps an
-- arg block as a local label -- title text id, prompt text id, config table,
-- the value B returns, the RAM slot for the result, and a NULL-terminated
-- list of option text ids.  Some menus take their options from the config
-- table instead, in which case the entries pointer is NULL and only the
-- prompt is available.
-- The credits sequence (data/sequences/credits.asm) is a list of
-- `dw CreditsSequenceCmd_*` entries, each followed by its arguments.  The
-- list's own label is not exported in poketcg.sym; the address comes from
-- SetCreditsSequenceCmdPtr, which writes it into the command pointer
-- directly, and is carried in the manifest.
-- Per-deck AI preferences (engine/duel/ai/decks/*).  Each deck AI keeps
-- labelled lists: arena and bench are card ids to lead with, prize is cards
-- to avoid giving up, retreat is (card, score) pairs and energy is
-- (card, max attached, score) triples.  Scores are stored offset by $80.
function RomExtractorTcg:extractAiDecks()
  local lists = self.manifest.aiDeckLists
  if not lists then return end
  local ids = self.manifest.cardIds or {}
  local out = {}
  for label, location in pairs(lists) do
    local aiName, listName = label:match("^AIActionTable_(.-)%.list_(.+)$")
    if aiName then
      local bank, address = location[1], location[2]
      local entry = out[aiName] or {}
      local values = {}
      if listName == "retreat" then
        for i = 0, 31 do
          local card = self.rom:byte(bank, address + i * 2)
          if card == 0 then break end
          values[#values + 1] = { card = card, constant = ids[tostring(card)],
            score = self.rom:byte(bank, address + i * 2 + 1) - 0x80 }
        end
      elseif listName == "energy" then
        for i = 0, 31 do
          local card = self.rom:byte(bank, address + i * 3)
          if card == 0 then break end
          values[#values + 1] = { card = card, constant = ids[tostring(card)],
            max = self.rom:byte(bank, address + i * 3 + 1),
            score = self.rom:byte(bank, address + i * 3 + 2) - 0x80 }
        end
      else
        for i = 0, 31 do
          local card = self.rom:byte(bank, address + i)
          if card == 0 then break end
          values[#values + 1] = { card = card, constant = ids[tostring(card)] }
        end
      end
      entry[listName] = values
      out[aiName] = entry
    end
  end
  self:write("ai_decks", out)
  local n = 0
  for _ in pairs(out) do n = n + 1 end
  self.stats.aiDecks = n
end

-- The attack animation table (Animations, read by GetAnimationData with a
-- hardcoded address).  Six bytes per ATK_ANIM_* id.  The first byte indexes
-- the sprite animation table, which is the part this port can act on; the
-- rest position and sequence the effect and are kept raw rather than guessed
-- at.
function RomExtractorTcg:extractAnimations()
  local location = self.manifest.animationsTable
  if not location then return end
  local bank, address = location[1], location[2]
  local names = self.manifest.attackAnimations or {}
  local count = 0
  for key in pairs(names) do count = math.max(count, tonumber(key) + 1) end
  local out = {}
  for id = 0, count - 1 do
    local base = address + id * 6
    local bytes = {}
    for i = 0, 5 do bytes[#bytes + 1] = self.rom:byte(bank, base + i) end
    out[id] = {
      id = id,
      name = names[tostring(id)],
      spriteAnimation = bytes[1],
      raw = bytes,
    }
  end
  self:write("attack_animations", out)
  self.stats.attackAnimations = count
end

function RomExtractorTcg:extractCredits()
  local location = self.manifest.creditsSequence
  local commands = self.manifest.creditsCommands
  if not (location and commands) then return end
  local bank, address = location[1], location[2]
  local texts = #(self.manifest.textLabels or {})
  local steps = {}
  local cursor = address
  for _ = 1, 2048 do
    if cursor >= 0x8000 then break end
    local pointer = self.rom:word(bank, cursor)
    local command = commands[tostring(pointer)]
    if not command then break end
    cursor = cursor + 2
    local args = {}
    for i = 0, command.args - 1 do
      args[#args + 1] = self.rom:byte(bank, cursor + i)
    end
    cursor = cursor + command.args
    local step = { name = command.name:gsub("^CreditsSequenceCmd_", ""), args = args }
    -- the text-printing commands carry a text id in their last two bytes
    if step.name:find("Text") and command.args >= 2 then
      local id = args[command.args - 1] + args[command.args] * 0x100
      if id > 0 and id < texts then step.textId = id end
    end
    steps[#steps + 1] = step
  end
  self:write("credits", { available = #steps > 0, bank = bank, address = address,
    steps = steps })
  self.stats.credits = #steps
end

function RomExtractorTcg:extractMultichoice()
  local menus = {}
  local texts = #(self.manifest.textLabels or {})
  for _, name in ipairs(self.manifest.multichoiceCommands or {}) do
    local key = "ScriptCommand_" .. name .. ".multichoice_menu_args"
    local location = self.symbols[key]
    if location then
      local bank, address = location[1], location[2]
      local w = function(o) return self.rom:word(bank, address + o) end
      local titleId, promptId = w(0), w(2)
      -- args: dw title, dw prompt, dw config, db cancel, dw result, dw entries
      local entriesPtr = w(9)
      local menu = {
        command = name,
        titleId = titleId,
        title = (titleId > 0 and titleId < texts) and self:textById(titleId) or nil,
        promptId = promptId,
        prompt = (promptId > 0 and promptId < texts) and self:textById(promptId) or nil,
        cancelValue = self.rom:byte(bank, address + 6),
        options = {},
      }
      -- When the arg block has no entries list, the options come from the
      -- config table (data/multichoice.asm): box x/y/w/h, the text position,
      -- a text id, an $ff marker, then the cursor's x/y, step, and max index.
      -- That text holds the options one per line, and the max index says how
      -- many of those lines are selectable.
      -- the config table is in bank 4, not the bank holding the arg block
      -- ("location of table configuration in bank 4"), so the marker byte is
      -- what identifies the right one
      local configPtr = w(4)
      local configBank
      if entriesPtr < 0x4000 and configPtr >= 0x4000 and configPtr < 0x8000 then
        for _, candidate in ipairs({ 4, bank, bank + 1, bank + 2 }) do
          if self.rom:byte(candidate, configPtr + 8) == 0xff then
            configBank = candidate
            break
          end
        end
      end
      if configBank then
        local menuTextId = self.rom:word(configBank, configPtr + 6)
        if menuTextId > 0 and menuTextId < texts then
          local maxIndex = self.rom:byte(configBank, configPtr + 12)
          local body = self:textById(menuTextId) or ""
          menu.menuTextId = menuTextId
          menu.cursorMax = maxIndex
          local lines = {}
          for line in (body .. "\n"):gmatch("(.-)\n") do
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if #line > 0 then lines[#lines + 1] = line end
          end
          for i = 1, math.min(#lines, maxIndex > 0 and maxIndex or #lines) do
            menu.options[#menu.options + 1] = { text = lines[i], fromConfig = true }
          end
        end
      end
      if entriesPtr >= 0x4000 and entriesPtr < 0x8000 then
        for i = 0, 7 do
          local id = self.rom:word(bank, entriesPtr + i * 2)
          if id == 0 then break end
          if id < texts then
            menu.options[#menu.options + 1] = { textId = id, text = self:textById(id) }
          end
        end
      end
      menus[name] = menu
    end
  end
  self:write("multichoice", menus)
end

-- Overworld sprite sheets (engine/gfx/sprites.asm): the same 4-byte
-- GfxTablePointers entry the tilesets use, with the fourth byte a tile
-- count.  The sheets are raw 2bpp; how the tiles group into facing frames is
-- the sprite animation system's business, which is not ported, so the sheet
-- is written whole and the renderer takes the first four tiles as a 16x16
-- frame.
function RomExtractorTcg:extractSprites()
  local ids = self.manifest.spriteIds or {}
  local count = 0
  for key in pairs(ids) do count = math.max(count, tonumber(key) + 1) end
  local index = {}
  for id = 0, count - 1 do
    local entry = self:gfxEntry("Sprites", id)
    local tiles = entry.extra
    if tiles > 0 and tiles <= 64 and entry.address >= 0x4000 and entry.address < 0x8000 then
      local raw = self.rom:bytes(entry.bank, entry.address, tiles * 16)
      -- The sheet is dumped as a plain 4-wide tile grid, NOT as character
      -- frames.  An OW frameset (data/map_ow_framesets.asm) builds a frame by
      -- substituting individual tiles, so which tiles form a facing frame is
      -- decided by the frameset and sprite-animation data, neither of which
      -- is ported yet.  Laying the sheet out as 2x2 frames produces
      -- scrambled characters, so no such arrangement is claimed here.
      local columns = 4
      local rows = math.ceil(tiles / columns)
      local image = self.backend.newImage(columns * 8, rows * 8)
      for tile = 0, tiles - 1 do
        local tx, ty = (tile % columns) * 8, math.floor(tile / columns) * 8
        for y = 0, 7 do
          local low = raw[tile * 16 + y * 2 + 1] or 0
          local high = raw[tile * 16 + y * 2 + 2] or 0
          for x = 0, 7 do
            local divisor = 2 ^ (7 - x)
            local shade = math.floor(high / divisor) % 2 * 2 + math.floor(low / divisor) % 2
            local c = GRAY[shade + 1]
            -- shade 0 is the transparent colour for sprites
            self.backend.setPixel(image, tx + x, ty + y, c[1], c[2], c[3],
              shade == 0 and 0 or 255)
          end
        end
      end
      local rel = ("sprites/%03d.png"):format(id)
      self.backend.savePng(image, "assets/generated/" .. rel)
      index[id] = { file = rel, tiles = tiles, columns = 4,
        name = ids[tostring(id)], framesetPorted = false }
    end
  end
  self:write("sprites", index)
  self.stats.sprites = count
end

-- Sprite animations (data/sprite_animation_pointers.asm).  An AnimData is
-- `db bank offset, dw frame table`, then 4-byte records of
-- {frame index, anim count, x translation, y translation} ending when the
-- count is 0.  The frame table is a list of pointers to OAM data: a size
-- byte, then that many {y, x, tile, attributes} records.  That is what says
-- which sprite-sheet tiles make up a facing frame -- the sheet's own layout
-- says nothing.
function RomExtractorTcg:extractSpriteAnimations()
  if not self.symbols.SpriteAnimations then return end
  local table_ = self:symbol("SpriteAnimations")
  local anims = {}
  -- the table is 218 entries (data/sprite_animation_pointers.asm); the
  -- attack animations index well past the first 32 the overworld uses
  for id = 0, 217 do
    local base = table_.address + id * 4
    local pointer = self.rom:word(table_.bank, base)
    local bank = self.rom:byte(table_.bank, base + 2) + table_.bank
    if pointer >= 0x4000 and pointer < 0x8000 then
      -- `frame_table` stores its bank as BANK(target) - BANK(AnimData1), so
      -- the frame table is resolved against AnimData1's bank, not against the
      -- animation's own bank
      local frameTableBank = (self.symbols.AnimData1 and self.symbols.AnimData1[1] or 0x20)
        + self.rom:byte(bank, pointer)
      local frameTable = self.rom:word(bank, pointer + 1)
      local frames = {}
      local cursor = pointer + 3
      for _ = 1, 16 do
        local index = self.rom:byte(bank, cursor)
        local count = self.rom:byte(bank, cursor + 1)
        if count == 0 then break end
        frames[#frames + 1] = { frame = index, duration = count,
          x = self.rom:byte(bank, cursor + 2), y = self.rom:byte(bank, cursor + 3) }
        cursor = cursor + 4
      end
      -- read the OAM for the frame indices this animation actually uses; the
      -- table entry at index 0 is not always one of them
      local wanted = {}
      for _, record in ipairs(frames) do wanted[record.frame] = true end
      local oam = {}
      if frameTable >= 0x4000 and frameTable < 0x8000 then
        for frame = 0, 15 do
          if wanted[frame] then
          local dataPtr = self.rom:word(frameTableBank, frameTable + frame * 2)
          if dataPtr >= 0x4000 and dataPtr < 0x8000 then
            local size = self.rom:byte(frameTableBank, dataPtr)
            if size > 0 and size <= 16 then
              local parts = {}
              for i = 0, size - 1 do
                parts[#parts + 1] = {
                  y = self.rom:byte(frameTableBank, dataPtr + 1 + i * 4),
                  x = self.rom:byte(frameTableBank, dataPtr + 2 + i * 4),
                  tile = self.rom:byte(frameTableBank, dataPtr + 3 + i * 4),
                  attributes = self.rom:byte(frameTableBank, dataPtr + 4 + i * 4),
                }
              end
              oam[frame] = parts
            end
          end
          end
        end
      end
      anims[id] = { id = id, bank = bank, frameTableBank = frameTableBank, address = pointer,
        frames = frames, oam = oam,
        firstFrame = frames[1] and frames[1].frame or 0 }
    end
  end
  self:write("sprite_animations", anims)
end

function RomExtractorTcg:extractNpcs()
  local ptrs = self:symbol("NPCHeaderPointers")
  local ids = self.manifest.npcIds or {}
  local count = 0
  for key in pairs(ids) do count = math.max(count, tonumber(key) + 1) end
  local npcs, decoded, clean = {}, 0, 0
  local banks = { ptrs.bank - 1, ptrs.bank, ptrs.bank + 1 }
  for id = 1, count - 1 do
    local header = self.rom:word(ptrs.bank, ptrs.address + id * 2)
    if header >= 0x4000 and header < 0x8000 then
      local b = function(o) return self.rom:byte(ptrs.bank, header + o) end
      local scriptPtr = b(5) + b(6) * 0x100
      local nameId = b(7) + b(8) * 0x100
      local texts = #(self.manifest.textLabels or {})
      local entry = {
        id = id,
        constant = ids[tostring(id)],
        sprite = b(1),
        animation = b(2),      -- base animation id; the facing is added to it
        animationCgb = b(3),
        name = (nameId > 0 and nameId < texts) and self:textById(nameId) or nil,
        nameId = nameId,
        scriptAddress = scriptPtr,
        pic = b(9), deck = b(10), music = b(11), matchStartMusic = b(12),
      }
      if entry.deck and entry.deck > 0 then
        entry.deckConstant = (self.manifest.deckIds or {})[tostring(entry.deck + 2)]
      end
      local steps, bank = self:decodeScriptAnyBank(scriptPtr, banks)
      if steps then
        decoded = decoded + 1
        entry.script = steps
        entry.scriptBank = bank
        local _, err = self:decodeScript(bank, scriptPtr)
        entry.scriptError = err
        if not err then clean = clean + 1 end
      end
      npcs[id] = entry
    end
  end
  self:write("npcs", { npcs = npcs, count = count, decoded = decoded, clean = clean })
  self.stats.npcs = decoded
  self.stats.npcScripts = clean
end

function RomExtractorTcg:extractTilesets()
  local ids = self.manifest.tilesetIds or {}
  local index = {}
  local count = 0
  for key in pairs(ids) do count = math.max(count, tonumber(key) + 1) end
  for id = 0, count - 1 do
    local entry = self:gfxEntry("Tilesets", id)
    local tiles = entry.extra
    if tiles > 0 and entry.address >= 0x4000 and entry.address < 0x8000 then
      local raw = self.rom:bytes(entry.bank, entry.address + 2, tiles * 16)
      local columns = 16
      local rows = math.ceil(tiles / columns)
      local image = self.backend.newImage(columns * 8, rows * 8)
      for tile = 0, tiles - 1 do
        local tx, ty = (tile % columns) * 8, math.floor(tile / columns) * 8
        for y = 0, 7 do
          local low = raw[tile * 16 + y * 2 + 1] or 0
          local high = raw[tile * 16 + y * 2 + 2] or 0
          for x = 0, 7 do
            local divisor = 2 ^ (7 - x)
            local shade = math.floor(high / divisor) % 2 * 2 + math.floor(low / divisor) % 2
            local c = GRAY[shade + 1]
            self.backend.setPixel(image, tx + x, ty + y, c[1], c[2], c[3], 255)
          end
        end
      end
      local rel = ("tilesets/%02d.png"):format(id)
      self.backend.savePng(image, "assets/generated/" .. rel)
      index[id] = { file = rel, tiles = tiles, columns = columns,
        name = ids[tostring(id)] }
    end
  end
  self:write("tilesets", index)
  self.stats.tilesets = count
end

function RomExtractorTcg:extractMaps()
  self:beginStage("maps")
  self:extractTilesets()
  self:extractNpcs()
  self:extractSprites()
  self:extractSpriteAnimations()
  self:extractMultichoice()
  self:extractCredits()
  self:extractAnimations()
  self:extractAiDecks()
  if not self.symbols.MapHeaders then
    self:write("maps", { available = false })
    return
  end
  local layout = self.manifest.mapLayout
  local count = layout.numMaps
  local headers = self:symbol("MapHeaders")
  local scripts = self:symbol("MapScripts")
  local maps = {}
  for index = 0, count - 1 do
    local base = headers.address + index * layout.headerSize
    local map = {
      index = index,
      constant = (self.manifest.mapIds or {})[tostring(index)],
      tilemap = self.rom:byte(headers.bank, base),
      tilemapCgb = self.rom:byte(headers.bank, base + 1),
      paletteCgb = self.rom:byte(headers.bank, base + 2),
      paletteSgb = self.rom:byte(headers.bank, base + 3),
      palette = self.rom:byte(headers.bank, base + 4),
      song = self.rom:byte(headers.bank, base + 5),
    }
    map.tilemapName = (self.manifest.tilemapIds or {})[tostring(map.tilemap)]

    -- tilemap: width, height, permission pointer, cgb flag, then LZ tiles
    local entry = self:gfxEntry("Tilemaps", map.tilemap)
    local width = self.rom:byte(entry.bank, entry.address)
    local height = self.rom:byte(entry.bank, entry.address + 1)
    local permissionsPtr = self.rom:word(entry.bank, entry.address + 2)
    if width > 0 and height > 0 and width <= 64 and height <= 64 then
      map.width, map.height = width, height
      map.tileset = entry.extra
      map.tiles = self:decompressLz(entry.bank, entry.address + 5, width * height)
      -- DecompressPermissionMap: permissions cover 2x2 tile blocks, so the
      -- grid is ((w+1)/2) x ((h+1)/2) bytes; bits $40 and $80 are the
      -- impassable flags the player movement check reads (overworld.asm)
      if permissionsPtr ~= 0 then
        map.permissionWidth = math.floor((width + 1) / 2)
        map.permissionHeight = math.floor((height + 1) / 2)
        map.permissions = self:decompressLz(entry.bank, permissionsPtr,
          map.permissionWidth * map.permissionHeight)
      end
    end

    -- scripts: 8 words per map; slot 0 is the NPC list, slot 2 the objects
    local scriptBase = scripts.address + index * layout.numMapScripts * 2
    map.scripts = {}
    for slot = 0, layout.numMapScripts - 1 do
      map.scripts[slot] = self.rom:word(scripts.bank, scriptBase + slot * 2)
    end
    map.npcs = self:readNpcs(scripts.bank, map.scripts[0])
    map.objects = self:readObjects(scripts.bank, map.scripts[2])
    -- Slots 0 and 2 are the NPC and object lists; the rest are scripts (load
    -- map, pressed A, after duel, close text box...) and hold the club
    -- progression, so they get the same branch-following decode NPC scripts
    -- get.  The pointer carries no bank, so the candidate banks are scored
    -- the same way too.
    -- The after-duel slot is not bytecode: it is `ld hl, table / call
    -- FindEndOfDuelScript / ret`, and the table it names holds one 6-byte
    -- record per duellable NPC (two npc ids, then the win and lose script
    -- pointers), terminated by $00.  The club medals live behind those win
    -- scripts, so they are decoded here.
    map.afterDuel = nil
    for slot = 0, layout.numMapScripts - 1 do
      local pointer = map.scripts[slot]
      -- the code lives in the script banks, not the map-script bank, so the
      -- preamble (`ld hl, nn` then `call nn`) is looked for in each
      local codeBank
      if pointer and pointer >= 0x4000 and pointer < 0x8000 then
        for _, candidate in ipairs({ scripts.bank - 1, scripts.bank, scripts.bank + 1 }) do
          if self.rom:byte(candidate, pointer) == 0x21
            and self.rom:byte(candidate, pointer + 3) == 0xcd then
            codeBank = candidate
            break
          end
        end
      end
      if codeBank then
        local tableAddress = self.rom:word(codeBank, pointer + 1)
        if tableAddress >= 0x4000 and tableAddress < 0x8000 then
          local entries, cursor = {}, tableAddress
          for _ = 1, 16 do
            local npc = self.rom:byte(codeBank, cursor)
            if npc == 0 then break end
            local winPtr = self.rom:word(codeBank, cursor + 2)
            local losePtr = self.rom:word(codeBank, cursor + 4)
            local entry = {
              npc = npc,
              constant = (self.manifest.npcIds or {})[tostring(npc)],
              npc2 = self.rom:byte(codeBank, cursor + 1),
              winAddress = winPtr, loseAddress = losePtr,
            }
            local banks = { codeBank, scripts.bank - 1, scripts.bank, scripts.bank + 1 }
            local won, wonBank = self:decodeScriptAnyBank(winPtr, banks)
            if won then entry.win = won; entry.winBank = wonBank end
            local lost, lostBank = self:decodeScriptAnyBank(losePtr, banks)
            if lost then entry.lose = lost; entry.loseBank = lostBank end
            entries[#entries + 1] = entry
            cursor = cursor + 6
          end
          if #entries > 0 then
            map.afterDuel = { slot = slot, bank = codeBank, address = tableAddress,
              entries = entries }
          end
        end
      end
    end

    map.scriptCode = {}
    for slot = 0, layout.numMapScripts - 1 do
      if slot ~= 0 and slot ~= 2 then
        local pointer = map.scripts[slot]
        if pointer and pointer >= 0x4000 and pointer < 0x8000 then
          local steps, bank = self:decodeScriptAnyBank(pointer,
            { scripts.bank - 1, scripts.bank, scripts.bank + 1 })
          if steps and #steps > 0 then
            map.scriptCode[slot] = { bank = bank, address = pointer, steps = steps }
          end
        end
      end
    end
    map.warps = self:readWarps(index)
    maps[index] = map
    self:tick("maps", index + 1, count)
  end
  self:write("maps", { available = true, count = count, maps = maps,
    scriptBank = scripts.bank })
  self.stats.maps = count
end

function RomExtractorTcg:medalEvents()
  if not self.symbols.MedalEvents then return nil end
  local sym = self:symbol("MedalEvents")
  local out = {}
  for i = 0, 7 do out[i] = self.rom:byte(sym.bank, sym.address + i) end
  return out
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
    -- script event ids and medal bits, so the runtime uses the game's own
    -- numbering rather than a private one
    eventByName = self.manifest.eventByName,
    medalBits = self.manifest.medalBits,
    -- MedalEvents (engine/overworld/scripting.asm): medal bit index -> the
    -- EVENT_BEAT_* id that show_medal_received_screen is given
    medalEvents = self:medalEvents(),
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
  self:extractMaps()
  self:write("manifest_stats", self.stats)
  return self.stats
end

return RomExtractorTcg
