-- Deck name entry: typing, limits, cancel, and saving a renamed deck.
package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/cards.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local decks = dofile(cacheDir .. "/data/generated/decks.lua")
local boosters = dofile(cacheDir .. "/data/generated/boosters.lua")
local NameEntry = require("src.tcg.NameEntry")
local HomeSession = require("src.tcg.HomeSession")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. msg) end
end

-- typing
do
  local got
  local entry = NameEntry.new({ onDone = function(name) got = name end })
  check(entry:current() == "A", "the cursor starts on A")
  entry:press("a")
  check(entry.name == "A", "A is typed")
  entry:press("right"); entry:press("a")
  check(entry.name == "AB", "the cursor moves along the row")
  entry:press("down"); entry:press("a")
  check(#entry.name == 3, "and between rows")
  entry:press("b")
  check(#entry.name == 2, "B rubs out")
  entry:press("start")
  check(entry.done and got == entry.name, "START accepts the name")
end

-- the limit and trailing spaces
do
  local entry = NameEntry.new({ limit = 4 })
  for _ = 1, 10 do entry:press("a") end
  check(#entry.name == 4, "typing stops at the limit (" .. #entry.name .. ")")

  local got, sentinel = nil, false
  local spaced = NameEntry.new({ onDone = function(name) got = name; sentinel = true end })
  spaced.name = "Deck   "
  spaced:press("start")
  check(sentinel and got == "Deck", "trailing spaces are trimmed")

  local blank = NameEntry.new({ onDone = function(name) got = name end })
  blank.name = "   "
  blank:press("start")
  check(got == nil, "an empty name is refused")

  local cancelled, called = nil, false
  local c = NameEntry.new({ name = "Keep", onDone = function(n) cancelled = n; called = true end })
  c:press("select")
  check(called and cancelled == nil, "SELECT cancels")
end

-- through the home flow: rename a deck slot and save it
do
  local saved
  local h = HomeSession.new({ cards = cards, decks = decks, boosters = boosters, seed = 2,
    load = function() return saved end, save = function(t) saved = t end })
  h:press("a"); h:press("a"); h:press("a")          -- new game, starter, message
  h.cursor = 2; h:press("a")                        -- DECKS
  h:press("a")                                      -- edit slot 1
  check(h.mode == "editor", "the editor is open")
  local renameRow
  for i, row in ipairs(h.menu) do if row.action == "rename" then renameRow = i end end
  check(renameRow ~= nil, "the editor offers RENAME")
  h.cursor = renameRow; h:press("a")
  check(h.mode == "nameEntry" and h.nameEntry ~= nil, "name entry opens")
  h.nameEntry.name = ""
  h:press("a"); h:press("right"); h:press("a")      -- type two letters
  h:press("start")
  check(h.mode == "editor", "accepting returns to the editor")
  check(h.editor.name == "AB", "the deck took the new name (" .. tostring(h.editor.name) .. ")")
  for i, row in ipairs(h.menu) do
    if row.action == "save" then h.cursor = i end
  end
  h:press("a")
  h:press("a")                                      -- dismiss the message
  check(h.collection.decks[1].name == "AB", "the saved deck keeps the name")
  local Collection = require("src.tcg.Collection")
  local back = Collection.deserialize(cards, saved)
  check(back and back.decks[1].name == "AB", "and it survives the save")
end

print(("tcg name tests: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
