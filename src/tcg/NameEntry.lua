-- Deck name entry (docs/tcg-phase1.md, Phase 32).
--
-- A character grid the player moves a cursor over, in the shape the GB
-- game's name entry uses: upper case, lower case, digits and a few marks,
-- with A to place, B to rub out and START to accept.  Headless and
-- button-driven like the other sessions, so the renderer only draws.
--
-- The length limit is the game's own DECK_NAME_SIZE (24), less the room the
-- game reserves for the " deck" suffix when it appends one.

local NameEntry = {}
NameEntry.__index = NameEntry

NameEntry.ROWS = {
  "ABCDEFGHIJ",
  "KLMNOPQRST",
  "UVWXYZ    ",
  "abcdefghij",
  "klmnopqrst",
  "uvwxyz    ",
  "0123456789",
  "!?'-.,&: ",
}

-- opts: { name = starting text, limit = n, onDone = fn(name|nil) }
function NameEntry.new(opts)
  opts = opts or {}
  return setmetatable({
    name = opts.name or "",
    limit = opts.limit or 21,
    row = 1, col = 1,
    onDone = opts.onDone,
    done = false,
  }, NameEntry)
end

function NameEntry:charAt(row, col)
  local line = NameEntry.ROWS[row]
  if not line then return nil end
  return line:sub(col, col)
end

function NameEntry:current()
  return self:charAt(self.row, self.col)
end

function NameEntry:append(ch)
  if ch == nil or ch == "" then return end
  if #self.name >= self.limit then return end
  self.name = self.name .. ch
end

function NameEntry:backspace()
  self.name = self.name:sub(1, math.max(0, #self.name - 1))
end

function NameEntry:accept()
  -- trailing spaces would look like a shorter name with padding
  local trimmed = self.name:gsub("%s+$", "")
  self.done = true
  if self.onDone then self.onDone(trimmed ~= "" and trimmed or nil) end
end

function NameEntry:cancel()
  self.done = true
  if self.onDone then self.onDone(nil) end
end

function NameEntry:press(button)
  if self.done then return end
  local rows = #NameEntry.ROWS
  local cols = #NameEntry.ROWS[1]
  if button == "up" then self.row = ((self.row - 2) % rows) + 1
  elseif button == "down" then self.row = (self.row % rows) + 1
  elseif button == "left" then self.col = ((self.col - 2) % cols) + 1
  elseif button == "right" then self.col = (self.col % cols) + 1
  elseif button == "a" then self:append(self:current())
  elseif button == "b" then self:backspace()
  elseif button == "start" then self:accept()
  elseif button == "select" then self:cancel() end
end

function NameEntry:view()
  return { name = self.name, row = self.row, col = self.col,
    rows = NameEntry.ROWS, limit = self.limit, done = self.done }
end

return NameEntry
