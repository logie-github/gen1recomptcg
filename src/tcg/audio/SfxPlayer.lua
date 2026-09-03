-- Sound-effect driver (docs/tcg-phase1.md, Phase 9), ported from
-- poketcg audio/sfx.asm.  A separate command set from the music engine:
-- each command byte's high nybble selects the opcode and its low nybble is
-- the first argument.
--
--   $0x ll   frequency: 11-bit value, high 3 bits from x, low byte ll;
--            also yields one frame, so a run of them is a pitch sweep
--   $1x nn   volume envelope (NRx2 value)
--   $2x      duty: x << 2 becomes the NRx1 duty bits
--   $3x nn   loop start, nn iterations      $4x  loop end
--   $5x nn   pitch offset, applied every wait frame (signed, sign-magnitude)
--   $6x nn   wait nn frames
--   $7x      wave instrument x (channel 3)
--   $8x nn   stereo panning
--   $fx      end
--
-- Channels run independently from the same header (a mask plus one command
-- pointer per active channel) and are mixed by the same renderer the music
-- driver uses, so a sound effect and a song can be summed by the caller.

local SfxPlayer = {}
SfxPlayer.__index = SfxPlayer

local DUTY_RATIO = { [0] = 0.125, 0.25, 0.5, 0.75 }
local BANK_SIZE = 0x4000

function SfxPlayer.new(audio, bankBytes, opts)
  opts = opts or {}
  assert(audio and audio.sfx, "no sfx data in the cache")
  local self = setmetatable({
    audio = audio,
    banks = bankBytes,
    rate = opts.sampleRate or 44100,
    frameRate = audio.frameRate or 60.24,
    volume = opts.volume or 0.25,
    channels = {},
    playing = false,
    samplesIntoFrame = 0,
  }, SfxPlayer)
  self.samplesPerFrame = self.rate / self.frameRate
  self:stop()
  return self
end

function SfxPlayer:byte(bank, address)
  local slot = self.audio.bankIndex[bank] or self.audio.bankIndex[tostring(bank)]
  if not slot then return 0xf0 end
  return self.banks:byte(slot * BANK_SIZE + (address - 0x4000) + 1) or 0xf0
end

local function newChannel(index)
  return {
    index = index, active = false, pc = 0, bank = 0,
    wait = 0, pitch = 0, pitchOffset = 0, dutyByte = 0x80,
    envVolume = 0, envDirection = -1, envPeriod = 0, envTimer = 0,
    -- SFX_end stops the driver, not the APU: the channel keeps sounding
    -- until its hardware envelope decays, which is what gives the short
    -- effects (cursor blips, hits) their tail
    ringing = false,
    wave = 0, phase = 0, panning = nil,
    loopStack = {},
    lfsr = 0x7fff, noiseTimer = 0, noiseShift = 4, noiseDivisor = 0, noiseWidth = 15,
  }
end

function SfxPlayer:stop()
  self.playing = false
  for i = 1, 4 do self.channels[i] = newChannel(i) end
end

function SfxPlayer:play(index)
  local entry = self.audio.sfx[index] or self.audio.sfx[tostring(index)]
  self:stop()
  if not entry or not entry.mask or entry.mask == 0 then return false end
  for ch = 1, 4 do
    local address = entry.channels[ch] or entry.channels[tostring(ch)]
    if address and address >= 0x4000 and address < 0x8000 then
      local c = newChannel(ch)
      c.active, c.bank, c.pc, c.wait = true, entry.bank, address, 1
      self.channels[ch] = c
    end
  end
  self.playing = true
  self.frames = 0
  return true
end

function SfxPlayer:isPlaying()
  if not self.playing then return false end
  for i = 1, 4 do
    local c = self.channels[i]
    if c.active or (c.ringing and c.envVolume > 0) then return true end
  end
  return false
end

function SfxPlayer:sounding(c)
  return c.active or (c.ringing and c.envVolume > 0)
end

local function signed(value)
  if value >= 0x80 then return -(value - 0x80) end
  return value
end

-- Run commands until the channel waits; false when it has ended.
function SfxPlayer:step(c)
  local guard = 0
  while c.active do
    guard = guard + 1
    if guard > 1024 then c.active = false; return false end
    local op = self:byte(c.bank, c.pc)
    c.pc = c.pc + 1
    local kind = math.floor(op / 16)
    local arg = op % 16
    if kind == 0x0 then
      local low = self:byte(c.bank, c.pc); c.pc = c.pc + 1
      c.pitch = arg * 256 + low
      if c.index == 4 then
        c.noiseShift = math.floor(low / 16)
        c.noiseWidth = (math.floor(low / 8) % 2 == 1) and 7 or 15
        c.noiseDivisor = low % 8
        c.lfsr = 0x7fff
      end
      -- SFX_frequency ends at Func_fc105 (store pointer, ret) rather than
      -- falling through to ExecuteNextSFXCommand, so it yields a frame the
      -- way an explicit wait does; this is what paces the pitch sweeps.
      c.wait = 1
      return true
    elseif kind == 0x1 then
      local env = self:byte(c.bank, c.pc); c.pc = c.pc + 1
      c.envVolume = math.floor(env / 16)
      c.envDirection = (math.floor(env / 8) % 2 == 1) and 1 or -1
      c.envPeriod = env % 8
      c.envTimer = c.envPeriod
      c.phase = 0
    elseif kind == 0x2 then
      c.dutyByte = (arg % 4) * 64
    elseif kind == 0x3 then
      local count = self:byte(c.bank, c.pc); c.pc = c.pc + 1
      c.loopStack[#c.loopStack + 1] = { pc = c.pc, count = count }
    elseif kind == 0x4 then
      local top = c.loopStack[#c.loopStack]
      if top then
        top.count = top.count - 1
        if top.count > 0 then c.pc = top.pc else table.remove(c.loopStack) end
      end
    elseif kind == 0x5 then
      c.pitchOffset = self:byte(c.bank, c.pc); c.pc = c.pc + 1
    elseif kind == 0x6 then
      c.wait = self:byte(c.bank, c.pc); c.pc = c.pc + 1
      if c.wait <= 0 then c.wait = 1 end
      return true
    elseif kind == 0x7 then
      c.wave = arg
    elseif kind == 0x8 then
      c.panning = self:byte(c.bank, c.pc); c.pc = c.pc + 1
    elseif kind == 0xf then
      c.active = false
      c.ringing = true
      -- a channel left with a flat envelope would ring forever; give it the
      -- decay the hardware register implies
      -- a rising or flat envelope would ring forever once the driver stops
      -- writing the register, so the tail always decays
      if c.envPeriod == 0 or c.envDirection > 0 then c.envPeriod, c.envDirection = 2, -1 end
      return false
    end
    -- $9-$e are SFX_unused: fall through and read the next command
  end
  return false
end

-- Safety net for effects whose programs loop indefinitely (several are meant
-- to be cut off by the next sound); five seconds is well past any real one.
SfxPlayer.MAX_FRAMES = 300

function SfxPlayer:frame()
  if not self.playing then return end
  self.frames = (self.frames or 0) + 1
  if self.frames > SfxPlayer.MAX_FRAMES then self:stop(); return end
  for i = 1, 4 do
    local c = self.channels[i]
    if self:sounding(c) then
      if c.active then
      c.wait = c.wait - 1
      if c.wait <= 0 then
        self:step(c)
      else
        -- SFX_ApplyPitchOffset runs on every waiting frame
        if c.pitchOffset ~= 0 then
          c.pitch = (c.pitch + signed(c.pitchOffset)) % 0x800
        end
      end
      end
      if c.envPeriod > 0 then
        c.envTimer = c.envTimer - 1
        if c.envTimer <= 0 then
          c.envTimer = c.envPeriod
          c.envVolume = math.max(0, math.min(15, c.envVolume + c.envDirection))
        end
      end
    end
  end
  if not self:isPlaying() then self.playing = false end
end

function SfxPlayer:sample(c, dt)
  if c.envVolume == 0 and c.index ~= 3 then return 0 end
  if c.index == 4 then
    local divisor = (c.noiseDivisor == 0) and 8 or (c.noiseDivisor * 16)
    local hz = 524288 / divisor / (2 ^ (c.noiseShift + 1))
    c.noiseTimer = c.noiseTimer + hz * dt
    while c.noiseTimer >= 1 do
      c.noiseTimer = c.noiseTimer - 1
      local bit0, bit1 = c.lfsr % 2, math.floor(c.lfsr / 2) % 2
      local xor = (bit0 ~= bit1) and 1 or 0
      c.lfsr = math.floor(c.lfsr / 2) + xor * 0x4000
    end
    return ((c.lfsr % 2 == 0) and 1 or -1) * (c.envVolume / 15) * 0.6
  end
  local hz = 131072 / math.max(1, 2048 - (c.pitch % 0x800))
  if c.index == 3 then
    hz = hz / 2
    local waves = self.audio.sfxWaves or {}
    local table_ = waves[c.wave] or waves[tostring(c.wave)]
    if not table_ then return 0 end
    c.phase = (c.phase + hz * dt) % 1
    local sample = table_[math.floor(c.phase * #table_) + 1] or 0
    return (sample / 7.5) - 1
  end
  c.phase = (c.phase + hz * dt) % 1
  local duty = DUTY_RATIO[math.floor(c.dutyByte / 64) % 4] or 0.5
  return ((c.phase < duty) and 1 or -1) * (c.envVolume / 15)
end

-- Mix `count` stereo frames, advancing the driver as time passes.
function SfxPlayer:render(count, out)
  out = out or {}
  local dt = 1 / self.rate
  local i = 1
  for _ = 1, count do
    if self.playing then
      self.samplesIntoFrame = self.samplesIntoFrame + 1
      if self.samplesIntoFrame >= self.samplesPerFrame then
        self.samplesIntoFrame = self.samplesIntoFrame - self.samplesPerFrame
        self:frame()
      end
    end
    local left, right = 0, 0
    for ch = 1, 4 do
      local c = self.channels[ch]
      if c and self:sounding(c) then
        local s = self:sample(c, dt)
        local l, r = 1, 1
        if c.panning then
          l = (math.floor(c.panning / 16) % 2 == 1) and 1 or 0
          r = (c.panning % 2 == 1) and 1 or 0
          if l == 0 and r == 0 then l, r = 1, 1 end
        end
        left, right = left + s * l, right + s * r
      end
    end
    out[i] = math.max(-1, math.min(1, left * self.volume)); i = i + 1
    out[i] = math.max(-1, math.min(1, right * self.volume)); i = i + 1
  end
  return out
end

return SfxPlayer
