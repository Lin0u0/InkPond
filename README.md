# InkPond

InkPond (墨池) is a native iOS/iPadOS editor for [Typst](https://typst.app/), with live preview and PDF export powered by a Rust FFI bridge.

<p align="center">
  <a href="https://apps.apple.com/us/app/inkpond/id6760032537"><img src="https://img.shields.io/badge/App%20Store-Download-0D96F6?logo=appstore&logoColor=white" alt="App Store"></a>
  <a href="https://testflight.apple.com/join/w5jmkR2T"><img src="https://img.shields.io/badge/TestFlight-Beta-0D96F6?logo=apple&logoColor=white" alt="TestFlight"></a>
  <a href="README.zh-CN.md"><img src="https://img.shields.io/badge/中文文档-README.zh--CN-34A853" alt="Chinese README"></a>
</p>
<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2017%2B%20%26%20iPadOS%2017%2B-2563EB" alt="Platform">
  <img src="https://img.shields.io/badge/Language-Swift%205-F59E0B" alt="Language">
  <img src="https://img.shields.io/badge/Typst-0.14.2-0EA5A4" alt="Typst Version">
  <img src="https://img.shields.io/badge/License-Apache%202-1D4ED8" alt="License">
</p>

## Languages

- English (current)
- 简体中文: [README.zh-CN.md](README.zh-CN.md)

## Quick Actions

| Action | Command / Link |
|---|---|
| Download | [App Store](https://apps.apple.com/us/app/inkpond/id6760032537) |
| Join TestFlight beta | [testflight.apple.com/join/w5jmkR2T](https://testflight.apple.com/join/w5jmkR2T) |
| Build Rust FFI | `cd rust-ffi && ./build-ios.sh` |
| Simulator debug build | `xcodebuild -project InkPond.xcodeproj -scheme InkPond -configuration Debug -destination 'generic/platform=iOS Simulator' build` |
| Export options file | `release/ExportOptions.plist` |

## Features

**Editor**
- Parser-backed Typst syntax highlighting with themed tokens, rainbow bracket coloring, and bracket mismatch detection
- Auto-pairing for `{}[]()""$$` with smart type-over, auto-delete, and auto-indent
- Code completion for Typst functions (~150), keywords, `#import` package specs, font families, labels, references, and image paths
- Snippets library with custom templates and `$0` cursor placeholders
- Find and replace (system `UIFindInteraction`)
- Line number gutter with error line highlighting
- Keyboard accessory bar with quick-insert buttons

**Preview & Compile**
- Typst `0.14.2` compilation through a Rust FFI bridge
- Live PDF preview with debounced recompilation (350ms)
- Bidirectional editor-to-preview sync via source maps
- `@preview` package downloads cached on device, plus local package resolution
- Document statistics (pages, words/tokens, characters; CJK-aware)
- Error banner with source location links
- Full-screen slideshow mode
- Parser-backed outline view for heading navigation
- Compiled preview cache for faster reopen and rebuild cycles

**Project Management**
- Multi-file projects with customizable entry file
- Project file browser with .typ, image, and font sections
- Image import from Photos, clipboard (including HTML paste), and remote URLs
- Per-project, app-wide, and system font resolution for explicit Typst font declarations
- Optional iCloud project sync with separate app font, local package, and snippet sync controls
- Local Typst package manager for folders and `.zip` / `.tar` / `.tar.gz` / `.tgz` archives
- ZIP project import and export
- PDF and source (.typ) export

**UI/UX**
- Adaptive layout: split view on iPad, tabbed on iPhone
- Separate app appearance controls plus three editor themes: Mocha (dark), Latte (light), System (adaptive) — based on Catppuccin
- Onboarding flow for new users
- Editor position resumption across launches
- Full VoiceOver and accessibility support
- Localized in English, Simplified Chinese, Traditional Chinese (HK/TW)
- Settings for iCloud, app fonts, local packages, keyboard shortcuts, and compile/package/system-font caches
- iOS 26 keyboard glass and visual enhancements where available, with iOS 17-compatible fallbacks

## Requirements

- macOS with Xcode 26.3+
- iOS/iPadOS deployment target: 17.0 (app target)
- Rust toolchain (`rustup`, `cargo`) for building `typst_ios.xcframework`

## Quick Start

1. Clone repo:
   ```bash
   git clone <your-fork-or-origin-url>
   cd InkPond
   ```
2. Make sure the native toolchain is ready:
   ```bash
   xcode-select -p
   cargo --version
   rustup show
   ```
   If any of these fail, install Xcode command line tools and the Rust toolchain before continuing.
3. Rebuild the Rust FFI framework after Rust changes:
   ```bash
   cd rust-ffi
   ./build-ios.sh
   cd ..
   ```
   This updates the committed `Frameworks/typst_ios.xcframework`.
4. Build and run in Xcode:
   ```bash
   open InkPond.xcodeproj
   ```

## Build Commands

```bash
# Simulator debug build
xcodebuild -project InkPond.xcodeproj -scheme InkPond -configuration Debug -destination 'generic/platform=iOS Simulator' build

# Device release archive
xcodebuild -project InkPond.xcodeproj -scheme InkPond -configuration Release -destination 'generic/platform=iOS' archive

# Unit tests
xcodebuild test -project InkPond.xcodeproj -scheme InkPond -only-testing:InkPondTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'

# UI tests
xcodebuild test -project InkPond.xcodeproj -scheme InkPond -only-testing:InkPondUITests -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'

# If your local simulator list differs, inspect available destinations first:
# xcodebuild -showdestinations -project InkPond.xcodeproj -scheme InkPond
```

## Rust FFI Notes

- `Frameworks/typst_ios.xcframework` is generated by `rust-ffi/build-ios.sh` and committed so Xcode Cloud can build without a Rust bootstrap step.
- `rust-ffi/build-ios.sh` removes `rust-ffi/target/` after packaging the xcframework to minimize local disk usage.
- Rebuild and commit `Frameworks/typst_ios.xcframework/` when Rust FFI output changes.
- The Swift bridge passes font paths, the project root, an `@preview` package cache, and the local package directory into Rust.
- Re-run `rust-ffi/build-ios.sh` when:
  - updating Typst / Rust dependencies
  - changing `rust-ffi/src/lib.rs`
  - rebuilding release artifacts for distribution
- If Xcode shows `Typst compiler library not linked`, the xcframework is missing, stale, or was built before switching branches. Re-run the build script and rebuild the app.

Current pinned Typst version: `0.14.2` (see `rust-ffi/Cargo.toml`).

## Release Pipeline (CLI)

Typical flow:

```bash
# 1) Archive
xcodebuild -project InkPond.xcodeproj -scheme InkPond -configuration Release -destination 'generic/platform=iOS' -archivePath /private/tmp/InkPond.xcarchive archive

# 2) Export IPA (using your ExportOptions.plist)
xcodebuild -exportArchive -archivePath /private/tmp/InkPond.xcarchive -exportPath /private/tmp/InkPond-export -exportOptionsPlist release/ExportOptions.plist

# 3) Upload (InkPond app id)
asc --profile default builds upload --app 6760032537 --ipa /private/tmp/InkPond-export/InkPond.ipa --output table
```

After upload, wait for processing, then distribute build to TestFlight groups.

Public App Store listing: [apps.apple.com/us/app/inkpond/id6760032537](https://apps.apple.com/us/app/inkpond/id6760032537)

## Project Layout

```text
InkPond/
├── InkPond/
│   ├── InkPondApp.swift                 # @main entry point, SwiftData ModelContainer
│   ├── ContentView.swift                # NavigationSplitView shell, environment setup
│   ├── AppAppearanceManager.swift       # App-wide light/dark/system appearance
│   ├── Models/
│   │   └── InkPondDocument.swift        # @Model: document data + project config
│   ├── Editor/
│   │   ├── TypstTextView.swift         # UITextView subclass (TextKit 1)
│   │   ├── SyntaxHighlighter.swift     # Typst token styling + rainbow brackets
│   │   ├── CompletionEngine.swift      # Context-aware code completion
│   │   ├── AutoPairEngine.swift        # Bracket/quote auto-pairing
│   │   ├── SyncCoordinator.swift       # Bidirectional editor↔preview sync
│   │   ├── EditorTheme.swift           # Mocha/Latte/System theme definitions
│   │   ├── ThemeManager.swift          # Theme persistence (UserDefaults)
│   │   ├── Snippet*.swift              # Snippet model, library, and store
│   │   ├── HighlightScheduler.swift    # Debounced highlighting
│   │   ├── LineNumberGutterView.swift  # Gutter with error markers
│   │   └── KeyboardAccessoryView.swift # Accessory bar (photo/snippet buttons)
│   ├── Compiler/
│   │   ├── TypstBridge.swift           # Rust FFI wrapper (compile + source map)
│   │   ├── TypstCompiler.swift         # Debounced compilation pipeline + cache
│   │   ├── SourceMap.swift             # Line↔page bidirectional mapping
│   │   ├── ProjectFileManager.swift    # Per-project file CRUD + validation
│   │   ├── FontManager.swift           # Project/app font metadata + parsing helpers
│   │   ├── CompileFontResolver.swift   # Font resolution and materialization planning
│   │   ├── CoreTextFontMaterializer.swift
│   │   │                              # System font materialization cache for Typst
│   │   ├── LocalPackageStore.swift     # Local Typst package catalog and imports
│   │   ├── PackageArchiveImporter.swift
│   │   │                              # Package archive extraction
│   │   ├── ExportManager.swift         # PDF/source/ZIP export (custom ZIP writer)
│   │   ├── ExportController.swift      # Export UI state machine
│   │   ├── ZipImporter.swift           # ZIP project import
│   │   ├── DirectoryMonitor.swift      # DispatchSource file system watcher
│   │   └── *CacheStore.swift           # Compiled preview + package caches
│   ├── Views/
│   │   ├── DocumentList/               # Document library, search, sort, rename
│   │   ├── DocumentEditor/             # Editor/preview split, file ops, images
│   │   │   └── OutlineView.swift       # Heading outline navigation
│   │   ├── EditorView.swift            # UIViewRepresentable for TypstTextView
│   │   ├── PreviewPane.swift           # PDFKit live preview + stats + sync marker
│   │   ├── SlideshowView.swift         # Full-screen PDF presentation
│   │   ├── OnboardingView.swift        # First-launch onboarding
│   │   ├── SnippetBrowserSheet.swift   # Snippet library browser
│   │   ├── ProjectFileBrowserSheet.swift
│   │   ├── ProjectSettingsSheet.swift
│   │   └── Settings/                   # iCloud, packages, fonts, caches, shortcuts
│   ├── Localization/                   # L10n.swift + .strings (en, zh-Hans, zh-Hant)
│   ├── Storage/
│   │   ├── StorageManager.swift        # Local/iCloud mode and migration
│   │   ├── Cloud*.swift                # iCloud coordination, availability, sync monitor
│   │   └── AppFontLibrary.swift        # App-wide font import tracking
│   ├── Shared/UI/                      # UIKit/SwiftUI bridges, haptics, a11y
│   ├── Support/
│   │   ├── AppIdentity.swift           # Bundle/app group/iCloud identifiers
│   │   └── InteractionSupport.swift    # Haptics and accessibility announcements
│   └── Bridging/                       # typst_ffi.h bridging header
├── rust-ffi/
│   ├── src/lib.rs                      # Rust Typst wrapper
│   ├── Cargo.toml                      # Rust dependencies (Typst engine)
│   └── build-ios.sh                    # XCFramework build (device + sim)
├── Frameworks/
│   └── typst_ios.xcframework/          # Committed Typst FFI artifact
├── release/
│   └── ExportOptions.plist
└── InkPond.xcodeproj
```

## Troubleshooting

- `Typst compiler library not linked`:
  - Run `cd rust-ffi && ./build-ios.sh` and rebuild the app.
  - If the script fails immediately, check `cargo --version`, `rustup show`, and `xcode-select -p`.
  - If the script succeeds but Xcode still fails to link, clean the build folder and rerun the app build.
- Simulator link errors about `typst_ios` architecture:
  - Rebuild xcframework; the script generates `arm64 + x86_64` simulator slices.
- TestFlight upload succeeded but not distributable yet:
  - Build is still processing in App Store Connect.
- `@preview` package import fails:
  - Check network access, then clear the package cache from Settings and recompile.
- iCloud files appear missing or not downloaded:
  - Open the Files app, go to iCloud Drive, and keep the InkPond folder downloaded before reopening the project.

## Acknowledgements

- [Typst](https://github.com/typst/typst) - core typesetting engine used for rendering and PDF generation (Apache 2.0)
- [Catppuccin](https://github.com/catppuccin/catppuccin) - color system used by the editor themes (MIT)
- [swift-bridge](https://github.com/chinedufn/swift-bridge) - inspiration and reference for Swift/Rust interop patterns (MIT or Apache-2.0)

## Special Thanks

- Thanks to everyone at [Donut](https://donutblogs.com/) for support and inspiration.
