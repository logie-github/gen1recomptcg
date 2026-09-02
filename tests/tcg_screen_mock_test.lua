-- Smoke test for the LÖVE duel renderer with a mock love.graphics: every
-- session mode is drawn at least once so nil-index mistakes surface without
-- a real LÖVE.  TCG_CACHE=<dir> lua tests/tcg_screen_mock_test.lua

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/cards.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

-- mock love
local calls = 0
local function noop() calls = calls + 1 end
love = { graphics = setmetatable({}, { __index = function() return noop end }) }
local font = { getWidth = function(_, s) return #s * 4 end, setFilter = noop }

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local decks = dofile(cacheDir .. "/data/generated/decks.lua")
local Duel = require("src.tcg.Duel")
local DuelSession = require("src.tcg.DuelSession")
local DuelScreen = require("src.tcg.ui.DuelScreen")

local function expand(deck)
  local out = {}
  for _, e in ipairs(deck.cards) do for _ = 1, e.count do out[#out + 1] = e.card end end
  return out
end

local d = Duel.new(cards, { decks = { expand(decks[3]), expand(decks[2]) }, seed = 5, prizes = 4 })
local s = DuelSession.new({ duel = d, human = 1 })
local exited = false
local screen = DuelScreen.new({ session = s, font = font, cardImage = function() return {} end,
  onExit = function() exited = true end })
s:start()

local seen = {}
local guard = 0
while not exited and guard < 3000 do
  guard = guard + 1
  seen[s.mode] = true
  screen:update(1 / 60)
  screen:draw()
  -- wander through the menus
  if s.mode == "main" then
    local pick = ({ "hand", "attack", "check", "endTurn" })[guard % 4 + 1]
    for i, row in ipairs(s.menu) do if row.action == pick then s.cursor = i end end
    screen:button("a")
  elseif s.mode == "hand" then
    if guard % 3 == 0 then screen:button("a") else screen:button("b") end
  elseif s.mode == "attack" then
    screen:button("a")
    if s.mode == "attack" then screen:button("b") end
  elseif s.mode == "check" then screen:button("b")
  else screen:button("a") end
end
local modes = {}
for m in pairs(seen) do modes[#modes + 1] = m end
table.sort(modes)
print("drawn modes: " .. table.concat(modes, ", ") .. "; draw calls " .. calls .. "; exited=" .. tostring(exited))
assert(seen.log and seen.main and seen.hand and seen.attack and seen.prompt and seen.check, "not all modes drawn")
assert(exited, "did not reach the end of a duel")
print("tcg screen mock test: ok")
