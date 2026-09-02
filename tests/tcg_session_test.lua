-- DuelSession driven by Game Boy buttons: the human seat is played by a
-- script that navigates the real menus (HAND -> card -> target, ATTACK,
-- END TURN, promotion prompts), so the same paths the LÖVE screen exercises
-- are covered without LÖVE.
--   TCG_CACHE=<dir> lua tests/tcg_session_test.lua [games]

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/cards.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local decks = dofile(cacheDir .. "/data/generated/decks.lua")
local Duel = require("src.tcg.Duel")
local DuelSession = require("src.tcg.DuelSession")

local games = tonumber(arg and arg[1]) or 30
local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. msg) end
end

local function expand(deck)
  local out = {}
  for _, e in ipairs(deck.cards) do for _ = 1, e.count do out[#out + 1] = e.card end end
  return out
end
local sams, practice = expand(decks[2]), expand(decks[3])

-- 1. menu mechanics on one session
do
  local d = Duel.new(cards, { decks = { practice, sams }, seed = 11, prizes = 4, names = { "YOU", "SAM" } })
  local s = DuelSession.new({ duel = d, human = 1 })
  s:start()
  check(s.mode == "prompt" and s.prompt.title:find("Active"), "setup asks for an active")
  s:press("a")
  check(d.players[1].active ~= nil, "active placed via prompt")
  -- bench prompt or straight to play
  local guard = 0
  while s.mode == "prompt" and s.prompt.title:find("Bench") do
    s:press("down"); s:press("a")   -- pick whatever is under the cursor (moves toward Done)
    guard = guard + 1; if guard > 10 then break end
  end
  -- skip any log pages
  guard = 0
  while s.mode == "log" do s:press("a"); guard = guard + 1; if guard > 50 then break end end
  check(s.mode == "main" or s.mode == "prompt", "main menu after setup (mode " .. s.mode .. ")")
  if s.mode == "main" then
    s:press("a")                                   -- HAND
    check(s.mode == "hand", "HAND opens the hand")
    s:press("b")
    check(s.mode == "main", "B returns to main")
    s:press("down"); s:press("a")                  -- ATTACK
    check(s.mode == "attack", "ATTACK opens the attack list")
    s:press("b")
    s:press("down"); s:press("down"); s:press("down"); s:press("down"); s:press("a")  -- CHECK
    check(s.mode == "check", "CHECK opens")
    s:press("b")
    check(s.mode == "main", "back to main")
    local v = s:view()
    check(v.me.active and v.foe.active and v.me.prizes == 4, "view exposes both sides")
  end
end

-- 2. scripted human: play everything playable, attack with the first
--    legal attack, else end the turn; answer every prompt with option 1.
local function scriptedTurn(s)
  local guard = 0
  while not s.duel.finished and guard < 400 do
    guard = guard + 1
    if s.mode == "log" then s:press("a")
    elseif s.mode == "prompt" then s:press("a")
    elseif s.mode == "main" then
      local pl = s:me()
      -- try each hand card once per turn, then attack, then end
      local played = false
      if not pl.flags.scriptDone then
        pl.flags.scriptDone = 0
      end
      if pl.flags.scriptDone < #pl.hand then
        pl.flags.scriptDone = pl.flags.scriptDone + 1
        s:openHand()
        s.cursor = pl.flags.scriptDone
        local before = #s.duel.log
        s:press("a")
        if s.mode == "hand" then s:press("b") end
        played = #s.duel.log > before
        if s.mode == "prompt" and s.prompt.cancel then s:press("a") end
      elseif not pl.flags.attacked then
        s:openAttack()
        local chosen = false
        for i, row in ipairs(s.menu) do
          if row.index then s.cursor = i; s:press("a"); chosen = true; break end
        end
        if not chosen then s:press("b"); s:openMain(); s.cursor = 6; s:press("a") end
        pl.flags.scriptDone = nil
      else
        s:openMain(); s.cursor = 6; s:press("a")
        pl.flags.scriptDone = nil
      end
    elseif s.mode == "hand" or s.mode == "attack" or s.mode == "check" then s:press("b")
    elseif s.mode == "over" then break
    else break end
  end
end

local endings = {}
for g = 1, games do
  local human = (g % 2) + 1
  local d = Duel.new(cards, { decks = { practice, sams }, seed = g * 13, prizes = 4, names = { "P1", "P2" } })
  local s = DuelSession.new({ duel = d, human = human })
  local ok, err = pcall(function()
    s:start()
    local guard = 0
    while not d.finished and guard < 3000 do
      guard = guard + 1
      if s.mode == "prompt" or s.mode == "log" then s:press("a")
      elseif s.mode == "main" then scriptedTurn(s)
      else s:press("b") end
    end
    if not d.finished then d:finish(0, "guard") end
    -- catch up the log so mode reaches "over"
    guard = 0
    while s.mode ~= "over" and guard < 200 do s:press("a"); guard = guard + 1 end
  end)
  if not ok then
    check(false, ("game %d crashed: %s"):format(g, tostring(err)))
    for i = math.max(1, #d.log - 6), #d.log do print("   " .. d.log[i]) end
  else
    check(d.finished.reason ~= "guard", "game " .. g .. " ended by rules")
    check(s.mode == "over", "game " .. g .. " session reached 'over' (mode " .. s.mode .. ")")
    check(d:census(1) == 60 and d:census(2) == 60, "game " .. g .. " census")
    endings[d.finished.reason] = (endings[d.finished.reason] or 0) + 1
  end
end
local parts = {}
for k, v in pairs(endings) do parts[#parts + 1] = k .. "=" .. v end
table.sort(parts)
print("endings: " .. table.concat(parts, ", "))
print(("tcg session tests: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
