-- A software stand-in for the slice of LÖVE the TCG screens use, so screens
-- can be rendered and inspected without LÖVE installed.
--
-- Supports: setColor, rectangle (fill/line), print, draw (image, optional
-- quad, x, y, r, sx, sy), setFont, newQuad, newImage/newImageData via a
-- reader for the PNGs the importer wrote (PngWriter emits stored deflate
-- blocks, so no inflate is needed), plus getDimensions/clear.
--
-- Output is a pixel buffer that can be written back out as a PNG.

local PngWriter = require("src.import.PngWriter")

local Shim = {}

-- ---------------------------------------------------------------------
-- a 4x6 bitmap font, written here rather than taken from anywhere: each
-- glyph is 4 columns of 6 bits, low bit at the top row
-- ---------------------------------------------------------------------
local GLYPHS = {
  [" "] = "0000", ["!"] = "0170", ["'"] = "0030", ["("] = "0360", [")"] = "0630",
  ["*"] = "0250", ["+"] = "0272", [","] = "0100", ["-"] = "0220", ["."] = "0100",
  ["/"] = "0140", ["0"] = "3663", ["1"] = "0277", ["2"] = "3752", ["3"] = "2553",
  ["4"] = "0743", ["5"] = "2757", ["6"] = "2767", ["7"] = "3431", ["8"] = "3773",
  ["9"] = "3573", [":"] = "0120", [";"] = "0120", ["<"] = "0242", ["="] = "0550",
  [">"] = "0424", ["?"] = "1541", ["A"] = "7737", ["B"] = "7553", ["C"] = "3663",
  ["D"] = "7663", ["E"] = "7555", ["F"] = "7115", ["G"] = "3673", ["H"] = "7727",
  ["I"] = "0707", ["J"] = "2603", ["K"] = "7627", ["L"] = "7444", ["M"] = "7317",
  ["N"] = "7167", ["O"] = "3663", ["P"] = "7117", ["Q"] = "3E63", ["R"] = "7527",
  ["S"] = "2553", ["T"] = "1711", ["U"] = "7443", ["V"] = "3444", ["W"] = "7627",
  ["X"] = "6116", ["Y"] = "1711", ["Z"] = "5551", ["["] = "0770", ["]"] = "0770",
  ["_"] = "4444", ["a"] = "6552", ["b"] = "7552", ["c"] = "2552", ["d"] = "2557",
  ["e"] = "2555", ["f"] = "0717", ["g"] = "2E52", ["h"] = "7117", ["i"] = "0570",
  ["j"] = "0E50", ["k"] = "7623", ["l"] = "0374", ["m"] = "6161", ["n"] = "6117",
  ["o"] = "2552", ["p"] = "E152", ["q"] = "2E51", ["r"] = "6117", ["s"] = "2552",
  ["t"] = "0374", ["u"] = "6446", ["v"] = "2444", ["w"] = "6261", ["x"] = "5225",
  ["y"] = "2E46", ["z"] = "5551", ["v"] = "2444",
}
local GLYPH_W, GLYPH_H = 4, 6

-- ---------------------------------------------------------------------
-- PNG reading (only what PngWriter produces: 8-bit RGBA, stored deflate)
-- ---------------------------------------------------------------------
local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

function Shim.readPng(bytes)
  assert(bytes:sub(1, 8) == "\137PNG\r\n\26\n", "not a PNG")
  local pos = 9
  local width, height, idat = 0, 0, {}
  while pos < #bytes do
    local length = u32(bytes, pos)
    local kind = bytes:sub(pos + 4, pos + 7)
    local data = bytes:sub(pos + 8, pos + 7 + length)
    if kind == "IHDR" then
      width, height = u32(data, 1), u32(data, 5)
    elseif kind == "IDAT" then
      idat[#idat + 1] = data
    elseif kind == "IEND" then
      break
    end
    pos = pos + 12 + length
  end
  local z = table.concat(idat)
  -- skip the 2-byte zlib header, then walk stored blocks
  local out, p = {}, 3
  while p <= #z - 4 do
    local final = z:byte(p) % 2
    local len = z:byte(p + 1) + z:byte(p + 2) * 256
    out[#out + 1] = z:sub(p + 5, p + 4 + len)
    p = p + 5 + len
    if final == 1 then break end
  end
  local raw = table.concat(out)
  local pixels = {}
  local stride = width * 4
  for y = 0, height - 1 do
    local rowStart = y * (stride + 1) + 1
    assert(raw:byte(rowStart) == 0, "only filter type 0 is supported")
    for i = 1, stride do
      pixels[y * stride + i] = raw:byte(rowStart + i)
    end
  end
  return { width = width, height = height, pixels = pixels }
end

-- ---------------------------------------------------------------------
-- the graphics surface
-- ---------------------------------------------------------------------
local Surface = {}
Surface.__index = Surface

function Shim.newSurface(w, h)
  local self = setmetatable({ width = w, height = h, pixels = {} }, Surface)
  for i = 1, w * h * 4 do self.pixels[i] = (i % 4 == 0) and 255 or 0 end
  return self
end

function Surface:set(x, y, r, g, b, a)
  x, y = math.floor(x), math.floor(y)
  if x < 0 or y < 0 or x >= self.width or y >= self.height then return end
  a = a or 1
  if a <= 0 then return end
  local i = (y * self.width + x) * 4 + 1
  local p = self.pixels
  p[i] = math.floor(p[i] * (1 - a) + r * 255 * a)
  p[i + 1] = math.floor(p[i + 1] * (1 - a) + g * 255 * a)
  p[i + 2] = math.floor(p[i + 2] * (1 - a) + b * 255 * a)
  p[i + 3] = 255
end

function Surface:toPng()
  return PngWriter.encode({ width = self.width, height = self.height, pixels = self.pixels })
end

-- Build a love-like table drawing onto `surface`.
function Shim.install(surface)
  local color = { 1, 1, 1, 1 }
  local font
  local g = {}

  function g.setColor(r, gg, b, a)
    if type(r) == "table" then color = { r[1], r[2], r[3], r[4] or 1 }
    else color = { r, gg, b, a or 1 } end
  end
  function g.getColor() return color[1], color[2], color[3], color[4] end
  function g.setFont(f) font = f end
  function g.getFont() return font end
  function g.getDimensions() return surface.width, surface.height end
  function g.getWidth() return surface.width end
  function g.getHeight() return surface.height end
  function g.clear(r, gg, b)
    for y = 0, surface.height - 1 do
      for x = 0, surface.width - 1 do surface:set(x, y, r or 0, gg or 0, b or 0, 1) end
    end
  end
  function g.push() end
  function g.pop() end
  function g.setCanvas() end
  function g.origin() end
  function g.translate() end
  function g.setScissor() end

  function g.rectangle(mode, x, y, w, h)
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    for iy = 0, h - 1 do
      for ix = 0, w - 1 do
        local edge = ix == 0 or iy == 0 or ix == w - 1 or iy == h - 1
        if mode == "fill" or edge then
          surface:set(x + ix, y + iy, color[1], color[2], color[3], color[4])
        end
      end
    end
  end

  -- Text is drawn with the game's own half-width font when one has been
  -- supplied (assets/generated/fonts/half_width.png: 8x8 glyphs in an
  -- 8-wide grid starting at $20), falling back to the crude built-in glyphs.
  function g.setFontImage(image) g._fontImage = image end

  function g.print(text, x, y)
    if g._fontImage then
      local img = g._fontImage
      x, y = math.floor(x), math.floor(y)
      for i = 1, #tostring(text) do
        local code = tostring(text):byte(i)
        local index = code - 0x20
        if index >= 0 then
          local sx, sy = (index % 8) * 8, math.floor(index / 8) * 8
          for iy = 0, 7 do
            for ix = 0, 7 do
              local pi = ((sy + iy) * img.width + sx + ix) * 4 + 1
              if (img.pixels[pi + 3] or 0) > 0 then
                surface:set(x + ix, y + iy, color[1], color[2], color[3], color[4])
              end
            end
          end
        end
        x = x + 5
      end
      return
    end
    return g._printFallback(text, x, y)
  end

  function g._printFallback(text, x, y)
    text = tostring(text)
    x, y = math.floor(x), math.floor(y)
    for i = 1, #text do
      local ch = text:sub(i, i)
      local glyph = GLYPHS[ch] or GLYPHS[ch:upper()] or GLYPHS["?"]
      for col = 1, GLYPH_W do
        local bits = tonumber(glyph:sub(col, col), 16) or 0
        for row = 0, GLYPH_H - 1 do
          if math.floor(bits / 2 ^ row) % 2 == 1 then
            surface:set(x + col - 1, y + row, color[1], color[2], color[3], color[4])
          end
        end
      end
      x = x + GLYPH_W + 1
    end
  end
  g.printf = function(text, x, y) g.print(text, x, y) end

  function g.newQuad(qx, qy, qw, qh, iw, ih)
    return { x = qx, y = qy, w = qw, h = qh }
  end

  function g.draw(image, a, b, c, d, e, f)
    local quad, x, y, sx, sy
    if type(a) == "table" and a.w then
      quad, x, y, sx, sy = a, b, c, e or 1, f or 1
    else
      x, y, sx, sy = a, b, d or 1, e or 1
    end
    x, y = math.floor(x or 0), math.floor(y or 0)
    local qx = quad and quad.x or 0
    local qy = quad and quad.y or 0
    local qw = quad and quad.w or image.width
    local qh = quad and quad.h or image.height
    for iy = 0, math.floor(qh * sy) - 1 do
      for ix = 0, math.floor(qw * sx) - 1 do
        local sxp = qx + math.floor(ix / sx)
        local syp = qy + math.floor(iy / sy)
        if sxp < image.width and syp < image.height then
          local i = (syp * image.width + sxp) * 4 + 1
          local p = image.pixels
          local alpha = (p[i + 3] or 255) / 255
          if alpha > 0 then
            surface:set(x + ix, y + iy,
              (p[i] or 0) / 255 * color[1], (p[i + 1] or 0) / 255 * color[2],
              (p[i + 2] or 0) / 255 * color[3], alpha * color[4])
          end
        end
      end
    end
  end

  local love = { graphics = g }
  love.timer = { getTime = function() return os.clock() end }
  return love
end

-- An image usable by g.draw, loaded from one of the importer's PNGs.
function Shim.image(bytes)
  local png = Shim.readPng(bytes)
  png.getDimensions = function(self) return self.width, self.height end
  png.setFilter = function() end
  return png
end

Shim.font = {
  getWidth = function(_, s) return #tostring(s) * (GLYPH_W + 1) end,
  getHeight = function() return GLYPH_H end,
  setFilter = function() end,
}

return Shim
