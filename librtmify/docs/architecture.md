# rtmify-trace: Architecture

## Overview

rtmify-trace is a single-binary CLI tool that reads an XLSX spreadsheet and
produces a Requirements Traceability Matrix (RTM) in one or more output
formats. The codebase is pure Zig 0.15.2 with zero external dependencies —
all XLSX parsing, XML generation, ZIP writing, HTTP, TLS, and PDF rendering
use Zig's standard library.

The tool is structured in three layers:

```
┌─────────────────────────────────────────────────────┐
│  rtmify-trace (main.zig)                            │
│  CLI argument parsing, file I/O, license gate       │
└────────────────────┬────────────────────────────────┘
                     │ imports as "rtmify"
┌────────────────────▼────────────────────────────────┐
│  librtmify (lib.zig)                                │
│  Diagnostics → XLSX parsing → Graph → Rendering     │
│  License verification                               │
│  C ABI exports for native GUI shells                │
└─────────────────────────────────────────────────────┘
```

`build.zig` produces three artifacts from one source tree:
- `rtmify-trace`: the CLI executable
- `librtmify.a`: static library for embedding in GUI shells
- `librtmify.dylib` / `.dll` / `.so`: dynamic library

---

## Module walkthrough

### `graph.zig` — in-memory graph

The graph is the core data structure. Everything else is either populating it
or querying it.

**Node types:** `UserNeed`, `Requirement`, `TestGroup`, `Test`, `Risk`

**Edge types:** `DERIVES_FROM`, `TESTED_BY`, `HAS_TEST`, `MITIGATED_BY`

The `Graph` struct owns an `ArenaAllocator` backed by whatever allocator the
caller supplies. All strings (node IDs, property values, edge IDs) are duped
into the arena on insertion. This means:

- Build the graph with `addNode` / `addEdge`
- Query it with `rtm()`, `risks()`, `nodesMissingEdge()`, `downstream()`
- Free everything at once with `graph.deinit()`

No incremental frees, no dangling pointers. The arena is the right tool here
because the graph is built once, queried, and then discarded.

**Gap detection** is implemented as `nodesMissingEdge(node_type, edge_label)`:
- Orphan requirements: requirements with no `DERIVES_FROM` edge
- Untested requirements: requirements with no `TESTED_BY` edge
- Unmitigated risks: risks with no `MITIGATED_BY` edge
- Unresolved references: cross-reference IDs with no matching node (detected
  during report rendering by checking `graph.getNode(id) == null`)

**`rtm()` query** iterates all `Requirement` nodes and for each emits one
`RtmRow` per test case. A requirement with no test group emits one row with
null test fields. A test group with N tests emits N rows.

---

### `diagnostic.zig` — diagnostics and error codes

All warnings and informational messages produced during parsing and ingestion
flow through a `Diagnostics` struct rather than being printed directly or
silently dropped.

**Error codes** follow a layered numbering scheme:

| Range | Layer |
|---|---|
| E1xx | Filesystem |
| E2xx | Container / ZIP |
| E3xx | XLSX structure |
| E4xx | Tab discovery |
| E5xx | Column mapping |
| E6xx | Row parsing / normalization |
| E7xx | Semantic validation |
| E8xx | Cross-reference resolution |

Each code has a stable title in the `catalog` array and a canonical URL at
`https://rtmify.io/errors/E{code}` that users can look up for more detail.

`Diagnostics` owns an `ArenaAllocator` for message strings and an `ArrayList`
(backed by the caller's allocator) for entries. `printSummary(writer)` emits
all warnings and infos to stderr. `writeJson(path, gpa)` writes the full
entry list as JSON, including `"code"` and `"url"` fields per entry — used
by `--gaps-json`.

---

### `xlsx.zig` — XLSX parser

XLSX is a ZIP archive containing XML files. The public entry point is
`parseValidated(alloc, path, *Diagnostics) ![]SheetData`, which applies
seven defensive layers before returning data. The legacy `parse()` wrapper
is retained for callers that don't need diagnostics.

**Layer 0 — filesystem:** `statFile` to detect missing files, directories,
empty files, files over 500 MB, and wrong extensions (`.xls`, `.csv`, `.ods`).

**Layer 1 — magic bytes:** first 4 bytes checked before ZIP parsing.
`D0 CF 11 E0` → OLE2 (Excel 97-2003, re-save as .xlsx). `50 4B` required for
ZIP. Non-ZIP content scanned for `<html`/`<table` → HTML export. ODS `mimetype`
entry detection. `[Content_Types].xml` scanned for xlsb/xlsm markers.

**Layer 2 — ZIP / OOXML structure:**
- Path traversal (`../`) in ZIP entries → warn + skip
- Encrypted ZIP entries → hard error
- ZIP bomb check: uncompressed > 100× compressed AND > 1 GB → hard error
- Missing `[Content_Types].xml` → hard error
- Missing `xl/workbook.xml` → hard error
- Missing `xl/sharedStrings.xml` → info + treat all cells as inline strings

**ZIP traversal** uses `std.zip.Iterator`. No full decompression of unused
entries.

**XML parsing** uses `std.xml` streaming tokenizer (no DOM). Each sheet is
parsed row by row, cell by cell. Cell values are shared strings, inline
strings (`t="inlineStr"`), formula string results (`t="str"`), or formula
errors (`#REF!`, `#N/A`, etc. — warned and treated as empty).

**`normalizeCell`** is a pure function applied to every extracted cell value:
trims whitespace, strips BOM and zero-width characters, converts NBSP and
smart quotes to ASCII equivalents, collapses runs of spaces, maps line breaks
and tabs to spaces.

Key gotchas:
- Self-closing cells (`<c r="X" s="N"/>`) have no value — detected by checking
  if `>` was preceded by `/`.
- Shared string values must be duped before the shared string table is freed.
- Google Sheets and LibreOffice produce slightly different XML than Excel;
  the parser handles both.

The parser returns `[]SheetData` — a flat array of named sheets, each holding
a `[]Row` of `[][]const u8` cells. Column order is preserved; header matching
happens in `schema.zig`.

---

### `schema.zig` — spreadsheet ingestion

Maps the raw `SheetData` from `xlsx.zig` onto `Graph` nodes and edges. The
public entry point is `ingestValidated(g, sheets, *Diagnostics) !IngestStats`.
The legacy `ingest()` wrapper is retained for callers that don't need
diagnostics. `IngestStats` carries counts of each node type ingested.

**Layer 3 — tab discovery (`resolveTab`):**

Tabs are matched in four tiers, most-specific first:

1. Case-insensitive exact match
2. Known synonym list (e.g. "Reqs", "Design Inputs", "FMEA", "V&V")
3. Substring match — longest match wins
4. Levenshtein distance ≤ 2 against the primary tab name (15-line DP, stack-allocated)

Synonym and fuzzy matches emit an INFO diagnostic. Two tabs matching the same
tier at equal priority → `AmbiguousTabMatch` hard error. `Requirements` tab
not found at any tier → `RequirementsTabNotFound` hard error. User Needs,
Tests, and Risks tabs are optional — their absence emits INFO only.

**Layer 4 — column mapping (`resolveCol`):**

Each expected column is matched against the header row using the same tiered
approach with full synonym lists per field (e.g. "Req ID", "Requirement Number",
"Item ID" all map to the ID column). Two headers matching the same field →
leftmost wins + WARN. If no ID column is found by header, a heuristic scans
all columns for one where the majority of data cells match `/^[A-Z]+-[0-9]+$/`
— used + WARN. Heuristic also fails → `IDColumnNotFound` hard error.

**Layer 5 — row normalization:**

- `normalizeId`: calls `normalizeCell`, then strips parenthetical suffixes
  (`"REQ-001 (old)"` → `"REQ-001"`) and leading/trailing hyphens, uppercases
- `isSectionDivider`: silent skip for decorative rows (empty ID, short or
  all-caps content, `---`/`===` separators)
- `parseNumericField`: maps textual severity/likelihood values (`"High"` → `"4"`,
  roman numerals, etc.); warns on fractional or unrecognized values
- `splitIds`: splits multi-value reference cells on `,`, `;`, `/`, `\n`, `\r`, `\t`
- `isBlankEquivalent`: treats `"n/a"`, `"tbd"`, `"—"`, `"none"` as intentionally empty
- Duplicate ID detection: per-tab `StringHashMap` — duplicate → WARN + skip
- Empty ID with content present → WARN + skip

Ingestion order matters for edge resolution — edges are only created if both
endpoints exist:

1. User Needs (nodes only)
2. Tests (TestGroup + Test nodes, `HAS_TEST` edges)
3. Requirements (Requirement nodes, `DERIVES_FROM` and `TESTED_BY` edges)
4. Risks (Risk nodes, `MITIGATED_BY` edges)

**Layer 6 — semantic validation (`semanticValidate`):**

Called at the end of `ingestValidated` against the fully-built graph.

Requirement checks (WARN):
- Empty or very short statement (< 10 chars)
- No "shall" keyword
- Multiple "shall" → compound requirement
- Vague words ("appropriate", "adequate", "user-friendly", "fast", etc.)
- Status = "obsolete" but has active `DERIVES_FROM` or `TESTED_BY` edges

Risk checks (WARN):
- Severity present but likelihood absent (or vice versa)
- `sev × lik > 12` with no mitigation
- Residual score exceeds initial score
- Residual values present but initial values absent

Test checks (WARN):
- TestGroup with no `HAS_TEST` edges

**Layer 7 — cross-reference resolution (`checkCrossRef`):**

Applied before every `addEdge` call. For each token from `splitIds`:
- `isBlankEquivalent` → skip silently
- Node not found in graph → WARN with "Available IDs" hint; edge added anyway
  to preserve traceability intent
- Node found but wrong type (e.g. `REQ-` prefix in a User Need source field) → WARN

---

### `render_md.zig` — Markdown renderer

Straightforward: iterates graph data, writes pipe-delimited tables. All
sections are sorted deterministically by ID before rendering so output is
stable across hash-map iteration order.

Gap rows are prefixed with `⚠`. Unresolved references are shown inline as
`⚠ UNRESOLVED: <id>`. The Gap Summary section counts each gap type separately.

---

### `render_docx.zig` — DOCX renderer

DOCX is a ZIP archive of XML files. The renderer generates all XML in memory
and writes it as a ZIP. Relevant files produced:

- `[Content_Types].xml` — MIME type declarations
- `_rels/.rels` — root relationships
- `word/_rels/document.xml.rels` — document relationships
- `word/styles.xml` — paragraph and table styles
- `word/document.xml` — the actual content

**ZIP writing** uses Zig's `std.compress.flate` for deflate compression. The
renderer implements its own minimal ZIP writer (local file headers, central
directory, end-of-central-directory record) since `std.zip` only provides a
reader in 0.15.2. `[Content_Types].xml` is stored uncompressed; all other
parts are deflated.

**Column widths** are specified in DXA (twentieths of a point). US Letter with
1-inch margins gives 9360 DXA of usable width. Each table uses proportional
column widths tuned to the content type (narrow ID columns, wide statement
columns).

Gap rows use yellow cell shading (`FFFF00`). Page numbers are placed in a
footer via `<w:fldChar>` / `<w:instrText>PAGE</w:instrText>`.

---

### `render_pdf.zig` — PDF renderer

Direct PDF 1.4 generation without any library. The renderer uses a two-phase
approach:

**Phase 1 — layout (PageBuilder):**

`PageBuilder` maintains a y-cursor and a list of page content streams. Each
page's content is buffered as a `[]u8`. When a row would overflow the bottom
margin, a new page is started automatically. Text is placed with absolute
coordinates using PDF `BT` / `ET` operators.

**Phase 2 — assembly (writePdf):**

`writePdf` serialises the PDF object tree with precise byte offsets tracked
via a position counter passed to every write call. The cross-reference (xref)
table requires exact byte positions for every object — the two-phase approach
ensures all content stream lengths are known before assembly begins.

**Object numbering:**
```
1  Catalog
2  Pages (parent of all page objects)
3  F1 font resource (Helvetica)
4  F2 font resource (Helvetica-Bold)
5..4+N       page objects (one per page)
5+N..4+2N    content stream objects (one per page)
```

**Helvetica AFM metrics** are compiled into a 256-entry `u16` lookup table at
comptime. Glyph widths are used to clip cell text to fit column widths rather
than wrapping (tables have fixed column widths; wrapping would require
two-pass layout).

**PDF string escaping:** `(`, `)`, and `\` are backslash-escaped. Non-ASCII
UTF-8 characters are substituted with ASCII equivalents (em dash → `-`,
`→` → `->`, `⚠` → `!`).

---

### `license.zig` — LemonSqueezy license verification

**Activation flow:**

1. `rtmify-trace --activate <key>` calls `license.activate(gpa, .{}, key)`
2. Computes a machine fingerprint: SHA-256 of hostname + OS tag, hex-encoded
3. POSTs to `https://api.lemonsqueezy.com/v1/licenses/activate`
4. On success, writes `~/.rtmify/license.json` with the activation record

**Startup check:**

`license.check(gpa, .{})` runs three layers of verification:

1. **Fingerprint** — recomputes `machineFingerprint()` and compares it to the
   stored value. Mismatch → `fingerprint_mismatch`. This prevents copying
   `license.json` to another machine.
2. **Expiry** — `checkRecord` compares `expires_at` against `now`. Perpetual
   licenses (`expires_at: null`) never expire. A 30-day grace period applies
   to subscription licenses after expiration.
3. **Periodic re-validation** — if `last_validated_at` is null or more than 7
   days ago, the tool POSTs to `https://api.lemonsqueezy.com/v1/licenses/validate`.
   On success, `last_validated_at` is updated in the cache. On network failure,
   a 30-day offline grace period applies; beyond that the tool returns
   `not_activated`.

`Options.now` overrides the current timestamp in tests, allowing all
time-dependent paths to be exercised without real network calls or sleeping.

**Machine fingerprint:** SHA-256 of hostname + null byte + OS tag string.
Platform-specific hostname retrieval:
- POSIX: `std.posix.gethostname`
- Windows: `GetComputerNameA` via `extern "kernel32"`

**Cache path:** `~/.rtmify/license.json` (POSIX) or
`%USERPROFILE%\.rtmify\license.json` (Windows). The `Options.dir` override
redirects I/O to an arbitrary path — used in tests to avoid touching the real
home directory.

**HTTP:** `std.http.Client.fetch` with `std.Io.Writer.Allocating` to capture
the response body. TLS is handled by Zig's built-in TLS implementation; no
system TLS dependency.

---

### `main.zig` — CLI entry point

`parseArgs(tokens: []const []const u8) ParseError!Args` is a pure function
that takes a flat token slice (not including argv[0]). This makes it fully
testable without spawning a process.

`run(gpa, args) !u8` contains all I/O logic and returns an exit code. `main()`
just calls `run` and passes the result to `std.posix.exit`.

**Exit codes:**
| Code | Meaning |
|---|---|
| 0 | success |
| 1 | input error (file not found, bad XLSX, missing tabs) |
| 2 | license error (not activated, expired, revoked) |
| 3 | output error (cannot write destination) |
| N | gap count (with `--strict` only, N ≥ 1) |

---

### `lib.zig` — C ABI surface

`lib.zig` serves two roles:

1. **Module re-exports** for `main.zig` (which imports `lib.zig` as "rtmify")
2. **C ABI exports** for native GUI shells (Swift, C#, etc.)

**`RtmifyGraph`** is a heap-allocated struct containing a
`GeneralPurposeAllocator` and a `Graph`. It is allocated via
`std.heap.page_allocator` so it has a stable address independent of the
caller's memory model.

**Last-error buffer** is a `threadlocal [512]u8`. Every C ABI function that
can fail writes a human-readable message before returning a non-zero status.
`rtmify_last_error()` returns a `[*:0]const u8` pointer directly into this
buffer. `rtmify_warning_count()` returns the number of WARN-level diagnostics
emitted during the most recent `rtmify_load` call.

**Status codes:**
```c
RTMIFY_OK             = 0
RTMIFY_ERR_FILE_NOT_FOUND = 1
RTMIFY_ERR_INVALID_XLSX   = 2
RTMIFY_ERR_MISSING_TAB    = 3
RTMIFY_ERR_LICENSE        = 4
RTMIFY_ERR_OUTPUT         = 5
```

---

## Memory model

| Component | Allocator | Lifetime |
|---|---|---|
| Graph nodes + edges | `ArenaAllocator` inside `Graph` | freed by `graph.deinit()` |
| XLSX parse data | temp `ArenaAllocator` in `rtmify_load` | freed after `schema.ingestValidated` returns |
| Diagnostics messages | `ArenaAllocator` inside `Diagnostics` | freed by `diag.deinit()` |
| Diagnostics entries list | caller's `gpa` | freed by `diag.deinit()` |
| PDF page streams | `ArenaAllocator` in `renderPdf` | freed when `renderPdf` returns |
| DOCX XML buffers | `ArenaAllocator` in `renderDocx` | freed when `renderDocx` returns |
| C ABI handle | `page_allocator` | freed by `rtmify_free` |
| License cache strings | `gpa` passed to `readCache` | caller frees |

---

## Testing

All tests live in `test` blocks within each source file. Run with:

```sh
zig build test
```

The test suite has 131 tests covering:
- Graph construction, edge idempotency, gap detection, BFS traversal
- XLSX parsing (inline strings, shared strings, self-closing cells,
  formula errors, normalizeCell variants)
- Diagnostics: add/count, printSummary format, writeJson structure,
  catalog completeness, lookupTitle
- Schema ingestion: resolveTab (exact, synonym, substring, fuzzy),
  resolveCol (synonym, heuristic), normalizeId, isSectionDivider,
  duplicate ID detection, parseNumericField, splitIds, isBlankEquivalent,
  semantic validation checks, cross-reference resolution
- Markdown, DOCX, and PDF rendering (content checks, not golden files)
- License: JSON round-trip, cache read/write/remove, expiry logic,
  fingerprint mismatch, re-validation skipped when recently validated
- CLI argument parsing (all flags including `--gaps-json`, error cases)
- C ABI: `rtmify_load` bad path, `rtmify_gap_count` empty and gapped graphs

No mocking. Tests use `testing.tmpDir()` for filesystem I/O, `Options.now`
to control timestamps in license tests, and build small graphs directly in
memory for render tests. Network calls (LemonSqueezy) are not exercised in
unit tests — re-validation is bypassed by setting `last_validated_at` to a
recent timestamp.

---

## Cross-compilation

Zig's built-in cross-compiler produces all targets from one machine:

```sh
zig build release
```

The release step in `build.zig` iterates `release_targets` and for each:
1. Resolves the target query (`std.Target.Query.parse`)
2. Creates an exe compile step at `ReleaseSafe`
3. Installs the output to `zig-out/release/` with the platform-named filename

Linux targets use the `musl` ABI suffix (`x86_64-linux-musl`) to produce
fully static binaries with no glibc dependency.

Windows targets link `kernel32` implicitly (used for `GetComputerNameA` in
`license.zig`). No other Windows system libraries are required.
