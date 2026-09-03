-- Overworld renderer (Phase 10).  Draws an Overworld's view on the 160x144
-- canvas and forwards Game Boy buttons.
--
-- Draws the map's own tiles when a tileset image is supplied (map tile bytes
-- are VRAM tile numbers, which start at $80 because the loader stages the
-- tileset at that offset -- see LoadTilesetGfx/GetTileOffsetPointer), with
-- markers over the top for warps, NPCs and objects and an arrow for the
-- player.  Without a tileset it falls back to a schematic drawn from the
-- permission grid, which is what the headless tests exercise.

local OverworldScreen = {}
OverworldScreen.__index = OverworldScreen

local W, H = 160, 144
local CELL = 8                     -- one 2x2-tile permission block on screen
local VIEW_W, VIEW_H = 19, 13      -- blocks visible around the player

local C = {
  bg = { 0.09, 0.10, 0.13 }, floor = { 0.72, 0.74, 0.70 }, wall = { 0.25, 0.27, 0.33 },
  warp = { 0.35, 0.55, 0.85 }, npc = { 0.90, 0.72, 0.25 }, object = { 0.45, 0.75, 0.45 },
  player = { 0.86, 0.22, 0.20 }, text = { 0.10, 0.10, 0.12 }, light = { 0.95, 0.95, 0.95 },
  box = { 1, 1, 1 }, panel = { 0.16, 0.18, 0.22 },
}
local function color(c) love.graphics.setColor(c[1], c[2], c[3], c[4] or 1) end

local function shortName(text, n)
  text = tostring(text or "")
  if #text > n then return text:sub(1, n - 1) .. "." end
  return text
end

-- opts.tileset: { image = love Image, columns = n, tiles = n } or nil
-- opts.spriteFor(spriteId) -> { image, columns } ; opts.animations = the
-- extracted sprite_animations table.  An NPC is drawn from its animation's
-- OAM records (tile plus x/y offsets) rather than from any assumed layout of
-- the sprite sheet -- the sheet is just a tile bank.
function OverworldScreen.new(opts)
  return setmetatable({
    world = assert(opts.world), font = assert(opts.font),
    tilesetFor = opts.tilesetFor,     -- function(tilesetId) -> tileset or nil
    spriteFor = opts.spriteFor,
    animations = opts.animations,
    npcData = opts.npcs,
    onExit = opts.onExit, blink = 0, quads = {},
  }, OverworldScreen)
end

-- Draw one 16x16 character at screen position (px, py).
function OverworldScreen:drawCharacter(spriteId, animId, px, py)
  if not (self.spriteFor and self.animations) then return false end
  local sheet = self.spriteFor(spriteId)
  local anim = self.animations[animId] or self.animations[tostring(animId)]
  if not (sheet and anim and anim.oam) then return false end
  local first = anim.firstFrame or 0
  local parts = anim.oam[first] or anim.oam[tostring(first)]
  if not parts then return false end
  color(C.box)
  local columns = sheet.columns or 4
  for _, part in ipairs(parts) do
    local index = part.tile
    local quad = love.graphics.newQuad((index % columns) * 8,
      math.floor(index / columns) * 8, 8, 8, sheet.image:getDimensions())
    love.graphics.draw(sheet.image, quad, px + (part.x or 0) / 2, py + (part.y or 0) / 2,
      0, 0.5, 0.5)
  end
  return true
end

local TILE_BASE = 0x80              -- wVRAMTileOffset for map tilesets

function OverworldScreen:quad(tileset, index)
  local cache = self.quads[tileset]
  if not cache then cache = {}; self.quads[tileset] = cache end
  if not cache[index] then
    local columns = tileset.columns or 16
    cache[index] = love.graphics.newQuad(
      (index % columns) * 8, math.floor(index / columns) * 8, 8, 8,
      tileset.image:getDimensions())
  end
  return cache[index]
end

function OverworldScreen:update(dt)
  self.blink = (self.blink + dt) % 1
  -- drive any in-progress slide
  self.world:update()
end

function OverworldScreen:button(btn)
  if btn == "start" and self.onExit then return self.onExit() end
  local message = self.world.message
  if message and message.kind == "choice" then
    local options = message.options or { "OK", "Cancel" }
    if btn == "up" then
      self.choice = ((self.choice or 1) - 2) % #options + 1
      return
    elseif btn == "down" then
      self.choice = ((self.choice or 1)) % #options + 1
      return
    elseif btn == "a" then
      local picked = (self.choice or 1) == 1
      self.choice = 1
      return self.world:interact(picked)
    elseif btn == "b" then
      self.choice = 1
      return self.world:interact(false)
    end
  end
  self.world:press(btn)
end

local ARROW = { [0] = "^", ">", "v", "<" }

function OverworldScreen:draw()
  local v = self.world:view()
  love.graphics.setFont(self.font)
  color(C.bg); love.graphics.rectangle("fill", 0, 0, W, H)

  -- camera in block units, centred on the player and clamped to the map
  local pbx, pby = math.floor(v.x / 2), math.floor(v.y / 2)
  local bw = math.floor(((v.width or 2) + 1) / 2)
  local bh = math.floor(((v.height or 2) + 1) / 2)
  local ox = math.max(0, math.min(bw - VIEW_W, pbx - math.floor(VIEW_W / 2)))
  local oy = math.max(0, math.min(bh - VIEW_H, pby - math.floor(VIEW_H / 2)))

  local tileset = self.tilesetFor and v.tileset and self.tilesetFor(v.tileset) or nil
  if tileset and v.tiles then
    -- one 8px cell on screen is one 2x2-tile block, so draw the block's four
    -- tiles at half scale and keep the block grid the markers use
    color(C.box)
    for row = 0, VIEW_H - 1 do
      for col = 0, VIEW_W - 1 do
        local bx, by = ox + col, oy + row
        for sub = 0, 3 do
          local tx = bx * 2 + sub % 2
          local ty = by * 2 + math.floor(sub / 2)
          if tx < v.width and ty < v.height then
            local index = (v.tiles[ty * v.width + tx + 1] or TILE_BASE) - TILE_BASE
            if index >= 0 and index < (tileset.tiles or 256) then
              love.graphics.draw(tileset.image, self:quad(tileset, index),
                col * CELL + (sub % 2) * 4, 11 + row * CELL + math.floor(sub / 2) * 4,
                0, 0.5, 0.5)
            end
          end
        end
      end
    end
  else
    for row = 0, VIEW_H - 1 do
      for col = 0, VIEW_W - 1 do
        local bx, by = ox + col, oy + row
        if bx < bw and by < bh then
          local walkable = self.world:walkable(bx * 2, by * 2)
          color(walkable and C.floor or C.wall)
          love.graphics.rectangle("fill", col * CELL, 11 + row * CELL, CELL - 1, CELL - 1)
        end
      end
    end
  end

  local function marker(x, y, c, glyph, mover)
    local dx, dy = 0, 0
    if mover then dx, dy = self.world:offsetOf(mover) end
    local col = (x + dx) / 2 - ox
    local row = (y + dy) / 2 - oy
    if col < 0 or row < 0 or col >= VIEW_W or row >= VIEW_H then return end
    color({ c[1], c[2], c[3], tileset and 0.55 or 1 })
    love.graphics.rectangle("fill", col * CELL, 11 + row * CELL, CELL - 1, CELL - 1)
    if glyph then
      color(C.text)
      love.graphics.print(glyph, col * CELL + 1, 11 + row * CELL - 1)
    end
  end

  for _, w in ipairs(v.warps or {}) do marker(w.x, w.y, C.warp) end
  for _, o in ipairs(v.objects or {}) do marker(o.x, o.y, C.object) end
  for _, n in ipairs(v.npcs or {}) do
    local col, row = math.floor(n.x / 2) - ox, math.floor(n.y / 2) - oy
    local drawn = false
    if col >= 0 and row >= 0 and col < VIEW_W and row < VIEW_H then
      local entry = self.npcData and self.npcData.npcs
        and (self.npcData.npcs[n.npc] or self.npcData.npcs[tostring(n.npc)])
      if entry then
        -- the header names the animation for one facing; the four facings
        -- are consecutive ids in the order north, east, south, west
        local animId = (entry.animation or 0) + (n.direction or 0)
        drawn = self:drawCharacter(entry.sprite, animId,
          col * CELL, 11 + row * CELL)
      end
    end
    if not drawn then marker(n.x, n.y, C.npc) end
  end
  marker(v.x, v.y, C.player, ARROW[v.facing], self.world)

  color(C.panel); love.graphics.rectangle("fill", 0, 0, W, 11)
  color(C.light)
  love.graphics.print(shortName(((v.name or "MAP"):gsub("_", " ")), 20), 2, 1)
  love.graphics.print("START", W - 27, 1)

  if v.message and v.message.kind == "choice" then
    local options = v.message.options or { "OK", "Cancel" }
    color(C.box); love.graphics.rectangle("fill", 0, H - 34, W, 34)
    color(C.panel); love.graphics.rectangle("line", 0.5, H - 33.5, W - 1, 33)
    color(C.text)
    love.graphics.print(shortName(v.message.name or "Choose", 30), 4, H - 31)
    for i, option in ipairs(options) do
      local y = H - 21 + (i - 1) * 9
      if i == (self.choice or 1) then
        color(C.player); love.graphics.print(">", 4, y)
      end
      color(C.text)
      love.graphics.print(shortName(option, 26), 12, y)
    end
  elseif v.message then
    color(C.box); love.graphics.rectangle("fill", 0, H - 34, W, 34)
    color(C.panel); love.graphics.rectangle("line", 0.5, H - 33.5, W - 1, 33)
    color(C.text)
    local name = v.message.name
    local text = v.message.text or "..."
    if name then love.graphics.print(tostring(name):sub(1, 30), 4, H - 31) end
    local y = H - 22
    for line in (text:gsub("\n", " ") .. " "):gmatch("(.-) ") do
      self._line = self._line or ""
      if #self._line + #line + 1 > 30 then
        if y + 8 > H - 2 then self._line = nil; break end
        love.graphics.print(self._line, 4, y); y = y + 9; self._line = line
      else
        self._line = (#self._line > 0) and (self._line .. " " .. line) or line
      end
    end
    if self._line and y + 8 <= H - 2 then love.graphics.print(self._line, 4, y) end
    self._line = nil
    if self.blink < 0.6 then color(C.player); love.graphics.print("v", W - 9, H - 10) end
  end
end

return OverworldScreen
