#!/bin/bash
# Measures the editor on this Mac: the perf tests in a Release build, then launch, memory, idle CPU and wakeups,
# and the app and DMG sizes. Writes perf/<version>.json for the Cargo workspace version, with the 1-minute load
# average at the start, after the tests and at the end, and each budget in perf/budgets.jq with its result; prints
# the budgets, the other measurements and whether every budget holds. Windows come to the front while it runs; no app
# is left running.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
derived=$HOME/Library/Caches/dev.arkwerx.dewline/DerivedData-perf
app=$derived/Build/Products/Release/Dewline.app
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
work=$(mktemp -d)
pid=
xcode=(-project "$root/app/Dewline.xcodeproj" -scheme Dewline -configuration Release -destination 'platform=macOS,arch=arm64'
    -derivedDataPath "$derived" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO -quiet)

finish() {
    if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; fi
    for copy in "$work"/cold-*/Dewline.app; do
        if [[ -e $copy ]]; then "$lsregister" -u "$copy" 2>/dev/null || true; fi
    done
    rm -rf "$work"
}
trap finish EXIT

# Prints the launch probe's milliseconds from process start to the document window's first display.
launch() { # app document
    rm -f "$work/probe"
    open -n -W --env DEWLINE_LAUNCH_PROBE=1 --stdout "$work/probe" -a "$1" "$2" --args -ApplePersistenceIgnoreState YES
    grep -E '^[0-9]+\.[0-9]$' "$work/probe"
}

# Launches a copy of the app and the document written past the file cache.
cold() { # n
    local copy=$work/cold-$1
    mkdir "$copy"
    ditto --nocache "$app" "$copy/Dewline.app"
    ditto --nocache "$work/1MB.md" "$copy/1MB.md"
    launch "$copy/Dewline.app" "$copy/1MB.md"
}

# Opens a document and waits until the app's CPU time holds for 2 s, then 10 s more. Prints JSON: the footprint
# then, and over the next 60 s the CPU, idle wakeups, context switches and whether the app stayed in front.
idle() { # document
    open -n -a "$app" "$1" --args -ApplePersistenceIgnoreState YES
    for _ in {1..50}; do pid=$(pgrep -n -f "$app/Contents/MacOS/Dewline") && break; sleep 0.1; done
    [[ -n $pid ]]
    local previous now=
    while previous=$now; sleep 2; now=$(ps -o time= -p "$pid"); [[ $now != "$previous" ]]; do :; done
    sleep 10
    top -l 2 -s 60 -c d -pid "$pid" -stats pid,mem,cpu,idlew,csw > "$work/top"
    local front
    front=$(lsappinfo info -only pid "$(lsappinfo front)" | grep -o 'pid = [0-9]*')
    kill "$pid"
    awk -v pid="$pid" -v front="$front" '
        function mb(v, unit) {
            sub(/[+-]$/, "", v)
            unit = substr(v, length(v))
            v = substr(v, 1, length(v) - 1)
            return unit == "G" ? v * 1024 : unit == "M" ? v : unit == "K" ? v / 1024 : v / 1048576
        }
        $1 == pid && !seen++ { footprint = mb($2) }
        $1 == pid { cpu = $3; wakeups = $4; switches = $5 }
        END {
            printf "{\"footprintMB\": %.1f, \"cpuPercent\": %s, \"idleWakeups\": %s, \"contextSwitches\": %s, \"frontmost\": %s}\n",
                footprint, cpu, wakeups, switches, (front == "pid = " pid) ? "true" : "false"
        }' "$work/top"
    pid=
}

load=$(sysctl -n vm.loadavg | awk '{ print $2 }')
xcodegen generate --spec "$root/app/project.yml" --quiet
TEST_RUNNER_DEWLINE_PERF=1 TEST_RUNNER_DEWLINE_PERF_OUT="$work/tests.json" \
    xcodebuild test "${xcode[@]}" -only-testing:DewlineTests/PerfTests ENABLE_TESTABILITY=YES
jq -e '.scroll' "$work/tests.json" > /dev/null
xcodebuild build "${xcode[@]}"
load="$load $(sysctl -n vm.loadavg | awk '{ print $2 }')"

# The first launch after a build pays a one-time cost the later fresh copies do not; it runs once.
cold 0 > "$work/first"
for n in 1 2 3; do cold "$n" >> "$work/cold"; done
launch "$app" "$work/1MB.md" > /dev/null
for _ in 1 2 3 4 5; do launch "$app" "$work/1MB.md" >> "$work/warm"; done
idle "$work/1MB.md" > "$work/idle1MB"
idle "$work/10MB.md" > "$work/idle10MB"
load="$load $(sysctl -n vm.loadavg | awk '{ print $2 }')"

mkdir "$work/dmg"
ditto "$app" "$work/dmg/Dewline.app"
hdiutil create -quiet -format ULMO -volname Dewline -srcfolder "$work/dmg" "$work/Dewline.dmg"

version=$(awk -F'"' '/^\[workspace.package\]/ { s = 1; next } /^\[/ { s = 0 } s && $1 ~ /^version *= */ { print $2; exit }' "$root/core/Cargo.toml")
result=$root/perf/$version.json
jq -n --slurpfile tests "$work/tests.json" --slurpfile cold "$work/cold" --slurpfile warm "$work/warm" \
    --slurpfile one "$work/idle1MB" --slurpfile ten "$work/idle10MB" \
    --arg date "$(date +%F)" --arg commit "$(git -C "$root" describe --always --dirty)" \
    --arg mac "$(sysctl -n machdep.cpu.brand_string), $(($(sysctl -n hw.memsize) >> 30)) GB, macOS $(sw_vers -productVersion)" \
    --arg xcode "$(xcodebuild -version | head -1)" --argjson load "[${load// /, }]" \
    --argjson corpus1 "$(stat -f %z "$work/1MB.md")" --argjson corpus10 "$(stat -f %z "$work/10MB.md")" \
    --argjson app "$(find "$app" -type f -exec stat -f %z {} + | awk '{ s += $1 } END { print s }')" \
    --argjson dmg "$(stat -f %z "$work/Dewline.dmg")" --slurpfile first "$work/first" \
    '{date: $date, commit: $commit, mac: $mac, xcode: $xcode, build: "Release, arm64, unsigned", load: $load,
      corpusBytes: {"1MB": $corpus1, "10MB": $corpus10}, appBytes: $app, dmgBytes: $dmg, firstLaunchMs: $first[0],
      launch1MB: {coldMs: $cold, warmMs: $warm}, idle1MB: $one[0], idle10MB: $ten[0]} + $tests[0]' \
    | jq -f "$root/perf/budgets.jq" > "$result"

jq -r '
    def f: if type != "number" then "-" elif . >= 100 then round | tostring else . * 10 | round / 10 | tostring end;
    (["Budget", "Ceiling", "Measured", "Result"] | @tsv),
    (.budgets[] | [.metric, "\(.budget) \(.unit)", "\(.measured | f) \(.unit)", if .pass then "holds" else "missed" end] | @tsv)
' "$result" | column -t -s $'\t'
echo
jq -r '
    def f: if type != "number" then "-" elif . >= 100 then round | tostring else . * 10 | round / 10 | tostring end;
    def row($metric; value): [$metric, value] | @tsv;
    (["Also measured", "Measured"] | @tsv),
    row("Keystroke 1 MB p95 / max, ms"; "\(.keystroke1MB.p95 | f) / \(.keystroke1MB.max | f)"),
    row("Keystroke 10 MB p50 / p99, ms"; "\(.keystroke10MB.p50 | f) / \(.keystroke10MB.p99 | f)"),
    row("Reveal p50 / p99, ms"; "\(.reveal.p50 | f) / \(.reveal.p99 | f)"),
    row("Select all / deselect 1 MB, ms"; "\(.reveal.selectAll1MB | f) / \(.reveal.deselect1MB | f)"),
    row("Scroll step p50 / p99, ms"; "\(.scroll.p50 | f) / \(.scroll.p99 | f)"),
    row("Scroll steps over 8.3 ms, of 200"; .scroll.over8_3ms | f),
    row("Scroll step settled p50 / p99, ms"; "\(.scrollSettled.p50 | f) / \(.scrollSettled.p99 | f)"),
    row("First launch after the build, 1 MB, ms"; .firstLaunchMs | f),
    row("Idle context switches in 60 s, 1 MB / 10 MB"; "\(.idle1MB.contextSwitches | f) / \(.idle10MB.contextSwitches | f)"),
    row("App in front while idle, 1 MB / 10 MB"; "\(.idle1MB.frontmost) / \(.idle10MB.frontmost)"),
    row("App, MB"; .appBytes / 1048576 | f)
' "$result" | column -t -s $'\t'
echo
jq -r 'if .pass then "Every budget holds." else "\([.budgets[] | select(.pass | not)] | length) of \(.budgets | length) budgets missed." end' "$result"
echo "Wrote $result"
