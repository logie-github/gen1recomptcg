-- Credits sequence player (docs/tcg-phase1.md, Phase 28).
--
-- Steps the decoded command list from data/generated/credits.lua at the
-- driver's frame rate and exposes what should be on screen: the current
-- scene, the text lines placed on it, the fade level and the overlay band.
-- Headless and frame-driven, so the renderer (src/tcg/ui/CreditsScreen.lua)
-- only draws and the whole sequence can be run in a test.
--
-- Commands and what this does with them:
--   DisableLCD                 clears the screen
--   LoadOWMap x,y,map          set the scene to an overworld map
--   LoadClubMap n              set the scene to a club map
--   LoadScene x,y,n            set a named scene
--   LoadNPC x,y,dir,sprite     place a character in the scene
--   LoadBooster a,b,c          place a booster pack graphic
--   InitVolcanoSprite          the volcano flourish
--   InitOverlay/TransformOverlay x,y,h,?   the band that wipes the screen
--   DrawRectangle x,y          a filled block
--   PrintText x,y,text         place a line of text
--   PrintTextBox x,y,text      place a line in a box
--   FadeIn / FadeOut           fade level moves over FADE_FRAMES
--   Wait n                     hold for n frames

local CreditsSequence = {}
CreditsSequence.__index = CreditsSequence

CreditsSequence.FADE_FRAMES = 16

function CreditsSequence.new(opts)
  local data = assert(opts.credits, "credits data required")
  return setmetatable({
    steps = data.steps,
    textFor = opts.textFor or function() return nil end,
    pc = 1,
    frames = 0,
    wait = 0,
    fade = 1,              -- 1 = black, 0 = fully visible
    fading = nil,          -- "in" | "out"
    fadeFrames = 0,
    scene = nil,           -- { kind, map, x, y }
    characters = {},
    boosters = {},
    rectangles = {},
    overlay = nil,
    lines = {},
    finished = false,
    shown = 0,             -- how many text lines have been placed
  }, CreditsSequence)
end

function CreditsSequence:clear()
  self.characters, self.boosters, self.rectangles, self.lines = {}, {}, {}, {}
  self.overlay = nil
end

local function arg(step, i) return step.args and step.args[i] or 0 end

-- Run commands until one takes time (a wait or a fade), or the list ends.
function CreditsSequence:step()
  while not self.finished do
    local s = self.steps[self.pc]
    if not s then self.finished = true; return end
    self.pc = self.pc + 1
    local name = s.name

    if name == "Wait" then
      self.wait = arg(s, 1)
      if self.wait <= 0 then self.wait = 1 end
      return
    elseif name == "FadeIn" then
      self.fading, self.fadeFrames = "in", CreditsSequence.FADE_FRAMES
      return
    elseif name == "FadeOut" then
      self.fading, self.fadeFrames = "out", CreditsSequence.FADE_FRAMES
      return
    elseif name == "DisableLCD" then
      self:clear()
      self.scene = nil
      self.fade = 1
    elseif name == "LoadOWMap" then
      self:clear()
      self.scene = { kind = "map", map = arg(s, 3), x = arg(s, 1), y = arg(s, 2) }
    elseif name == "LoadClubMap" then
      self:clear()
      self.scene = { kind = "club", index = arg(s, 1) }
    elseif name == "LoadScene" then
      self:clear()
      self.scene = { kind = "scene", index = arg(s, 3), x = arg(s, 1), y = arg(s, 2) }
    elseif name == "LoadNPC" then
      self.characters[#self.characters + 1] =
        { x = arg(s, 1), y = arg(s, 2), direction = arg(s, 3), sprite = arg(s, 4) }
    elseif name == "LoadBooster" then
      self.boosters[#self.boosters + 1] = { x = arg(s, 1), y = arg(s, 2), kind = arg(s, 3) }
    elseif name == "InitVolcanoSprite" then
      self.volcano = true
    elseif name == "InitOverlay" or name == "TransformOverlay" then
      self.overlay = { x = arg(s, 1), y = arg(s, 2), height = arg(s, 3) }
    elseif name == "DrawRectangle" then
      self.rectangles[#self.rectangles + 1] = { x = arg(s, 1), y = arg(s, 2) }
    elseif name == "PrintText" or name == "PrintTextBox" then
      local text = s.textId and self.textFor(s.textId)
      self.lines[#self.lines + 1] = {
        x = arg(s, 1), y = arg(s, 2), text = text, boxed = name == "PrintTextBox",
      }
      self.shown = self.shown + 1
    end
  end
end

-- One frame of the sequence.
function CreditsSequence:frame()
  if self.finished then return end
  self.frames = self.frames + 1
  if self.wait > 0 then
    self.wait = self.wait - 1
    if self.wait > 0 then return end
  elseif self.fading then
    self.fadeFrames = self.fadeFrames - 1
    local t = self.fadeFrames / CreditsSequence.FADE_FRAMES
    self.fade = (self.fading == "in") and t or (1 - t)
    if self.fadeFrames > 0 then return end
    self.fade = (self.fading == "in") and 0 or 1
    self.fading = nil
  end
  self:step()
end

-- Run the whole thing without a renderer; returns the frames it took.
function CreditsSequence:runToEnd(limit)
  local guard = 0
  self:step()
  while not self.finished and guard < (limit or 100000) do
    guard = guard + 1
    self:frame()
  end
  return guard
end

function CreditsSequence:view()
  return {
    scene = self.scene, characters = self.characters, boosters = self.boosters,
    rectangles = self.rectangles, overlay = self.overlay, lines = self.lines,
    fade = self.fade, finished = self.finished, frames = self.frames,
  }
end

return CreditsSequence
