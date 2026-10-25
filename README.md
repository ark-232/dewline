# Dewline

**Nothing changes behind your back.**

A native Mac markdown editor that shows what agents changed. Open any `.md` file in place. When Claude Code, Codex, git or a sync app writes to it, Dewline marks the change, names the writer and keeps a snapshot first. Nothing is ever silently overwritten.

macOS 26+ · Free · Source-available (FSL) · No account, no telemetry

**Status:** early development. There is nothing to install yet; the [roadmap](docs/roadmap.md) says what comes when.

## Repository

| Path | What |
|---|---|
| `app/` | The Mac app: Swift 6 and AppKit. The Xcode project is generated from `app/project.yml`. |
| `core/` | The Rust engine and the `dewline` command-line tool. |
| `docs/` | [Architecture](docs/architecture.md), [roadmap](docs/roadmap.md), [research](docs/research.md), [decisions](docs/decisions/). |

## Build

Needs macOS 26, Xcode 27, Rust 1.99 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
(cd core && cargo test --workspace)
xcodegen generate --spec app/project.yml
xcodebuild test -project app/Dewline.xcodeproj -scheme Dewline -destination 'platform=macOS'
```

## License

[FSL-1.1-ALv2](LICENSE.md): use, read and change it for anything except a competing product. Each release becomes Apache-2.0 two years after it ships.
