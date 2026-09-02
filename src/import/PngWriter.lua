-- Minimal PNG encoder in plain Lua (5.1 / LuaJIT / 5.4 compatible).
--
-- Produces an 8-bit RGBA PNG using zlib "stored" (uncompressed) deflate
-- blocks, so it needs no compression library.  Used by the headless
-- extraction path (tools/tcg_extract_cli.lua) and as a fallback image
-- backend; under LÖVE, ImageWriter/love.image is used instead.
--
-- image = { width = w, height = h, pixels = { r,g,b,a, r,g,b,a, ... } }
-- with pixel values 0..255 in row-major order.

local PngWriter = {}

-- Portable XOR for 32-bit values without bit libraries.
local function bxor(a, b)
  local result, bit = 0, 1
  while a > 0 or b > 0 do
    local ab, bb = a % 2, b % 2
    if ab ~= bb then result = result + bit end
    a, b, bit = (a - ab) / 2, (b - bb) / 2, bit * 2
  end
  return result
end

local function buildCrcTable()
  local t = {}
  for n = 0, 255 do
    local c = n
    for _ = 1, 8 do
      if c % 2 == 1 then
        c = bxor((c - 1) / 2, 0xEDB88320)
      else
        c = c / 2
      end
    end
    t[n] = c
  end
  return t
end
local crc_t = buildCrcTable()

local function crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    local byte = s:byte(i)
    local idx = bxor(c % 256, byte)
    c = bxor(crc_t[idx], (c - c % 256) / 256)
  end
  return bxor(c, 0xFFFFFFFF)
end

local function adler32(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

local function u32be(n)
  return string.char(
    math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256, n % 256)
end

local function chunk(kind, data)
  return u32be(#data) .. kind .. data .. u32be(crc32(kind .. data))
end

-- zlib stream with stored deflate blocks (max 65535 bytes each).
local function zlibStored(raw)
  local out = { "\120\1" }   -- CMF/FLG for no compression
  local pos, len = 1, #raw
  repeat
    local n = math.min(65535, len - pos + 1)
    local final = (pos + n - 1 >= len) and 1 or 0
    out[#out + 1] = string.char(final,
      n % 256, math.floor(n / 256),
      (65535 - n) % 256, math.floor((65535 - n) / 256))
    out[#out + 1] = raw:sub(pos, pos + n - 1)
    pos = pos + n
  until pos > len
  if len == 0 then out[#out + 1] = string.char(1, 0, 0, 255, 255) end
  out[#out + 1] = u32be(adler32(raw))
  return table.concat(out)
end

function PngWriter.encode(image)
  local w, h, px = image.width, image.height, image.pixels
  assert(#px == w * h * 4, "pixel buffer size mismatch")
  local rows = {}
  local i = 1
  for _ = 1, h do
    local row = { "\0" }   -- filter type 0
    local bytes = {}
    for x = 1, w * 4 do
      bytes[x] = string.char(px[i]); i = i + 1
    end
    row[2] = table.concat(bytes)
    rows[#rows + 1] = table.concat(row)
  end
  local ihdr = u32be(w) .. u32be(h) .. string.char(8, 6, 0, 0, 0)
  return "\137PNG\r\n\26\n"
    .. chunk("IHDR", ihdr)
    .. chunk("IDAT", zlibStored(table.concat(rows)))
    .. chunk("IEND", "")
end

function PngWriter.newImage(width, height)
  local px = {}
  for i = 1, width * height * 4 do px[i] = 0 end
  return { width = width, height = height, pixels = px }
end

function PngWriter.setPixel(image, x, y, r, g, b, a)
  local i = (y * image.width + x) * 4 + 1
  local px = image.pixels
  px[i], px[i + 1], px[i + 2], px[i + 3] = r, g, b, a or 255
end

return PngWriter
