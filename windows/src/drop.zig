// drop.zig — WM_DROPFILES handler: extension check, UTF-16 → UTF-8 path

const std = @import("std");
const bridge = @import("bridge.zig");

// ---------------------------------------------------------------------------
// Win32 types / externs
// ---------------------------------------------------------------------------

const HWND = *anyopaque;
const HDROP = *anyopaque;
const UINT = c_uint;
const BOOL = c_int;

// ---------------------------------------------------------------------------
// Win32 externs
// ---------------------------------------------------------------------------

extern "shell32" fn DragQueryFileW(
    hDrop: HDROP,
    iFile: UINT,
    lpszFile: ?[*]u16,
    cch: UINT,
) callconv(.winapi) UINT;

extern "shell32" fn DragFinish(hDrop: HDROP) callconv(.winapi) void;

// ---------------------------------------------------------------------------
// Extension-specific user messages
// ---------------------------------------------------------------------------

fn extensionMessage(ext: []const u8) [*:0]const u8 {
    if (std.ascii.eqlIgnoreCase(ext, ".xls"))
        return "That\xe2\x80\x99s a .xls file \xe2\x80\x94 open it in Excel and re-save as .xlsx.";
    if (std.ascii.eqlIgnoreCase(ext, ".csv"))
        return ".csv files are not supported. RTMify Trace reads .xlsx files.";
    return "RTMify Trace reads .xlsx files.";
}

// ---------------------------------------------------------------------------
// handleDrop — called from WndProc WM_DROPFILES
// ---------------------------------------------------------------------------

pub fn handleDrop(
    hwnd: HWND,
    h_drop: HDROP,
    set_status: *const fn (HWND, [*:0]const u8) void,
    spawn_load: *const fn (HWND, []const u8) void,
) void {
    defer DragFinish(h_drop);

    var path_w: [1024]u16 = undefined;
    const chars = DragQueryFileW(h_drop, 0, &path_w, @intCast(path_w.len));
    if (chars == 0) return;

    // Convert UTF-16LE → UTF-8
    var path_utf8_buf: [1024]u8 = undefined;
    const nbytes = std.unicode.utf16LeToUtf8(&path_utf8_buf, path_w[0..chars]) catch {
        set_status(hwnd, "Could not read the dropped file path.");
        return;
    };
    const utf8_slice = path_utf8_buf[0..nbytes];

    const ext = std.fs.path.extension(utf8_slice);
    if (std.ascii.eqlIgnoreCase(ext, ".xlsx")) {
        set_status(hwnd, "Reading spreadsheet\xe2\x80\xa6");
        spawn_load(hwnd, utf8_slice);
    } else {
        set_status(hwnd, extensionMessage(ext));
    }
}
