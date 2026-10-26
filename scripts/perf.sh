#!/bin/bash
# Measures the editor on this Mac: the perf tests in a Release build, then launch, memory, idle CPU and wakeups,
# and the app and DMG sizes. Writes perf/m0-<date>.json, with the 1-minute load average at the start, after the
# tests and at the end, and prints a table. Windows come to the front while it runs; no app is left running.
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
launch() { # app variant document
    rm -f "$work/probe"
    open -n -W --env DEWLINE_LAUNCH_PROBE=1 --stdout "$work/probe" -a "$1" "$3" \
        --args -ApplePersistenceIgnoreState YES -DewlineTextKit "$2"
    grep -E '^[0-9]+\.[0-9]$' "$work/probe"
}

# Launches a copy of the app and the document written past the file cache.
cold() { # variant n
    local copy=$work/cold-$1-$2
    mkdir "$copy"
    ditto --nocache "$app" "$copy/Dewline.app"
    ditto --nocache "$work/1MB.md" "$copy/1MB.md"
    launch "$copy/Dewline.app" "$1" "$copy/1MB.md"
}

# Opens a document and waits until the app's CPU time holds for 2 s, then 10 s more. Prints JSON: the footprint
# then, and over the next 30 s the CPU, idle wakeups, context switches and whether the app stayed in front.
idle() { # variant document
    open -n -a "$app" "$2" --args -ApplePersistenceIgnoreState YES -DewlineTextKit "$1"
    for _ in {1..50}; do pid=$(pgrep -n -f "$app/Contents/MacOS/Dewline") && break; sleep 0.1; done
    [[ -n $pid ]]
    local previous now=
    while previous=$now; sleep 2; now=$(ps -o time= -p "$pid"); [[ $now != "$previous" ]]; do :; done
    sleep 10
    top -l 2 -s 30 -c d -pid "$pid" -stats pid,mem,cpu,idlew,csw > "$work/top"
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
jq -e '.textKit1.scroll and .textKit2.scroll' "$work/tests.json" > /dev/null
xcodebuild build "${xcode[@]}"
load="$load $(sysctl -n vm.loadavg | awk '{ print $2 }')"

outside='{}'
for variant in 1 2; do
    for n in 1 2 3; do cold "$variant" "$n" >> "$work/cold$variant"; done
    launch "$app" "$variant" "$work/1MB.md" > /dev/null
    for _ in 1 2 3 4 5; do launch "$app" "$variant" "$work/1MB.md" >> "$work/warm$variant"; done
    idle "$variant" "$work/1MB.md" > "$work/idle1MB"
    idle "$variant" "$work/10MB.md" > "$work/idle10MB"
    outside=$(jq --arg key "textKit$variant" --slurpfile cold "$work/cold$variant" --slurpfile warm "$work/warm$variant" \
        --slurpfile one "$work/idle1MB" --slurpfile ten "$work/idle10MB" \
        '.[$key] = {launch1MB: {coldMs: $cold, warmMs: $warm}, idle1MB: $one[0], idle10MB: $ten[0]}' <<< "$outside")
done
load="$load $(sysctl -n vm.loadavg | awk '{ print $2 }')"

mkdir "$work/dmg"
ditto "$app" "$work/dmg/Dewline.app"
hdiutil create -quiet -format ULMO -volname Dewline -srcfolder "$work/dmg" "$work/Dewline.dmg"

mkdir -p "$root/perf"
result=$root/perf/m0-$(date +%F).json
jq -n --slurpfile tests "$work/tests.json" --argjson outside "$outside" \
    --arg date "$(date +%F)" --arg commit "$(git -C "$root" describe --always --dirty)" \
    --arg mac "$(sysctl -n machdep.cpu.brand_string), $(($(sysctl -n hw.memsize) >> 30)) GB, macOS $(sw_vers -productVersion)" \
    --arg xcode "$(xcodebuild -version | head -1)" --argjson load "[${load// /, }]" \
    --argjson corpus1 "$(stat -f %z "$work/1MB.md")" --argjson corpus10 "$(stat -f %z "$work/10MB.md")" \
    --argjson app "$(find "$app" -type f -exec stat -f %z {} + | awk '{ s += $1 } END { print s }')" \
    --argjson dmg "$(stat -f %z "$work/Dewline.dmg")" \
    '{date: $date, commit: $commit, mac: $mac, xcode: $xcode, build: "Release, arm64, unsigned", load: $load,
      corpusBytes: {"1MB": $corpus1, "10MB": $corpus10}, appBytes: $app, dmgBytes: $dmg, variants: ($tests[0] * $outside)}' \
    > "$result"

jq -r '
    def f: if . >= 100 then round | tostring else . * 10 | round / 10 | tostring end;
    def median: sort | .[length / 2 | floor];
    def row($metric; value; $budget): [$metric, (.variants.textKit1 | value), (.variants.textKit2 | value), $budget] | @tsv;
    (["Metric", "TextKit 1", "TextKit 2", "Budget"] | @tsv),
    row("Open 1 MB, ms"; .open1MB.ms | f; "50"),
    row("Open 10 MB, ms"; .open10MB.ms | f; "250"),
    row("Keystroke 1 MB p50 / p95 / p99, ms"; "\(.keystroke1MB.p50 | f) / \(.keystroke1MB.p95 | f) / \(.keystroke1MB.p99 | f)"; "8 / - / 16"),
    row("Keystroke 10 MB p50 / p95 / p99, ms"; "\(.keystroke10MB.p50 | f) / \(.keystroke10MB.p95 | f) / \(.keystroke10MB.p99 | f)"; "- / 16 / -"),
    row("Reveal p50 / p99, ms"; "\(.reveal.p50 | f) / \(.reveal.p99 | f)"; "-"),
    row("Select all / deselect 1 MB, ms"; "\(.reveal.selectAll1MB | f) / \(.reveal.deselect1MB | f)"; "-"),
    row("Scroll step p50 / p99, ms"; "\(.scroll.p50 | f) / \(.scroll.p99 | f)"; "-"),
    row("Scroll steps over 8.3 ms, of 200"; .scroll.over8_3ms | f; "-"),
    row("Scroll step settled p50 / p99, ms"; "\(.scrollSettled.p50 | f) / \(.scrollSettled.p99 | f)"; "-"),
    row("Launch 1 MB cold (slowest of 3) / warm (median of 5), ms"; "\(.launch1MB.coldMs | max | f) / \(.launch1MB.warmMs | median | f)"; "300 / 150"),
    row("Memory 1 MB / 10 MB, MB"; "\(.idle1MB.footprintMB | f) / \(.idle10MB.footprintMB | f)"; "80 / 150"),
    row("Idle 1 MB CPU %, idle wakeups, context switches in 30 s"; "\(.idle1MB.cpuPercent | f), \(.idle1MB.idleWakeups | f), \(.idle1MB.contextSwitches | f)"; "0, 0, -"),
    row("App in front while idle, 1 MB / 10 MB"; "\(.idle1MB.frontmost) / \(.idle10MB.frontmost)"; "-"),
    ("\(.appBytes / 1048576 | f), \(.dmgBytes / 1048576 | f)" as $size | ["App, DMG (ULMO), MB", $size, $size, "-, 20"] | @tsv)
' "$result" | column -t -s $'\t'
echo "Wrote $result"
