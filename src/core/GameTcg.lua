-- Pokemon Trading Card Game service owner (Phase 1, docs/tcg-phase1.md).
--
-- What exists today: the imported cache is loaded and a card browser runs
-- on the 160x144 Game Boy canvas -- every card's art, stats, attacks and
-- rules text, the built-in decks, and the booster tables.  There is no duel
-- engine, overworld, or save yet; this file is the seam those will hang off,
-- the way Game2.lua is for Gold/Silver.
--
-- Interface: the same surface main.lua drives on Game/Game2 (load, update,
-- draw, key/gamepad/touch/mouse handlers, focus/visible/onResume).  Input
-- goes through src/core/Input.lua so keyboard rebinds and controllers work
-- unchanged.

local Input = require("src.core.Input")
local CacheFs = require("src.import.CacheFs")
local GameVersion = require("src.core.GameVersion")

local GameTcg = {}
GameTcg.__index = GameTcg

local GB_W, GB_H = 160, 144

-- Screen palette (CGB-ish menu greys; the card art carries its own palette).
local COLORS = {
  bg = { 0.94, 0.94, 0.90 },
  panel = { 0.16, 0.18, 0.22 },
  text = { 0.10, 0.10, 0.12 },
  textLight = { 0.95, 0.95, 0.95 },
  accent = { 0.86, 0.22, 0.20 },
  dim = { 0.55, 0.55, 0.55 },
}

local TYPE_SHORT = {
  TYPE_PKMN_FIRE = "Fire", TYPE_PKMN_GRASS = "Grass", TYPE_PKMN_LIGHTNING = "Lightning",
  TYPE_PKMN_WATER = "Water", TYPE_PKMN_FIGHTING = "Fighting", TYPE_PKMN_PSYCHIC = "Psychic",
  TYPE_PKMN_COLORLESS = "Colorless", TYPE_TRAINER = "Trainer",
}
local ENERGY_SHORT = { FIRE = "R", GRASS = "G", LIGHTNING = "L", WATER = "W",
  FIGHTING = "F", PSYCHIC = "P", COLORLESS = "C", UNUSED = "?" }

function GameTcg.new()
  return setmetatable({
    data = {},
    images = {},
    mode = "list",     -- list | card | decks | boosters
    cursor = 1,
    scroll = 0,
    detailPage = 1,
    deckCursor = 0,
    errorText = nil,
    frame = 0,
  }, GameTcg)
end

-- ---------------------------------------------------------------------
-- loading
-- ---------------------------------------------------------------------

local function loadGenerated(rel)
  local value, err = CacheFs.loadActive(rel)
  if value == nil then error(("could not load %s: %s"):format(rel, tostring(err))) end
  return value
end

function GameTcg:load(opts)
  self.opts = opts or {}
  Input:init()
  local ok, err = pcall(function()
    self.data.constants = loadGenerated("data/generated/constants.lua")
    self.data.cards = loadGenerated("data/generated/cards.lua")
    self.data.text = loadGenerated("data/generated/text.lua")
    self.data.cardArt = loadGenerated("data/generated/card_art.lua")
    self.data.decks = loadGenerated("data/generated/decks.lua")
    self.data.boosters = loadGenerated("data/generated/boosters.lua")
  end)
  if not ok then self.errorText = tostring(err) end

  -- ordered card list (ids 1..count, skipping any nil rows)
  self.cardIds = {}
  if self.data.cards then
    for id = 1, self.data.cards.count do
      if self.data.cards.byId[id] then self.cardIds[#self.cardIds + 1] = id end
    end
  end
  self.deckIndices = {}
  if self.data.decks then
    local keys = {}
    for k in pairs(self.data.decks) do keys[#keys + 1] = k end
    table.sort(keys)
    self.deckIndices = keys
  end

  self.canvas = love.graphics.newCanvas(GB_W, GB_H)
  self.canvas:setFilter("nearest", "nearest")
  self.font = love.graphics.newFont(8)
  self.font:setFilter("nearest", "nearest")
  if love.window and love.window.setTitle then
    pcall(love.window.setTitle, GameVersion.info().displayName .. " (Phase 1 card browser)")
  end
end

function GameTcg:cardImage(id)
  local img = self.images[id]
  if img == nil then
    local entry = self.data.cardArt and self.data.cardArt[id]
    img = false
    if entry then
      local bytes = CacheFs.readActive("assets/generated/" .. entry.file)
      if bytes then
        local ok, result = pcall(function()
          local fileData = love.filesystem.newFileData(bytes, entry.file)
          local image = love.graphics.newImage(love.image.newImageData(fileData))
          image:setFilter("nearest", "nearest")
          return image
        end)
        if ok then img = result end
      end
    end
    self.images[id] = img
  end
  return img or nil
end

-- ---------------------------------------------------------------------
-- update / input
-- ---------------------------------------------------------------------

local LIST_ROWS = 8

function GameTcg:currentCard()
  local id = self.cardIds[self.cursor]
  return id and self.data.cards.byId[id], id
end

function GameTcg:update(dt)
  self.frame = self.frame + 1
  Input:step()
  if self.errorText then
    if Input:wasPressed("b") or Input:wasPressed("start") then self:quit() end
    return
  end
  local n = #self.cardIds
  if self.mode == "list" then
    if Input:wasPressed("down") then self.cursor = math.min(n, self.cursor + 1) end
    if Input:wasPressed("up") then self.cursor = math.max(1, self.cursor - 1) end
    if Input:wasPressed("right") then self.cursor = math.min(n, self.cursor + LIST_ROWS) end
    if Input:wasPressed("left") then self.cursor = math.max(1, self.cursor - LIST_ROWS) end
    if self.cursor - 1 < self.scroll then self.scroll = self.cursor - 1 end
    if self.cursor - 1 >= self.scroll + LIST_ROWS then self.scroll = self.cursor - LIST_ROWS end
    if Input:wasPressed("a") then self.mode = "card"; self.detailPage = 1 end
    if Input:wasPressed("select") then self.mode = "decks"; self.deckCursor = 1 end
    if Input:wasPressed("start") then self.mode = "boosters" end
    if Input:wasPressed("b") then self:quit() end
  elseif self.mode == "card" then
    if Input:wasPressed("right") then self.cursor = math.min(n, self.cursor + 1); self.detailPage = 1 end
    if Input:wasPressed("left") then self.cursor = math.max(1, self.cursor - 1); self.detailPage = 1 end
    if Input:wasPressed("a") or Input:wasPressed("down") then self.detailPage = self.detailPage % 3 + 1 end
    if Input:wasPressed("up") then self.detailPage = (self.detailPage - 2) % 3 + 1 end
    if Input:wasPressed("b") then self.mode = "list" end
  elseif self.mode == "decks" then
    local m = #self.deckIndices
    if Input:wasPressed("down") then self.deckCursor = math.min(m, self.deckCursor + 1) end
    if Input:wasPressed("up") then self.deckCursor = math.max(1, self.deckCursor - 1) end
    if Input:wasPressed("b") or Input:wasPressed("select") then self.mode = "list" end
  elseif self.mode == "boosters" then
    if Input:wasPressed("b") or Input:wasPressed("start") then self.mode = "list" end
  end
end

function GameTcg:quit()
  -- Power-cycle back to the launcher, the way Gen 2's QUIT row does.
  local ok, HostShell = pcall(require, "src.core.HostShell")
  if ok and HostShell and HostShell.restart then HostShell.restart() else love.event.quit() end
end

-- ---------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------

local function setColor(c) love.graphics.setColor(c[1], c[2], c[3], c[4] or 1) end

local function wrap(font, text, width)
  local lines = {}
  for paragraph in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      local candidate = line == "" and word or (line .. " " .. word)
      if font:getWidth(candidate) > width and line ~= "" then
        lines[#lines + 1] = line
        line = word
      else
        line = candidate
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

-- Replace text markers with something printable in a plain font.
local function plain(s)
  if not s then return "" end
  s = s:gsub("{SYM:07}", "[C]"):gsub("{SYM:%x%x}", "*")
  s = s:gsub("{RAM1}", "[name]"):gsub("{RAM2}", "[text]"):gsub("{RAM3}", "[n]")
  s = s:gsub("{FW:[^}]*}", "?"):gsub("{CTRL:%x%x}", ""):gsub("{BYTE:%x%x}", "?")
  return s
end

local function energyString(cost)
  local parts = {}
  for _, key in ipairs({ "FIRE", "GRASS", "LIGHTNING", "WATER", "FIGHTING", "PSYCHIC", "COLORLESS", "UNUSED" }) do
    local n = cost and cost[key]
    if n and n > 0 then parts[#parts + 1] = ENERGY_SHORT[key] .. n end
  end
  return #parts > 0 and table.concat(parts, " ") or "-"
end

function GameTcg:drawHeader(title, hint)
  setColor(COLORS.panel)
  love.graphics.rectangle("fill", 0, 0, GB_W, 11)
  setColor(COLORS.textLight)
  love.graphics.print(title, 2, 1)
  if hint then
    love.graphics.print(hint, GB_W - self.font:getWidth(hint) - 2, 1)
  end
end

function GameTcg:drawList()
  self:drawHeader("CARDS " .. self.cursor .. "/" .. #self.cardIds, "A:view SEL:decks")
  for row = 0, LIST_ROWS - 1 do
    local index = self.scroll + row + 1
    local id = self.cardIds[index]
    if not id then break end
    local card = self.data.cards.byId[id]
    local y = 14 + row * 12
    if index == self.cursor then
      setColor(COLORS.accent)
      love.graphics.rectangle("fill", 0, y - 1, GB_W, 11)
      setColor(COLORS.textLight)
    else
      setColor(COLORS.text)
    end
    local kind = card.kind == "pokemon" and (TYPE_SHORT[card.type] or "?") or
      (card.kind == "energy" and "Energy" or "Trainer")
    love.graphics.print(("%03d %s"):format(id, plain(card.name)), 3, y)
    love.graphics.print(kind, GB_W - self.font:getWidth(kind) - 3, y)
  end
  setColor(COLORS.dim)
  love.graphics.print("B:launcher  START:boosters", 2, GB_H - 10)
end

function GameTcg:drawCard()
  local card, id = self:currentCard()
  if not card then return end
  self:drawHeader(plain(card.name), ("%d/3"):format(self.detailPage))
  local img = self:cardImage(id)
  local y0 = 13
  if self.detailPage == 1 then
    if img then
      setColor({ 1, 1, 1 })
      love.graphics.draw(img, 2, y0)
    end
    setColor(COLORS.text)
    local x = 70
    local lines = {}
    if card.kind == "pokemon" then
      lines[#lines + 1] = (TYPE_SHORT[card.type] or card.type) .. "  HP " .. card.hp
      lines[#lines + 1] = card.stage:gsub("_", " ")
      if card.preEvolutionName then lines[#lines + 1] = "from " .. plain(card.preEvolutionName) end
      lines[#lines + 1] = "Lv" .. card.level .. "  #" .. card.pokedexNumber
      lines[#lines + 1] = "W:" .. table.concat(card.weakness, ",")
        .. " R:" .. (#card.resistance > 0 and table.concat(card.resistance, ",") or "-")
      lines[#lines + 1] = "Retreat " .. card.retreatCost
    else
      lines[#lines + 1] = card.kind == "energy" and "Energy" or "Trainer"
    end
    lines[#lines + 1] = card.rarity .. "  " .. card.set
    for i, line in ipairs(lines) do love.graphics.print(line, x, y0 + (i - 1) * 9) end
  elseif self.detailPage == 2 then
    setColor(COLORS.text)
    local y = y0
    if card.kind == "pokemon" then
      for _, attack in ipairs(card.attacks) do
        local head = ("%s [%s]"):format(plain(attack.name), energyString(attack.energy))
        if attack.category == "POKEMON_POWER" then head = "PKMN PWR: " .. plain(attack.name) end
        love.graphics.print(head, 2, y); y = y + 9
        if attack.damage > 0 or attack.category ~= "DAMAGE_NORMAL" then
          local suffix = ({ DAMAGE_PLUS = "+", DAMAGE_MINUS = "-", DAMAGE_X = "x" })[attack.category] or ""
          love.graphics.print("  " .. attack.damage .. suffix, 2, y); y = y + 9
        end
        for _, line in ipairs(wrap(self.font, plain(attack.description), GB_W - 6)) do
          love.graphics.print(line, 4, y); y = y + 8
        end
        y = y + 3
      end
    else
      for _, line in ipairs(wrap(self.font, plain(card.description), GB_W - 6)) do
        love.graphics.print(line, 4, y); y = y + 8
      end
    end
  else
    setColor(COLORS.text)
    local y = y0
    if card.kind == "pokemon" then
      love.graphics.print(plain(card.category) .. " Pokemon", 2, y); y = y + 9
      love.graphics.print(("Length %d'%d\"  Weight %d lbs"):format(
        card.length.feet, card.length.inches, card.weight), 2, y); y = y + 11
      for _, line in ipairs(wrap(self.font, plain(card.description), GB_W - 6)) do
        love.graphics.print(line, 4, y); y = y + 8
      end
    else
      love.graphics.print("(no further text)", 2, y)
    end
  end
  setColor(COLORS.dim)
  love.graphics.print("</>:card  A:page  B:back", 2, GB_H - 10)
end

function GameTcg:drawDecks()
  self:drawHeader("DECKS", "B:back")
  local key = self.deckIndices[self.deckCursor]
  local deck = key and self.data.decks[key]
  for row = 0, 5 do
    local index = self.deckCursor - 2 + row
    local k = self.deckIndices[index]
    if k then
      local d = self.data.decks[k]
      local y = 13 + row * 9
      if index == self.deckCursor then setColor(COLORS.accent) else setColor(COLORS.text) end
      love.graphics.print(plain(d.name or d.label), 2, y)
    end
  end
  if deck then
    setColor(COLORS.panel)
    love.graphics.rectangle("fill", 0, 68, GB_W, GB_H - 68)
    setColor(COLORS.textLight)
    love.graphics.print(("%d cards"):format(deck.total), 2, 70)
    local y, col = 79, 0
    for i, entry in ipairs(deck.cards) do
      if i > 14 then break end
      local card = self.data.cards.byId[entry.card]
      local label = ("%dx %s"):format(entry.count, card and plain(card.name) or entry.constant or "?")
      love.graphics.print(label, 2 + col * 80, y)
      col = col + 1
      if col == 2 then col = 0; y = y + 9 end
    end
  end
end

function GameTcg:drawBoosters()
  self:drawHeader("BOOSTER PACKS", "B:back")
  setColor(COLORS.text)
  local y = 13
  local packs = self.data.boosters.packs
  local keys = {}
  for k in pairs(packs) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    if y > GB_H - 18 then break end
    local p = packs[k]
    local name = p.constant:gsub("^BOOSTER_", ""):gsub("_", " ")
    local energy = p.energy.kind == "card" and (p.energy.constant or "?"):gsub("_ENERGY", "")
      or p.energy.kind
    love.graphics.print(("%-22s %s"):format(name:sub(1, 22), energy), 2, y)
    y = y + 8
  end
end

function GameTcg:drawError()
  self:drawHeader("TCG IMPORT PROBLEM", "B:quit")
  setColor(COLORS.text)
  local y = 14
  for _, line in ipairs(wrap(self.font, self.errorText, GB_W - 4)) do
    love.graphics.print(line, 2, y); y = y + 8
    if y > GB_H - 8 then break end
  end
end

function GameTcg:draw()
  love.graphics.push("all")
  love.graphics.setCanvas(self.canvas)
  love.graphics.setFont(self.font)
  setColor(COLORS.bg)
  love.graphics.rectangle("fill", 0, 0, GB_W, GB_H)
  if self.errorText then self:drawError()
  elseif self.mode == "list" then self:drawList()
  elseif self.mode == "card" then self:drawCard()
  elseif self.mode == "decks" then self:drawDecks()
  elseif self.mode == "boosters" then self:drawBoosters() end
  love.graphics.setCanvas()
  love.graphics.pop()

  local ww, wh = love.graphics.getDimensions()
  local scale = math.max(1, math.floor(math.min(ww / GB_W, wh / GB_H)))
  love.graphics.clear(0.05, 0.05, 0.06)
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(self.canvas,
    math.floor((ww - GB_W * scale) / 2), math.floor((wh - GB_H * scale) / 2), 0, scale, scale)
end

-- ---------------------------------------------------------------------
-- host events (same surface as Game/Game2)
-- ---------------------------------------------------------------------

function GameTcg:keypressed(key) Input:keypressed(key) end
function GameTcg:keyreleased(key) Input:keyreleased(key) end
function GameTcg:gamepadpressed(joystick, button) Input:gamepadpressed(joystick, button) end
function GameTcg:gamepadreleased(joystick, button) Input:gamepadreleased(joystick, button) end
function GameTcg:gamepadaxis(joystick, axis, value) Input:gamepadaxis(joystick, axis, value) end
function GameTcg:joystickpressed(joystick, button) Input:joystickpressed(joystick, button) end
function GameTcg:joystickreleased(joystick, button) Input:joystickreleased(joystick, button) end
function GameTcg:joystickaxis(joystick, axis, value) Input:joystickaxis(joystick, axis, value) end
function GameTcg:joystickhat(joystick, hat, direction) Input:joystickhat(joystick, hat, direction) end
function GameTcg:joystickadded() end
function GameTcg:joystickremoved() end
function GameTcg:wheelmoved() end
function GameTcg:touchpressed() end
function GameTcg:touchmoved() end
function GameTcg:touchreleased() end
function GameTcg:mousepressed() end
function GameTcg:mousemoved() end
function GameTcg:mousereleased() end
function GameTcg:focus() end
function GameTcg:visible() end
function GameTcg:onResume() end
function GameTcg:reset() end

return GameTcg
