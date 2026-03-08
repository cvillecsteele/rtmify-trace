const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Module re-exports (used by main.zig via `@import("rtmify")`)
// ---------------------------------------------------------------------------

pub const graph = @import("graph.zig");
pub const xlsx = @import("xlsx.zig");
pub const schema = @import("schema.zig");
pub const render_md = @import("render_md.zig");
pub const render_docx = @import("render_docx.zig");
pub const license = @import("license.zig");
pub const render_pdf = @import("render_pdf.zig");
pub const diagnostic = @import("diagnostic.zig");

// ---------------------------------------------------------------------------
// C ABI status codes
// ---------------------------------------------------------------------------

pub const RtmifyStatus = enum(c_int) {
    ok = 0,
    err_file_not_found = 1,
    err_invalid_xlsx = 2,
    err_missing_tab = 3,
    err_license = 4,
    err_output = 5,
};

// ---------------------------------------------------------------------------
// Opaque graph handle (heap-allocated, owns its GPA and Graph)
// ---------------------------------------------------------------------------

pub const RtmifyGraph = struct {
    gpa_state: std.heap.GeneralPurposeAllocator(.{}),
    g: graph.Graph,
};

// ---------------------------------------------------------------------------
// Thread-local last-error buffer and warning count
// ---------------------------------------------------------------------------

threadlocal var last_error_buf: [512]u8 = .{0} ** 512;
threadlocal var last_warning_count: c_int = 0;

pub export fn rtmify_warning_count() c_int {
    return last_warning_count;
}

fn setError(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(last_error_buf[0 .. last_error_buf.len - 1], fmt, args) catch
        last_error_buf[0 .. last_error_buf.len - 1];
    last_error_buf[written.len] = 0;
}

pub export fn rtmify_last_error() [*:0]const u8 {
    return @ptrCast(&last_error_buf);
}

// ---------------------------------------------------------------------------
// Internal helper: load sheets into an already-initialised handle
// ---------------------------------------------------------------------------

fn loadSheets(handle: *RtmifyGraph, path: []const u8) RtmifyStatus {
    const gpa = handle.gpa_state.allocator();
    var parse_arena = std.heap.ArenaAllocator.init(gpa);
    defer parse_arena.deinit();

    var diag = diagnostic.Diagnostics.init(gpa);
    defer diag.deinit();

    const sheets = xlsx.parseValidated(parse_arena.allocator(), path, &diag) catch |err| {
        last_warning_count = @intCast(diag.warning_count);
        switch (err) {
            error.FileNotFound => {
                setError("file not found: {s}", .{path});
                return .err_file_not_found;
            },
            else => {
                setError("failed to parse XLSX: {s}", .{@errorName(err)});
                return .err_invalid_xlsx;
            },
        }
    };

    _ = schema.ingestValidated(&handle.g, sheets, &diag) catch |err| {
        last_warning_count = @intCast(diag.warning_count);
        setError("failed to ingest spreadsheet: {s}", .{@errorName(err)});
        return .err_missing_tab;
    };

    last_warning_count = @intCast(diag.warning_count);
    return .ok;
}

// ---------------------------------------------------------------------------
// C ABI: rtmify_load
// ---------------------------------------------------------------------------

pub export fn rtmify_load(xlsx_path: [*:0]const u8, out_graph: **RtmifyGraph) RtmifyStatus {
    const path = std.mem.span(xlsx_path);

    const handle = std.heap.page_allocator.create(RtmifyGraph) catch {
        setError("out of memory", .{});
        return .err_invalid_xlsx;
    };
    handle.gpa_state = .init;
    const gpa = handle.gpa_state.allocator();
    handle.g = graph.Graph.init(gpa);

    const status = loadSheets(handle, path);
    if (status != .ok) {
        handle.g.deinit();
        _ = handle.gpa_state.deinit();
        std.heap.page_allocator.destroy(handle);
        return status;
    }

    out_graph.* = handle;
    return .ok;
}

// ---------------------------------------------------------------------------
// C ABI: rtmify_free
// ---------------------------------------------------------------------------

pub export fn rtmify_free(handle: *RtmifyGraph) void {
    handle.g.deinit();
    _ = handle.gpa_state.deinit();
    std.heap.page_allocator.destroy(handle);
}

// ---------------------------------------------------------------------------
// C ABI: rtmify_gap_count
// ---------------------------------------------------------------------------

fn computeGapCount(g: *const graph.Graph) !usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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

pub export fn rtmify_gap_count(handle: *const RtmifyGraph) c_int {
    const count = computeGapCount(&handle.g) catch return -1;
    return @intCast(@min(count, @as(usize, std.math.maxInt(c_int))));
}

// ---------------------------------------------------------------------------
// C ABI: rtmify_generate
// ---------------------------------------------------------------------------

fn isoTimestamp(buf: *[20]u8) []u8 {
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

pub export fn rtmify_generate(
    handle: *const RtmifyGraph,
    format: [*:0]const u8,
    output_path: [*:0]const u8,
    project_name: ?[*:0]const u8,
) RtmifyStatus {
    const fmt_str = std.mem.span(format);
    const out_path = std.mem.span(output_path);
    const proj_name: []const u8 = if (project_name) |p| std.mem.span(p) else "RTMify Report";

    var ts_buf: [20]u8 = undefined;
    const timestamp = isoTimestamp(&ts_buf);

    const file = std.fs.cwd().createFile(out_path, .{}) catch |err| {
        setError("cannot write to {s}: {s}", .{ out_path, @errorName(err) });
        return .err_output;
    };
    defer file.close();
    const dw = file.deprecatedWriter();

    if (std.mem.eql(u8, fmt_str, "md")) {
        render_md.renderMd(&handle.g, proj_name, timestamp, dw) catch |err| {
            setError("markdown render failed: {s}", .{@errorName(err)});
            return .err_output;
        };
    } else if (std.mem.eql(u8, fmt_str, "docx")) {
        render_docx.renderDocx(&handle.g, proj_name, timestamp, dw) catch |err| {
            setError("docx render failed: {s}", .{@errorName(err)});
            return .err_output;
        };
    } else if (std.mem.eql(u8, fmt_str, "pdf")) {
        render_pdf.renderPdf(&handle.g, proj_name, timestamp, dw) catch |err| {
            setError("pdf render failed: {s}", .{@errorName(err)});
            return .err_output;
        };
    } else {
        setError("unknown format: {s}", .{fmt_str});
        return .err_output;
    }

    return .ok;
}

// ---------------------------------------------------------------------------
// C ABI: license functions
// ---------------------------------------------------------------------------

pub export fn rtmify_activate_license(license_key: [*:0]const u8) RtmifyStatus {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const key = std.mem.span(license_key);
    license.activate(gpa, .{}, key) catch |err| {
        setError("license activation failed: {s}", .{@errorName(err)});
        return .err_license;
    };
    return .ok;
}

pub export fn rtmify_check_license() RtmifyStatus {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const result = license.check(gpa, .{}) catch {
        setError("license check failed", .{});
        return .err_license;
    };
    return switch (result) {
        .ok => .ok,
        .not_activated => blk: {
            setError("license not activated", .{});
            break :blk .err_license;
        },
        .expired => blk: {
            setError("license expired", .{});
            break :blk .err_license;
        },
    };
}

pub export fn rtmify_deactivate_license() RtmifyStatus {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    license.deactivate(gpa, .{}) catch |err| {
        setError("deactivation failed: {s}", .{@errorName(err)});
        return .err_license;
    };
    return .ok;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "lib imports" {
    _ = graph;
    _ = xlsx;
    _ = schema;
    _ = render_md;
    _ = render_docx;
    _ = license;
    _ = render_pdf;
    _ = diagnostic;
}

test "rtmify_last_error is valid pointer" {
    const err_ptr = rtmify_last_error();
    _ = std.mem.span(err_ptr);
}

test "rtmify_load nonexistent file returns err_file_not_found" {
    var handle: *RtmifyGraph = undefined;
    const status = rtmify_load("/nonexistent/path/to/file.xlsx", &handle);
    try testing.expectEqual(RtmifyStatus.err_file_not_found, status);
    const err_msg = std.mem.span(rtmify_last_error());
    try testing.expect(err_msg.len > 0);
}

test "rtmify_gap_count empty graph" {
    const handle = try std.heap.page_allocator.create(RtmifyGraph);
    defer std.heap.page_allocator.destroy(handle);
    handle.gpa_state = .init;
    defer _ = handle.gpa_state.deinit();
    handle.g = graph.Graph.init(handle.gpa_state.allocator());
    defer handle.g.deinit();

    try testing.expectEqual(@as(c_int, 0), rtmify_gap_count(handle));
}

test "rtmify_gap_count with orphan and untested requirements" {
    const handle = try std.heap.page_allocator.create(RtmifyGraph);
    defer std.heap.page_allocator.destroy(handle);
    handle.gpa_state = .init;
    defer _ = handle.gpa_state.deinit();
    handle.g = graph.Graph.init(handle.gpa_state.allocator());
    defer handle.g.deinit();

    // Two requirements with no edges → 2 orphan + 2 untested = 4 gaps
    try handle.g.addNode("REQ-001", .requirement, &.{});
    try handle.g.addNode("REQ-002", .requirement, &.{});
    try testing.expectEqual(@as(c_int, 4), rtmify_gap_count(handle));
}
