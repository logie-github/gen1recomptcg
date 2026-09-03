-- LÖVE playback for MusicPlayer (Phase 8): a queueable source fed from the
-- driver on the main thread.  Kept deliberately small -- Gen 1's ChipAudio
-- moves synthesis to a worker thread, which this can adopt later if the
-- per-frame cost shows up in a profile; the TCG driver renders roughly a
-- tenth of the samples ChipAudio does per second because it has no
-- per-instrument PCM.

local MusicPlayer = require("src.tcg.audio.MusicPlayer")

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
  if not self.player:isPlaying() then return end
  local free = self.source:getFreeBufferCount()
  for _ = 1, free do
    local out = self.player:render(BUFFER_SAMPLES, self.scratch)
    for i = 0, BUFFER_SAMPLES - 1 do
      self.soundData:setSample(i, 1, out[i * 2 + 1] or 0)
      self.soundData:setSample(i, 2, out[i * 2 + 2] or 0)
    end
    self.source:queue(self.soundData)
  end
  if not self.source:isPlaying() then pcall(self.source.play, self.source) end
end

return MusicSource
