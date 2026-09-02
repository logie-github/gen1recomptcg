-- HomeSession: new game, starter, deck editor, packs, a full duel through
-- the flow with rewards, save/continue.  TCG_CACHE=<dir> lua tests/tcg_home_test.lua

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/cards.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local decks = dofile(cacheDir .. "/data/generated/decks.lua")
local boosters = dofile(cacheDir .. "/data/generated/boosters.lua")
local HomeSession = require("src.tcg.HomeSession")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. msg) end
end

local saved = nil
local function newSession(seed)
  return HomeSession.new({ cards = cards, decks = decks, boosters = boosters, seed = seed or 1,
    load = function() return saved end, save = function(t) saved = t end })
end

local h = newSession(1)
check(h.mode == "title" and #h.menu == 1, "fresh title has only NEW GAME")
h:press("a")
check(h.mode == "starter", "starter menu")
h:press("down"); h:press("a")                        -- Squirtle
check(h.mode == "message", "starter message")
h:press("a")
check(h.mode == "home" and h.collection.starter == "squirtle", "home after starter")
check(saved ~= nil, "auto-saved after starter")

-- collection screen lists owned cards
h:press("down"); h:press("down"); h:press("a")
check(h.mode == "collection" and #h.menu > 10, "collection lists cards")
h:press("b")

-- deck editor: open slot 2, add cards, try to save (illegal), fill it, save
h:press("down"); h:press("a")                        -- DECKS
check(h.mode == "decks", "decks menu")
h:press("down"); h:press("a")                        -- slot 2
check(h.mode == "editor" and #h.editor.cards == 0, "empty editor for slot 2")
h.cursor = 2; h:press("a")                           -- ADD CARDS
check(h.mode == "editorPick", "pick list")
h:press("select")
check(h.editor.filter == "pokemon", "filter cycles")
-- give the first listed Pokemon extra copies so the 4-of rule is what stops us
local firstCard = h.menu[1].card
h.collection:add(firstCard, 10)
h:openEditorPick()
h.cursor = 1
h:press("a")                                          -- add it
check(#h.editor.cards == 1, "card added")
for _ = 1, 3 do h:press("a") end
check(#h.editor.cards == 4, "four copies added")
h:press("a")                                          -- fifth: refused with an inline notice
check(h.mode == "editorPick" and h.notice ~= nil and #h.editor.cards == 4, "4-of limit notice, still 4 (" .. #h.editor.cards .. ")")
h:press("b")                                          -- back to editor
h.cursor = 3; h:press("a")                            -- SAVE (illegal: 4 cards)
check(h.mode == "message", "illegal save explains")
h:press("a")
check(h.mode == "editor" and not h.collection.decks[2], "illegal deck not saved")
-- fill with energy through the picker (a fresh collection owns too few, so top it up)
h.collection:add(cards.byConstant.WATER_ENERGY, 60)
h.cursor = 2; h:press("a")
while h.editor.filter ~= "energy" do h:press("select") end
local guard = 0
while #h.editor.cards < 60 and guard < 400 do
  guard = guard + 1
  local before = #h.editor.cards
  h:press("a")
  if h.mode == "message" then h:press("a") end
  if #h.editor.cards == before then h:press("down") end
end
check(#h.editor.cards == 60, "filled to 60 (" .. #h.editor.cards .. ")")
h:press("b")
h.cursor = 3; h:press("a")
check(h.collection.decks[2] and #h.collection.decks[2].cards == 60, "legal deck saved to slot 2")
h:press("a")                                          -- dismiss "Deck saved."
check(h.mode == "decks", "back at decks")
h:press("select")                                     -- make slot 1 active (cursor 1)
check(h.activeDeck == 1, "slot 1 chosen as duel deck")
h:press("b")

-- a duel from the home menu through to the reward
h:press("a")                                          -- DUEL (home cursor 1)
check(h.mode == "opponent" and #h.menu > 20, "opponent list")
for i, row in ipairs(h.menu) do if row.label:find("Sam") then h.cursor = i end end
h:press("a")
check(h.mode == "duel", "duel started")
-- play the human seat with the scripted approach from tcg_session_test: pick
-- defaults, attack when possible, end turn otherwise
guard = 0
while h.mode == "duel" and guard < 4000 do
  guard = guard + 1
  local s = h.duelSession
  if s.mode == "over" then h:press("a")
  elseif s.mode == "main" then
    local pl = s:me()
    if not pl.flags.attacked then
      s:openAttack()
      local chosen = false
      for i, row in ipairs(s.menu) do if row.index then s.cursor = i; s:press("a"); chosen = true; break end end
      if not chosen then s:openMain(); s.cursor = 6; s:press("a") end
    else s:openMain(); s.cursor = 6; s:press("a") end
  else h:press("a") end
end
check(h.mode == "message", "reward/loss message after the duel (mode " .. h.mode .. ")")
local st = h.collection.stats
check(st.duels == 1 and (st.wins + st.losses == 1 or st.wins + st.losses == 0), "stats updated")
h:press("a")
if st.wins == 1 then
  check(#h.unopened == 2, "two packs after a win")
  h.cursor = 4; h:press("a")                          -- PACKS
  check(h.mode == "packs", "packs list")
  h:press("a")
  check(h.mode == "packResult" and #h.lastPack == 10, "pack opened, 10 cards")
  check(h.collection.stats.boosters == 1, "booster counted")
  h:press("a")
  check(h.mode == "packs" and #h.unopened == 1, "one pack left")
  h:press("b")
end

-- continue from save
local h2 = newSession(2)
check(#h2.menu == 2 and h2.menu[1].action == "continue", "CONTINUE offered with a save")
h2:press("a")
check(h2.mode == "home" and h2.collection.decks[2] and #h2.collection.decks[2].cards == 60, "continued with saved decks")
check(h2.collection.stats.duels == 1, "stats persisted")

print(("tcg home tests: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
