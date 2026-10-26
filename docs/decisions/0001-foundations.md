# 0001: Foundations

Date: 2026-10-25. Each line is the owner's decision unless marked as recommended.

| Decision | Choice | Reopens if |
|---|---|---|
| Platform | Mac only | not planned |
| Minimum macOS | 26, universal binary | requests and the macOS 15 compatibility build justify it |
| Stack | Swift and AppKit app, Rust engine through UniFFI (recommended) | TextKit fails M0: CodeMirror 6 in a web view, with the owner's sign-off |
| License | FSL-1.1-ALv2, public repository | not planned |
| Release order | 1.0 editor and agent safety; 1.1 own-Mac sync; 1.2 quick send; 1.3 sign-in, Drive and collaboration | 1.1 is re-planned with evidence before it starts |
| 1.0 scope | the core editor plus Claude Code attribution, git awareness, folder review, Obsidian syntax, word count, fonts and DOCX | the G1 demo says no-go |
| Google sign-in | optional: identity for sharing and sync, a future paid tier, Drive backup; never needed to write | not planned |
| Peer to peer | own-Mac sync, quick send, live collaboration | not planned |
| Design | an achromatic page under standard chrome; color only for other writers and decisions (recommended) | user evidence after G1 |
| Name | Dewline | the trademark or App Store checks fail |
| Pricing promise | free core writing forever; own-Mac sync free; any paid tier covers hosted services only (recommended) | not planned |

[0002](0002-1.0-scope.md) replaced the release order and 1.0 scope rows on 2026-10-25.
[0003](0003-full-app.md) replaced the design row on 2026-10-25.
