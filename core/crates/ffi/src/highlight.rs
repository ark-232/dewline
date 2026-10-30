use std::path::PathBuf;

use dewline_core::highlight;

/// Code highlighting for fenced blocks, on one worker thread (record 0008).
#[derive(uniffi::Object)]
pub struct Highlighter(highlight::Highlighter);

#[uniffi::export]
impl Highlighter {
    /// `syntaxes` is the app's `Syntaxes.packdump`.
    #[uniffi::constructor]
    pub fn new(syntaxes: String) -> Self {
        Self(highlight::Highlighter::new(PathBuf::from(syntaxes)))
    }

    /// Waits for the worker, so call it off the main thread. Each span as three words: start and end in UTF-16
    /// offsets of `text`, and its `highlight::Class`. Empty for a language without a syntax; `None` when a newer
    /// request for `block` or a `forget` overtook this one.
    pub fn highlight(&self, block: u64, language: String, text: String) -> Option<Vec<u32>> {
        let spans = self.0.highlight(block, &language, &text)?;
        Some(
            spans
                .iter()
                .flat_map(|span| [span.start, span.end, span.class as u32])
                .collect(),
        )
    }

    /// Cancels `block`'s requests and drops its line states.
    pub fn forget(&self, block: u64) {
        self.0.forget(block);
    }
}
