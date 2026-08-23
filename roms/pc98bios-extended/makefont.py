#!/usr/bin/env python3
"""Build a freely redistributable PC-98 character-generator image.

The output layout is the compact 0x46800-byte format consumed by
hw/display/pc98-vga.c:

  00000-007ff  256 ANK glyphs, 8x8
  00800-017ff  256 ANK glyphs, 8x16
  01800-467ff  JIS X 0208 rows 21h-7Ch, 16x16

The 8x16 ANK and 16x16 JIS glyphs are copied from GNU Unifont's native bitmap
source without outline scaling.  Cairo is used only for the legacy 8x8 ANK
set.  The generated binary is checked in, so end users do not need Cairo.
"""

from __future__ import annotations

import argparse
import gzip
import pathlib

import cairo


FONT_SIZE = 0x46800
KANJI_BASE = 0x1800
KANJI_ROW_BYTES = 0x60 * 32
DEFAULT_UNIFONT_BDF = (
    pathlib.Path(__file__).parent
    / "fonts"
    / "unifont_jp-17.0.04.bdf.gz"
)

BdfGlyphs = dict[int, tuple[int, list[int]]]

# PC-98 displays compact mnemonic symbols for C0 controls rather than leaving
# the whole range blank.  These are semantic labels, drawn with an original
# 3x5 bitmap alphabet; they are not copied from an NEC font ROM.  PC-98 calls
# VT "HM" (home) and FF "CL" (clear).
CONTROL_LABELS = (
    None, "SH", "SX", "EX", "ET", "EQ", "AK", "BL",
    "BS", "HT", "LF", "HM", "CL", "CR", "SO", "SI",
    "DE", "D1", "D2", "D3", "D4", "NK", "SN", "EB",
    "CN", "EM", "SB", "EC",
)

TINY_3X5 = {
    "1": ("010", "110", "010", "010", "111"),
    "2": ("110", "001", "010", "100", "111"),
    "3": ("110", "001", "010", "001", "110"),
    "4": ("101", "101", "111", "001", "001"),
    "A": ("010", "101", "111", "101", "101"),
    "B": ("110", "101", "110", "101", "110"),
    "C": ("011", "100", "100", "100", "011"),
    "D": ("110", "101", "101", "101", "110"),
    "E": ("111", "100", "110", "100", "111"),
    "F": ("111", "100", "110", "100", "100"),
    "H": ("101", "101", "111", "101", "101"),
    "I": ("111", "010", "010", "010", "111"),
    "K": ("101", "101", "110", "101", "101"),
    "L": ("100", "100", "100", "100", "111"),
    "M": ("101", "111", "111", "101", "101"),
    "N": ("101", "111", "111", "111", "101"),
    "O": ("010", "101", "101", "101", "010"),
    "Q": ("010", "101", "101", "111", "011"),
    "R": ("110", "101", "110", "101", "101"),
    "S": ("011", "100", "010", "001", "110"),
    "T": ("111", "010", "010", "010", "010"),
    "X": ("101", "101", "010", "101", "101"),
}

CONTROL_ARROWS = {
    0x1C: "\u2192",
    0x1D: "\u2190",
    0x1E: "\u2191",
    0x1F: "\u2193",
}


def decode_ank(code: int) -> str | None:
    if code < 0x20 or code == 0x7F:
        return None
    try:
        text = bytes((code,)).decode("cp932")
    except UnicodeDecodeError:
        return None
    # CP932 maps its four undefined single-byte slots into the private-use
    # area.  They are blank ANK cells, not printable replacement glyphs.
    if "\uf8f0" <= text <= "\uf8f3":
        return None
    return text


def decode_jis(row: int, cell: int) -> str | None:
    if not (0x21 <= row <= 0x7E and 0x21 <= cell <= 0x7E):
        return None
    encoded = bytes((0x1B, 0x24, 0x42, row, cell, 0x1B, 0x28, 0x42))
    try:
        return encoded.decode("iso2022_jp")
    except UnicodeDecodeError:
        return None


def rasterize(
    text: str | None,
    width: int,
    height: int,
    family: str,
    point_size: float,
) -> list[int]:
    if not text:
        return [0] * height

    surface = cairo.ImageSurface(cairo.FORMAT_A8, width, height)
    context = cairo.Context(surface)
    options = cairo.FontOptions()
    options.set_antialias(cairo.ANTIALIAS_NONE)
    options.set_hint_style(cairo.HINT_STYLE_FULL)
    options.set_hint_metrics(cairo.HINT_METRICS_ON)
    context.set_font_options(options)
    context.select_font_face(
        family, cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL
    )
    context.set_font_size(point_size)

    extents = context.text_extents(text)
    x = (width - extents.width) / 2.0 - extents.x_bearing
    y = (height - extents.height) / 2.0 - extents.y_bearing
    context.move_to(round(x), round(y))
    context.set_source_rgba(1, 1, 1, 1)
    context.show_text(text)
    surface.flush()

    stride = surface.get_stride()
    data = memoryview(surface.get_data())
    rows: list[int] = []
    for y_pos in range(height):
        bits = 0
        for x_pos in range(width):
            if data[y_pos * stride + x_pos]:
                bits |= 1 << (width - 1 - x_pos)
        rows.append(bits)
    return rows


def load_bdf(path: pathlib.Path) -> BdfGlyphs:
    """Load Unicode glyphs from a 16-pixel-high BDF or BDF.GZ file."""
    glyphs: BdfGlyphs = {}
    encoding: int | None = None
    width = 0
    height = 0
    bitmap: list[int] | None = None
    opener = gzip.open if path.suffix == ".gz" else open

    with opener(path, "rt", encoding="utf-8") as source:
        for raw_line in source:
            line = raw_line.strip()
            if line.startswith("ENCODING "):
                fields = line.split()
                encoding = int(fields[1])
            elif line.startswith("BBX "):
                fields = line.split()
                width = int(fields[1])
                height = int(fields[2])
            elif line == "BITMAP":
                bitmap = []
            elif line == "ENDCHAR":
                if (
                    encoding is not None
                    and encoding >= 0
                    and bitmap is not None
                    and height == 16
                    and len(bitmap) == 16
                    and width in (8, 16)
                ):
                    glyphs[encoding] = (width, bitmap)
                encoding = None
                width = 0
                height = 0
                bitmap = None
            elif bitmap is not None:
                bitmap.append(int(line, 16))

    return glyphs


def bdf_rasterize(
    glyphs: BdfGlyphs,
    text: str | None,
    target_width: int,
) -> list[int] | None:
    if not text or len(text) != 1:
        return None

    glyph = glyphs.get(ord(text))
    if glyph is None:
        return None

    source_width, rows = glyph
    if source_width < target_width:
        shift = (target_width - source_width) // 2
        return [bits << shift for bits in rows]
    if source_width > target_width:
        shift = (source_width - target_width) // 2
        mask = (1 << target_width) - 1
        return [(bits >> shift) & mask for bits in rows]
    return rows


def special_ank_rasterize(
    glyphs: BdfGlyphs,
    code: int,
    height: int,
) -> list[int] | None:
    """Return PC-98 C0 mnemonic/arrow glyphs for an 8-pixel-wide cell."""
    if code == 0:
        return [0] * height

    if 0 < code < len(CONTROL_LABELS):
        label = CONTROL_LABELS[code]
        assert label is not None and len(label) == 2
        source_rows = []
        for row in range(5):
            bits = 0
            for char_index, char in enumerate(label):
                for x_pos, pixel in enumerate(TINY_3X5[char][row]):
                    if pixel == "1":
                        x_target = char_index * 4 + x_pos
                        bits |= 1 << (7 - x_target)
            source_rows.append(bits)

        scale_y = 2 if height == 16 else 1
        rendered = [
            bits
            for bits in source_rows
            for _ in range(scale_y)
        ]
        top = (height - len(rendered)) // 2
        return [0] * top + rendered + [0] * (height - top - len(rendered))

    arrow = CONTROL_ARROWS.get(code)
    if arrow is not None:
        rendered = bdf_rasterize(glyphs, arrow, 8)
        if rendered is None:
            return None
        if height == 8:
            return [
                rendered[row] | rendered[row + 1]
                for row in range(0, 16, 2)
            ]
        return rendered

    return None


def build_font(
    ank_family: str,
    kanji_family: str,
    unifont_glyphs: BdfGlyphs,
) -> bytearray:
    output = bytearray(FONT_SIZE)

    for code in range(256):
        text = decode_ank(code)
        # DejaVu Mono does not contain the CP932 half-width katakana block,
        # and Cairo's toy API does not perform per-glyph fallback.  Use the
        # Japanese face for the upper ANK half while retaining a true
        # monospace Latin face for ASCII.
        family = ank_family if code < 0x80 else kanji_family
        glyph = special_ank_rasterize(unifont_glyphs, code, 8)
        if glyph is None:
            glyph = rasterize(text, 8, 8, family, 7.5)
        for row, bits in enumerate(glyph):
            output[code * 8 + row] = bits

        glyph = special_ank_rasterize(unifont_glyphs, code, 16)
        if glyph is None:
            glyph = bdf_rasterize(unifont_glyphs, text, 8)
        if glyph is None:
            glyph = rasterize(text, 8, 16, family, 14.0)
        for row, bits in enumerate(glyph):
            output[0x800 + code * 16 + row] = bits

    # The file reserves 60h glyph slots per JIS row, including the blank
    # 20h and 7Fh boundary cells expected by kanji_copy().
    for row_index in range(0x5C):
        jis_row = row_index + 0x21
        row_base = KANJI_BASE + row_index * KANJI_ROW_BYTES
        for slot in range(0x60):
            jis_cell = slot + 0x20
            text = decode_jis(jis_row, jis_cell)
            glyph = bdf_rasterize(unifont_glyphs, text, 16)
            if glyph is None:
                glyph = rasterize(text, 16, 16, kanji_family, 15.0)
            glyph_base = row_base + slot * 32
            for y_pos, bits in enumerate(glyph):
                output[glyph_base + y_pos] = (bits >> 8) & 0xFF
                output[glyph_base + 16 + y_pos] = bits & 0xFF

    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--ank-family",
        default="DejaVu Sans Mono",
        help="fontconfig family used for 8-pixel ANK glyphs",
    )
    parser.add_argument(
        "--kanji-family",
        default="Droid Sans Fallback",
        help="fontconfig fallback family for glyphs absent from GNU Unifont",
    )
    parser.add_argument(
        "--unifont-bdf",
        type=pathlib.Path,
        default=DEFAULT_UNIFONT_BDF,
        help="GNU Unifont Japanese BDF or BDF.GZ bitmap source",
    )
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()

    unifont_glyphs = load_bdf(args.unifont_bdf)
    output = build_font(args.ank_family, args.kanji_family, unifont_glyphs)
    args.output.write_bytes(output)


if __name__ == "__main__":
    main()
