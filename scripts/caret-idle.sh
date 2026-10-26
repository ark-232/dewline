#!/bin/bash
# Acceptance test 3 of the caret on the Release app at Lively, for both TextKit stacks: a jump streak, a click
# streak and a landing mark, then the app's CPU, idle wakeups and context switches over the next 5 s and the 60 s
# after them (top, as scripts/perf.sh measures idle), the display modes the system caret takes, two screenshots of
# the caret 1 s apart and its color on screen. The window comes to the front; screencapture needs Screen Recording
# for the terminal and the color needs ImageMagick. Leaves no app running and exits 1 when a check fails.
# Usage: scripts/caret-idle.sh [1|2], one stack, or both by default.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
derived=$HOME/Library/Caches/dev.arkwerx.dewline/DerivedData-idle
app=$derived/Build/Products/Release/Dewline.app
srgb="/System/Library/ColorSync/Profiles/sRGB Profile.icc"
work=$(mktemp -d)
pid=
failed=0

finish() {
    if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap finish EXIT

front() {
    lsappinfo info -only pid "$(lsappinfo front)" | grep -o 'pid = [0-9]*' | grep -o '[0-9]*' || true
}

# Prints the app's CPU %, idle wakeups and context switches over the given seconds.
sample() { # seconds
    top -l 2 -s "$1" -c d -pid "$pid" -stats pid,cpu,idlew,csw | awk -v pid="$pid" '$1 == pid { line = $2 " " $3 " " $4 } END { print line }'
}

check() { # description result
    if [[ $2 == true ]]; then echo "  pass  $1"; else echo "  FAIL  $1"; failed=1; fi
}

locked() {
    ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers.0.CGSSessionScreenIsLocked raw - 2>/dev/null || echo false
}

if [[ $(locked) == true ]]; then echo "The screen is locked; the app cannot come to the front." >&2; exit 1; fi
xcodegen generate --spec "$root/app/project.yml" --quiet
xcodebuild build -project "$root/app/Dewline.xcodeproj" -scheme Dewline -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO -quiet
for line in $(seq 1 300); do printf 'Line %d has **strong** words and *quiet* ones to read.\n\n' "$line"; done > "$work/idle.md"
if [[ $(defaults read -g AppleInterfaceStyle 2>/dev/null || true) == Dark ]]; then accent=(132 168 253); else accent=(45 84 211); fi

for variant in ${1:-1 2}; do
    out=$work/probe$variant
    open -n --env DEWLINE_CARET_PROBE=1 --stdout "$out" -a "$app" "$work/idle.md" \
        --args -ApplePersistenceIgnoreState YES -DewlineTextKit "$variant" -DewlineMotion lively
    for _ in {1..50}; do pid=$(pgrep -n -f "$app/Contents/MacOS/Dewline") && break; sleep 0.1; done
    for _ in {1..150}; do grep -q ' done$' "$out" 2>/dev/null && break; sleep 0.1; done
    first=$(front)
    active=$(sample 5)
    sleep 1
    rect=$(awk '$2 == "caret" { print $3 }' "$out")
    (sleep 20; screencapture -x -R"$rect" "$work/a$variant.png"; sleep 1; screencapture -x -R"$rect" "$work/b$variant.png") &
    shots=$!
    idle=$(sample 60)
    wait "$shots" || true
    last=$(front)
    kill "$pid"
    pid_was=$pid
    pid=

    read -r cpu wakeups switches <<< "$idle"
    read -r active_cpu active_wakeups active_switches <<< "$active"
    done_at=$(awk '$2 == "done" { print $1 }' "$out")
    modes=$(awk 'seen { print $3 } $2 == "done" { seen = 1 }' "$out" | tr '\n' ' ')
    solid_after=$(awk -v start="$done_at" 'seen && $3 == 2 { printf "%.2f", $1 - start; exit } $2 == "done" { seen = 1 }' "$out")
    color=$(magick "$work/a$variant.png" -profile "$srgb" -gravity center -crop 1x1+0+0 -depth 8 txt:- 2>/dev/null \
        | grep -o -E 'srgba?\([0-9.,]+\)' | tr -d 'srgba()' | cut -d, -f1-3 | tr ',' ' ' || true)
    read -r red green blue <<< "$color"
    off=$(( ${red:-999} - ${accent[0]} )); off=${off#-}
    for channel in $(( ${green:-999} - ${accent[1]} )) $(( ${blue:-999} - ${accent[2]} )); do channel=${channel#-}; (( channel > off )) && off=$channel; done

    echo "TextKit $variant"
    sed -E 's/^/  probe /' "$out"
    echo "  active 5 s: CPU $active_cpu%, idle wakeups $active_wakeups, context switches $active_switches"
    echo "  idle 60 s:  CPU $cpu%, idle wakeups $wakeups, context switches $switches"
    echo "  caret on screen: rgb $color, accent ${accent[*]}, largest channel difference $off"
    check "in front for the whole run" "$([[ $first == "$pid_was" && $last == "$pid_was" ]] && echo true || echo false)"
    check "jump streak, click streak and landing mark ran" "$(grep -c -E '(streak|mark) true$' "$out" | grep -qx 3 && echo true || echo false)"
    check "solid 5 to 5.6 s after the last input (${solid_after:-never})" "$(awk -v s="${solid_after:-0}" 'BEGIN { print (s >= 5 && s <= 5.6) ? "true" : "false" }')"
    check "held solid: modes after the input were [ ${modes}]" "$([[ $modes =~ ^(2 )+$ ]] && echo true || echo false)"
    check "idle CPU 0.0% and 0 idle wakeups" "$([[ $cpu == 0.0 && $wakeups == 0 ]] && echo true || echo false)"
    check "screenshots 1 s apart identical" "$([[ -s $work/a$variant.png ]] && cmp -s "$work/a$variant.png" "$work/b$variant.png" && echo true || echo false)"
    check "caret color within 3 of the accent in each sRGB channel" "$( (( off <= 3 )) && echo true || echo false)"
done
exit "$failed"
