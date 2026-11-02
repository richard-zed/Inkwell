//! OpenType layout: the substrate GPOS and GSUB are both made of.
//!
//! Coverage, ClassDef, the script -> langsys -> feature -> lookup indirection
//! and ValueRecords live here once. Two copies would be two sets of bugs.
//!
//! Everything is bounds-checked and allocator-free. A malformed table makes a
//! lookup return nothing; `init` refuses a header whose lists do not fit.
//!
//! Deliberately absent for now, each because it needs machinery this layer
//! does not have yet: contextual lookups (GPOS 7/8, GSUB 5/6), GDEF mark
//! filtering, Device tables (hint-time only, and we do not hint), and
//! FeatureVariations (variable fonts).

const std = @import("std");

pub const Error = error{ Truncated, MissingTable, BufferTooSmall };

/// Big-endian four-character tag, the same encoding `glyfz.tag` produces.
pub fn tag(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// What a ValueRecord can say. Device offsets are read past, not applied.
/// Where a mark sits relative to the glyph it attaches to, in font units.
pub const Offset = struct { x: i16 = 0, y: i16 = 0 };

/// GDEF, only as much of it as matching needs: which glyphs a lookup flagged
/// IgnoreMarks or UseMarkFilteringSet may step over.
///
/// Three tables, and they answer three different questions, which is why the
/// flags are not one flag:
///
/// - `GlyphClassDef` says whether a glyph is a mark at all. IgnoreMarks asks
///   exactly this and nothing more.
/// - `MarkAttachClassDef` says which mark CLASS a glyph belongs to. Attach-Type
///   selects by class, and `IgnoreBaseGlyphs`/`IgnoreLigatures` ask whether a
///   glyph is a base or a ligature, which is also GlyphClassDef.
/// - `MarkGlyphSetsDef` (GDEF 1.2+) lists named sets of coverage tables.
///   UseMarkFilteringSet names ONE set by index, and only glyphs inside it are
///   transparent -- a mark outside the set still blocks the match.
///
/// Reading UseMarkFilteringSet as if it were IgnoreMarks (which is what this
/// did before) is the difference between shaping and approximating: a font
/// that filters to "combining marks below" would have had every above-mark
/// skipped too, and a rule meant to span a specific mark would match across
/// the wrong ones.
pub const Gdef = struct {
    data: []const u8,
    class_def: usize = 0, // absolute offset, 0 when the table has none
    attach_class: usize = 0,
    sets_at: usize = 0,

    pub fn init(data: []const u8, off: u32, len: u32) Error!Gdef {
        if (data.len < off + len or len < 12) return error.Truncated;
        const end: usize = off + @as(usize, len);
        var g: Gdef = .{ .data = data };
        const rel = try u16At(data, off + 4);
        if (rel != 0) g.class_def = try relInside(off, end, rel);
        const attach = try u16At(data, off + 10);
        if (attach != 0) g.attach_class = try relInside(off, end, attach);
        // Major/minor 1.2 introduced MarkGlyphSetsDef at offset 12, and the
        // minor version is what decides whether that offset is there at all.
        const minor = try u16At(data, off + 2);
        if (minor >= 2 and len >= 14) {
            const sets = try u16At(data, off + 12);
            if (sets != 0) g.sets_at = try relInside(off, end, sets);
        }
        return g;
    }

    pub fn classOf(self: Gdef, gid: u16) Error!u16 {
        if (self.class_def == 0) return 0;
        const at = self.class_def;
        switch (try u16At(self.data, at)) {
            1 => {
                const start = try u16At(self.data, at + 2);
                const count = try u16At(self.data, at + 4);
                if (gid < start or gid >= start + count) return 0;
                return try u16At(self.data, at + 6 + @as(usize, gid - start) * 2);
            },
            2 => {
                const count = try u16At(self.data, at + 2);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const rec = at + 4 + i * 6;
                    const lo = try u16At(self.data, rec);
                    const hi = try u16At(self.data, rec + 2);
                    if (gid >= lo and gid <= hi) return try u16At(self.data, rec + 4);
                }
                return 0;
            },
            else => return 0,
        }
    }

    /// Class 1 is base, 2 is ligature, 3 is mark, 4 is component. Anything the
    /// ClassDef does not mention is class 0, which is none of the four.
    pub fn isMark(self: Gdef, gid: u16) Error!bool {
        return (try self.classOf(gid)) == 3;
    }

    pub fn isBase(self: Gdef, gid: u16) Error!bool {
        return (try self.classOf(gid)) == 1;
    }

    pub fn isLigature(self: Gdef, gid: u16) Error!bool {
        return (try self.classOf(gid)) == 2;
    }

    /// Mark attachment class, for Attach-Type. 0 means "not in any class",
    /// which Attach-Type never matches, so a font may leave this table out.
    pub fn attachClassOf(self: Gdef, gid: u16) Error!u16 {
        if (self.attach_class == 0) return 0;
        return classDefAt(self.data, self.attach_class, gid);
    }

    /// Is `gid` inside the MarkGlyphSetsDef set numbered `set`?
    pub fn inMarkSet(self: Gdef, set: u16, gid: u16) Error!bool {
        if (self.sets_at == 0) return false;
        const at = self.sets_at;
        const format = try u16At(self.data, at);
        if (format != 1) return false;
        const count = try u16At(self.data, at + 2);
        if (set >= count) return false;
        const rel = try u32At(self.data, at + 4 + @as(usize, set) * 4);
        if (rel == 0) return false;
        const cov = at + rel;
        // Coverage returns an index, and reading it as a bool is the whole
        // question here; the index itself is not used.
        return (coverageIndexAt(self.data, cov, gid) catch null) != null;
    }

    /// A glyph is transparent to a lookup when the lookup's flag says so.
    ///
    /// The four flags are not exclusive and are evaluated in the order the
    /// spec lists them; a glyph skipped by ANY of them is skipped. 0x0002 is
    /// RESTRICTED TO SCRIPT SHAPERS, and nowhere near the mark question --
    /// reading it as "also ignore marks" (which this did) widened every
    /// IgnoreMarks lookup in a font that happened to set it.
    pub fn skips(self: Gdef, flags: u16, set: u16, gid: u16) Error!bool {
        // IgnoreBaseGlyphs asks the ClassDef; returning true unconditionally
        // skipped every glyph in the buffer, which makes the lookup match
        // nothing and is invisible in output because "nothing matched" is the
        // same result as "no rule here".
        if (flags & 0x0002 != 0 and try self.isBase(gid)) return true;
        if (flags & 0x0004 != 0 and try self.isLigature(gid)) return true;
        if (flags & 0x0008 != 0 and try self.isMark(gid)) return true;
        if (flags & 0x0010 != 0 and try self.inMarkSet(set, gid)) return true;

        // MarkAttachmentType: the HIGH BYTE of the flag names a mark class,
        // and a glyph carrying a DIFFERENT class is skipped. A glyph with no
        // class at all is not skipped by this bit -- it is filtered by
        // UseMarkFilteringSet instead. Getting this backwards disables the
        // filter without changing any output.
        const want: u16 = (flags >> 8) & 0xFF;
        if (want != 0) {
            const have = try self.attachClassOf(gid);
            if (have != 0 and have != want) return true;
        }
        return false;
    }
};

/// ClassDef without the Layout indirection, so GDEF can use it too.
fn classDefAt(data: []const u8, abs: usize, gid: u16) Error!u16 {
    switch (try u16At(data, abs)) {
        1 => {
            const start = try u16At(data, abs + 2);
            const n = try u16At(data, abs + 4);
            if (gid < start or gid >= start + n) return 0;
            return try u16At(data, abs + 6 + @as(usize, gid - start) * 2);
        },
        2 => {
            const n = try u16At(data, abs + 2);
            var lo: usize = 0;
            var hi: usize = n;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const r = abs + 4 + mid * 6;
                const start = try u16At(data, r);
                const last = try u16At(data, r + 2);
                if (gid < start) {
                    hi = mid;
                } else if (gid > last) {
                    lo = mid + 1;
                } else {
                    return try u16At(data, r + 4);
                }
            }
            return 0;
        },
        else => return 0,
    }
}

fn coverageIndexAt(data: []const u8, abs: usize, gid: u16) Error!?u16 {
    const fmt = try u16At(data, abs);
    const n = try u16At(data, abs + 2);
    var lo: usize = 0;
    var hi: usize = n;
    switch (fmt) {
        1 => {
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const g = try u16At(data, abs + 4 + mid * 2);
                if (g < gid) {
                    lo = mid + 1;
                } else if (g > gid) {
                    hi = mid;
                } else {
                    return @intCast(mid);
                }
            }
            return null;
        },
        2 => {
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const r = abs + 4 + mid * 6;
                const start = try u16At(data, r);
                const last = try u16At(data, r + 2);
                if (gid < start) {
                    hi = mid;
                } else if (gid > last) {
                    lo = mid + 1;
                } else {
                    const first = try u16At(data, r + 4);
                    return first + (gid - start);
                }
            }
            return null;
        },
        else => return error.MissingTable,
    }
}

fn relInside(base: usize, end: usize, rel: u16) Error!usize {
    const abs = base + rel;
    if (abs >= end) return error.Truncated;
    return abs;
}

pub const Adjust = struct {
    x_placement: i16 = 0,
    y_placement: i16 = 0,
    x_advance: i16 = 0,
    y_advance: i16 = 0,

    pub fn isZero(self: Adjust) bool {
        return self.x_placement == 0 and self.y_placement == 0 and
            self.x_advance == 0 and self.y_advance == 0;
    }

    /// Wrapping: a font with absurd values must not panic a caller.
    pub fn add(lhs: Adjust, rhs: Adjust) Adjust {
        return .{
            .x_placement = lhs.x_placement +% rhs.x_placement,
            .y_placement = lhs.y_placement +% rhs.y_placement,
            .x_advance = lhs.x_advance +% rhs.x_advance,
            .y_advance = lhs.y_advance +% rhs.y_advance,
        };
    }
};

/// Bytes a ValueRecord occupies, given the subtable's valueFormat.
pub fn valueSize(vf: u16) usize {
    return 2 * @as(usize, @popCount(vf & 0x00FF));
}

/// One GPOS or GSUB table, addressed over the caller's font bytes.
pub const Layout = struct {
    data: []const u8,
    /// One component index per buffer slot: which ligature component this
    /// glyph followed, 0xFF when it followed none. Written by ligature
    /// substitution because mark-to-ligature is the only reader.
    lig: ?[]u8 = null,
    gdef: ?Gdef = null,
    script_list: usize,
    feature_list: usize,
    lookup_list: usize,

    pub fn init(data: []const u8, off: u32, len: u32) Error!Layout {
        const base: usize = off;
        const end: usize = base + @as(usize, len);
        if (len < 10 or end > data.len) return error.Truncated;
        const major = try u16At(data, base);
        // 1.1 shares the header shape and only adds FeatureVariations, which
        // this layer does not read, so the version is not a gate at 1.x.
        if (major != 1) return error.MissingTable;
        const sl = try u16At(data, base + 4);
        const fl = try u16At(data, base + 6);
        const ll = try u16At(data, base + 8);
        return .{
            .data = data,
            .script_list = try inside(base, end, sl),
            .feature_list = try inside(base, end, fl),
            .lookup_list = try inside(base, end, ll),
        };
    }

    /// Lookup indices for `feat` under `script`/`lang`, sorted so the caller
    /// applies them in lookup-list order. An absent script, an absent langsys
    /// or a langsys without that feature all give an empty slice; they are not
    /// errors, because "this font does not kern this script" is a real answer.
    pub fn featureLookups(self: Layout, script: u32, lang: u32, feat: u32, out: []u16) Error![]u16 {
        var n: usize = 0;
        const langs = try self.langsys(script, lang) orelse return out[0..0];
        const count = try u16At(self.data, langs + 4);
        const idxs = langs + 6;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const fi = try u16At(self.data, idxs + i * 2);
            const rec = self.feature_list + 2 + @as(usize, fi) * 6;
            const ftag = try u32At(self.data, rec);
            if (ftag != feat) continue;
            const feature = self.feature_list + try u16At(self.data, rec + 4);
            const lookup_count = try u16At(self.data, feature + 2);
            var k: usize = 0;
            while (k < lookup_count) : (k += 1) {
                if (n == out.len) break;
                out[n] = try u16At(self.data, feature + 4 + k * 2);
                n += 1;
            }
        }
        return sortUnique(out[0..n]);
    }

    /// `featureLookups` for a script chosen when the caller has no text
    /// context: `latn`, then DFLT, then each script in file order.
    ///
    /// `latn` first is not a Latin bias for its own sake, it is what the fonts
    /// do: DejaVu Sans puts ONE class-based kern lookup under DFLT and the two
    /// real ones under `latn`, so a DFLT-first policy silently loses most of
    /// its kerning. A caller that knows the script -- which is what an Arabic
    /// or Indic app will -- calls `featureLookups` directly and this policy
    /// never runs.
    pub fn featureLookupsDefault(self: Layout, feat: u32, out: []u16) Error![]u16 {
        const latn = try self.featureLookups(tag("latn"), 0, feat, out);
        if (latn.len != 0) return latn;
        const dflt = try self.featureLookups(tag("DFLT"), 0, feat, out);
        if (dflt.len != 0) return dflt;
        const count = try u16At(self.data, self.script_list);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const st = try u32At(self.data, self.script_list + 2 + i * 6);
            const got = try self.featureLookups(st, 0, feat, out);
            if (got.len != 0) return got;
        }
        return out[0..0];
    }

    /// Absolute offset of the LangSys for `script`/`lang`, or the script's
    /// default when `lang` has no record.
    fn langsys(self: Layout, script: u32, lang: u32) Error!?usize {
        const count = try u16At(self.data, self.script_list);
        var i: usize = 0;
        var script_abs: ?usize = null;
        while (i < count) : (i += 1) {
            const rec = self.script_list + 2 + i * 6;
            if (try u32At(self.data, rec) != script) continue;
            script_abs = self.script_list + try u16At(self.data, rec + 4);
            break;
        }
        const s = script_abs orelse return null;

        if (lang != 0) {
            const lang_count = try u16At(self.data, s + 2);
            var j: usize = 0;
            while (j < lang_count) : (j += 1) {
                const rec = s + 4 + j * 6;
                if (try u32At(self.data, rec) != lang) continue;
                return s + try u16At(self.data, rec + 4);
            }
        }
        const def = try u16At(self.data, s);
        if (def == 0) return null;
        return s + def;
    }

    /// Sum of every PairPos adjustment the given lookups have for this pair.
    ///
    /// The LEFT glyph's records only: valueFormat2 adjusts the glyph that
    /// follows, and a pair lookup that wants to move the right glyph needs a
    /// positioned sequence, not a pair. Extension (type 9) wrappers are
    /// unwrapped, because large fonts cannot express themselves without them.
    pub fn pairAdjust(self: Layout, lookups: []const u16, left: u16, right: u16) Adjust {
        var total: Adjust = .{};
        for (lookups) |li| {
            total = total.add(self.pairAdjustLookup(li, left, right) catch Adjust{});
        }
        return total;
    }

    fn pairAdjustLookup(self: Layout, index: u16, left: u16, right: u16) Error!Adjust {
        const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, index) * 2);
        const kind = try u16At(self.data, lookup);
        const sub_count = try u16At(self.data, lookup + 4);
        var total: Adjust = .{};
        var i: usize = 0;
        while (i < sub_count) : (i += 1) {
            const sub = lookup + try u16At(self.data, lookup + 6 + i * 2);
            switch (kind) {
                2 => total = total.add(try self.pairAt(sub, left, right)),
                9 => {
                    // Long offsets live in their own subtable; unwrap and go on.
                    const inner_kind = try u16At(self.data, sub + 2);
                    const inner = sub + try u32At(self.data, sub + 4);
                    if (inner_kind == 2) total = total.add(try self.pairAt(inner, left, right));
                },
                else => {},
            }
        }
        return total;
    }

    /// One PairPos subtable (format 1 or 2), for a pair.
    fn pairAt(self: Layout, abs: usize, left: u16, right: u16) Error!Adjust {
        const fmt = try u16At(self.data, abs);
        const cov = abs + try u16At(self.data, abs + 2);
        const vf1 = try u16At(self.data, abs + 4);
        const vf2 = try u16At(self.data, abs + 6);
        const s1 = valueSize(vf1);
        const s2 = valueSize(vf2);

        switch (fmt) {
            1 => {
                const set_count = try u16At(self.data, abs + 8);
                const idx = (try self.coverageIndex(cov, left)) orelse return .{};
                if (idx >= set_count) return .{};
                const set = abs + try u16At(self.data, abs + 10 + @as(usize, idx) * 2);
                const n = try u16At(self.data, set);
                const rec = 2 + s1 + s2;
                // PairValueRecords are sorted by secondGlyph, by the spec.
                var lo: usize = 0;
                var hi: usize = n;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const at = set + 2 + mid * rec;
                    const g = try u16At(self.data, at);
                    if (g < right) {
                        lo = mid + 1;
                    } else if (g > right) {
                        hi = mid;
                    } else {
                        return self.readValue(at + 2, vf1);
                    }
                }
                return .{};
            },
            2 => {
                // Class 0 is a real matrix row -- glyphs outside the ClassDef
                // land there, and fonts put real values in it -- so unlike the
                // coverage index it is not a reason to bail.
                if (try self.coverageIndex(cov, left) == null) return .{};
                const cd1 = abs + try u16At(self.data, abs + 8);
                const cd2 = abs + try u16At(self.data, abs + 10);
                const n1 = try u16At(self.data, abs + 12);
                const n2 = try u16At(self.data, abs + 14);
                const c1 = try self.classOf(cd1, left);
                const c2 = try self.classOf(cd2, right);
                if (c1 >= n1 or c2 >= n2) return .{};
                const rec = s1 + s2;
                const at = abs + 16 + (@as(usize, c1) * n2 + c2) * rec;
                return self.readValue(at, vf1);
            },
            else => return .{},
        }
    }

    fn readValue(self: Layout, at: usize, vf: u16) Error!Adjust {
        var a: Adjust = .{};
        var p = at;
        if (vf & 0x0001 != 0) {
            a.x_placement = try i16At(self.data, p);
            p += 2;
        }
        if (vf & 0x0002 != 0) {
            a.y_placement = try i16At(self.data, p);
            p += 2;
        }
        if (vf & 0x0004 != 0) {
            a.x_advance = try i16At(self.data, p);
            p += 2;
        }
        if (vf & 0x0008 != 0) {
            a.y_advance = try i16At(self.data, p);
            p += 2;
        }
        // Device/VariationIndex offsets (0x10..0x80) are hint-time and are
        // skipped, not followed; valueSize accounts for their width.
        return a;
    }

    /// Coverage index of `gid`, or null when the glyph is not covered.
    pub fn coverageIndex(self: Layout, abs: usize, gid: u16) Error!?u16 {
        const fmt = try u16At(self.data, abs);
        const n = try u16At(self.data, abs + 2);
        var lo: usize = 0;
        var hi: usize = n;
        switch (fmt) {
            1 => {
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const g = try u16At(self.data, abs + 4 + mid * 2);
                    if (g < gid) {
                        lo = mid + 1;
                    } else if (g > gid) {
                        hi = mid;
                    } else {
                        return @intCast(mid);
                    }
                }
                return null;
            },
            2 => {
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const r = abs + 4 + mid * 6;
                    const start = try u16At(self.data, r);
                    const last = try u16At(self.data, r + 2);
                    if (gid < start) {
                        hi = mid;
                    } else if (gid > last) {
                        lo = mid + 1;
                    } else {
                        const first = try u16At(self.data, r + 4);
                        return first + (gid - start);
                    }
                }
                return null;
            },
            else => return error.MissingTable,
        }
    }

    /// ClassDef class of `gid`. Glyphs the ClassDef does not mention are class
    /// 0, which is what the spec says, not a failure.
    pub fn classOf(self: Layout, abs: usize, gid: u16) Error!u16 {
        const fmt = try u16At(self.data, abs);
        switch (fmt) {
            1 => {
                const start = try u16At(self.data, abs + 2);
                const n = try u16At(self.data, abs + 4);
                if (gid < start or gid >= start + n) return 0;
                return try u16At(self.data, abs + 6 + @as(usize, gid - start) * 2);
            },
            2 => {
                const n = try u16At(self.data, abs + 2);
                var lo: usize = 0;
                var hi: usize = n;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const r = abs + 4 + mid * 6;
                    const start = try u16At(self.data, r);
                    const last = try u16At(self.data, r + 2);
                    if (gid < start) {
                        hi = mid;
                    } else if (gid > last) {
                        lo = mid + 1;
                    } else {
                        return try u16At(self.data, r + 4);
                    }
                }
                return 0;
            },
            else => return error.MissingTable,
        }
    }

    /// One GSUB pass for `feat` over `in`, writing to `out`.
    ///
    /// Types 1 (single), 2 (multiple), 3 (alternate) and 4 (ligature). The
    /// pass is left to right, one lookup at a time, in lookup-list order --
    /// which is the order the spec applies them in, because a later lookup is
    /// written against the output of the earlier ones. Contextual lookups
    /// (types 5 and 6) are not applied, so a font that only replaces through
    /// context reads as unchanged rather than as wrong.
    ///
    /// `out` may alias `in`? No: it is written from the start, so pass distinct
    /// buffers. It must have room for the longest expansion the feature can
    /// produce, and too little room is `BufferTooSmall`, never a truncation.
    pub fn substitute(self: Layout, feat: u32, in: []const u16, out: []u16) Error!usize {
        if (out.len < in.len) return error.BufferTooSmall;
        @memcpy(out[0..in.len], in);
        var len = in.len;

        var lookups_buf: [256]u16 = undefined;
        const lookups = try self.featureLookupsDefault(feat, &lookups_buf);
        for (lookups) |li| {
            const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, li) * 2);
            const kind = try u16At(self.data, lookup);
            const flags = try u16At(self.data, lookup + 2);
            const sub_count = try u16At(self.data, lookup + 4);
            const mark_set = try self.markFilteringSet(li);
            var i: usize = 0;
            while (i < sub_count) : (i += 1) {
                const sub = lookup + try u16At(self.data, lookup + 6 + i * 2);
                const step = try self.substPass(kind, sub, out, len, flags, mark_set);
                len = step;
            }
        }
        return len;
    }

    /// The lookups of `feat` under `script` and `lang`, falling back to the
    /// default script when that script does not carry it. Arabic lives under
    /// `arab`, and a font may not repeat ccmp there.
    ///
    /// `lang` is what `locl` turns on: a font stores regional glyph forms
    /// (Japanese against Simplified Chinese, say) as separate LangSys records
    /// carrying the same feature tag, so passing 0 asks for the default forms
    /// and can never reach the others.
    fn lookupsFor(self: Layout, script: u32, lang: u32, feat: u32, out: []u16) []const u16 {
        if (self.featureLookups(script, lang, feat, out)) |l| {
            if (l.len > 0) return l;
        } else |_| {}
        return self.featureLookupsDefault(feat, out) catch return &.{};
    }

    /// Apply lookup `index` at one position, stopping at the first subtable
    /// that changes the buffer. `depth` bounds the nesting a contextual lookup
    /// can ask for, so a font that points a lookup at itself cannot loop.
    fn applyLookupAt(self: Layout, index: u16, buf: []u16, len: usize, pos: usize, depth: u4) Error!usize {
        if (depth > 8) return len;
        const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, index) * 2);
        const kind = try u16At(self.data, lookup);
        const flags = try u16At(self.data, lookup + 2);
        const sub_count = try u16At(self.data, lookup + 4);
        const mark_set = try self.markFilteringSet(index);
        var cur = len;
        var i: usize = 0;
        while (i < sub_count) : (i += 1) {
            const sub = lookup + try u16At(self.data, lookup + 6 + i * 2);
            var real_kind = kind;
            var real = sub;
            if (kind == 7) {
                real_kind = try u16At(self.data, sub + 2);
                real = sub + try u32At(self.data, sub + 4);
            }
            const step = try self.substAt(real_kind, real, buf, cur, pos, depth, flags, mark_set);
            // Only a HIT carries a length. Step.len defaults to 0 for a miss,
            // so assigning it unconditionally truncated the run to nothing at
            // the first lookup that did not match.
            if (step.hit) {
                cur = step.len;
                break;
            }
        }
        return cur;
    }

    /// GSUB type 6, chaining contextual. Format 3 only: every coverage set is
    /// an explicit list of positions, which is what real fonts use for this.
    /// Formats 1 and 2 (glyph and class based rule sets) are not implemented
    /// and match nothing, so a font using them keeps its unsubstituted glyphs
    /// rather than producing wrong ones.
    /// Contextual/chaining lookup dispatch by substFormat.
    ///
    /// Formats 1 and 2 differ from 3 only in how the input sequence is named --
    /// a glyph-keyed ruleset, a class-keyed ruleset, or an explicit coverage
    /// list. The records and the substitution loop are identical, so each
    /// format earns its way to `runRecords` and nothing past that is
    /// format-specific.
    fn chainAt(self: Layout, sub: usize, buf: []u16, len: usize, pos: usize, depth: u4, flags: u16, set: u16) Error!Step {
        const fmt = try u16At(self.data, sub);
        return switch (fmt) {
            1 => self.chainGlyphRules(sub, buf, len, pos, depth, flags, set),
            2 => self.chainClassRules(sub, buf, len, pos, depth, flags, set),
            3 => self.chainCoverage(sub, buf, len, pos, depth, flags, set),
            else => .{},
        };
    }

    /// Format 1: the first glyph of the input selects a RuleSet, and each Rule
    /// in that set is a plain glyph sequence followed by records.
    ///
    /// Note the input coverage is a SET count, not a single coverage table:
    /// offset 4 points at the first RuleSet, and a RuleSet appears at position
    /// `coverageIndex(glyph)` in that array. An index past setCount means the
    /// glyph has no rules, which is a miss and not an error.
    fn chainGlyphRules(self: Layout, sub: usize, buf: []u16, len: usize, pos: usize, depth: u4, flags: u16, set: u16) Error!Step {
        const cov = sub + try u16At(self.data, sub + 2);
        const idx = (try self.coverageIndex(cov, buf[pos])) orelse return .{};
        const set_n = try u16At(self.data, sub + 4);
        if (idx >= set_n) return .{};
        const set_rel = try u16At(self.data, sub + 6 + @as(usize, idx) * 2);
        if (set_rel == 0) return .{}; // correct: this glyph simply has no rules
        const set_at = sub + set_rel;
        const rule_n = try u16At(self.data, set_at);
        const st = try self.tryRules(set_at, rule_n, buf, len, pos, depth, flags, set);
        return st;
    }

    /// Format 2: the input is a sequence of CLASSES, so every glyph must be
    /// resolved through ClassDef before comparison, and the count of classes is
    /// what the ClassSet array is indexed by.
    fn chainClassRules(self: Layout, sub: usize, buf: []u16, len: usize, pos: usize, depth: u4, flags: u16, set: u16) Error!Step {
        const cov = sub + try u16At(self.data, sub + 2);
        const idx = (try self.coverageIndex(cov, buf[pos])) orelse return .{};
        const class_def = sub + try u16At(self.data, sub + 4);
        const class_n = try u16At(self.data, sub + 6);
        if (idx >= class_n) return .{};
        const set_rel = try u16At(self.data, sub + 8 + @as(usize, idx) * 2);
        if (set_rel == 0) return .{};
        const set_at = sub + set_rel;
        const rule_n = try u16At(self.data, set_at);
        return self.tryClassRules(class_def, set_at, rule_n, buf, len, pos, depth, flags, set);
    }

    /// Walk a RuleSet's rules for format 1, taking the first that matches.
    ///
    /// Longest-match would be wrong here: OpenType rule order IS priority, and
    /// a face that lists a specific rule before a general one expects the
    /// specific one to win. `chainClassRules` follows the same rule.
    fn tryRules(self: Layout, set_at: usize, rule_n: usize, buf: []u16, len: usize, pos: usize, depth: u4, flags: u16, set: u16) Error!Step {
        var r: usize = 0;
        while (r < rule_n) : (r += 1) {
            const rule = set_at + try u16At(self.data, set_at + 2 + r * 2);
            const glyph_n = try u16At(self.data, rule);
            const rec_n = try u16At(self.data, rule + 2);
            if (glyph_n == 0 or glyph_n > 16) continue;

            var positions: [16]usize = undefined;
            var got: usize = 0;
            var p = pos + 1; // the first glyph is what selected this rule
            positions[0] = pos;
            got = 1;
            while (got < glyph_n) {
                if (p >= len) return .{};
                if (try self.skipsGlyph(flags, set, buf[p])) {
                    p += 1;
                    continue;
                }
                const want = try u16At(self.data, rule + 4 + (got - 1) * 2);
                if (buf[p] != want) {
                    got = 0;
                    break;
                }
                positions[got] = p;
                got += 1;
                p += 1;
            }
            if (got != glyph_n) continue;
            const rec_off = rule + 4 + (glyph_n - 1) * 2;
            return self.runRecords(rec_off, rec_n, positions[0..glyph_n], pos, buf, len, depth);
        }
        return .{};
    }

    /// Walk a ClassSet's rules for format 2, comparing CLASSES rather than
    /// glyph ids. Every glyph in the run is resolved through the ClassDef, so
    /// two glyphs in the same class match the same rule.
    fn tryClassRules(self: Layout, class_def: usize, set_at: usize, rule_n: usize, buf: []u16, len: usize, pos: usize, depth: u4, flags: u16, set: u16) Error!Step {
        var r: usize = 0;
        while (r < rule_n) : (r += 1) {
            const rule = set_at + try u16At(self.data, set_at + 2 + r * 2);
            const glyph_n = try u16At(self.data, rule);
            const rec_n = try u16At(self.data, rule + 2);
            if (glyph_n == 0 or glyph_n > 16) continue;

            var positions: [16]usize = undefined;
            positions[0] = pos;
            var got: usize = 1;
            var p = pos + 1;
            while (got < glyph_n) {
                if (p >= len) return .{};
                if (try self.skipsGlyph(flags, set, buf[p])) {
                    p += 1;
                    continue;
                }
                const want = try u16At(self.data, rule + 4 + (got - 1) * 2);
                if (try self.classOf(class_def, buf[p]) != want) {
                    got = 0;
                    break;
                }
                positions[got] = p;
                got += 1;
                p += 1;
            }
            if (got != glyph_n) continue;
            const rec_off = rule + 4 + (glyph_n - 1) * 2;
            return self.runRecords(rec_off, rec_n, positions[0..glyph_n], pos, buf, len, depth);
        }
        return .{};
    }

    fn chainCoverage(self: Layout, sub: usize, buf: []u16, len: usize, pos: usize, depth: u4, flags: u16, set: u16) Error!Step {
        if (try u16At(self.data, sub) != 3) return .{};
        var at = sub + 2;

        const back_n = try u16At(self.data, at);
        at += 2;
        const back_off = at;
        at += @as(usize, back_n) * 2;

        const in_n = try u16At(self.data, at);
        at += 2;
        const in_off = at;
        at += @as(usize, in_n) * 2;

        const ahead_n = try u16At(self.data, at);
        at += 2;
        const ahead_off = at;
        at += @as(usize, ahead_n) * 2;

        const rec_n = try u16At(self.data, at);
        at += 2;
        const rec_off = at;

        // Input coverage, left to right from pos.
        //
        // With lookupFlag IgnoreMarks (or UseMarkFilteringSet) a mark does not
        // break the match: it is stepped over and LEFT IN PLACE, which is how
        // HarfBuzz ligates لَا while keeping the fatha. `positions` maps each
        // matched input slot back to its buffer index so the records below
        // still name the right glyph.
        if (in_n == 0 or in_n > 16) return .{};
        var positions: [16]usize = undefined;
        var got: usize = 0;
        var p = pos;
        while (got < in_n) {
            if (p >= len) return .{};
            if (try self.skipsGlyph(flags, set, buf[p])) {
                p += 1;
                continue;
            }
            const cov = sub + try u16At(self.data, in_off + got * 2);
            if ((try self.coverageIndex(cov, buf[p])) == null) return .{};
            positions[got] = p;
            got += 1;
            p += 1;
        }
        const matched_end = p;
        // Backtrack reads backwards from pos, nearest first: coverage j matches
        // the glyph j positions to the left.
        if (pos < back_n) return .{};
        for (0..back_n) |j| {
            const cov = sub + try u16At(self.data, back_off + j * 2);
            if ((try self.coverageIndex(cov, buf[pos - 1 - j])) == null) return .{};
        }
        // Lookahead starts after the input.
        var ap = matched_end;
        var adone: usize = 0;
        while (adone < ahead_n) {
            if (ap >= len) return .{};
            if (try self.skipsGlyph(flags, set, buf[ap])) {
                ap += 1;
                continue;
            }
            const cov = sub + try u16At(self.data, ahead_off + adone * 2);
            if ((try self.coverageIndex(cov, buf[ap])) == null) return .{};
            adone += 1;
            ap += 1;
        }

        return self.runRecords(rec_off, rec_n, positions[0..got], pos, buf, len, depth);
    }

    /// GPOS type 4, mark-to-base. Each mark glyph offsets itself by
    /// (base anchor - mark anchor) for its class, so a fatha lands where the
    /// font drew that letter's room for one rather than on the baseline.
    ///
    /// The base is the nearest preceding glyph that is not itself a mark, and
    /// the class is the one the mark's MarkRecord names. Anchors are integer
    /// font units: no device tables, no variation deltas.
    pub fn markAttach(self: Layout, script: u32, lang: u32, feat: u32, buf: []const u16, len: usize, out: []Offset) Error!usize {
        var lookups_buf: [256]u16 = undefined;
        var placed: usize = 0;
        for (self.lookupsFor(script, lang, feat, &lookups_buf)) |li| {
            const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, li) * 2);
            var kind = try u16At(self.data, lookup);
            const sub_count = try u16At(self.data, lookup + 4);
            var si: usize = 0;
            while (si < sub_count) : (si += 1) {
                var sub = lookup + try u16At(self.data, lookup + 6 + si * 2);
                kind = try u16At(self.data, lookup);
                if (kind == 9) {
                    kind = try u16At(self.data, sub + 2);
                    sub = sub + try u32At(self.data, sub + 4);
                }
                if (kind == 4) {
                    placed += try self.markBaseSub(sub, buf, len, out);
                } else if (kind == 5) {
                    placed += try self.markLigSub(sub, buf, len, out);
                } else if (kind == 6) {
                    placed += try self.markMarkSub(sub, buf, len, out);
                }
            }
        }
        return placed;
    }

    /// GPOS type 1, single adjustment: the advance or placement of one glyph,
    /// moved on its own. `palt` and `halt` live here, and on a CJK face they
    /// are the difference between ideographs stuck on an em grid and text that
    /// reads as typeset. Format 1 gives every covered glyph the same value;
    /// format 2 gives each its own.
    fn singlePosSub(self: Layout, sub: usize, buf: []const u16, len: usize, out: []Adjust) Error!usize {
        const fmt = try u16At(self.data, sub);
        const cov = sub + try u16At(self.data, sub + 2);
        const vf = try u16At(self.data, sub + 4);
        switch (fmt) {
            1 => {
                const one = try self.readValue(sub + 6, vf);
                var touched: usize = 0;
                for (buf[0..len], out[0..len]) |g, *o| {
                    if ((try self.coverageIndex(cov, g)) == null) continue;
                    o.* = o.*.add(one);
                    touched += 1;
                }
                return touched;
            },
            2 => {
                const count = try u16At(self.data, sub + 6);
                const sz = valueSize(vf);
                var touched: usize = 0;
                for (buf[0..len], out[0..len]) |g, *o| {
                    const ci = (try self.coverageIndex(cov, g)) orelse continue;
                    // A coverage index past the value array is a broken font,
                    // not a reason to read whatever follows the subtable.
                    if (ci >= count) continue;
                    o.* = o.*.add(try self.readValue(sub + 8 + ci * sz, vf));
                    touched += 1;
                }
                return touched;
            },
            else => return 0,
        }
    }

    /// Apply every SinglePos lookup a feature names, adding into `out`.
    ///
    /// Additive rather than overwriting, so two features on one run compose:
    /// `palt` and `halt` are both single adjustments and a caller may ask for
    /// either or both.
    pub fn adjustSingles(self: Layout, script: u32, lang: u32, feat: u32, buf: []const u16, len: usize, out: []Adjust) Error!usize {
        if (out.len < len) return error.Truncated;
        var lookups_buf: [256]u16 = undefined;
        var touched: usize = 0;
        for (self.lookupsFor(script, lang, feat, &lookups_buf)) |li| {
            const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, li) * 2);
            const sub_count = try u16At(self.data, lookup + 4);
            var si: usize = 0;
            while (si < sub_count) : (si += 1) {
                const raw = lookup + try u16At(self.data, lookup + 6 + si * 2);
                var kind = try u16At(self.data, lookup);
                var sub = raw;
                if (kind == 9) {
                    kind = try u16At(self.data, sub + 2);
                    sub = sub + try u32At(self.data, sub + 4);
                }
                if (kind == 1) touched += try self.singlePosSub(sub, buf, len, out);
            }
        }
        return touched;
    }

    /// GPOS type 6, mark-to-mark: the second of two marks stacked on one
    /// letter. The upper mark anchors to the lower one and INHERITS that mark's
    /// offset, so a fatha over a shadda sits on the shadda rather than sinking
    /// to wherever the shadda's own anchor put it.
    fn markMarkSub(self: Layout, sub: usize, buf: []const u16, len: usize, out: []Offset) Error!usize {
        if (try u16At(self.data, sub) != 1) return 0;
        const mark1_cov = sub + try u16At(self.data, sub + 2);
        const mark2_cov = sub + try u16At(self.data, sub + 4);
        const class_count = try u16At(self.data, sub + 6);
        const mark1_array = sub + try u16At(self.data, sub + 8);
        const mark2_array = sub + try u16At(self.data, sub + 10);

        var placed: usize = 0;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const mi = (try self.coverageIndex(mark1_cov, buf[i])) orelse continue;
            // The thing underneath is the nearest preceding glyph of the
            // mark2 set -- another mark, not the letter.
            var j = i;
            var under: ?u16 = null;
            while (j > 0) {
                j -= 1;
                if ((try self.coverageIndex(mark2_cov, buf[j])) != null) {
                    under = try self.coverageIndex(mark2_cov, buf[j]);
                    break;
                }
                // Stop at a letter. A mark two letters back is not under this
                // one, and walking past the base is how a lone kasra ended up
                // inheriting the offset of a sukun on the PREVIOUS letter.
                if ((try self.coverageIndex(mark1_cov, buf[j])) == null) break;
            }
            const mi2 = under orelse continue;

            // Two marks stack only if they sit on the SAME component of the
            // same ligature. HarfBuzz enforces this with a ligature id plus a
            // component index; the component alone is enough here, because the
            // walk above cannot cross a letter. Without it a damma written after
            // lam-lam-heh stacked onto the fatha over the SECOND lam and both
            // got dragged to the first lam's anchor -- which is how a
            // mark-to-ligature placement that had just succeeded was thrown away.
            if (self.lig) |lg| {
                const a: u8 = if (i < lg.len) lg[i] else 0xFF;
                const b: u8 = if (j < lg.len) lg[j] else 0xFF;
                if (a != b) continue;
            }

            // Two marks stack only if they sit on the SAME component of the
            // same ligature. HarfBuzz enforces this with a ligature id plus a
            // component index; the component alone is enough here, because the
            // walk above cannot cross a letter. Without this, a damma written
            // after lam-lam-heh stack onto the fatha over the SECOND lam and
            // both get dragged to the first lam's anchor -- which is how the
            // mark-to-ligature placement that just succeeded got thrown away.
            if (self.lig) |lg| {
                const a: u8 = if (i < lg.len) lg[i] else 0xFF;
                const b: u8 = if (j < lg.len) lg[j] else 0xFF;
                if (a != b) continue;
            }

            const cls = try u16At(self.data, mark1_array + 2 + @as(usize, mi) * 4);
            if (cls >= class_count) continue;
            const mark1_anchor = mark1_array + try u16At(self.data, mark1_array + 2 + @as(usize, mi) * 4 + 2);
            const mark2_anchor = mark2_array + try u16At(self.data, mark2_array + 2 + (@as(usize, mi2) * class_count + cls) * 2);
            if (try u16At(self.data, mark2_anchor) == 0) continue;

            const ax = try i16At(self.data, mark2_anchor + 2);
            const ay = try i16At(self.data, mark2_anchor + 4);
            const bx = try i16At(self.data, mark1_anchor + 2);
            const by = try i16At(self.data, mark1_anchor + 4);
            out[i] = .{ .x = out[j].x + (ax - bx), .y = out[j].y + (ay - by) };
            placed += 1;
        }
        return placed;
    }

    /// GPOS type 5, mark-to-ligature. A mark over a ligature anchors to the
    /// anchor drawn for the COMPONENT it belongs to, not to one anchor for the
    /// whole ligature -- which is why a fatha on lam-alef sits where the alef
    /// left room instead of at the join.
    ///
    /// WHICH component comes from ligature formation, which records one index
    /// per surviving slot (`Layout.lig`). A mark written between two components
    /// attaches to the one it followed -- the reason lam-lam-heh puts its fatha
    /// over the second lam and not over the heh. Where no record exists, the
    /// mark takes the LAST component, which is HarfBuzz's own fallback when its
    /// ligature ids do not match.
    fn markLigSub(self: Layout, sub: usize, buf: []const u16, len: usize, out: []Offset) Error!usize {
        if (try u16At(self.data, sub) != 1) return 0;
        const mark_cov = sub + try u16At(self.data, sub + 2);
        const lig_cov = sub + try u16At(self.data, sub + 4);
        const class_count = try u16At(self.data, sub + 6);
        const mark_array = sub + try u16At(self.data, sub + 8);
        const lig_array = sub + try u16At(self.data, sub + 10);
        const lig_count = try u16At(self.data, lig_array);

        var placed: usize = 0;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const mi = (try self.coverageIndex(mark_cov, buf[i])) orelse continue;
            // Walk back to the ligature: other marks may sit between them.
            var j = i;
            var lig_index: ?u16 = null;
            while (j > 0) {
                j -= 1;
                if ((try self.coverageIndex(mark_cov, buf[j])) != null) continue;
                lig_index = try self.coverageIndex(lig_cov, buf[j]);
                break;
            }
            const li = lig_index orelse continue;
            if (li >= lig_count) continue;

            // MarkRecord: class, then the anchor offset within MarkArray.
            const cls = try u16At(self.data, mark_array + 2 + @as(usize, mi) * 4);
            if (cls >= class_count) continue;
            const mark_anchor = mark_array + try u16At(self.data, mark_array + 2 + @as(usize, mi) * 4 + 2);

            // LigatureAttach: one row per component, one anchor per class in
            // each row, offsets from the LigatureAttach itself.
            const att = lig_array + try u16At(self.data, lig_array + 2 + @as(usize, li) * 2);
            const comp_count = try u16At(self.data, att);
            if (comp_count == 0) continue;
            const recorded: u8 = if (self.lig) |lg| (if (i < lg.len) lg[i] else 0xFF) else 0xFF;
            const comp: u16 = if (recorded == 0xFF or recorded >= comp_count)
                comp_count - 1
            else
                recorded;
            const anchor_off = try u16At(self.data, att + 2 + (@as(usize, comp) * class_count + cls) * 2);
            if (anchor_off == 0) continue;
            const lig_anchor = att + anchor_off;

            const bx = try i16At(self.data, lig_anchor + 2);
            const by = try i16At(self.data, lig_anchor + 4);
            const mx = try i16At(self.data, mark_anchor + 2);
            const my = try i16At(self.data, mark_anchor + 4);
            out[i] = .{ .x = bx - mx, .y = by - my };
            placed += 1;
        }
        return placed;
    }

    fn markBaseSub(self: Layout, sub: usize, buf: []const u16, len: usize, out: []Offset) Error!usize {
        if (try u16At(self.data, sub) != 1) return 0;
        const mark_cov = sub + try u16At(self.data, sub + 2);
        const base_cov = sub + try u16At(self.data, sub + 4);
        const class_count = try u16At(self.data, sub + 6);
        const mark_array = sub + try u16At(self.data, sub + 8);
        const base_array = sub + try u16At(self.data, sub + 10);

        var placed: usize = 0;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const mi = (try self.coverageIndex(mark_cov, buf[i])) orelse continue;
            // Walk back to the base: any number of marks may stack on it.
            var j = i;
            var base_index: ?u16 = null;
            while (j > 0) {
                j -= 1;
                if ((try self.coverageIndex(mark_cov, buf[j])) != null) continue;
                base_index = try self.coverageIndex(base_cov, buf[j]);
                break;
            }
            const bi = base_index orelse continue;

            // MarkRecord: class, then the anchor offset within MarkArray.
            const cls = try u16At(self.data, mark_array + 2 + @as(usize, mi) * 4);
            if (cls >= class_count) continue;
            const mark_anchor = mark_array + try u16At(self.data, mark_array + 2 + @as(usize, mi) * 4 + 2);

            // BaseRecord: one anchor offset per class, within BaseArray.
            const base_anchor = base_array + try u16At(self.data, base_array + 2 + (@as(usize, bi) * class_count + cls) * 2);
            if (try u16At(self.data, base_anchor) == 0) continue;

            const bx = try i16At(self.data, base_anchor + 2);
            const by = try i16At(self.data, base_anchor + 4);
            const mx = try i16At(self.data, mark_anchor + 2);
            const my = try i16At(self.data, mark_anchor + 4);
            out[i] = .{ .x = bx - mx, .y = by - my };
            placed += 1;
        }
        return placed;
    }

    /// Apply one feature at ONE buffer position, which is what a joining form
    /// needs: `init` applies to the letters that take an initial form and to
    /// nothing else. Returns the (possibly changed) buffer length.
    pub fn applyFeatureAt(self: Layout, script: u32, lang: u32, feat: u32, buf: []u16, len: usize, pos: usize) Error!usize {
        if (pos >= len) return len;
        var lookups_buf: [256]u16 = undefined;
        var cur = len;
        for (self.lookupsFor(script, lang, feat, &lookups_buf)) |li| {
            cur = try self.applyLookupAt(li, buf, cur, pos, 0);
        }
        return cur;
    }

    /// Apply one feature at every position, in order.
    pub fn applyFeature(self: Layout, script: u32, lang: u32, feat: u32, buf: []u16, len: usize) Error!usize {
        var lookups_buf: [256]u16 = undefined;
        var cur = len;
        for (self.lookupsFor(script, lang, feat, &lookups_buf)) |li| {
            const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, li) * 2);
            const kind = try u16At(self.data, lookup);
            const flags = try u16At(self.data, lookup + 2);
            const sub_count = try u16At(self.data, lookup + 4);
            const mark_set = try self.markFilteringSet(li);
            // Subtables are ALTERNATIVES, not stages. At each position the
            // first subtable that matches is the one that applies -- even when
            // it records nothing. Running every subtable in turn let Amiri's
            // lookup 48 fall past its deliberate no-op blocker and apply the
            // LamLam form, which preempted the Lellah form in lookup 49.
            var pos: usize = 0;
            while (pos < cur) {
                var applied = false;
                var i: usize = 0;
                while (i < sub_count) : (i += 1) {
                    const sub = lookup + try u16At(self.data, lookup + 6 + i * 2);
                    var real_kind = kind;
                    var real = sub;
                    if (kind == 7) {
                        real_kind = try u16At(self.data, sub + 2);
                        real = sub + try u32At(self.data, sub + 4);
                    }
                    const step = try self.substAt(real_kind, real, buf, cur, pos, 0, flags, mark_set);
                    if (step.hit) {
                        cur = step.len;
                        pos += step.advance;
                        applied = true;
                        break;
                    }
                }
                if (!applied) pos += 1;
            }
        }
        return cur;
    }

    /// Walk `buf[0..len]` applying one subtable at every position.
    fn substPass(self: Layout, kind: u16, sub: usize, buf: []u16, len: usize, flags: u16, mark_set: u16) Error!usize {
        var real_kind = kind;
        var real = sub;
        if (kind == 7) {
            // GSUB Extension: the same unwrap GPOS uses, different type number.
            real_kind = try u16At(self.data, sub + 2);
            real = sub + try u32At(self.data, sub + 4);
        }
        var pos: usize = 0;
        var n = len;
        while (pos < n) {
            const step = try self.substAt(real_kind, real, buf, n, pos, 0, flags, mark_set);
            if (step.hit) {
                n = step.len;
                pos += step.advance;
            } else {
                pos += 1;
            }
        }
        return n;
    }

    /// Apply a SequenceLookupRecord array at matched input positions.
    ///
    /// Shared by every contextual format because the record list is the same
    /// structure in all of them; only how the input positions were established
    /// differs. Format 3, and formats 1 and 2 of lookups 5 and 6, all funnel
    /// their matches through here.
    ///
    /// A nested lookup may change the buffer length, so later target positions
    /// shift by however much the earlier ones moved. `positions` maps each
    /// matched input slot to its buffer index, so a record naming sequence
    /// index i still lands on the glyph it was chosen for after an earlier
    /// record lengthened or shortened the run.
    fn runRecords(
        self: Layout,
        rec_off: usize,
        rec_n: usize,
        positions: []const usize,
        pos: usize,
        buf: []u16,
        len: usize,
        depth: u4,
    ) Error!Step {
        // Advance is a DISTANCE from pos, not the absolute index of the last
        // matched glyph. Returning the absolute index scans correctly only
        // when a match starts at 0, which is how this survived the format 3
        // tests in this file and would have over-scanned in a real face.
        const matched_end = if (positions.len == 0) 0 else positions[positions.len - 1] + 1;
        const advance = if (matched_end > pos) matched_end - pos else 1;
        var cur = len;
        var shift: isize = 0;
        var any: bool = false;
        for (0..rec_n) |r| {
            const seq = try u16At(self.data, rec_off + r * 4);
            const li = try u16At(self.data, rec_off + r * 4 + 2);
            if (seq >= positions.len) continue;
            const target = @as(isize, @intCast(positions[seq])) + shift;
            if (target < 0 or target >= @as(isize, @intCast(cur))) continue;
            const before = cur;
            cur = try self.applyLookupAt(li, buf, cur, @intCast(target), depth + 1);
            shift += @as(isize, @intCast(cur)) - @as(isize, @intCast(before));
            any = true;
        }
        // A record list where every record was out of range changed nothing.
        // Reporting a hit would advance the scan past an untouched position.
        if (!any and cur == len) return .{};
        return .{ .hit = true, .len = cur, .advance = advance };
    }

    const Step = struct { hit: bool = false, len: usize = 0, advance: usize = 1 };

    fn substAt(self: Layout, kind: u16, sub: usize, buf: []u16, len: usize, pos: usize, depth: u4, flags: u16, set: u16) Error!Step {
        // Contextual lookups gate other lookups rather than substituting a
        // glyph, so they do not have a coverage table at offset 2.
        if (kind == 6) return self.chainAt(sub, buf, len, pos, depth, flags, set);
        const gid = buf[pos];
        const cov = sub + try u16At(self.data, sub + 2);
        const idx = (try self.coverageIndex(cov, gid)) orelse return .{};
        switch (kind) {
            1 => {
                // Format 1 maps by delta (a signed add, wrapping 16-bit);
                // format 2 lists the substitutes.
                const fmt = try u16At(self.data, sub);
                const to: u16 = if (fmt == 1)
                    gid +% @as(u16, @bitCast(try i16At(self.data, sub + 4)))
                else blk: {
                    const count = try u16At(self.data, sub + 4);
                    if (idx >= count) return .{};
                    break :blk try u16At(self.data, sub + 6 + @as(usize, idx) * 2);
                };
                if (to == gid) return .{};
                buf[pos] = to;
                return .{ .hit = true, .len = len, .advance = 1 };
            },
            2 => {
                const count = try u16At(self.data, sub + 4);
                if (idx >= count) return .{};
                const seq = sub + try u16At(self.data, sub + 6 + @as(usize, idx) * 2);
                const n = try u16At(self.data, seq);
                if (n == 0) return .{};
                if (len - 1 + n > buf.len) return error.BufferTooSmall;
                if (n > 1) {
                    const tail = len - pos - 1;
                    std.mem.copyBackwards(u16, buf[pos + n .. pos + n + tail], buf[pos + 1 .. pos + 1 + tail]);
                }
                var k: usize = 0;
                while (k < n) : (k += 1) buf[pos + k] = try u16At(self.data, seq + 2 + k * 2);
                return .{ .hit = true, .len = len - 1 + n, .advance = n };
            },
            3 => {
                const count = try u16At(self.data, sub + 4);
                if (idx >= count) return .{};
                const lset = sub + try u16At(self.data, sub + 6 + @as(usize, idx) * 2);
                const n = try u16At(self.data, lset);
                if (n == 0) return .{};
                // Alternate 0 is the designer's first choice.
                const to = try u16At(self.data, lset + 2);
                if (to == gid) return .{};
                buf[pos] = to;
                return .{ .hit = true, .len = len, .advance = 1 };
            },
            4 => {
                const count = try u16At(self.data, sub + 4);
                if (idx >= count) return .{};
                const lset = sub + try u16At(self.data, sub + 6 + @as(usize, idx) * 2);
                const lig_count = try u16At(self.data, lset);
                var l: usize = 0;
                while (l < lig_count) : (l += 1) {
                    const lig = lset + try u16At(self.data, lset + 2 + l * 2);
                    const lig_glyph = try u16At(self.data, lig);
                    const comps = try u16At(self.data, lig + 2);
                    if (comps == 0 or comps > 16) continue;
                    // Where each component actually sits. With IgnoreMarks a
                    // mark between components is stepped over and LEFT IN
                    // PLACE, so the ligature can form without eating it --
                    // which is how الله keeps its shadda.
                    var positions: [16]usize = undefined;
                    positions[0] = pos;
                    var got: usize = 1;
                    var q = pos + 1;
                    while (got < comps) {
                        if (q >= len) break;
                        const want = try u16At(self.data, lig + 4 + (got - 1) * 2);
                        if (buf[q] == want) {
                            positions[got] = q;
                            got += 1;
                            q += 1;
                            continue;
                        }
                        if (try self.skipsGlyph(flags, set, buf[q])) {
                            q += 1;
                            continue;
                        }
                        break;
                    }
                    if (got != comps) continue;
                    buf[pos] = lig_glyph;
                    if (self.lig) |lg| {
                        if (pos < lg.len) lg[pos] = 0;
                    }
                    // Keep everything that was not consumed as a component, so
                    // the stepped-over marks survive in order after the ligature.
                    var write = pos + 1;
                    var r = pos + 1;
                    while (r < len) : (r += 1) {
                        var consumed = false;
                        var c: usize = 1;
                        while (c < comps) : (c += 1) {
                            if (positions[c] == r) {
                                consumed = true;
                                break;
                            }
                        }
                        if (consumed) continue;
                        buf[write] = buf[r];
                        // Remember WHICH component this glyph followed. That is
                        // the whole of what mark-to-ligature needs to pick the
                        // anchor the designer drew under this mark, and it is
                        // knowledge that exists only here: once the components
                        // are gone nothing on the buffer still names them.
                        if (self.lig) |lg| {
                            if (write < lg.len) {
                                var done: u8 = 1; // component 0 sits at `pos`
                                var k: usize = 1;
                                while (k < comps) : (k += 1) {
                                    if (positions[k] < r) done += 1;
                                }
                                lg[write] = done - 1;
                            }
                        }
                        write += 1;
                    }
                    return .{ .hit = true, .len = write, .advance = 1 };
                }
                return .{};
            },
            else => return .{},
        }
    }

    /// Would lookup `flags` step over `gid`?
    ///
    /// A lookup with no flag bits set never skips anything and never touches
    /// GDEF, which is the common case: most lookups carry flag 0.
    fn skipsGlyph(self: Layout, flags: u16, set: u16, gid: u16) Error!bool {
        if (flags & 0x001E == 0) return false;
        const g = self.gdef orelse return false;
        return g.skips(flags, set, gid);
    }

    /// The MarkFilteringSet a lookup names, or 0 when it names none.
    ///
    /// The set index is NOT in the Lookup header. It lives in the optional
    /// tail that follows the SubTable offsets, and it is present only when
    /// lookupFlag UseMarkFilteringSet (0x0010) is set. Reading offset 0x0010
    /// of the lookup as if it were the set index silently picked up the first
    /// subtable's offset instead.
    pub fn markFilteringSet(self: Layout, index: u16) Error!u16 {
        const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, index) * 2);
        const flags = try u16At(self.data, lookup + 2);
        if (flags & 0x0010 == 0) return 0;
        const sub_count = try u16At(self.data, lookup + 4);
        return try u16At(self.data, lookup + 6 + @as(usize, sub_count) * 2);
    }

    /// Lookup type of a lookup index, with Extension wrappers resolved.
    pub fn lookupType(self: Layout, index: u16) Error!u16 {
        const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, index) * 2);
        const kind = try u16At(self.data, lookup);
        if (kind != 9) return kind;
        const sub = lookup + try u16At(self.data, lookup + 6);
        return try u16At(self.data, sub + 2);
    }
};

/// Sort ascending and drop duplicates: feature records may name lookups in any
/// order, and the spec applies them in lookup-list order.
fn sortUnique(items: []u16) []u16 {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const v = items[i];
        var j = i;
        while (j > 0 and items[j - 1] > v) : (j -= 1) items[j] = items[j - 1];
        items[j] = v;
    }
    var n: usize = 0;
    for (items) |v| {
        if (n == 0 or items[n - 1] != v) {
            items[n] = v;
            n += 1;
        }
    }
    return items[0..n];
}

fn inside(base: usize, end: usize, rel: u16) Error!usize {
    const abs = base + rel;
    if (abs + 4 > end) return error.Truncated;
    return abs;
}

fn u16At(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return error.Truncated;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn i16At(b: []const u8, off: usize) Error!i16 {
    if (off + 2 > b.len) return error.Truncated;
    return std.mem.readInt(i16, b[off..][0..2], .big);
}

fn u32At(b: []const u8, off: usize) Error!u32 {
    if (off + 4 > b.len) return error.Truncated;
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

// -- tests -------------------------------------------------------------
//
// Synthetic tables rather than a real face: a fixture states exactly one fact,
// so a failure names the field that broke instead of "Lato's kerning moved".
//
// Layout order matters. Every offset in an OpenType layout table points
// FORWARD, so the tables are emitted in dependency order: header, the three
// lists, the lookup, and only then the lookup's subtable.

const testing = std.testing;

const Builder = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn init() Builder {
        var b: Builder = .{};
        @memset(b.buf[0..], 0);
        return b;
    }
    fn bytes(b: *const Builder) []const u8 {
        return b.buf[0..b.len];
    }
    fn put16(b: *Builder, v: u16) usize {
        const at = b.len;
        std.mem.writeInt(u16, b.buf[at..][0..2], v, .big);
        b.len += 2;
        return at;
    }
    fn put32(b: *Builder, v: u32) usize {
        const at = b.len;
        std.mem.writeInt(u32, b.buf[at..][0..4], v, .big);
        b.len += 4;
        return at;
    }
    fn putTag(b: *Builder, t: *const [4]u8) usize {
        const at = b.len;
        @memcpy(b.buf[at..][0..4], t);
        b.len += 4;
        return at;
    }
    fn patch16(b: *Builder, at: usize, v: usize) void {
        std.mem.writeInt(u16, b.buf[at..][0..2], @intCast(v), .big);
    }
    fn patch32(b: *Builder, at: usize, v: usize) void {
        std.mem.writeInt(u32, b.buf[at..][0..4], @intCast(v), .big);
    }
};

const Header = struct { scr: usize, fea: usize, loo: usize };

fn header(b: *Builder) Header {
    _ = b.put32(0x0001_0000);
    return .{ .scr = b.put16(0), .fea = b.put16(0), .loo = b.put16(0) };
}

/// A lookup whose subtable has not been written yet.
const Shell = struct { slot: usize, lookup: usize };

fn place(b: *Builder, sh: Shell, sub: usize) void {
    b.patch16(sh.slot, sub - sh.lookup);
}

/// One DFLT script, one langsys with no lang record, one `kern` feature, one
/// lookup. Everything the two tests that follow need, and nothing else.
fn shell(b: *Builder, h: Header, lookup_type: u16, fea_tag: *const [4]u8) Shell {
    const scr = b.len;
    b.patch16(h.scr, scr);
    _ = b.put16(1);
    _ = b.putTag("DFLT");
    const srec = b.put16(0);
    const script = b.len;
    b.patch16(srec, script - scr);
    const dls = b.put16(0);
    _ = b.put16(0); // langSysCount
    const langs = b.len;
    b.patch16(dls, langs - script);
    _ = b.put16(0); // lookupOrder: must be 0
    _ = b.put16(0xFFFF); // requiredFeatureIndex: none
    _ = b.put16(1); // featureIndexCount
    _ = b.put16(0); // feature 0, the kern feature below

    const fea = b.len;
    b.patch16(h.fea, fea);
    _ = b.put16(1);
    _ = b.putTag(fea_tag);
    const frec = b.put16(0);
    const feature = b.len;
    b.patch16(frec, feature - fea);
    _ = b.put16(0); // featureParams
    _ = b.put16(1); // lookupIndexCount
    _ = b.put16(0); // lookup 0

    const loo = b.len;
    b.patch16(h.loo, loo);
    _ = b.put16(1);
    const lrec = b.put16(0);
    const lookup = b.len;
    b.patch16(lrec, lookup - loo);
    _ = b.put16(lookup_type);
    _ = b.put16(0); // flag
    _ = b.put16(1); // subtableCount
    return .{ .slot = b.put16(0), .lookup = lookup };
}

/// PairPos format 1 over glyph 5: (5,7) = -80, (5,9) = +25.
fn pair1(b: *Builder) usize {
    const sub = b.len;
    _ = b.put16(1);
    const cov = b.put16(0);
    _ = b.put16(0x0004);
    _ = b.put16(0);
    _ = b.put16(1);
    const setrec = b.put16(0);
    const set = b.len;
    b.patch16(setrec, set - sub);
    _ = b.put16(2);
    _ = b.put16(7);
    _ = b.put16(@bitCast(@as(i16, -80)));
    _ = b.put16(9);
    _ = b.put16(@bitCast(@as(i16, 25)));
    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(5);
    return sub;
}

/// PairPos format 2: left 5 is class 1, rights 7..9 are class 1 of ClassDef2,
/// and the class-0 row carries a real value the way fonts actually use it.
fn pair2(b: *Builder) usize {
    const sub = b.len;
    _ = b.put16(2);
    const cov = b.put16(0);
    _ = b.put16(0x0004);
    _ = b.put16(0);
    const cd1 = b.put16(0);
    const cd2 = b.put16(0);
    _ = b.put16(2);
    _ = b.put16(2);
    // 2x2 matrix: (0,0) = 0, (0,1) = -40, (1,0) = -12, (1,1) = -100
    _ = b.put16(0);
    _ = b.put16(@bitCast(@as(i16, -40)));
    _ = b.put16(@bitCast(@as(i16, -12)));
    _ = b.put16(@bitCast(@as(i16, -100)));

    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(5);

    const cd1abs = b.len;
    b.patch16(cd1, cd1abs - sub);
    _ = b.put16(1);
    _ = b.put16(5);
    _ = b.put16(1);
    _ = b.put16(1);

    const cd2abs = b.len;
    b.patch16(cd2, cd2abs - sub);
    _ = b.put16(2);
    _ = b.put16(1);
    _ = b.put16(7);
    _ = b.put16(9);
    _ = b.put16(1);
    return sub;
}

fn gposPair1(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 2, "kern");
    place(b, sh, pair1(b));
}

fn gposPair2(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 2, "kern");
    place(b, sh, pair2(b));
}

/// SinglePos format 1: -120 advance for everything the coverage names.
fn single1(b: *Builder) usize {
    const sub = b.len;
    _ = b.put16(1);
    const cov = b.put16(0);
    _ = b.put16(0x0004); // valueFormat: xAdvance only
    _ = b.put16(@bitCast(@as(i16, -120)));
    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(5);
    return sub;
}

/// SinglePos format 2: -50 for glyph 5, +70 for glyph 7.
fn single2(b: *Builder) usize {
    const sub = b.len;
    _ = b.put16(2);
    const cov = b.put16(0);
    _ = b.put16(0x0004);
    _ = b.put16(2); // valueCount
    _ = b.put16(@bitCast(@as(i16, -50)));
    _ = b.put16(@bitCast(@as(i16, 70)));
    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(2);
    _ = b.put16(5);
    _ = b.put16(7);
    return sub;
}

fn gposSingle1(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 1, "palt");
    place(b, sh, single1(b));
}

fn gposSingle2(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 1, "halt");
    place(b, sh, single2(b));
}

test "single-1 moves the advance of every covered glyph" {
    var b = Builder.init();
    gposSingle1(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));

    var out: [4]Adjust = @splat(.{});
    const gids = [_]u16{ 5, 6, 5 };
    const n = try l.adjustSingles(tag("DFLT"), 0, tag("palt"), &gids, gids.len, &out);
    // Two of the three are covered; the middle glyph is untouched.
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i16, -120), out[0].x_advance);
    try testing.expectEqual(@as(i16, 0), out[1].x_advance);
    try testing.expectEqual(@as(i16, -120), out[2].x_advance);
    // An advance adjustment, not a move: nothing drags the glyph sideways.
    try testing.expectEqual(@as(i16, 0), out[0].x_placement);
    try testing.expectEqual(@as(i16, 0), out[0].y_advance);
}

test "single-2 gives each covered glyph its own value" {
    var b = Builder.init();
    gposSingle2(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));

    var out: [4]Adjust = @splat(.{});
    const gids = [_]u16{ 5, 6, 7 };
    _ = try l.adjustSingles(tag("DFLT"), 0, tag("halt"), &gids, gids.len, &out);
    try testing.expectEqual(@as(i16, -50), out[0].x_advance);
    try testing.expectEqual(@as(i16, 0), out[1].x_advance);
    try testing.expectEqual(@as(i16, 70), out[2].x_advance);
}

test "adjustments from two features compose instead of overwriting" {
    // The reason the values ADD. A caller applying palt and halt to one run
    // must get the sum, or whichever ran last would silently win.
    var acc: [1]Adjust = @splat(.{ .x_advance = 10 });
    const extra = Adjust{ .x_advance = -7 };
    acc[0] = acc[0].add(extra);
    try testing.expectEqual(@as(i16, 3), acc[0].x_advance);
}

test "a buffer shorter than the run is refused, not written past" {
    var b = Builder.init();
    gposSingle1(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));

    var out: [1]Adjust = @splat(.{});
    const gids = [_]u16{ 5, 5, 5 };
    try testing.expectError(error.Truncated, l.adjustSingles(tag("DFLT"), 0, tag("palt"), &gids, gids.len, &out));
}

test "tag is big-endian, the same as glyfz's" {
    try testing.expectEqual(@as(u32, 0x6B65_726E), tag("kern"));
    try testing.expectEqual(@as(u32, 0x4446_4C54), tag("DFLT"));
}

test "valueSize counts only the record fields it must skip" {
    try testing.expectEqual(@as(usize, 0), valueSize(0));
    try testing.expectEqual(@as(usize, 2), valueSize(0x0004));
    try testing.expectEqual(@as(usize, 8), valueSize(0x000F));
    // Device offsets ride along in the record even though we never follow them.
    try testing.expectEqual(@as(usize, 16), valueSize(0x00FF));
}

test "pair-1 gives a signed adjustment and nothing for an absent pair" {
    var b = Builder.init();
    gposPair1(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));

    var buf: [8]u16 = undefined;
    const lookups = try l.featureLookups(tag("DFLT"), 0, tag("kern"), &buf);
    try testing.expectEqual(@as(usize, 1), lookups.len);

    try testing.expectEqual(@as(i16, -80), l.pairAdjust(lookups, 5, 7).x_advance);
    try testing.expectEqual(@as(i16, 25), l.pairAdjust(lookups, 5, 9).x_advance);
    // Covered left glyph, absent right; then a right glyph with no left coverage.
    try testing.expectEqual(@as(i16, 0), l.pairAdjust(lookups, 5, 8).x_advance);
    try testing.expectEqual(@as(i16, 0), l.pairAdjust(lookups, 6, 7).x_advance);
    try testing.expect(!l.pairAdjust(lookups, 5, 7).isZero());
    try testing.expect(l.pairAdjust(lookups, 6, 7).isZero());
}

test "pair-2 reads class 0 as a row, not as a miss" {
    var b = Builder.init();
    gposPair2(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));

    var buf: [8]u16 = undefined;
    const lookups = try l.featureLookups(tag("DFLT"), 0, tag("kern"), &buf);

    // left 5 -> class 1, right 7 -> class 1
    try testing.expectEqual(@as(i16, -100), l.pairAdjust(lookups, 5, 7).x_advance);
    // left 5 -> class 1, right 3 -> class 0 (the row fonts really kern against)
    try testing.expectEqual(@as(i16, -12), l.pairAdjust(lookups, 5, 3).x_advance);
    // left 8 is uncovered: a class-based subtable still requires coverage.
    try testing.expectEqual(@as(i16, 0), l.pairAdjust(lookups, 8, 7).x_advance);
}

test "an extension lookup is unwrapped, not skipped" {
    var b = Builder.init();
    const h = header(&b);
    const sh = shell(&b, h, 9, "kern");
    const ext = b.len;
    _ = b.put16(1); // extension posFormat
    _ = b.put16(2); // extensionLookupType: the real PairPos
    const inner = b.put32(0);
    const sub = pair1(&b);
    std.mem.writeInt(u32, b.buf[inner..][0..4], @intCast(sub - ext), .big);
    place(&b, sh, ext);

    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));
    var buf: [8]u16 = undefined;
    const lookups = try l.featureLookups(tag("DFLT"), 0, tag("kern"), &buf);
    try testing.expectEqual(@as(u16, 2), try l.lookupType(lookups[0]));
    try testing.expectEqual(@as(i16, -80), l.pairAdjust(lookups, 5, 7).x_advance);
}

test "an offset past the end adjusts nothing instead of panicking" {
    var b = Builder.init();
    const h = header(&b);
    const sh = shell(&b, h, 2, "kern");
    const sub = pair1(&b);
    place(&b, sh, sub);
    // Break the subtable's coverage offset, leaving the header intact.
    std.mem.writeInt(u16, b.buf[sub + 2 ..][0..2], 0xFFF0, .big);

    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));
    var buf: [8]u16 = undefined;
    const lookups = try l.featureLookups(tag("DFLT"), 0, tag("kern"), &buf);
    try testing.expectEqual(@as(usize, 1), lookups.len);
    try testing.expect(l.pairAdjust(lookups, 5, 7).isZero());
}

test "a header whose lists do not fit is refused at init" {
    var b = Builder.init();
    gposPair1(&b);
    try testing.expectError(error.Truncated, Layout.init(b.bytes(), 0, 8));
    var junk: [16]u8 = @splat(0);
    try testing.expectError(error.MissingTable, Layout.init(&junk, 0, 16));
}

test "an absent feature is an empty answer, not an error" {
    var b = Builder.init();
    gposPair1(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));
    var buf: [8]u16 = undefined;
    try testing.expectEqual(@as(usize, 0), (try l.featureLookups(tag("DFLT"), 0, tag("liga"), &buf)).len);
    try testing.expectEqual(@as(usize, 0), (try l.featureLookups(tag("arab"), 0, tag("kern"), &buf)).len);
    // ...but the default policy finds the DFLT one.
    try testing.expectEqual(@as(usize, 1), (try l.featureLookupsDefault(tag("kern"), &buf)).len);
}

/// Two scripts, each with its own `kern` feature and lookup index. Only the
/// indirection is real here: this fixture is about which script is chosen.
fn twoScripts(b: *Builder) void {
    const h = header(b);

    const scr = b.len;
    b.patch16(h.scr, scr);
    _ = b.put16(2);
    _ = b.putTag("DFLT");
    const r0 = b.put16(0);
    _ = b.putTag("latn");
    const r1 = b.put16(0);

    const s0 = b.len;
    b.patch16(r0, s0 - scr);
    const d0 = b.put16(0);
    _ = b.put16(0);
    const ls0 = b.len;
    b.patch16(d0, ls0 - s0);
    _ = b.put16(0);
    _ = b.put16(0xFFFF);
    _ = b.put16(1);
    _ = b.put16(0);

    const s1 = b.len;
    b.patch16(r1, s1 - scr);
    const d1 = b.put16(0);
    _ = b.put16(0);
    const ls1 = b.len;
    b.patch16(d1, ls1 - s1);
    _ = b.put16(0);
    _ = b.put16(0xFFFF);
    _ = b.put16(1);
    _ = b.put16(1);

    const fea = b.len;
    b.patch16(h.fea, fea);
    _ = b.put16(2);
    _ = b.putTag("kern");
    const f0 = b.put16(0);
    _ = b.putTag("kern");
    const f1 = b.put16(0);
    const ft0 = b.len;
    b.patch16(f0, ft0 - fea);
    _ = b.put16(0);
    _ = b.put16(1);
    _ = b.put16(0);
    const ft1 = b.len;
    b.patch16(f1, ft1 - fea);
    _ = b.put16(0);
    _ = b.put16(1);
    _ = b.put16(1);

    const loo = b.len;
    b.patch16(h.loo, loo);
    _ = b.put16(2);
    const lr0 = b.put16(0);
    const lr1 = b.put16(0);
    const look = b.len;
    b.patch16(lr0, look - loo);
    b.patch16(lr1, look - loo);
    _ = b.put16(2);
    _ = b.put16(0);
    _ = b.put16(0);
}

test "the default script policy prefers latn, and DFLT still resolves" {
    var b = Builder.init();
    twoScripts(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));

    var buf: [8]u16 = undefined;
    try testing.expectEqualSlices(u16, &.{1}, try l.featureLookups(tag("latn"), 0, tag("kern"), &buf));
    try testing.expectEqualSlices(u16, &.{0}, try l.featureLookups(tag("DFLT"), 0, tag("kern"), &buf));
    // latn wins when both exist -- DejaVu Sans carries its two real kern
    // lookups under latn and a single class lookup under DFLT.
    try testing.expectEqualSlices(u16, &.{1}, try l.featureLookupsDefault(tag("kern"), &buf));
}

// -- substitution fixtures ---------------------------------------------

/// Single substitution, format 1: glyph 5 becomes glyph 15.
fn gsubSingleDelta(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 1, "liga");
    const sub = b.len;
    _ = b.put16(1);
    const cov = b.put16(0);
    _ = b.put16(@bitCast(@as(i16, 10)));
    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(5);
    place(b, sh, sub);
}

/// Single substitution, format 2: the substitute is listed, not derived.
fn gsubSingleList(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 1, "liga");
    const sub = b.len;
    _ = b.put16(2);
    const cov = b.put16(0);
    _ = b.put16(1); // glyphCount
    _ = b.put16(30); // substitute for the first covered glyph
    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(5);
    place(b, sh, sub);
}

/// Multiple substitution: glyph 5 expands to 7 then 8.
fn gsubMultiple(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 2, "liga");
    const sub = b.len;
    _ = b.put16(1);
    const cov = b.put16(0);
    _ = b.put16(1);
    const seqrec = b.put16(0);
    const seq = b.len;
    b.patch16(seqrec, seq - sub);
    _ = b.put16(2);
    _ = b.put16(7);
    _ = b.put16(8);
    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(5);
    place(b, sh, sub);
}

/// Ligatures: 5+6+7 -> 20, and 5+6 -> 21. The longer record comes first, so a
/// three-glyph sequence must not match the two-glyph rule.
/// A GSUB with two lookups, which is the smallest shape a contextual rule
/// needs: lookup 0 is a single substitution reachable ONLY through the record,
/// lookup 1 is the chaining rule that decides when to call it. The feature
/// lists lookup 1 alone, so nothing substitutes unless the context matches.
fn gsubChain(b: *Builder) void {
    const h = header(b);

    // ScriptList: one DFLT script, one langsys naming feature 0.
    const scr = b.len;
    b.patch16(h.scr, scr);
    _ = b.put16(1);
    _ = b.putTag("DFLT");
    const srec = b.put16(0);
    const script = b.len;
    b.patch16(srec, script - scr);
    const dls = b.put16(0);
    _ = b.put16(0); // LangSysCount
    const langs = b.len;
    b.patch16(dls, langs - script);
    _ = b.put16(0); // LookupOrder
    _ = b.put16(0xFFFF); // ReqFeatureIndex
    _ = b.put16(1); // FeatureIndexCount
    _ = b.put16(0);

    // FeatureList: one 'liga' naming lookup 1 and NOT lookup 0.
    const fea = b.len;
    b.patch16(h.fea, fea);
    _ = b.put16(1);
    _ = b.putTag("liga");
    const frec = b.put16(0);
    const feature = b.len;
    b.patch16(frec, feature - fea);
    _ = b.put16(0); // FeatureParams
    _ = b.put16(1); // LookupIndexCount
    _ = b.put16(1); // lookup 1: the chaining rule

    // LookupList.
    const loo = b.len;
    b.patch16(h.loo, loo);
    _ = b.put16(2);
    const l0rec = b.put16(0);
    const l1rec = b.put16(0);

    // Lookup 0: single substitution, format 1, glyph 10 -> 15.
    const l0 = b.len;
    b.patch16(l0rec, l0 - loo);
    _ = b.put16(1); // lookupType
    _ = b.put16(0); // lookupFlag
    _ = b.put16(1); // subTableCount
    const l0sub = b.put16(0);
    const s0 = b.len;
    b.patch16(l0sub, s0 - l0);
    _ = b.put16(1); // substFormat
    const cov0 = b.put16(0);
    _ = b.put16(@bitCast(@as(i16, 5))); // delta +5
    const covabs0 = b.len;
    b.patch16(cov0, covabs0 - s0);
    _ = b.put16(1); // coverage format 1
    _ = b.put16(1); // glyphCount
    _ = b.put16(10);

    // Lookup 1: chaining contextual, format 3. Input [10], lookahead [20],
    // one record that runs lookup 0 at sequence index 0.
    const l1 = b.len;
    b.patch16(l1rec, l1 - loo);
    _ = b.put16(6);
    _ = b.put16(0);
    _ = b.put16(1);
    const l1sub = b.put16(0);
    const s1 = b.len;
    b.patch16(l1sub, s1 - l1);
    _ = b.put16(3); // substFormat
    _ = b.put16(0); // backtrackGlyphCount
    _ = b.put16(1); // inputGlyphCount
    const icov = b.put16(0);
    _ = b.put16(1); // lookaheadGlyphCount
    const acov = b.put16(0);
    _ = b.put16(1); // substCount
    _ = b.put16(0); // sequenceIndex
    _ = b.put16(0); // lookupListIndex -> lookup 0
    const icovabs = b.len;
    b.patch16(icov, icovabs - s1);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(10);
    const acovabs = b.len;
    b.patch16(acov, acovabs - s1);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(20);
}

fn gsubLigature(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 4, "liga");
    const sub = b.len;
    _ = b.put16(1);
    const cov = b.put16(0);
    _ = b.put16(1);
    const setrec = b.put16(0);
    const set = b.len;
    b.patch16(setrec, set - sub);
    _ = b.put16(2);
    const l0 = b.put16(0);
    const l1 = b.put16(0);

    const lig0 = b.len;
    b.patch16(l0, lig0 - set);
    _ = b.put16(20); // ligature glyph
    _ = b.put16(3); // componentCount, first included
    _ = b.put16(6);
    _ = b.put16(7);

    const lig1 = b.len;
    b.patch16(l1, lig1 - set);
    _ = b.put16(21);
    _ = b.put16(2);
    _ = b.put16(6);

    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(5);
    place(b, sh, sub);
}

test "single substitution maps by delta and by list" {
    var b = Builder.init();
    gsubSingleDelta(&b);
    const d1 = b.bytes();
    const l1 = try Layout.init(d1, 0, @intCast(d1.len));
    var out: [8]u16 = undefined;
    try testing.expectEqual(@as(usize, 1), try l1.substitute(tag("liga"), &.{5}, &out));
    try testing.expectEqual(@as(u16, 15), out[0]);

    var c = Builder.init();
    gsubSingleList(&c);
    const d2 = c.bytes();
    const l2 = try Layout.init(d2, 0, @intCast(d2.len));
    try testing.expectEqual(@as(usize, 1), try l2.substitute(tag("liga"), &.{5}, &out));
    try testing.expectEqual(@as(u16, 30), out[0]);
    // A glyph outside the coverage is left exactly as it was.
    try testing.expectEqual(@as(usize, 1), try l2.substitute(tag("liga"), &.{9}, &out));
    try testing.expectEqual(@as(u16, 9), out[0]);
}

test "multiple substitution grows the sequence in place" {
    var b = Builder.init();
    gsubMultiple(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));
    var out: [8]u16 = undefined;
    const n = try l.substitute(tag("liga"), &.{ 5, 9 }, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u16, &.{ 7, 8, 9 }, out[0..n]);

    // Too little room is an error, never a silent truncation.
    var small: [1]u16 = undefined;
    try testing.expectError(error.BufferTooSmall, l.substitute(tag("liga"), &.{5}, &small));
}

test "ligature substitution takes the longest matching rule first" {
    var b = Builder.init();
    gsubLigature(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));
    var out: [8]u16 = undefined;

    var n = try l.substitute(tag("liga"), &.{ 5, 6, 7, 9 }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u16, &.{ 20, 9 }, out[0..n]);

    // Same first two glyphs, third differs: the two-component ligature applies.
    n = try l.substitute(tag("liga"), &.{ 5, 6, 9 }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u16, &.{ 21, 9 }, out[0..n]);

    // Nothing covered: unchanged, and no growth.
    n = try l.substitute(tag("liga"), &.{ 9, 9 }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u16, &.{ 9, 9 }, out[0..n]);
}

test "a ligature replaces its components with one glyph" {
    var b = Builder.init();
    gsubLigature(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));
    var out: [8]u16 = undefined;
    const n = try l.substitute(tag("liga"), &.{ 5, 6 }, &out);
    // Two components become one glyph: the length has to SHRINK, which is what
    // distinguishes a substitution from a positioning adjustment.
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u16, 21), out[0]);
}

test "a chaining lookup substitutes through the lookup it names" {
    var b = Builder.init();
    gsubChain(&b);
    const l = try Layout.init(b.bytes(), 0, @intCast(b.len));

    var buf = [_]u16{ 10, 20 };
    const n = try l.applyFeature(tag("DFLT"), 0, tag("liga"), &buf, 2);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u16, 15), buf[0]); // 10 -> 15 via lookup 0
    try testing.expectEqual(@as(u16, 20), buf[1]); // untouched
}

test "a chaining lookup whose lookahead fails changes nothing" {
    var b = Builder.init();
    gsubChain(&b);
    const l = try Layout.init(b.bytes(), 0, @intCast(b.len));

    // Lookup 0 is not in the feature, so with the context broken there is
    // nothing left that could substitute the 10.
    var buf = [_]u16{ 10, 30 };
    const n = try l.applyFeature(tag("DFLT"), 0, tag("liga"), &buf, 2);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u16, 10), buf[0]);
    try testing.expectEqual(@as(u16, 30), buf[1]);
}

test "UseMarkFilteringSet skips only the named set, not every mark" {
    // GDEF 1.2 with GlyphClassDef (50 = mark) and one MarkGlyphSet holding
    // only glyph 30. A lookup flagged IgnoreMarks|UseMarkFilteringSet must
    // step over 30 but be BLOCKED by 50 -- the two behave identically under
    // the old proxy, which read UseMarkFilteringSet as "also ignore marks".
    var gd = Builder.init();
    _ = gd.put16(1); // majorVersion
    _ = gd.put16(2); // minorVersion -> MarkGlyphSetsDef exists at +12
    const gGlyphClass = gd.put16(0); // +4
    _ = gd.put16(0); // +6 attachListOffset
    _ = gd.put16(0); // +8 ligCaretListOffset
    const gMarkAttach = gd.put16(0); // +10
    const gSets = gd.put16(0); // +12

    // GlyphClassDef format 1: glyph 50 is a mark.
    const classAt = gd.len;
    gd.patch16(gGlyphClass, classAt);
    _ = gd.put16(1);
    _ = gd.put16(50); // startGlyphID
    _ = gd.put16(1); // glyphCount
    _ = gd.put16(3); // class 3 = mark

    const attachAt = gd.len;
    gd.patch16(gMarkAttach, attachAt);
    _ = gd.put16(1);
    _ = gd.put16(50);
    _ = gd.put16(1);
    _ = gd.put16(2); // mark attach class 2

    // MarkGlyphSets format 1: one set, covering glyph 30 only.
    const setsAt = gd.len;
    gd.patch16(gSets, setsAt);
    _ = gd.put16(1); // format
    _ = gd.put16(1); // setCount
    const covRel = gd.put32(0);
    const covAt = gd.len;
    gd.patch32(covRel, covAt - setsAt);
    _ = gd.put16(1); // coverage format 1
    _ = gd.put16(1);
    _ = gd.put16(30);

    const g = try Gdef.init(gd.bytes(), 0, @intCast(gd.len));
    try testing.expect(try g.isMark(50));
    try testing.expect(!try g.isMark(30)); // in the SET, but not class 3
    try testing.expect(try g.inMarkSet(0, 30));
    try testing.expect(!try g.inMarkSet(0, 50));

    // IgnoreMarks alone: 50 is skipped, 30 is not.
    try testing.expect(try g.skips(0x0008, 0, 50));
    try testing.expect(!try g.skips(0x0008, 0, 30));

    // UseMarkFilteringSet: 30 is skipped, 50 (a mark OUTSIDE the set) is not.
    try testing.expect(try g.skips(0x0010, 0, 30));
    try testing.expect(!try g.skips(0x0010, 0, 50));

    // The two together are the union, which is what the old code collapsed
    // into "any mark is transparent".
    try testing.expect(try g.skips(0x0018, 0, 30));
    try testing.expect(try g.skips(0x0018, 0, 50));

    // A glyph in neither table is never skipped.
    try testing.expect(!try g.skips(0x0018, 0, 7));

    // MarkAttachmentType lives in the high byte of the flag. Glyph 50 is in
    // attach class 2, so a filter asking for class 2 keeps it and any other
    // class skips it.
    try testing.expect(!try g.skips(0x0200, 0, 50));
    try testing.expect(try g.skips(0x0300, 0, 50));
    // A glyph with no attach class is never skipped by this bit.
    try testing.expect(!try g.skips(0x0300, 0, 7));
}

test "UseMarkFilteringSet blocks when GDEF names no sets table" {
    // A lookup flagged 0x0010 against a GDEF with no MarkGlyphSetsDef (v1.0)
    // must skip NOTHING rather than fall back to ignoring marks.
    var gd = Builder.init();
    _ = gd.put16(1);
    _ = gd.put16(0); // minorVersion 0 -> no sets offset at all
    const gGlyphClass = gd.put16(0);
    _ = gd.put16(0);
    _ = gd.put16(0);
    _ = gd.put16(0);
    const classAt = gd.len;
    gd.patch16(gGlyphClass, classAt);
    _ = gd.put16(1);
    _ = gd.put16(50);
    _ = gd.put16(1);
    _ = gd.put16(3);

    const g = try Gdef.init(gd.bytes(), 0, @intCast(gd.len));
    try testing.expect(try g.isMark(50));
    try testing.expect(!try g.skips(0x0010, 0, 50));
    try testing.expect(try g.skips(0x0008, 0, 50)); // but IgnoreMarks still does
}

/// Two chaining lookups in one `liga` feature, each a different format.
///
/// Both run lookup 0, which is a single substitution with delta +5 over glyph
/// 10 -- the same subtable `gsubChain` uses, so the substitution half is known
/// good and only the rule SELECTION differs between the two tests.
///
///   lookup 1, format 1: coverage {50} selects rule set 0. That rule's input is
///                       [50, 60]; record 0 runs lookup 0 at sequence 0.
///                       So [50,60] -> [55,60] and nothing else moves.
///   lookup 2, format 2: coverage {70}, ClassDef says 70 is class 0 and both 80
///                       and 81 are class 1. The rule's input is [class 0,
///                       class 1], so [70,80] and [70,81] both match.
fn gsubChainFormats(b: *Builder) void {
    const h = header(b);

    const scr = b.len;
    b.patch16(h.scr, scr);
    _ = b.put16(1);
    _ = b.putTag("DFLT");
    const srec = b.put16(0);
    const script = b.len;
    b.patch16(srec, script - scr);
    const dls = b.put16(0);
    _ = b.put16(0); // langSysCount
    const langs = b.len;
    b.patch16(dls, langs - script);
    _ = b.put16(0); // lookupOrder
    _ = b.put16(0xFFFF); // requiredFeatureIndex
    _ = b.put16(1); // featureIndexCount
    _ = b.put16(0);

    const fea = b.len;
    b.patch16(h.fea, fea);
    _ = b.put16(1);
    _ = b.putTag("liga");
    const frec = b.put16(0);
    const feature = b.len;
    b.patch16(frec, feature - fea);
    _ = b.put16(0); // featureParams
    _ = b.put16(2); // lookupIndexCount
    _ = b.put16(1); // lookup 1
    _ = b.put16(2); // lookup 2

    const loo = b.len;
    b.patch16(h.loo, loo);
    _ = b.put16(4);
    const l0rec = b.put16(0);
    const l1rec = b.put16(0);
    const l2rec = b.put16(0);
    const l3rec = b.put16(0);

    // Lookup 0: single substitution, delta +5 over glyph 10. The record's
    // sequence index 0 names glyph 50, which this coverage does not hold, so
    // in these two fixtures the record is expected to change NOTHING and the
    // tests assert the match itself via the untouched buffer. Lookup 0 is
    // proven separately by the format-3 test above.
    const l0 = b.len;
    b.patch16(l0rec, l0 - loo);
    _ = b.put16(1); // lookupType
    _ = b.put16(0); // lookupFlag
    _ = b.put16(1); // subTableCount
    const l0sub = b.put16(0);
    const s0 = b.len;
    b.patch16(l0sub, s0 - l0);
    _ = b.put16(1); // substFormat
    const cov0 = b.put16(0);
    _ = b.put16(@bitCast(@as(i16, 5))); // delta +5
    const covabs0 = b.len;
    b.patch16(cov0, covabs0 - s0);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(10);

    // Lookup 1: chaining format 1. Coverage {50}; rule set 0 has one rule whose
    // input is [50, 60] and whose single record names sequence 0. Lookup 0
    // covers 10, not 50, so the substitution is a no-op -- but the rule must
    // still MATCH, which the test proves by substituting through a lookup that
    // does map 50.
    const l1 = b.len;
    b.patch16(l1rec, l1 - loo);
    _ = b.put16(6); // lookupType: chaining
    _ = b.put16(0); // lookupFlag
    _ = b.put16(1); // subTableCount
    const l1sub = b.put16(0);
    const s1 = b.len;
    b.patch16(l1sub, s1 - l1);
    _ = b.put16(1); // substFormat 1
    const f1cov = b.put16(0);
    _ = b.put16(1); // ruleSetCount
    const f1set = b.put16(0);
    const f1setAt = b.len;
    b.patch16(f1set, f1setAt - s1);
    _ = b.put16(1); // ruleCount
    const f1rule = b.put16(0);
    const f1ruleAt = b.len;
    b.patch16(f1rule, f1ruleAt - f1setAt);
    _ = b.put16(2); // glyphCount
    _ = b.put16(1); // seqLookupCount
    _ = b.put16(60); // second input glyph
    _ = b.put16(0); // sequenceIndex
    _ = b.put16(3); // lookupListIndex 3: the one covering 50
    const f1covAt = b.len;
    b.patch16(f1cov, f1covAt - s1);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(50);

    // Lookup 2: chaining format 2. Coverage {70}. ClassDef: 70 -> class 0,
    // 80..81 -> class 1. Rule input is [class 0, class 1], record names
    // sequence 0.
    const l2 = b.len;
    b.patch16(l2rec, l2 - loo);
    _ = b.put16(6);
    _ = b.put16(0);
    _ = b.put16(1);
    const l2sub = b.put16(0);
    const s2 = b.len;
    b.patch16(l2sub, s2 - l2);
    _ = b.put16(2); // substFormat 2
    const f2cov = b.put16(0);
    const f2class = b.put16(0);
    _ = b.put16(1); // classSetCount
    const f2set = b.put16(0);

    const f2classAt = b.len;
    b.patch16(f2class, f2classAt - s2);
    _ = b.put16(2); // ClassDef format 2 (ranges)
    _ = b.put16(2); // classRangeCount
    _ = b.put16(70);
    _ = b.put16(70);
    _ = b.put16(0); // 70 is class 0
    _ = b.put16(80);
    _ = b.put16(81);
    _ = b.put16(1); // 80..81 are class 1

    const f2setAt = b.len;
    b.patch16(f2set, f2setAt - s2);
    _ = b.put16(1); // ruleCount
    const f2rule = b.put16(0);
    const f2ruleAt = b.len;
    b.patch16(f2rule, f2ruleAt - f2setAt);
    _ = b.put16(2); // glyphCount
    _ = b.put16(1); // seqLookupCount
    _ = b.put16(1); // second input CLASS
    _ = b.put16(0); // sequenceIndex
    _ = b.put16(3); // lookupListIndex 3: the one covering 70

    const f2covAt = b.len;
    b.patch16(f2cov, f2covAt - s2);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(70);

    // Lookup 3: single substitution, delta +5, covering 50 and 70. This is the
    // lookup both chaining rules name, so a match is visible as 50 -> 55 and
    // 70 -> 75 rather than as an unchanged buffer.
    const l3 = b.len;
    b.patch16(l3rec, l3 - loo);
    _ = b.put16(1);
    _ = b.put16(0);
    _ = b.put16(1);
    const l3sub = b.put16(0);
    const s3 = b.len;
    b.patch16(l3sub, s3 - l3);
    _ = b.put16(1); // substFormat
    const cov3 = b.put16(0);
    _ = b.put16(@bitCast(@as(i16, 5))); // delta +5
    const covabs3 = b.len;
    b.patch16(cov3, covabs3 - s3);
    _ = b.put16(1);
    _ = b.put16(2);
    _ = b.put16(50);
    _ = b.put16(70);
}

test "chaining format 1 matches a glyph sequence and substitutes through it" {
    var b = Builder.init();
    gsubChainFormats(&b);
    const l = try Layout.init(b.bytes(), 0, @intCast(b.len));

    // Coverage {50} selects rule set 0; the rule's input is [50, 60] and its
    // record runs lookup 3 at sequence 0, which maps 50 -> 55.
    var buf = [_]u16{ 50, 60 };
    const n = try l.applyFeature(tag("DFLT"), 0, tag("liga"), &buf, 2);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u16, 55), buf[0]);
    try testing.expectEqual(@as(u16, 60), buf[1]); // untouched

    // A different second glyph means no rule applies.
    var miss = [_]u16{ 50, 61 };
    _ = try l.applyFeature(tag("DFLT"), 0, tag("liga"), &miss, 2);
    try testing.expectEqual(@as(u16, 50), miss[0]);
}

test "chaining format 2 matches by class, not by glyph id" {
    var b = Builder.init();
    gsubChainFormats(&b);
    const l = try Layout.init(b.bytes(), 0, @intCast(b.len));

    // 70 is class 0 and 80..81 are class 1, so both complete the rule.
    var buf = [_]u16{ 70, 80 };
    _ = try l.applyFeature(tag("DFLT"), 0, tag("liga"), &buf, 2);
    try testing.expectEqual(@as(u16, 75), buf[0]);

    var other = [_]u16{ 70, 81 };
    _ = try l.applyFeature(tag("DFLT"), 0, tag("liga"), &other, 2);
    try testing.expectEqual(@as(u16, 75), other[0]); // same class, same match

    // 82 is in neither class range, so the rule does not complete.
    var miss = [_]u16{ 70, 82 };
    _ = try l.applyFeature(tag("DFLT"), 0, tag("liga"), &miss, 2);
    try testing.expectEqual(@as(u16, 70), miss[0]);
}

test "a contextual match advances by distance, not by absolute index" {
    // Park the match at position 2. Returning the absolute index of the last
    // matched glyph (3) instead of the distance (2) skips a glyph of the run.
    var b = Builder.init();
    gsubChainFormats(&b);
    const l = try Layout.init(b.bytes(), 0, @intCast(b.len));

    var buf = [_]u16{ 99, 98, 50, 60, 50, 60 };
    _ = try l.applyFeature(tag("DFLT"), 0, tag("liga"), &buf, 6);

    try testing.expectEqual(@as(u16, 99), buf[0]); // prefix untouched
    try testing.expectEqual(@as(u16, 55), buf[2]); // first match
    try testing.expectEqual(@as(u16, 55), buf[4]); // second match reached
}

test "format 3 also advances by distance" {
    var b = Builder.init();
    gsubChain(&b);
    const l = try Layout.init(b.bytes(), 0, @intCast(b.len));

    // Format 3 is input [10] lookahead [20]; park it at position 1.
    var buf = [_]u16{ 77, 10, 20 };
    _ = try l.applyFeature(tag("DFLT"), 0, tag("liga"), &buf, 3);
    try testing.expectEqual(@as(u16, 77), buf[0]);
    try testing.expectEqual(@as(u16, 15), buf[1]); // 10 -> 15
}
