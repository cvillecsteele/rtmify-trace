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
│  XLSX parsing → Graph → Report rendering            │
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

### `xlsx.zig` — XLSX parser

XLSX is a ZIP archive containing XML files. The parser does two things:

1. **ZIP traversal** — reads the central directory, extracts named entries by
   path using `std.zip.Iterator`. No full decompression of unused entries.

2. **XML parsing** — uses `std.xml` streaming tokenizer (no DOM). Each sheet
   is parsed row by row, cell by cell. Cell values are either inline strings
   or indices into the shared strings table.

Key gotchas discovered during implementation:

- Self-closing cells (`<c r="X" s="N"/>`) have no value — detected by checking
  if the `>` was preceded by `/`.
- Shared string values must be duped before the shared string table is freed.
- Google Sheets and LibreOffice produce slightly different XML structure than
  Excel; the parser handles both.

The parser returns `[]SheetData` — a flat array of named sheets, each holding
a `[]Row` of `[][]const u8` cells. Column order is preserved as-is; header
matching happens in `schema.zig`.

---

### `schema.zig` — spreadsheet ingestion

Maps the raw `SheetData` from `xlsx.zig` onto `Graph` nodes and edges.

Ingestion order matters for edge resolution — edges are only created if both
endpoints exist. The order is:

1. User Needs (nodes only)
2. Tests (TestGroup + Test nodes, `HAS_TEST` edges)
3. Requirements (Requirement nodes, `DERIVES_FROM` and `TESTED_BY` edges)
4. Risks (Risk nodes, `MITIGATED_BY` edges)

Column lookup is by header name (case-insensitive), so column reordering in
the template does not break ingestion. Missing optional columns are treated as
empty. Unresolved cross-references (ID present but target node missing) are
silently skipped — they surface as gaps in the output report.

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

`license.check(gpa, .{})` reads the cache, parses it, and calls `checkRecord`
which compares `expires_at` (if present) against `now + GRACE_PERIOD_SECS`.
No network call on normal runs.

**Grace period:** 30 days past subscription expiration before the tool stops
running. Perpetual licenses (`expires_at: null`) never expire.

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
buffer.

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
| XLSX parse data | temp `ArenaAllocator` in `rtmify_load` | freed after `schema.ingest` returns |
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

The test suite has 71 tests covering:
- Graph construction, edge idempotency, gap detection, BFS traversal
- XLSX parsing (inline strings, shared strings, self-closing cells)
- Schema ingestion and edge resolution
- Markdown, DOCX, and PDF rendering (content checks, not golden files)
- License record JSON round-trip, cache read/write/remove, expiry logic
- CLI argument parsing (all flags, error cases)
- C ABI: `rtmify_load` bad path, `rtmify_gap_count` empty and gapped graphs

No mocking. Tests use `testing.tmpDir()` for filesystem I/O and build
small graphs directly in memory for render tests. Network calls (LemonSqueezy)
are not exercised in unit tests.

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
