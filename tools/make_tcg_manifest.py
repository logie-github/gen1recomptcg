#!/usr/bin/env python3
"""Generate tools/rom_manifest_tcg.json from pret/poketcg + poketcg.sym.

Pokemon Trading Card Game (US, GBC) counterpart to make_rom_manifest.py and
make_gold_manifest.py.  Same contract as those: the manifest carries symbol
addresses, symbolic IDs/orderings and enum tables so RomExtractorTcg.lua can
decode the user's ROM at first boot.  It carries no ROM bytes, no graphics,
no dialogue payload, and no complete symbol file.

Differences from the Gen 1/2 manifests that shape this file:
  - The unit of content is a card, not a species.  CardPointers is a table
    of 2-byte pointers (bank 0x0c) into variable-size card structs; layout
    comes from constants/card_data_constants.asm.
  - Text is a flat 3-byte-offset table (TextOffsets, bank 0x0d) relative to
    the table itself, spanning banks 0x0d..0x1c.  The manifest keeps only the
    label names in table order so generated data can be keyed by name.
  - Card art is 64x48 raw 2bpp (48 tiles) + one 8-byte CGB palette,
    addressed by (offset-from-CardGraphics)/8.  No compression involved.
  - Decks are `db count, cardId` pairs terminated by 0, followed by a text
    pointer for the name.

Usage: python3 tools/make_tcg_manifest.py [--poketcg DIR] [--symbols FILE]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rom_data import SymbolTable  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANONICAL_TCG_SHA1 = "0f8670a583255cff3e5b7ca71b5d7454d928fc48"
OUTPUT = os.path.join(REPO_ROOT, "tools", "rom_manifest_tcg.json")

DEFAULT_POKETCG_CANDIDATES = [
    os.path.join(os.path.dirname(REPO_ROOT), "poketcg"),
]
DEFAULT_SYMBOL_CANDIDATES = [
    os.path.join(os.path.dirname(REPO_ROOT), "poketcg-symbols", "poketcg.sym"),
    os.path.join(os.path.dirname(REPO_ROOT), "poketcg", "poketcg.sym"),
]


# --------------------------------------------------------------------------
# tiny RGBDS reader (const_def / const / DEF ... EQU ...)
# --------------------------------------------------------------------------

def strip_comment(line):
    out, in_str = [], False
    for ch in line:
        if ch == '"':
            in_str = not in_str
        if ch == ";" and not in_str:
            break
        out.append(ch)
    return "".join(out).strip()


def parse_number(tok, env):
    tok = tok.strip()
    if tok.startswith("$"):
        return int(tok[1:], 16)
    if tok.startswith("%"):
        return int(tok[1:], 2)
    if re.fullmatch(r"-?\d+", tok):
        return int(tok)
    if tok in env:
        return env[tok]
    # very small expression support: a << b, a + b, a - b, a | b
    m = re.fullmatch(r"(.+?)\s*(<<|\+|-|\|)\s*(.+)", tok)
    if m:
        a, op, b = parse_number(m.group(1), env), m.group(2), parse_number(m.group(3), env)
        return {"<<": a << b, "+": a + b, "-": a - b, "|": a | b}[op]
    raise ValueError(f"cannot evaluate {tok!r}")


def read_consts(path, env=None):
    """Return (ordered [(name, value)], env) for one constants file."""
    env = dict(env or {})
    out = []
    value = 0
    step = 1
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = strip_comment(raw)
            if not line:
                continue
            m = re.match(r"const_def(?:\s+(.+?))?(?:\s*,\s*(.+))?$", line)
            if m:
                value = parse_number(m.group(1), env) if m.group(1) else 0
                step = parse_number(m.group(2), env) if m.group(2) else 1
                env["const_value"] = value
                continue
            m = re.match(r"(?:deck_const|const)\s+(\w+)$", line)
            if m:
                name = m.group(1)
                env[name] = value
                out.append((name, value))
                value += step
                env["const_value"] = value
                continue
            m = re.match(r"const_skip$", line)
            if m:
                value += step
                env["const_value"] = value
                continue
            m = re.match(r"DEF\s+(\w+)\s+EQU\s+(.+)$", line)
            if m:
                try:
                    env[m.group(1)] = parse_number(m.group(2), env)
                except ValueError:
                    pass  # EQUS strings and exotic expressions are not needed
                continue
    return out, env


def read_pointer_labels(path, table_label):
    """Labels listed as `dw X` immediately after `TABLE::`, until a blank line
    or a non-dw line."""
    labels = []
    with open(path, encoding="utf-8") as f:
        active = False
        for raw in f:
            line = strip_comment(raw)
            if line.startswith(table_label + "::") or line == table_label + ":":
                active = True
                continue
            if not active:
                continue
            if line.startswith("table_width") or line.startswith("assert_table_length"):
                continue
            m = re.match(r"dw\s+(\w+)$", line)
            if m:
                labels.append(m.group(1))
                continue
            if not line:
                continue
            break
    return labels


def read_text_labels(path):
    """text_offsets.asm: entry 0 is a raw `dwb`, then `textpointer Label`."""
    labels = []
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = strip_comment(raw)
            if line.startswith("dwb"):
                labels.append("NULL")
            m = re.match(r"textpointer\s+(\w+)$", line)
            if m:
                labels.append(m.group(1))
    return labels


def read_charmap(path):
    """Half-width charmap ($20..$7f) plus control names from charmaps.asm.
    Returns {byte: string}."""
    out = {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith("NEWCHARMAP"):
                break  # everything after is the Japanese full-width set
            m = re.match(r'\s*charmap\s+"((?:\\.|[^"\\])*)",\s*(\$[0-9a-fA-F]+|\w+)', line)
            if not m:
                continue
            text, code = m.group(1), m.group(2)
            text = text.replace("\\\\", "\\").replace("\\{", "{")
            if code.startswith("$"):
                out[int(code[1:], 16)] = text
    return out


def read_song_labels(path, table="SongHeaderPointers1"):
    """music*_headers.asm: the header table's `dw` rows, in table order."""
    labels = []
    with open(path, encoding="utf-8") as f:
        active = False
        for raw in f:
            line = strip_comment(raw)
            if line.startswith(table + ":"):
                active = True
                continue
            if not active:
                continue
            if line.startswith("table_width"):
                continue
            m = re.match(r"dw\s+(\w+)$", line)
            if m:
                labels.append(m.group(1))
                continue
            if line.startswith("assert_table_length") or not line:
                if labels:
                    break
    return labels


def read_card_gfx_labels(path):
    """gfx.asm: CardGraphics:: followed by `<Name>CardGfx::` labels."""
    labels = []
    with open(path, encoding="utf-8") as f:
        active = False
        for raw in f:
            line = strip_comment(raw)
            if line.startswith("CardGraphics::"):
                active = True
                continue
            if active:
                m = re.match(r"(\w+CardGfx)::", line)
                if m:
                    labels.append(m.group(1))
                elif line.startswith("SECTION") and labels:
                    # card gfx span several SECTIONs; keep going until a
                    # non-card label shows up
                    continue
                elif re.match(r"\w+::", line) and not line.startswith("INCBIN"):
                    break
    return labels


# --------------------------------------------------------------------------

def find_first(candidates, what):
    for c in candidates:
        if os.path.exists(c):
            return c
    raise SystemExit(f"{what} not found; tried: {candidates}")


def sym(symbols, name):
    # Same [bank, address] shape RomExtractor:symbol expects.
    s = symbols.by_name[name]
    return [s.bank, s.address]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--poketcg")
    ap.add_argument("--symbols")
    ap.add_argument("--output", default=OUTPUT)
    args = ap.parse_args()

    poketcg = args.poketcg or find_first(DEFAULT_POKETCG_CANDIDATES, "poketcg checkout")
    symfile = args.symbols or find_first(DEFAULT_SYMBOL_CANDIDATES, "poketcg.sym")
    src = os.path.join(poketcg, "src")
    symbols = SymbolTable(symfile)

    # ---- enums -----------------------------------------------------------
    cards, env = read_consts(os.path.join(src, "constants", "card_constants.asm"))
    card_data, env = read_consts(os.path.join(src, "constants", "card_data_constants.asm"), env)
    decks, env = read_consts(os.path.join(src, "constants", "deck_constants.asm"), env)
    boosters, env = read_consts(os.path.join(src, "constants", "booster_constants.asm"), env)

    def enum(prefix=None, names=None):
        picked = [(n, v) for n, v in card_data + boosters if
                  (prefix and n.startswith(prefix)) or (names and n in names)]
        return {str(v): n for n, v in picked}

    types = {str(env[n]): n for n in
             ["FIRE", "GRASS", "LIGHTNING", "WATER", "FIGHTING", "PSYCHIC", "COLORLESS", "UNUSED_TYPE"]}
    card_types = {}
    for n in ["FIRE", "GRASS", "LIGHTNING", "WATER", "FIGHTING", "PSYCHIC", "COLORLESS"]:
        card_types[str(env[n])] = "TYPE_PKMN_" + n
    card_types[str(env["UNUSED_TYPE"])] = "TYPE_PKMN_UNUSED"
    for n, v in card_data:
        if n.startswith("TYPE_ENERGY_") or n.startswith("TYPE_TRAINER"):
            card_types[str(v)] = n

    rarity = {"0": "CIRCLE", "1": "DIAMOND", "2": "STAR", "255": "PROMOSTAR"}
    sets = {str(env[n] >> 4): n for n in
            ["COLOSSEUM", "EVOLUTION", "MYSTERY", "LABORATORY", "PROMOTIONAL", "ENERGY"]}
    sets2 = {str(env[n]): n for n in ["JUNGLE", "FOSSIL", "GB", "PRO"]}
    stages = {str(env[n]): n for n in ["BASIC", "STAGE1", "STAGE2", "STAGE2_WITHOUT_STAGE1"]}
    wr = {n: env[n] for n in ["WR_FIRE", "WR_GRASS", "WR_LIGHTNING", "WR_WATER", "WR_FIGHTING", "WR_PSYCHIC"]}
    categories = {str(env[n]): n for n in ["DAMAGE_NORMAL", "DAMAGE_PLUS", "DAMAGE_MINUS", "DAMAGE_X", "POKEMON_POWER"]}
    flag1 = {str(1 << env[n + "_F"]): n for n in
             ["INFLICT_POISON", "INFLICT_SLEEP", "INFLICT_PARALYSIS", "INFLICT_CONFUSION",
              "LOW_RECOIL", "DAMAGE_TO_OPPONENT_BENCH", "HIGH_RECOIL", "DRAW_CARD"]}
    flag2 = {str(1 << env[n + "_F"]): n for n in
             ["SWITCH_OPPONENT_POKEMON", "HEAL_USER", "NULLIFY_OR_WEAKEN_ATTACK", "DISCARD_ENERGY",
              "ATTACHED_ENERGY_BOOST", "IGNORE_THIS_ATTACK", "ENCOURAGE_THIS_ATTACK", "FLAG_2_BIT_7"]}
    flag3 = {str(1 << env[n + "_F"]): n for n in ["BOOST_IF_TAKEN_DAMAGE", "SPECIAL_AI_HANDLING"]}

    # ---- orderings -------------------------------------------------------
    card_pointer_labels = read_pointer_labels(os.path.join(src, "data", "cards.asm"), "CardPointers")
    deck_pointer_labels = read_pointer_labels(os.path.join(src, "data", "decks.asm"), "DeckPointers")
    text_labels = read_text_labels(os.path.join(src, "text", "text_offsets.asm"))
    card_gfx_labels = read_card_gfx_labels(os.path.join(src, "gfx.asm"))
    song_labels = read_song_labels(os.path.join(src, "audio", "music1_headers.asm"))
    song_labels2 = read_song_labels(os.path.join(src, "audio", "music2_headers.asm"),
                                    "SongHeaderPointers2")
    sfx_labels = read_song_labels(os.path.join(src, "audio", "sfx_headers.asm"),
                                  "SFXHeaderPointers")
    sfx_consts, _ = read_consts(os.path.join(src, "constants", "sfx_constants.asm"), env)
    charmap = read_charmap(os.path.join(src, "constants", "charmaps.asm"))

    # CardPointers is NULL, <NUM_CARDS pointers>, NULL (assert_table_length
    # NUM_CARDS + 2); drop the trailing terminator so index == card id.
    if card_pointer_labels and card_pointer_labels[-1] == "NULL":
        card_pointer_labels = card_pointer_labels[:-1]
    if len(card_pointer_labels) != len(cards) + 1:
        raise SystemExit(f"CardPointers has {len(card_pointer_labels)} rows, "
                         f"card_constants has {len(cards)} ids")

    # gfx index = (absolute(label) - absolute(CardGraphics)) / 8
    cg = symbols.by_name["CardGraphics"]
    cg_abs = cg.bank * 0x4000 + (cg.address - 0x4000)
    gfx_index = {}
    for label in card_gfx_labels:
        s = symbols.by_name[label]
        gfx_index[str((s.bank * 0x4000 + (s.address - 0x4000) - cg_abs) // 8)] = label

    manifest = {
        "game": "tcg",
        "romSha1": CANONICAL_TCG_SHA1,
        "source": "pret/poketcg",
        "symbols": {
            name: sym(symbols, name) for name in [
                "CardPointers", "CardGraphics", "TextOffsets", "DeckPointers",
                "BoosterDataJumptable", "BoosterSetRarityAmountsTable",
                "Fonts", "FullWidthFonts", "HalfWidthFont", "SymbolsFont",
                # audio driver tables (audio/music1.asm, bank $3d)
                "NumberOfSongs1", "SongBanks1", "SongHeaderPointers1",
                "Music1_Pitches", "Music1_OctaveOffsets", "Music1_WaveInstruments",
                "Music1_NoiseInstruments", "Music1_VibratoTypes", "Music1_SFXPriorities",
                "NumberOfSongs2", "SongBanks2", "SongHeaderPointers2",
                "Music2_Pitches", "Music2_OctaveOffsets", "Music2_WaveInstruments",
                "Music2_NoiseInstruments", "Music2_VibratoTypes",
                # sfx driver (audio/sfx.asm, bank $3f)
                "NumberOfSFX", "SFXHeaderPointers", "SFX_WaveInstruments",
                "DuelGraphics", "DuelCardHeaderGraphics", "DuelDmgSgbSymbolGraphics",
                "DuelCgbSymbolGraphics", "DuelOtherGraphics", "DuelBoxMessages",
            ] if name in symbols.by_name
        },
        "cardIds": {str(v): n for n, v in cards},
        "cardOrder": [n for n, _ in cards],
        "cardLabels": card_pointer_labels,       # index = card id, [0] = NULL
        "cardGfxLabels": gfx_index,               # gfx index -> label
        "deckIds": {str(v): n for n, v in decks},
        "deckLabels": deck_pointer_labels,
        "songLabels": song_labels,
        # engine 2 (audio/music2.asm) owns the club, dome and credits themes
        "songLabels2": song_labels2,
        "sfxLabels": sfx_labels,
        "sfxIds": {str(v): n for n, v in sfx_consts},
        "textLabels": text_labels,                # index = text id, [0] = "NULL"
        "charmap": {str(k): v for k, v in charmap.items()},
        "textControl": {
            "TX_END": 0x00, "TX_SYMBOL": 0x05, "TX_HALFWIDTH": 0x06, "TX_HALF2FULL": 0x07,
            "TX_RAM1": 0x09, "TX_LINE": 0x0a, "TX_RAM2": 0x0b, "TX_RAM3": 0x0c,
        },
        "layout": {
            "pkmnCardLength": env["PKMN_CARD_DATA_LENGTH"],
            "nonPkmnCardLength": env["TRN_CARD_DATA_LENGTH"],
            "deckSize": env["DECK_SIZE"],
            "deckNameSize": env["DECK_NAME_SIZE"],
            "cardArt": {"width": 64, "height": 48, "tiles": 48, "paletteBytes": 8},
            "boosterCards": env["NUM_CARDS_IN_BOOSTER"],
            "numBoosters": len([n for n, _ in boosters if n.startswith("BOOSTER_") and
                                n.count("_") >= 2 and not n.startswith("BOOSTER_CARD_TYPE")]),
        },
        "enums": {
            "types": types, "cardTypes": card_types, "rarity": rarity, "sets": sets,
            "sets2": sets2, "stages": stages, "weaknessBits": wr, "categories": categories,
            "attackFlag1": flag1, "attackFlag2": flag2, "attackFlag3": flag3,
            "boosterSets": {str(v): n for n, v in boosters if n.startswith("BOOSTER_") and
                            n in ("BOOSTER_COLOSSEUM", "BOOSTER_EVOLUTION", "BOOSTER_MYSTERY", "BOOSTER_LABORATORY")},
            "boosters": {str(v): n for n, v in boosters if re.match(r"BOOSTER_(COLOSSEUM|EVOLUTION|MYSTERY|LABORATORY|ENERGY)_", n)},
        },
    }

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {args.output}: {len(cards)} cards, {len(text_labels)} texts, "
          f"{len(gfx_index)} card gfx, {len(deck_pointer_labels)} decks, "
          f"{len(song_labels)} songs, {len(sfx_labels)} sfx")


if __name__ == "__main__":
    main()
