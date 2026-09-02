-- HomeScreen against a mock love.graphics: every HomeSession mode drawn.
package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/cards.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()
local calls = 0
local function noop() calls = calls + 1 end
love = { graphics = setmetatable({}, { __index = function() return noop end }) }
local font = { getWidth = function(_, s) return #s * 4 end }

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local decks = dofile(cacheDir .. "/data/generated/decks.lua")
local boosters = dofile(cacheDir .. "/data/generated/boosters.lua")
local HomeSession = require("src.tcg.HomeSession")
local HomeScreen = require("src.tcg.ui.HomeScreen")

local saved
local s = HomeSession.new({ cards = cards, decks = decks, boosters = boosters, seed = 3,
  load = function() return saved end, save = function(t) saved = t end })
local quit = false
local screen = HomeScreen.new({ session = s, font = font, cardImage = function() return {} end,
  onQuit = function() quit = true end })

local seen = {}
local function step(btn) screen:update(1 / 60); screen:draw(); seen[s.mode] = true; if btn then screen:button(btn) end end
step("a")                    -- NEW GAME
step("a")                    -- starter
step("a")                    -- message
step()                       -- home
-- collection
s.cursor = 3; step("a"); step("down"); step("b")
-- decks / editor / pick
s.cursor = 2; step("a"); step("a"); s.cursor = 2; step("a"); step("select"); step("a"); step("b"); step("b"); step("b")
-- packs (none) -> message
s.cursor = 4; step("a"); step("a")
-- opponent list -> duel -> play by ending turns until over
s.cursor = 1; step("a"); step("a")
local guard = 0
while s.mode == "duel" and guard < 5000 do
  guard = guard + 1
  local ds = s.duelSession
  if ds.mode == "main" then
    if not ds:me().flags.attacked then
      ds:openAttack()
      local picked = false
      for i, row in ipairs(ds.menu) do if row.index then ds.cursor = i; step("a"); picked = true; break end end
      if not picked then ds:openMain(); ds.cursor = 6; step("a") end
    else ds:openMain(); ds.cursor = 6; step("a") end
  else step("a") end
end
step("a")                    -- reward message
step()
if #s.unopened > 0 then s.cursor = 4; step("a"); step("a"); step("a"); step("b") end
s.cursor = 6; step("a"); step()   -- QUIT
local modes = {}
for m in pairs(seen) do modes[#modes + 1] = m end
table.sort(modes)
print("drawn modes: " .. table.concat(modes, ", ") .. "; draw calls " .. calls .. "; quit=" .. tostring(quit))
for _, m in ipairs({ "title", "starter", "message", "home", "collection", "decks", "editor", "editorPick", "opponent", "duel" }) do
  assert(seen[m], "mode not drawn: " .. m)
end
assert(quit, "QUIT did not fire")
print("tcg home mock test: ok")
