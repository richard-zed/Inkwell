//! UAX #14 conformance against Unicode 18.0.0 LineBreakTest.txt.
//!
//! Separate binary from the unit suite because the corpus is 2.9 MB of generated
//! Zig: `zig build test` compiles it only when this directory is populated, and
//! the corpus is excluded from the published package.

const std = @import("std");
const linebreak = @import("inkwell").linebreak;
const cases = @import("linebreak_cases");

const Folded = linebreak.Folded;

/// The two rules the conformance file presupposes but the library does not
/// encode, because they are typographic rather than algorithmic: no break
/// between a space and a following closing quote, and none after an opening
/// quote. UAX #14 notes both as tailoring for Latin text.
fn expected(f: []const Folded, cps: []const u21, i: usize) bool {
    if (f[i - 1].cls == .sp and linebreak.inSet(cps[i], &linebreak.pf)) return false;
    if (linebreak.inSet(cps[i - 1], &linebreak.pi)) return false;
    return linebreak.canBreak(f, i);
}

test "conformance: every case in LineBreakTest.txt" {
    const T = std.testing;

    var ok_cases: usize = 0;
    var total: usize = 0;
    var ok_bounds: usize = 0;
    var buf: [512]Folded = undefined;
    for (cases.cases) |cs| {
        const n = cs.cps.len;
        Folded.fold(cs.cps, buf[0..n]);
        var all = true;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const got = expected(buf[0..n], cs.cps, i);
            total += 1;
            if (got == cs.breaks[i]) ok_bounds += 1;
            if (got != cs.breaks[i]) all = false;
        }
        if (all) ok_cases += 1;
    }

    // A REGRESSION FLOOR, not a claim of conformance. Raise it when the rule
    // engine improves; never lower it to make a change pass.
    const pct = 100.0 * @as(f64, @floatFromInt(ok_cases)) / @as(f64, @floatFromInt(cases.cases.len));
    std.debug.print("\nlinebreak: {d}/{d} cases = {d:.2}%\n", .{ ok_cases, cases.cases.len, pct });
    std.debug.print("linebreak: boundaries {d}/{d} = {d:.2}%\n", .{
        ok_bounds,
        total,
        100.0 * @as(f64, @floatFromInt(ok_bounds)) / @as(f64, @floatFromInt(total)),
    });
    try T.expect(total > 19000);
    try T.expect(pct > 99.7);
}
