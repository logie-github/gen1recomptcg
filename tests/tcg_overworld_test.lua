-- Overworld: extracted map data is coherent and the walking engine obeys
-- the permission map, warps and interactions.
--   TCG_CACHE=<dir> lua tests/tcg_overworld_test.lua

package.path = "./?.lua;" .. package.path
local cacheDir = os.getenv("TCG_CACHE") or "tcg-cache"
local f = io.open(cacheDir .. "/data/generated/maps.lua", "rb")
if not f then print("SKIP: no TCG cache at " .. cacheDir); os.exit(0) end
f:close()

local maps = dofile(cacheDir .. "/data/generated/maps.lua")
local Overworld = require("src.tcg.Overworld")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. msg) end
end

-- 1. extracted data
check(maps.available and maps.count == 34, "34 maps (NUM_MAPS)")
local withTiles, withPerms, warps, npcs, objects = 0, 0, 0, 0, 0
for i = 0, maps.count - 1 do
  local m = maps.maps[i]
  if m.tiles then
    withTiles = withTiles + 1
    check(#m.tiles == m.width * m.height,
      (m.constant or i) .. " tilemap decompresses to w*h (" .. #m.tiles .. ")")
  end
  if m.permissions then
    withPerms = withPerms + 1
    check(#m.permissions == m.permissionWidth * m.permissionHeight,
      (m.constant or i) .. " permission grid is half resolution")
  end
  warps = warps + #m.warps
  npcs = npcs + #m.npcs
  objects = objects + #m.objects
  for _, w in ipairs(m.warps) do
    check(maps.maps[w.map] ~= nil, (m.constant or i) .. " warp target exists")
    check(w.x % 2 == 0 and w.y % 2 == 0 and w.destX % 2 == 0 and w.destY % 2 == 0,
      (m.constant or i) .. " warp coordinates sit on block boundaries")
  end
end
check(withTiles >= 33, withTiles .. " maps have tiles")
check(withPerms >= 32, withPerms .. " maps have permissions")
check(warps >= 100 and npcs >= 50 and objects >= 50,
  ("%d warps, %d npcs, %d objects"):format(warps, npcs, objects))

-- Mason Laboratory specifics, checked against data/npc_map_data.asm
do
  local lab = maps.maps[1]
  check(lab.constant == "MASON_LABORATORY", "map 1 is the laboratory")
  check(lab.width == 28 and lab.height == 30, "laboratory is 28x30")
  local found
  for _, n in ipairs(lab.npcs) do if n.constant == "NPC_DRMASON" then found = n end end
  check(found and found.x == 0x0e and found.y == 0x06, "Dr Mason stands at 14,6")
  check(#lab.warps == 4, "the laboratory has four warps")
end

-- 2. movement
do
  local ow = Overworld.new({ maps = maps, map = 1 })
  check(ow.map.constant == "MASON_LABORATORY", "spawned in the laboratory")
  check(ow:walkable(ow.x, ow.y), "spawn tile is walkable")
  -- walls block
  local blockedTried, blockedRefused = 0, 0
  for y = 0, 28, 2 do
    for x = 0, 26, 2 do
      if not ow:walkable(x, y) then
        blockedTried = blockedTried + 1
        ow.x, ow.y = x, y
      end
    end
  end
  check(blockedTried > 20, blockedTried .. " blocked tiles exist")
  -- walking never lands on a blocked tile
  ow = Overworld.new({ maps = maps, map = 1 })
  local rng = 12345
  local moves, warpsHit = 0, 0
  for _ = 1, 4000 do
    rng = (rng * 1103515245 + 12345) % 2147483648
    local btn = ({ "up", "down", "left", "right" })[math.floor(rng / 65536) % 4 + 1]
    local ok, why = ow:press(btn)
    if ok then
      moves = moves + 1
      if why == "warp" then warpsHit = warpsHit + 1 end
      check(ow:walkable(ow.x, ow.y) or ow:warpAt(ow.x, ow.y) ~= nil,
        "never stands on a blocked tile")
    end
    check(ow.x % 2 == 0 and ow.y % 2 == 0, "stays on the movement grid")
  end
  check(moves > 500, moves .. " successful steps in a random walk")
  check(warpsHit > 0, warpsHit .. " warps taken while wandering")
end

-- 3. warps move you and land you somewhere walkable
do
  local ow = Overworld.new({ maps = maps, map = 1 })
  local lab = maps.maps[1]
  local warp = lab.warps[3]                       -- into the deck machine room
  ow.x, ow.y = warp.x, warp.y - 2
  local before = ow.mapIndex
  ow:step(Overworld.SOUTH)
  if ow.mapIndex == before then
    ow.x, ow.y = warp.x - 2, warp.y
    ow:step(Overworld.EAST)
  end
  check(ow.mapIndex == warp.map, "stepping on the warp changes map")
  check(ow.x == warp.destX and ow.y == warp.destY, "arrives at the destination coordinates")
end

-- 4. interaction
do
  local ow = Overworld.new({ maps = maps, map = 1 })
  local mason
  for _, n in ipairs(maps.maps[1].npcs) do if n.constant == "NPC_DRMASON" then mason = n end end
  ow.x, ow.y = mason.x, mason.y + 2
  ow.facing = Overworld.NORTH
  check(ow:interact(), "talking to Dr Mason works")
  check(ow.message and ow.message.npc == mason, "the message names the NPC")
  check(ow:press("b") and ow.message == nil, "B closes the message")
  -- a bookshelf object carries its text
  local object = maps.maps[1].objects[1]
  ow.x, ow.y = object.x, object.y + 2
  ow.facing = object.direction
  local ok = ow:interact()
  check(ok and ow.message and ow.message.text and #ow.message.text > 0,
    "reading an object shows its text")
  check(not ow:walkable(mason.x, mason.y), "NPCs block their tile")
end

-- 5. tilesets
do
  local tilesets = dofile(cacheDir .. "/data/generated/tilesets.lua")
  local n = 0
  for _ in pairs(tilesets) do n = n + 1 end
  check(n >= 80, n .. " tilesets extracted")
  for i = 0, maps.count - 1 do
    local m = maps.maps[i]
    if m.tiles then
      local ts = tilesets[m.tileset]
      check(ts ~= nil, (m.constant or i) .. " has a tileset (" .. tostring(m.tileset) .. ")")
      if ts then
        -- map bytes are VRAM tile numbers starting at $80
        local lo, hi = 255, 0
        for _, v in ipairs(m.tiles) do lo = math.min(lo, v); hi = math.max(hi, v) end
        check(lo >= 0x80, (m.constant or i) .. " tile bytes start at $80 (lowest " .. lo .. ")")
        check(hi - 0x80 < ts.tiles + 8,
          (m.constant or i) .. " tile indices fit the tileset (" .. (hi - 0x80) .. " vs " .. ts.tiles .. ")")
      end
    end
  end
end

-- sprite sheets extract, and are honest about not being frame-ready
do
  local sprites = dofile(cacheDir .. "/data/generated/sprites.lua")
  local n = 0
  for id, entry in pairs(sprites) do
    n = n + 1
    check(entry.tiles > 0 and entry.tiles <= 64, (entry.name or id) .. " has a sane tile count")
    check(entry.framesetPorted == false,
      (entry.name or id) .. " is marked as not frame-ready (the frameset system is unported)")
  end
  check(n >= 100, n .. " sprite sheets extracted")
end

-- every sprite animation resolves its frame table and names real tiles
do
  local anims = dofile(cacheDir .. "/data/generated/sprite_animations.lua")
  local total, withOam = 0, 0
  for id, anim in pairs(anims) do
    total = total + 1
    local first = anim.firstFrame or 0
    local parts = anim.oam[first]
    if parts then
      withOam = withOam + 1
      check(#parts >= 1 and #parts <= 16, "animation " .. id .. " has a sane part count")
      for _, part in ipairs(parts) do
        check(part.tile ~= nil and part.x ~= nil and part.y ~= nil,
          "animation " .. id .. " part is complete")
      end
    end
  end
  -- 191 of the 218 resolve; the rest are entries whose frame table points
  -- outside the banks the animation data lives in, and they are recorded as
  -- unresolved rather than papered over
  check(withOam >= 190, ("%d of %d animations resolve their frame table"):format(withOam, total))
  check(total >= 218, total .. " animations extracted")
end

-- sliding movement: with stepFrames set, a step takes that many frames and
-- the mover is drawn partway until it lands
do
  local ow = Overworld.new({ maps = maps, map = 1, npcs = npcData, stepFrames = 8 })
  local sx, sy = ow.x, ow.y
  local moved = false
  for _, dir in ipairs({ Overworld.EAST, Overworld.SOUTH, Overworld.WEST, Overworld.NORTH }) do
    if ow:step(dir) then moved = true; break end
  end
  check(moved, "a step starts")
  check(ow.walking ~= nil, "the slide is in progress")
  local dx, dy = ow:offsetOf(ow)
  check(dx ~= 0 or dy ~= 0, "the mover is drawn offset while sliding")
  check(ow.x ~= sx or ow.y ~= sy, "the destination is taken immediately")
  -- a second step is refused until the first lands
  check(ow:step(Overworld.EAST) == false, "no second step mid-slide")
  for _ = 1, 8 do ow:update() end
  check(ow.walking == nil, "the slide finishes")
  local ox, oy = ow:offsetOf(ow)
  check(ox == 0 and oy == 0, "and the offset clears")

  -- a scripted path queues its steps
  local world = Overworld.new({ maps = maps, map = 1, npcs = npcData, stepFrames = 4 })
  world:walkPath("player", { Overworld.EAST, Overworld.EAST })
  local guard = 0
  while world.walking and guard < 40 do guard = guard + 1; world:update() end
  check(guard > 4, "the queued steps each took frames (" .. guard .. ")")
end

print(("tcg overworld tests: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
