// bridge.zig — C ABI declarations for librtmify + worker thread helpers
//
// All worker threads call one librtmify function, then PostMessageW back to
// the main thread. No shared mutable state between threads.

const std = @import("std");

// ---------------------------------------------------------------------------
// Win32 primitives used in this file
// ---------------------------------------------------------------------------

const HWND = *anyopaque;
const BOOL = c_int;
const UINT = c_uint;
const WPARAM = usize;
const LPARAM = isize;

extern "user32" fn PostMessageW(
    hWnd: HWND,
    Msg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// librtmify C ABI status codes
// ---------------------------------------------------------------------------

pub const RTMIFY_OK: i32 = 0;
pub const RTMIFY_ERR_FILE_NOT_FOUND: i32 = 1;
pub const RTMIFY_ERR_INVALID_XLSX: i32 = 2;
pub const RTMIFY_ERR_MISSING_TAB: i32 = 3;
pub const RTMIFY_ERR_LICENSE: i32 = 4;
pub const RTMIFY_ERR_OUTPUT: i32 = 5;

// ---------------------------------------------------------------------------
// Opaque graph handle
// ---------------------------------------------------------------------------

pub const RtmifyGraph = opaque {};

// ---------------------------------------------------------------------------
// C ABI extern declarations (librtmify.a)
// ---------------------------------------------------------------------------

pub extern fn rtmify_load(
    xlsx_path: [*:0]const u8,
    out_graph: **RtmifyGraph,
) i32;

pub extern fn rtmify_generate(
    graph: *const RtmifyGraph,
    format: [*:0]const u8,
    output_path: [*:0]const u8,
    project_name: ?[*:0]const u8,
) i32;

pub extern fn rtmify_gap_count(graph: *const RtmifyGraph) i32;
pub extern fn rtmify_warning_count() i32;
pub extern fn rtmify_last_error() [*:0]const u8;
pub extern fn rtmify_free(graph: *RtmifyGraph) void;
pub extern fn rtmify_activate_license(license_key: [*:0]const u8) i32;
pub extern fn rtmify_check_license() i32;
pub extern fn rtmify_deactivate_license() i32;

// ---------------------------------------------------------------------------
// Custom window messages (worker → main thread via PostMessageW)
// ---------------------------------------------------------------------------

pub const WM_APP: UINT = 0x8000;
pub const WM_LOAD_COMPLETE: UINT = WM_APP + 1;
pub const WM_GENERATE_COMPLETE: UINT = WM_APP + 2;
pub const WM_ACTIVATE_COMPLETE: UINT = WM_APP + 3;

// ---------------------------------------------------------------------------
// Context structs — heap-allocated, freed by WndProc after receipt
// ---------------------------------------------------------------------------

pub const LoadContext = struct {
    hwnd: HWND,
    path_utf8: [1024:0]u8,
};

pub const GenerateContext = struct {
    hwnd: HWND,
    graph: *const RtmifyGraph,
    // Parallel arrays: formats[i] → output_paths[i]
    formats: [3][8:0]u8,
    output_paths: [3][1024:0]u8,
    project_name: [256:0]u8,
    count: usize, // number of generate calls (1 for single, 3 for "All")
};

pub const ActivateContext = struct {
    hwnd: HWND,
    key: [128:0]u8,
};

// ---------------------------------------------------------------------------
// Worker functions
// ---------------------------------------------------------------------------

fn loadWorker(ctx: *LoadContext) void {
    var graph: *RtmifyGraph = undefined;
    const status = rtmify_load(&ctx.path_utf8, &graph);
    const lp: LPARAM = if (status == RTMIFY_OK) @bitCast(@intFromPtr(graph)) else 0;
    _ = PostMessageW(ctx.hwnd, WM_LOAD_COMPLETE, @intCast(status), lp);
    std.heap.page_allocator.destroy(ctx);
}

fn generateWorker(ctx: *GenerateContext) void {
    var status: i32 = RTMIFY_OK;
    var i: usize = 0;
    while (i < ctx.count) : (i += 1) {
        status = rtmify_generate(
            ctx.graph,
            &ctx.formats[i],
            &ctx.output_paths[i],
            &ctx.project_name,
        );
        if (status != RTMIFY_OK) break;
    }
    _ = PostMessageW(ctx.hwnd, WM_GENERATE_COMPLETE, @intCast(status), 0);
    std.heap.page_allocator.destroy(ctx);
}

fn activateWorker(ctx: *ActivateContext) void {
    const status = rtmify_activate_license(&ctx.key);
    _ = PostMessageW(ctx.hwnd, WM_ACTIVATE_COMPLETE, @intCast(status), 0);
    std.heap.page_allocator.destroy(ctx);
}

// ---------------------------------------------------------------------------
// Spawn helpers — allocate context, detach thread
// ---------------------------------------------------------------------------

pub fn spawnLoad(hwnd: HWND, path: []const u8) void {
    const ctx = std.heap.page_allocator.create(LoadContext) catch return;
    ctx.hwnd = hwnd;
    ctx.path_utf8 = std.mem.zeroes([1024:0]u8);
    const n = @min(path.len, 1023);
    @memcpy(ctx.path_utf8[0..n], path[0..n]);
    const thread = std.Thread.spawn(.{}, loadWorker, .{ctx}) catch {
        std.heap.page_allocator.destroy(ctx);
        return;
    };
    thread.detach();
}

pub fn spawnGenerate(
    hwnd: HWND,
    graph: *const RtmifyGraph,
    formats: []const []const u8,
    output_paths: []const []const u8,
    project: []const u8,
) void {
    const ctx = std.heap.page_allocator.create(GenerateContext) catch return;
    ctx.hwnd = hwnd;
    ctx.graph = graph;
    ctx.count = @min(formats.len, 3);
    ctx.formats = std.mem.zeroes([3][8:0]u8);
    ctx.output_paths = std.mem.zeroes([3][1024:0]u8);
    ctx.project_name = std.mem.zeroes([256:0]u8);

    var i: usize = 0;
    while (i < ctx.count) : (i += 1) {
        const fn_len = @min(formats[i].len, 7);
        @memcpy(ctx.formats[i][0..fn_len], formats[i][0..fn_len]);
        const op_len = @min(output_paths[i].len, 1023);
        @memcpy(ctx.output_paths[i][0..op_len], output_paths[i][0..op_len]);
    }
    const pn = @min(project.len, 255);
    @memcpy(ctx.project_name[0..pn], project[0..pn]);

    const thread = std.Thread.spawn(.{}, generateWorker, .{ctx}) catch {
        std.heap.page_allocator.destroy(ctx);
        return;
    };
    thread.detach();
}

pub fn spawnActivate(hwnd: HWND, key: []const u8) void {
    const ctx = std.heap.page_allocator.create(ActivateContext) catch return;
    ctx.hwnd = hwnd;
    ctx.key = std.mem.zeroes([128:0]u8);
    const n = @min(key.len, 127);
    @memcpy(ctx.key[0..n], key[0..n]);
    const thread = std.Thread.spawn(.{}, activateWorker, .{ctx}) catch {
        std.heap.page_allocator.destroy(ctx);
        return;
    };
    thread.detach();
}
