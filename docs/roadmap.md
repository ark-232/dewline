# Roadmap

Each milestone is a vertical slice with a check that decides it is done. Weeks are solo estimates.

| Milestone | Scope | Done when |
|---|---|---|
| M-1 | Repository, CI, license, research and decision records | CI is green on an empty app |
| M0 (2 weeks) | Spike: TextKit 2 against TextKit 1 with hidden markdown syntax. Days 1-4 test correctness (Japanese and Chinese input, VoiceOver, spelling, selection, Writing Tools); days 5-10 measure latency, scrolling, memory and launch. | A decision record with the numbers |
| M1 (weeks 3-9) | The editor: inline rendering, byte-identical saves, outline and folding, lists, shortcuts, multi-cursor, find, focus and typewriter modes, images, tables, Obsidian syntax, word count, fonts | Round-trip and conformance tests pass; typing stays under 8 ms at the median on a 1 MB file |
| M2 (weeks 10-14) | The change engine: live merge of outside writes, highlighted changes with Keep and Revert, conflict cards, snapshots, git awareness, Claude Code attribution | 10,000 randomized outside writes lose nothing and keep the cursor |
| G1 | A go/no-go demo with 20-30 people who use agents on their notes | The decision is recorded |
| M3 (weeks 15-21) | Folder windows, Review Changes across files, the agent decision log, tabs, Quick Look, HTML, PDF and DOCX export, the CLI | `dewline open notes.md:10 --wait` works as `$EDITOR` |
| M4 (weeks 22-24) | Release pipeline, Sparkle updates, Homebrew cask, accessibility pass, site, public beta, 1.0 | A notarized DMG of 20 MB or less installs with Homebrew and updates itself |
| 1.1 | Sync between your own Macs, peer to peer, no account | Two Macs edit offline and converge to identical files |
| 1.2 | Quick send to a paired Mac | A verified transfer the receiver accepts |
| 1.3 | Optional Google sign-in, Drive backup, live collaboration | Remote cursors under 150 ms on a direct connection |

## Budgets

| Metric | Budget |
|---|---|
| Keystroke to screen commit | 8 ms median, 16 ms p99 on a 1 MB file |
| Cold launch | 300 ms |
| Open 1 MB / 10 MB | 50 / 250 ms |
| Idle memory | 80 MB |
| Idle CPU | 0% |
| Download | 20 MB |

## Never

Electron or a bundled browser engine; a paywall before writing; an account to write; a proprietary file format; reformatting a file on open; plugins with full system access; AI built into the editor.
