-- Duel sounds and attack animations (docs/tcg-phase1.md, Phase 33).
--
-- Maps the duel's events onto the sound effects the game uses for them and
-- onto the attack animation the card names, so a UI can play both without
-- knowing anything about the duel engine.  Attach with:
--
--   duel.onEvent = DuelAudio.handler({ playSfx = fn, onAnimation = fn })
--
-- The animation side reports the attack's ATK_ANIM_* name and a duration;
-- what an animation looks like is the renderer's business, and the sprite
-- effects themselves are not ported.

local DuelAudio = {}

-- event -> SFX constant, using the names the ROM actually defines
-- (checked against the extracted sfx table: there is no SFX_ATTACK, SFX_HIT,
-- SFX_KO or SFX_DRAW_CARD; hits are SINGLE_HIT and BIG_HIT)
DuelAudio.SOUNDS = {
  attack = "SFX_SINGLE_HIT",
  damage = "SFX_SINGLE_HIT",
  bigDamage = "SFX_BIG_HIT",
  knockOut = "SFX_BIG_HIT",
  coin = "SFX_COIN_TOSS",
  shuffle = "SFX_CARD_SHUFFLE",
  draw = "SFX_CARD_SHUFFLE",
}

-- Some of those names may not exist in every build; the caller's playSfx is
-- expected to ignore an unknown one, and `resolve` prefers a name that does.
function DuelAudio.resolve(available, wanted, fallback)
  if not available then return wanted end
  for _, name in ipairs({ wanted, fallback }) do
    if name then
      for _, entry in pairs(available) do
        if entry.constant == name then return name end
      end
    end
  end
  return nil
end

DuelAudio.ANIMATION_FRAMES = 24

-- opts: { playSfx = fn(constant), onAnimation = fn(info), sfx = sfx table }
function DuelAudio.handler(opts)
  local playSfx = opts.playSfx or function() end
  local onAnimation = opts.onAnimation
  local available = opts.sfx

  local function play(wanted, fallback)
    local name = DuelAudio.resolve(available, wanted, fallback)
    if name then playSfx(name) end
  end

  return function(kind, data)
    if kind == "attack" then
      -- the hit sound comes with the damage event, so an attack only opens
      -- its animation here
      if false then play(DuelAudio.SOUNDS.attack) end
      if onAnimation and data.animationName and data.animationName ~= "ATK_ANIM_NONE" then
        local entry = opts.attackAnimations
          and (opts.attackAnimations[data.animation]
            or opts.attackAnimations[tostring(data.animation)])
        onAnimation({
          name = data.animationName,
          id = data.animation,
          spriteAnimation = entry and entry.spriteAnimation,
          sprite = entry and entry.raw and entry.raw[3],
          label = data.animationName:gsub("^ATK_ANIM_", ""):gsub("_", " "),
          frames = DuelAudio.ANIMATION_FRAMES,
          attack = data.attack and data.attack.name,
        })
      end
    elseif kind == "damage" then
      if data.amount and data.amount > 0 then
        play(data.big and DuelAudio.SOUNDS.bigDamage or DuelAudio.SOUNDS.damage,
          DuelAudio.SOUNDS.damage)
      end
    elseif kind == "knockOut" then
      play(DuelAudio.SOUNDS.knockOut, DuelAudio.SOUNDS.bigDamage)
    elseif kind == "coin" then
      play(DuelAudio.SOUNDS.coin)
    elseif kind == "shuffle" then
      play(DuelAudio.SOUNDS.shuffle)
    end
  end
end

return DuelAudio
