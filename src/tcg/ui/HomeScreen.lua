-- Home / menu renderer (Phase 7).  Reads a HomeSession and draws the
-- current list on the 160x144 canvas; duels are drawn by DuelScreen.

local DuelScreen = require("src.tcg.ui.DuelScreen")
local NameEntryScreen = require("src.tcg.ui.NameEntryScreen")

local HomeScreen = {}
HomeScreen.__index = HomeScreen

local W, H = 160, 144
local C = {
  bg = { 0.93, 0.93, 0.89 }, panel = { 0.16, 0.18, 0.22 }, text = { 0.10, 0.10, 0.12 },
  light = { 0.95, 0.95, 0.95 }, accent = { 0.86, 0.22, 0.20 }, dim = { 0.55, 0.55, 0.55 }, box = { 1, 1, 1 },
}
local function color(c) love.graphics.setColor(c[1], c[2], c[3], c[4] or 1) end

local TITLES = {
  title = "POKEMON TCG", starter = "Choose a starter deck", home = "HOME", decks = "DECKS  A:edit SEL:use",
  collection = "COLLECTION", packs = "BOOSTER PACKS", packResult = "You got:", opponent = "Choose an opponent",
  editor = "DECK EDITOR", editorPick = "ADD  SEL:filter B:done", message = "", quit = "",
}

-- opts: { session, font, cardImage = fn(id) -> Image|nil, onQuit = fn, onBrowser = fn }
function HomeScreen.new(opts)
  local self = setmetatable({
    session = assert(opts.session), font = assert(opts.font),
    cardImage = opts.cardImage or function() return nil end,
    onQuit = opts.onQuit, onBrowser = opts.onBrowser,
    duelScreen = nil, blink = 0,
  }, HomeScreen)
  return self
end

function HomeScreen:update(dt)
  self.blink = (self.blink + dt) % 1
  local s = self.session
  if s.mode == "duel" then
    if not self.duelScreen or self.duelScreen.session ~= s.duelSession then
      self.duelScreen = DuelScreen.new({ session = s.duelSession, font = self.font, cardImage = self.cardImage })
    end
    self.duelScreen:update(dt)
  else
    self.duelScreen = nil
  end
  if s.mode == "quit" and self.onQuit then self.onQuit() end
end

function HomeScreen:button(btn)
  local s = self.session
  if s.mode == "home" and btn == "select" and self.onBrowser then return self.onBrowser() end
  s:press(btn)
end

local function clip(text, n)
  text = tostring(text or "")
  if #text > n then return text:sub(1, n - 1) .. "." end
  return text
end

function HomeScreen:drawList(rows, cursor, y, maxRows, showArt)
  local first = math.max(1, math.min(cursor - maxRows + 1, #rows - maxRows + 1))
  for r = 0, maxRows - 1 do
    local row = rows[first + r]
    if not row then break end
    local ry = y + r * 10
    if first + r == cursor then
      color(C.accent); love.graphics.rectangle("fill", 0, ry - 1, W, 10); color(C.light)
    elseif row.enabled == false then color(C.dim)
    else color(C.text) end
    love.graphics.print(clip(row.label, 36), 4, ry)
  end
  if #rows > maxRows then
    color(C.dim); love.graphics.print(("%d/%d"):format(cursor, #rows), W - 30, H - 9)
  end
  -- selected card's art, when the row names one
  local row = rows[cursor]
  if showArt and row and row.card then
    local img = self.cardImage(row.card)
    if img then color(C.box); love.graphics.draw(img, W - 66, H - 50, 0, 1, 1) end
  end
end

function HomeScreen:draw()
  local s = self.session
  love.graphics.setFont(self.font)
  if s.mode == "duel" and self.duelScreen then return self.duelScreen:draw() end
  if s.mode == "nameEntry" and s.nameEntry then
    if not self.nameScreen or self.nameScreen.entry ~= s.nameEntry then
      self.nameScreen = NameEntryScreen.new({ entry = s.nameEntry, font = self.font })
    end
    return self.nameScreen:draw()
  end
  color(C.bg); love.graphics.rectangle("fill", 0, 0, W, H)
  color(C.panel); love.graphics.rectangle("fill", 0, 0, W, 11)
  color(C.light); love.graphics.print(TITLES[s.mode] or s.mode, 2, 1)

  if s.mode == "message" then
    color(C.box); love.graphics.rectangle("fill", 8, 50, W - 16, 40)
    color(C.panel); love.graphics.rectangle("line", 8.5, 50.5, W - 17, 39)
    color(C.text)
    local text, y = s.message.text, 54
    for line in (text .. " "):gmatch("(.-) ") do
      -- naive wrap at 34 chars
      if not self._line then self._line = "" end
      if #self._line + #line + 1 > 34 then love.graphics.print(self._line, 12, y); y = y + 9; self._line = line
      else self._line = (#self._line > 0) and (self._line .. " " .. line) or line end
    end
    love.graphics.print(self._line or "", 12, y); self._line = nil
    color(C.dim); love.graphics.print("A", W - 16, 80)
    return
  end
  if s.mode == "quit" then return end

  local rows = s.menu
  if s.mode == "editorPick" and s.notice then
    color(C.accent); love.graphics.print(clip(s.notice, 38), 2, 13)
    self:drawList(rows, s.cursor, 24, 11, true)
  elseif s.mode == "collection" or s.mode == "editorPick" or s.mode == "packResult" then
    self:drawList(rows, s.cursor, 14, 12, true)
  else
    self:drawList(rows, s.cursor, 14, 12, false)
  end
  if s.mode == "home" then
    color(C.dim); love.graphics.print("SELECT: card list", 2, H - 9)
  elseif s.mode == "editor" and s.editor and s.editor.errors and s.editor.errors[1] then
    color(C.dim); love.graphics.print(clip(s.editor.errors[1], 38), 2, H - 9)
  end
end

return HomeScreen
