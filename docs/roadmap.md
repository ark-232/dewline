# Roadmap

Each milestone is a vertical slice with a check that decides it is done. Weeks are solo estimates. Betas ship from M4; 1.0 waits for every milestone through M8.

| Milestone | Scope | Done when |
|---|---|---|
| M-1 | Repository, CI, license, research and decision records | CI is green on an empty app |
| M0 (weeks 1-3) | Spike: TextKit 2 against TextKit 1 with hidden markdown syntax. Correctness first (Japanese and Chinese input, VoiceOver, spelling, selection, Writing Tools), then latency, scrolling, memory and launch, then source mode, rendered blocks and the math engine trial. | A decision record with the numbers |
| M1 (weeks 4-11) | The editor: inline rendering, byte-identical saves, outline and folding, lists, shortcuts, multi-cursor, find, focus and typewriter modes, images, tables, Obsidian syntax with wikilinks, code highlighting, word count, tabs, source mode, the animated caret, themes and font install | Round-trip and conformance tests pass; typing stays under 8 ms at the median on a 1 MB file in every theme |
| M2 (weeks 12-16) | The change engine: live merge of outside writes, highlighted changes with Keep and Revert, conflict cards, snapshots, git awareness, Claude Code attribution | 10,000 randomized outside writes lose nothing and keep the cursor |
| M3 (weeks 17-20) | The app shell: launch window, file sidebar, Quick Open, find in files, breadcrumbs, Settings | A new user goes from launch to editing a file in a folder without Terminal |
| G1 | A go/no-go demo with 20-30 engineers who run Claude Code, Codex or Cursor | The decision is recorded |
| M4 (weeks 21-23) | Release pipeline, Sparkle updates with a beta channel, Homebrew cask | A beta installs with Homebrew and updates itself |
| M5 (weeks 24-29) | Review Changes across files, the agent decision log, Quick Look, HTML, PDF and DOCX export, the CLI, the inbox and Add to Dewline Inbox | `dewline open notes.md:10 --wait` works as `$EDITOR`; a line spoken to Siri lands in the open inbox |
| M6 (weeks 30-34) | Mermaid diagrams and math, rendered natively; Vim mode | A diagram corpus renders or shows its source with a reason; Vim's motions and operators pass a conformance table |
| M7 (weeks 35-44) | Live collaboration by invite link, peer to peer | Two Macs co-edit a file with remote cursors under 150 ms; a removed collaborator cannot rejoin |
| M8 (weeks 45-47) | Accessibility pass, site, 1.0 | A notarized DMG of 20 MB or less installs with Homebrew and updates itself |
| 1.1 | Sync between your own Macs, peer to peer, no account | Two Macs edit offline and converge to identical files |
| 1.2 | Quick send to a paired Mac | A verified transfer the receiver accepts |
| 1.3 | Optional Google sign-in, Drive backup, email invites | Sign-in is never needed to write |

## Budgets

| Metric | Budget |
|---|---|
| Keystroke to screen commit | 8 ms median, 16 ms p99 on a 1 MB file |
| Cold launch | 300 ms |
| Open 1 MB / 10 MB | 50 / 250 ms |
| Idle memory | 80 MB |
| Idle CPU | 0% five seconds after the last input |
| Download | 20 MB |

## Never

Electron or a bundled browser engine; JavaScript running on your notes; a paywall before writing; an account to write; a proprietary file format; reformatting a file on open; plugins with full system access; AI built into the editor; guilt streaks, nags or telemetry.
