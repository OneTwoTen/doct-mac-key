//! Acceptance test: run **every** `core/tests/fixtures/*.tsv` row through the
//! reference host simulation (`sim::simulate`, SPEC §6) and compare with the
//! frozen expected document text.
//!
//! This uses a custom test harness (`harness = false` in `Cargo.toml`) so that a
//! plain `cargo test` prints the per-fixture-file pass counts, which the team
//! quotes in reports. The process exits non-zero if any row fails.
//!
//! The fixtures are the behaviour contract and are intentionally not editable
//! from this crate: a mismatch is an engine bug, not a test expectation bug.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use doctkey_core::sim::{self, FixtureLine};

/// Directory holding the frozen fixture files.
fn fixture_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
}

/// Every `.tsv` file in the fixture directory, sorted for deterministic output.
fn fixture_files() -> Result<Vec<PathBuf>, String> {
    let directory = fixture_dir();
    let entries = fs::read_dir(&directory)
        .map_err(|error| format!("cannot read {}: {error}", directory.display()))?;
    let mut files: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|extension| extension == "tsv"))
        .collect();
    files.sort();
    Ok(files)
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("fixtures: FAILED\n{message}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let files = fixture_files()?;
    if files.is_empty() {
        return Err(format!(
            "no .tsv fixtures found in {}",
            fixture_dir().display()
        ));
    }

    let mut total_checked = 0usize;
    let mut failures: Vec<String> = Vec::new();

    for file in &files {
        let name = file
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| file.display().to_string());
        let content = fs::read_to_string(file)
            .map_err(|error| format!("cannot read {}: {error}", file.display()))?;

        let mut checked = 0usize;
        let mut file_failures = 0usize;
        for (index, line) in content.lines().enumerate() {
            match sim::parse_fixture_line(line) {
                FixtureLine::Skip => {}
                FixtureLine::Error(message) => {
                    file_failures += 1;
                    failures.push(format!("{name}:{}: parse error: {message}", index + 1));
                }
                FixtureLine::Row(row) => {
                    checked += 1;
                    let got = sim::simulate(&row.config_json, &row.keys);
                    if got != row.expected {
                        file_failures += 1;
                        failures.push(format!(
                            "{name}:{}: keys {:?}: expected {:?}, got {:?} ({})",
                            index + 1,
                            row.keys,
                            row.expected,
                            got,
                            row.config_json
                        ));
                    }
                }
            }
        }
        total_checked += checked;
        // Printed unconditionally: with a custom harness this is visible in a
        // plain `cargo test` run.
        println!("  {name:<14} {checked:>3} row(s) passed, {file_failures} failed");
    }

    println!(
        "fixtures: {total_checked} row(s) across {} file(s), {} failure(s)",
        files.len(),
        failures.len()
    );

    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("\n"))
    }
}
