# 0004: TextKit

Date: 2026-10-26. Decided by evidence, as the owner authorized.

| Decision | Choice | Reopens if |
|---|---|---|
| Text system | TextKit 2. TextKit 1 and the switch between the two are deleted, so each feature is built once. | TextKit 2 misses a budget in the M8 numbers table, or fails the owner's manual matrix in the M8 accessibility pass |

Inline Writing Tools needs TextKit 2. Apple says so in [Get started with Writing Tools](https://developer.apple.com/videos/play/wwdc2024/10168/) (WWDC24, at 3:58): "UITextView or NSTextView has to use TextKit 2 to support the full Writing Tools experience. If you are using TextKit 1, you will get a limited experience that just shows rewritten results in a panel." AppKit calls the full experience [complete](https://developer.apple.com/documentation/appkit/customizing-writing-tools-behavior-for-system-views): it "displays the changes inline with the rest of your view's content".

TextKit 2 leads on memory, typing in a 10 MB file, select all and idle at 1 MB; TextKit 1 scrolls faster, and the two type a 1 MB file about alike. Release builds for arm64 on an M4 Pro, from #6 (`perf/m0-2026-10-25.json`) unless marked:

| | TextKit 1 | TextKit 2 |
|---|---|---|
| Memory with 1 MB / 10 MB open | 66 / 294 MB | 42 / 91 MB |
| Keystroke p50 at 1 MB / 10 MB | 13.2 / 29.4 ms | 12.1 / 12.1 ms |
| Select all at 1 MB | 5,166 ms | 112 ms |
| Idle 30 s with 1 MB open: CPU, context switches | 1%, 545 | 0%, 57 |
| Page Down step p50; steps over 8.3 ms, of 200 | 4.4 ms; 18 | 14.6 ms; 197 |
| Open 1 MB with the whole text styled, before and after #10's one-write restyle | 639 to 249 ms | 474 to 189 ms |
| First screen of 1 MB styled, after #10 | 64 ms | 50 ms |

Source mode (#7), rendered blocks (#9) and the caret (#12) passed the same tests on both stacks, and the caret idled at 0.0% CPU with no wakeups on either.

The Mac was under load for these runs (load average 4 to 9), so they rank the stacks and do not certify TextKit 2: the final `scripts/perf.sh` run is the M8 numbers table. The owner's manual matrix (Japanese and Chinese input, VoiceOver by character, word and line, inline Writing Tools, dictation) moves to the M8 accessibility pass.
