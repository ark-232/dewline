use std::path::Path;

use dewline_core::export;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ExportError {
    #[error("{message}")]
    Io { message: String },
}

/// `markdown` as a Word document, with relative image paths read from inside
/// `folder`.
#[uniffi::export]
pub fn export_docx(markdown: String, folder: String) -> Result<Vec<u8>, ExportError> {
    export::docx::docx(&markdown, Path::new(&folder)).map_err(|error| ExportError::Io {
        message: error.to_string(),
    })
}
