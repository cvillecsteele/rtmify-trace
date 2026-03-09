// state.zig — App state machine, output path logic, project name derivation

const std = @import("std");
const bridge = @import("bridge.zig");

// ---------------------------------------------------------------------------
// Enumerations
// ---------------------------------------------------------------------------

pub const Format = enum { pdf, docx, md, all };

pub const AppStateTag = enum {
    license_gate,
    drop_zone,
    file_loaded,
    generating,
    done,
};

// ---------------------------------------------------------------------------
// Data structs
// ---------------------------------------------------------------------------

pub const FileSummary = struct {
    path_utf8: [1024:0]u8 = std.mem.zeroes([1024:0]u8),
    display_name: [256:0]u8 = std.mem.zeroes([256:0]u8),
    gap_count: i32 = 0,
    warning_count: i32 = 0,
};

pub const GenerateResult = struct {
    output_paths: [3][1024:0]u8 = std.mem.zeroes([3][1024:0]u8),
    path_count: usize = 0,
    gap_count: i32 = 0,
};

pub const AppState = struct {
    tag: AppStateTag = .drop_zone,
    graph: ?*bridge.RtmifyGraph = null,
    summary: ?FileSummary = null,
    result: ?GenerateResult = null,
    activation_error: [256:0]u8 = std.mem.zeroes([256:0]u8),
    has_activation_error: bool = false,
    format: Format = .pdf,
};

// ---------------------------------------------------------------------------
// outputPath — "requirements.xlsx" + "pdf" → "C:\dir\requirements-rtm.pdf"
// Appends numeric suffix if the candidate file already exists.
// ---------------------------------------------------------------------------

pub fn outputPath(input: []const u8, fmt: []const u8, buf: []u8) []u8 {
    const basename = std.fs.path.basename(input);
    const ext_str = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - ext_str.len];
    const dir = std.fs.path.dirname(input) orelse ".";

    // Build base candidate
    const candidate = std.fmt.bufPrint(buf, "{s}\\{s}-rtm.{s}", .{ dir, stem, fmt }) catch
        return buf[0..0];

    // If file does not exist, use it directly
    std.fs.cwd().access(candidate, .{}) catch return candidate;

    // File exists — find next available numbered name
    var tmp: [1024]u8 = undefined;
    var i: u32 = 2;
    while (i <= 99) : (i += 1) {
        const numbered = std.fmt.bufPrint(&tmp, "{s}\\{s}-rtm-{d}.{s}", .{ dir, stem, i, fmt }) catch break;
        std.fs.cwd().access(numbered, .{}) catch {
            // File not found → use this name
            const n = @min(numbered.len, buf.len);
            @memcpy(buf[0..n], numbered[0..n]);
            return buf[0..n];
        };
    }

    return candidate; // fallback, may overwrite
}

// ---------------------------------------------------------------------------
// projectName — "requirements.xlsx" → "requirements"
// ---------------------------------------------------------------------------

pub fn projectName(input: []const u8, buf: []u8) []u8 {
    const basename = std.fs.path.basename(input);
    const ext_str = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - ext_str.len];
    const n = @min(stem.len, buf.len);
    @memcpy(buf[0..n], stem[0..n]);
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// formatSlice — Format enum → format string slice
// ---------------------------------------------------------------------------

pub fn formatSlice(fmt: Format) []const u8 {
    return switch (fmt) {
        .pdf => "pdf",
        .docx => "docx",
        .md => "md",
        .all => "all",
    };
}
