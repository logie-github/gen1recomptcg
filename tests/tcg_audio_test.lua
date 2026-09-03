-- Music driver: every song parses, plays, and renders non-silent audio.
--   TCG_CACHE=<dir> lua tests/tcg_audio_test.lua

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/audio.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local audio = dofile(cacheDir .. "/data/generated/audio.lua")
local bf = assert(io.open(cacheDir .. "/assets/generated/audio/music_banks.bin", "rb"))
local banks = bf:read("*a"); bf:close()
local MusicPlayer = require("src.tcg.audio.MusicPlayer")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. msg) end
end

check(audio.available, "audio extracted")
check(#banks % audio.bankSize == 0, "bank blob is whole banks")

local playable = 0
for i = 0, audio.songCount - 1 do
  local song = audio.songs[i]
  if song and song.mask and song.mask ~= 0 then
    playable = playable + 1
    local p = MusicPlayer.new(audio, banks)
    check(p:play(i), song.label .. " starts")
    -- 20 seconds of driver frames: no crash, no runaway loop
    local ok, err = pcall(function()
      for _ = 1, 1200 do p:frame() end
    end)
    check(ok, song.label .. " ran 1200 frames: " .. tostring(err))
    -- render half a second and look for signal
    local p2 = MusicPlayer.new(audio, banks)
    p2:play(i)
    local out = p2:render(22050)
    local peak, energy = 0, 0
    for _, s in ipairs(out) do
      local a = math.abs(s)
      if a > peak then peak = a end
      energy = energy + a
      if s ~= s then peak = -1 end          -- NaN guard
    end
    check(peak > 0.01, song.label .. " renders audible output (peak " .. string.format("%.3f", peak) .. ")")
    check(peak <= 1, song.label .. " stays in range")
    check(energy / #out > 0.001, song.label .. " is not near-silent")
  end
end
check(playable >= 26, "at least 26 playable songs (" .. playable .. ")")
check(audio.engines and audio.engines[2], "both sound engines' tables extracted")

-- notes land in a musical range: sample the pitch registers a song programs
do
  local p = MusicPlayer.new(audio, banks)
  p:play(9)                                    -- Overworld (engine 2)
  local lo, hi, seen = math.huge, 0, 0
  for _ = 1, 600 do
    p:frame()
    for ch = 1, 2 do
      local c = p.channels[ch]
      if c and c.active and c.playingNote and c.pitch > 0 then
        local hz = 131072 / math.max(1, 2048 - c.pitch)
        lo, hi, seen = math.min(lo, hz), math.max(hi, hz), seen + 1
      end
    end
  end
  check(seen > 50, "the song programs notes (" .. seen .. " frames)")
  check(lo > 30 and hi < 8000, ("pitches are musical (%.0f-%.0f Hz)"):format(lo, hi))
end

-- looping songs keep playing; jingles end
do
  local p = MusicPlayer.new(audio, banks)
  p:play(2)                                    -- Duel Theme 1 has a main loop
  for _ = 1, 3600 do p:frame() end
  check(p:isPlaying(), "a looping song still plays after a minute")
end

-- determinism: same song, same samples
do
  local a = MusicPlayer.new(audio, banks); a:play(3)
  local b = MusicPlayer.new(audio, banks); b:play(3)
  local sa, sb = a:render(4410), b:render(4410)
  local same = true
  for i = 1, #sa do if sa[i] ~= sb[i] then same = false; break end end
  check(same, "rendering is deterministic")
end

-- an unknown/empty song index is a no-op, not an error
do
  local p = MusicPlayer.new(audio, banks)
  check(p:play(0) == false, "Music_Stop is not playable")
  check(p:play(99) == false, "out-of-range song refused")
  local out = p:render(64)
  local silent = true
  for _, s in ipairs(out) do if s ~= 0 then silent = false end end
  check(silent, "nothing playing renders silence")
end

print(("tcg audio tests: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
