# Inkwell

Font decoder and glyph rasteriser for Zig 0.16/0.17. TrueType, CFF and CFF2
outlines; GSUB/GPOS shaping; variable-font instances; COLR colour; Unicode
Variation Sequences. No allocator, no IO, no libc — every buffer is caller-owned.

Basically all of this was written by AI. It exists because a UI library needed
font rendering without a C dependency: outlines decoded and rasterised directly
in Zig, allocations hoisted out into caller memory, masks cached. The
rasteriser is at parity at UI sizes and behind at display sizes; the cache is
where the win is. Both measured, not asserted, below.

## Usage

```zig
var font = try inkwell.Font.init(bytes);           // bytes are yours
var cache = try inkwell.Cache.init(&storage, .{}); // so is the cache's memory
const gid = try font.glyphIndex('A');
const m = try cache.mask(font, gid, 16, .zero);    // hash lookup once warm
```

That sample is a unit test, so it cannot rot quietly.

Two properties are the whole point:

- **No allocator.** There is no `std.mem.Allocator` parameter and no file to
  open. Outlines, edges, coverage and the glyph cache are all caller scratch,
  reused frame to frame. The claim is about who owns memory, not about using none.
- **Masks are cached.** A naive rasteriser allocates, rasterises and frees per
  glyph per draw. A cache hit here is a hash lookup and a slice into caller
  memory, keyed on glyph, scale and subpixel phase.

Inkwell does not lay text out and has no fallback chain. It answers "may a line
break between these two codepoints" (UAX #14); choosing a position from a
measured width needs advances and a box, which stay with the caller.
`Font.pick` answers the fallback question without owning the policy.

## Status

| layer | state |
|---|---|
| sfnt directory, including `ttcf` collections | done |
| `head`, `maxp`, `hhea`, `hmtx`, `OS/2`, `post` | done |
| `cmap` formats 4, 12, and 14 (variation sequences) | done |
| `glyf`/`loca`, simple and composite, `USE_MY_METRICS` | done |
| CFF1 outlines: INDEX, DICT, charstring, cubic→quadratic | done |
| CFF2 outlines, including `blend` against a variation store | done |
| coverage: exact-area sweep, caller-owned buffers | done |
| outline and glyph stroking, with scaled AA ramp | done |
| `name` decoded to UTF-8, with an encoding preference | done |
| `kern` format 0, and GPOS pair kerning (formats 1 and 2) | done |
| GSUB lookups 1–6, including chained context | done |
| GPOS lookups 1, 2, 4, 5, 6, 7, 8, 9 | done |
| Arabic and Thai shaping | done |
| variable axes: `fvar`, `avar`, `gvar`, `HVAR` | done |
| COLRv0 layers with CPAL palettes | done |
| UAX #14 line breaking: 49 classes, LB1-resolved, conformance-tested | done |
| subsetting | done |
| `cmap` formats other than 4, 12, 14 | not implemented |
| GPOS Device tables, GSUB 1.1 FeatureVariations | not implemented |
| vertical metrics: `vhea`, `vmtx`, `VORG` | not implemented |
| hinting, COLRv1, kern formats 2/3 | out of scope |

## Kerning

Two surfaces answering different questions.

`kern()` is the **raw legacy read** — `kern` table, format 0 only. A zero from
it means that table says nothing, not that the designer wanted no adjustment.
Apple's version 1 layout is not read.

`pairAdjust()` reads **GPOS**, where modern fonts keep kerning. PairPos formats
1 and 2 are both needed: Liberation ships only format 1, DejaVu only format 2,
Lato splits one face across both. Extension wrappers are unwrapped.

`Kern` is the entry point that decides: GPOS first, legacy only when the face
has no `kern` feature in GPOS. A face carrying both states it twice, so summing
would double every pair — DejaVu is such a face.

`shape()` folds pair adjustment into its advances. A shaper that returns glyph
ids and leaves kerning to the caller is how two owners apply it twice. Pairing
is adjacent, marks included: lookup flags are not modelled, and Inter's `kern`
feature carries both kinds at once, so skipping marks would answer for a flag
never read.

Verified differentially against fontTools' decode: 95,236 pairs over five
faces, 18,918 non-zero, no disagreements.

Script selection has no text to work from, so it tries `latn`, then DFLT, then
file order — which matters, because DejaVu keeps one class-based lookup under
DFLT and its two real ones under `latn`.

## Variation sequences

`cmap` format 14 is the one format that is **not a codepoint map**. It is keyed
by a pair, and carries two sub-tables that mean opposite things:

- **DefaultUVS** lists sequences needing no substitution — the base glyph *is*
  the answer. A hit must return the base gid, never a miss. Reading it as
  not-found is the classic failure, and it fails silently as notdef.
- **NonDefaultUVS** carries explicit glyph ids, as a flat list of
  `uint24 unicodeValue; uint16 glyphID` records — five bytes per mapping, **not**
  range-compressed.

A font with only format 14 cannot exist usefully: the subtable never answers
"what glyph is `A`", so every base character it references must be mapped by a
format 4 or 12 table. Format 14 is always a passenger.

Tested against real faces via `zig build varseq -Dvarseq=<font>`:
Noto Sans Math (51 mappings, NonDefault only, single selector) and Noto Sans CJK
(both sub-tables). Math is the discriminating test — CJK's one-element mappings
let a wrong stride land on the right byte by accident.

## Names and box metrics

`family`, `style`, and `name` for any id. Names are decoration: a face without
a `name` table still loads and the accessor returns null. The same id is stored
once per encoding, so there is a preference order — Windows Unicode, then the
Unicode platform, then Mac Roman, and Mac Roman only while the bytes are pure
ASCII, because decoding an unimplemented codepage produces a plausible wrong answer.

`os2()` returns `cap_height` and `x_height`, null below version 2. Null rather
than zero, because zero is a legal cap height. DejaVu Sans ships version 1, so
this is the ordinary case.

`hhea` gives one set of vertical metrics; `OS/2` carries three, and on real
faces they disagree — DejaVu Sans is 1556/-492 typographic against 1901/-483 in
`hhea`. Sizing a line by ascender-descender gives a different answer depending
on which you read.

## Scope

`glyf`, CFF and CFF2. An OTTO face is read through `CFF ` when it has one and
`CFF2` when it does not; a face carrying neither is refused rather than
half-loaded.

Three decoding questions have answers the spec settles but a common naive
implementation gets wrong, so they are recorded as decisions rather than
incidental behaviour:

- `cmap` format 4 applies `idDelta` through a non-zero `idRangeOffset`, as the
  spec requires, rather than returning the fetched value unchanged.
- Composite transforms are applied as given, rather than multiplying by each
  column's norm — which would square a uniform scale.
- `SCALED_COMPONENT_OFFSET` is honoured rather than ignored.

All three agree on translate-only composites.

## Checks

```sh
zig build                                     # compile
zig build test                                # unit suite, no font needed
zig build varseq -Dvarseq=/path/font.ttf      # cmap format 14 on a real face
zig build bench  -Doptimize=ReleaseFast -Dfont=/path/font.ttf
zig build fuzz   -Dfont=/path/font.ttf        # malformed input
```

**Unit suite** — coverage graded against brute-force supersampling and
hand-computed shapes, so it is never marked by its own algebra.

**Fuzz** — a truncated face at every 4000th byte plus 20,000 single-bit flips,
deterministic. Every outcome must be a scoped error or a face that still
behaves; a panic, out-of-bounds read, hang, or a face that loads with no glyphs
is a failure. Proven able to fail in both directions: an impossible assertion
turns it red, and running with no font reports *skipped*, not passed.

**Glyph differential** (historic run) on DejaVu Sans:

| check | result |
|---|---|
| metrics | 0 mismatched |
| `cmap` over 0..0x10FFFF | 0 mismatched |
| outlines, 6190 glyphs | 0 mismatched, 0 skipped |
| pixel boxes | 75,036 comparisons, exact |
| coverage, 37,140 rasterisations, 6.74M pixels | max delta 4/255 |
| kerning, 90,000 pairs | 0 mismatched |

Those comparisons were shown capable of failing: a one-unit box shift flagged
6190/6190, a half-pixel phase shift drove coverage delta to 169. Agreement with
a reference implementation proves Inkwell is not *different*, not that it is
*right* — which is why the spec settles arguments.

## Cost

Per glyph, ReleaseFast, 94 printable-ASCII glyphs, best of 40:

| size | raster (ns) | cache hit |
|---|---|---|
| 11 | 2048-2064 | 22.9 ns |
| 16 | 1983-2212 | 15.2 ns |
| 24 | 2380-2399 | 13.4 ns |
| 34 | 3250-3267 | 12.6 ns |
| 48 | 4562-4572 | 11.7 ns |

Honestly: the rasteriser is the expensive part and it scales up with size — a
48px glyph costs roughly twice an 11px one. **The cache is the win.** A hit is
an order of magnitude cheaper than a rasterisation at every size, and at UI
sizes it is cheap enough to make per-frame text drawing a non-issue.

One regression worth recording: `Font.variationId` once took `Font` **by value**
while running on every cache hit; `Font` carries thirteen spans, so each hit
copied it. Hits were 39–152% slower until fixed. The rule is narrow — the copy
only bites where it survives the optimiser, in a method called per hit in the
hot loop. The decode chain still takes `Font` by value deliberately; converting
all nine signatures to `*const Font` was measured and did not help.

## Profiles

| profile | ref | contains |
|---|---|---|
| full | `Zig-0.16`, `main` | outlines, shaping, variations, colour, varseq |
| minimal | `v0.2.1-zig0.17` | Latin TrueType `glyf` decode and rasterise, caches |

The minimal line is frozen: TrueType only, no CFF, no shaping, no variations, no
colour. Take it for the smaller API surface — Zig compiles only reachable code,
so a consumer that never shapes already elides those modules. It buys fewer
types, not a smaller binary.

```zon
.inkwell = .{
    .url = "git+https://github.com/richard-zed/inkwell?ref=Zig-0.16",
    .hash = "...",
},
```

## Caches

Neither allocates; both are carved from a buffer you supply.

`Cache` holds rasterised coverage keyed on glyph, scale and phase, and
partitions its arena by mask size so one display-size glyph cannot evict the
alphabet. `Cache.init` refuses a buffer smaller than the options require. When a
size class fills, that class alone gives way and `stats.flushes` counts it — a
high flush count says the arena is undersized, which is a number to look at
rather than a behaviour to infer.

`Lookup` caches codepoint→glyph index and the *resolved* advance, collapsing the
`USE_MY_METRICS` component walk to once per codepoint. `slots` defaults to 512.

## Licence

See `LICENSE`.
