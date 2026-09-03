-- OverworldScreen against a mock love.graphics: draws the map, markers and
-- the text box without a real LÖVE.
package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/maps.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()
local calls = 0
local function noop() calls = calls + 1 end
love = { graphics = setmetatable({}, { __index = function() return noop end }) }
local font = { getWidth = function(_, s) return #s * 4 end }

local maps = dofile(cacheDir .. "/data/generated/maps.lua")
local Overworld = require("src.tcg.Overworld")
local OverworldScreen = require("src.tcg.ui.OverworldScreen")

local exited = false
local world = Overworld.new({ maps = maps, map = 1 })
-- a stand-in tileset so the tile-drawing path is exercised too
local fakeTileset = { image = { getDimensions = function() return 128, 96 end }, columns = 16, tiles = 151 }
local screen = OverworldScreen.new({ world = world, font = font,
  tilesetFor = function() return fakeTileset end,
  onExit = function() exited = true end })

local seenMaps, sawMessage = {}, false
local rng = 7
for i = 1, 3000 do
  screen:update(1 / 60)
  screen:draw()
  seenMaps[world.mapIndex] = true
  if world.message then sawMessage = true end
  rng = (rng * 1103515245 + 12345) % 2147483648
  local btn = ({ "up", "down", "left", "right", "a", "b" })[math.floor(rng / 65536) % 6 + 1]
  screen:button(btn)
end
screen:button("start")
local n = 0
for _ in pairs(seenMaps) do n = n + 1 end
print(("drawn: %d maps visited, message box %s, %d draw calls, exited=%s")
  :format(n, tostring(sawMessage), calls, tostring(exited)))
assert(n >= 2, "never left the first map")
assert(sawMessage, "never opened a message")
assert(exited, "START did not exit")
print("tcg overworld mock test: ok")
