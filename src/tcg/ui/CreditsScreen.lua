-- Credits renderer (Phase 28): draws a CreditsSequence's current state on the
-- 160x144 canvas.  Scenes that name a map are drawn from that map's own tiles
-- when a tileset is supplied; characters use the same sprite path the
-- overworld uses.  Everything else -- the overlay band, the rectangles, the
-- fade -- is drawn directly.

local CreditsScreen = {}
CreditsScreen.__index = CreditsScreen

local W, H = 160, 144
local C = {
  black = { 0, 0, 0 }, bg = { 0.93, 0.93, 0.89 }, text = { 0.10, 0.10, 0.12 },
  box = { 1, 1, 1 }, panel = { 0.16, 0.18, 0.22 }, band = { 0.35, 0.55, 0.85 },
}
local function color(c, a) love.graphics.setColor(c[1], c[2], c[3], a or 1) end

-- opts: { sequence, font, maps, tilesetFor, spriteFor, animations, onDone }
function CreditsScreen.new(opts)
  return setmetatable({
    sequence = assert(opts.sequence), font = assert(opts.font),
    maps = opts.maps, tilesetFor = opts.tilesetFor,
    spriteFor = opts.spriteFor, animations = opts.animations,
    onDone = opts.onDone, quads = {},
  }, CreditsScreen)
end

function CreditsScreen:update()
  self.sequence:frame()
  if self.sequence.finished and self.onDone then self.onDone() end
end

function CreditsScreen:button(btn)
  -- any press skips the rest of the roll
  if btn and self.onDone then self.onDone() end
end

function CreditsScreen:quad(image, index, columns)
  local key = tostring(image) .. ":" .. index
  if not self.quads[key] then
    self.quads[key] = love.graphics.newQuad((index % columns) * 8,
      math.floor(index / columns) * 8, 8, 8, image:getDimensions())
  end
  return self.quads[key]
end

function CreditsScreen:drawScene(scene)
  if not (scene and self.maps and self.tilesetFor) then return false end
  local map = self.maps.maps and (self.maps.maps[scene.map] or self.maps.maps[scene.index])
  if not (map and map.tiles) then return false end
  local tileset = self.tilesetFor(map.tileset)
  if not tileset then return false end
  color(C.box)
  local across = math.min(20, map.width)
  local down = math.min(18, map.height)
  for ty = 0, down - 1 do
    for tx = 0, across - 1 do
      local index = (map.tiles[ty * map.width + tx + 1] or 0x80) - 0x80
      if index >= 0 and index < (tileset.tiles or 256) then
        love.graphics.draw(tileset.image, self:quad(tileset.image, index, tileset.columns or 16),
          tx * 8, ty * 8)
      end
    end
  end
  return true
end

function CreditsScreen:draw()
  local v = self.sequence:view()
  love.graphics.setFont(self.font)
  color(C.bg); love.graphics.rectangle("fill", 0, 0, W, H)

  if not self:drawScene(v.scene) then
    color(C.panel); love.graphics.rectangle("fill", 0, 0, W, H)
  end

  for _, rect in ipairs(v.rectangles or {}) do
    color(C.panel); love.graphics.rectangle("fill", rect.x * 8, rect.y * 8, 32, 16)
  end

  if v.overlay then
    color(C.band, 0.5)
    love.graphics.rectangle("fill", v.overlay.x, v.overlay.y,
      W, math.max(2, math.min(H, v.overlay.height)))
  end

  -- characters, using the overworld's sprite path
  if self.spriteFor and self.animations then
    for _, ch in ipairs(v.characters or {}) do
      local sheet = self.spriteFor(ch.sprite)
      local anim = self.animations[ch.direction or 0]
      local parts = anim and anim.oam and (anim.oam[anim.firstFrame or 0])
      if sheet and parts then
        color(C.box)
        for _, part in ipairs(parts) do
          love.graphics.draw(sheet.image,
            self:quad(sheet.image, part.tile, sheet.columns or 4),
            ch.x * 8 + (part.x or 0), ch.y * 8 + (part.y or 0))
        end
      end
    end
  end

  for _, line in ipairs(v.lines or {}) do
    if line.text then
      if line.boxed then
        color(C.box)
        love.graphics.rectangle("fill", line.x * 8 - 2, line.y * 8 - 2,
          math.min(W, #line.text * 5 + 6), 12)
      end
      color(C.text)
      love.graphics.print(line.text:gsub("\n", " "), line.x * 8, line.y * 8)
    end
  end

  if v.fade > 0 then
    color(C.black, v.fade)
    love.graphics.rectangle("fill", 0, 0, W, H)
  end
end

return CreditsScreen
