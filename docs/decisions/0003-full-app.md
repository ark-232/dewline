# 0003: The full app

Date: 2026-10-26. The owner's decisions.

| Decision | Choice | Reopens if |
|---|---|---|
| App shell | 1.0 is a full app: a launch window, a file sidebar (folder tree, Recents, Pinned), Quick Open, find in files, breadcrumbs, back and forward, tabs, and a Settings window with every pane | not planned |
| Look | Native macOS 26 glass tinted by the theme. The dew line under the tabs marks every outside change. Six themes: Tidewater, Aurora, Dawnline, Dusk, Nightwatch and Carbon. An optional book heading style. Theme accents stay out of the writer colors' hues. | user evidence after G1 |
| Fonts | Pick body, heading and code fonts. Install fonts inside the app from a catalog of open-license families (downloaded on request and hash-checked) or by dropping in font files. They install for Dewline only unless you choose Install for All Apps. | not planned |
| Source mode | Option-Command-U switches between rendered and raw markdown in a monospaced font; the caret's line stays where it was | not planned |
| Motion | The caret moves with life and small moments animate. A typed character never waits for an animation, Reduce Motion gets a still version, and five seconds after the last input nothing runs. | an animation costs typing latency or idle CPU |
| Audience | Engineers, developers and people who work with agents, whose memory and context files (CLAUDE.md, AGENTS.md, rules, skills, plans) are markdown. Code highlighting ships in 1.0. | not planned |
| Capture | One inbox file. Every capture path (the CLI, MCP, an App Intent on the Mac, an iPhone Shortcut) appends an entry that starts with a dated source line. | not planned |
| Engagement | Habit-forming in healthy ways only: no guilt streaks, nags, telemetry or dark patterns | not planned |

1.0 grows to about 47 solo weeks. This record replaces the Design row of [0001](0001-foundations.md).
