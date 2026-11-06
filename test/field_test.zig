//! Signed distance fields for glyph outlines, against a real face.
//!
//! The primitives are covered by hand-built squares in the unit suite, which
//! proves the signing and the ramp but says nothing about whether the edges
//! reaching them survived flattening. That is the specific failure this checks:
//! `edgesIntoPhase` drops every zero-height edge because a scanline sweep needs
//! no area from one, and those edges are the whole top and bottom of every
//! horizontal stroke.
//!
//! So the first test counts horizontals on real glyphs. 文 is a glyph of mostly
//! horizontal strokes and lost ALL of them before the flag; a face that renders
//! only verticals is the symptom.
//!
//! Point INKWELL_FACE at a font path, or `zig build field -Dface=path`. No font
//! is vendored.

const std = @import("std");
const inkwell = @import("inkwell");

const Font = inkwell.Font;
const FieldCache = inkwell.FieldCache;

fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .limited(64 * 1024 * 1024));
}

/// Pixels per font unit. `scale` multiplies font units, it is not a target
/// pixel size: Noto CJK is 2048 units/em, so 32.0 asks for a 32,768px em and
/// a box of 16064x18240. This is roughly 36px/em.
const scale: f32 = 0.0175;

fn facePath(comptime name: [:0]const u8) ?[]const u8 {
    const z = std.c.getenv(name) orelse return null;
    const s = std.mem.span(z);
    return if (s.len == 0) null else s;
}

test "flattening keeps horizontal edges on a real glyph" {
    // The bug: `Emitter.line` returns early when py0 == py1, which is right for
    // sweep() and fatal for a distance field. The flag is what changes it, so
    // the assertion is that the count moves off zero.
    const path = facePath("INKWELL_FACE") orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;

    const bytes = try readFile(gpa, path);
    defer gpa.free(bytes);
    const font = try Font.init(bytes);

    // Pick whichever of these the face actually has, so a Latin-only face still
    // runs the same code path rather than skipping.
    const glyphs: [4]u21 = .{ '文', '国', 'E', 'H' };
    var tested: usize = 0;

    for (glyphs) |cp| {
        const gid = font.glyphIndex(cp) catch continue;
        if (gid == 0) continue;

        var pts: [1024]inkwell.Point = undefined;
        var ends: [256]u16 = undefined;
        const outline = font.outline(gid, &pts, &ends) catch continue;
        const box = try font.bitmapBox(gid, scale, 0);

        var edges: [4096]inkwell.Edge = undefined;

        const without = try font.edgesIntoPhase(
            gid,
            scale,
            0,
            0,
            box,
            outline.points,
            outline.ends,
            &edges,
        );
        var horiz_without: usize = 0;
        for (edges[0..without]) |e| {
            if (e.y0 == e.y1) horiz_without += 1;
        }

        const with = try font.edgesIntoPhaseOpt(
            gid,
            scale,
            0,
            0,
            box,
            outline.points,
            outline.ends,
            &edges,
            .{ .keep_horizontal = true },
        );
        var horiz_with: usize = 0;
        for (edges[0..with]) |e| {
            if (e.y0 == e.y1) horiz_with += 1;
        }

        // The sweep drops every horizontal; the flag keeps them. Both directions
        // matter: a flattener that never produced horizontals would pass a
        // "without == 0" check alone.
        try std.testing.expectEqual(@as(usize, 0), horiz_without);
        try std.testing.expect(horiz_with > 0);
        tested += 1;
    }

    if (tested == 0) return error.SkipZigTest;
}

test "a glyph field is signed and the cache reuses it" {
    const path = facePath("INKWELL_FACE") orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;

    const bytes = try readFile(gpa, path);
    defer gpa.free(bytes);
    const font = try Font.init(bytes);

    // 'o' is the ring case: ink on the outside band, a hole in the middle. It
    // exists in essentially every face, so this needs no CJK.
    const gid = try font.glyphIndex('o');

    const opts: FieldCache.Options = .{};
    const mem = try gpa.alignedAlloc(u8, .@"8", FieldCache.needed(opts));
    defer gpa.free(mem);
    var fc = try FieldCache.init(mem, opts);

    const a = try fc.fieldAt(&font, gid, scale, .zero, .zero, 4);
    try std.testing.expect(a.dist.len > 0);
    try std.testing.expectEqual(@as(u64, 1), fc.snapshot().misses);
    try std.testing.expectEqual(@as(u64, 0), fc.snapshot().hits);

    // Signed, not unsigned: an absolute distance goes small inside the stroke as
    // well as on its outline, so a field that never goes negative is the bug.
    var saw_negative = false;
    for (a.dist) |d| {
        if (d < 0) saw_negative = true;
    }
    try std.testing.expect(saw_negative);

    // Same key: no second bake, and identical numbers because it is the same
    // arena window.
    const b = try fc.fieldAt(&font, gid, scale, .zero, .zero, 4);
    try std.testing.expectEqual(@as(u64, 1), fc.snapshot().misses);
    try std.testing.expectEqual(@as(u64, 1), fc.snapshot().hits);
    try std.testing.expectEqualSlices(f32, a.dist, b.dist);

    // A narrower width is still a hit: the field is baked at the widest width
    // and every width below it is a threshold change. That is what keeps width
    // out of the cache key.
    const c = try fc.fieldAt(&font, gid, scale, .zero, .zero, 1);
    try std.testing.expectEqual(@as(u64, 1), fc.snapshot().misses);
    try std.testing.expectEqualSlices(f32, a.dist, c.dist);
}

test "antialiased stroke on a real glyph keeps the band and softens it" {
    const path = facePath("INKWELL_FACE") orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;

    const bytes = try readFile(gpa, path);
    defer gpa.free(bytes);
    const font = try Font.init(bytes);

    const gid = try font.glyphIndex('o');

    const opts: FieldCache.Options = .{};
    const mem = try gpa.alignedAlloc(u8, .@"8", FieldCache.needed(opts));
    defer gpa.free(mem);
    var fc = try FieldCache.init(mem, opts);

    const f = try fc.fieldAt(&font, gid, scale, .zero, .zero, 4);
    const n = f.dist.len;
    const hard = try gpa.alloc(u8, n);
    defer gpa.free(hard);
    const soft = try gpa.alloc(u8, n);
    defer gpa.free(soft);

    inkwell.strokeCoverage(f.dist, hard, 3);
    inkwell.strokeCoverageAA(f.dist, soft, 3, 1.0);

    var inked: usize = 0;
    var partial: usize = 0;
    for (hard, soft) |h, s| {
        if (h != 0) inked += 1;
        if (s != 0 and s != 255) partial += 1;
        // aa never expands the band, only softens its boundaries.
        if (h == 0) try std.testing.expect(s < 255);
    }

    // A stroke that inks nothing is the failure mode worth catching: it means
    // the field lost the outline, not that the ramp was conservative.
    try std.testing.expect(inked > 0);
    try std.testing.expect(partial > 0);
}
