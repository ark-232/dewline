const BOM: &[u8] = b"\xEF\xBB\xBF";

/// A file's bytes as opened. Opening never writes and never normalizes:
/// `to_bytes` returns exactly what `new` was given.
#[derive(Debug, PartialEq, Eq)]
pub enum Opened {
    /// UTF-8, with or without a byte-order mark. Editable.
    Utf8 { bom: bool, text: String },
    /// Any other encoding. Opens read-only and is never written.
    Other(Vec<u8>),
}

impl Opened {
    pub fn new(mut bytes: Vec<u8>) -> Self {
        let bom = bytes.starts_with(BOM);
        if bom {
            bytes.drain(..BOM.len());
        }
        match String::from_utf8(bytes) {
            Ok(text) => Opened::Utf8 { bom, text },
            Err(err) => {
                let mut bytes = err.into_bytes();
                if bom {
                    bytes.splice(0..0, BOM.iter().copied());
                }
                Opened::Other(bytes)
            }
        }
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        match self {
            Opened::Utf8 { bom, text } => encode(text, *bom),
            Opened::Other(bytes) => bytes.clone(),
        }
    }
}

/// The bytes that save `text`: the byte-order mark when the file had one,
/// then the text unchanged.
pub fn encode(text: &str, bom: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len() + if bom { BOM.len() } else { 0 });
    if bom {
        out.extend_from_slice(BOM);
    }
    out.extend_from_slice(text.as_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn bom_is_kept_out_of_the_text() {
        let opened = Opened::new(b"\xEF\xBB\xBF# Notes\n".to_vec());
        assert_eq!(
            opened,
            Opened::Utf8 {
                bom: true,
                text: "# Notes\n".into()
            }
        );
    }

    #[test]
    fn line_endings_stay_verbatim() {
        let bytes = b"a\r\nb\nc\rd".to_vec();
        assert_eq!(
            Opened::new(bytes),
            Opened::Utf8 {
                bom: false,
                text: "a\r\nb\nc\rd".into()
            }
        );
    }

    #[test]
    fn invalid_utf8_opens_read_only_with_its_bom() {
        let bytes = b"\xEF\xBB\xBFcaf\xE9".to_vec();
        assert_eq!(Opened::new(bytes.clone()), Opened::Other(bytes));
    }

    proptest! {
        #[test]
        fn any_bytes_round_trip(bytes in proptest::collection::vec(any::<u8>(), 0..4096)) {
            prop_assert_eq!(Opened::new(bytes.clone()).to_bytes(), bytes);
        }

        #[test]
        fn any_text_round_trips(text in "\\PC*", bom in any::<bool>()) {
            let bytes = encode(&text, bom);
            prop_assert_eq!(Opened::new(bytes.clone()).to_bytes(), bytes);
        }
    }
}
