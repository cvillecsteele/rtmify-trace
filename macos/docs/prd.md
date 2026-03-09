# RTMify Trace — macOS Shell
## Product Requirements Document
### Version 0.1

---

## 1. What This Is

A native macOS application that wraps `librtmify` in a drag-and-drop GUI. The user drags an XLSX file onto the window, picks an output format, and gets a traceability report. No terminal. No command-line arguments. One window, one workflow.

The app is a SwiftUI shell. All spreadsheet parsing, graph construction, gap detection, and report rendering happen inside `librtmify.a`, which is statically linked at compile time. The Swift code handles window management, drag-and-drop, file dialogs, license activation, and progress display. It calls six C functions. That's the entire integration surface.

---

## 2. What We Have

`librtmify.a` — a static library compiled from Zig 0.15.2 with a C ABI. Zero external dependencies. The library does everything: XLSX parsing (seven defensive validation layers), in-memory graph construction, gap detection, and report rendering in PDF, Word, and Markdown.

The C ABI surface:

```c
typedef struct RtmifyGraph RtmifyGraph;

// Status codes
enum {
    RTMIFY_OK                 = 0,
    RTMIFY_ERR_FILE_NOT_FOUND = 1,
    RTMIFY_ERR_INVALID_XLSX   = 2,
    RTMIFY_ERR_MISSING_TAB    = 3,
    RTMIFY_ERR_LICENSE        = 4,
    RTMIFY_ERR_OUTPUT         = 5,
};

int32_t rtmify_load(const char* xlsx_path, RtmifyGraph** out_graph);
int32_t rtmify_generate(const RtmifyGraph* graph, const char* format,
                        const char* output_path, const char* project_name);
int32_t rtmify_gap_count(const RtmifyGraph* graph);
const char* rtmify_last_error(void);
void rtmify_free(RtmifyGraph* graph);

int32_t rtmify_activate_license(const char* license_key);
int32_t rtmify_check_license(void);
int32_t rtmify_deactivate_license(void);
int32_t rtmify_warning_count(void);
```

The license cache lives at `~/.rtmify/license.json`. The CLI already reads and writes this path. The GUI must use the same path so a user who activates via the CLI doesn't get prompted again by the GUI, and vice versa.

---

## 3. Build Artifact

One file: `RTMify Trace.dmg`.

Inside the DMG: `RTMify Trace.app` — a macOS Universal Binary containing both `arm64` (Apple Silicon) and `x86_64` (Intel) slices. macOS selects the correct architecture at launch.

Build steps:

```
1. zig build -Dtarget=aarch64-macos  → librtmify-arm64.a
2. zig build -Dtarget=x86_64-macos   → librtmify-x64.a
3. lipo -create librtmify-arm64.a librtmify-x64.a → librtmify.a (universal)
4. xcodebuild (SwiftUI project, links universal librtmify.a) → RTMify Trace.app
5. create-dmg → RTMify Trace.dmg
```

The `.app` bundle is a directory, but macOS presents it as a single object. The user opens the DMG, drags the app to Applications, done. No installer. No postflight scripts.

Target: macOS 13+ (Ventura). This covers every Mac sold since 2017 and every Mac still receiving security updates. SwiftUI features used are all available in macOS 13.

---

## 4. Application States

The app has exactly three states. The user is always in exactly one of them.

### State 1: License Gate

Shown on launch if `rtmify_check_license()` returns non-zero.

The window displays:
- RTMify Trace wordmark/logo
- A text field for the license key
- An "Activate" button
- A link to `https://store.rtmify.io` ("Need a license?")
- Error text area (hidden until activation fails)

On activation attempt:
- Button changes to "Activating..." and disables
- Call `rtmify_activate_license(key)` on a background thread (it makes an HTTPS call)
- On success (returns 0): transition to State 2
- On failure: show error from `rtmify_last_error()` in the error text area. Re-enable the button.

The license gate replaces the entire window content. There is no "skip" option, no trial mode, no greyed-out drop zone visible behind it. The user cannot interact with anything else until activation succeeds.

### State 2: Ready (Drop Zone)

Shown on launch if `rtmify_check_license()` returns 0, or after successful activation.

The window displays:
- A large drop zone (dashed border, centered icon or text: "Drop .xlsx here")
- A format picker below the drop zone (segmented control: PDF / Word / Markdown / All)
- A "Browse..." button as an alternative to drag-and-drop
- A "Generate" button (disabled until a file is loaded)
- A small status line at the bottom showing the loaded filename, or empty

Drop zone behavior:
- Accepts `.xlsx` files only. Other file types show a rejection animation (the drop zone border flashes red briefly) and a status line message: "RTMify Trace reads .xlsx files."
- On valid drop or Browse selection: call `rtmify_load(path, &graph)` on a background thread
- While loading: drop zone shows a spinner and "Reading spreadsheet..."
- On success: transition to State 2b (file loaded)
- On failure: show error from `rtmify_last_error()` in a sheet/alert. Return to empty drop zone.

### State 2b: File Loaded (Ready to Generate)

The window displays:
- The drop zone now shows the filename and a summary: "47 requirements, 23 user needs, 42 tests, 12 risks"
- If `rtmify_gap_count(graph) > 0`: a yellow banner below the drop zone: "7 traceability gaps detected — they'll be flagged in the report"
- If `rtmify_warning_count() > 0`: include warning count in the summary
- The format picker (PDF / Word / Markdown / All)
- The "Generate" button, now enabled
- A "Clear" button or × to unload the file and return to the empty drop zone
- The user can drop a different file to replace the current one

On "Generate" click:
- Button changes to "Generating..." and disables
- If format is "All": call `rtmify_generate` three times (pdf, docx, md)
- Otherwise: call `rtmify_generate(graph, format, output_path, project_name)` on a background thread
- On success: transition to State 3
- On failure: show error from `rtmify_last_error()` in a sheet/alert. Return to State 2b.

**Output path logic:** Save the report next to the input file, same directory, same base name. `requirements.xlsx` → `requirements-rtm.pdf`. If the output file already exists, append a numeric suffix: `requirements-rtm-2.pdf`. Do not prompt with a save dialog — this is a one-click tool.

**Project name:** Derived from the input filename. `requirements.xlsx` → `"requirements"`. `Ventilator_v2.1_reqs.xlsx` → `"Ventilator_v2.1_reqs"`. Used in the report header.

### State 3: Done

Shown after successful generation.

The window displays:
- A success message: "Report generated"
- The output filename(s) and path
- A "Show in Finder" button (calls `NSWorkspace.shared.selectFile`)
- A "Open" button (calls `NSWorkspace.shared.open` on the output file)
- A "Generate Another" button → returns to State 2 with the same file loaded, or State 2 empty if the user prefers to drop a new file
- If gaps were detected: the gap count is reiterated: "7 gaps flagged in the report"

---

## 5. Window Specifications

**Size:** 480 × 520 points, fixed. Not resizable. This is a single-purpose tool, not a workspace application. The fixed size keeps the layout simple and prevents the drop zone from looking empty at large sizes.

**Title bar:** "RTMify Trace". No subtitle.

**Minimum macOS version:** 13.0 (Ventura).

**App icon:** The RTMify logo (to be provided) at all required sizes. Use an asset catalog.

**Menu bar:** Standard macOS menus, mostly default:
- **RTMify Trace** menu: About, Settings (if needed later), Quit
- **File** menu: Open (triggers Browse), Close Window
- **Help** menu: link to `https://rtmify.io/docs/trace`

No Edit menu (there's nothing to edit except the license key field). No View menu (there's one view).

---

## 6. Drag and Drop

The drop zone accepts drops via SwiftUI's `.onDrop(of:)` modifier with UTType `.xlsx` (technically `org.openxmlformats.spreadsheetml.sheet`) and as a fallback, any file with `.xlsx` extension.

If a user drops a non-`.xlsx` file:
- The drop zone does not accept the drop (cursor shows the "not allowed" badge)
- If the file is `.xls`, `.csv`, `.ods`, or `.numbers`: show a status line message specific to the format. "That's a .xls file — open it in Excel and re-save as .xlsx." This mirrors the CLI's error messages from the input validation layer.
- Other file types: "RTMify Trace reads .xlsx files."

If a user drops multiple files:
- Accept only the first one. Ignore the rest. No error.

The entire window should be a drop target, not just the dashed rectangle. The dashed rectangle is a visual hint, but the user shouldn't have to aim precisely. When a valid file is dragged over the window, the drop zone border animates (highlight or color change) to indicate it will accept.

---

## 7. License Integration

### Shared Cache

The GUI reads and writes `~/.rtmify/license.json` — the same file the CLI uses. The C ABI functions (`rtmify_check_license`, `rtmify_activate_license`, `rtmify_deactivate_license`) handle all cache I/O. The Swift code never reads or writes this file directly.

### Startup Check

On launch, call `rtmify_check_license()` on the main thread (it's a local file read, fast). If it returns 0: State 2. If non-zero: State 1.

### Activation

`rtmify_activate_license(key)` makes an HTTPS request to LemonSqueezy. Always call this on a background thread. The C ABI function blocks until the HTTP response is received or the 5-second timeout fires.

### Deactivation

Expose deactivation in the menu bar: RTMify Trace → Deactivate License. Confirm with a dialog ("This will remove your license from this machine. You can re-activate with your key. Deactivate?"). Call `rtmify_deactivate_license()`. On success, transition to State 1.

### Offline Behavior

`rtmify_check_license()` handles offline grace periods internally. The GUI doesn't need to know whether the license was validated online or from cache. If the check passes, the tool works. If it fails, the error message from `rtmify_last_error()` explains why (expired, revoked, needs network, etc.).

---

## 8. Threading Model

SwiftUI runs on the main thread. `librtmify` functions that do I/O (file parsing, report generation, license activation) must run on a background thread.

Three operations go to background threads:
1. `rtmify_load` — file I/O, parsing, can take 1-2 seconds on a large spreadsheet
2. `rtmify_generate` — report rendering, file I/O, PDF generation can take a few seconds
3. `rtmify_activate_license` — network I/O, up to 5-second timeout

Pattern:

```swift
Task {
    let status = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let result = rtmify_load(path, &graph)
            continuation.resume(returning: result)
        }
    }
    // Back on MainActor — update UI
    if status == RTMIFY_OK {
        self.state = .fileLoaded
    } else {
        self.errorMessage = String(cString: rtmify_last_error())
    }
}
```

`rtmify_check_license()` is a local file read and runs on the main thread at startup. `rtmify_gap_count()` and `rtmify_warning_count()` are in-memory lookups and run on the main thread after load completes. `rtmify_free()` is a deallocation and runs on the main thread during cleanup.

---

## 9. Bridging Header

The Xcode project includes a bridging header that declares the C ABI:

```c
// rtmify-bridge.h
#ifndef RTMIFY_BRIDGE_H
#define RTMIFY_BRIDGE_H

#include <stdint.h>

typedef struct RtmifyGraph RtmifyGraph;

#define RTMIFY_OK                  0
#define RTMIFY_ERR_FILE_NOT_FOUND  1
#define RTMIFY_ERR_INVALID_XLSX    2
#define RTMIFY_ERR_MISSING_TAB     3
#define RTMIFY_ERR_LICENSE         4
#define RTMIFY_ERR_OUTPUT          5

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

#endif
```

Xcode links `librtmify.a` (universal binary) via Build Settings → Other Linker Flags: `-lrtmify` and Library Search Paths pointing at the directory containing the universal `.a` file.

---

## 10. Error Handling

Every error the user sees comes from `rtmify_last_error()`. The Swift code never composes its own error messages about spreadsheet parsing, graph construction, or report generation. The library's error messages are written for end users (not developers) and are specific and actionable. The GUI's job is to display them, not to interpret or rephrase them.

**Display mechanism:** Errors during file load or report generation appear as a macOS sheet (`.alert` modifier) attached to the window. The sheet shows the error text and an "OK" button that dismisses it.

**Activation errors** display inline in the license gate view, below the text field. No sheet, no alert — the user is already looking at the activation form.

**Crash prevention:** If `rtmify_load` or `rtmify_generate` returns a non-zero status, the GUI must not call any other function on the graph pointer (it may be null or invalid). Always check the return value before proceeding.

---

## 11. Distribution

### Code Signing

The app must be signed with a Developer ID certificate for distribution outside the Mac App Store. Unsigned apps trigger Gatekeeper warnings ("Apple cannot check it for malicious software") that will alarm the target user. An unidentified-developer warning is a dealbreaker for someone at a regulated company evaluating tools.

Signing: `codesign --deep --force --sign "Developer ID Application: [Your Name]" RTMify\ Trace.app`

### Notarization

Apple requires notarization for all Developer ID-signed apps. Without it, macOS 14+ shows a more aggressive warning. Submit the signed `.app` (or `.dmg`) to Apple's notarization service via `notarytool`. This is a one-time step per build, takes 2-5 minutes, and requires an Apple Developer account ($99/year).

```bash
xcrun notarytool submit "RTMify Trace.dmg" \
    --apple-id you@example.com \
    --team-id XXXXXXXXXX \
    --password @keychain:notary-password \
    --wait
xcrun stapler staple "RTMify Trace.dmg"
```

### DMG Packaging

Use `create-dmg` or `hdiutil` to produce the DMG. Contents: the `.app` and a symbolic link to `/Applications` so the user can drag-to-install. Set a background image if you want the branded drag-to-install layout (optional for v1).

### Upload to LemonSqueezy

Replace the macOS CLI binaries on the product with the DMG (or add alongside). The user downloads the DMG from their LemonSqueezy order page after purchase.

---

## 12. App Lifecycle

### Launch

1. `NSApplication` starts
2. SwiftUI `App` struct creates the single `Window`
3. `onAppear`: call `rtmify_check_license()` → State 1 or State 2

### File Load

1. User drops file or clicks Browse
2. Background thread: `rtmify_load(path, &graph)` → stores `OpaquePointer?` in view model
3. Main thread: update state, display summary

### Generate

1. User clicks Generate
2. Background thread: `rtmify_generate(graph, format, path, name)` → one call per format
3. Main thread: transition to State 3

### Clear / New File

1. Call `rtmify_free(graph)` on the current graph
2. Set graph pointer to nil
3. Return to State 2 (empty drop zone)

### Quit

1. If a graph is loaded: call `rtmify_free(graph)`
2. Standard `NSApplication.terminate`

---

## 13. What This Is Not

- Not a document editor. The user does not edit requirements in this app. They edit in their spreadsheet and drop the file here.
- Not a viewer. The user does not browse the graph, inspect nodes, or navigate traceability chains. That's what RTMify Live is for.
- Not a sync tool. There is no connection to Google Sheets. No polling. No live updates.
- Not a multi-window app. One window. One file at a time.
- Not an auto-updater. When a new version ships, the user downloads it from LemonSqueezy. The app does not phone home for updates. (The license re-validation check may incidentally confirm the version is current, but the app doesn't act on it.)

---

## 14. Future Considerations (Not v1)

**File association:** Register `RTMify Trace.app` as a handler for `.xlsx` files so the user can right-click → Open With → RTMify Trace. Requires an `Info.plist` entry for the UTType and a handler in the SwiftUI `App` that accepts opened files. Low effort, nice polish.

**Recent files:** Remember the last 5 files processed and show them as a list below the drop zone when empty. `UserDefaults` storage. Small convenience.

**Automatic format memory:** Remember the last format the user selected. `UserDefaults`. Trivial.

**Batch mode:** Accept a folder drop and process all `.xlsx` files in it. Moderate effort — needs a progress view showing per-file status.

---

## 15. Project Layout

```
macos/
├── RTMify Trace.xcodeproj
├── RTMify Trace/
│   ├── App.swift                 ← @main, WindowGroup, onAppear license check
│   ├── ContentView.swift         ← State router: license gate, drop zone, or done
│   ├── LicenseGateView.swift     ← License key input + activate button
│   ├── DropZoneView.swift        ← Drop target + file summary + format picker
│   ├── DoneView.swift            ← Success screen with Finder/Open buttons
│   ├── ViewModel.swift           ← ObservableObject: state, graph pointer, errors
│   ├── RTMifyBridge.swift        ← Swift wrappers around C ABI calls
│   ├── rtmify-bridge.h           ← C bridging header
│   ├── Assets.xcassets           ← App icon
│   └── Info.plist
├── lib/
│   └── librtmify.a              ← Universal binary (arm64 + x86_64)
└── Makefile                      ← Orchestrates zig build + lipo + xcodebuild + DMG
```

Estimated Swift: under 400 lines across all files. The app is small because the library does all the work.