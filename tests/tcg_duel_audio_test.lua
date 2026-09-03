-- Duel events, their sounds, and attack animations.
package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/cards.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local cards = dofile(cacheDir .. "/data/generated/cards.lua")
local decks = dofile(cacheDir .. "/data/generated/decks.lua")
local audio = dofile(cacheDir .. "/data/generated/audio.lua")
local Duel = require("src.tcg.Duel")
local SimpleAI = require("src.tcg.SimpleAI")
local DuelAudio = require("src.tcg.DuelAudio")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. msg) end
end

-- every sound the mapping names exists in the ROM's sfx table
do
  for event, constant in pairs(DuelAudio.SOUNDS) do
    local found = false
    for _, entry in pairs(audio.sfx) do
      if entry.constant == constant and entry.mask and entry.mask ~= 0 then found = true end
    end
    check(found, ("%s -> %s exists and is playable"):format(event, constant))
  end
end

-- every attack carries an animation name
do
  local total, named = 0, 0
  for id = 1, cards.count do
    local card = cards.byId[id]
    if card and card.kind == "pokemon" then
      for _, atk in ipairs(card.attacks) do
        total = total + 1
        if atk.animationName then named = named + 1 end
      end
    end
  end
  check(named == total, ("%d of %d attacks name an animation"):format(named, total))
end

-- a played duel emits the events, and the handler turns them into sounds
do
  local function expand(deck)
    local out = {}
    for _, e in ipairs(deck.cards) do for _ = 1, e.count do out[#out + 1] = e.card end end
    return out
  end
  local played, animations = {}, 0
  local duel = Duel.new(cards, { decks = { expand(decks[3]), expand(decks[2]) },
    seed = 11, prizes = 4 })
  duel.onEvent = DuelAudio.handler({
    sfx = audio.sfx,
    playSfx = function(name) played[name] = (played[name] or 0) + 1 end,
    onAnimation = function(info)
      animations = animations + 1
      check(info.name and info.name ~= "ATK_ANIM_NONE", "an animation is named")
      check(info.label and not info.label:find("ATK_ANIM"), "the label is readable")
      check((info.frames or 0) > 0, "it has a duration")
    end,
  })
  SimpleAI.playout(duel)

  local kinds = 0
  for _ in pairs(played) do kinds = kinds + 1 end
  check(kinds >= 3, kinds .. " distinct sounds played over a duel")
  check((played.SFX_SINGLE_HIT or 0) + (played.SFX_BIG_HIT or 0) > 0, "hits made a sound")
  check((played.SFX_CARD_SHUFFLE or 0) > 0, "shuffling made a sound")
  check(animations > 0, animations .. " attack animations reported")
end

-- headless duels stay silent: with no handler attached, emitting is a no-op
do
  local function expand(deck)
    local out = {}
    for _, e in ipairs(deck.cards) do for _ = 1, e.count do out[#out + 1] = e.card end end
    return out
  end
  local duel = Duel.new(cards, { decks = { expand(decks[3]), expand(decks[2]) }, seed = 3 })
  local ok = pcall(function() duel:emit("attack", {}) end)
  check(ok, "emitting with no handler is harmless")
  check(duel.onEvent == nil, "headless duels have no event handler")
end

print(("tcg duel audio tests: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
