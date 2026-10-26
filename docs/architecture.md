# Architecture

Swift owns the pixels. Rust owns the bytes.

## The split

The Mac app (`app/`, Swift 6 and AppKit) owns every pixel and the keystroke path: the text view and its layout, drawing, the system text services (spell check, Writing Tools, dictation, the find bar), documents, windows and menus.

The engine (`core/`, Rust) owns the bytes: decoding, parsing, the change engine, snapshots, the path jail, diagram rendering, collaboration, export, and the `dewline` CLI and MCP server. The app reaches it through UniFFI, and it is never on the keystroke path. One engine serves the app, the Quick Look extension and the CLI.

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
| Diagrams | Mermaid through mermaid-rs-renderer, off the main thread and cached; no JavaScript |
| Math | native typesetting, no JavaScript; the engine is chosen in M0 |
| Vim mode | an input layer in the app, off by default |
| Collaboration | Loro for the shared file's history, iroh for transport with a relay fallback |

## Security

- Note content never reaches a web view with scripts enabled, and no JavaScript runs on it anywhere: diagrams and math render natively, off the main thread, with size caps. A failed render shows the source.
- One fuzzed path jail guards every file the CLI, the MCP server, attachments and export touch.
- The MCP server runs over stdio, refuses roots at or above your home folder, serves markdown only and appends only to one inbox file.
- Agent hooks can label a change the app already saw. They cannot write.
- A collaboration invite link joins once, and only after the host approves. Removing someone rotates the document key.
- No telemetry, and no account is needed to write.

Report vulnerabilities through the repository's private vulnerability reporting.

## Collaboration

Live collaboration ships in 1.0 on the same change engine. Share creates an invite link; the other person opens it in Dewline, the host approves the join, and edits run peer to peer over iroh with a relay fallback. Loro mirrors only the shared file, and the `.md` stays the source of truth on each Mac. No account is involved.

Sync between your own Macs and quick send follow in 1.1 and 1.2 on the same transport. Google sign-in arrives in 1.3, optional, for Drive backup and email invites, and is never needed to write.
