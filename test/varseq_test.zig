//! Unicode Variation Sequences (cmap format 14), against a real face.
//!
//! Format 14 is the one cmap format that is NOT a codepoint map: it is keyed by
//! a pair, and it carries two sub-tables that mean opposite things. DefaultUVS
//! lists sequences that need no substitution -- the base glyph IS the answer --
//! so a hit there must return the base glyph, never a miss. NonDefaultUVS
//! carries explicit glyph ids.
//!
//! Noto Sans CJK is the face to test against because it is the canonical
//! carrier of variation sequences and it has BOTH sub-table kinds. A font with
//! only NonDefaultUVS would let a broken DefaultUVS path pass silently.
//!
//! Point INKWELL_VARSEQ at the font path, or run
//! `zig build varseq -Dvarseq=path`. No font is vendored.

const std = @import("std");
const inkwell = @import("inkwell");

fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .limited(64 * 1024 * 1024));
}

// The results below were read out of the font independently, by a Python
// script walking the raw format 14 bytes -- not by this decoder. Both sides
// parse the same file, but they share no code, so agreement means the
// structure was read correctly rather than consistently.
//
// Asserted pairs, selector U+FE00 unless noted:
//   U+3001     DefaultUVS   -> base glyph unchanged
//   U+4FAE     NonDefaultUVS -> an explicit glyph id, not the base
//   U+4FB0     NonDefaultUVS -> 58913, which is past this face's glyph count,
//                               so the guard must reject it rather than
//                               hand back an id nothing can draw
//   U+FFFD     no coverage   -> null
//   any / U+FE02             no selector record -> null
test "variation sequences resolve against the real face" {
    const gpa = std.testing.allocator;
    const path_z = std.c.getenv("INKWELL_VARSEQ") orelse return error.SkipZigTest;
    const path = std.mem.span(path_z);

    const bytes = try readFile(gpa, path);
    defer gpa.free(bytes);

    const font = try inkwell.Font.init(bytes);

    // The fixture must actually carry the subtable, or every assertion below
    // would pass by returning null for the wrong reason.
    try std.testing.expect(font.hasVariationTable());

    // --- DefaultUVS: covered, and the base glyph is the correct answer ---
    // U+3001 as a plain codepoint is a real glyph; the sequence maps to the
    // same one by definition, so a miss here is the bug this test exists for.
    const base_3001 = try font.glyphIndex(0x3001);
    if (base_3001 != 0) {
        const got = try font.glyphIndexVariation(0x3001, 0xFE00);
        try std.testing.expect(got != null);
        try std.testing.expectEqual(base_3001, got.?);
        try std.testing.expect(font.hasVariation(0x3001, 0xFE00));
    }

    // --- NonDefaultUVS: an explicit id that differs from the base ---
    const base_4fae = try font.glyphIndex(0x4FAE);
    if (base_4fae != 0) {
        const got = try font.glyphIndexVariation(0x4FAE, 0xFE00);
        try std.testing.expect(got != null);
        try std.testing.expect(got.? != base_4fae);
    }

    // --- A range that exists, a pair inside it that does not ---
    // U+FFFD is nowhere in the format 14 tables.
    try std.testing.expectEqual(@as(?u16, null), try font.glyphIndexVariation(0xFFFD, 0xFE00));
    try std.testing.expect(!font.hasVariation(0xFFFD, 0xFE00));

    // --- A selector with no record at all ---
    try std.testing.expectEqual(@as(?u16, null), try font.glyphIndexVariation(0x3001, 0xFE02));
    try std.testing.expect(!font.hasVariation(0x3001, 0xFE02));
}

// A face with no format 14 subtable must say so, not invent coverage.
test "a face without format 14 has no variation sequences" {
    const gpa = std.testing.allocator;
    const path_z = std.c.getenv("INKWELL_NO_VARSEQ") orelse return error.SkipZigTest;
    const path = std.mem.span(path_z);

    const bytes = try readFile(gpa, path);
    defer gpa.free(bytes);

    const font = try inkwell.Font.init(bytes);
    try std.testing.expect(!font.hasVariationTable());
    try std.testing.expectEqual(@as(?u16, null), try font.glyphIndexVariation(0x3001, 0xFE00));
    try std.testing.expect(!font.hasVariation(0x3001, 0xFE00));
}

// Noto Sans Math exercises the OTHER shape of format 14: one selector (U+FE00),
// a NonDefaultUVS sub-table only, and no DefaultUVS at all. It is worth a
// second face because the CJK test's DefaultUVS assertions are guarded by
// `base != 0` and would pass vacuously on a face that only has NonDefault --
// this one has 51 explicit-id ranges and no defaults whatsoever.
//
// Ground truth read out of the raw bytes by an independent Python walk:
// 51 ranges, every one NonDefault, every one naming a glyph id that differs
// from the base character's, and the highest id (4355) still under
// numGlyphs (5014). So the past-the-end guard is never exercised here --
// it must be, or the assertion means nothing.
test "variation sequences resolve against a non-default-only face" {
    const gpa = std.testing.allocator;
    const path_z = std.c.getenv("INKWELL_VARSEQ_MATH") orelse return error.SkipZigTest;
    const path = std.mem.span(path_z);

    const bytes = try readFile(gpa, path);
    defer gpa.free(bytes);

    const font = try inkwell.Font.init(bytes);
    try std.testing.expect(font.hasVariationTable());

    // Digit zero: base 1779, sequence variant 1839. Two different glyphs, so
    // this cannot pass by returning the base and cannot pass by returning null.
    const base = try font.glyphIndex(0x30);
    try std.testing.expectEqual(@as(u16, 1779), base);
    const got = try font.glyphIndexVariation(0x30, 0xFE00);
    try std.testing.expectEqual(@as(?u16, 1839), got);
    try std.testing.expect(font.hasVariation(0x30, 0xFE00));

    // A script letter, to show the table is not one contiguous block.
    try std.testing.expectEqual(@as(?u16, 1445), try font.glyphIndexVariation(0x210B, 0xFE00));

    // This face has exactly ONE selector record. U+FE01 is a real selector that
    // this font says nothing about, which is the "no record" case.
    try std.testing.expectEqual(@as(?u16, null), try font.glyphIndexVariation(0x30, 0xFE01));
    try std.testing.expect(!font.hasVariation(0x30, 0xFE01));

    // A codepoint the face maps but the format 14 table does not cover.
    try std.testing.expectEqual(@as(?u16, null), try font.glyphIndexVariation(0x41, 0xFE00));
}
