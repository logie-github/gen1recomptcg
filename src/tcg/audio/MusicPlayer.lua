-- Pokemon TCG music driver (docs/tcg-phase1.md, Phase 8).
--
-- poketcg has its own sound engine (audio/music1.asm), unrelated to the
-- pokered format src/core/ChipAudio.lua streams, so it needs its own
-- interpreter.  This file is that interpreter plus a small PCM renderer:
--
--   MusicPlayer.new(audioData, banks)   audio = data/generated/audio.lua,
--                                       banks = music_banks.bin contents
--   player:play(songIndex)              start a song
--   player:frame()                      advance one driver frame (~60.24 Hz)
--   player:render(sampleCount)          mix `sampleCount` stereo samples,
--                                       calling frame() as time passes
--
-- Command set (Music1_PlayNextNote and Music1_CommandTable):
--   $00-$cf  note: high nybble = pitch (0 = rest), low nybble = length-1;
--            duration = (length) * speed frames, gated by `cutoff`
--   $d0 nn   speed          $d1-$d6  octave        $d7/$d8 inc/dec octave
--   $d9      tie            $da/$db  end           $dc nn  stereo panning
--   $dd      main loop start        $de  main loop end
--   $df nn   loop start (count)     $e0  loop end
--   $e1 ww   jump           $e2 ww   call          $e3  return
--   $e4 nn   frequency offset       $e5 nn  duty   $e6 nn  volume envelope
--   $e7 nn   wave instrument        $e8 nn  cutoff $e9 nn  echo (release env)
--   $ea nn   vibrato type   $eb nn   vibrato delay
--   $ec nn   pitch offset   $ed nn   adjust pitch offset      $ff  end
--
-- The renderer is an approximation of the DMG APU, not a cycle-accurate
-- emulation: square channels use duty + a linear volume envelope, the wave
-- channel plays the 32-nybble instrument at the programmed frequency with
-- the level shift, and the noise channel steps a 15/7-bit LFSR from the
-- noise instrument's register script.  Frequency sweeps, the length counter
-- and the analog high-pass are not modelled.

local MusicPlayer = {}
MusicPlayer.__index = MusicPlayer

local SAMPLE_RATE = 44100
local FRAME_RATE = 60.24
local BANK_SIZE = 0x4000
local DUTY_RATIO = { [0] = 0.125, 0.25, 0.5, 0.75 }

-- ---------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------

function MusicPlayer.new(audio, bankBytes, opts)
  opts = opts or {}
  assert(audio and audio.available, "no audio data in the cache")
  local self = setmetatable({
    audio = audio,
    banks = bankBytes,
    rate = opts.sampleRate or SAMPLE_RATE,
    frameRate = audio.frameRate or FRAME_RATE,
    volume = opts.volume or 0.22,
    channels = {},
    playing = false,
    song = nil,
    samplesIntoFrame = 0,
    frames = 0,
  }, MusicPlayer)
  self.samplesPerFrame = self.rate / self.frameRate
  self.tables = audio.engines and audio.engines[1] or audio
  return self
end

function MusicPlayer:byte(bank, address)
  local slot = self.audio.bankIndex[bank] or self.audio.bankIndex[tostring(bank)]
  if not slot then return 0xff end
  local index = slot * BANK_SIZE + (address - 0x4000)
  return self.banks:byte(index + 1) or 0xff
end

function MusicPlayer:word(bank, address)
  return self:byte(bank, address) + self:byte(bank, address + 1) * 0x100
end

-- ---------------------------------------------------------------------
-- channel state
-- ---------------------------------------------------------------------

local function newChannel(index)
  return {
    index = index,
    active = false,
    pc = 0, bank = 0,
    wait = 0,            -- frames until the next command (wddbb)
    gate = 0,            -- frames until release (wddc3)
    speed = 1,
    octave = 0,
    tie = false,
    cutoff = 8,
    echo = index >= 3 and 0x40 or 0x08,
    volumeByte = 0xf0,
    dutyByte = 0x80,
    frequencyOffset = 0,
    pitchOffset = 0,
    vibratoType = 0, vibratoDelay = 0, vibratoStep = 0, vibratoWait = 0,
    stack = {},
    mainLoop = 0,
    pitch = 0,           -- 11-bit GB frequency
    playingNote = false,
    -- renderer
    phase = 0,
    envVolume = 0, envDirection = 0, envPeriod = 0, envTimer = 0,
    wave = 0, waveIndex = 0,
    lfsr = 0x7fff, noiseTimer = 0, noiseScript = nil, noiseStep = 0,
    noiseDivisor = 8, noiseShift = 4, noiseWidth = 15,
  }
end

function MusicPlayer:stop()
  self.playing = false
  self.song = nil
  for i = 1, 4 do self.channels[i] = newChannel(i) end
end

function MusicPlayer:play(index)
  local song = self.audio.songs[index] or self.audio.songs[tostring(index)]
  self:stop()
  if not song or not song.mask or song.mask == 0 then return false end
  self.song = song
  for ch = 1, 4 do
    local address = song.channels[ch] or song.channels[tostring(ch)]
    if address then
      local c = newChannel(ch)
      c.active = true
      c.bank = song.bank
      c.pc = address
      c.mainLoop = address
      c.wait = 1
      self.channels[ch] = c
    end
  end
  self.tables = (self.audio.engines and self.audio.engines[song.engine or 1]) or self.audio
  self.playing = true
  self.frames = 0
  return true
end

function MusicPlayer:isPlaying()
  if not self.playing then return false end
  for i = 1, 4 do if self.channels[i].active then return true end end
  return false
end

-- ---------------------------------------------------------------------
-- interpreter
-- ---------------------------------------------------------------------

local function signedOffset(value)
  -- frequency/pitch offsets are sign-magnitude with bit 7 as the sign
  if value >= 0x80 then return -(value - 0x80) end
  return value
end

function MusicPlayer:pitchFor(c, note)
  local audio = self.tables
  local offsets = audio.octaveOffsets
  local octave = math.max(0, math.min(7, c.octave))
  local base = offsets[octave] or offsets[tostring(octave)] or 0
  local index = base + (note - 1) * 2 + c.pitchOffset * 2
  local wordIndex = math.floor(index / 2)
  local pitches = audio.pitches
  local value = pitches[wordIndex] or pitches[tostring(wordIndex)]
  if not value then return nil end
  value = value + signedOffset(c.frequencyOffset)
  return math.max(0, math.min(0x7ff, value % 0x800))
end

-- Start a note on `c`; note = 0 means a rest.
function MusicPlayer:startNote(c, note, lengthNybble)
  local length = lengthNybble + 1
  local duration = length * c.speed
  c.wait = duration
  if c.cutoff ~= 8 then
    c.gate = math.floor(duration * c.cutoff / 8)
  else
    c.gate = duration
  end
  if note == 0 then
    c.playingNote = false
    c.tie = false
    return
  end
  if c.index == 4 then
    local list = self.tables.noise
    local instrument = list[note] or list[tostring(note)]
    c.noiseScript = instrument
    c.noiseStep = 1
    if instrument and instrument[1] then
      -- NR41..NR44 seed: bytes 1..4 are length, envelope, poly, control
      local env = instrument[2] or 0xf0
      local poly = instrument[3] or 0x00
      c.envVolume = math.floor(env / 16)
      c.envDirection = (math.floor(env / 8) % 2 == 1) and 1 or -1
      c.envPeriod = env % 8
      c.envTimer = c.envPeriod
      c.noiseShift = math.floor(poly / 16)
      c.noiseWidth = (math.floor(poly / 8) % 2 == 1) and 7 or 15
      c.noiseDivisor = poly % 8
      c.lfsr = 0x7fff
    end
    c.playingNote = true
    c.tie = false
    return
  end
  local pitch = self:pitchFor(c, note)
  if pitch then c.pitch = pitch end
  if not c.tie then
    -- retrigger: reload the envelope from the programmed value
    local env = c.volumeByte
    c.envVolume = math.floor(env / 16)
    c.envDirection = (math.floor(env / 8) % 2 == 1) and 1 or -1
    c.envPeriod = env % 8
    c.envTimer = c.envPeriod
    c.phase = 0
    c.waveIndex = 0
  end
  c.tie = false
  c.playingNote = true
  c.vibratoStep = 0
  c.vibratoWait = 0
end

-- Run commands until the channel has a wait; returns false when it ended.
function MusicPlayer:step(c)
  local guard = 0
  while c.active do
    guard = guard + 1
    if guard > 4096 then c.active = false; return false end
    local op = self:byte(c.bank, c.pc)
    c.pc = c.pc + 1
    if op < 0xd0 then
      self:startNote(c, math.floor(op / 16), op % 16)
      return true
    elseif op == 0xd0 then
      c.speed = self:byte(c.bank, c.pc); c.pc = c.pc + 1
    elseif op >= 0xd1 and op <= 0xd6 then
      local octave = (op % 8) - 1
      if c.index == 3 then octave = octave + 1 end   -- Music1_octave's ch3 case
      c.octave = octave
    elseif op == 0xd7 then c.octave = c.octave + 1
    elseif op == 0xd8 then c.octave = c.octave - 1
    elseif op == 0xd9 then c.tie = true
    elseif op == 0xda or op == 0xdb or op == 0xff then
      c.active = false
      c.playingNote = false
      return false
    elseif op == 0xdc then
      c.panning = self:byte(c.bank, c.pc); c.pc = c.pc + 1
    elseif op == 0xdd then
      c.mainLoop = c.pc - 1
    elseif op == 0xde then
      c.pc = c.mainLoop + 1
    elseif op == 0xdf then
      local count = self:byte(c.bank, c.pc); c.pc = c.pc + 1
      c.stack[#c.stack + 1] = { pc = c.pc, count = count }
    elseif op == 0xe0 then
      local top = c.stack[#c.stack]
      if top then
        top.count = top.count - 1
        if top.count > 0 then c.pc = top.pc else table.remove(c.stack) end
      end
    elseif op == 0xe1 then
      c.pc = self:word(c.bank, c.pc)
    elseif op == 0xe2 then
      local target = self:word(c.bank, c.pc)
      c.stack[#c.stack + 1] = { pc = c.pc + 2, call = true }
      c.pc = target
    elseif op == 0xe3 then
      for i = #c.stack, 1, -1 do
        if c.stack[i].call then c.pc = c.stack[i].pc; table.remove(c.stack, i); break end
      end
    elseif op == 0xe4 then c.frequencyOffset = self:byte(c.bank, c.pc); c.pc = c.pc + 1
    elseif op == 0xe5 then c.dutyByte = self:byte(c.bank, c.pc); c.pc = c.pc + 1
    elseif op == 0xe6 then c.volumeByte = self:byte(c.bank, c.pc); c.pc = c.pc + 1
    elseif op == 0xe7 then c.wave = self:byte(c.bank, c.pc); c.pc = c.pc + 1
    elseif op == 0xe8 then c.cutoff = self:byte(c.bank, c.pc); c.pc = c.pc + 1
    elseif op == 0xe9 then c.echo = self:byte(c.bank, c.pc); c.pc = c.pc + 1
    elseif op == 0xea then c.vibratoType = self:byte(c.bank, c.pc); c.pc = c.pc + 1
    elseif op == 0xeb then c.vibratoDelay = self:byte(c.bank, c.pc); c.pc = c.pc + 1
    elseif op == 0xec then c.pitchOffset = self:byte(c.bank, c.pc); c.pc = c.pc + 1
    elseif op == 0xed then
      c.pitchOffset = (c.pitchOffset + self:byte(c.bank, c.pc)) % 256; c.pc = c.pc + 1
    else
      -- $ee-$fe are Music1_end entries in the command table
      c.active = false
      c.playingNote = false
      return false
    end
  end
  return false
end

-- Vibrato: after `delay` frames, walk the type's delta list, wrapping at $80.
function MusicPlayer:vibrato(c)
  if c.vibratoDelay == 0 or not c.playingNote then return 0 end
  if c.vibratoWait < c.vibratoDelay then
    c.vibratoWait = c.vibratoWait + 1
    return 0
  end
  local list = self.tables.vibrato[c.vibratoType] or self.tables.vibrato[tostring(c.vibratoType)]
  if not list then return 0 end
  local value = list[c.vibratoStep + 1]
  if value == nil or value == 0x80 then
    c.vibratoStep = 0
    value = list[1]
  end
  c.vibratoStep = c.vibratoStep + 1
  if value == nil or value == 0x80 then return 0 end
  if value >= 0x80 then return -(256 - value) end
  return value
end

-- One driver frame.
function MusicPlayer:frame()
  if not self.playing then return end
  self.frames = self.frames + 1
  for i = 1, 4 do
    local c = self.channels[i]
    if c.active then
      c.wait = c.wait - 1
      if c.wait <= 0 then
        self:step(c)
      elseif c.gate > 0 then
        c.gate = c.gate - 1
        if c.gate == 0 then
          -- release: the echo byte is written to the envelope register
          c.envVolume = math.floor((c.echo or 0) / 16)
          c.envDirection = -1
          c.envPeriod = 0
        end
      end
      c.vibratoDelta = self:vibrato(c)
      -- 64 Hz envelope, stepped once per driver frame (close enough at 60 Hz)
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

-- ---------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------

local function squareSample(c, dt)
  if not c.playingNote or c.envVolume == 0 then return 0 end
  local pitch = math.max(0, math.min(0x7ff, c.pitch + (c.vibratoDelta or 0)))
  local hz = 131072 / math.max(1, 2048 - pitch)
  c.phase = (c.phase + hz * dt) % 1
  local duty = DUTY_RATIO[math.floor((c.dutyByte or 0x80) / 64) % 4] or 0.5
  local level = (c.phase < duty) and 1 or -1
  return level * (c.envVolume / 15)
end

function MusicPlayer:waveSample(c, dt)
  if not c.playingNote then return 0 end
  local level = math.floor((c.volumeByte or 0x20) / 32) % 4     -- AUD3LEVEL bits 6-5
  if level == 0 then return 0 end
  local scale = ({ 1, 0.5, 0.25 })[level] or 1
  local pitch = math.max(0, math.min(0x7ff, c.pitch + (c.vibratoDelta or 0)))
  local hz = 65536 / math.max(1, 2048 - pitch)
  c.phase = (c.phase + hz * dt) % 1
  local table_ = self.tables.waves[c.wave] or self.tables.waves[tostring(c.wave)]
  if not table_ then return 0 end
  local n = #table_
  local sample = table_[math.floor(c.phase * n) + 1] or 0
  return ((sample / 7.5) - 1) * scale
end

local function noiseSample(c, dt)
  if not c.playingNote or c.envVolume == 0 then return 0 end
  local divisor = (c.noiseDivisor == 0) and 8 or (c.noiseDivisor * 16)
  local hz = 524288 / divisor / (2 ^ (c.noiseShift + 1))
  c.noiseTimer = c.noiseTimer + hz * dt
  while c.noiseTimer >= 1 do
    c.noiseTimer = c.noiseTimer - 1
    local bit0 = c.lfsr % 2
    local bit1 = math.floor(c.lfsr / 2) % 2
    local xor = (bit0 ~= bit1) and 1 or 0
    c.lfsr = math.floor(c.lfsr / 2) + xor * 0x4000
    if c.noiseWidth == 7 then
      c.lfsr = c.lfsr - (math.floor(c.lfsr / 64) % 2) * 64 + xor * 64
    end
  end
  local level = (c.lfsr % 2 == 0) and 1 or -1
  return level * (c.envVolume / 15) * 0.6
end

-- Mix `count` stereo frames into a flat { l, r, l, r, ... } table.
function MusicPlayer:render(count, out)
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
      local s = 0
      if c and c.active then
        if ch == 1 or ch == 2 then s = squareSample(c, dt)
        elseif ch == 3 then s = self:waveSample(c, dt)
        else s = noiseSample(c, dt) end
      end
      -- stereo_panning: high nybble = left, low nybble = right per channel
      local pan = c and c.panning
      local l, r = 1, 1
      if pan then
        l = (math.floor(pan / 16) % 2 == 1) and 1 or 0
        r = (pan % 2 == 1) and 1 or 0
        if l == 0 and r == 0 then l, r = 1, 1 end
      end
      left = left + s * l
      right = right + s * r
    end
    out[i] = math.max(-1, math.min(1, left * self.volume)); i = i + 1
    out[i] = math.max(-1, math.min(1, right * self.volume)); i = i + 1
  end
  return out
end

MusicPlayer.SAMPLE_RATE = SAMPLE_RATE

return MusicPlayer
