-- Deterministic RNG for duels (xorshift32 in plain arithmetic, so it runs
-- identically on LuaJIT/5.1 and 5.4).  A seed plus an action sequence
-- reproduces a whole duel, which is what the headless tests and future
-- link play both need.  Not the GB game's RNG: coin flips there come from
-- the frame counter and joypad timing, which are not reproducible anyway.

local Rng = {}
Rng.__index = Rng

local MOD = 4294967296

local function xor32(a, b)
  local result, bit = 0, 1
  while a > 0 or b > 0 do
    local ab, bb = a % 2, b % 2
    if ab ~= bb then result = result + bit end
    a, b, bit = (a - ab) / 2, (b - bb) / 2, bit * 2
  end
  return result
end

function Rng.new(seed)
  local s = (tonumber(seed) or 1) % MOD
  if s == 0 then s = 0x9E3779B9 end
  return setmetatable({ state = s, flips = 0 }, Rng)
end

function Rng:next()
  local x = self.state
  x = xor32(x, (x * 8192) % MOD)          -- x ^= x << 13
  x = xor32(x, math.floor(x / 131072))     -- x ^= x >> 17
  x = xor32(x, (x * 32) % MOD)             -- x ^= x << 5
  self.state = x
  return x
end

-- integer in [lo, hi]
function Rng:int(lo, hi)
  return lo + self:next() % (hi - lo + 1)
end

-- true = heads
function Rng:coin()
  self.flips = self.flips + 1
  return self:next() % 2 == 1
end

return Rng
