-- Headless TCG extraction: runs RomExtractorTcg under plain Lua/LuaJIT with
-- no LÖVE, writing the same data/generated + assets/generated tree the
-- packaged importer produces.  Used for verification and by developers who
-- want the cache in the source tree.
--
--   lua tools/tcg_extract_cli.lua --rom "<path>.gbc" [--out DIR]
--
-- Run from the repo root (package.path is set relative to it).

package.path = "./?.lua;./?/init.lua;" .. package.path

local args = { ... }
local romPath, out = nil, "tcg-cache"
for i = 1, #args do
  if args[i] == "--rom" then romPath = args[i + 1]
  elseif args[i] == "--out" then out = args[i + 1] end
end
assert(romPath, "usage: lua tools/tcg_extract_cli.lua --rom <file> [--out DIR]")

local f = assert(io.open(romPath, "rb"))
local romData = f:read("*a"); f:close()

local Json = require("src.link.Json")
local mf = assert(io.open("tools/rom_manifest_tcg.json", "rb"))
local manifest = assert(Json.decode(mf:read("*a"))); mf:close()

local RomExtractorTcg = require("src.import.RomExtractorTcg")
local lastStage
local extractor = RomExtractorTcg.new(romData, manifest, function(_, _, stage, cur, total)
  if stage ~= lastStage then lastStage = stage; io.write(("[%s] "):format(stage)); io.flush() end
end, manifest.romSha1, RomExtractorTcg.headlessBackend(out))
local stats = extractor:run()
print()
for k, v in pairs(stats) do print(("  %-10s %d"):format(k, v)) end
print("wrote " .. out)
