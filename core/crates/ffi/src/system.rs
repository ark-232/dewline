//! What the app's system entry points need from the core: the Quick Look page, the inbox append behind the App Intent
//! and the Service, and the path check behind the `dewline://` URLs.

use std::env;
use std::path::{Path, PathBuf};

use dewline_core::jail::Jail;
use dewline_core::{export, inbox};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum Refusal {
    #[error("{message}")]
    Refused { message: String },
}

fn refused(message: impl ToString) -> Refusal {
    Refusal::Refused {
        message: message.to_string(),
    }
}

/// A Quick Look page of `text`: the page export writes, with diagrams and math as their source and no image inlined.
#[uniffi::export]
pub fn preview_html(text: String, title: String, css: String) -> String {
    export::html(
        &text,
        &export::ExportOptions {
            title: &title,
            css: &css,
            diagram: &|_| None,
            math: &|_, _| None,
            folder: None,
        },
    )
}

/// Appends `text` to the inbox at `path`, or at the default inbox in the home folder, as one entry from `source`.
#[uniffi::export]
pub fn inbox_append(path: Option<String>, source: String, text: String) -> Result<(), Refusal> {
    let path = match path {
        Some(path) => PathBuf::from(path),
        None => inbox::default_path(&home()?),
    };
    inbox::append(&path, &source, &text)
        .map_err(|error| refused(format!("{}: {error}", path.display())))
}

/// `path`, absolute, with every link resolved, if it lies inside the home folder but not inside ~/Library or a `.ssh`
/// folder. A file not there yet is checked through its folder.
#[uniffi::export]
pub fn jailed_path(path: String) -> Result<String, Refusal> {
    let shown = path.clone();
    let path = Path::new(&path);
    if !path.is_absolute() {
        return Err(refused(format!("{shown}: the path is not absolute")));
    }
    let (folder, name) = if path.exists() {
        (path, None)
    } else {
        match (path.parent(), path.file_name()) {
            (Some(folder), Some(name)) => (folder, Some(name)),
            _ => return Err(refused(format!("{shown}: no such file"))),
        }
    };
    let jail = Jail::new(&home()?).map_err(refused)?;
    let relative = jail
        .resolve(folder)
        .map_err(|error| refused(format!("{shown}: {error}")))?
        .join(name.unwrap_or_default());
    // Case-folded, so a differently cased name on a case-insensitive volume is refused too.
    let folded = PathBuf::from(relative.to_string_lossy().to_lowercase());
    if folded.starts_with("library") {
        return Err(refused(format!("{shown}: it is inside ~/Library")));
    }
    if folded.iter().any(|part| part == ".ssh") {
        return Err(refused(format!("{shown}: it is inside .ssh")));
    }
    jail.root()
        .join(relative)
        .into_os_string()
        .into_string()
        .map_err(|_| refused(format!("{shown}: the path is not UTF-8")))
}

fn home() -> Result<PathBuf, Refusal> {
    env::home_dir().ok_or_else(|| refused("there is no home folder"))
}
