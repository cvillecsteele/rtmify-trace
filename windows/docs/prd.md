# RTMify Trace — Windows Shell
## Product Requirements Document
### Version 0.1

---

## 1. What This Is

A native Windows application that wraps `librtmify` in a drag-and-drop GUI. The user drags an XLSX file onto the window, picks an output format, and gets a traceability report. No command prompt. No arguments. One window, one workflow.

The app is a Win32 GUI written in Zig. All spreadsheet parsing, graph construction, gap detection, and report rendering happen inside `librtmify.a`, which is statically linked at compile time. The Zig GUI code handles window creation, drag-and-drop, file dialogs, license activation, and progress display. It calls the same six C ABI functions the macOS shell and CLI use.

The entire application — GUI and library — compiles to a single `.exe`. No installer. No DLLs. No runtime. No `.msi`. The user downloads the file, double-clicks it, and it runs.

---

## 2. What We Have

`librtmify.a` — a static library compiled from Zig 0.15.2 with a C ABI. Zero external dependencies. The C ABI surface is identical to what the macOS shell links against:

```c
int32_t rtmify_load(const char* xlsx_path, RtmifyGraph** out_graph);
int32_t rtmify_generate(const RtmifyGraph* graph, const char* format,
                        const char* output_path, const char* project_name);
int32_t rtmify_gap_count(const RtmifyGraph* graph);
int32_t rtmify_warning_count(void);
const char* rtmify_last_error(void);
void rtmify_free(RtmifyGraph* graph);

int32_t rtmify_activate_license(const char* license_key);
int32_t rtmify_check_license(void);
int32_t rtmify_deactivate_license(void);
```

The license cache lives at `%USERPROFILE%\.rtmify\license.json`. The CLI already reads and writes this path. The GUI uses the same path.

---

## 3. Build Artifact

One file: `rtmify-trace.exe`.

No installer. No DLLs alongside. No `.zip` to unpack (though LemonSqueezy may wrap it in a zip for download — the user extracts one file). The user can put it anywhere: Desktop, Downloads, `C:\Tools\`. It runs from wherever it is.

Build:

```
zig build win-gui -Dtarget=x86_64-windows
```

A single `build.zig` step that:
1. Compiles the Win32 GUI source
2. Links `librtmify` statically (same source tree, same build system)
3. Sets `.subsystem = .windows` to suppress the console window
4. Embeds the application icon and version info via a `.rc` resource file
5. Outputs `rtmify-trace.exe`

Target: Windows 10 1809+ and Windows 11. This covers every Windows machine still receiving security updates.

For ARM64 Windows (Surface Pro X, etc.): a second build with `-Dtarget=aarch64-windows` produces `rtmify-trace-arm64.exe`. Two separate executables, uploaded to LemonSqueezy as two files. Windows does not have a universal binary mechanism like macOS. The x64 build runs on ARM64 via emulation (slowly), so the ARM64 build is a nice-to-have, not a blocker.

---

## 4. Why Zig for the Windows GUI

The GUI could be C, C++, C#, or Zig. Zig wins on three counts:

**Same toolchain as `librtmify`.** No second compiler, no second build system. `build.zig` already produces the library. Adding a Win32 GUI executable to the same build file is one additional `addExecutable` call. The GUI source files sit in the same repo, import the same library, and cross-compile from macOS or Linux the same way the CLI does.

**Win32 is a C API.** Zig calls C APIs natively. `CreateWindowExW`, `DragAcceptFiles`, `WM_DROPFILES`, `GetOpenFileNameW` — these are all available through `@cImport` of `windows.h` or through Zig's `std.os.windows` bindings. No wrappers needed.

**Static linking, no runtime.** Zig targets `x86_64-windows-gnu` (MinGW ABI) which statically links everything. The result is a standalone `.exe` that runs on a clean Windows install with no Visual C++ Redistributable, no .NET, no MSVC runtime DLLs.

The tradeoff: Win32 GUI code in any language is verbose. Creating a window, handling the message loop, positioning controls — it's 2002-era API design. But the app has four controls (a text area, a combo box, two buttons) and a drop target. The verbosity is bounded.

---

## 5. Application States

Identical to the macOS shell. Three states.

### State 1: License Gate

Shown on launch if `rtmify_check_license()` returns non-zero.

The window displays:
- RTMify Trace title text (drawn via `DrawTextW` or a static control)
- An edit control for the license key
- An "Activate" button
- A "Need a license?" link (opens `https://store.rtmify.io` in the default browser via `ShellExecuteW`)
- An error text area (hidden until activation fails)

On activation attempt:
- Button text changes to "Activating..." and disables
- Spawn a worker thread: `rtmify_activate_license(key)`
- On success: post a custom message to the window, transition to State 2
- On failure: post custom message with error, show `rtmify_last_error()` text, re-enable button

### State 2: Ready (Drop Zone)

Shown on launch if `rtmify_check_license()` returns 0, or after successful activation.

The window displays:
- A large drop zone area (painted as a dashed rectangle in `WM_PAINT`, centered text: "Drop .xlsx here")
- A format picker below the drop zone (combo box: PDF / Word / Markdown / All)
- A "Browse..." button (opens `GetOpenFileNameW` dialog filtered to `*.xlsx`)
- A "Generate" button (disabled until a file is loaded)
- A status line at the bottom (static text control)

Drop zone behavior:
- The window calls `DragAcceptFiles(hwnd, TRUE)` at creation
- `WM_DROPFILES`: extract path via `DragQueryFileW`. Check extension. Accept `.xlsx` only.
- Non-`.xlsx` drops: set status line text ("That's a .xls file — open it in Excel and re-save as .xlsx." / "RTMify Trace reads .xlsx files.")
- Multiple files dropped: accept only the first
- On valid file: spawn worker thread calling `rtmify_load(path, &graph)`
- While loading: status line shows "Reading spreadsheet..." and drop zone text updates
- On success: transition to State 2b
- On failure: show error in a `MessageBoxW`. Return to empty drop zone.

### State 2b: File Loaded

The window displays:
- Drop zone shows filename and summary: "47 requirements, 23 user needs, 42 tests, 12 risks"
- If gaps > 0: yellow banner (painted rectangle with text): "7 traceability gaps detected — they'll be flagged in the report"
- Format picker, Generate button (enabled), Clear button
- User can drop a different file to replace

On "Generate":
- Button text → "Generating...", disables
- Worker thread: `rtmify_generate` (once per format, or three times for "All")
- On success: transition to State 3
- On failure: `MessageBoxW` with error, return to State 2b

**Output path:** Same logic as macOS. Report saves next to the input file. `requirements.xlsx` → `requirements-rtm.pdf`. Numeric suffix if file exists. No save dialog.

**Project name:** Derived from input filename, same as macOS.

### State 3: Done

The window displays:
- "Report generated" message
- Output filename and path
- "Show in Explorer" button (`ShellExecuteW` with `"open"` on the parent directory, or `SHOpenFolderAndSelectItems` to select the file)
- "Open" button (`ShellExecuteW` on the output file)
- "Generate Another" button → State 2 with same file, or State 2 empty

---

## 6. Window Specifications

**Size:** 480 × 520 pixels (logical), fixed. `WS_OVERLAPPEDWINDOW` without `WS_THICKFRAME` and `WS_MAXIMIZEBOX` to prevent resizing and maximizing.

**Title:** "RTMify Trace"

**DPI awareness:** The app manifest declares per-monitor DPI awareness (`<dpiAwareness>PerMonitorV2</dpiAwareness>`). All pixel measurements are scaled by the DPI factor at runtime. Without this, the window looks tiny on 4K displays or blurry if Windows scales it.

**Icon:** Embedded via a `.rc` resource file compiled into the exe. The icon appears in the title bar, taskbar, and Alt-Tab.

**Font:** System default (Segoe UI on Windows 10/11). Retrieved via `SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, ...)` and applied to all controls via `WM_SETFONT`.

---

## 7. Drag and Drop

Win32 drag-and-drop uses the `WM_DROPFILES` message.

Setup: `DragAcceptFiles(hwnd, TRUE)` in `WM_CREATE`.

Handler:

```
WM_DROPFILES:
    count = DragQueryFileW(hDrop, 0xFFFFFFFF, null, 0)  // file count
    DragQueryFileW(hDrop, 0, &path_buf, path_buf.len)   // first file path
    DragFinish(hDrop)
    // check extension, proceed or reject
```

The entire client area is the drop target. Win32's `DragAcceptFiles` applies to the whole window by default.

Visual feedback during drag-over requires implementing `IDropTarget` (COM interface) instead of the simpler `WM_DROPFILES`. For v1, `WM_DROPFILES` is sufficient — the cursor changes to indicate a drop is possible, but the drop zone border doesn't animate during hover. If the lack of hover feedback feels wrong during testing, upgrade to `IDropTarget` in v1.1. The implementation is ~60 lines of COM boilerplate.

File type filtering on drop: check the file extension from the path string. `.xlsx` → accept. `.xls` → specific message. Everything else → generic message. This happens after the drop, not during drag-over (unless `IDropTarget` is implemented).

---

## 8. Threading Model

Win32 GUI runs a message loop on the main thread. Long-running `librtmify` calls must run on worker threads to keep the window responsive.

Three operations go to worker threads:
1. `rtmify_load` — file I/O and parsing
2. `rtmify_generate` — report rendering
3. `rtmify_activate_license` — network I/O

Pattern: spawn a thread with `std.Thread.spawn`, have it call the C ABI function, then post a custom window message (`WM_APP + N`) back to the main thread with the result. The message handler updates UI state.

```zig
const WM_LOAD_COMPLETE = std.os.windows.WM_APP + 1;
const WM_GENERATE_COMPLETE = std.os.windows.WM_APP + 2;
const WM_ACTIVATE_COMPLETE = std.os.windows.WM_APP + 3;

fn loadWorker(hwnd: HWND, path: [*:0]const u8) void {
    const status = rtmify_load(path, &graph_ptr);
    _ = PostMessageW(hwnd, WM_LOAD_COMPLETE, @intCast(status), 0);
}

// In WndProc:
WM_LOAD_COMPLETE => {
    const status: i32 = @intCast(wParam);
    if (status == RTMIFY_OK) {
        transitionToFileLoaded();
    } else {
        showError(rtmify_last_error());
    }
}
```

No mutexes needed. The worker thread calls one `librtmify` function, gets one result, posts one message. The main thread handles the message and updates state. No shared mutable state between threads.

---

## 9. Resource File

A `.rc` file compiled by Zig's resource compiler embeds metadata into the `.exe`:

```rc
// rtmify.rc
1 ICON "rtmify.ico"

VS_VERSION_INFO VERSIONINFO
FILEVERSION    1,0,0,0
PRODUCTVERSION 1,0,0,0
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904E4"
        BEGIN
            VALUE "CompanyName", "RTMify"
            VALUE "FileDescription", "RTMify Trace — Requirements Traceability Matrix Generator"
            VALUE "FileVersion", "1.0.0"
            VALUE "InternalName", "rtmify-trace"
            VALUE "LegalCopyright", "© 2026 RTMify"
            VALUE "OriginalFilename", "rtmify-trace.exe"
            VALUE "ProductName", "RTMify Trace"
            VALUE "ProductVersion", "1.0.0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x0409, 0x04E4
    END
END
```

This gives the `.exe` a proper icon in Explorer, correct metadata in Properties → Details, and a real name in Task Manager instead of "rtmify-trace.exe".

The application manifest (DPI awareness, visual styles) is embedded via:

```rc
1 RT_MANIFEST "rtmify.manifest"
```

The manifest file:

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">
        PerMonitorV2
      </dpiAwareness>
    </windowsSettings>
  </application>
  <dependency>
    <dependentAssembly>
      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls"
        version="6.0.0.0" processorArchitecture="*"
        publicKeyToken="6595b64144ccf1df" language="*"/>
    </dependentAssembly>
  </dependency>
</assembly>
```

The Common Controls v6 dependency gives the app Windows 10/11 visual styles (themed buttons, edit controls, combo boxes) instead of the Windows 95 look. Without this manifest entry, every control renders in the classic flat gray style.

---

## 10. Error Handling

Same principle as macOS: every user-facing error comes from `rtmify_last_error()`. The Zig GUI code never composes its own messages about parsing or generation failures.

**File load and generation errors:** `MessageBoxW` with the error text, `MB_OK | MB_ICONWARNING` style. The warning icon (yellow triangle) is less alarming than the error icon (red circle). Parsing failures are recoverable ("fix your spreadsheet and try again"), not catastrophic.

**Activation errors:** displayed inline as a static text control below the license key field, colored red. No message box — the user is already looking at the form.

**Null guard:** if `rtmify_load` returns non-zero, the graph pointer may be null. Never call `rtmify_generate`, `rtmify_gap_count`, or `rtmify_free` on a null pointer. The view model tracks state; the generate button is only enabled when a graph is loaded.

---

## 11. Custom Painting

The drop zone and gap banner are not standard Win32 controls. They're painted in `WM_PAINT`.

**Drop zone:** A dashed rectangle drawn with `CreatePen(PS_DASH, ...)` and `Rectangle()`. Center-aligned text drawn with `DrawTextW` using `DT_CENTER | DT_VCENTER | DT_SINGLELINE`. Background is the window background color.

**Gap banner:** A filled rectangle with a yellow background (`CreateSolidBrush(RGB(255, 248, 225))`), 1px border in amber (`RGB(249, 168, 37)`), and dark text. Positioned below the drop zone.

**Summary text:** The file summary ("47 requirements, 23 user needs...") is drawn as centered text inside the drop zone rectangle, replacing the "Drop .xlsx here" prompt.

**State transitions** trigger `InvalidateRect(hwnd, null, TRUE)` to force a repaint. The `WM_PAINT` handler checks the current state and draws accordingly.

Win32 custom painting is stateless: you draw the entire client area from scratch on every `WM_PAINT`. There's no retained-mode scene graph. This is fine because the window contents are simple and change infrequently.

---

## 12. Distribution

### No Installer

The `.exe` is the deliverable. No MSI, no NSIS, no Inno Setup, no WiX. The user downloads one file and runs it. Settings (the license cache) are stored in `%USERPROFILE%\.rtmify\` and persist across updates.

If a user wants to "install" it, they put it in `C:\Program Files\RTMify\` or wherever they keep tools. If they want a Start Menu shortcut, they make one. The app doesn't create shortcuts, modify the registry, or write to Program Files. It's a portable executable.

### SmartScreen

The first time a user runs a downloaded `.exe`, Windows SmartScreen may show a "Windows protected your PC" warning. This happens because the executable is new and unrecognized. Two mitigations:

**Code signing (recommended):** Sign the `.exe` with an EV (Extended Validation) code signing certificate. EV certificates establish immediate SmartScreen reputation — no warning on first run. Standard (OV) certificates build reputation over time (days to weeks of downloads before SmartScreen stops warning). EV certificates cost $300-500/year from providers like DigiCert, Sectigo, or SSL.com. They require identity verification and sometimes a hardware token.

**Without signing:** SmartScreen shows "Windows protected your PC / Microsoft Defender SmartScreen prevented an unrecognized app from starting." The user clicks "More info" → "Run anyway." This is workable for early adopters but unacceptable for the target market. A quality engineer at a medical device company will not click "Run anyway" on an unrecognized executable. Budget for the code signing certificate.

### Upload to LemonSqueezy

Upload `rtmify-trace.exe` (x64) and `rtmify-trace-arm64.exe` (ARM64) as product files on the LemonSqueezy variant. The user downloads the correct one. If you want to simplify, ship only x64 — it runs on ARM64 via emulation with acceptable speed for a tool that processes a spreadsheet.

---

## 13. App Lifecycle

### Launch

1. `WinMain` entry point (Zig: `pub export fn wWinMain(...)`)
2. Register window class, create window
3. Check license: `rtmify_check_license()` → set initial state
4. Enter message loop: `GetMessageW` / `TranslateMessage` / `DispatchMessageW`

### File Load

1. `WM_DROPFILES` or Browse button click → extract path
2. Spawn worker thread: `rtmify_load(path, &graph)`
3. Worker posts `WM_LOAD_COMPLETE` → main thread updates state, repaints

### Generate

1. Generate button click
2. Spawn worker thread: `rtmify_generate` (per format)
3. Worker posts `WM_GENERATE_COMPLETE` → main thread transitions to State 3

### Clear / New File

1. Call `rtmify_free(graph)` on current graph
2. Set graph pointer to null
3. Return to State 2, repaint

### Quit

1. `WM_CLOSE` → if graph loaded, call `rtmify_free(graph)`
2. `PostQuitMessage(0)`

---

## 14. Comparison to macOS Shell

| Aspect | macOS | Windows |
|--------|-------|---------|
| Language | Swift (SwiftUI) | Zig (Win32) |
| UI framework | SwiftUI | Raw Win32 + custom paint |
| Library linkage | `librtmify.a` (universal) via Xcode | `librtmify.a` (x64) via `build.zig` |
| Build tool | `xcodebuild` | `zig build` |
| Distribution | `.dmg` containing `.app` | Single `.exe` |
| Code signing | Developer ID + notarization | EV code signing certificate |
| Drop target API | SwiftUI `.onDrop` | `WM_DROPFILES` / `DragAcceptFiles` |
| Threading | Swift `Task` + `DispatchQueue` | `std.Thread.spawn` + `PostMessageW` |
| Installer | None (drag to Applications) | None (just run it) |
| DPI handling | Automatic | Manifest + runtime scaling |
| Visual style | Native SwiftUI controls | Common Controls v6 + custom paint |

Both shells call the same six C ABI functions. Both share the same license cache path convention. Both implement the same three states with the same UX flow. The platform-specific code is entirely in the presentation layer.

---

## 15. What This Is Not

Same constraints as the macOS shell:

- Not a document editor
- Not a graph viewer
- Not a sync tool
- Not a multi-window app
- Not an auto-updater

Additionally:

- Not a Windows Store app. No MSIX packaging, no Store submission. Direct download only.
- Not backwards-compatible to Windows 7/8. Win10 1809+ only. The Common Controls v6 theming and per-monitor DPI APIs require it.

---

## 16. Project Layout

```
windows/
├── src/
│   ├── main.zig              ← wWinMain, message loop, WndProc
│   ├── ui.zig                ← Window creation, control layout, custom paint
│   ├── drop.zig              ← WM_DROPFILES handler, extension check
│   ├── dialogs.zig           ← Browse (GetOpenFileNameW), error (MessageBoxW)
│   ├── state.zig             ← App state machine, view model
│   └── bridge.zig            ← Zig wrappers around librtmify C ABI
├── res/
│   ├── rtmify.rc             ← Icon, version info, manifest
│   ├── rtmify.ico            ← Application icon (multiple sizes)
│   └── rtmify.manifest       ← DPI awareness, Common Controls v6
└── (build.zig is in the repo root, adds win-gui step)
```

Estimated Zig: 600-800 lines across all files. More than the macOS shell because Win32 is more verbose than SwiftUI — window class registration, message dispatch, manual control creation and positioning, custom painting. The logic is identical; the boilerplate is larger.