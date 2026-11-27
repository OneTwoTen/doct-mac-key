//! `doctkey-cli` — command-line front end for the DoctKey engine.
//!
//! Used for manual poking and for running the acceptance fixtures without a
//! macOS host:
//!
//! ```text
//! doctkey-cli --keys "vieejt"                        # final simulated text
//! doctkey-cli --method vni --keys "vie65t"           # VNI
//! doctkey-cli --tone traditional --keys "hoas"       # hóa
//! doctkey-cli --fixtures core/tests/fixtures/telex.tsv
//! doctkey-cli --repl                                 # per-keystroke display
//! ```

use std::fs;
use std::io::{self, BufRead, Write};
use std::path::Path;
use std::process::ExitCode;

use doctkey_core::sim::{self, FixtureLine, Token};
use doctkey_core::{Config, Engine, Method, Mode, Op, ToneStyle};

const USAGE: &str = "\
doctkey-cli — DoctKey engine sandbox

USAGE:
    doctkey-cli [OPTIONS] [--keys <KEYS> | --repl | --fixtures <FILE>]

OPTIONS:
    --method telex|vni          Input method (default: telex)
    --mode vi|en                Language mode (default: vi)
    --smart 0|1                 Smart English fallback (default: 1)
    --tone modern|traditional   Tone placement style (default: modern)
    --keys <KEYS>               Simulate KEYS and print the final document text
    --repl                      Interactive per-keystroke display
    --fixtures <FILE>           Run one .tsv fixture file and print OK/FAIL rows
    -h, --help                  Print this help

KEYS accepts printable characters plus <BS>, <DEL>, <ESC>, <ENTER>, <TAB>.";

/// Fully resolved command-line options.
struct Options {
    method: Method,
    mode: Mode,
    smart_english: bool,
    tone_style: ToneStyle,
    keys: Option<String>,
    fixtures: Option<String>,
    repl: bool,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            method: Method::Telex,
            mode: Mode::Vi,
            smart_english: true,
            tone_style: ToneStyle::Modern,
            keys: None,
            fixtures: None,
            repl: false,
        }
    }
}

impl Options {
    fn config_json(&self) -> String {
        Config {
            mode: self.mode,
            method: self.method,
            tone_style: self.tone_style,
            smart_english: self.smart_english,
        }
        .to_json()
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(code) => ExitCode::from(code),
        Err(message) => {
            eprintln!("error: {message}");
            eprintln!();
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn run(args: &[String]) -> Result<u8, String> {
    let mut options = Options::default();
    let mut index = 0;
    while index < args.len() {
        let flag = args[index].clone();
        match flag.as_str() {
            "-h" | "--help" => {
                println!("{USAGE}");
                return Ok(0);
            }
            "--method" => {
                let value = next_value(args, &mut index, "--method")?;
                options.method = Method::parse(&value)
                    .ok_or_else(|| format!("unknown method {value:?} (expected telex or vni)"))?;
            }
            "--mode" => {
                let value = next_value(args, &mut index, "--mode")?;
                options.mode = Mode::parse(&value)
                    .ok_or_else(|| format!("unknown mode {value:?} (expected vi or en)"))?;
            }
            "--smart" => {
                let value = next_value(args, &mut index, "--smart")?;
                options.smart_english = match value.as_str() {
                    "0" | "false" => false,
                    "1" | "true" => true,
                    _ => return Err(format!("--smart expects 0 or 1, got {value:?}")),
                };
            }
            "--tone" => {
                let value = next_value(args, &mut index, "--tone")?;
                options.tone_style = ToneStyle::parse(&value).ok_or_else(|| {
                    format!("unknown tone style {value:?} (expected modern or traditional)")
                })?;
            }
            "--keys" => {
                options.keys = Some(next_value(args, &mut index, "--keys")?);
            }
            "--fixtures" => {
                options.fixtures = Some(next_value(args, &mut index, "--fixtures")?);
            }
            "--repl" => options.repl = true,
            other => return Err(format!("unknown argument {other:?}")),
        }
        index += 1;
    }

    let config_json = options.config_json();

    if let Some(path) = options.fixtures {
        return run_fixtures(Path::new(&path));
    }
    if options.repl {
        return run_repl(&config_json);
    }
    if let Some(keys) = options.keys {
        println!("{}", sim::simulate(&config_json, &keys));
        return Ok(0);
    }
    println!("{USAGE}");
    Ok(0)
}

fn next_value(args: &[String], index: &mut usize, flag: &str) -> Result<String, String> {
    *index += 1;
    args.get(*index)
        .cloned()
        .ok_or_else(|| format!("{flag} expects a value"))
}

/// Run one fixture file, printing one line per row and a summary.
fn run_fixtures(path: &Path) -> Result<u8, String> {
    let content = fs::read_to_string(path)
        .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
    let mut passed = 0usize;
    let mut failed = 0usize;
    for (line_index, line) in content.lines().enumerate() {
        match sim::parse_fixture_line(line) {
            FixtureLine::Skip => {}
            FixtureLine::Error(message) => {
                failed += 1;
                println!("FAIL line {}: {message}", line_index + 1);
            }
            FixtureLine::Row(row) => {
                let got = sim::simulate(&row.config_json, &row.keys);
                if got == row.expected {
                    passed += 1;
                    println!("OK   {}  =>  {}", row.keys, row.expected);
                } else {
                    failed += 1;
                    println!(
                        "FAIL line {}: keys {:?}: expected {:?}, got {:?}",
                        line_index + 1,
                        row.keys,
                        row.expected,
                        got
                    );
                }
            }
        }
    }
    println!();
    println!("{}: {passed} passed, {failed} failed", path.display());
    Ok(if failed == 0 { 0 } else { 1 })
}

/// Interactive per-keystroke display: one line per key, then the committed text.
fn run_repl(config_json: &str) -> Result<u8, String> {
    let mut engine = Engine::new(config_json);
    println!("DoctKey REPL — {config_json}");
    println!("Type keys then Enter. <BS> <DEL> <ESC> <ENTER> <TAB> are supported. Ctrl-D quits.");

    let stdin = io::stdin();
    let mut input = stdin.lock();
    let mut line = String::new();
    loop {
        print!("keys> ");
        let _ = io::stdout().flush();
        line.clear();
        match input.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(error) => return Err(format!("cannot read stdin: {error}")),
        }
        let entered = line.trim_end_matches(['\r', '\n']);
        for token in sim::tokenize(entered) {
            let (label, result) = match token {
                Token::Char(ch) => (format!("{ch}"), engine.feed_char(ch, 0)),
                Token::Key(key) => (format!("<{}>", key_name(key)), engine.feed_key(key)),
            };
            println!(
                "  {:<8} op={:<8} text={:<10?} word={:<10?} raw={:<10?} consumed={}",
                label,
                result.op.as_str(),
                result.text,
                result.word,
                result.raw,
                result.consumed
            );
        }
        let committed = engine.commit();
        if committed.op == Op::Commit {
            println!("  committed {:?}", committed.text);
        } else {
            println!("  (no composition to commit)");
        }
    }
    Ok(0)
}

fn key_name(key: u32) -> &'static str {
    match key {
        1 => "BS",
        2 => "DEL",
        3 => "ESC",
        4 => "ENTER",
        5 => "TAB",
        6 => "MOVE",
        _ => "KEY",
    }
}
