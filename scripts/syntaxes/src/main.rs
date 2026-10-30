//! Writes the syntaxes `core::highlight` loads, every `.sublime-syntax` file in `sources/`, as an uncompressed newline
//! dump. Those are the syntaxes in `DEFAULTS` from sublimehq/Packages at the commit syntect 5.3.0 builds its defaults
//! from (fa6b8629c95041bf262d4c1dab95c456a0530122), every syntax they embed, and bat 0.26.1's TOML, TypeScript and Swift.
//! Usage: cargo run --release --manifest-path scripts/syntaxes/Cargo.toml -- app/Dewline/Syntaxes.packdump [Packages]
//! With a Packages checkout, it first copies the syntaxes `DEFAULTS` reaches from it into `sources/`.

use std::collections::BTreeSet;

use syntect::dumps::dump_to_uncompressed_file;
use syntect::parsing::syntax_definition::{ContextReference, MatchOperation, Pattern};
use syntect::parsing::{SyntaxDefinition, SyntaxSetBuilder};

const DEFAULTS: &[&str] = &[
    "Rust",
    "Python",
    "JavaScript",
    "JSON",
    "C",
    "C++",
    "Go",
    "Java",
    "Bourne Again Shell (bash)",
    "YAML",
    "HTML",
    "CSS",
    "SQL",
];
const BAT: &[&str] = &["TOML", "TypeScript", "Swift"];

/// The scopes and file names a syntax's contexts reach outside it.
fn references(syntax: &SyntaxDefinition) -> Vec<String> {
    let mut found = Vec::new();
    let mut add = |reference: &ContextReference| match reference {
        ContextReference::ByScope { scope, .. } => found.push(scope.build_string()),
        ContextReference::File { name, .. } => found.push(name.clone()),
        _ => {}
    };
    for context in syntax.contexts.values() {
        for pattern in &context.patterns {
            match pattern {
                Pattern::Include(reference) => add(reference),
                Pattern::Match(pattern) => {
                    if let MatchOperation::Push(references) | MatchOperation::Set(references) =
                        &pattern.operation
                    {
                        references.iter().for_each(&mut add);
                    }
                    if let Some(reference) = &pattern.with_prototype {
                        add(reference);
                    }
                }
            }
        }
    }
    found
}

fn load(path: &std::path::Path) -> SyntaxDefinition {
    SyntaxDefinition::load_from_str(&std::fs::read_to_string(path).unwrap(), true, None).unwrap()
}

/// The `.sublime-syntax` files under `folder`.
fn files(folder: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut found = Vec::new();
    for entry in std::fs::read_dir(folder).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            found.extend(files(&path));
        } else if path
            .extension()
            .is_some_and(|extension| extension == "sublime-syntax")
        {
            found.push(path);
        }
    }
    found
}

/// The names of `wanted` and every syntax they reach in `all`, with the syntaxes nothing in `all` resolves.
fn closure(all: &[SyntaxDefinition], wanted: &[&str]) -> (BTreeSet<String>, BTreeSet<String>) {
    let mut names: BTreeSet<String> = wanted.iter().map(|name| name.to_string()).collect();
    let mut missing = BTreeSet::new();
    loop {
        let mut reached = Vec::new();
        for target in all
            .iter()
            .filter(|syntax| names.contains(&syntax.name))
            .flat_map(references)
        {
            match all
                .iter()
                .find(|syntax| syntax.scope.build_string() == target || syntax.name == target)
            {
                Some(syntax) if !names.contains(&syntax.name) => reached.push(syntax.name.clone()),
                Some(_) => {}
                None => {
                    missing.insert(target);
                }
            }
        }
        if reached.is_empty() {
            return (names, missing);
        }
        names.extend(reached);
    }
}

fn main() {
    let out = std::env::args()
        .nth(1)
        .expect("usage: syntaxes <out.packdump> [Packages]");
    let sources = std::path::Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/sources"));
    if let Some(packages) = std::env::args().nth(2) {
        let packages = std::path::Path::new(&packages);
        let found: Vec<_> = files(packages)
            .into_iter()
            .map(|path| (load(&path), path))
            .collect();
        let all: Vec<_> = found.iter().map(|(syntax, _)| syntax.clone()).collect();
        let (names, _) = closure(&all, DEFAULTS);
        for (syntax, path) in &found {
            if names.contains(&syntax.name) {
                let to = sources
                    .join("Packages")
                    .join(path.strip_prefix(packages).unwrap());
                std::fs::create_dir_all(to.parent().unwrap()).unwrap();
                std::fs::copy(path, to).unwrap();
            }
        }
    }
    let all: Vec<_> = files(sources).iter().map(|path| load(path)).collect();
    let wanted: Vec<&str> = DEFAULTS.iter().chain(BAT).copied().collect();
    let (names, missing) = closure(&all, &wanted);
    assert!(missing.is_empty(), "unresolved: {missing:?}");
    assert_eq!(
        names.len(),
        all.len(),
        "sources/ holds syntaxes nothing reaches"
    );
    let mut builder = SyntaxSetBuilder::new();
    all.into_iter().for_each(|syntax| builder.add(syntax));
    let set = builder.build();
    dump_to_uncompressed_file(&set, &out).unwrap();
    println!(
        "{out}: {}",
        names.into_iter().collect::<Vec<_>>().join(", ")
    );
}
