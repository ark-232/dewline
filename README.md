<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/brand/lockup-dark.svg">
  <img src="docs/brand/lockup.svg" alt="Dewline" width="320">
</picture>

**Notes you can grep.**

Dewline is a native Markdown editor for Mac. It opens the .md files you already keep, in any folder or Obsidian vault, and saves them exactly as you wrote them.

macOS 26+ · Free · No account, no telemetry

## Why switch

1. **A Mac app, built as one.** AppKit and TextKit 2 over a Rust engine. No Electron, and no JavaScript runs on your notes. Measured for 0.1.0 on an M4 Pro: 8.9 ms from keystroke to screen at the median on a 1 MB file, and 0% CPU at idle ([run](perf/0.1.0.json), [budgets](docs/decisions/0010-perf-budgets.md)).
2. **Your files stay your files.** Open any .md file where it lives, any folder, any Obsidian vault. Nothing to import. A save changes only the bytes you edited and never overwrites a newer copy on disk.
3. **The features are built in.** Everything below ships in the app. There are no plugins to find, install or update.

## Features

**Writing.** Syntax hides until the caret reaches it. Tables, task lists, footnotes, front matter, callouts, highlights and code with syntax colors render in the page. Math and Mermaid diagrams are drawn natively, with no JavaScript. Wikilinks, embeds and #tags link your notes. Vim mode, a Source view, focus and typewriter modes.

**Files and saves.** Edits save in place as plain Markdown. When something else changes the open file (git, a sync app, a script or a coding agent), Dewline marks each change and lets you keep or revert it. It snapshots the file before an outside change lands, and File > Snapshots restores any snapshot.

**Finding your way.** A folder sidebar, tabs, Quick Open (⇧⌘O), find in files (⇧⌘F) and a command palette for files, commands and settings (⇧⌘P).

**Looks.** Six themes, a pack of four more (Solarized, Gruvbox, Nord, Tokyo Night), light and dark, and fonts you install from Settings.

**Sharing.** Export to HTML, PDF or DOCX. Quick Look previews .md files in Finder. Edit a file live with someone by invite link, peer to peer.

Every shortcut is in [docs/keyboard.md](docs/keyboard.md).

## Coming from Obsidian or Notion

Dewline opens an Obsidian vault as it is, so you can use it instead of Obsidian on your Mac or beside it. For Notion, it suits the notes and docs you want to keep as files; it has no databases, web pages or team workspace.

| | Obsidian | Notion | Dewline 0.1.0 |
|---|---|---|---|
| Markdown with syntax hidden until the caret arrives | Yes | n/a | Yes |
| Open an existing vault or folder in place, no import | Yes | No | Yes |
| Wikilinks, embeds, #tags, callouts, front matter | Yes | Partial | Yes |
| Backlinks pane, graph view, Canvas, Bases | Yes | n/a | No (backlinks only through `dewline mcp`) |
| Community plugins and themes | 2,000+ | Integrations | No, by design (ten built-in themes) |
| Phone and tablet apps | Yes | Yes | No |
| Sync between your devices | Paid Sync | Cloud | No (planned for 1.1, Mac to Mac) |
| Databases, views, relations | Bases | Yes | No |
| Web access, public pages | Publish (paid) | Yes | No |
| Team workspace, permissions | No | Yes | No |
| Live co-editing | Plugins | Yes | Yes: invite link, peer to peer, both Macs online |
| Works offline, files on disk | Yes | Limited | Yes |
| Export HTML, PDF, DOCX | PDF, plugins | Yes, with losses | Yes |
| Native Mac app | No (Electron) | No (Electron) | Yes (AppKit, TextKit 2) |

## For developers

The app carries a `dewline` command in `Dewline.app/Contents/Helpers`; the Homebrew cask links it onto your PATH.

- `dewline open notes.md:12 --wait` opens a file at a line and returns when its window closes, so `EDITOR="dewline open --wait"` works for git and your shell.
- `dewline mcp <folder>` serves a folder's notes to an agent over MCP: read, search, backlinks, decisions and an inbox append.
- `dewline notify` runs from Claude Code, Codex and Cursor hooks and tells Dewline which agent changed a file, so the change carries its name. `dewline doctor --install-hooks` installs them; [docs/hooks.md](docs/hooks.md) has them by hand.
- `dewline export` writes HTML, PDF or DOCX, `dewline capture` adds a dated line to `~/Documents/Dewline/Inbox.md`, and `dewline changes` lists the agent changes you kept or reverted.

## Install

0.1.0 is not tagged yet. Once it is:

```sh
brew install --cask ark-232/tap/dewline
```

or download the DMG from [Releases](https://github.com/ark-232/dewline/releases). Dewline updates itself.

## Build

Needs macOS 26, Xcode 27, Rust 1.99 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
(cd core && cargo test --workspace)
scripts/build-xcframework.sh   # the Rust engine as Packages/MdCore/DewlineFFI.xcframework
xcodegen generate --spec app/project.yml
xcodebuild test -project app/Dewline.xcodeproj -scheme Dewline -destination 'platform=macOS'
```

For a local Release build, pass `ARCHS=arm64` (or `ONLY_ACTIVE_ARCH=YES` with `-destination 'platform=macOS,arch=arm64'`) unless you built the XCFramework with `--universal`, which needs Rust's `x86_64-apple-darwin` target.

| Path | What |
|---|---|
| `app/` | The Mac app: Swift 6 and AppKit. The Xcode project is generated from `app/project.yml`. |
| `core/` | The Rust engine and the `dewline` command-line tool. |
| `docs/` | [Architecture](docs/architecture.md), [roadmap](docs/roadmap.md), [research](docs/research.md), [decisions](docs/decisions/), [agent hooks](docs/hooks.md). |

## License

Free, source-available (FSL-1.1-ALv2). [The license](LICENSE.md) lets you use, read and change Dewline for anything except a competing product. Each release becomes Apache-2.0 two years after it ships.
