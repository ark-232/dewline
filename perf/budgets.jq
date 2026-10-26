# The plan's performance budgets for what scripts/perf.sh measures. Each budget is a ceiling, and a measurement that is
# missing misses it. Adds `budgets` (metric, unit, budget, measured, pass for each) and `pass`, true when every budget
# holds; release.yml's verify job refuses a tag whose perf/<version>.json does not pass. Scrolling (120 fps) is
# measured in Instruments, not here.
def median: sort | .[length / 2 | floor];
def row($metric; $unit; $budget; $measured):
    {metric: $metric, unit: $unit, budget: $budget, measured: $measured,
     pass: (($measured | type) == "number" and $measured <= $budget)};

. + {budgets: [
    row("Keystroke, 1 MB, p50"; "ms"; 8; .keystroke1MB.p50),
    row("Keystroke, 1 MB, p99"; "ms"; 16; .keystroke1MB.p99),
    row("Keystroke, 10 MB, p95"; "ms"; 16; .keystroke10MB.p95),
    row("Cold launch, 1 MB, slowest of 3"; "ms"; 300; (.launch1MB.coldMs // [] | max)),
    row("Warm launch, 1 MB, median of 5"; "ms"; 150; (.launch1MB.warmMs // [] | median)),
    row("Open 1 MB"; "ms"; 50; .open1MB.ms),
    row("Open 10 MB"; "ms"; 250; .open10MB.ms),
    row("Idle memory, 1 MB"; "MB"; 80; .idle1MB.footprintMB),
    row("Idle memory, 10 MB"; "MB"; 150; .idle10MB.footprintMB),
    row("Idle CPU, 1 MB"; "%"; 0; .idle1MB.cpuPercent),
    row("Idle CPU, 10 MB"; "%"; 0; .idle10MB.cpuPercent),
    row("Idle wakeups in 60 s, 1 MB"; ""; 0; .idle1MB.idleWakeups),
    row("Idle wakeups in 60 s, 10 MB"; ""; 0; .idle10MB.idleWakeups),
    row("DMG"; "MB"; 20; (.dmgBytes // null | if . == null then null else . / 1048576 end))
]} | .pass = all(.budgets[]; .pass)
