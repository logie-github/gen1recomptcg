-- LÖVE playback for MusicPlayer (Phase 8): a queueable source fed from the
-- driver on the main thread.  Kept deliberately small -- Gen 1's ChipAudio
-- moves synthesis to a worker thread, which this can adopt later if the
-- per-frame cost shows up in a profile; the TCG driver renders roughly a
-- tenth of the samples ChipAudio does per second because it has no
-- per-instrument PCM.

local MusicPlayer = require("src.tcg.audio.MusicPlayer")
local SfxPlayer = require("src.tcg.audio.SfxPlayer")

local MusicSource = {}
MusicSource.__index = MusicSource

local BUFFER_SAMPLES = 2048
local BUFFER_COUNT = 8

-- audio: data/generated/audio.lua, banks: music_banks.bin bytes
function MusicSource.new(audio, banks, opts)
  opts = opts or {}
  local rate = opts.sampleRate or 44100
  local self = setmetatable({
    player = MusicPlayer.new(audio, banks, { sampleRate = rate, volume = opts.volume }),
    -- effects are mixed into the same buffers, so one queueable source
    -- carries both and they stay in sync
    sfx = audio.sfx and SfxPlayer.new(audio, banks, { sampleRate = rate }) or nil,
    sfxScratch = {},
    rate = rate,
    scratch = {},
    current = nil,
    muted = opts.muted or false,
  }, MusicSource)
  local ok, source = pcall(function()
    return love.audio.newQueueableSource(rate, 16, 2, BUFFER_COUNT)
  end)
  self.source = ok and source or nil
  self.soundData = ok and love.sound.newSoundData(BUFFER_SAMPLES, rate, 16, 2) or nil
  return self
end

function MusicSource:play(songIndex)
  if self.current == songIndex and self.player:isPlaying() then return end
  self.current = songIndex
  self.player:play(songIndex)
  if self.source and not self.muted then pcall(self.source.play, self.source) end
end

-- Play a sound effect by index or by its SFX_* constant.
function MusicSource:playSfx(id)
  if not self.sfx then return end
  local index = id
  if type(id) == "string" then
    for i, entry in pairs(self.player.audio.sfx) do
      if entry.constant == id then index = tonumber(i); break end
    end
  end
  if type(index) == "number" then self.sfx:play(index) end
end

function MusicSource:stop()
  self.current = nil
  self.player:stop()
  if self.source then pcall(self.source.stop, self.source) end
end

function MusicSource:setMuted(muted)
  self.muted = muted
  if self.source then
    if muted then pcall(self.source.stop, self.source)
    elseif self.current then pcall(self.source.play, self.source) end
  end
end

-- Call once per love.update: top the queue up.
function MusicSource:update()
  if not (self.source and self.soundData) or self.muted then return end
  local sfxPlaying = self.sfx and self.sfx:isPlaying()
  if not (self.player:isPlaying() or sfxPlaying) then return end
  local free = self.source:getFreeBufferCount()
  for _ = 1, free do
    local out = self.player:render(BUFFER_SAMPLES, self.scratch)
    local fx = self.sfx and self.sfx:isPlaying()
      and self.sfx:render(BUFFER_SAMPLES, self.sfxScratch) or nil
    for i = 0, BUFFER_SAMPLES - 1 do
      local l, r = out[i * 2 + 1] or 0, out[i * 2 + 2] or 0
      if fx then
        l = math.max(-1, math.min(1, l + (fx[i * 2 + 1] or 0)))
        r = math.max(-1, math.min(1, r + (fx[i * 2 + 2] or 0)))
      end
      self.soundData:setSample(i, 1, l)
      self.soundData:setSample(i, 2, r)
    end
    self.source:queue(self.soundData)
  end
  if not self.source:isPlaying() then pcall(self.source.play, self.source) end
end

return MusicSource
