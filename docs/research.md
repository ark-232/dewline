# Research

What the October 2026 studies found, in brief. Four multi-agent studies ran: the market (36 agents), the stack (46), design and brand (63) and naming (18). An adversarial verifier re-checked each lane's load-bearing claims before synthesis.

## What users want

| Signal | Evidence |
|---|---|
| Inline rendering of plain files | Obsidian's in-place editing request: 1,079 likes. A Zed discussion calls inline editing the one feature keeping its author on VS Code. |
| Native speed, no Electron | The most repeated complaint across Hacker News and Reddit threads; MarkEdit's 4 MB download is praised. |
| Clean native design | 153 App Store mentions; iA Writer holds 59 of 67 recent reviews at 4-5 stars at $49.99. |
| Outline and folding | 395 votes across four issue trackers |
| Vim mode, Mermaid, spell check | about 551, 515 and 506 votes, some on issues already shipped |
| Tabs | 283 votes |

## What users punish

Electron weight; subscriptions or paywalls before writing (31 of 72 recent low Ulysses reviews); sync that loses data (24 of 68 recent low Obsidian iOS reviews); required accounts; proprietary storage; reformatting files on open; fragile plugins; undisclosed AI-generated code.

## The gap

Many native Mac markdown editors launched in 2026, and most drew 2-5 points on Hacker News. Typora on macOS is native WebKit, not Electron, so "a native Typora" is not a pitch. The open problem is agents: Claude Code, Codex, git and sync apps rewrite files that are open in an editor, and no editor shows what changed and who changed it while keeping the old version. A 2026 benchmark found that none of six WYSIWYG editors saved files byte for byte.

Closest projects: Stet (reviewing AI edits in local Markdown), editmd (live agent edits through Yjs) and Lettera (from Bear's makers).

## Stack

Four architectures were designed and scored by three judges (product feel, engineering risk, strategy):

| Architecture | Borda points |
|---|---|
| Swift and AppKit with TextKit, Rust engine | 11 |
| Swift shell with CodeMirror 6 in a web view, Rust engine | 10 |
| Tauri 2 with CodeMirror 6 | 5 |
| Rust on GPUI | 4 |

GPUI lacks VoiceOver for text, Writing Tools, the find bar, Services and spell check. Tauri's benefit is cross-platform reach, which a Mac-only app never uses.

## Design

An achromatic, opaque page under the standard macOS chrome. Color appears only when another writer changed the file or a decision is needed. Each writer is told apart by four channels (hue, underline style, a small-caps label and the spoken name), so the meaning survives grayscale and color blindness. Insertions and deletions differ by shape, never by red and green. Body text is New York 17 pt on a 68-character line. Nothing animates while you type.

## Name

Dewline is a calm nature word and the name of the Cold War Distant Early Warning radar line. The name round checked 84 English candidates against domains, GitHub, Homebrew, crates.io, npm and the App Store; the best-sounding (Keel, Byline, Faircopy, Sightglass) all collided with live software.
