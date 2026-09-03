-- Sound-effect driver: every effect parses, ends, and the real ones are audible.
--   TCG_CACHE=<dir> lua tests/tcg_sfx_test.lua

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/audio.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local audio = dofile(cacheDir .. "/data/generated/audio.lua")
local bf = assert(io.open(cacheDir .. "/assets/generated/audio/music_banks.bin", "rb"))
local banks = bf:read("*a"); bf:close()
local SfxPlayer = require("src.tcg.audio.SfxPlayer")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. msg) end
end

check(audio.sfx ~= nil and audio.sfxWaves ~= nil, "sfx data extracted")

local played, audible, capped, frames = 0, 0, 0, 0
for i = 1, 95 do
  local entry = audio.sfx[i]
  if entry and entry.mask and entry.mask ~= 0 then
    local p = SfxPlayer.new(audio, banks)
    check(p:play(i), (entry.label or i) .. " starts")
    played = played + 1
    local out = p:render(22050)
    local peak, nan = 0, false
    for _, s in ipairs(out) do
      if s ~= s then nan = true end
      local a = math.abs(s)
      if a > peak then peak = a end
    end
    check(not nan, (entry.label or i) .. " has no NaN samples")
    check(peak <= 1, (entry.label or i) .. " stays in range")
    if peak > 0.01 then audible = audible + 1 end
    local q = SfxPlayer.new(audio, banks)
    q:play(i)
    local n = 0
    while q:isPlaying() and n < 400 do q:frame(); n = n + 1 end
    frames = frames + n
    if n >= SfxPlayer.MAX_FRAMES then capped = capped + 1 end
  end
end

check(played >= 90, "at least 90 effects have programs (" .. played .. ")")
check(audible >= 50, "at least 50 are audible (" .. audible .. ")")
check(capped <= 3, "almost none need the runaway cap (" .. capped .. ")")
check(frames / played < 120, ("effects are short, %.0f frames average"):format(frames / played))

-- the named UI effects specifically
for _, name in ipairs({ "SFX_CURSOR", "SFX_CONFIRM", "SFX_CANCEL", "SFX_COIN_TOSS", "SFX_BIG_HIT" }) do
  local index
  for i, e in pairs(audio.sfx) do if e.constant == name then index = tonumber(i) end end
  check(index ~= nil, name .. " is present")
  if index then
    local p = SfxPlayer.new(audio, banks)
    p:play(index)
    local out = p:render(11025)
    local peak = 0
    for _, s in ipairs(out) do peak = math.max(peak, math.abs(s)) end
    check(peak > 0.01, name .. " is audible (peak " .. string.format("%.3f", peak) .. ")")
  end
end

-- determinism and the silent path
do
  local a = SfxPlayer.new(audio, banks); a:play(11)
  local b = SfxPlayer.new(audio, banks); b:play(11)
  local sa, sb = a:render(2048), b:render(2048)
  local same = true
  for i = 1, #sa do if sa[i] ~= sb[i] then same = false break end end
  check(same, "rendering is deterministic")
  local p = SfxPlayer.new(audio, banks)
  check(p:play(0) == false, "Sfx_Stop is not playable")
  local silent = true
  for _, s in ipairs(p:render(64)) do if s ~= 0 then silent = false end end
  check(silent, "nothing playing renders silence")
end

print(("tcg sfx tests: %d passed, %d failed (%d audible of %d)"):format(passed, failed, audible, played))
if failed > 0 then os.exit(1) end
