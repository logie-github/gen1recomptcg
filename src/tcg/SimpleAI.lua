-- Placeholder duelist AI for headless play and tests: benches Basics,
-- evolves when possible, attaches energy to the active first, plays any
-- playable Trainer, attacks with the strongest affordable attack, otherwise
-- ends the turn.  Not the game's deck AI (engine/duel/ai/*), which is a
-- later port; this exists so a duel can run start to finish.

local SimpleAI = {}

local PRIORITY = { playTrainer = 1, playBasic = 2, evolve = 3, attachEnergy = 4, retreat = 6, attack = 5, endTurn = 9 }

function SimpleAI.choose(duel, p)
  local acts = duel:legalActions(p)
  local best, bestScore
  for _, a in ipairs(acts) do
    local score = PRIORITY[a.kind] or 8
    if a.kind == "attachEnergy" and a.location ~= 0 then score = score + 0.5 end
    if a.kind == "attack" then
      local atk = duel:card(duel.players[p].active.card).attacks[a.index]
      score = score - (atk.damage or 0) / 1000
    end
    if a.kind == "retreat" then score = 20 end   -- never retreat in this stub
    if not bestScore or score < bestScore then best, bestScore = a, score end
  end
  return best
end

function SimpleAI.act(duel, p)
  local a = SimpleAI.choose(duel, p)
  if a.kind == "playBasic" then return duel:playBasic(p, a.card)
  elseif a.kind == "evolve" then return duel:evolve(p, a.card, a.location)
  elseif a.kind == "attachEnergy" then return duel:attachEnergy(p, a.card, a.location)
  elseif a.kind == "playTrainer" then return duel:playTrainer(p, a.card)
  elseif a.kind == "retreat" then return duel:retreat(p, a.location)
  elseif a.kind == "attack" then return duel:attack(p, a.index)
  else duel:endTurn(); return true end
end

-- Play a whole duel between two SimpleAIs.  Returns the duel.
function SimpleAI.playout(duel, maxTurns)
  duel:start()
  for p = 1, 2 do
    local pl = duel.players[p]
    for _, id in ipairs(pl.hand) do
      local c = duel:card(id)
      if c.kind == "pokemon" and c.stage == "BASIC" then duel:placeActive(p, id); break end
    end
  end
  duel:finishSetup()
  local guard = 0
  while not duel.finished do
    local before = duel.turn
    SimpleAI.act(duel, duel.current)
    guard = guard + 1
    if guard > (maxTurns or 400) * 30 then
      duel:finish(0, "playout guard tripped")
    end
    if duel.turn > (maxTurns or 400) then duel:finish(0, "turn limit") end
  end
  return duel
end

return SimpleAI
