# Pools KeystrokeLatency's parts() runs for scripts/perf.sh: for each document size and part of a keystroke, the p50,
# p95 and p99 in ms over every run's keystrokes, with each run's clock probe in µs and whether its app was in front.
def rank($fraction): sort | .[(length * $fraction | ceil) - 1];
def ms: . * 100 | round / 100;
{clockUs: map(.clockUs), frontmost: map(.frontmost)}
+ (. as $runs | .[0].cells | with_entries(.key as $size | .value |= with_entries(.key as $part
    | .value = ([$runs[].cells[$size][$part][]] | {p50: (rank(0.5) | ms), p95: (rank(0.95) | ms), p99: (rank(0.99) | ms)}))))
