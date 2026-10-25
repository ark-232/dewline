# Architecture

Swift owns the pixels. Rust owns the bytes.

## The split

The Mac app (`app/`, Swift 6 and AppKit) owns every pixel and the keystroke path: the text view and its layout, drawing, the system text services (spell check, Writing Tools, dictation, the find bar), documents, windows and menus.

The engine (`core/`, Rust) owns the bytes: decoding, parsing, the change engine, snapshots, the path jail, export, and the `dewline` CLI and MCP server. The app reaches it through UniFFI, and it is never on the keystroke path. One engine serves the app, the Quick Look extension and the CLI.

A pure-Rust UI was ruled out: no Rust GUI framework offers VoiceOver for text, Writing Tools, the find bar, Services and spell check, and rebuilding them was estimated at 28 weeks of solo work. A web view editor was ruled out as the default: it breaks the single-process memory budget and limits Writing Tools to a panel. CodeMirror 6 in a web view stays the fallback if TextKit fails the first measurement milestone.

## Rules the code keeps

- The raw markdown text is the only model. Rendering changes attributes, never characters.
- Opening never writes and never normalizes. Unedited bytes never change, including the byte-order mark and line endings.
- Every write, from any writer, takes one path: detect the change, compare it with the last known contents, snapshot, three-way merge, apply, and save only if the disk still matches.
- Conflicts never enter the file. The other version shows as a card until you choose.
- Snapshots live in `~/Library/Application Support/dev.arkwerx.dewline/`, never beside your files.
- Nothing restyles or applies outside changes while an input method is composing text.
- After five seconds without input, nothing runs: no timers, no animation, no blinking caret.

## Components

| Layer | Choice |
|---|---|
| App | Swift 6, AppKit, NSDocument, native tabs, macOS 26+, universal binary |
| Editor | NSTextView; TextKit 2 or TextKit 1, chosen by measurement |
| Parsing | pulldown-cmark, reparsing only the edited lines |
| Diff and merge | imara-diff, three-way merge against the last known contents |
| Snapshots | content-addressed BLAKE3 and zstd store |
| Bridge | UniFFI in an XCFramework |
| Updates | Sparkle 2, EdDSA-signed |
| Quick Look | static HTML with no web view and no scripts |

## Security

- Note content never reaches a web view with scripts enabled.
- One fuzzed path jail guards every file the CLI, the MCP server, attachments and export touch.
- The MCP server runs over stdio, refuses roots at or above your home folder, serves markdown only and appends only to one inbox file.
- Agent hooks can label a change the app already saw. They cannot write.
- No telemetry, and no account is needed to write.

Report vulnerabilities through the repository's private vulnerability reporting.

## Later

Sync between your own Macs, quick send and live collaboration will use the same change engine: Loro mirrors only the files you enroll, iroh carries the bytes, and the `.md` file stays the source of truth. Google sign-in will be optional, for sharing, Drive backup and a future paid tier, and never needed to write.
