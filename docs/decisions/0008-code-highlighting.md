# 0008: Code highlighting

Date: 2026-10-30. Decided by research (26 Oct), as the owner authorized.

| Decision | Choice | Reopens if |
|---|---|---|
| Engine | syntect 5.3.0 with the onig backend, on one Rust worker thread that owns the syntaxes and each block's per-line parse states, so an edit reparses from its first changed line. | syntect's next release lands #706, or a syntax we ship needs `branch` (syntect cannot run current Sublime packages) |
| Syntaxes | 16 in `app/Dewline/Syntaxes.packdump` (138 KB), an uncompressed newline dump loaded with `from_uncompressed_dump_file`: C, C++, CSS, Go, HTML, Java, JavaScript, JSON, Python, Rust, Shell, SQL and YAML from sublimehq/Packages at syntect's commit, bat 0.26.1's TOML, TypeScript and Swift, and what they embed. `scripts/syntaxes` builds it from `scripts/syntaxes/sources`. | users ask for a language we lack |
| Diff and markdown | Highlighted in `core::highlight` without syntect; markdown goes through `core::md`. | a fence language needs grammar the prefixes and tokens cannot give |
| Across the FFI | Spans as (start, end, class) in UTF-16 offsets; Swift maps the 14 classes to the heading token and 9 code tokens derived from each theme's link, accent, ink2 and heading. | a theme needs its own code colors |
| In the editor | Colors are TextKit 2 rendering attributes set in the layout manager's validator, so a result redraws without layout. Fenced code is monospaced; a language without a syntax stays plain. | a result that lands redraws nothing until the next layout |
| Pathological lines | A line with over 2,000 scope changes stays plain (the mdmost PR #21 budget), a line over 16 KB is not parsed, and a line that takes over 30 ms leaves the rest of its block plain. | real files trip the budget |

**#706.** syntect 5.3.0 still loops forever on two contexts that `set` each other without consuming input; the fix is merged upstream but unreleased. We do not vendor a fork. A time cap cannot stop a `parse_line` that never returns, so the guard is the data: the known trigger, `x /*` in older JavaScript, returns with the shipped JavaScript and TypeScript, and a test holds that. A loop the dump still hides would pin the highlight worker, never the main thread, and leave code plain.

**Size.** The dump adds 0.13 MB compressed; the arm64 library grows 0.65 MB (0.25 MB compressed). A universal DMG grows about 0.6 to 0.7 MB.
