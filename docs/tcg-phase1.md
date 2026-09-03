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

## Phase 5: duelist AI

| File | Role |
| --- | --- |
| `src/tcg/DuelAI.lua` | one general policy following poketcg's `AIMainTurnLoop` order (bench, evolve, energy, Trainers, Powers, retreat, attack) with attack scoring shaped like `ai/attacks.asm` (base 0x50, +20 for a KO, +1 per damage counter, recoil/discard/self-confusion penalties, status and bench-damage bonuses, healing attacks only when hurt) and retreat scoring shaped like `ai/retreat.asm` (conditions, imminent KO, a bench Pokémon that hits harder or can KO now, minus the retreat cost). Energy goes to one attacker at a time, active first unless it is already powered. Trainers have per-card "worth it now" tests (PlusPower only when it turns a hit into a KO, Defender only when it prevents a KO, Gust of Wind only onto a KO-able bench target, draw cards only with a small hand and a safe deck). Coin-flip attacks are valued at expected damage. |
| `tests/tcg_ai_test.lua` | DuelAI vs SimpleAI from alternating seats on the practice decks and on random decks (must win ≥70%), plus DuelAI mirror games for termination; `lua tests/tcg_ai_test.lua [games]` |

Measured at 200 games each: 71% on the practice decks, 74% on random decks
(SimpleAI already attacks with its strongest affordable attack every turn, so
this is a real margin, not a beat-random number). Not ported: the per-deck
scripts in `engine/duel/ai/decks/*` and the boss set-up tricks; those can be
layered on top as deck-specific overrides of `TRAINER_WANTS` and
`scoreAttack`.

## Phase 6: playable duels in the LÖVE app

| File | Role |
| --- | --- |
| `src/tcg/DuelSession.lua` | human-vs-AI session as pure state: setup prompts (active, bench), main menu (HAND / ATTACK / RETREAT / PKMN POWER / CHECK / END TURN), target prompts for evolution, energy, retreat, Powers, promotion and the targeted Trainers, paced log (three lines per A press), AI seat run through `DuelAI.takeTurn`. Input is Game Boy buttons via `press(btn)`; renderers read `view()`. |
| `src/tcg/ui/DuelScreen.lua` | LÖVE renderer for a session on the 160×144 canvas: both sides (active with art thumbnail, HP bar, condition tags, energy count; bench with HP), bottom panel per mode. Draw-only. |
| `src/core/GameTcg.lua` | DECKS: A picks your deck, A again picks the opponent's, the duel starts (4 prizes, AI opponent); B/A on the result returns to the deck list. |
| `src/tcg/Duel.lua` | `placeBench` for setup, per-seat `autoPromote`, `promote` as a legal action when the Arena is empty |
| `tests/tcg_session_test.lua` | menu mechanics plus 30 full games where a script plays the human seat through the real menus and prompts |
| `tests/tcg_screen_mock_test.lua` | draws every session mode against a mock `love.graphics` so renderer nil-indexes surface headless |

The renderer has not been run under real LÖVE here; the mock covers call
shapes, not pixels. Expect layout tweaks on first run (font metrics, art
scaling). Not yet: choosing which Energy to discard for retreat (last
attached is used), choosing discards for Computer Search / Item Finder /
Energy Retrieval (engine defaults), opponent hand/prize reveals.

## Phase 7: collection, decks, boosters, save, game flow

| File | Role |
| --- | --- |
| `src/tcg/Boosters.lua` | pack generation ported from `engine/booster_packs.asm`: fixed/random/all-energy openers, rarity loop STAR→DIAMOND→CIRCLE with the set's amounts, weighted type draw over types with viable unpicked cards, weight decay `max(1, w − average)` after each draw, no duplicates, regenerate on exhaustion |
| `src/tcg/Collection.lua` | owned counts, four deck slots, starter decks (+ extra cards, `starter_deck.asm`), deck rules from `deck_configuration.asm` (60 cards, ≤4 per name except basic Energy, ≥1 Basic, owned copies), save serialization |
| `src/tcg/HomeSession.lua` | title (NEW GAME / CONTINUE) → starter → home (DUEL, DECKS, COLLECTION, PACKS, SAVE, QUIT); deck editor with add/remove, filter and inline rule notices; pack opening; opponent list from the built-in decks; duel via `DuelSession`; rewards (2 neutral packs per win) and stats |
| `src/tcg/ui/HomeScreen.lua` | renderer; delegates duels to `DuelScreen` |
| `src/core/GameTcg.lua` | boots into the home flow; `save_tcg.lua` in the LÖVE save directory; SELECT on the home menu opens the card browser, B returns |
| `tests/tcg_collection_test.lua` | every pack type × 40 draws checked against the rarity table (including the Mystery Trainer/Colorless energy-in-loop case and Double Colorless as a DIAMOND), type skew, deck rules, save round trip |
| `tests/tcg_home_test.lua`, `tests/tcg_home_mock_test.lua` | the whole flow by button presses, including a duel and its rewards, and CONTINUE from the save; mock-LÖVE draw of every mode |

Simplifications at the time of this phase, all since addressed except where
noted: opponents were chosen from a deck list (the overworld and its club
progression came in Phases 10-13), wins paid generic packs (Phase 31 awards
the packs the scripts name), deck names were fixed (Phase 32 added name
entry), and medals were absent (Phase 16). Card Pop! remains unported.

## Phase 8: music driver

poketcg has its own sound engine (`audio/music1.asm` and `audio/music2.asm`),
unrelated to the pokered format `src/core/ChipAudio.lua` streams, so it needs
its own interpreter.

| File | Role |
| --- | --- |
| `src/import/RomExtractorTcg.lua` (`extractAudio`) | song header tables for both engines, per-engine pitch / octave / wave / noise / vibrato tables, and a verbatim copy of every bank the songs point into (`assets/generated/audio/music_banks.bin`, 32 KiB) |
| `src/tcg/audio/MusicPlayer.lua` | the driver: the full command set from `Music1_PlayNextNote` / `Music1_CommandTable` (notes with speed-scaled length and `cutoff` gating, octave, tie, panning, main loop, counted loops, jump/call/return, frequency and pitch offsets, duty, volume envelope, wave instrument, echo release, vibrato type and delay), stepped at the game's 60.24 Hz timer rate, plus a PCM renderer |
| `src/tcg/audio/MusicSource.lua` | LÖVE playback through a queueable source |
| `src/core/GameTcg.lua` | plays the title, home, duel and booster themes per screen; mutes on focus loss |
| `tests/tcg_audio_test.lua` | all 26 playable songs start, run 1200 driver frames, render audible in-range non-NaN output; looping songs still play after a minute; rendering is deterministic; notes land between roughly 30 Hz and 8 kHz; nothing playing renders silence |

A song is owned by whichever engine's header table has a non-NULL entry for
its index: engine 1 holds the title, duel, pause, deck machine, Card Pop and
match themes, engine 2 the PC menu, dome, challenge hall, clubs, Ronald,
Imakuni?, Hall of Honor and credits.

The renderer approximates the DMG APU rather than emulating it: duty-cycle
squares with a linear volume envelope, the 32-nybble wave instrument at the
programmed frequency with the level shift, and an LFSR for noise seeded from
the noise instrument's register script. Not modelled: frequency sweep, the
length counter, the analog high-pass, per-frame noise register scripts beyond
their seed, and SFX (`audio/sfx.asm` is a separate command set and is not
ported). Synthesis runs on the main thread; Gen 1's worker-thread approach in
`ChipAudio` is available if profiling calls for it.

## Phase 9: sound effects

| File | Role |
| --- | --- |
| `src/import/RomExtractorTcg.lua` | SFX header table (a channel mask plus one command pointer per *active* channel — the header packs them, it does not reserve a slot each), the SFX wave instruments, and the SFX bank copied alongside the song banks |
| `src/tcg/audio/SfxPlayer.lua` | the `audio/sfx.asm` command set: frequency, envelope, duty, counted loops, pitch offset, wait, wave instrument, panning, end |
| `src/tcg/audio/MusicSource.lua` | effects mixed into the same queueable source as the music, so both stay in sync; `playSfx(index or "SFX_*")` |
| `src/core/GameTcg.lua` | cursor / confirm / cancel blips on menu input |
| `tests/tcg_sfx_test.lua` | all 95 effects parse, end, stay in range and are audible; the named UI effects specifically; determinism; the silent path |

Two details of the original that the tests forced out into the open:

- `SFX_frequency` ends at `Func_fc105` (store pointer, return) instead of
  falling through to `ExecuteNextSFXCommand`, so it yields a frame like an
  explicit wait. Without that, a run of frequency commands collapses into one
  frame and most effects render as silence rather than as pitch sweeps.
- `SFX_end` stops the driver, not the APU: the channel keeps sounding until
  its hardware envelope decays, which is what gives the blips and hits their
  tail. The port keeps a ringing channel alive until its envelope reaches
  zero, forcing a decay when the program left a flat or rising envelope, with
  a five-second cap for the few effects meant to be cut off by the next sound.

## Phase 10: overworld maps

| File | Role |
| --- | --- |
| `src/import/RomExtractorTcg.lua` (`extractMaps`) | map headers, the tilemap table reached through `GfxTablePointers`, tile data and permission grids decompressed with poketcg's own LZ (`home/decompress.asm`), warps, NPC placements and interactable objects with their text |
| `src/tcg/Overworld.lua` | grid movement, collision, warps and interaction, headless and button-driven like the other sessions |
| `src/tcg/ui/OverworldScreen.lua` | schematic renderer plus the text box |
| `src/core/GameTcg.lua` | SELECT in the card browser opens the map; START leaves it |
| `tests/tcg_overworld_test.lua` | every tilemap decompresses to exactly width×height, every permission grid to the half-resolution size, every warp target exists and sits on a block boundary, Dr Mason stands where `npc_map_data.asm` says; a 4,000-press random walk never lands on a blocked tile or leaves the movement grid, warps move the player to the right coordinates, and talking works |
| `tests/tcg_overworld_mock_test.lua` | mock-LÖVE draw across several maps and a message box |

Details that shaped the port:

- Tile and permission data use poketcg's LZ, not the Gen 1 schemes already in
  `src/import/Rom.lua`: a 256-byte ring buffer seeded at `$ef`, MSB-first
  command bits, a set bit copying a literal and a clear bit starting a run of
  (nybble + 2) bytes from an offset, with the run length alternating between
  the high and low nybble of a shared length byte. Decompressing to exactly
  width×height for all 34 maps is what confirms it.
- Permissions cover 2×2 tile blocks, so the grid is `((w+1)/2)×((h+1)/2)`, and
  the player moves two tiles at a time — which is why every warp, NPC and
  object coordinate in the data is even. Bits `$40` and `$80` block a step
  (`overworld.asm`), as does any coordinate reaching `$1f`.
- Several maps point their script slots at RAM routines rather than at data
  lists, so only ROMX pointers are read as NPC or object lists.

Not ported at the time of this phase -- the map script slots were decoded in
Phase 12 and movement in Phase 29. The list as it stood: NPC movement
scripts, the six other map script slots (load map, pressed A, after duel,
close text box), doors, club structure, medals and Ronald. The overworld is
therefore explorable but not yet wired to duels.

## Phase 11: map tilesets

| File | Role |
| --- | --- |
| `src/import/RomExtractorTcg.lua` (`extractTilesets`) | all 87 tilesets, reached through the same `GfxTablePointers` table as the tilemaps, written as one PNG each (raw 2bpp preceded by a two-byte tile count) |
| `src/tcg/ui/OverworldScreen.lua` | draws the map's own tiles through quads when a tileset is supplied, with the warp / NPC / object markers dimmed over the top; the schematic view stays as the fallback |
| `src/core/GameTcg.lua` | loads tileset images from the cache on first use, like card art |
| `tests/tcg_overworld_test.lua` | every map's tileset exists and its tile bytes start at `$80` and fit the tileset's tile count |

Map tile bytes are VRAM tile numbers rather than tileset indices: the loader
stages a map's tileset at tile offset `$80`, so a tile's index into the
tileset image is `byte - $80`. Rebuilding a whole map from the extracted tiles
and tileset and comparing it against the game's own room layout is how that
was confirmed.

## Phase 12: NPC scripts and dialogue

| File | Role |
| --- | --- |
| `tools/make_tcg_manifest.py` | the script opcode table: order from the `ScriptCommand_*_index` const block, argument width per command derived from each macro body in `macros/scripts.asm` (`db` = 1, `dw`/`tx` = 2, `dwb` = 3, one branch of an `IF`/`ELSE`) |
| `src/import/RomExtractorTcg.lua` | NPC headers (sprite, script pointer, name, and the duel fields: pic, deck, music) and a script decoder that follows branch targets |
| `src/tcg/ScriptRunner.lua` | the interpreter: text, questions with yes/no jumps, `StartDuel` specs, jumps and event-flag conditionals, event setters, booster and card grants; unimplemented commands are counted in `unhandled` and skipped |
| `src/tcg/Overworld.lua` | talking runs the NPC's script; A advances and answers yes, B answers no or closes the box |
| `tests/tcg_script_test.lua` | decode coverage, Dr Mason's script checked step by step against `mason_laboratory.asm`, event-flag branching, every script terminating under four event seeds, and a conversation driven through the overworld |

Three decoding details, each caught by a test rather than by reading:

- A script label sits on the `rst $20` byte that `start_script` emits, so the
  bytecode begins one byte after the pointer.
- Scripts are labelled in a different bank from the NPC headers that point at
  them and the pointer carries no bank, so the extractor decodes each
  candidate bank and scores the results — clean termination, length, and how
  much dialogue or duelling it contains. Ninety of the scripts resolve to
  bank 3, the rest to 4 and 5.
- The decoder has to follow jump targets. Walking only the fall-through path
  stops at the first terminator, which for most NPCs is before the branch
  holding the duel or the reward: linear walking found three duels in the
  whole game, target-following finds the real set.

Not ported at the time of this phase: the movement, multichoice,
challenge-hall and card-trading commands. Phase 15 closed the command set,
Phase 17 the multichoice options and Phase 29 the movement; the map script
slots were decoded in Phase 12. The overworld
is not yet wired to start duels — the script yields a duel spec with prizes,
deck and music, and connecting that to `DuelSession` is the next step.

## Phase 13: script duels

Talking to a duelling NPC now runs its script to the `StartDuel` command and
plays that duel: the player's deck comes from the save's active slot, the
opponent's from the built-in deck list by the constant in the script, and the
prize count and NPC name come from the spec. When the duel screen closes the
overworld resumes and the script continues from where it yielded.

| File | Role |
| --- | --- |
| `src/core/GameTcg.lua` | `startScriptDuel(spec)`; the overworld holds its event flags across visits, and a missing deck reports a notice instead of failing |
| `tests/tcg_script_test.lua` | every duel spec in the game names a deck the game actually has, one is played end to end, and the script finishes afterwards |

### Over-size built-in decks (not a bug)

Three of the 56 built-in decks parse to more than 60 cards:
`UNNAMED_2_DECK` (62), `GRASS_AND_PSYCHIC_DECK` (61) and `RESHUFFLE_DECK`
(63). This was recorded here earlier as a suspected parsing bug; it is not.
The lists in `data/decks.asm` genuinely contain that many cards, poketcg
comments the count on each of them and comments out the `deck_list_end`
assert that would otherwise fail, and the extractor's totals match those
comments exactly. Two further over-size lists (66 and 72 cards) sit inside
the unnamed-deck runs, which the extractor reads only up to the first
terminator by design.

The duel engine takes the first 60 cards when handed an over-long list, which
is the pragmatic choice; what the GB game does with these decks has not been
checked and would need hardware or an emulator to establish.

## Phase 14: rendering the screens without LÖVE

The LÖVE-side code had been verified only against mocks that record call
shapes, which catches nil-indexes but not layout. `tests/love_shim.lua` is a
software stand-in for the slice of LÖVE the screens use — `setColor`,
`rectangle`, `print`, `draw` with quads and scaling, `newQuad` — rasterising
into a pixel buffer that is written out with the importer's own PNG writer.
It reads the extracted PNGs directly (the writer emits stored deflate blocks,
so no inflate is needed) and draws text with the game's own half-width font
from the cache, so the output matches what LÖVE would put on the canvas
rather than an approximation of it.

`tests/render_screens.lua` drives the real sessions and screens through the
shim and writes one PNG per screen:

```
TCG_CACHE=<cache dir> lua tests/render_screens.lua <output dir>
```

Layout bugs it found and that are now fixed:

- the duel's bench row collided with the HP bar above it, and the turn banner
  clipped the row beneath — the vertical budget is now explicit (opponent
  1–40, turn bar 41–50, player 52–91, bottom panel 92–143)
- the bottom panel covered the player's bench
- the main menu's sixth row (END TURN) fell off the bottom of the screen
- text boxes and menus drew past the bottom edge instead of clipping
- the overworld's map name ran into the START hint, and long dialogue
  overflowed the text box

## Phase 15: the rest of the script command set, and medals

Measuring which commands actually ran unhandled — rather than guessing which
looked important — put `JumpIfEventEqual` at the top with 51 occurrences,
meaning a large share of dialogue branches were silently taking the wrong
path. The command set is now complete for everything the game's scripts
actually execute: across every NPC script run under two event seeds, zero
commands execute unhandled (was ~180).

Added to `src/tcg/ScriptRunner.lua`:

- the event comparisons: equal, not-equal, less-than, zero, non-zero, plus
  zeroing and incrementing
- the card commands: grant, take, and the ownership jumps, all going through
  `Collection` so a script's rewards land in the save
- packs to the PC (`TryGivePCPack`, `TryGiveMedalPCPacks`)
- medals (`ShowMedalReceivedScreen`), stored in `Collection.medals` and
  serialised with the save; `Collection:medalCount()` is what a Hall of Honor
  check would read
- player movement and position jumps, applied to the overworld's own player
  state so `JumpIfPlayerCoordsMatch` works
- the Fighting Club pupil three-way jump, and the Man1 requested-card family
- multichoice commands, which yield a `choice` to the caller rather than
  picking silently
- the housekeeping no-ops: frames, text-box closes, audio, screen flashes

`src/tcg/Overworld.lua` passes its collection and player state into the
runner, and `GameTcg` routes script-granted packs into the same unopened
queue the home menu opens from.

Deliberately not guessed at: `PickNextMan1RequestedCard` keeps the current
card rather than inventing a roll a save could not reproduce, and scripted
movement paths apply their end position rather than animating a route.

## Phase 16: medals, the Hall of Honor gate, and choice prompts

Medals were briefly kept in a table of my own. The game already tracks them
as a bitmask in `EVENT_MEDAL_FLAGS` with a running total in
`EVENT_MEDAL_COUNT`, and opens the Hall of Honor through
`EVENT_HALL_OF_HONOR_DOORS_OPEN`, so the port now uses that numbering
instead: the manifest carries the event ids and medal bits from
`constants/script_constants.asm`, the extractor writes them into
`constants.lua`, and `ShowMedalReceivedScreen` sets the bit and increments
the count, skipping both when the medal is already held.

- `Collection` serialises the event table alongside the collection, decks and
  stats, so progress survives a save; `hasAllMedals()` is the Hall of Honor
  condition
- multichoice commands yield a `choice` to the caller with a default option
  pair, and `OverworldScreen` draws it as a cursor list answered with A or B
- the option lists live in engine tables extracted in Phase 17, so all four
  menus now carry the game's own options

Tests cover the eight medals setting all eight bits, the count reaching
eight, re-awarding not double-counting, and both medals and event values
surviving a save round trip.

## Phase 17: multichoice menus

Each multichoice command keeps its arguments in a local label the symbol file
exposes (`ScriptCommand_*.multichoice_menu_args`): title text, prompt text,
config table, the value B returns, the result slot, and a NULL-terminated
list of option text ids. `extractMultichoice` reads those and writes
`data/generated/multichoice.lua`, so the prompts and options are the game's
own rather than placeholders.

`ScriptRunner` yields the real option list with the prompt, and `advance()`
takes the chosen index, recording it in the event the game uses
(`EVENT_AARON_DECK_MENU_CHOICE`, `EVENT_SAM_MENU_CHOICE`) so later branches
read the same value the original would.

Two of the four menus (Sam's normal and rules menus) build their options from
a config table in bank 4, extracted in Phase 25; all four menus have their
real options. That is a real gap, not a finished feature: the
starter and opponent-deck menus have their three options each, Sam's two do
not.

## What a playthrough still needs

`tests/tcg_playthrough_test.lua` starts a new game and tries to walk the
progression. It cannot finish, and the reason is worth recording precisely.

**Reachable today:** the starter deck, every duel the NPC scripts start (12
played end to end against the real AI in the test), the medal bookkeeping
(all eight bits, the count, the Hall of Honor condition), and the save.

**The blocker:** only one of the eight medal awards is reachable. Each map has
eight script slots (`MAP_SCRIPT_*`: NPC list, after-NPCs-loaded, objects, load
map, pressed A, after duel, close text box, and one more), and the extractor
decodes only the NPC list and the objects. Club progression lives in the rest
— which opponent counts as the club master, what the after-duel slot does with
a win, and how the door scripts gate the next club. Until those slots are
decoded the same way NPC-header scripts are, a run cannot get past the first
club.

**Also missing for a complete game:** the `EVENT_BEAT_*` write that the
after-duel slot performs (the harness sets it itself and says so), Sam's two
multichoice option tables, NPC overworld sprites, the Hall of Honor ending
sequence, Card Pop! and link play.

The decoder that follows branch targets already handles everything these
slots would contain; the work is extracting the eight pointers per map and
running the same decode over them, then interpreting the handful of commands
that only appear there.

## Phase 19: the club chain

The after-duel script slot turned out not to be bytecode at all: it is
`ld hl, table / call FindEndOfDuelScript / ret`, and the table names one
6-byte record per duellable opponent — two NPC ids, then the scripts to run
on a win and on a loss. The medal awards live behind the win scripts, which
is why decoding only the NPC-header scripts found one of the eight. The code
sits in the script banks rather than the map-script bank, so the extractor
looks for the preamble across the candidate banks the same way it does for
script pointers.

That yields 20 after-duel tables, 48 opponent records, 42 distinct opponents,
and all eight club medals.

`tests/tcg_playthrough_test.lua` now plays the real chain: for each club,
find the master's duel (from their script, or from the deck field in their
NPC header), play it with the duel engine and `DuelAI` against the starter
deck, and on a win run the club's win script so it awards the medal, hands
out packs and sets the beat event.

**Where it gets to: all 8 medals, and the Hall of Honor condition.** Getting
the last two took one fix and one correction:

- `test_if_event_false` compiles to a conditional jump with a NULL target
  (`macros/scripts.asm`): the branch is a flag the caller reads, not a jump.
  The runner was treating the null target as "jump outside the decoded
  script" and ending the run, which killed every win script that opens with
  such a test -- Nikki's among them. Null and non-ROMX targets are now a
  no-op. This was a real bug affecting any script with a `test_if_event_*`.
- Amy was not unbeatable, only hard: the starter deck wins about one duel in
  four against her Rain Dance deck (measured over 20 runs; a mid-game deck
  wins over half). The harness was giving up after eight attempts. It now
  retries as a player would.

The playthrough test is therefore a test again rather than a progress report:
new game, eight club masters beaten with the real duel engine and AI, eight
medals awarded by the game's own win scripts, all surviving a save.

## Phase 21: overworld sprite sheets, and why NPCs are still markers

`Sprites` (engine/gfx/sprites.asm) uses the same 4-byte `GfxTablePointers`
entry as the tilesets, so all 112 overworld sprite sheets extract cleanly as
2bpp with shade 0 taken as transparent.

They are **not** drawn in the overworld, and the reason is worth recording
because it looked like a five-minute job. A 16x16 character is four tiles, so
the obvious layout is four tiles per frame in OAM order. Rendering that
produces scrambled characters, and the data notes in
`data/map_ow_framesets.asm` say why: an OW frame substitutes *one tile at a
time*, and a frameset subgroup issues several substitutions with zero
duration to change a group of tiles together. Which tiles make up a facing
frame is therefore decided by the frameset and sprite-animation data, not by
position in the sheet.

So the sheets are dumped as a plain tile grid with `framesetPorted = false`,
and the overworld keeps drawing NPCs as markers. Finishing this means porting
`MapOWFramesetPointers`, the frameset subgroup format and
`SpriteAnimations` — a real subsystem, not a layout tweak.

## Phase 22: sprite animations (partial)

The previous phase concluded that NPC sprites needed the OW frameset system.
That was wrong: OW framesets animate *map* tiles (water, flowers). Character
frames come from `SpriteAnimations` (`data/sprite_animation_pointers.asm`).

The format: an AnimData is `db bank offset, dw frame table`, then 4-byte
records of {frame index, anim count, x translation, y translation} ending
when the count is zero. The frame table lists pointers to OAM data -- a size
byte, then that many {y, x, tile, attributes} records. Those records name the
sprite-sheet tiles that make up a frame, which is why no assumed layout of
the sheet ever produced a character: the sheet is a tile bank and the OAM
data is the arrangement.

Extraction is in place and the data is right where it resolves: rendering the
tiles that `SPRITE_ANIM_LIGHT_NPC_UP` names produces recognisable characters.

**Now finished.** All 32 animations resolve. The cause was the one predicted:
`frame_table` stores its bank as `BANK(target) - BANK(AnimData1)`, so the
frame table and its OAM records live in `BANK(AnimData1) + offset` (bank $20
plus the byte), not in the animation's own bank. Resolving that byte against
`AnimData1` took the count from 26 to 32, and the overworld now draws NPCs as
characters instead of markers, each facing the direction its placement gives
it (the four facings are consecutive animation ids from the base the NPC
header names).

The frame is drawn at half scale because one screen cell is an 8px block
while a character is a 16x16 object; a renderer that scrolls by pixel rather
than by block would draw them at full size.

## Phase 24: the ending

The Hall of Honor's ending hangs off an *object*, not an NPC: the objects in
`data/map_objects.asm` carry a routine pointer, and two of the Hall's objects
point at scripts. The extractor stored that pointer from the start but never
decoded it; it now runs the same branch-following decode over object routines,
and `Overworld:interact` runs an object's script when it has one.

New commands in the runner: `PlayCredits` (yields a `credits` pending and
ends the run), `SaveGame` (calls back so the caller persists), `OpenDeckMachine`
(yields a `deckMachine` pending), and `PickLegendaryCard`, which chooses among
the four legendary birds the player is still missing so that a following
`give_card VARIABLE_CARD` hands over the right one.

`tests/tcg_playthrough_test.lua` now runs the whole arc: new game, eight club
masters beaten with the real duel engine, eight medals from the game's own win
scripts, then the Hall of Honor object awarding Zapdos, Moltres, Articuno and
Dragonite, saving, and reaching the credits.

The credits sequence was decoded in Phase 26 and is played in Phase 28.

## Phase 25: Sam's menus, and where the credits stop

Two of the four multichoice menus keep their options in a config table
(`data/multichoice.asm`) instead of in the command's arg block: box position
and size, the text position, a text id, an `$ff` marker, then the cursor's
start, step and max index. The options are the lines of that one text, and
the cursor's max index says how many are selectable. The table lives in bank
4 rather than the bank holding the arg block, so the extractor identifies the
right bank by the marker byte.

All four menus now carry their real options, and the test pins the count
against each menu's cursor range.

### The credits sequence

`play_credits` runs a command list whose entries are `dw CreditsSequenceCmd_*`
pointers followed by their arguments. The list's own label is not exported in
`poketcg.sym`, so its address could not be looked up like every other table's.
It is recoverable anyway: `SetCreditsSequenceCmdPtr` (07:57fc) writes the
address into the command pointer as immediate bytes, which gives 07:5aef, and
the first entry there is `CreditsSequenceCmd_DisableLCD` exactly as the source
has it.

The extractor decodes the list with argument widths derived from
`macros/credits_sequence.asm`, the same way script command widths are derived.
It runs to a natural end at 373 commands: the display commands (disable LCD,
fades, overlays, rectangles), the scene loads (club maps, overworld maps, NPCs,
boosters, the volcano sprite), waits, and 26 text prints.

Rendering that sequence is a screen's worth of work on top of the decoded
data, and is not done; the data it needs is now extracted.

## Phase 27: the last fifteen attacks

Every attack in the set now has a handler. The fifteen that no rules-text
pattern could match are ported explicitly in `src/tcg/EffectsRare.lua`,
because each needs state the text-inference layer cannot express:

| Attack | What it needed |
| --- | --- |
| Ninetales LV35 Lure | reading the opponent's hand |
| Moltres LV35 Dive Bomb | spending a caller-chosen amount of Energy for damage |
| Magnemite LV15 Magnetic Storm | pooling and randomly redealing every Energy on a side |
| Zapdos LV40 Thunderstorm | a coin per benched opponent, with recoil per tail |
| Marowak LV32 Call for Friend | filling both Benches from both decks |
| Hypno Prophecy | reordering either deck's top cards |
| Mew LV15 Psywave | random damage and a random condition |
| Mew LV23 Devolution Beam | returning a stage to its owner's hand |
| Pidgeotto / Spearow Mirror Move | the last damage this Pokemon took |
| Pidgeot LV40 Hurricane | returning the defender and its cards to hand |
| Clefairy / Clefable Metronome | copying an attack off the defender's card |
| Porygon Conversion 1 and 2 | rewriting Weakness or Resistance |

Three engine changes fell out of this:

- `Duel:dealDamage` records `lastDamageTaken` on the slot, which is what
  Mirror Move repeats.
- `Duel:weaknessOf` and `resistanceOf` consult a per-slot override, so
  Conversion's change is honoured by the damage calculation rather than being
  cosmetic.
- `Duel:attack` takes an `args` table and passes it into the effect context,
  so an attack's choices (Energy to discard, attack to copy, type to switch
  to) can come from a caller instead of always defaulting.

`Patterns.coverage` now reports zero unmatched attacks, and the fuzz tier runs
200 seeds with the full set live.

## Phase 28: the credits roll

| File | Role |
| --- | --- |
| `src/tcg/CreditsSequence.lua` | steps the 373 decoded commands at the driver's frame rate and exposes what should be on screen: the scene, the characters and boosters placed on it, the text lines, the overlay band and the fade level |
| `src/tcg/ui/CreditsScreen.lua` | draws that state -- map scenes from the map's own tiles, characters through the same sprite path the overworld uses, then the rectangles, overlay and fade |
| `src/core/GameTcg.lua` | a script reaching `play_credits` rolls them; any button skips |

The whole roll runs headlessly in the playthrough test: it terminates, lasts
about 175 seconds at the game's frame rate, shows 36 text lines, and keeps
its fade level in range. Rendering two frames through the software LÖVE
stand-in shows the expected pictures -- an overworld scene under the title
card, and a club interior with characters and a heading.

Timings are the sequence's own wait counts at 60.24 Hz; the fade length is a
port-side constant, since the original's fade is a palette animation this
renderer approximates with an alpha overlay.

## Phase 29: scripted movement

`move_player` is direction and speed, not a destination -- the earlier handler
read its second and third bytes as coordinates, which was wrong. The NPC
movement commands take a pointer to a movement table: a list of direction
bytes terminated by `$ff` (the `NPCMovement_*` labels in the map scripts).

The extractor now follows those pointers and attaches the direction list to
the decoded step, which found 13 paths totalling 70 steps. `ScriptRunner`
hands the path to an `onMove` callback, and `Overworld:walkPath` applies it:
the player or the named NPC steps one block per direction, turning as it goes,
and a step onto a blocked tile or off the map ends the walk the way the
original's collision does.

Movement is applied as a jump per step rather than an animated slide; the
speed byte is carried but not used, since nothing in the port animates
between tiles yet.

## Phase 30: per-deck AI preferences

The 20 deck AIs in `engine/duel/ai/decks/*` are hand-written turn routines,
but each keeps its preferences as labelled data tables, and those labels are
exported. Extracting the tables gets most of the personality without porting
the routines:

| List | Contents |
| --- | --- |
| `arena`, `bench` | the Basics this deck wants in play, in order |
| `retreat` | per-card retreat score, positive meaning happier to switch to it |
| `energy` | per-card cap on attached Energy and a score bonus |
| `prize`, `play_hand` | cards to avoid giving up, and hand-play preferences |

16 profiles extract, and their entries reproduce the source exactly (the Rain
Dance deck's Squirtle at -3 retreat and a 2-Energy cap, and so on).

`DuelAI` takes an optional profile: it benches the deck's own preferred Basics
before falling back to raw HP, stops attaching Energy to a Pokemon at that
deck's cap, applies the per-card Energy score, and adds the retreat bonus when
choosing what to switch to. `DuelSession` passes the profile matching the
opponent's deck, so club masters play their own decks the way their AI would.

The turn routines themselves are not ported -- what an opponent leads with,
loads up and retreats to now follows its deck, but the order it takes actions
in is still the general policy. Profiles cost nothing in strength: the AI
still beats the stub comfortably.

## Phase 31: the packs a script actually names

`give_booster_packs` carries three booster ids, with `NO_BOOSTER` ($ff) in the
unused slots. The handler was counting the non-zero slots and handing back a
number, so every reward became the same neutral pack. It now resolves each id
through the booster enum and passes the packs themselves, and `GameTcg` queues
the named pack rather than a stand-in.

Across the NPC and after-duel scripts that is 19 distinct pack types -- each
club's own colours, the evolution and laboratory sets, and the energy pack --
where before there was one.

`give_one_of_each_trainer_booster` and the PC-pack commands report their kind
to the callback too, so a caller can tell a club reward from a PC delivery.

## Phase 32: deck naming and sliding movement

**Naming.** `src/tcg/NameEntry.lua` is the character grid the player types a
deck name on -- upper case, lower case, digits and a few marks, with A to
place, B to rub out, START to accept and SELECT to cancel. The limit is the
game's own `DECK_NAME_SIZE` less the room it reserves for the " deck" suffix.
`src/tcg/ui/NameEntryScreen.lua` draws it, and the deck editor gained a
RENAME row. Names go into the deck slot and survive the save.

**Movement.** A step now slides over `stepFrames` frames instead of jumping,
with `Overworld:offsetOf` giving the renderer the mover's partway position and
scripted paths queueing their steps. Animation is opt-in: `stepFrames`
defaults to 0, so headless callers -- the tests, the script runner, the
playthrough -- keep the instant semantics they rely on, and `GameTcg` sets 8
for the UI.

Adding the RENAME row broke two home tests that addressed editor rows by
index; they now look rows up by action, which is what they should have done
from the start.

## Phase 33: duel sounds and attack animations

`Duel:emit` reports what happens during a duel -- attacks, damage, knockouts,
coin tosses, shuffles -- and does nothing when no handler is attached, so
headless play is unchanged. `src/tcg/DuelAudio.lua` turns those events into
sounds and animation cues, and `GameTcg` attaches it when a duel starts.

The sound names came from checking the extracted sfx table rather than
guessing: there is no `SFX_ATTACK`, `SFX_HIT`, `SFX_KO` or `SFX_DRAW_CARD` in
the ROM. Hits are `SFX_SINGLE_HIT` and `SFX_BIG_HIT`, and the mapping uses
those, with `SFX_COIN_TOSS` and `SFX_CARD_SHUFFLE` for the rest. The test
asserts every name in the mapping exists and is playable, so a wrong guess
fails loudly.

Every attack now carries its `ATK_ANIM_*` name (90 distinct animations across
345 attacks), and `DuelScreen` shows the attack's banner for the animation's
duration. **The sprite effects themselves are not ported** -- what plays is
the attack's name for the right length of time, not the original's animation.


## Phase 34: attack animation frames

`Animations`, the table `GetAnimationData` indexes by `ATK_ANIM_*` id, is not
exported in the symbol file either; the routine loads it with an immediate
(`ld bc, $4e32`), which gives 07:4e32, six bytes per entry. The first byte
indexes the sprite animation table, and the remaining bytes position and
sequence the effect -- those are kept raw rather than guessed at.

Extracting the sprite animation table in full (218 entries, where only the
first 32 the overworld needs were being read) makes 135 of the 144 attack
animations resolve, 119 of them with frame data. `DuelScreen` steps the
animation's own frame list and draws its OAM tiles over the defender while
the attack resolves.

Two honest limits: the effect's positioning and timing bytes are not
interpreted, so frames play centred at a fixed rate rather than following the
original's choreography; and 27 of the 218 sprite animations do not resolve a
frame table, which the overworld test now records as a number rather than
asserting away.

## Phase 35: link duels and Card Pop!

Both are built on the engine's existing transport contract (`send`,
`poll`), so they run over the real link layer or over the loopback the tests
use.

**Link duels** (`src/tcg/LinkDuel.lua`) exchange actions, not state: the duel
engine is deterministic, so both sides build the same duel from the same seed
and the two decks, then apply the same action sequence. The host is always
player 1 so seating agrees. Every action carries a running digest of the
sender's duel, and a mismatch stops the duel rather than letting the two
sides drift apart unnoticed. Out-of-turn actions and foreign protocols are
refused.

**Card Pop!** (`src/tcg/CardPop.lua`) has both sides send a fingerprint and a
salt, and derives the card from the combined pair, so neither side chooses
alone and both receive the same card. The pairing is recorded in the save so
it pays out once, and a different partner pays out again.

Two bugs the loopback tests caught, both mine: the divergence test forged its
action on the side whose turn it was, so the out-of-turn check fired before
the digest check and hid what was being tested; and the Card Pop fingerprint
mixed in the collection size, which changes the moment a pop lands, so the
same pair produced a different key on a second attempt and the
once-per-pairing rule never fired.

What is not covered: no real transport has been driven. The loopback delivers
messages instantly, in order, and never drops one, so latency, reordering,
disconnection mid-duel and version mismatch across builds are all unexercised.
