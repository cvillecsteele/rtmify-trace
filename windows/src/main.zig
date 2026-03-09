// main.zig — wWinMain entry point and WndProc message dispatch
//
// Implements the 3-state UX:
//   license_gate  →  drop_zone / file_loaded  →  done
//
// Workers post WM_APP+N messages back; all UI mutation is on the main thread.

const std = @import("std");
const bridge = @import("bridge.zig");
const state = @import("state.zig");
const ui = @import("ui.zig");
const drop = @import("drop.zig");
const dialogs = @import("dialogs.zig");

// ---------------------------------------------------------------------------
// Win32 types
// ---------------------------------------------------------------------------

const HWND = *anyopaque;
const HINSTANCE = *anyopaque;
const BOOL = c_int;
const UINT = c_uint;
const DWORD = u32;
const WORD = u16;
const LPARAM = isize;
const WPARAM = usize;
const LRESULT = isize;
const ATOM = u16;

const MSG = extern struct {
    hwnd: ?*anyopaque,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt_x: i32,
    pt_y: i32,
    lPrivate: DWORD,
};

const RECT = ui.RECT;

const WNDPROC = *const fn (?*anyopaque, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?*anyopaque,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque,
};

// ---------------------------------------------------------------------------
// Win32 constants
// ---------------------------------------------------------------------------

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const WS_THICKFRAME: DWORD = 0x00040000;
const WS_MAXIMIZEBOX: DWORD = 0x00010000;
const WS_CAPTION: DWORD = 0x00C00000;
const WS_SYSMENU: DWORD = 0x00080000;
const WS_MINIMIZEBOX: DWORD = 0x00020000;

const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

const WM_DESTROY: UINT = 0x0002;
const WM_CREATE: UINT = 0x0001;
const WM_PAINT: UINT = 0x000F;
const WM_COMMAND: UINT = 0x0111;
const WM_DROPFILES: UINT = 0x0233;
const WM_DPICHANGED: UINT = 0x02E0;
const WM_CLOSE: UINT = 0x0010;
const WM_ACTIVATE: UINT = 0x0006;
const WM_CTLCOLORSTATIC: UINT = 0x0138;

const IDC_STATIC: usize = 0xFFFF;

const SW_SHOW: c_int = 5;
const SW_HIDE: c_int = 0;

const COLOR_BTNFACE: c_int = 15;
const COLOR_WINDOW: c_int = 5;

// LOGPIXELSX for GetDeviceCaps
const LOGPIXELSX: c_int = 88;

// SWP flags
const SWP_NOZORDER: UINT = 0x0004;
const SWP_NOACTIVATE: UINT = 0x0010;

// SetWindowPos insert-after values
const HWND_TOP: ?*anyopaque = null;

// ---------------------------------------------------------------------------
// Win32 extern functions
// ---------------------------------------------------------------------------

extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD, lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16,
    dwStyle: DWORD, X: i32, Y: i32, nWidth: i32, nHeight: i32,
    hWndParent: ?*anyopaque, hMenu: ?*anyopaque, hInstance: ?*anyopaque, lpParam: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?*anyopaque, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn DefWindowProcW(hWnd: ?*anyopaque, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.winapi) void;
extern "user32" fn LoadCursorW(hInstance: ?*anyopaque, lpCursorName: usize) callconv(.winapi) ?*anyopaque;
extern "user32" fn LoadIconW(hInstance: ?*anyopaque, lpIconName: usize) callconv(.winapi) ?*anyopaque;
extern "user32" fn MessageBoxW(hWnd: ?HWND, lpText: [*:0]const u16, lpCaption: [*:0]const u16, uType: c_uint) callconv(.winapi) c_int;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?*anyopaque, X: i32, Y: i32, cx: i32, cy: i32, uFlags: UINT) callconv(.winapi) BOOL;
extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn GetSysColorBrush(nIndex: c_int) callconv(.winapi) *anyopaque;
extern "user32" fn SetTextColor(hdc: *anyopaque, crColor: u32) callconv(.winapi) u32;
extern "user32" fn GetDC(hWnd: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn ReleaseDC(hWnd: ?*anyopaque, hDC: *anyopaque) callconv(.winapi) c_int;

extern "shell32" fn DragAcceptFiles(hWnd: HWND, fAccept: BOOL) callconv(.winapi) void;
extern "shell32" fn ShellExecuteW(
    hwnd: ?*anyopaque, lpOperation: ?[*:0]const u16, lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16, lpDirectory: ?[*:0]const u16, nShowCmd: c_int,
) callconv(.winapi) isize;

extern "gdi32" fn GetDeviceCaps(hdc: *anyopaque, nIndex: c_int) callconv(.winapi) c_int;
extern "gdi32" fn DeleteObject(ho: *anyopaque) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Global application state
// ---------------------------------------------------------------------------

var g_state: state.AppState = .{};
var g_hinstance: ?*anyopaque = null;

// ---------------------------------------------------------------------------
// UTF-16 string helpers
// ---------------------------------------------------------------------------

fn makeW(comptime s: []const u8) [s.len:0]u16 {
    comptime {
        var buf: [s.len:0]u16 = undefined;
        for (s, 0..) |c, i| buf[i] = c;
        return buf;
    }
}

// Returns a static [*:0]const u16 pointer valid for the life of the program.
fn toUtf16Z(comptime s: []const u8) [*:0]const u16 {
    const W = struct {
        const data: [s.len:0]u16 = makeW(s);
    };
    return &W.data;
}

fn utf8ToW(utf8: []const u8, buf: []u16) []u16 {
    return std.unicode.utf8ToUtf16Le(buf, utf8) catch buf[0..0];
}

// ---------------------------------------------------------------------------
// Shell execute helpers
// ---------------------------------------------------------------------------

fn shellOpen(path_utf8: []const u8) void {
    var w: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
    _ = std.unicode.utf8ToUtf16Le(&w, path_utf8) catch return;
    _ = ShellExecuteW(null, toUtf16Z("open"), &w, null, null, SW_SHOW);
}

fn shellShowInExplorer(path_utf8: []const u8) void {
    // Explorer /select,path highlights the file in Explorer
    var w: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
    _ = std.unicode.utf8ToUtf16Le(&w, path_utf8) catch return;
    var arg_buf: [1024]u8 = undefined;
    const arg = std.fmt.bufPrint(&arg_buf, "/select,\"{s}\"", .{path_utf8}) catch return;
    var arg_w: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
    _ = std.unicode.utf8ToUtf16Le(&arg_w, arg) catch return;
    _ = ShellExecuteW(null, null, toUtf16Z("explorer.exe"), &arg_w, null, SW_SHOW);
}

// ---------------------------------------------------------------------------
// State transitions
// ---------------------------------------------------------------------------

fn transitionToDropZone(hwnd: HWND) void {
    if (g_state.graph) |g| {
        bridge.rtmify_free(g);
        g_state.graph = null;
    }
    g_state.summary = null;
    g_state.result = null;
    g_state.tag = .drop_zone;
    ui.updateVisibility(.drop_zone);
    _ = InvalidateRect(hwnd, null, 1);
}

fn transitionToFileLoaded(hwnd: HWND, graph: *bridge.RtmifyGraph, path_utf8: []const u8) void {
    var summary = state.FileSummary{};
    const n = @min(path_utf8.len, 1023);
    @memcpy(summary.path_utf8[0..n], path_utf8[0..n]);

    const base = std.fs.path.basename(path_utf8);
    const bn = @min(base.len, 255);
    @memcpy(summary.display_name[0..bn], base[0..bn]);

    summary.gap_count = bridge.rtmify_gap_count(graph);
    summary.warning_count = bridge.rtmify_warning_count();

    g_state.graph = graph;
    g_state.summary = summary;
    g_state.tag = .file_loaded;
    ui.updateVisibility(.file_loaded);
    _ = InvalidateRect(hwnd, null, 1);
}

fn transitionToDone(hwnd: HWND, result: state.GenerateResult) void {
    g_state.result = result;
    g_state.tag = .done;
    ui.updateVisibility(.done);

    // Build output text
    var out_msg_buf: [4096]u8 = undefined;
    var out_msg: []u8 = out_msg_buf[0..0];

    var i: usize = 0;
    while (i < result.path_count) : (i += 1) {
        const p = std.mem.sliceTo(&result.output_paths[i], 0);
        out_msg = std.fmt.bufPrint(&out_msg_buf, "{s}{s}\r\n", .{ out_msg, p }) catch out_msg;
    }
    if (result.gap_count > 0) {
        out_msg = std.fmt.bufPrint(&out_msg_buf, "{s}\r\n{d} traceability gap{s} flagged in report.", .{
            out_msg, result.gap_count,
            if (result.gap_count == 1) "" else "s",
        }) catch out_msg;
    }

    ui.setOutputText(out_msg);
    _ = InvalidateRect(hwnd, null, 1);
}

// ---------------------------------------------------------------------------
// handleGenerate — build context and spawn worker
// ---------------------------------------------------------------------------

fn handleGenerate(hwnd: HWND) void {
    const graph = g_state.graph orelse return;
    const summary = g_state.summary orelse return;
    const fmt = ui.getSelectedFormat();

    const path_utf8 = std.mem.sliceTo(&summary.path_utf8, 0);
    var proj_buf: [256]u8 = undefined;
    const proj = state.projectName(path_utf8, &proj_buf);

    var fmts: [3][]const u8 = undefined;
    var paths: [3][]const u8 = undefined;
    var path_storage: [3][1024]u8 = undefined;
    var count: usize = 0;

    var result = state.GenerateResult{};

    if (fmt == .all) {
        const all_fmts = [_][]const u8{ "pdf", "docx", "md" };
        for (all_fmts, 0..) |f, fi| {
            fmts[fi] = f;
            const out = state.outputPath(path_utf8, f, &path_storage[fi]);
            paths[fi] = out;
            const on = @min(out.len, 1023);
            @memcpy(result.output_paths[fi][0..on], out[0..on]);
        }
        count = 3;
    } else {
        const fstr = state.formatSlice(fmt);
        fmts[0] = fstr;
        const out = state.outputPath(path_utf8, fstr, &path_storage[0]);
        paths[0] = out;
        const on = @min(out.len, 1023);
        @memcpy(result.output_paths[0][0..on], out[0..on]);
        count = 1;
    }

    result.path_count = count;
    result.gap_count = if (g_state.summary) |s| s.gap_count else 0;

    // Store result in state (worker will complete it via WM_GENERATE_COMPLETE)
    g_state.result = result;

    // Update UI to "generating" state
    g_state.tag = .generating;
    ui.updateVisibility(.generating);
    if (ui.generate_btn) |b| _ = SetWindowTextW(b, toUtf16Z("Generating\xe2\x80\xa6"));

    bridge.spawnGenerate(hwnd, graph, fmts[0..count], paths[0..count], proj);
}

// ---------------------------------------------------------------------------
// WndProc — main window message handler
// ---------------------------------------------------------------------------

fn wndProc(hwnd: ?*anyopaque, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const hw = hwnd orelse return DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        WM_CREATE => {
            ui.createControls(hw, g_hinstance orelse hw);
            ui.setFont(hw);
            DragAcceptFiles(hw, 1);
            // Check license on startup
            const lic_status = bridge.rtmify_check_license();
            if (lic_status == bridge.RTMIFY_OK) {
                g_state.tag = .drop_zone;
            } else {
                g_state.tag = .license_gate;
            }
            ui.updateVisibility(g_state.tag);
            return 0;
        },

        WM_DESTROY => {
            if (g_state.graph) |g| bridge.rtmify_free(g);
            if (ui.g_hfont) |f| _ = DeleteObject(f);
            PostQuitMessage(0);
            return 0;
        },

        WM_PAINT => {
            ui.paint(hw, &g_state);
            return 0;
        },

        WM_DROPFILES => {
            const h_drop: *anyopaque = @ptrFromInt(wparam);
            drop.handleDrop(hw, h_drop, &uiSetStatus, &bridgeSpawnLoad);
            return 0;
        },

        WM_DPICHANGED => {
            // lParam = pointer to RECT with suggested new window position/size
            const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = SetWindowPos(hw, HWND_TOP,
                suggested.left, suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
            return 0;
        },

        WM_CTLCOLORSTATIC => {
            // Color the activation error label red
            const ctrl_hwnd: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (ctrl_hwnd != null and ctrl_hwnd == ui.activ_err) {
                const hdc: *anyopaque = @ptrFromInt(wparam);
                _ = SetTextColor(hdc, 0x000000CC);
                return @bitCast(@intFromPtr(GetSysColorBrush(COLOR_BTNFACE)));
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        WM_COMMAND => {
            const ctrl_id = wparam & 0xFFFF;
            switch (ctrl_id) {
                ui.IDC_ACTIVATE_BTN => handleActivate(hw),
                ui.IDC_BROWSE_BTN => handleBrowse(hw),
                ui.IDC_GENERATE_BTN => handleGenerate(hw),
                ui.IDC_CLEAR_BTN => transitionToDropZone(hw),
                ui.IDC_SHOW_BTN => handleShowInExplorer(),
                ui.IDC_OPEN_BTN => handleOpenFile(),
                ui.IDC_AGAIN_BTN => transitionToDropZone(hw),
                else => {},
            }
            return 0;
        },

        bridge.WM_LOAD_COMPLETE => {
            const status: i32 = @intCast(wparam);
            if (status == bridge.RTMIFY_OK) {
                const graph: *bridge.RtmifyGraph = @ptrFromInt(@as(usize, @bitCast(lparam)));
                const path_utf8 = if (g_state.summary) |s| std.mem.sliceTo(&s.path_utf8, 0) else "";
                transitionToFileLoaded(hw, graph, path_utf8);
            } else {
                dialogs.showError(hw, bridge.rtmify_last_error());
                g_state.tag = .drop_zone;
                ui.updateVisibility(.drop_zone);
                _ = InvalidateRect(hw, null, 1);
            }
        },

        bridge.WM_GENERATE_COMPLETE => {
            const status: i32 = @intCast(wparam);
            // Restore button text
            if (ui.generate_btn) |b| _ = SetWindowTextW(b, toUtf16Z("Generate"));
            if (status == bridge.RTMIFY_OK) {
                if (g_state.result) |r| {
                    transitionToDone(hw, r);
                }
            } else {
                dialogs.showError(hw, bridge.rtmify_last_error());
                g_state.tag = .file_loaded;
                ui.updateVisibility(.file_loaded);
                _ = InvalidateRect(hw, null, 1);
            }
        },

        bridge.WM_ACTIVATE_COMPLETE => {
            const status: i32 = @intCast(wparam);
            if (ui.activate_btn) |b| _ = SetWindowTextW(b, toUtf16Z("Activate"));
            if (ui.activate_btn) |b| _ = EnableWindow(b, 1);
            if (status == bridge.RTMIFY_OK) {
                g_state.has_activation_error = false;
                if (ui.activ_err) |c| _ = ShowWindow(c, SW_HIDE);
                g_state.tag = .drop_zone;
                ui.updateVisibility(.drop_zone);
                _ = InvalidateRect(hw, null, 1);
            } else {
                g_state.has_activation_error = true;
                ui.setActivationError(bridge.rtmify_last_error());
            }
        },

        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    return 0;
}

// ---------------------------------------------------------------------------
// WM_COMMAND handlers
// ---------------------------------------------------------------------------

fn handleActivate(hwnd: HWND) void {
    var key_buf: [128]u8 = undefined;
    const key = ui.getKeyText(&key_buf);
    if (key.len == 0) return;

    if (ui.activate_btn) |b| {
        _ = SetWindowTextW(b, toUtf16Z("Activating\xe2\x80\xa6"));
        _ = EnableWindow(b, 0);
    }
    bridge.spawnActivate(hwnd, key);
}

extern "user32" fn EnableWindow(hWnd: *anyopaque, bEnable: BOOL) callconv(.winapi) BOOL;

fn handleBrowse(hwnd: HWND) void {
    var path_buf: [1024]u8 = undefined;
    const path = dialogs.browseXlsx(hwnd, &path_buf) orelse return;
    // Store path for later (transitionToFileLoaded uses g_state.summary.path_utf8)
    g_state.summary = state.FileSummary{};
    const n = @min(path.len, 1023);
    @memcpy(g_state.summary.?.path_utf8[0..n], path[0..n]);
    ui.setStatusText(hwnd, "Reading spreadsheet\xe2\x80\xa6");
    bridge.spawnLoad(hwnd, path);
}

fn handleShowInExplorer() void {
    const result = g_state.result orelse return;
    if (result.path_count == 0) return;
    const first = std.mem.sliceTo(&result.output_paths[0], 0);
    shellShowInExplorer(first);
}

fn handleOpenFile() void {
    const result = g_state.result orelse return;
    if (result.path_count == 0) return;
    const first = std.mem.sliceTo(&result.output_paths[0], 0);
    shellOpen(first);
}

// ---------------------------------------------------------------------------
// Adapter callbacks for drop.zig (avoid circular imports)
// ---------------------------------------------------------------------------

fn uiSetStatus(hwnd: HWND, msg: [*:0]const u8) void {
    ui.setStatusText(hwnd, msg);
}

fn bridgeSpawnLoad(hwnd: HWND, path: []const u8) void {
    // Store path in summary for later use in transitionToFileLoaded
    g_state.summary = state.FileSummary{};
    const n = @min(path.len, 1023);
    @memcpy(g_state.summary.?.path_utf8[0..n], path[0..n]);
    bridge.spawnLoad(hwnd, path);
}

// When WM_LOAD_COMPLETE arrives with RTMIFY_OK, we need the original path.
// It's stored in g_state.summary.path_utf8.

// ---------------------------------------------------------------------------
// wWinMain — entry point for .windows subsystem
// ---------------------------------------------------------------------------

pub export fn wWinMain(
    hInstance: *anyopaque,
    _: ?*anyopaque,
    _: [*:0]u16,
    nCmdShow: c_int,
) callconv(.winapi) c_int {
    g_hinstance = hInstance;

    // Window class
    const cls_name = toUtf16Z("RTMifyTraceWnd");
    var wc = WNDCLASSEXW{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = 0x0003, // CS_HREDRAW | CS_VREDRAW
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = LoadIconW(null, 32512), // IDI_APPLICATION = 32512
        .hCursor = LoadCursorW(null, 32512), // IDC_ARROW = 32512
        .hbrBackground = GetSysColorBrush(COLOR_BTNFACE),
        .lpszMenuName = null,
        .lpszClassName = cls_name,
        .hIconSm = null,
    };
    _ = RegisterClassExW(&wc);

    // Fixed-size window: overlapped without resize/maximize
    const win_style = (WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX) & ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
    const hwnd_opt = CreateWindowExW(
        0,
        cls_name,
        toUtf16Z("RTMify Trace"),
        win_style,
        CW_USEDEFAULT, CW_USEDEFAULT,
        480, 520,
        null, null,
        hInstance,
        null,
    );

    const hwnd = hwnd_opt orelse return 1;

    _ = ShowWindow(hwnd, nCmdShow);
    _ = UpdateWindow(hwnd);

    // Message loop
    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) != 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }

    return @intCast(msg.wParam & 0xFFFFFFFF);
}
