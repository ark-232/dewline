#![no_main]

use dewline_core::md::{Window, parse, parse_window};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: (&str, &str, bool, bool)| {
    let (text, next, at_start, row) = input;
    let whole = parse(text);
    let units: Vec<u16> = text.encode_utf16().collect();
    // Panics if an offset runs past the end or splits a surrogate pair.
    let whole_char = |at: u32| {
        units.get(at as usize).is_none_or(|unit| !(0xDC00..0xE000).contains(unit)) && at as usize <= units.len()
    };
    let mut previous = 0;
    for block in &whole.blocks {
        assert!(previous <= block.start && block.start < block.end && whole_char(block.end));
        previous = block.end;
    }
    for token in &whole.tokens {
        let offsets = [token.start, token.content_start, token.content_end, token.end];
        assert!(offsets.is_sorted() && offsets.into_iter().all(whole_char));
        assert!(whole.blocks.iter().any(|b| b.start <= token.start && token.end <= b.end));
    }
    let window = Window { text, next, at_start, row };
    if let Some(parsed) = parse_window(&window, &whole.labels) {
        for token in &parsed.tokens {
            let offsets = [token.start, token.content_start, token.content_end, token.end];
            assert!(offsets.is_sorted() && offsets.into_iter().all(whole_char));
        }
    }
});
