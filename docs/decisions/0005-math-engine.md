# 0005: Math engine

Date: 2026-10-26. Decided by evidence, as the owner authorized.

| Decision | Choice | Reopens if |
|---|---|---|
| Math engine | RaTeX in the Rust engine. SwiftMath and the switch between the two are deleted. | people need a formula RaTeX cannot render |

RaTeX typesets all 50 formulas in `corpus/math`; SwiftMath fails one, `\underbrace`. #8's Release run measured RaTeX at a 0.30 ms median and found it matches KaTeX, while SwiftMath mis-spaced several formulas. RaTeX runs under the engine's 250 ms render budget, and dropping SwiftMath takes its 7.4 MB of math fonts out of the app.

#8 also reported that SwiftMath crashes on partial input; that does not reproduce. Typed one character at a time, the 50 formulas pass through 2,590 prefixes, and each engine, called as the app called it, returned a picture or an error for every one.

This settles the engine that [0002](0002-1.0-scope.md) left to M0.
