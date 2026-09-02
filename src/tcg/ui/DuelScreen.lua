-- Duel screen (docs/tcg-phase1.md, Phase 6): draws a DuelSession on the
-- 160x144 canvas.  All state lives in the session; this file only reads
-- session:view() and forwards Game Boy buttons.  Card art comes from the
-- imported cache via the loader the browser already uses.

local DuelScreen = {}
DuelScreen.__index = DuelScreen

local W, H = 160, 144

local C = {
  bg = { 0.93, 0.93, 0.89 }, panel = { 0.16, 0.18, 0.22 }, text = { 0.10, 0.10, 0.12 },
  light = { 0.95, 0.95, 0.95 }, accent = { 0.86, 0.22, 0.20 }, dim = { 0.55, 0.55, 0.55 },
  hpOk = { 0.20, 0.62, 0.25 }, hpLow = { 0.86, 0.22, 0.20 }, box = { 1, 1, 1 },
}
local STATUS_TAG = { confused = "CNF", asleep = "SLP", paralyzed = "PRZ" }

local function color(c) love.graphics.setColor(c[1], c[2], c[3], c[4] or 1) end

-- opts: { session = DuelSession, font = love Font, cardImage = function(id) -> Image|nil, onExit = fn }
function DuelScreen.new(opts)
  return setmetatable({
    session = assert(opts.session),
    font = assert(opts.font),
    cardImage = opts.cardImage or function() return nil end,
    onExit = opts.onExit,
    blink = 0,
  }, DuelScreen)
end

function DuelScreen:update(dt)
  self.blink = (self.blink + dt) % 1
end

-- Game Boy button -> session
function DuelScreen:button(btn)
  local s = self.session
  if s.mode == "over" then
    if (btn == "a" or btn == "b" or btn == "start") and self.onExit then self.onExit() end
    return
  end
  s:press(btn)
end

-- ---------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------

local function hpColor(hp, max)
  return (hp * 2 <= max) and C.hpLow or C.hpOk
end

local function shortName(name, n)
  name = name or "-"
  if #name > n then return name:sub(1, n - 1) .. "." end
  return name
end

function DuelScreen:drawSlot(v, x, y, mine, art)
  -- art thumbnail 32x24 when available, then name / HP bar / status / energy
  if v.card and art then
    local img = self.cardImage(v.card)
    if img then
      color(C.box); love.graphics.draw(img, x, y, 0, 0.5, 0.5)
    end
    x = x + 34
  end
  color(C.text)
  love.graphics.print(shortName(v.name, 12), x, y)
  -- HP bar
  local barW = 48
  color(C.dim); love.graphics.rectangle("fill", x, y + 9, barW, 3)
  color(hpColor(v.hp, v.maxHp)); love.graphics.rectangle("fill", x, y + 9, math.floor(barW * v.hp / v.maxHp), 3)
  color(C.text)
  love.graphics.print(("%d/%d"):format(v.hp, v.maxHp), x + barW + 3, y + 6)
  local tags = {}
  if v.status ~= "none" then tags[#tags + 1] = STATUS_TAG[v.status] end
  if v.poison > 0 then tags[#tags + 1] = v.poison == 2 and "PSN2" or "PSN" end
  tags[#tags + 1] = "E" .. v.energy
  love.graphics.print(table.concat(tags, " "), x, y + 14)
end

function DuelScreen:drawBench(bench, x, y)
  color(C.text)
  for i, b in ipairs(bench) do
    local bx = x + (i - 1) * 31
    love.graphics.print(shortName(b.name, 6), bx, y)
    color(hpColor(b.hp, b.maxHp))
    love.graphics.print(tostring(b.hp), bx, y + 7)
    color(C.text)
  end
end

function DuelScreen:drawSide(side, y, mine)
  color(C.text)
  love.graphics.print(("%s  D%d H%d P%d"):format(shortName(side.name, 8), side.deck, side.hand, side.prizes), 2, y)
  if side.active then
    self:drawSlot(side.active, 2, y + 8, mine, true)
  else
    love.graphics.print("(no Active Pokemon)", 2, y + 10)
  end
  self:drawBench(side.bench, 2, y + 32)
end

function DuelScreen:drawMenu(rows, cursor, x, y, width, maxRows)
  color(C.box); love.graphics.rectangle("fill", x, y, width, H - y)
  color(C.panel); love.graphics.rectangle("line", x + 0.5, y + 0.5, width - 1, H - y - 1)
  local first = math.max(1, math.min(cursor - maxRows + 1, #rows - maxRows + 1))
  if first < 1 then first = 1 end
  for r = 0, maxRows - 1 do
    local i = first + r
    local row = rows[i]
    if not row then break end
    local ry = y + 3 + r * 9
    if i == cursor then
      color(C.accent); love.graphics.rectangle("fill", x + 2, ry - 1, width - 4, 9)
      color(C.light)
    else color(C.text) end
    love.graphics.print(shortName(row.label, math.floor((width - 8) / 4)), x + 5, ry)
  end
  if #rows > maxRows then
    color(C.dim)
    love.graphics.print(("%d/%d"):format(cursor, #rows), x + width - 26, H - 9)
  end
end

function DuelScreen:drawTextBox(lines, y)
  color(C.box); love.graphics.rectangle("fill", 0, y, W, H - y)
  color(C.panel); love.graphics.rectangle("line", 0.5, y + 0.5, W - 1, H - y - 1)
  color(C.text)
  for i, line in ipairs(lines) do
    love.graphics.print(shortName(line:gsub("^%s+", ""), 38), 4, y + 3 + (i - 1) * 9)
  end
  if self.blink < 0.6 then
    color(C.accent); love.graphics.print("v", W - 9, H - 9)
  end
end

function DuelScreen:draw()
  local v = self.session:view()
  love.graphics.setFont(self.font)
  color(C.bg); love.graphics.rectangle("fill", 0, 0, W, H)

  -- opponent (top) and player (middle)
  self:drawSide(v.foe, 1, false)
  color(C.panel); love.graphics.rectangle("fill", 0, 46, W, 1)
  color(C.dim)
  local who = v.finished and "" or (v.current == v.human and "YOUR TURN" or "OPPONENT")
  love.graphics.print(("T%d %s"):format(v.turn, who), 100, 47)
  self:drawSide(v.me, 49, true)

  -- bottom panel by mode
  local y = 96
  if v.mode == "log" then
    self:drawTextBox(v.pageLines, y)
  elseif v.mode == "prompt" and v.prompt then
    color(C.panel); love.graphics.rectangle("fill", 0, y, W, 10)
    color(C.light); love.graphics.print(shortName(v.prompt.title, 38), 3, y + 1)
    self:drawMenu(v.prompt.options, v.cursor, 0, y + 10, W, 4)
  elseif v.mode == "main" then
    self:drawMenu(v.menu, v.cursor, 0, y, 80, 5)
    color(C.box); love.graphics.rectangle("fill", 80, y, 80, H - y)
    color(C.dim)
    love.graphics.print("A:pick B:back", 84, y + 4)
    love.graphics.print("START:end turn", 84, y + 13)
  elseif v.mode == "hand" or v.mode == "attack" then
    self:drawMenu(v.menu, v.cursor, 0, y, W, 5)
  elseif v.mode == "check" then
    local lines = {}
    local a = v.me.active
    if a then
      lines[1] = ("%s %d/%d E%d"):format(a.name, a.hp, a.maxHp, a.energy)
    end
    local f = v.foe.active
    if f then
      lines[2] = ("vs %s %d/%d E%d"):format(f.name, f.hp, f.maxHp, f.energy)
    end
    lines[3] = ("Discard %d / %d"):format(v.me.discard, v.foe.discard)
    self:drawTextBox(lines, y)
  elseif v.mode == "over" then
    local msg = "Draw"
    if v.finished and v.finished.winner == v.human then msg = "You win!"
    elseif v.finished and v.finished.winner ~= 0 then msg = "You lose." end
    self:drawTextBox({ msg, v.finished and v.finished.reason or "", "A: back to cards" }, y)
  else
    self:drawTextBox({ "..." }, y)
  end
end

return DuelScreen
