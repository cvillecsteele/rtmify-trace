/// XLSX parser for RTMify Trace.
///
/// Reads an XLSX file (ZIP + XML) and returns the worksheet rows as
/// string arrays. No third-party libraries; uses only Zig stdlib.
///
/// Memory: all returned data is allocated with the provided allocator.
/// Use an ArenaAllocator and deinit the arena when done.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// One row from a worksheet. cells[col] is the string value (empty = "").
/// Indexed 0-based (0=A, 1=B, …). Owned by the allocator passed to parse().
pub const Row = []const []const u8;

/// Parsed data from one worksheet.
/// rows[0]  = header row (column titles).
/// rows[1…] = data rows with at least one non-empty cell.
pub const SheetData = struct {
    name: []const u8,
    rows: []const Row,
};

// ---------------------------------------------------------------------------
// Top-level parse
// ---------------------------------------------------------------------------

pub fn parse(allocator: Allocator, path: []const u8) ![]SheetData {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = file.reader(&read_buf);

    // --- enumerate ZIP central directory ---
    const Entry = struct {
        name: []u8,
        file_offset: u64,
        compressed_size: u64,
        uncompressed_size: u64,
        method: std.zip.CompressionMethod,
        header_zip_offset: u64,
        filename_len: u32,
    };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    var iter = try std.zip.Iterator.init(&fr);
    var name_buf: [512]u8 = undefined;
    while (try iter.next()) |ce| {
        if (ce.filename_len > name_buf.len) continue;
        try fr.seekTo(ce.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try fr.interface.readSliceAll(name_buf[0..ce.filename_len]);
        const nm = try allocator.dupe(u8, name_buf[0..ce.filename_len]);
        try entries.append(allocator, .{
            .name = nm,
            .file_offset = ce.file_offset,
            .compressed_size = ce.compressed_size,
            .uncompressed_size = ce.uncompressed_size,
            .method = ce.compression_method,
            .header_zip_offset = ce.header_zip_offset,
            .filename_len = ce.filename_len,
        });
    }

    // Helper: find an entry by exact name
    const findEntry = struct {
        fn f(es: []const Entry, name: []const u8) ?Entry {
            for (es) |e| if (std.mem.eql(u8, e.name, name)) return e;
            return null;
        }
    }.f;

    // --- shared strings ---
    const ss_ent = findEntry(entries.items, "xl/sharedStrings.xml") orelse
        return error.MissingSharedStrings;
    const ss_xml = try extract(&fr, ss_ent.file_offset, ss_ent.compressed_size,
        ss_ent.uncompressed_size, ss_ent.method, allocator);
    defer allocator.free(ss_xml);
    const shared = try parseSharedStrings(ss_xml, allocator);
    defer {
        for (shared) |s| allocator.free(s);
        allocator.free(shared);
    }

    // --- workbook + rels → sheet name → relative file path ---
    const wb_ent = findEntry(entries.items, "xl/workbook.xml") orelse return error.InvalidXlsx;
    const wb_xml = try extract(&fr, wb_ent.file_offset, wb_ent.compressed_size,
        wb_ent.uncompressed_size, wb_ent.method, allocator);
    defer allocator.free(wb_xml);

    const rl_ent = findEntry(entries.items, "xl/_rels/workbook.xml.rels") orelse return error.InvalidXlsx;
    const rl_xml = try extract(&fr, rl_ent.file_offset, rl_ent.compressed_size,
        rl_ent.uncompressed_size, rl_ent.method, allocator);
    defer allocator.free(rl_xml);

    var sheet_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = sheet_map.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        sheet_map.deinit();
    }
    try parseWorkbookAndRels(wb_xml, rl_xml, allocator, &sheet_map);

    // --- parse the four data sheets ---
    const wanted = [_][]const u8{ "User Needs", "Requirements", "Tests", "Risks" };
    var result: std.ArrayList(SheetData) = .empty;

    for (wanted) |sname| {
        const rel_path = sheet_map.get(sname) orelse continue;

        var full_buf: [64]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "xl/{s}", .{rel_path}) catch continue;

        const ws_ent = findEntry(entries.items, full) orelse continue;
        const ws_xml = try extract(&fr, ws_ent.file_offset, ws_ent.compressed_size,
            ws_ent.uncompressed_size, ws_ent.method, allocator);
        defer allocator.free(ws_xml);

        const rows = try parseWorksheet(ws_xml, shared, allocator);
        if (rows.len == 0) continue;

        try result.append(allocator, .{
            .name = try allocator.dupe(u8, sname),
            .rows = rows,
        });
    }

    return result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// ZIP extraction
// ---------------------------------------------------------------------------

fn extract(
    fr: *std.fs.File.Reader,
    file_offset: u64,
    compressed_size: u64,
    uncompressed_size: u64,
    method: std.zip.CompressionMethod,
    allocator: Allocator,
) ![]u8 {
    try fr.seekTo(file_offset);
    const lh = try fr.interface.takeStruct(std.zip.LocalFileHeader, .little);
    if (!std.mem.eql(u8, &lh.signature, &std.zip.local_file_header_sig))
        return error.InvalidXlsx;

    const data_off = file_offset +
        @as(u64, @sizeOf(std.zip.LocalFileHeader)) +
        @as(u64, lh.filename_len) +
        @as(u64, lh.extra_len);
    try fr.seekTo(data_off);

    _ = compressed_size; // used implicitly by the reader position

    const buf = try allocator.alloc(u8, @intCast(uncompressed_size));
    errdefer allocator.free(buf);

    var fw = std.Io.Writer.fixed(buf);

    switch (method) {
        .store => {
            fr.interface.streamExact64(&fw, uncompressed_size) catch return error.ExtractionFailed;
        },
        .deflate => {
            var flate_buf: [flate.max_window_len]u8 = undefined;
            var dec = flate.Decompress.init(&fr.interface, .raw, &flate_buf);
            dec.reader.streamExact64(&fw, uncompressed_size) catch return error.ExtractionFailed;
        },
        else => return error.UnsupportedCompression,
    }

    return buf;
}

// ---------------------------------------------------------------------------
// XML helpers
// ---------------------------------------------------------------------------

/// Return the value of attribute `name="value"` in a tag fragment.
fn attrVal(tag: []const u8, name: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "{s}=\"", .{name}) catch return null;
    const pos = std.mem.indexOf(u8, tag, search) orelse return null;
    const start = pos + search.len;
    const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
    return tag[start..end];
}

/// Convert an XLSX cell reference column letters to a 0-based index.
/// "A1" → 0, "B2" → 1, "Z1" → 25, "AA1" → 26.
fn colIdx(cell_ref: []const u8) ?usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < cell_ref.len and cell_ref[i] >= 'A' and cell_ref[i] <= 'Z') : (i += 1) {
        col = col * 26 + (cell_ref[i] - 'A' + 1);
    }
    if (i == 0) return null;
    return col - 1;
}

/// Unescape the five predefined XML entities.
fn xmlUnescape(src: []const u8, allocator: Allocator) ![]const u8 {
    if (std.mem.indexOf(u8, src, "&") == null) return allocator.dupe(u8, src);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '&') {
            if (std.mem.startsWith(u8, src[i..], "&amp;")) { try out.append(allocator, '&'); i += 5; continue; }
            if (std.mem.startsWith(u8, src[i..], "&lt;"))  { try out.append(allocator, '<'); i += 4; continue; }
            if (std.mem.startsWith(u8, src[i..], "&gt;"))  { try out.append(allocator, '>'); i += 4; continue; }
            if (std.mem.startsWith(u8, src[i..], "&quot;")){ try out.append(allocator, '"'); i += 6; continue; }
            if (std.mem.startsWith(u8, src[i..], "&apos;")){ try out.append(allocator, '\''); i += 6; continue; }
        }
        try out.append(allocator, src[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// sharedStrings.xml parser
// ---------------------------------------------------------------------------

/// Parse xl/sharedStrings.xml → slice of string slices (one per <si>).
/// Rich text: concatenates all <t>…</t> within each <si>.
fn parseSharedStrings(xml: []const u8, allocator: Allocator) ![][]const u8 {
    var strings: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;

    while (std.mem.indexOf(u8, xml[pos..], "<si>")) |rel| {
        const si_start = pos + rel;
        const si_end_rel = std.mem.indexOf(u8, xml[si_start..], "</si>") orelse break;
        const si_end = si_start + si_end_rel;
        const si = xml[si_start + 4 .. si_end];

        // Collect text from all <t …>…</t> within the <si>
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);

        var sp: usize = 0;
        while (sp < si.len) {
            // Find "<t" followed immediately by ">" or " " (not "<tbl", "<tr", etc.)
            const t_rel = std.mem.indexOf(u8, si[sp..], "<t") orelse break;
            const t_abs = sp + t_rel;
            if (t_abs + 2 >= si.len) break;
            const next = si[t_abs + 2];
            if (next != '>' and next != ' ') {
                sp = t_abs + 2;
                continue;
            }
            // Find closing ">" of the opening tag
            const gt_rel = std.mem.indexOfScalarPos(u8, si, t_abs, '>') orelse break;
            // Find "</t>"
            const end_rel = std.mem.indexOf(u8, si[gt_rel + 1 ..], "</t>") orelse break;
            const t_text = si[gt_rel + 1 .. gt_rel + 1 + end_rel];
            try text.appendSlice(allocator, t_text);
            sp = gt_rel + 1 + end_rel + 4;
        }

        const unescaped = try xmlUnescape(text.items, allocator);
        try strings.append(allocator, unescaped);
        pos = si_end + 5;
    }

    return strings.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Workbook + rels parser
// ---------------------------------------------------------------------------

/// Build a map from sheet name → relative file path (e.g. "worksheets/sheet2.xml").
fn parseWorkbookAndRels(
    wb_xml: []const u8,
    rels_xml: []const u8,
    allocator: Allocator,
    out: *std.StringHashMap([]const u8),
) !void {
    // Step 1: workbook.xml → name → rId
    var rid_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = rid_map.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        rid_map.deinit();
    }

    var pos: usize = 0;
    while (std.mem.indexOf(u8, wb_xml[pos..], "<sheet ")) |rel| {
        const tag_start = pos + rel + 1; // skip '<'
        const tag_end = std.mem.indexOfScalarPos(u8, wb_xml, tag_start, '>') orelse break;
        const tag = wb_xml[tag_start..tag_end];

        if (attrVal(tag, "name")) |name| {
            if (attrVal(tag, "r:id")) |rid| {
                const k = try allocator.dupe(u8, name);
                const v = try allocator.dupe(u8, rid);
                try rid_map.put(k, v);
            }
        }
        pos = tag_end;
    }

    // Step 2: rels xml → rId → Target
    var target_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = target_map.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        target_map.deinit();
    }

    pos = 0;
    while (std.mem.indexOf(u8, rels_xml[pos..], "<Relationship ")) |rel| {
        const tag_start = pos + rel + 1;
        const tag_end = std.mem.indexOfScalarPos(u8, rels_xml, tag_start, '>') orelse break;
        const tag = rels_xml[tag_start..tag_end];

        if (attrVal(tag, "Id")) |id| {
            if (attrVal(tag, "Target")) |target| {
                // Only include worksheet relationships
                if (std.mem.indexOf(u8, tag, "worksheet") != null) {
                    const k = try allocator.dupe(u8, id);
                    const v = try allocator.dupe(u8, target);
                    try target_map.put(k, v);
                }
            }
        }
        pos = tag_end;
    }

    // Step 3: combine: sheet name → file path
    var it = rid_map.iterator();
    while (it.next()) |kv| {
        const sheet_name = kv.key_ptr.*;
        const rid = kv.value_ptr.*;
        if (target_map.get(rid)) |target| {
            const k = try allocator.dupe(u8, sheet_name);
            const v = try allocator.dupe(u8, target);
            try out.put(k, v);
        }
    }
}

// ---------------------------------------------------------------------------
// Worksheet parser
// ---------------------------------------------------------------------------

const MAX_COLS = 32;

/// Parse xl/worksheets/sheetN.xml → rows.
/// rows[0] is the header row; rows[1..] are non-empty data rows.
fn parseWorksheet(
    xml: []const u8,
    shared: []const []const u8,
    allocator: Allocator,
) ![]Row {
    var rows: std.ArrayList(Row) = .empty;

    // Find <sheetData> block
    const sd_start = std.mem.indexOf(u8, xml, "<sheetData") orelse return rows.toOwnedSlice(allocator);
    const sd_end = std.mem.indexOf(u8, xml[sd_start..], "</sheetData>") orelse xml.len;
    const sheet_data = xml[sd_start .. sd_start + sd_end];

    var pos: usize = 0;
    var is_first_row = true;

    while (std.mem.indexOf(u8, sheet_data[pos..], "<row ")) |rel| {
        const row_tag_start = pos + rel;

        // Find the end of the opening row tag
        const row_gt = std.mem.indexOfScalarPos(u8, sheet_data, row_tag_start, '>') orelse break;

        // Find </row>
        const row_end_rel = std.mem.indexOf(u8, sheet_data[row_gt..], "</row>") orelse
            (sheet_data.len - row_gt);
        const row_content = sheet_data[row_gt + 1 .. row_gt + row_end_rel];

        const row = try parseRow(row_content, shared, allocator);

        if (is_first_row) {
            // Always include the header row
            try rows.append(allocator, row);
            is_first_row = false;
        } else {
            // Include data rows only if at least one cell is non-empty
            var has_data = false;
            for (row) |cell| {
                if (cell.len > 0) { has_data = true; break; }
            }
            if (has_data) try rows.append(allocator, row);
        }

        pos = row_gt + row_end_rel + 6; // skip past </row>
    }

    return rows.toOwnedSlice(allocator);
}

/// Parse one <row>…</row> body into a fixed-width cell array.
fn parseRow(row_xml: []const u8, shared: []const []const u8, allocator: Allocator) !Row {
    var cells: [MAX_COLS][]const u8 = undefined;
    @memset(&cells, "");
    var max_col: usize = 0;

    var pos: usize = 0;
    while (std.mem.indexOf(u8, row_xml[pos..], "<c ")) |rel| {
        const c_start = pos + rel;

        // End of this cell's opening tag
        const c_gt = std.mem.indexOfScalarPos(u8, row_xml, c_start, '>') orelse break;
        const cell_tag = row_xml[c_start + 2 .. c_gt]; // between '<c' and '>'

        // Cell reference → column index
        const col = blk: {
            const r = attrVal(cell_tag, "r") orelse break :blk null;
            break :blk colIdx(r);
        } orelse {
            pos = c_gt + 1;
            continue;
        };

        // Self-closing cell <c r="X" .../> has no value; skip it cleanly.
        if (c_gt > 0 and row_xml[c_gt - 1] == '/') {
            if (col < MAX_COLS and col > max_col) max_col = col;
            pos = c_gt + 1;
            continue;
        }

        // Find </c> to bound the cell content
        const c_end_rel = std.mem.indexOf(u8, row_xml[c_gt..], "</c>") orelse
            (row_xml.len - c_gt);
        const cell_content = row_xml[c_gt + 1 .. c_gt + c_end_rel];

        // Is this a shared string cell?
        const is_shared = if (attrVal(cell_tag, "t")) |t| std.mem.eql(u8, t, "s") else false;

        // Extract <v>…</v>
        const value: []const u8 = blk: {
            const v_start = std.mem.indexOf(u8, cell_content, "<v>") orelse break :blk "";
            const v_end = std.mem.indexOf(u8, cell_content[v_start..], "</v>") orelse break :blk "";
            const raw = cell_content[v_start + 3 .. v_start + v_end];
            if (is_shared) {
                const idx = std.fmt.parseInt(usize, raw, 10) catch break :blk try allocator.dupe(u8, raw);
                break :blk if (idx < shared.len) try allocator.dupe(u8, shared[idx]) else "";
            } else {
                // Numeric or inline string — strip trailing ".0" for cleanliness
                const duped = try allocator.dupe(u8, raw);
                // Strip ".0" suffix on integer floats (e.g. "4.0" → "4")
                if (std.mem.endsWith(u8, duped, ".0")) {
                    break :blk duped[0 .. duped.len - 2];
                }
                break :blk duped;
            }
        };

        if (col < MAX_COLS) {
            cells[col] = value;
            if (col > max_col) max_col = col;
        }

        const next_pos = c_gt + c_end_rel + 4;
        if (next_pos > row_xml.len) break;
        pos = next_pos;
    }

    // Build a slice sized to the rightmost non-empty column + 1
    const width = max_col + 1;
    const row_slice = try allocator.alloc([]const u8, width);
    @memcpy(row_slice, cells[0..width]);
    return row_slice;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "colIdx" {
    try testing.expectEqual(@as(usize, 0), colIdx("A1").?);
    try testing.expectEqual(@as(usize, 1), colIdx("B2").?);
    try testing.expectEqual(@as(usize, 25), colIdx("Z1").?);
    try testing.expectEqual(@as(usize, 26), colIdx("AA1").?);
    try testing.expectEqual(@as(usize, 27), colIdx("AB3").?);
}

test "attrVal" {
    const tag = "sheet name=\"User Needs\" r:id=\"rId6\"";
    try testing.expectEqualStrings("User Needs", attrVal(tag, "name").?);
    try testing.expectEqualStrings("rId6", attrVal(tag, "r:id").?);
    try testing.expect(attrVal(tag, "missing") == null);
}

test "xmlUnescape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try xmlUnescape("a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;", alloc);
    try testing.expectEqualStrings("a & b <c> \"d\" 'e'", result);

    // No entities → dupe of original
    const plain = try xmlUnescape("hello world", alloc);
    try testing.expectEqualStrings("hello world", plain);
}

test "parseSharedStrings basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const xml =
        \\<?xml version="1.0"?><sst><si><t>Hello</t></si><si><t>World</t></si></sst>
    ;
    const strs = try parseSharedStrings(xml, alloc);
    try testing.expectEqual(@as(usize, 2), strs.len);
    try testing.expectEqualStrings("Hello", strs[0]);
    try testing.expectEqualStrings("World", strs[1]);
}

test "parseSharedStrings rich text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Rich text: multiple <r><t> within one <si>
    const xml =
        \\<sst><si><r><rPr/><t>foo</t></r><r><rPr/><t>bar</t></r></si></sst>
    ;
    const strs = try parseSharedStrings(xml, alloc);
    try testing.expectEqual(@as(usize, 1), strs.len);
    try testing.expectEqualStrings("foobar", strs[0]);
}

test "parseRow shared string cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const shared = [_][]const u8{ "zero", "one", "two" };
    // <c r="A1" t="s"><v>1</v></c>  →  col 0 = "one"
    // <c r="C1" t="s"><v>2</v></c>  →  col 2 = "two"
    const row_xml =
        \\<c r="A1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c>
    ;
    const row = try parseRow(row_xml, &shared, alloc);
    try testing.expectEqual(@as(usize, 3), row.len);
    try testing.expectEqualStrings("one", row[0]);
    try testing.expectEqualStrings("", row[1]);
    try testing.expectEqualStrings("two", row[2]);
}

test "parseRow numeric cell strips .0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const shared = [_][]const u8{};
    const row_xml =
        \\<c r="A1"><v>4.0</v></c><c r="B1"><v>3.5</v></c>
    ;
    const row = try parseRow(row_xml, &shared, alloc);
    try testing.expectEqual(@as(usize, 2), row.len);
    try testing.expectEqualStrings("4", row[0]);
    try testing.expectEqualStrings("3.5", row[1]);
}

test "parse fixture integration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const sheets = try parse(alloc, "test/fixtures/RTMify_Requirements_Tracking_Template.xlsx");

    // Should have all 4 data sheets
    try testing.expectEqual(@as(usize, 4), sheets.len);

    // Verify sheet names in order
    try testing.expectEqualStrings("User Needs", sheets[0].name);
    try testing.expectEqualStrings("Requirements", sheets[1].name);
    try testing.expectEqualStrings("Tests", sheets[2].name);
    try testing.expectEqualStrings("Risks", sheets[3].name);

    // User Needs: header + 1 data row (UN-001)
    const un = sheets[0];
    try testing.expect(un.rows.len >= 2);
    try testing.expectEqualStrings("UN-001", un.rows[1][0]);
    try testing.expectEqualStrings("This better work", un.rows[1][1]);

    // Requirements: header + 2 data rows
    const req = sheets[1];
    try testing.expect(req.rows.len >= 3);
    try testing.expectEqualStrings("REQ-001", req.rows[1][0]);
    try testing.expectEqualStrings("REQ-002", req.rows[2][0]);

    // Tests: header + 4 data rows (T-001 through T-004)
    const tests = sheets[2];
    try testing.expect(tests.rows.len >= 5);

    // Risks: header + 1 data row (RSK-101)
    const risks = sheets[3];
    try testing.expect(risks.rows.len >= 2);
    try testing.expectEqualStrings("RSK-101", risks.rows[1][0]);
}
