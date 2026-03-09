# RTMify Trace — macOS App

Native SwiftUI application that wraps `librtmify.a` in a drag-and-drop GUI. All XLSX parsing, graph construction, gap detection, and report rendering happen in the Zig library. Swift handles the window, file drops, license activation, and progress display.

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Xcode | 16+ (26.0 tested) | App Store / developer.apple.com |
| Zig | 0.15.2 | `brew install zig` or ziglang.org |
| Command Line Tools | any | `xcode-select --install` |

---

## Quick Start

```sh
# 1. Build librtmify.a (arm64, ~9.7 MB)
cd trace/macos
make lib

# 2. Open in Xcode
open "RTMify Trace.xcodeproj"
# Cmd+B to build, Cmd+R to run
```

Or build entirely from the command line:

```sh
make build   # runs make lib then xcodebuild Release
```

---

## Make Targets

| Target | What it does |
|---|---|
| `make lib` | Builds `lib/librtmify.a` (arm64, ReleaseSafe) |
| `make build` | Builds `lib/librtmify.a` then `xcodebuild Release` |
| `make build-universal` | lipo arm64 + x64 → universal `lib/librtmify.a` |
| `make clean` | Removes `lib/` and `.build/` |

`lib/librtmify.a` is not committed — always build it from source first.

---

## Development Workflow

### First time

```sh
cd trace/macos
make lib
open "RTMify Trace.xcodeproj"
```

### After changing Zig source

```sh
cd trace/librtmify
zig build test --summary all          # must be 132/132 green
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
cp zig-out/lib/librtmify.a ../macos/lib/librtmify.a
```

Then Cmd+B in Xcode (or `make build`).

### After changing Swift source only

Just Cmd+B in Xcode — no library rebuild needed.

---

## Dev License Key

The app shows a license gate on first launch. For local development, use the bypass key:

```
RTMIFY-DEV-0000-0000
```

This is recognized entirely within `librtmify` — no network call is made. The key writes a valid `~/.rtmify/license.json` that never expires and never triggers online re-validation. To reset to the license gate state:

```sh
rm ~/.rtmify/license.json
```

To deactivate from within the app: **RTMify Trace menu → Deactivate License...**

---

## Project Layout

```
trace/macos/
├── Makefile
├── RTMify Trace.xcodeproj/
│   └── project.pbxproj          ← hand-generated; edit here for build settings
├── RTMify Trace/
│   ├── App.swift                 ← @main, Window scene, deactivate menu
│   ├── ContentView.swift         ← state switcher + error alert
│   ├── ViewModel.swift           ← AppState machine, all async C calls
│   ├── RTMifyBridge.swift        ← async Swift wrappers over C ABI
│   ├── LicenseGateView.swift     ← key entry + activate button
│   ├── DropZoneView.swift        ← drag-and-drop zone, file summary, format picker
│   ├── DoneView.swift            ← results, Show in Finder, Generate Another
│   ├── rtmify-bridge.h           ← C ABI declarations (bridging header)
│   ├── Info.plist                ← bundle ID io.rtmify.trace, macOS 13+
│   └── Assets.xcassets/          ← placeholder app icon
├── lib/
│   └── librtmify.a               ← built by `make lib`; not committed
└── docs/
    └── prd.md                    ← product requirements document
```

---

## Architecture

```
┌─────────────────────────────────────┐
│           RTMify Trace.app          │
│  ┌─────────────────────────────┐   │
│  │         SwiftUI (~400 LOC)  │   │
│  │  App / ContentView          │   │
│  │  ViewModel (AppState)       │   │
│  │  LicenseGateView            │   │
│  │  DropZoneView               │   │
│  │  DoneView                   │   │
│  └────────────┬────────────────┘   │
│               │ rtmify-bridge.h    │
│  ┌────────────▼────────────────┐   │
│  │      librtmify.a (Zig)      │   │
│  │  XLSX parsing (7 layers)    │   │
│  │  Graph construction         │   │
│  │  Gap detection              │   │
│  │  PDF / DOCX / MD rendering  │   │
│  │  License management         │   │
│  └─────────────────────────────┘   │
└─────────────────────────────────────┘
```

**C ABI surface** (all 9 functions in `rtmify-bridge.h`):

```c
rtmify_load()              // parse XLSX → opaque graph handle
rtmify_generate()          // graph + format + path → output file
rtmify_gap_count()         // number of traceability gaps
rtmify_warning_count()     // number of validation warnings
rtmify_last_error()        // human-readable error from last failure
rtmify_free()              // release graph handle
rtmify_activate_license()  // validate key with LemonSqueezy + write cache
rtmify_check_license()     // read cache → 0 = ok, non-zero = gate
rtmify_deactivate_license()// remove cache + notify LemonSqueezy
```

---

## Build Settings (key ones)

| Setting | Value | Why |
|---|---|---|
| `SWIFT_OBJC_BRIDGING_HEADER` | `RTMify Trace/rtmify-bridge.h` | Exposes C ABI to Swift |
| `LIBRARY_SEARCH_PATHS` | `$(SRCROOT)/lib` | Finds `librtmify.a` |
| `OTHER_LINKER_FLAGS` | `-lrtmify` | Links the static library |
| `MACOSX_DEPLOYMENT_TARGET` | `13.0` | Ventura minimum |
| `SWIFT_VERSION` | `5.9` | |
| `CODE_SIGN_IDENTITY` | `-` | Ad-hoc signing (no Apple account needed) |
| `ENABLE_HARDENED_RUNTIME` | `NO` | Simplified local dev |

To change any of these, edit `RTMify Trace.xcodeproj/project.pbxproj` directly or open the project in Xcode → target → Build Settings.

---

## Troubleshooting

### `make lib` fails
```
zig: command not found
```
Install Zig 0.15.2: `brew install zig` or download from [ziglang.org](https://ziglang.org/download/).

---

### `Undefined symbols: ___divtf3` (linker error)
The library was built without bundling Zig's compiler-rt. Ensure `build.zig` in `trace/librtmify/` has:
```zig
static_lib.bundle_compiler_rt = true;
```
Then `make lib` again.

---

### `Cannot link directly with SwiftUICore` (linker warning → error)
Seen on some Xcode/SDK combinations. Usually caused by incorrect code signing settings. Verify `CODE_SIGN_IDENTITY = "-"` and `CODE_SIGN_STYLE = Manual` in the project.

---

### App shows license gate, dev key doesn't work
Verify the library was rebuilt after the last change to `license.zig`. The dev key (`RTMIFY-DEV-0000-0000`) is compiled into `librtmify.a` — a stale library won't recognize it.

---

### Drop zone rejects a valid XLSX
The drop handler checks UTType `org.openxmlformats.spreadsheetml.sheet` first, then falls back to path extension. If macOS hasn't registered the UTType, the extension check should catch it. If neither works, verify the file is a true XLSX (ZIP-based) and not an XLS renamed to `.xlsx`.

---

## Release Build (Universal Binary)

```sh
# Build universal librtmify.a (arm64 + x86_64)
make build-universal

# Build the app against it
xcodebuild -project "RTMify Trace.xcodeproj" \
           -scheme "RTMify Trace" \
           -configuration Release \
           -derivedDataPath .build
```

The resulting `.app` is at `.build/Build/Products/Release/RTMify Trace.app`.

For a distributable DMG, use [create-dmg](https://github.com/create-dmg/create-dmg) or Packages.app — not yet automated in the Makefile.
