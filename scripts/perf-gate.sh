#!/bin/bash
# The perf gate in release.yml's verify job: judges a perf.sh result against perf/budgets.jq. A v* tag fails when the
# file is missing or misses a budget. A rehearse/v* tag only warns (owner decision D26), so signing, notarization and
# feed signing can be rehearsed before the budgets hold. Missed budgets go to the job summary when there is one.
# Usage: scripts/perf-gate.sh <perf/<version>.json> <tag>
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
usage="usage: scripts/perf-gate.sh <perf/<version>.json> <tag>"
result=${1:?$usage}
tag=${2:?$usage}

verdict() { # message
    if [[ $tag == rehearse/* ]]; then
        echo "::warning::$1 (advisory for rehearse/ tags)"
        exit 0
    fi
    echo "::error::$1"
    exit 1
}

[[ -f $result ]] || verdict "$result is missing (scripts/perf.sh writes it)"
judged=$(jq -f "$root/perf/budgets.jq" "$result") || verdict "$result is not perf.sh's JSON"
if jq -e .pass <<< "$judged" > /dev/null; then
    echo "perf-gate.sh: $result holds every budget"
    exit 0
fi
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    jq -r '"### Missed perf budgets", "", "| Budget | Ceiling | Measured |", "|---|---|---|",
        (.budgets[] | select(.pass | not) | "| \(.metric) | \(.budget) \(.unit) | \(.measured // "missing") \(.unit) |")' \
        <<< "$judged" >> "$GITHUB_STEP_SUMMARY"
fi
verdict "$result misses budgets: $(jq -r '[.budgets[] | select(.pass | not) | .metric] | join("; ")' <<< "$judged")"
