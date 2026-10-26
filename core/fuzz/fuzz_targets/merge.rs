#![no_main]

use dewline_core::merge::{Bias, apply, map_offset, merge3};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|texts: (&str, &str, &str)| {
    let (base, ours, theirs) = texts;
    let merge = merge3(base, ours, theirs);
    // Panics if an edit splits a surrogate pair or runs past the end.
    let merged = apply(ours, &merge.edits);
    if let Some(covering) = &merge.covering {
        assert_eq!(apply(ours, std::slice::from_ref(covering)), merged);
    }

    let units: Vec<u16> = ours.encode_utf16().collect();
    let in_crlf =
        |at: u32| at > 0 && units.get(at as usize) == Some(&10) && units[at as usize - 1] == 13;
    let merged16: Vec<u16> = merged.encode_utf16().collect();
    let mut ranges: Vec<(u32, u32)> = merge.edits.iter().map(|e| (e.start, e.end)).collect();
    for conflict in &merge.conflicts {
        let kept = &units[conflict.start as usize..conflict.end as usize];
        let at = map_offset(&merge.edits, conflict.start, Bias::Before) as usize;
        assert_eq!(&merged16[at..at + kept.len()], kept);
        ranges.push((conflict.start, conflict.end));
    }
    ranges.sort_unstable();
    assert!(ranges.windows(2).all(|pair| pair[0].1 < pair[1].0));
    assert!(
        ranges
            .iter()
            .all(|&(start, end)| !in_crlf(start) && !in_crlf(end))
    );

    let swapped = merge3(base, theirs, ours);
    assert_eq!(merge.conflicts.is_empty(), swapped.conflicts.is_empty());
    if merge.conflicts.is_empty() {
        assert_eq!(apply(theirs, &swapped.edits), merged);
    }
    assert_eq!(apply(base, &merge3(base, base, theirs).edits), theirs);
    assert!(merge3(base, ours, base).edits.is_empty());
});
