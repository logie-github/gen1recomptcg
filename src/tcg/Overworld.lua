-- Overworld (docs/tcg-phase1.md, Phase 10).
--
-- Grid movement over the extracted maps, headless and driven by Game Boy
-- buttons the way DuelSession and HomeSession are, so the renderer
-- (src/tcg/ui/OverworldScreen.lua) only draws.
--
-- Rules taken from poketcg:
--   * coordinates are in tile units; permissions cover 2x2 tile blocks
--     (overworld.asm DecompressPermissionMap), so the blocking test reads
--     permissions[(y/2) * permissionWidth + (x/2)] and refuses the move when
--     bits $40 or $80 are set, or when a coordinate reaches $1f
--   * the player steps two tiles at a time -- one permission block -- which
--     is why every warp, NPC and object coordinate in the data is even
--   * standing on a warp tile moves you to its destination map and position
--   * A talks to an NPC or an interactable object on the tile you face
--     (data/map_objects.asm entries carry the direction you must face)
--
-- Talking to an NPC runs its decoded script through src/tcg/ScriptRunner.lua
-- when npc data is supplied, so dialogue branches on event flags and can ask
-- questions or start duels.
--
-- Not modelled yet: NPC movement scripts, the map script slots other than
-- the NPC and object lists, and the door animations.

local ScriptRunner = require("src.tcg.ScriptRunner")

local Overworld = {}
Overworld.__index = Overworld

Overworld.NORTH, Overworld.EAST, Overworld.SOUTH, Overworld.WEST = 0, 1, 2, 3
local STEP = 2                      -- one permission block
local BLOCKED = 0xc0                -- $40 | $80
local COORD_LIMIT = 0x1f

local DELTA = {
  [0] = { 0, -STEP }, { STEP, 0 }, { 0, STEP }, { -STEP, 0 },
}
local BUTTON_DIRECTION = { up = 0, right = 1, down = 2, left = 3 }

-- opts: { maps = data/generated/maps.lua, map = index, x = , y = , facing = }
function Overworld.new(opts)
  local data = assert(opts.maps, "maps data required")
  local self = setmetatable({
    data = data,
    map = nil,
    x = 0, y = 0,
    facing = Overworld.SOUTH,
    message = nil,          -- { text, name }
    log = {},
    onWarp = opts.onWarp,
    onTalk = opts.onTalk,
    onBoosters = opts.onBoosters,
    onDuel = opts.onDuel,
    npcData = opts.npcs,           -- data/generated/npcs.lua
    events = opts.events or {},
    -- With stepFrames > 0 a step slides over that many frames and the
    -- renderer reads `offset` to draw the mover partway between tiles.  The
    -- default is 0, so headless callers keep the instant, frame-free
    -- semantics the tests and the script runner rely on; the UI opts in.
    stepFrames = opts.stepFrames or 0,
    walking = nil,          -- { mover, fromX, fromY, frames, total, queue }
    collection = opts.collection,  -- so scripts can grant cards and medals
    eventByName = opts.eventByName or {},
    medalBits = opts.medalBits or {},
    multichoice = opts.multichoice or {},
    cardsByConstant = opts.cardsByConstant,
    boosterIds = opts.boosterIds,
    onSave = opts.onSave,
    medalEvents = opts.medalEvents,
    runner = nil,
    steps = 0,
  }, Overworld)
  self:enter(opts.map or 1, opts.x, opts.y, opts.facing)
  return self
end

function Overworld:say(fmt, ...)
  self.log[#self.log + 1] = fmt:format(...)
end

function Overworld:mapData(index)
  return self.data.maps[index] or self.data.maps[tostring(index)]
end

-- Move to `index`, defaulting to the first walkable tile when no position is
-- given (used for the initial spawn and for tests).
function Overworld:enter(index, x, y, facing)
  local map = self:mapData(index)
  if not map then return false, "no such map" end
  self.map = map
  self.mapIndex = index
  self.facing = facing or self.facing
  if x and y then
    self.x, self.y = x, y
  else
    self.x, self.y = self:firstWalkable()
  end
  self.message = nil
  self:say("entered %s at %d,%d", map.constant or index, self.x, self.y)
  return true
end

function Overworld:firstWalkable()
  local map = self.map
  for y = 0, (map.height or 2) - 1, STEP do
    for x = 0, (map.width or 2) - 1, STEP do
      if self:walkable(x, y) then return x, y end
    end
  end
  return 0, 0
end

function Overworld:permissionAt(x, y)
  local map = self.map
  if not map.permissions then return 0 end
  local px, py = math.floor(x / 2), math.floor(y / 2)
  if px < 0 or py < 0 or px >= map.permissionWidth or py >= map.permissionHeight then
    return BLOCKED
  end
  return map.permissions[py * map.permissionWidth + px + 1] or 0
end

function Overworld:walkable(x, y)
  local map = self.map
  if x < 0 or y < 0 then return false end
  if x >= COORD_LIMIT or y >= COORD_LIMIT then return false end
  if map.width and (x >= map.width or y >= map.height) then return false end
  if self:npcAt(x, y) then return false end
  -- overworld.asm: `and $40 | $80` -- either impassable flag blocks the step
  return math.floor(self:permissionAt(x, y) / 64) % 4 == 0
end

function Overworld:npcAt(x, y)
  for _, npc in ipairs(self.map.npcs or {}) do
    if npc.x == x and npc.y == y then return npc end
  end
  return nil
end

function Overworld:warpAt(x, y)
  for _, warp in ipairs(self.map.warps or {}) do
    if warp.x == x and warp.y == y then return warp end
  end
  return nil
end

function Overworld:objectAt(x, y, facing)
  for _, object in ipairs(self.map.objects or {}) do
    if object.x == x and object.y == y and object.direction == facing then return object end
  end
  return nil
end

function Overworld:facingTile()
  local d = DELTA[self.facing]
  return self.x + d[1], self.y + d[2]
end

-- Try to step in `direction`; the first press turns, a second moves, which is
-- how the GB game handles a direction press against a wall.
-- Advance any in-progress slide by one frame; returns true while one runs.
function Overworld:update()
  local walk = self.walking
  if not walk then return false end
  walk.frames = walk.frames + 1
  if walk.frames < walk.total then return true end
  -- the slide finished: land, then take the next queued step if there is one
  walk.mover.offset = nil
  self.walking = nil
  if walk.queue and #walk.queue > 0 then
    local nextDirection = table.remove(walk.queue, 1)
    self:beginSlide(walk.mover, nextDirection, walk.queue)
  end
  return self.walking ~= nil
end

-- Move `mover` one block in `direction`, sliding over stepFrames.
function Overworld:beginSlide(mover, direction, queue)
  local DELTAS = { [0] = { 0, -STEP }, { STEP, 0 }, { 0, STEP }, { -STEP, 0 } }
  local delta = DELTAS[direction]
  if not delta then return false end
  mover.direction = direction
  if mover == self then self.facing = direction end
  local nx, ny = mover.x + delta[1], mover.y + delta[2]
  local blocked
  if mover == self then
    blocked = not self:walkable(nx, ny)
  else
    blocked = nx < 0 or ny < 0
      or nx >= (self.map.width or 0) or ny >= (self.map.height or 0)
  end
  if blocked then return false end
  mover.x, mover.y = nx, ny
  mover.offset = { x = -delta[1], y = -delta[2] }
  self.walking = { mover = mover, frames = 0, total = self.stepFrames, queue = queue }
  return true
end

-- How far through its slide a mover is, as tiles of offset (0 when still).
function Overworld:offsetOf(mover)
  local walk = self.walking
  if not walk or walk.mover ~= mover or not mover.offset then return 0, 0 end
  local t = 1 - (walk.frames / walk.total)
  return mover.offset.x * t, mover.offset.y * t
end

function Overworld:step(direction)
  if self.message then return false end
  if self.walking then return false end
  if self.facing ~= direction then
    self.facing = direction
    -- the original turns and moves in the same press when the way is clear
  end
  local d = DELTA[direction]
  local nx, ny = self.x + d[1], self.y + d[2]
  if not self:walkable(nx, ny) then return false end
  if self.stepFrames > 0 then
    self:beginSlide(self, direction, nil)
  else
    self.x, self.y = nx, ny
  end
  self.steps = self.steps + 1
  local warp = self:warpAt(nx, ny)
  if warp then
    local destination = warp.map
    self:say("warp to map %d at %d,%d", destination, warp.destX, warp.destY)
    self:enter(destination, warp.destX, warp.destY, self.facing)
    if self.onWarp then self.onWarp(destination, warp) end
    return true, "warp"
  end
  return true
end

-- A: talk to whatever is on the tile being faced.
function Overworld:interact(yes)
  if self.message then
    -- an open message belongs to a running script: let it continue
    if self.runner and not self.runner.finished then
      local pending = self.runner:advance(yes ~= false)
      self.message = pending and {
        name = pending.name, text = pending.text, kind = pending.kind,
        duel = pending.duel, npc = self.message.npc, options = pending.options,
      } or nil
      if not self.message then self.runner = nil end
      return true
    end
    self.message = nil
    self.runner = nil
    return true
  end
  local fx, fy = self:facingTile()
  local npc = self:npcAt(fx, fy)
  if npc then
    self:say("talked to %s", npc.constant or "someone")
    if self.onTalk then self.onTalk(npc) end
    local entry = self.npcData and self.npcData.npcs
      and (self.npcData.npcs[npc.npc] or self.npcData.npcs[tostring(npc.npc)])
    if entry and entry.script then
      self.runner = ScriptRunner.new({
        script = entry.script, npc = entry, events = self.events,
        collection = self.collection, player = self,
        eventByName = self.eventByName, medalBits = self.medalBits,
        multichoice = self.multichoice, medalEvents = self.medalEvents,
        onDuel = self.onDuel, onBoosters = self.onBoosters,
        onMove = function(who, directions, entry) self:walkPath(who, directions, entry, npc) end,
        boosterIds = self.boosterIds,
      })
      local pending = self.runner:run()
      self.message = pending and {
        name = pending.name or entry.name, text = pending.text,
        kind = pending.kind, duel = pending.duel, npc = npc,
        options = pending.options,
      } or nil
      if not self.message then self.runner = nil end
      return true
    end
    self.message = { name = npc.constant, text = nil, npc = npc }
    return true
  end
  -- objects list the direction the player must be facing to use them
  local object = self:objectAt(fx, fy, self.facing) or self:objectAt(self.x, self.y, self.facing)
  if object and object.script then
    -- objects carry scripts too: the Hall of Honor's legendary-card scene
    -- and its ending hang off two of them
    self.runner = ScriptRunner.new({
      script = object.script, events = self.events, collection = self.collection,
      multichoice = self.multichoice, eventByName = self.eventByName,
      medalEvents = self.medalEvents, cardsByConstant = self.cardsByConstant,
      onSave = self.onSave,
    })
    local pending = self.runner:run()
    -- many object routines only print the object's own text through the
    -- engine's default handler, so a script that yields nothing falls back
    -- to that text rather than to silence
    if pending then
      self.message = { name = object.name, text = pending.text or object.text,
        kind = pending.kind, options = pending.options, object = object }
    else
      self.runner = nil
      self.message = { name = object.name, text = object.text, object = object }
    end
    self:say("used %s", object.name or "something")
    return true
  end
  if object then
    self.message = { name = object.name, text = object.text, object = object }
    self:say("read %s", object.name or "something")
    return true
  end
  return false
end

-- Apply a scripted movement path.  `who` is "player", "active" (the NPC being
-- talked to) or an NPC id.  Steps that would land on a blocked tile stop the
-- walk, the way the original's collision does.
function Overworld:walkPath(who, directions, entry, talking)
  local DELTAS = { [0] = { 0, -STEP }, { STEP, 0 }, { 0, STEP }, { -STEP, 0 } }
  local mover
  if who == "player" then
    mover = self
  else
    local id = (who == "active") and (talking and talking.npc) or who
    for _, placed in ipairs(self.map.npcs or {}) do
      if placed.npc == id then mover = placed end
    end
    mover = mover or talking
  end
  if not mover then return end
  if self.stepFrames > 0 then
    local queue = {}
    for i = 2, #directions do queue[#queue + 1] = directions[i] end
    if directions[1] then self:beginSlide(mover, directions[1], queue) end
    self:say("%s walks %d step(s)", who == "player" and "the player" or "an NPC", #directions)
    return
  end
  for _, direction in ipairs(directions) do
    local delta = DELTAS[direction]
    if not delta then break end
    local nx, ny = mover.x + delta[1], mover.y + delta[2]
    mover.direction = direction
    if mover == self then
      self.facing = direction
      if not self:walkable(nx, ny) then break end
    elseif nx < 0 or ny < 0 or nx >= (self.map.width or 0) or ny >= (self.map.height or 0) then
      break
    end
    mover.x, mover.y = nx, ny
  end
  self:say("%s walked %d step(s)", who == "player" and "the player" or "an NPC", #directions)
end

function Overworld:press(button)
  local direction = BUTTON_DIRECTION[button]
  if direction then return self:step(direction) end
  if button == "a" then return self:interact() end
  if button == "b" then
    -- B answers "no" to a question and otherwise closes the box
    if self.message and self.message.kind == "question" then return self:interact(false) end
    if self.message then self.message = nil; self.runner = nil; return true end
  end
  return false
end

-- Snapshot for renderers and tests.
function Overworld:view()
  local map = self.map
  return {
    map = self.mapIndex, name = map.constant, width = map.width, height = map.height,
    x = self.x, y = self.y, facing = self.facing,
    tiles = map.tiles, tileset = map.tileset,
    npcs = map.npcs, objects = map.objects, warps = map.warps,
    message = self.message, steps = self.steps,
  }
end

return Overworld
