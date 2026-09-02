# Pokemon Trading Card Game — Phase 1

Third engine family alongside Gen 1 (`src/core/Game.lua`) and Gen 2
(`src/core/Game2.lua`). Same contract as the other carts: the repo ships an
address/name manifest derived from `pret/poketcg`; every byte of card data,
text, art and audio comes from the player's own ROM at first boot and lives
only in the private cache.

Accepted ROM: Pokemon Trading Card Game (U) [C][!].gbc, 1 MiB,
SHA-1 `0f8670a583255cff3e5b7ca71b5d7454d928fc48` (`GameVersion.VERSIONS.tcg`).

## Files

| File | Role |
| --- | --- |
| `tools/make_tcg_manifest.py` | poketcg checkout + `poketcg.sym` -> `tools/rom_manifest_tcg.json` |
| `tools/rom_manifest_tcg.json` | symbol addresses, card/deck/text/gfx orderings, enum tables, charmap |
| `src/import/RomExtractorTcg.lua` | first-boot importer (cards, text, card art, decks, boosters, fonts, duel gfx) |
| `src/import/PngWriter.lua` | pure-Lua PNG encoder for the headless path |
| `tools/tcg_extract_cli.lua` | `lua tools/tcg_extract_cli.lua --rom X.gbc --out DIR` — same output without LÖVE |
| `src/core/GameTcg.lua` | service owner; today a card/deck/booster browser on the 160x144 canvas |

Routing: `GameVersion.engine(version) == "tcg"` in `ExtractThread.lua`,
`RomImporter.lua` (`startExtraction`) and `main.lua` (`bootGame`).
`generation` is 3, so every existing `== 2` Gen 2 test stays false. Any code
that treats "not Gen 2" as "Gen 1" (arena profiles, cache markers, save
conversion) has not been audited for the TCG column yet.

## Generated cache (`tcg/`)

`data/generated/`
- `constants.lua` — card/deck ids, enums, struct layout
- `cards.lua` — `byId[1..228]`, `byConstant[NAME] = id`; Pokemon rows carry hp,
  stage, attacks (energy cost per type, damage, category, flags, effect-command
  ROM pointer, animation), weakness/resistance, dex data; Trainer/Energy rows
  carry effect-command pointer and rules text
- `text.lua` — `byId[1..2988]`, `byLabel[poketcgLabel] = id`; `\n` line
  breaks, `{RAM1}`/`{RAM2}`/`{RAM3}` substitutions, `{SYM:xx}` symbol-font
  glyphs, `{FW:..}` for untranslated full-width bytes (30 unused entries)
- `card_art.lua` — per card: PNG path, decoded CGB palette, gfx label
- `decks.lua` — `[0..55]`: card list `{count, card, constant}`, total, name
- `boosters.lua` — 29 packs: set, energy rule, per-type weights; rarity
  amounts per set
- `fonts.lua`, `duel_gfx.lua` — PNG paths

`assets/generated/`
- `cards/NNN.png` — 64x48, palette applied (`rgbgfx --columns` tile order)
- `fonts/half_width.png` (64x96, 1bpp), `fonts/symbols.png` (64x56)
- `duel/*.png` — card headers, DMG/SGB and CGB symbols, other, box messages

## Text format (poketcg `home/text.asm`)

3-byte offsets in `TextOffsets` (bank $0d) relative to the table itself, so
`abs = TextOffsets_abs + offset`. Bytes $20..$7f are the half-width ASCII
charmap; `$06` selects half width, `$07` full width, `$0a` line, `$05 xx`
symbol glyph, `$09/$0b/$0c` RAM substitutions, `$00` end.

## Card struct (poketcg `constants/card_data_constants.asm`)

Pokemon rows are $41 bytes, Trainer/Energy rows $0e. Attack energy costs are
packed one nybble per type in FIRE, GRASS, LIGHTNING, WATER, FIGHTING,
PSYCHIC, COLORLESS, UNUSED order (`energy` macro). `gfxIndex * 8` is the
offset from `CardGraphics` to 768 bytes of 2bpp plus an 8-byte palette.

## Not done

- Duel engine (`engine/duel/*`, effect commands, AI decks, animations)
- Overworld, NPCs, scripts, Card Pop, deck editor, booster opening, save format
- Audio: poketcg's driver (`audio/*.asm`) is not the pokered format ChipAudio
  streams; needs its own interpreter
- Launcher strings still say "Gen 1 Recompilation Project"

## Regenerating the manifest

```
git clone https://github.com/pret/poketcg ../poketcg
git clone -b symbols https://github.com/pret/poketcg ../poketcg-symbols
python3 tools/make_tcg_manifest.py
```

## Phase 2: duel engine core (headless)

| File | Role |
| --- | --- |
| `src/tcg/Duel.lua` | board state, setup/mulligans, turn flow, play/evolve/attach/retreat/attack, damage modifiers, status conditions, between-turn events, knockouts, prizes, win conditions |
| `src/tcg/Effects.lua` | attack/Trainer/Power handler registry keyed by card constant; unported attacks fall back to printed damage (logged once per process), unported Trainers are unplayable |
| `src/tcg/Rng.lua` | seeded xorshift32; a seed + action list reproduces a duel |
| `src/tcg/SimpleAI.lua` | stub duelist so playouts run end to end (not the game's deck AI) |
| `tests/tcg_duel_test.lua` | 20 seeded playouts (card conservation, rule-based endings, determinism) plus rule unit checks; `TCG_CACHE=<dir> lua tests/tcg_duel_test.lua` |

Rules ported, with provenance:
- weakness x2 then resistance -30, then PlusPower +10 / Defender -20, floor 0 — `home/duel.asm ApplyDamageModifiers_DamageToTarget`
- confusion: attack flips, tails = 20 to self and the attack ends; retreat flips after paying, tails = stays — `HandleConfusionDamageToSelf`, `core.asm AttemptRetreat`
- between turns: turn player's active takes poison (10/20), sleep coin, paralysis cured, PlusPowers discarded; then the other active's poison and sleep coin, Defenders discarded; then knockouts — `core.asm HandleBetweenTurnsEvents`
- no evolving on turn 1 or the turn a Pokemon was played/evolved; evolving keeps damage and clears conditions; leaving the Arena clears conditions
- energy costs: coloured requirements first, leftover of any colour pays colourless; Double Colorless counts 2
- mulligan: redraw until a Basic (the GB game grants no bonus draw); deck-out on draw loses; no active and empty bench loses; both last prizes simultaneously ties

Effects ported so far: the two practice decks' attacks (Super Fang, Water Gun, Quick Attack, Pin Missile, Thunder, Thunder Jolt, Thunderpunch, Thundershock, Earthquake, Submission, Ram, Dark Mind, Recover, the coin-flip Confuse/Paralyze attacks), Strikes Back, and Bill, Professor Oak, Potion, Super Potion, Full Heal, Switch, Gust of Wind, PlusPower, Defender, Energy Removal.

Not yet: "can't attack next turn" style substatuses (Tail Wag, Leer, Agility, Harden, Withdraw...), Pokemon Powers other than Strikes Back, target choice for multi-target effects (first legal target is used), the real deck AI, and the remaining ~170 effect routines.

## Phase 3: substatuses and text-inferred attack effects

| File | Role |
| --- | --- |
| `src/tcg/Duel.lua` (`setSub`/`sub`/`clearSubs`, `applyDefenderSubs`, `damageBench`) | per-slot substatuses with lazy expiry: `cannotAttack`, `cannotRetreat`, `disabledAttack`, `attackCoin` (Smokescreen family), `preventAll` (Agility family), `preventUpTo`, `damageReduction`, `halveDamage`, `doubleBase`; player-level `noTrainersUntil`. Benching, retreating and evolving clear them. |
| `src/tcg/EffectPatterns.lua` | attack handlers built from the card's rules text; explicit handlers in `Effects.lua` take precedence |
| `tests/tcg_effects_test.lua` | rigged-coin unit checks for the inferred families (status, coins×damage, flip-until-tails, energy discard, damage reduction and its expiry, Agility, Sand-attack, Headache, bench damage, Whirlwind) |
| `tests/tcg_fuzz_test.lua` | random 60-card decks from the whole pool, 150 seeds, invariants after every action (`lua tests/tcg_fuzz_test.lua [seeds]`) |

How inference works: `Patterns.infer(card, index)` normalises the attack's
description and matches it against ~60 Lua patterns, one family at a time
("status", "switch", ...), and composes the matching clauses into before/after
hooks. `Patterns.coverage()` reports the split; at the time of writing 213 of
the 228 attacks with rules text resolve through it, 15 match nothing and fall
back to printed damage:

- choice-driven: Metronome (Clefairy/Clefable), Mew Devolution Beam, Porygon
  Conversion 1/2, Hypno Prophecy, Poliwhirl Amnesia (headless default disables
  the strongest attack)
- state-driven: Pidgeotto/Spearow Mirror Move, Pidgeot Hurricane, Mew LV15
  Psywave, Ninetales LV35 Lure, Moltres Wildfire, Magnemite Magnetic Storm,
  Marowak LV32 Call for Friend, Mewtwo Energy Absorption (partial)

Caveats: choices ("choose 1 of them") default to the first legal target; the
GB game's exact ordering of coin flips versus damage for a few cards is not
verified against poketcg; "(Benching or evolving either Pokémon ends this
effect)" is implemented as "either Pokémon leaving the Arena or evolving
clears every substatus on it", which is broader than some cards specify.

## Phase 4: Pokémon Powers, the full Trainer set, pseudo-Pokémon

| File | Role |
| --- | --- |
| `src/tcg/Powers.lua` | every Pokémon Power: passive (Thick Skinned, Kabuto Armor, Invisible Wall, Transparency, Neutralizing Shield, Prehistoric Power, Retreat Aid, Toxic Gas), on-play (Firegiver, Quickfreeze, Peal of Thunder, Healing Wind), activated (Solar Power, Energy Trans, Heal, Energy Burn, Rain Dance, Cowardice, Damage Swap, Strange Behavior, Curse, Step In); Strikes Back stays in `Effects.lua` |
| `src/tcg/Trainers.lua` | the 24 Trainers not already in `Effects.lua`; `Effects.lua` requires it |
| `src/tcg/Duel.lua` | `setStatus`/`setPoison`/`cure` as the single write path for conditions (immunities live there), `usePower` actions and `Duel:usePower`, `retreatCost` (Retreat Aid), Energy Burn in `energyProvided`, on-play hooks in `playBasic`/`evolve`, Muk/Aerodactyl checks, pseudo-Pokémon (Clefairy Doll, Mysterious Fossil: 10 HP Basics, no prize on KO), `autoPromote` |

Every Trainer and every Power now has a handler, so the fuzz tier runs on unrestricted decks (500 seeds, 0 failures).

Deferred / simplified:
- Venomoth Shift, Omanyte Clairvoyance, Mankey Peek: registered as no-ops (information or type-change effects with no headless consequence).
- Pokédex: order is kept unless `args.order` is supplied. Poké Ball / Computer Search / Pokémon Trader / Item Finder / Recycle default to the "most useful" card by a fixed heuristic (evolution of something in play, else a Basic).
- Mysterious Fossil's "discard from play at any time" is not exposed as an action.
- Energy Trans, Damage Swap, Rain Dance and Strange Behavior are unlimited per turn as printed; `SimpleAI` budgets three power uses per turn so a stub playout cannot loop.

Running the suite: `TCG_CACHE=<cache dir> lua tests/tcg_duel_test.lua; lua tests/tcg_effects_test.lua; lua tests/tcg_fuzz_test.lua [seeds]`.
