// ui.zig — Win32 window class registration, control creation,
//           visibility management, WM_PAINT custom drawing, DPI, font.

const std = @import("std");
const state = @import("state.zig");

// ---------------------------------------------------------------------------
// Win32 primitive types
// ---------------------------------------------------------------------------

pub const HWND = *anyopaque;
const HINSTANCE = *anyopaque;
const HDC = *anyopaque;
const HFONT = *anyopaque;
const HBRUSH = *anyopaque;
const HPEN = *anyopaque;
const BOOL = c_int;
const UINT = c_uint;
const DWORD = u32;
const WORD = u16;
const LPARAM = isize;
const WPARAM = usize;
const LRESULT = isize;
const COLORREF = u32;
const ATOM = u16;

pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

const LOGFONTW = extern struct {
    lfHeight: i32 = 0,
    lfWidth: i32 = 0,
    lfEscapement: i32 = 0,
    lfOrientation: i32 = 0,
    lfWeight: i32 = 400,
    lfItalic: u8 = 0,
    lfUnderline: u8 = 0,
    lfStrikeOut: u8 = 0,
    lfCharSet: u8 = 1,
    lfOutPrecision: u8 = 0,
    lfClipPrecision: u8 = 0,
    lfQuality: u8 = 2, // CLEARTYPE_QUALITY
    lfPitchAndFamily: u8 = 0,
    lfFaceName: [32]u16 = std.mem.zeroes([32]u16),
};

const NONCLIENTMETRICSW = extern struct {
    cbSize: UINT,
    iBorderWidth: i32,
    iScrollWidth: i32,
    iScrollHeight: i32,
    iCaptionWidth: i32,
    iCaptionHeight: i32,
    lfCaptionFont: LOGFONTW,
    iSmCaptionWidth: i32,
    iSmCaptionHeight: i32,
    lfSmCaptionFont: LOGFONTW,
    iMenuWidth: i32,
    iMenuHeight: i32,
    lfMenuFont: LOGFONTW,
    lfStatusFont: LOGFONTW,
    lfMessageFont: LOGFONTW,
    iPaddedBorderWidth: i32,
};

// ---------------------------------------------------------------------------
// Win32 constants
// ---------------------------------------------------------------------------

const WS_CHILD: DWORD = 0x40000000;
const WS_VISIBLE: DWORD = 0x10000000;
const WS_BORDER: DWORD = 0x00800000;
const WS_TABSTOP: DWORD = 0x00010000;
const WS_GROUP: DWORD = 0x00020000;
const WS_VSCROLL: DWORD = 0x00200000;
const WS_DISABLED: DWORD = 0x08000000;

const BS_PUSHBUTTON: DWORD = 0x00000000;
const BS_DEFPUSHBUTTON: DWORD = 0x00000001;
const BS_NOTIFY: DWORD = 0x00004000;

const ES_LEFT: DWORD = 0x0000;
const ES_AUTOHSCROLL: DWORD = 0x0080;
const ES_MULTILINE: DWORD = 0x0004;
const ES_READONLY: DWORD = 0x0800;

const SS_LEFT: DWORD = 0x00000000;
const SS_CENTER: DWORD = 0x00000001;
const SS_RIGHT: DWORD = 0x00000002;
const SS_NOTIFY: DWORD = 0x00000100;
const SS_WORDELLIPSIS: DWORD = 0x0000C000;

const CBS_DROPDOWNLIST: DWORD = 0x0003;
const CBS_HASSTRINGS: DWORD = 0x0200;

const COLOR_WINDOW: c_int = 5;
const COLOR_WINDOWTEXT: c_int = 8;
const COLOR_BTNFACE: c_int = 15;

const TRANSPARENT_MODE: c_int = 1;
const OPAQUE_MODE: c_int = 2;

const PS_SOLID: c_int = 0;
const PS_DASH: c_int = 1;
const PS_NULL: c_int = 5;

const DT_LEFT: UINT = 0x00000000;
const DT_CENTER: UINT = 0x00000001;
const DT_RIGHT: UINT = 0x00000002;
const DT_VCENTER: UINT = 0x00000004;
const DT_WORDBREAK: UINT = 0x00000010;
const DT_SINGLELINE: UINT = 0x00000020;
const DT_CALCRECT: UINT = 0x00000400;
const DT_END_ELLIPSIS: UINT = 0x00008000;

const SPI_GETNONCLIENTMETRICS: UINT = 0x0029;

const WM_SETFONT: UINT = 0x0030;
const CB_ADDSTRING: UINT = 0x0143;
const CB_SETCURSEL: UINT = 0x014E;
const CB_GETCURSEL: UINT = 0x0147;

const SW_HIDE: c_int = 0;
const SW_SHOW: c_int = 5;
const SW_SHOWNA: c_int = 8;

const NULL_HANDLE: ?*anyopaque = null;

// ---------------------------------------------------------------------------
// Win32 extern functions
// ---------------------------------------------------------------------------

extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: ?[*:0]const u16,
    lpWindowName: ?[*:0]const u16,
    dwStyle: DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?*anyopaque,
    hMenu: ?*anyopaque,
    hInstance: ?*anyopaque,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;

extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: c_int) callconv(.winapi) c_int;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn FillRect(hDC: HDC, lprc: *const RECT, hbr: *anyopaque) callconv(.winapi) c_int;
extern "user32" fn DrawTextW(hDC: HDC, lpString: [*]const u16, nCount: c_int, lpRect: *RECT, uFormat: UINT) callconv(.winapi) c_int;
extern "user32" fn SystemParametersInfoW(uAction: UINT, uParam: UINT, pvParam: *anyopaque, fWinIni: UINT) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(hWnd: HWND) callconv(.winapi) UINT;
extern "user32" fn GetSysColorBrush(nIndex: c_int) callconv(.winapi) *anyopaque;
extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?*anyopaque, X: i32, Y: i32, cx: i32, cy: i32, uFlags: UINT) callconv(.winapi) BOOL;
extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn FrameRect(hDC: HDC, lprc: *const RECT, hbr: *anyopaque) callconv(.winapi) c_int;

extern "gdi32" fn CreatePen(fnPenStyle: c_int, nWidth: c_int, crColor: COLORREF) callconv(.winapi) *anyopaque;
extern "gdi32" fn CreateSolidBrush(crColor: COLORREF) callconv(.winapi) *anyopaque;
extern "gdi32" fn SelectObject(hdc: HDC, h: *anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(ho: *anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn GetStockObject(i: c_int) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SetBkMode(hdc: HDC, iBkMode: c_int) callconv(.winapi) c_int;
extern "gdi32" fn SetBkColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
extern "gdi32" fn SetTextColor(hdc: HDC, crColor: COLORREF) callconv(.winapi) COLORREF;
extern "gdi32" fn Rectangle(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32) callconv(.winapi) BOOL;
extern "gdi32" fn CreateFontIndirectW(lplf: *const LOGFONTW) callconv(.winapi) ?*anyopaque;

// ---------------------------------------------------------------------------
// Control IDs
// ---------------------------------------------------------------------------

pub const IDC_KEY_EDIT: usize = 101;
pub const IDC_ACTIVATE_BTN: usize = 102;
pub const IDC_ACTIV_ERR: usize = 104;
pub const IDC_FORMAT_COMBO: usize = 201;
pub const IDC_BROWSE_BTN: usize = 202;
pub const IDC_GENERATE_BTN: usize = 203;
pub const IDC_CLEAR_BTN: usize = 204;
pub const IDC_STATUS_TEXT: usize = 205;
pub const IDC_OUTPUT_TEXT: usize = 301;
pub const IDC_SHOW_BTN: usize = 302;
pub const IDC_OPEN_BTN: usize = 303;
pub const IDC_AGAIN_BTN: usize = 304;

// ---------------------------------------------------------------------------
// Global control handles (set in createControls)
// ---------------------------------------------------------------------------

pub var key_edit: ?*anyopaque = null;
pub var activate_btn: ?*anyopaque = null;
pub var activ_err: ?*anyopaque = null;
pub var format_combo: ?*anyopaque = null;
pub var browse_btn: ?*anyopaque = null;
pub var generate_btn: ?*anyopaque = null;
pub var clear_btn: ?*anyopaque = null;
pub var status_text: ?*anyopaque = null;
pub var output_text: ?*anyopaque = null;
pub var show_btn: ?*anyopaque = null;
pub var open_btn: ?*anyopaque = null;
pub var again_btn: ?*anyopaque = null;

// Stored font handle for cleanup
pub var g_hfont: ?*anyopaque = null;

// ---------------------------------------------------------------------------
// DPI-scaled layout helpers
// ---------------------------------------------------------------------------

inline fn sc(v: i32, dpi: u32) i32 {
    return @divTrunc(v * @as(i32, @intCast(dpi)), 96);
}

fn makeW(comptime s: []const u8) [s.len:0]u16 {
    comptime {
        var buf: [s.len:0]u16 = undefined;
        for (s, 0..) |c, i| buf[i] = c;
        return buf;
    }
}

// Returns a static [*:0]const u16 pointer suitable for Win32 string parameters.
// The returned pointer is valid for the lifetime of the program.
fn toUtf16Z(comptime s: []const u8) [*:0]const u16 {
    const W = struct {
        const data: [s.len:0]u16 = makeW(s);
    };
    return &W.data;
}

pub extern "user32" fn EnableWindow(hWnd: *anyopaque, bEnable: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(hWnd: *anyopaque, nCmdShow: c_int) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// createControls — called once in WM_CREATE
// ---------------------------------------------------------------------------

pub fn createControls(hwnd: HWND, hinstance: *anyopaque) void {
    const dpi = GetDpiForWindow(hwnd);

    // Class names as sentinel-terminated UTF-16 literals
    const CLS_EDIT = toUtf16Z("EDIT");
    const CLS_BTN = toUtf16Z("BUTTON");
    const CLS_STATIC = toUtf16Z("STATIC");
    const CLS_COMBO = toUtf16Z("COMBOBOX");

    // --- License gate controls ---

    key_edit = CreateWindowExW(
        0x0200, // WS_EX_CLIENTEDGE
        CLS_EDIT,
        null,
        WS_CHILD | WS_VISIBLE | WS_BORDER | WS_TABSTOP | ES_LEFT | ES_AUTOHSCROLL,
        sc(60, dpi), sc(185, dpi), sc(360, dpi), sc(28, dpi),
        hwnd, @ptrFromInt(IDC_KEY_EDIT), hinstance, null,
    );

    activate_btn = CreateWindowExW(
        0,
        CLS_BTN,
        toUtf16Z("Activate"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
        sc(165, dpi), sc(228, dpi), sc(150, dpi), sc(32, dpi),
        hwnd, @ptrFromInt(IDC_ACTIVATE_BTN), hinstance, null,
    );

    activ_err = CreateWindowExW(
        0,
        CLS_STATIC,
        null,
        WS_CHILD | SS_LEFT | SS_WORDELLIPSIS,
        sc(60, dpi), sc(270, dpi), sc(360, dpi), sc(40, dpi),
        hwnd, @ptrFromInt(IDC_ACTIV_ERR), hinstance, null,
    );

    // --- Drop zone controls ---

    format_combo = CreateWindowExW(
        0,
        CLS_COMBO,
        null,
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWNLIST | CBS_HASSTRINGS,
        sc(20, dpi), sc(308, dpi), sc(160, dpi), sc(200, dpi),
        hwnd, @ptrFromInt(IDC_FORMAT_COMBO), hinstance, null,
    );
    if (format_combo) |combo| {
        const combo_strs = [_][*:0]const u16{
            toUtf16Z("PDF"),
            toUtf16Z("Word (.docx)"),
            toUtf16Z("Markdown"),
            toUtf16Z("All Formats"),
        };
        for (combo_strs) |s| {
            _ = SendMessageW(combo, CB_ADDSTRING, 0, @bitCast(@intFromPtr(s)));
        }
        _ = SendMessageW(combo, CB_SETCURSEL, 0, 0);
    }

    browse_btn = CreateWindowExW(
        0,
        CLS_BTN,
        toUtf16Z("Browse..."),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
        sc(193, dpi), sc(308, dpi), sc(80, dpi), sc(28, dpi),
        hwnd, @ptrFromInt(IDC_BROWSE_BTN), hinstance, null,
    );

    generate_btn = CreateWindowExW(
        0,
        CLS_BTN,
        toUtf16Z("Generate"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_DISABLED | BS_PUSHBUTTON,
        sc(286, dpi), sc(308, dpi), sc(114, dpi), sc(28, dpi),
        hwnd, @ptrFromInt(IDC_GENERATE_BTN), hinstance, null,
    );

    clear_btn = CreateWindowExW(
        0,
        CLS_BTN,
        toUtf16Z("Clear"),
        WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
        sc(286, dpi), sc(344, dpi), sc(114, dpi), sc(28, dpi),
        hwnd, @ptrFromInt(IDC_CLEAR_BTN), hinstance, null,
    );

    status_text = CreateWindowExW(
        0,
        CLS_STATIC,
        null,
        WS_CHILD | WS_VISIBLE | SS_LEFT,
        sc(20, dpi), sc(348, dpi), sc(260, dpi), sc(28, dpi),
        hwnd, @ptrFromInt(IDC_STATUS_TEXT), hinstance, null,
    );

    // --- Done controls ---

    output_text = CreateWindowExW(
        0x0200, // WS_EX_CLIENTEDGE
        CLS_EDIT,
        null,
        WS_CHILD | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_LEFT,
        sc(20, dpi), sc(20, dpi), sc(440, dpi), sc(220, dpi),
        hwnd, @ptrFromInt(IDC_OUTPUT_TEXT), hinstance, null,
    );

    show_btn = CreateWindowExW(
        0,
        CLS_BTN,
        toUtf16Z("Show in Explorer"),
        WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
        sc(20, dpi), sc(255, dpi), sc(140, dpi), sc(35, dpi),
        hwnd, @ptrFromInt(IDC_SHOW_BTN), hinstance, null,
    );

    open_btn = CreateWindowExW(
        0,
        CLS_BTN,
        toUtf16Z("Open"),
        WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
        sc(173, dpi), sc(255, dpi), sc(140, dpi), sc(35, dpi),
        hwnd, @ptrFromInt(IDC_OPEN_BTN), hinstance, null,
    );

    again_btn = CreateWindowExW(
        0,
        CLS_BTN,
        toUtf16Z("Generate Another"),
        WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
        sc(326, dpi), sc(255, dpi), sc(134, dpi), sc(35, dpi),
        hwnd, @ptrFromInt(IDC_AGAIN_BTN), hinstance, null,
    );
}

// ---------------------------------------------------------------------------
// setFont — apply system message font to all child controls
// ---------------------------------------------------------------------------

pub fn setFont(hwnd: HWND) void {
    _ = hwnd;
    var ncm: NONCLIENTMETRICSW = std.mem.zeroes(NONCLIENTMETRICSW);
    ncm.cbSize = @sizeOf(NONCLIENTMETRICSW);
    _ = SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, ncm.cbSize, &ncm, 0);
    const hf = CreateFontIndirectW(&ncm.lfMessageFont) orelse return;
    g_hfont = hf;

    // Apply to all child controls
    const ctls = [_]?*anyopaque{
        key_edit, activate_btn, activ_err, format_combo, browse_btn,
        generate_btn, clear_btn, status_text, output_text, show_btn,
        open_btn, again_btn,
    };
    for (ctls) |oc| {
        if (oc) |c| _ = SendMessageW(c, WM_SETFONT, @intFromPtr(hf), 1);
    }
}

// ---------------------------------------------------------------------------
// updateVisibility — show/hide controls per state
// ---------------------------------------------------------------------------

pub fn updateVisibility(tag: state.AppStateTag) void {
    // License gate
    const lic = @intFromBool(tag == .license_gate);
    if (key_edit) |c| _ = ShowWindow(c, if (lic != 0) SW_SHOW else SW_HIDE);
    if (activate_btn) |c| _ = ShowWindow(c, if (lic != 0) SW_SHOW else SW_HIDE);
    // activ_err stays hidden until there's an error message

    // Drop zone controls
    const dz = @intFromBool(tag == .drop_zone or tag == .file_loaded or tag == .generating);
    if (format_combo) |c| _ = ShowWindow(c, if (dz != 0) SW_SHOW else SW_HIDE);
    if (browse_btn) |c| _ = ShowWindow(c, if (dz != 0) SW_SHOW else SW_HIDE);
    if (generate_btn) |c| _ = ShowWindow(c, if (dz != 0) SW_SHOW else SW_HIDE);
    if (status_text) |c| _ = ShowWindow(c, if (dz != 0) SW_SHOW else SW_HIDE);

    // Clear button only when file is loaded or generating
    const cl = @intFromBool(tag == .file_loaded or tag == .generating);
    if (clear_btn) |c| _ = ShowWindow(c, if (cl != 0) SW_SHOW else SW_HIDE);

    // Generate button enabled only when file_loaded
    if (generate_btn) |c| {
        _ = EnableWindow(c, if (tag == .file_loaded) 1 else 0);
    }

    // Done controls
    const dn = @intFromBool(tag == .done);
    if (output_text) |c| _ = ShowWindow(c, if (dn != 0) SW_SHOW else SW_HIDE);
    if (show_btn) |c| _ = ShowWindow(c, if (dn != 0) SW_SHOW else SW_HIDE);
    if (open_btn) |c| _ = ShowWindow(c, if (dn != 0) SW_SHOW else SW_HIDE);
    if (again_btn) |c| _ = ShowWindow(c, if (dn != 0) SW_SHOW else SW_HIDE);
}

// ---------------------------------------------------------------------------
// setStatusText — update the status bar label (UTF-8 in, UTF-16 out)
// ---------------------------------------------------------------------------

pub fn setStatusText(hwnd: HWND, msg_utf8: [*:0]const u8) void {
    _ = hwnd;
    const s = std.mem.span(msg_utf8);
    var buf: [512:0]u16 = std.mem.zeroes([512:0]u16);
    const n = std.unicode.utf8ToUtf16Le(buf[0..buf.len], s) catch 0;
    buf[n] = 0;
    if (status_text) |c| _ = SetWindowTextW(c, &buf);
}

// ---------------------------------------------------------------------------
// setActivationError — show error label with red text
// ---------------------------------------------------------------------------

pub fn setActivationError(msg_utf8: [*:0]const u8) void {
    const s = std.mem.span(msg_utf8);
    var buf: [512:0]u16 = std.mem.zeroes([512:0]u16);
    const n = std.unicode.utf8ToUtf16Le(buf[0..buf.len], s) catch 0;
    buf[n] = 0;
    if (activ_err) |c| {
        _ = SetWindowTextW(c, &buf);
        _ = ShowWindow(c, SW_SHOW);
    }
}

// ---------------------------------------------------------------------------
// setOutputText — populate the done-state output text area
// ---------------------------------------------------------------------------

pub fn setOutputText(text_utf8: []const u8) void {
    var buf: [4096:0]u16 = std.mem.zeroes([4096:0]u16);
    const n = std.unicode.utf8ToUtf16Le(buf[0..buf.len], text_utf8) catch 0;
    buf[n] = 0;
    if (output_text) |c| _ = SetWindowTextW(c, &buf);
}

// ---------------------------------------------------------------------------
// getKeyText — read license key edit control (UTF-8)
// ---------------------------------------------------------------------------

pub fn getKeyText(buf: []u8) []u8 {
    var wbuf: [128]u16 = std.mem.zeroes([128]u16);
    const len = if (key_edit) |c|
        @as(usize, @intCast(@max(0, GetWindowTextW(c, &wbuf, @intCast(wbuf.len)))))
    else
        0;
    const nbytes = std.unicode.utf16LeToUtf8(buf, wbuf[0..len]) catch return buf[0..0];
    return buf[0..nbytes];
}

// ---------------------------------------------------------------------------
// getSelectedFormat — read combo box selection → Format enum
// ---------------------------------------------------------------------------

pub fn getSelectedFormat() state.Format {
    if (format_combo) |c| {
        const sel = SendMessageW(c, CB_GETCURSEL, 0, 0);
        return switch (sel) {
            0 => .pdf,
            1 => .docx,
            2 => .md,
            3 => .all,
            else => .pdf,
        };
    }
    return .pdf;
}

// ---------------------------------------------------------------------------
// paint — handles WM_PAINT custom drawing
// ---------------------------------------------------------------------------

pub fn paint(hwnd: HWND, app_state: *const state.AppState) void {
    var ps: PAINTSTRUCT = undefined;
    const hdc = BeginPaint(hwnd, &ps);
    defer _ = EndPaint(hwnd, &ps);

    // Fill window background
    var client: RECT = undefined;
    _ = GetClientRect(hwnd, &client);
    _ = FillRect(hdc, &client, GetSysColorBrush(COLOR_BTNFACE));

    const tag = app_state.tag;

    if (tag == .license_gate) {
        paintLicenseGate(hdc, &client);
        return;
    }

    if (tag == .drop_zone or tag == .file_loaded or tag == .generating) {
        paintDropZone(hdc, &client, app_state);
        return;
    }

    if (tag == .done) {
        paintDone(hdc, &client, app_state);
        return;
    }
}

fn paintLicenseGate(hdc: HDC, client: *const RECT) void {
    _ = SetBkMode(hdc, TRANSPARENT_MODE);

    // Title
    const title = comptime makeW("RTMify Trace");
    var title_rect = RECT{
        .left = 0,
        .top = @divTrunc(client.bottom, 6),
        .right = client.right,
        .bottom = @divTrunc(client.bottom, 6) + 60,
    };
    _ = SetTextColor(hdc, 0x001A1A2E); // --dark
    _ = DrawTextW(hdc, &title, @intCast(title.len - 1), &title_rect, DT_CENTER | DT_SINGLELINE | DT_VCENTER);

    // Subtitle
    const sub = comptime makeW("Enter your license key to activate.");
    var sub_rect = RECT{
        .left = 60,
        .top = title_rect.bottom + 20,
        .right = client.right - 60,
        .bottom = title_rect.bottom + 50,
    };
    _ = SetTextColor(hdc, 0x00555555);
    _ = DrawTextW(hdc, &sub, @intCast(sub.len - 1), &sub_rect, DT_CENTER | DT_SINGLELINE | DT_VCENTER);

    // "Need a license?" link text (bottom)
    const link = comptime makeW("Need a license? Visit store.rtmify.io");
    var link_rect = RECT{
        .left = 0,
        .top = client.bottom - 60,
        .right = client.right,
        .bottom = client.bottom - 40,
    };
    _ = SetTextColor(hdc, 0x00C0651A); // blue-ish
    _ = DrawTextW(hdc, &link, @intCast(link.len - 1), &link_rect, DT_CENTER | DT_SINGLELINE | DT_VCENTER);
}

fn paintDropZone(hdc: HDC, client: *const RECT, app_state: *const state.AppState) void {
    const dz_margin: i32 = 20;
    const dz_bottom: i32 = @divTrunc(client.bottom * 6, 10); // ~60% of height
    var dz_rect = RECT{
        .left = dz_margin,
        .top = 15,
        .right = client.right - dz_margin,
        .bottom = dz_bottom,
    };

    // Fill drop zone with slightly lighter bg
    const drop_bg = CreateSolidBrush(0x00F5F5F5);
    defer _ = DeleteObject(drop_bg);
    _ = FillRect(hdc, &dz_rect, drop_bg);

    // Draw dashed border (PS_DASH requires pen width = 1)
    const border_pen = CreatePen(PS_DASH, 1, 0x00969696);
    defer _ = DeleteObject(border_pen);
    const null_brush = GetStockObject(5) orelse return; // NULL_BRUSH = 5
    const old_pen = SelectObject(hdc, border_pen);
    const old_brush = SelectObject(hdc, null_brush);
    defer {
        if (old_pen) |p| _ = SelectObject(hdc, p);
        if (old_brush) |b| _ = SelectObject(hdc, b);
    }
    _ = SetBkMode(hdc, OPAQUE_MODE); // dashed pen requires opaque bg mode
    _ = Rectangle(hdc, dz_rect.left, dz_rect.top, dz_rect.right, dz_rect.bottom);

    _ = SetBkMode(hdc, TRANSPARENT_MODE);
    _ = SetTextColor(hdc, 0x00555555);

    // Center text in drop zone
    if (app_state.summary) |*summary| {
        // Show filename
        var name_w: [256:0]u16 = std.mem.zeroes([256:0]u16);
        const name_slice = std.mem.sliceTo(&summary.display_name, 0);
        _ = std.unicode.utf8ToUtf16Le(name_w[0..name_w.len], name_slice) catch 0;
        const name_len = std.mem.indexOfScalar(u16, &name_w, 0) orelse 256;

        var name_rect = RECT{
            .left = dz_rect.left + 20,
            .top = dz_rect.top + @divTrunc(dz_rect.bottom - dz_rect.top, 2) - 40,
            .right = dz_rect.right - 20,
            .bottom = dz_rect.top + @divTrunc(dz_rect.bottom - dz_rect.top, 2) - 10,
        };
        _ = SetTextColor(hdc, 0x001A1A1A);
        _ = DrawTextW(hdc, &name_w, @intCast(name_len), &name_rect, DT_CENTER | DT_SINGLELINE | DT_END_ELLIPSIS);

        // Show gap count if any
        if (summary.gap_count > 0) {
            const gap_rect = RECT{
                .left = dz_rect.left + 20,
                .top = dz_rect.bottom - 50,
                .right = dz_rect.right - 20,
                .bottom = dz_rect.bottom - 10,
            };
            // Yellow gap banner
            const gap_bg = CreateSolidBrush(0x00E1F8FF); // amber-ish
            defer _ = DeleteObject(gap_bg);
            _ = FillRect(hdc, &gap_rect, gap_bg);
            // Amber border
            const gap_border = CreateSolidBrush(0x0025A8F9);
            defer _ = DeleteObject(gap_border);
            _ = FrameRect(hdc, &gap_rect, gap_border);

            var gap_msg_buf: [128]u8 = undefined;
            const gap_msg = std.fmt.bufPrint(&gap_msg_buf, "{d} traceability gap{s} detected \xe2\x80\x94 flagged in report", .{
                summary.gap_count,
                if (summary.gap_count == 1) "" else "s",
            }) catch "Traceability gaps detected";
            var gap_w: [256:0]u16 = std.mem.zeroes([256:0]u16);
            _ = std.unicode.utf8ToUtf16Le(gap_w[0..gap_w.len], gap_msg) catch 0;
            const gap_wlen = std.mem.indexOfScalar(u16, &gap_w, 0) orelse 256;
            var gap_text_rect = gap_rect;
            _ = SetTextColor(hdc, 0x001A1A1A);
            _ = DrawTextW(hdc, &gap_w, @intCast(gap_wlen), &gap_text_rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        }
    } else {
        // Empty drop zone
        const hint = comptime makeW("Drop .xlsx here");
        var hint_rect = RECT{
            .left = dz_rect.left,
            .top = dz_rect.top,
            .right = dz_rect.right,
            .bottom = dz_rect.bottom,
        };
        _ = DrawTextW(hdc, &hint, @intCast(hint.len - 1), &hint_rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }
}

fn paintDone(hdc: HDC, client: *const RECT, app_state: *const state.AppState) void {
    _ = client;
    _ = app_state;
    _ = SetBkMode(hdc, TRANSPARENT_MODE);
    // Title drawn via STATIC control text; output path via EDIT control.
    // Just paint a subtle success header.
    const hdr = comptime makeW("Report Generated");
    var hdr_rect = RECT{ .left = 20, .top = 0, .right = 460, .bottom = 20 };
    _ = SetTextColor(hdc, 0x00228B22);
    _ = DrawTextW(hdc, &hdr, @intCast(hdr.len - 1), &hdr_rect, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
}
