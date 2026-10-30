use dewline_core::search;

/// Offsets are UTF-16 code units: `start..end` in the file's text after any
/// byte-order mark, `preview_start..preview_end` in `preview`.
#[derive(uniffi::Record)]
pub struct SearchMatch {
    /// Counted from 1.
    pub line: u32,
    pub start: u32,
    pub end: u32,
    /// The line around the match, with "…" where it was cut.
    pub preview: String,
    pub preview_start: u32,
    pub preview_end: u32,
}

#[derive(uniffi::Record)]
pub struct SearchFile {
    /// The file's index in the paths searched.
    pub file: u32,
    pub matches: Vec<SearchMatch>,
}

#[derive(uniffi::Record)]
pub struct SearchResults {
    /// The files with a match, in the order searched.
    pub files: Vec<SearchFile>,
    /// The search stopped at its limit with matches left.
    pub stopped: bool,
}

/// Searches `paths` in order for `query` as plain text, and stops after
/// `limit` matches. Files over 64 MB, files that aren't UTF-8 and files that
/// can't be read are skipped.
#[uniffi::export]
pub fn search_files(
    paths: Vec<String>,
    query: String,
    match_case: bool,
    whole_word: bool,
    limit: u32,
) -> SearchResults {
    let options = search::Options {
        match_case,
        whole_word,
    };
    let found = search::search(&paths, &query, options, limit as usize);
    SearchResults {
        files: found
            .files
            .into_iter()
            .map(|file| SearchFile {
                file: file.file as u32,
                matches: file
                    .matches
                    .into_iter()
                    .map(|m| SearchMatch {
                        line: m.line,
                        start: m.start,
                        end: m.end,
                        preview: m.preview,
                        preview_start: m.preview_start,
                        preview_end: m.preview_end,
                    })
                    .collect(),
            })
            .collect(),
        stopped: found.stopped,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_matches_by_file_index() {
        let dir = tempfile::tempdir().unwrap();
        let paths: Vec<String> = ["a.md", "b.md"]
            .iter()
            .map(|name| dir.path().join(name).to_str().unwrap().to_owned())
            .collect();
        std::fs::write(&paths[0], "nothing").unwrap();
        std::fs::write(&paths[1], "# Plan\r\nThe plan").unwrap();
        let results = search_files(paths, "plan".into(), false, true, 1);
        assert!(results.stopped);
        let [file] = results.files.as_slice() else {
            panic!("one file has matches");
        };
        let [m] = file.matches.as_slice() else {
            panic!("the limit is one match");
        };
        assert_eq!((file.file, m.line, m.start, m.end), (1, 1, 2, 6));
        assert_eq!(
            (m.preview.as_str(), m.preview_start, m.preview_end),
            ("# Plan", 2, 6)
        );
    }
}
