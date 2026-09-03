-- Render the TCG screens through the software LÖVE stand-in and write them
-- as PNGs, so layout can be checked without LÖVE.
--   TCG_CACHE=<dir> lua tests/render_screens.lua <output dir>

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local outDir = arg and arg[1] or "/tmp/shots"

local Shim = require("tests.love_shim")
local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a"); f:close(); return data
end

local fontImage = Shim.image(readFile(cacheDir .. "/assets/generated/fonts/half_width.png"))
local surface, love
local function newFrame()
  surface = Shim.newSurface(160, 144)
  love = Shim.install(surface)
  _G.love = love
  love.graphics.setFontImage(fontImage)
  love.graphics.setColor(1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
end
local function save(name)
  local f = assert(io.open(outDir .. "/" .. name .. ".png", "wb"))
  f:write(surface:toPng()); f:close()
  print("wrote " .. name .. ".png")
end

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local decks = dofile(cacheDir .. "/data/generated/decks.lua")
local boosters = dofile(cacheDir .. "/data/generated/boosters.lua")
local maps = dofile(cacheDir .. "/data/generated/maps.lua")
local npcs = dofile(cacheDir .. "/data/generated/npcs.lua")
local tilesets = dofile(cacheDir .. "/data/generated/tilesets.lua")
local cardArt = dofile(cacheDir .. "/data/generated/card_art.lua")

local imageCache = {}
local function cardImage(id)
  if imageCache[id] == nil then
    local entry = cardArt[id]
    local bytes = entry and readFile(cacheDir .. "/assets/generated/" .. entry.file)
    imageCache[id] = bytes and Shim.image(bytes) or false
  end
  return imageCache[id] or nil
end
local sprites = dofile(cacheDir .. "/data/generated/sprites.lua")
local animations = dofile(cacheDir .. "/data/generated/sprite_animations.lua")
local spriteCache = {}
local function spriteFor(id)
  if spriteCache[id] == nil then
    local entry = sprites[id]
    local bytes = entry and readFile(cacheDir .. "/assets/generated/" .. entry.file)
    spriteCache[id] = bytes and { image = Shim.image(bytes), columns = entry.columns } or false
  end
  return spriteCache[id] or nil
end

local tilesetCache = {}
local function tilesetFor(id)
  if tilesetCache[id] == nil then
    local entry = tilesets[id]
    local bytes = entry and readFile(cacheDir .. "/assets/generated/" .. entry.file)
    tilesetCache[id] = bytes and
      { image = Shim.image(bytes), columns = entry.columns, tiles = entry.tiles } or false
  end
  return tilesetCache[id] or nil
end

local Duel = require("src.tcg.Duel")
local DuelSession = require("src.tcg.DuelSession")
local DuelScreen = require("src.tcg.ui.DuelScreen")
local HomeSession = require("src.tcg.HomeSession")
local HomeScreen = require("src.tcg.ui.HomeScreen")
local Overworld = require("src.tcg.Overworld")
local OverworldScreen = require("src.tcg.ui.OverworldScreen")

local function expand(deck)
  local out = {}
  for _, e in ipairs(deck.cards) do for _ = 1, e.count do out[#out + 1] = e.card end end
  return out
end

-- home flow
local saved
local home = HomeSession.new({ cards = cards, decks = decks, boosters = boosters, seed = 4,
  load = function() return saved end, save = function(t) saved = t end })
local homeScreen = HomeScreen.new({ session = home, font = Shim.font, cardImage = cardImage })
newFrame(); homeScreen:draw(); save("01_title")
home:press("a"); newFrame(); homeScreen:draw(); save("02_starter")
home:press("a"); newFrame(); homeScreen:draw(); save("03_message")
home:press("a"); newFrame(); homeScreen:draw(); save("04_home")
home.cursor = 3; home:press("a"); newFrame(); homeScreen:draw(); save("05_collection")
home:press("b")
home.cursor = 2; home:press("a"); newFrame(); homeScreen:draw(); save("06_decks")
home:press("a"); newFrame(); homeScreen:draw(); save("07_editor")

-- a duel mid-turn
local duel = Duel.new(cards, { decks = { expand(decks[3]), expand(decks[2]) },
  seed = 9, prizes = 4, names = { "YOU", "SAM" } })
local session = DuelSession.new({ duel = duel, human = 1 })
session:start()
local guard = 0
while session.mode ~= "main" and guard < 60 do guard = guard + 1; session:press("a") end
-- give the board some substance
local me = duel.players[1].active
me.energy = { cards.byConstant.FIGHTING_ENERGY, cards.byConstant.FIGHTING_ENERGY }
duel.players[2].active.hp = math.max(10, duel.players[2].active.hp - 20)
local duelScreen = DuelScreen.new({ session = session, font = Shim.font, cardImage = cardImage })
newFrame(); duelScreen:draw(); save("08_duel_main")
session:openHand(); newFrame(); duelScreen:draw(); save("09_duel_hand")
session:openAttack(); newFrame(); duelScreen:draw(); save("10_duel_attack")
session:press("b"); session:openMain(); session.cursor = 6; session:press("a")
newFrame(); duelScreen:draw(); save("11_duel_log")

-- overworld, with and without a message
local world = Overworld.new({ maps = maps, map = 1, npcs = npcs })
local screen = OverworldScreen.new({ world = world, font = Shim.font, tilesetFor = tilesetFor,
  spriteFor = spriteFor, animations = animations, npcs = npcs })
newFrame(); screen:draw(); save("12_overworld")
local mason
for _, n in ipairs(maps.maps[1].npcs) do if n.constant == "NPC_DRMASON" then mason = n end end
world.x, world.y = mason.x, mason.y + 2
world.facing = Overworld.NORTH
world:interact()
newFrame(); screen:draw(); save("13_overworld_talk")

-- credits: a frame from partway through the roll
do
  local CreditsSequence = require("src.tcg.CreditsSequence")
  local CreditsScreen = require("src.tcg.ui.CreditsScreen")
  local credits = dofile(cacheDir .. "/data/generated/credits.lua")
  local text = dofile(cacheDir .. "/data/generated/text.lua")
  local sequence = CreditsSequence.new({ credits = credits,
    textFor = function(id) return text.byId[id] end })
  local screen = CreditsScreen.new({ sequence = sequence, font = Shim.font,
    maps = maps, tilesetFor = tilesetFor, spriteFor = spriteFor, animations = animations })
  sequence:step()
  local shot = 0
  for i = 1, 4000 do
    sequence:frame()
    if #sequence.lines > 0 and sequence.fade < 0.2 and shot < 2 then
      shot = shot + 1
      newFrame(); screen:draw(); save(("14_credits_%d"):format(shot))
      for _ = 1, 400 do sequence:frame() end
    end
  end
end
