/// Diagnostics collection for RTMify validation pipeline.
///
/// Each layer of parsing appends warnings/info entries here. Hard errors
/// are returned as ValidationError; soft issues become entries in this list.
/// Every entry carries a stable numeric code (e.g. E703) that users can
/// look up at https://rtmify.io/errors/E<code>.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Error code type and named constants
// ---------------------------------------------------------------------------

pub const Code = u16;

/// Named error codes. Use these at every call site:
///   try diag.warn(E.req_no_shall, .semantic, tab, row, "...", .{});
pub const E = struct {
    // Layer 0: Filesystem
    pub const file_not_found:           Code = 101;
    pub const file_is_directory:        Code = 102;
    pub const file_unreadable:          Code = 103;
    pub const file_empty:               Code = 104;
    pub const file_too_large:           Code = 105;
    pub const wrong_extension:          Code = 106;
    // Layer 1: Container / ZIP
    pub const ole2_format:              Code = 201;
    pub const ods_format:               Code = 202;
    pub const html_as_xlsx:             Code = 203;
    pub const not_a_zip:                Code = 204;
    pub const encrypted_zip:            Code = 205;
    pub const zip_bomb:                 Code = 206;
    pub const xlsb_format:              Code = 207;
    pub const path_traversal:           Code = 208;
    pub const xlsm_macro:               Code = 209;
    // Layer 2: XLSX structure
    pub const missing_content_types:    Code = 301;
    pub const missing_workbook:         Code = 302;
    pub const missing_workbook_rels:    Code = 303;
    pub const missing_shared_strings:   Code = 304;
    pub const missing_worksheet:        Code = 305;
    // Layer 3: Tab discovery
    pub const requirements_tab_missing: Code = 401;
    pub const ambiguous_tab:            Code = 402;
    pub const tab_synonym_match:        Code = 403;
    pub const tab_substring_match:      Code = 404;
    pub const tab_fuzzy_match:          Code = 405;
    pub const optional_tab_missing:     Code = 406;
    // Layer 4: Column mapping
    pub const column_synonym_match:     Code = 501;
    pub const column_ambiguous:         Code = 502;
    pub const id_column_guessed:        Code = 503;
    pub const id_column_missing:        Code = 504;
    // Layer 5: Row parsing / normalization
    pub const id_paren_stripped:        Code = 601;
    pub const id_hyphen_stripped:       Code = 602;
    pub const row_no_id:                Code = 603;
    pub const duplicate_id:             Code = 604;
    pub const duplicate_test_id:        Code = 605;
    pub const numeric_text_mapped:      Code = 606;
    pub const numeric_fractional:       Code = 607;
    pub const numeric_unrecognized:     Code = 608;
    // Layer 6: Semantic validation
    pub const req_empty:                Code = 701;
    pub const req_short:                Code = 702;
    pub const req_no_shall:             Code = 703;
    pub const req_compound:             Code = 704;
    pub const req_vague:                Code = 705;
    pub const req_obsolete_traced:      Code = 706;
    pub const risk_score_mismatch:      Code = 707;
    pub const risk_unmitigated:         Code = 708;
    pub const risk_residual_no_init:    Code = 709;
    pub const risk_residual_exceeds:    Code = 710;
    pub const test_group_empty:         Code = 711;
    // Layer 7: Cross-reference resolution
    pub const ref_not_found:            Code = 801;
    pub const ref_wrong_type:           Code = 802;
};

// ---------------------------------------------------------------------------
// Catalog: human-readable titles for every code
// ---------------------------------------------------------------------------

pub const CatalogEntry = struct { code: Code, title: []const u8 };

pub const catalog = [_]CatalogEntry{
    .{ .code = 101, .title = "File not found" },
    .{ .code = 102, .title = "Path is a directory, not a file" },
    .{ .code = 103, .title = "File cannot be read" },
    .{ .code = 104, .title = "File is empty" },
    .{ .code = 105, .title = "File too large (> 500 MB)" },
    .{ .code = 106, .title = "Unexpected file extension" },
    .{ .code = 201, .title = "OLE2 / legacy .xls format — re-save as .xlsx" },
    .{ .code = 202, .title = "OpenDocument Spreadsheet (.ods) — re-save as .xlsx" },
    .{ .code = 203, .title = "HTML document saved with .xlsx extension" },
    .{ .code = 204, .title = "Not a ZIP archive" },
    .{ .code = 205, .title = "Password-protected workbook" },
    .{ .code = 206, .title = "ZIP bomb detected (extreme compression ratio)" },
    .{ .code = 207, .title = "Binary Excel format (.xlsb) — re-save as .xlsx" },
    .{ .code = 208, .title = "ZIP entry with path traversal sequence skipped" },
    .{ .code = 209, .title = "Macro-enabled workbook (.xlsm) — macros ignored" },
    .{ .code = 301, .title = "Missing [Content_Types].xml — file may be corrupt" },
    .{ .code = 302, .title = "Missing xl/workbook.xml" },
    .{ .code = 303, .title = "Missing xl/_rels/workbook.xml.rels" },
    .{ .code = 304, .title = "xl/sharedStrings.xml absent — treating all cells as inline values" },
    .{ .code = 305, .title = "Worksheet file listed in workbook but missing from ZIP" },
    .{ .code = 401, .title = "No matching 'Requirements' tab found" },
    .{ .code = 402, .title = "Multiple tabs match the same name — using first" },
    .{ .code = 403, .title = "Tab identified by known synonym" },
    .{ .code = 404, .title = "Tab identified by substring match" },
    .{ .code = 405, .title = "Tab identified by fuzzy (Levenshtein) match" },
    .{ .code = 406, .title = "Optional tab not found — related data will be absent" },
    .{ .code = 501, .title = "Column header matched by known synonym" },
    .{ .code = 502, .title = "Multiple columns match the same field — using leftmost" },
    .{ .code = 503, .title = "ID column not found by name; inferred from data pattern" },
    .{ .code = 504, .title = "ID column not found — rows in this tab will be skipped" },
    .{ .code = 601, .title = "Parenthetical suffix removed from ID" },
    .{ .code = 602, .title = "Leading or trailing hyphens removed from ID" },
    .{ .code = 603, .title = "Row has content but no ID — skipped" },
    .{ .code = 604, .title = "Duplicate ID in this tab — subsequent row skipped" },
    .{ .code = 605, .title = "Duplicate test case ID — subsequent row skipped" },
    .{ .code = 606, .title = "Text severity/likelihood value mapped to number" },
    .{ .code = 607, .title = "Fractional severity/likelihood value — ignored" },
    .{ .code = 608, .title = "Unrecognized severity/likelihood value — ignored" },
    .{ .code = 701, .title = "Requirement has no statement text" },
    .{ .code = 702, .title = "Requirement statement is very short (< 10 characters)" },
    .{ .code = 703, .title = "Requirement has no 'shall'" },
    .{ .code = 704, .title = "Compound requirement: multiple 'shall' clauses" },
    .{ .code = 705, .title = "Vague or ambiguous term in requirement statement" },
    .{ .code = 706, .title = "Obsolete requirement still has active trace links" },
    .{ .code = 707, .title = "Risk severity present without likelihood (or vice versa)" },
    .{ .code = 708, .title = "High-risk score (> 12) with no mitigation" },
    .{ .code = 709, .title = "Residual risk scores present but initial scores absent" },
    .{ .code = 710, .title = "Residual risk score exceeds initial risk score" },
    .{ .code = 711, .title = "Test group has no associated test cases" },
    .{ .code = 801, .title = "Cross-reference target not found in the graph" },
    .{ .code = 802, .title = "Cross-reference target has an unexpected node type" },
};

/// Look up the human-readable title for a code. Returns "Unknown" for unlisted codes.
pub fn lookupTitle(code: Code) []const u8 {
    for (catalog) |e| {
        if (e.code == code) return e.title;
    }
    return "Unknown";
}

/// The base URL for per-code documentation pages.
pub const error_url_base = "https://rtmify.io/errors/";

// ---------------------------------------------------------------------------
// Public enums
// ---------------------------------------------------------------------------

pub const Level = enum { info, warn, err };

pub const Source = enum {
    filesystem,
    container,
    structure,
    tab_discovery,
    column_mapping,
    row_parsing,
    semantic,
    cross_ref,
};

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

pub const Entry = struct {
    level: Level,
    code: Code,
    source: Source,
    tab: ?[]const u8, // null = file-level
    row: ?u32, // 1-based; null = not row-level
    message: []const u8, // owned by Diagnostics arena
};

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

pub const Diagnostics = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry), // backed by caller's allocator
    warning_count: u32,
    error_count: u32,

    pub fn init(gpa: Allocator) Diagnostics {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .entries = .empty,
            .warning_count = 0,
            .error_count = 0,
        };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.entries.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }

    pub fn add(
        self: *Diagnostics,
        level: Level,
        code: Code,
        source: Source,
        tab: ?[]const u8,
        row: ?u32,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const msg = try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
        const tab_owned: ?[]const u8 = if (tab) |t| try self.arena.allocator().dupe(u8, t) else null;
        try self.entries.append(self.arena.child_allocator, .{
            .level = level,
            .code = code,
            .source = source,
            .tab = tab_owned,
            .row = row,
            .message = msg,
        });
        switch (level) {
            .warn => self.warning_count += 1,
            .err => self.error_count += 1,
            .info => {},
        }
    }

    pub fn warn(
        self: *Diagnostics,
        code: Code,
        source: Source,
        tab: ?[]const u8,
        row: ?u32,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        return self.add(.warn, code, source, tab, row, fmt, args);
    }

    pub fn info(
        self: *Diagnostics,
        code: Code,
        source: Source,
        tab: ?[]const u8,
        row: ?u32,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        return self.add(.info, code, source, tab, row, fmt, args);
    }

    /// Print all entries to writer. Format:
    ///   [WARN] E703 [tab] row N: message
    ///   [ERR ] E401: message
    pub fn printSummary(self: *const Diagnostics, writer: anytype) !void {
        for (self.entries.items) |e| {
            const level_str: []const u8 = switch (e.level) {
                .warn => "WARN",
                .info => "INFO",
                .err => "ERR ",
            };
            if (e.tab) |t| {
                if (e.row) |r| {
                    try writer.print("[{s}] E{d} [{s}] row {d}: {s}\n", .{ level_str, e.code, t, r, e.message });
                } else {
                    try writer.print("[{s}] E{d} [{s}]: {s}\n", .{ level_str, e.code, t, e.message });
                }
            } else {
                try writer.print("[{s}] E{d}: {s}\n", .{ level_str, e.code, e.message });
            }
        }
    }

    /// Write all entries as JSON to path. Each entry includes a "code" number
    /// and a "url" field pointing to the documentation page.
    pub fn writeJson(self: *const Diagnostics, path: []const u8, gpa: Allocator) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);

        const w = out.writer(gpa);
        try w.writeAll("{\"diagnostics\":[");
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{");
            try w.print("\"level\":\"{s}\"", .{@tagName(e.level)});
            try w.print(",\"code\":{d}", .{e.code});
            try w.print(",\"url\":\"{s}E{d}\"", .{ error_url_base, e.code });
            try w.print(",\"source\":\"{s}\"", .{@tagName(e.source)});
            if (e.tab) |t| {
                try w.writeAll(",\"tab\":\"");
                try writeJsonString(w, t);
                try w.writeByte('"');
            } else {
                try w.writeAll(",\"tab\":null");
            }
            if (e.row) |r| {
                try w.print(",\"row\":{d}", .{r});
            } else {
                try w.writeAll(",\"row\":null");
            }
            try w.writeAll(",\"message\":\"");
            try writeJsonString(w, e.message);
            try w.writeAll("\"}");
        }
        try w.print("],\"warning_count\":{d},\"error_count\":{d}}}", .{
            self.warning_count, self.error_count,
        });

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(out.items);
    }
};

fn writeJsonString(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"'  => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

// ---------------------------------------------------------------------------
// ValidationError
// ---------------------------------------------------------------------------

pub const ValidationError = error{
    FileNotFound,
    FileIsDirectory,
    FileUnreadable,
    FileEmpty,
    FileTooLarge,
    OLE2Format,
    ODSFormat,
    HTMLAsXlsx,
    NotAZip,
    CorruptZip,
    EncryptedZip,
    ZipBomb,
    MissingContentTypes,
    MissingWorkbook,
    MissingWorkbookRels,
    RequirementsTabNotFound,
    AmbiguousTabMatch,
    IDColumnNotFound,
    XlsbFormat,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Diagnostics add and count" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try d.warn(E.wrong_extension, .filesystem, null, null, "test warning {d}", .{42});
    try d.info(E.missing_shared_strings, .structure, "Requirements", null, "info entry", .{});
    try d.warn(E.row_no_id, .row_parsing, "Tests", 5, "row warn", .{});

    try testing.expectEqual(@as(u32, 2), d.warning_count);
    try testing.expectEqual(@as(u32, 0), d.error_count);
    try testing.expectEqual(@as(usize, 3), d.entries.items.len);

    try testing.expectEqual(Level.warn, d.entries.items[0].level);
    try testing.expectEqual(@as(Code, E.wrong_extension), d.entries.items[0].code);
    try testing.expect(d.entries.items[0].tab == null);
    try testing.expectEqualStrings("test warning 42", d.entries.items[0].message);

    try testing.expectEqual(Level.info, d.entries.items[1].level);
    try testing.expectEqual(@as(Code, E.missing_shared_strings), d.entries.items[1].code);
    try testing.expectEqualStrings("Requirements", d.entries.items[1].tab.?);

    try testing.expectEqual(@as(?u32, 5), d.entries.items[2].row);
}

test "Diagnostics printSummary includes code" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try d.warn(E.req_no_shall, .semantic, null, null, "bad file", .{});
    try d.info(E.tab_fuzzy_match, .tab_discovery, "Reqs", 3, "fuzzy match", .{});

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try d.printSummary(fbs.writer());
    const out = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, out, "[WARN] E703:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[INFO] E405 [Reqs] row 3:") != null);
}

test "Diagnostics writeJson includes code and url" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try d.warn(E.req_no_shall, .semantic, "Requirements", 7, "no shall", .{});

    const tmp_path = "/tmp/diag_test.json";
    try d.writeJson(tmp_path, testing.allocator);

    const content = try std.fs.cwd().readFileAlloc(testing.allocator, tmp_path, 65536);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "\"diagnostics\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"warning_count\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"code\":703") != null);
    try testing.expect(std.mem.indexOf(u8, content, "rtmify.io/errors/E703") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"tab\":\"Requirements\"") != null);
}

test "catalog covers all E constants" {
    // Every named constant in E should appear in the catalog.
    const e_codes = [_]Code{
        E.file_not_found, E.file_is_directory, E.file_unreadable, E.file_empty,
        E.file_too_large, E.wrong_extension,
        E.ole2_format, E.ods_format, E.html_as_xlsx, E.not_a_zip, E.encrypted_zip,
        E.zip_bomb, E.xlsb_format, E.path_traversal, E.xlsm_macro,
        E.missing_content_types, E.missing_workbook, E.missing_workbook_rels,
        E.missing_shared_strings, E.missing_worksheet,
        E.requirements_tab_missing, E.ambiguous_tab, E.tab_synonym_match,
        E.tab_substring_match, E.tab_fuzzy_match, E.optional_tab_missing,
        E.column_synonym_match, E.column_ambiguous, E.id_column_guessed, E.id_column_missing,
        E.id_paren_stripped, E.id_hyphen_stripped, E.row_no_id, E.duplicate_id,
        E.duplicate_test_id, E.numeric_text_mapped, E.numeric_fractional, E.numeric_unrecognized,
        E.req_empty, E.req_short, E.req_no_shall, E.req_compound, E.req_vague,
        E.req_obsolete_traced, E.risk_score_mismatch, E.risk_unmitigated,
        E.risk_residual_no_init, E.risk_residual_exceeds, E.test_group_empty,
        E.ref_not_found, E.ref_wrong_type,
    };
    for (e_codes) |code| {
        var found = false;
        for (catalog) |ce| {
            if (ce.code == code) { found = true; break; }
        }
        if (!found) {
            std.debug.print("E{d} missing from catalog\n", .{code});
            try testing.expect(false);
        }
    }
}

test "lookupTitle returns known title" {
    try testing.expectEqualStrings("Requirement has no 'shall'", lookupTitle(703));
    try testing.expectEqualStrings("File not found", lookupTitle(101));
    try testing.expectEqualStrings("Unknown", lookupTitle(999));
}
