-- Renderer for NameEntry: the name being typed, then the character grid with
-- the cursor on it.

local NameEntryScreen = {}
NameEntryScreen.__index = NameEntryScreen

local W, H = 160, 144
local C = {
  bg = { 0.93, 0.93, 0.89 }, panel = { 0.16, 0.18, 0.22 }, text = { 0.10, 0.10, 0.12 },
  light = { 0.95, 0.95, 0.95 }, accent = { 0.86, 0.22, 0.20 }, dim = { 0.55, 0.55, 0.55 },
  box = { 1, 1, 1 },
}
local function color(c) love.graphics.setColor(c[1], c[2], c[3], c[4] or 1) end

function NameEntryScreen.new(opts)
  return setmetatable({ entry = assert(opts.entry), font = assert(opts.font) },
    NameEntryScreen)
end

function NameEntryScreen:button(btn) self.entry:press(btn) end

function NameEntryScreen:draw()
  local v = self.entry:view()
  love.graphics.setFont(self.font)
  color(C.bg); love.graphics.rectangle("fill", 0, 0, W, H)
  color(C.panel); love.graphics.rectangle("fill", 0, 0, W, 11)
  color(C.light); love.graphics.print("NAME YOUR DECK", 2, 1)

  -- the name so far, with an underscore for the space left
  color(C.box); love.graphics.rectangle("fill", 4, 15, W - 8, 14)
  color(C.panel); love.graphics.rectangle("line", 4.5, 15.5, W - 9, 13)
  color(C.text)
  love.graphics.print(v.name, 8, 19)
  color(C.dim)
  love.graphics.print(("%d/%d"):format(#v.name, v.limit), W - 34, 19)

  local originX, originY = 12, 36
  for r, line in ipairs(v.rows) do
    for c = 1, #line do
      local ch = line:sub(c, c)
      local x = originX + (c - 1) * 13
      local y = originY + (r - 1) * 12
      if r == v.row and c == v.col then
        color(C.accent); love.graphics.rectangle("fill", x - 3, y - 2, 12, 11)
        color(C.light)
      else
        color(C.text)
      end
      love.graphics.print(ch, x, y)
    end
  end

  color(C.dim)
  love.graphics.print("A:add  B:rub out", 4, H - 19)
  love.graphics.print("START:done  SELECT:cancel", 4, H - 10)
end

return NameEntryScreen
