const std = @import("std");
const rtmify = @import("rtmify");
const graph = rtmify.graph;
const xlsx = rtmify.xlsx;
const schema = rtmify.schema;
const render_md = rtmify.render_md;
const render_docx = rtmify.render_docx;
const render_pdf = rtmify.render_pdf;
const license = rtmify.license;
const diagnostic = rtmify.diagnostic;
const Diagnostics = diagnostic.Diagnostics;

const VERSION = @import("build_options").version;

// ---------------------------------------------------------------------------
// Exit codes
// ---------------------------------------------------------------------------

const EXIT_SUCCESS: u8 = 0;
const EXIT_INPUT: u8 = 1; // file not found, not XLSX, missing tabs
const EXIT_LICENSE: u8 = 2; // not activated, expired, revoked
const EXIT_OUTPUT: u8 = 3; // can't write to destination

// ---------------------------------------------------------------------------
// Argument types
// ---------------------------------------------------------------------------

pub const Format = enum { md, docx, pdf, all };

pub const Args = struct {
    input: ?[]const u8 = null,
    format: Format = .docx,
    output: ?[]const u8 = null,
    project: ?[]const u8 = null,
    activate: ?[]const u8 = null,
    deactivate: bool = false,
    strict: bool = false,
    version: bool = false,
    help: bool = false,
    gaps_json: ?[]const u8 = null,
};

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidFormat,
    ConflictingOptions,
};

/// Parse a flat slice of argument strings (not including argv[0]).
/// Returns a populated Args or a ParseError.
pub fn parseArgs(tokens: []const []const u8) ParseError!Args {
    var args = Args{};
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const tok = tokens[i];
        if (std.mem.eql(u8, tok, "--help") or std.mem.eql(u8, tok, "-h")) {
            args.help = true;
        } else if (std.mem.eql(u8, tok, "--version")) {
            args.version = true;
        } else if (std.mem.eql(u8, tok, "--deactivate")) {
            args.deactivate = true;
        } else if (std.mem.eql(u8, tok, "--strict")) {
            args.strict = true;
        } else if (std.mem.eql(u8, tok, "--activate")) {
            i += 1;
            if (i >= tokens.len) return error.MissingValue;
            args.activate = tokens[i];
        } else if (std.mem.eql(u8, tok, "--format")) {
            i += 1;
            if (i >= tokens.len) return error.MissingValue;
            const f = tokens[i];
            if (std.mem.eql(u8, f, "md")) {
                args.format = .md;
            } else if (std.mem.eql(u8, f, "docx")) {
                args.format = .docx;
            } else if (std.mem.eql(u8, f, "all")) {
                args.format = .all;
            } else if (std.mem.eql(u8, f, "pdf")) {
                args.format = .pdf;
            } else {
                return error.InvalidFormat;
            }
        } else if (std.mem.eql(u8, tok, "--output")) {
            i += 1;
            if (i >= tokens.len) return error.MissingValue;
            args.output = tokens[i];
        } else if (std.mem.eql(u8, tok, "--gaps-json")) {
            i += 1;
            if (i >= tokens.len) return error.MissingValue;
            args.gaps_json = tokens[i];
        } else if (std.mem.eql(u8, tok, "--project")) {
            i += 1;
            if (i >= tokens.len) return error.MissingValue;
            args.project = tokens[i];
        } else if (std.mem.startsWith(u8, tok, "--")) {
            return error.UnknownFlag;
        } else {
            // Positional: input file
            if (args.input != null) return error.ConflictingOptions;
            args.input = tok;
        }
    }
    return args;
}

// ---------------------------------------------------------------------------
// Help / version text
// ---------------------------------------------------------------------------

const HELP =
    \\rtmify-trace <input.xlsx> [options]
    \\
    \\Generate a Requirements Traceability Matrix from an RTMify spreadsheet.
    \\
    \\Options:
    \\  --format <md|docx|pdf|all>  Output format (default: docx)
    \\  --output <path>          Output file or directory (default: same dir as input)
    \\  --project <name>         Project name for report header (default: filename)
    \\  --gaps-json <path>       Write diagnostics JSON to path
    \\  --activate <key>         Activate license key for this machine
    \\  --deactivate             Deactivate license on this machine
    \\  --strict                 Exit with gap count when gaps are found (for CI)
    \\  --version                Print version and exit
    \\  --help                   Print this help and exit
    \\
    \\Examples:
    \\  rtmify-trace requirements.xlsx
    \\  rtmify-trace requirements.xlsx --format all --output ./reports/
    \\  rtmify-trace requirements.xlsx --format md --project "Ventilator v2.1"
    \\  rtmify-trace requirements.xlsx --gaps-json gaps.json
    \\  rtmify-trace --activate XXXX-XXXX-XXXX-XXXX
    \\
    \\Exit codes:
    \\  0   success
    \\  1   input file error
    \\  2   license error
    \\  3   output error
    \\  N   gap count (with --strict)
    \\
;

fn printVersion(w: anytype) !void {
    const target = @import("builtin").target;
    const cpu_arch = @tagName(target.cpu.arch);
    const os_tag = @tagName(target.os.tag);
    try w.print("rtmify-trace {s} {s}-{s} (zig {s})\n", .{
        VERSION, cpu_arch, os_tag, @import("builtin").zig_version_string,
    });
}

// ---------------------------------------------------------------------------
// Output path resolution
// ---------------------------------------------------------------------------

/// Return the stem of a filename (basename without last extension).
pub fn stem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(base);
    if (ext.len == 0) return base;
    return base[0 .. base.len - ext.len];
}

/// Build the output file path for a given format extension ("md" or "docx").
/// Caller owns the returned slice.
fn outputPath(
    gpa: std.mem.Allocator,
    input_path: []const u8,
    fmt_ext: []const u8,
    output_opt: ?[]const u8,
) ![]u8 {
    const filename = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ stem(input_path), fmt_ext });
    defer gpa.free(filename);

    if (output_opt) |out| {
        // If output ends with a path separator, treat as directory
        const last = out[out.len - 1];
        if (last == '/' or last == std.fs.path.sep) {
            return std.fs.path.join(gpa, &.{ out, filename });
        }
        // Otherwise treat as a literal file path
        return gpa.dupe(u8, out);
    }

    // Default: same directory as input
    const dir = std.fs.path.dirname(input_path) orelse ".";
    return std.fs.path.join(gpa, &.{ dir, filename });
}

// ---------------------------------------------------------------------------
// Gap counting
// ---------------------------------------------------------------------------

fn gapCount(g: *const graph.Graph, gpa: std.mem.Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var untested: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesMissingEdge(.requirement, .tested_by, alloc, &untested);

    var orphan: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesMissingEdge(.requirement, .derives_from, alloc, &orphan);

    var risk_rows: std.ArrayList(graph.RiskRow) = .empty;
    try g.risks(alloc, &risk_rows);
    var unresolved: usize = 0;
    for (risk_rows.items) |row| {
        if (row.req_id) |rid| {
            if (g.getNode(rid) == null) unresolved += 1;
        }
    }

    return untested.items.len + orphan.items.len + unresolved;
}

// ---------------------------------------------------------------------------
// Timestamp
// ---------------------------------------------------------------------------

pub fn isoTimestamp(buf: *[20]u8) []u8 {
    const ts = std.time.timestamp();
    const secs_per_min = 60;
    const secs_per_hour = 3600;
    const secs_per_day = 86400;

    var remaining: u64 = @intCast(@max(ts, 0));
    const days = remaining / secs_per_day;
    remaining -= days * secs_per_day;
    const hour = remaining / secs_per_hour;
    remaining -= hour * secs_per_hour;
    const minute = remaining / secs_per_min;
    const second = remaining - minute * secs_per_min;

    // Gregorian date from day count (days since 1970-01-01)
    const z = days + 719468;
    const era = z / 146097;
    const doe = z - era * 146097;
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const yr = if (m <= 2) y + 1 else y;

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yr, m, d, hour, minute, second,
    }) catch buf[0..20];
}

// ---------------------------------------------------------------------------
// Generate a single report file
// ---------------------------------------------------------------------------

fn generateReport(
    gpa: std.mem.Allocator,
    g: *const graph.Graph,
    fmt: Format,
    input_path: []const u8,
    project_name: []const u8,
    timestamp: []const u8,
    output_opt: ?[]const u8,
) !void {
    switch (fmt) {
        .md => {
            const path = try outputPath(gpa, input_path, "md", output_opt);
            defer gpa.free(path);
            const file = std.fs.cwd().createFile(path, .{}) catch |err| {
                std.debug.print("Error: cannot write to {s}: {s}\n", .{ path, @errorName(err) });
                return error.OutputError;
            };
            defer file.close();
            const dw = file.deprecatedWriter();
            try render_md.renderMd(g, project_name, timestamp, dw);
            std.debug.print("  → {s}\n", .{path});
        },
        .docx => {
            const path = try outputPath(gpa, input_path, "docx", output_opt);
            defer gpa.free(path);
            const file = std.fs.cwd().createFile(path, .{}) catch |err| {
                std.debug.print("Error: cannot write to {s}: {s}\n", .{ path, @errorName(err) });
                return error.OutputError;
            };
            defer file.close();
            const dw = file.deprecatedWriter();
            try render_docx.renderDocx(g, project_name, timestamp, dw);
            std.debug.print("  → {s}\n", .{path});
        },
        .pdf => {
            const path = try outputPath(gpa, input_path, "pdf", output_opt);
            defer gpa.free(path);
            const file = std.fs.cwd().createFile(path, .{}) catch |err| {
                std.debug.print("Error: cannot write to {s}: {s}\n", .{ path, @errorName(err) });
                return error.OutputError;
            };
            defer file.close();
            const dw = file.deprecatedWriter();
            try render_pdf.renderPdf(g, project_name, timestamp, dw);
            std.debug.print("  → {s}\n", .{path});
        },
        .all => {
            try generateReport(gpa, g, .md, input_path, project_name, timestamp, output_opt);
            try generateReport(gpa, g, .docx, input_path, project_name, timestamp, output_opt);
            try generateReport(gpa, g, .pdf, input_path, project_name, timestamp, output_opt);
        },
    }
}

// ---------------------------------------------------------------------------
// Main run logic (returns exit code)
// ---------------------------------------------------------------------------

fn run(gpa: std.mem.Allocator, args: Args) !u8 {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (args.help) {
        try stdout.writeAll(HELP);
        return EXIT_SUCCESS;
    }

    if (args.version) {
        try printVersion(stdout);
        return EXIT_SUCCESS;
    }

    if (args.activate) |key| {
        license.activate(gpa, .{}, key) catch {
            const ls_msg = license.lastLsError();
            if (ls_msg.len > 0) {
                try stderr.print("Error: {s}\n", .{ls_msg});
            } else {
                try stderr.writeAll("Error: license activation failed. Check your key and internet connection.\n");
            }
            return EXIT_LICENSE;
        };
        try stdout.print("License activated successfully.\n", .{});
        return EXIT_SUCCESS;
    }

    if (args.deactivate) {
        license.deactivate(gpa, .{}) catch |err| {
            try stderr.print("Warning: deactivation error: {s}\n", .{@errorName(err)});
        };
        try stdout.print("License deactivated.\n", .{});
        return EXIT_SUCCESS;
    }

    // License gate
    const lic_result = license.check(gpa, .{}) catch .not_activated;
    switch (lic_result) {
        .ok => {},
        .not_activated => {
            try stderr.writeAll("Error: license not activated.\n");
            try stderr.writeAll("Run: rtmify-trace --activate <your-license-key>\n");
            return EXIT_LICENSE;
        },
        .expired => {
            try stderr.writeAll("Error: license expired (grace period elapsed).\n");
            try stderr.writeAll("Visit https://rtmify.io to renew your subscription.\n");
            return EXIT_LICENSE;
        },
        .fingerprint_mismatch => {
            try stderr.writeAll("Error: this license is not valid on this machine.\n");
            try stderr.writeAll("To move your license, deactivate on the old machine first.\n");
            return EXIT_LICENSE;
        },
    }

    const input_path = args.input orelse {
        try stderr.writeAll("Error: no input file specified.\n");
        try stderr.writeAll("Run: rtmify-trace --help\n");
        return EXIT_INPUT;
    };

    // Parse XLSX
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var diag = Diagnostics.init(gpa);
    defer diag.deinit();

    const sheets = xlsx.parseValidated(alloc, input_path, &diag) catch |err| {
        try diag.printSummary(stderr);
        switch (err) {
            error.FileNotFound => {
                try stderr.print("Error: file not found: {s}\n", .{input_path});
            },
            else => {
                try stderr.print("Error: could not read {s}: {s}\n", .{ input_path, @errorName(err) });
            },
        }
        return EXIT_INPUT;
    };

    var g = graph.Graph.init(alloc);
    _ = schema.ingestValidated(&g, sheets, &diag) catch |err| {
        try diag.printSummary(stderr);
        try stderr.print("Error: failed to ingest spreadsheet: {s}\n", .{@errorName(err)});
        return EXIT_INPUT;
    };

    try diag.printSummary(stderr);
    if (args.gaps_json) |jp| try diag.writeJson(jp, gpa);

    const gaps = try gapCount(&g, gpa);
    const project_name = args.project orelse stem(input_path);

    var ts_buf: [20]u8 = undefined;
    const timestamp = isoTimestamp(&ts_buf);

    generateReport(gpa, &g, args.format, input_path, project_name, timestamp, args.output) catch |err| switch (err) {
        error.OutputError => return EXIT_OUTPUT,
        else => {
            try stderr.print("Error: report generation failed: {s}\n", .{@errorName(err)});
            return EXIT_OUTPUT;
        },
    };

    if (gaps == 0) {
        try stdout.print("Done. No gaps found.\n", .{});
    } else {
        try stdout.print("Done. {d} gap(s) found.\n", .{gaps});
    }

    if (args.strict and gaps > 0) {
        return @intCast(@min(gaps, 254));
    }

    return EXIT_SUCCESS;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var arg_iter = std.process.argsWithAllocator(gpa) catch {
        std.debug.print("Error: out of memory\n", .{});
        std.posix.exit(1);
    };
    defer arg_iter.deinit();

    var tokens: std.ArrayList([]u8) = .empty;
    defer {
        for (tokens.items) |t| gpa.free(t);
        tokens.deinit(gpa);
    }
    _ = arg_iter.next(); // skip argv[0]
    while (arg_iter.next()) |a| {
        const owned = gpa.dupe(u8, a) catch {
            std.debug.print("Error: out of memory\n", .{});
            std.posix.exit(1);
        };
        tokens.append(gpa, owned) catch {
            std.debug.print("Error: out of memory\n", .{});
            std.posix.exit(1);
        };
    }

    const args = parseArgs(tokens.items) catch |err| {
        const msg = switch (err) {
            error.UnknownFlag => "unknown flag",
            error.MissingValue => "missing value for flag",
            error.InvalidFormat => "invalid format: use md, docx, or all",
            error.ConflictingOptions => "multiple input files specified",
        };
        std.debug.print("Error: {s}\nRun 'rtmify-trace --help' for usage.\n", .{msg});
        std.posix.exit(EXIT_INPUT);
    };

    const code = run(gpa, args) catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        std.posix.exit(EXIT_INPUT);
    };

    std.posix.exit(code);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseArgs no args" {
    const args = try parseArgs(&.{});
    try testing.expectEqual(@as(?[]const u8, null), args.input);
    try testing.expectEqual(Format.docx, args.format);
    try testing.expect(!args.strict);
    try testing.expect(!args.help);
    try testing.expect(!args.version);
}

test "parseArgs input file only" {
    const args = try parseArgs(&.{"requirements.xlsx"});
    try testing.expectEqualStrings("requirements.xlsx", args.input.?);
    try testing.expectEqual(Format.docx, args.format);
}

test "parseArgs --format md" {
    const args = try parseArgs(&.{ "input.xlsx", "--format", "md" });
    try testing.expectEqual(Format.md, args.format);
}

test "parseArgs --format all" {
    const args = try parseArgs(&.{ "input.xlsx", "--format", "all" });
    try testing.expectEqual(Format.all, args.format);
}

test "parseArgs --format docx" {
    const args = try parseArgs(&.{ "input.xlsx", "--format", "docx" });
    try testing.expectEqual(Format.docx, args.format);
}

test "parseArgs --output and --project" {
    const args = try parseArgs(&.{ "in.xlsx", "--output", "./out/", "--project", "My Project" });
    try testing.expectEqualStrings("./out/", args.output.?);
    try testing.expectEqualStrings("My Project", args.project.?);
}

test "parseArgs --version and --help" {
    const v = try parseArgs(&.{"--version"});
    try testing.expect(v.version);

    const h = try parseArgs(&.{"--help"});
    try testing.expect(h.help);

    const hh = try parseArgs(&.{"-h"});
    try testing.expect(hh.help);
}

test "parseArgs --activate" {
    const args = try parseArgs(&.{ "--activate", "XXXX-1234-YYYY-5678" });
    try testing.expectEqualStrings("XXXX-1234-YYYY-5678", args.activate.?);
}

test "parseArgs --deactivate --strict" {
    const args = try parseArgs(&.{ "--deactivate", "--strict" });
    try testing.expect(args.deactivate);
    try testing.expect(args.strict);
}

test "parseArgs unknown flag" {
    try testing.expectError(error.UnknownFlag, parseArgs(&.{"--unknown"}));
}

test "parseArgs missing value" {
    try testing.expectError(error.MissingValue, parseArgs(&.{"--format"}));
    try testing.expectError(error.MissingValue, parseArgs(&.{"--activate"}));
    try testing.expectError(error.MissingValue, parseArgs(&.{"--output"}));
    try testing.expectError(error.MissingValue, parseArgs(&.{"--project"}));
}

test "parseArgs --format pdf" {
    const args = try parseArgs(&.{ "input.xlsx", "--format", "pdf" });
    try testing.expectEqual(Format.pdf, args.format);
}

test "parseArgs invalid format" {
    try testing.expectError(error.InvalidFormat, parseArgs(&.{ "--format", "html" }));
    try testing.expectError(error.InvalidFormat, parseArgs(&.{ "--format", "rtf" }));
}

test "parseArgs multiple positionals" {
    try testing.expectError(error.ConflictingOptions, parseArgs(&.{ "a.xlsx", "b.xlsx" }));
}

test "parseArgs --gaps-json" {
    const args = try parseArgs(&.{ "input.xlsx", "--gaps-json", "/tmp/gaps.json" });
    try testing.expectEqualStrings("/tmp/gaps.json", args.gaps_json.?);
}

test "parseArgs --gaps-json missing value" {
    try testing.expectError(error.MissingValue, parseArgs(&.{"--gaps-json"}));
}

test "stem helper" {
    try testing.expectEqualStrings("requirements", stem("requirements.xlsx"));
    try testing.expectEqualStrings("requirements", stem("/path/to/requirements.xlsx"));
    try testing.expectEqualStrings("file", stem("file"));
    try testing.expectEqualStrings("my.report", stem("my.report.xlsx"));
}

test "isoTimestamp format" {
    var buf: [20]u8 = undefined;
    const ts = isoTimestamp(&buf);
    try testing.expectEqual(@as(usize, 20), ts.len);
    try testing.expectEqual('T', ts[10]);
    try testing.expectEqual('Z', ts[19]);
    try testing.expectEqual('-', ts[4]);
    try testing.expectEqual('-', ts[7]);
    try testing.expectEqual(':', ts[13]);
    try testing.expectEqual(':', ts[16]);
}
