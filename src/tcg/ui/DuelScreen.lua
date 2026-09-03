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
    animations = opts.animations,      -- sprite_animations.lua
    spriteFor = opts.spriteFor,
    session = assert(opts.session),
    font = assert(opts.font),
    cardImage = opts.cardImage or function() return nil end,
    onExit = opts.onExit,
    blink = 0,
  }, DuelScreen)
end

function DuelScreen:update(dt)
  self.blink = (self.blink + dt) % 1
  if self.animation then
    self.animation.frames = self.animation.frames - 1
    if self.animation.frames <= 0 then self.animation = nil end
  end
end

-- Called by DuelAudio when an attack names an animation.  The sprite effects
-- themselves are not ported, so this shows the attack and its animation for
-- the animation's duration rather than drawing the effect.
function DuelScreen:showAnimation(info)
  self.animation = { label = info.label, attack = info.attack,
    frames = info.frames or 24, total = info.frames or 24,
    spriteAnimation = info.spriteAnimation, sprite = info.sprite }
end

-- Draw the attack animation's sprite frames over the defender.  The frames
-- come from the sprite animation the Animations table names; the effect's
-- own positioning and sequencing bytes are not interpreted, so the frames
-- play centred on the defender at the animation's own frame rate.
function DuelScreen:drawAttackAnimation()
  local anim = self.animation
  if not (anim and anim.spriteAnimation and self.animations and self.spriteFor) then
    return false
  end
  local data = self.animations[anim.spriteAnimation]
    or self.animations[tostring(anim.spriteAnimation)]
  if not (data and data.oam and data.frames and #data.frames > 0) then return false end
  -- step through the animation's own frame list as the timer runs down
  local elapsed = (anim.total or 24) - anim.frames
  local index = (math.floor(elapsed / 4) % #data.frames) + 1
  local frame = data.frames[index] and data.frames[index].frame or data.firstFrame or 0
  local parts = data.oam[frame] or data.oam[tostring(frame)]
  local sheet = self.spriteFor and self.spriteFor(anim.sprite or 0)
  if not (parts and sheet) then return false end
  color(C.box)
  for _, part in ipairs(parts) do
    local index2 = part.tile
    local quad = love.graphics.newQuad((index2 % (sheet.columns or 4)) * 8,
      math.floor(index2 / (sheet.columns or 4)) * 8, 8, 8, sheet.image:getDimensions())
    love.graphics.draw(sheet.image, quad, 60 + (part.x or 0), 12 + (part.y or 0))
  end
  return true
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
      color(C.box); love.graphics.draw(img, x, y, 0, 0.4375, 0.4375)  -- 28x21
    end
    x = x + 30
  end
  color(C.text)
  love.graphics.print(shortName(v.name, 14), x, y)
  -- HP bar
  local barW = 40
  color(C.dim); love.graphics.rectangle("fill", x, y + 9, barW, 3)
  color(hpColor(v.hp, v.maxHp)); love.graphics.rectangle("fill", x, y + 9, math.floor(barW * v.hp / v.maxHp), 3)
  color(C.text)
  love.graphics.print(("%d/%d"):format(v.hp, v.maxHp), x + barW + 4, y + 7)
  local tags = {}
  if v.status ~= "none" then tags[#tags + 1] = STATUS_TAG[v.status] end
  if v.poison > 0 then tags[#tags + 1] = v.poison == 2 and "PSN2" or "PSN" end
  tags[#tags + 1] = "E" .. v.energy
  love.graphics.print(table.concat(tags, " "), x, y + 14)
end

-- The bench is one row of five short labels with the HP beside the name, so
-- it fits in a single 8px band instead of colliding with the row above.
function DuelScreen:drawBench(bench, x, y)
  for i, b in ipairs(bench) do
    if i > 5 then break end
    local bx = x + (i - 1) * 32
    color(C.text)
    love.graphics.print(shortName(b.name, 4), bx, y)
    color(hpColor(b.hp, b.maxHp))
    love.graphics.print(tostring(b.hp), bx + 21, y)
  end
end

function DuelScreen:drawSide(side, y, mine)
  color(C.text)
  love.graphics.print(("%s D%d H%d P%d"):format(shortName(side.name, 6), side.deck, side.hand, side.prizes), 2, y)
  if side.active then
    self:drawSlot(side.active, 2, y + 8, mine, true)
  else
    love.graphics.print("(no Active Pokemon)", 2, y + 10)
  end
  self:drawBench(side.bench, 2, y + 31)
end

function DuelScreen:drawMenu(rows, cursor, x, y, width, maxRows, rowHeight)
  rowHeight = rowHeight or 9
  color(C.box); love.graphics.rectangle("fill", x, y, width, H - y)
  color(C.panel); love.graphics.rectangle("line", x + 0.5, y + 0.5, width - 1, H - y - 1)
  local first = math.max(1, math.min(cursor - maxRows + 1, #rows - maxRows + 1))
  if first < 1 then first = 1 end
  for r = 0, maxRows - 1 do
    local i = first + r
    local row = rows[i]
    if not row then break end
    local ry = y + 2 + r * rowHeight
    if ry + 8 > H - 1 then break end
    if i == cursor then
      color(C.accent); love.graphics.rectangle("fill", x + 2, ry - 1, width - 4, rowHeight)
      color(C.light)
    else color(C.text) end
    love.graphics.print(shortName(row.label, math.floor((width - 8) / 4)), x + 5, ry)
  end
  if #rows > maxRows then
    color(C.dim)
    love.graphics.print(("%d/%d"):format(cursor, #rows), x + width - 24, H - 8)
  end
end

function DuelScreen:drawTextBox(lines, y)
  color(C.box); love.graphics.rectangle("fill", 0, y, W, H - y)
  color(C.panel); love.graphics.rectangle("line", 0.5, y + 0.5, W - 1, H - y - 1)
  color(C.text)
  for i, line in ipairs(lines) do
    local ly = y + 3 + (i - 1) * 9
    if ly + 8 > H - 1 then break end
    love.graphics.print(shortName(line:gsub("^%s+", ""), 30), 4, ly)
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
  -- vertical budget: foe 1..40, turn bar 41..50, player 52..91, panel 92..143
  self:drawSide(v.foe, 1, false)
  color(C.panel); love.graphics.rectangle("fill", 0, 41, W, 10)
  color(C.light)
  local who = v.finished and "" or (v.current == v.human and "YOUR TURN" or "OPPONENT")
  love.graphics.print(("TURN %d  %s"):format(v.turn, who), 3, 42)
  self:drawSide(v.me, 52, true)

  -- bottom panel by mode
  local y = 92
  if self.animation then
    self:drawAttackAnimation()
    color(C.panel); love.graphics.rectangle("fill", 0, 41, W, 10)
    color(C.light)
    love.graphics.print(shortName((self.animation.attack or "") .. "!", 30), 3, 42)
  end
  if v.mode == "log" then
    self:drawTextBox(v.pageLines, y)
  elseif v.mode == "prompt" and v.prompt then
    color(C.panel); love.graphics.rectangle("fill", 0, y, W, 10)
    color(C.light); love.graphics.print(shortName(v.prompt.title, 38), 3, y + 1)
    self:drawMenu(v.prompt.options, v.cursor, 0, y + 10, W, 4)
  elseif v.mode == "main" then
    self:drawMenu(v.menu, v.cursor, 0, y, 82, 6, 8)
    color(C.box); love.graphics.rectangle("fill", 82, y, W - 82, H - y)
    color(C.dim)
    love.graphics.print("A:pick", 86, y + 4)
    love.graphics.print("B:back", 86, y + 13)
    love.graphics.print("START:end", 86, y + 22)
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
