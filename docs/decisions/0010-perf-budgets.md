# 0010: Performance budgets for 0.1.0

Date: 2026-11-02. Decided by the owner after perf pass 3 (#73).

Four of the plan's budgets were set before anything was measured. Three perf passes brought the rest under budget; these four sit at what macOS and TextKit allow on the owner's Mac (M4 Pro, macOS 27.2, perf.sh with the app in front). Each new ceiling sits just above the pass 3 run, so `perf/budgets.jq` still fails a regression.

| Budget | Was | Now | Pass 3 run | Why |
|---|---|---|---|---|
| Keystroke, 1 MB, p50 | 8 ms | 9.5 ms | 8.9 ms | Dewline's own code is about 0.5 ms of a keystroke; the rest is TextKit 2 layout, the Core Animation commit and AppKit's software glyph drawing into 64-bit pixels. |
| Cold launch, slowest of 3 | 300 ms | 750 ms | 715 ms | A near-empty AppKit app that opens a file takes about 315 ms cold here. A new copy's first launch costs about 10 ms per MB of bundle whether the code loads or not, and the Rust library is 16.5 MB per architecture. |
| Warm launch, median of 5 | 150 ms | 425 ms | 403 ms | The same near-empty app takes about 240 ms warm. Dewline adds about 100 ms, in pieces of 3 to 13 ms. |
| Open 1 MB | 50 ms | 85 ms | 80 ms | The first text draw in a process blocks 10 to 30 ms while Core Animation sets up Metal, and perf.sh's 1 MB open is that first draw. |

The other ten budgets are unchanged.

Reopens if: the Rust library loses a large dependency (Mermaid, Loro or the sync stack), which lowers cold launch; TextKit or AppKit changes the keystroke path; or a pass finds a piece of launch worth more than 20 ms.
