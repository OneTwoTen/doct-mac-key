//! Reference host simulation (SPEC §6).
//!
//! [`simulate`] mirrors what the macOS controller does in *direct insert* mode:
//! it keeps a document buffer plus the composition currently on screen, applies
//! every engine result and lets the host process keys the IME passed through.
//! The acceptance fixtures and the CLI fixture runner are written against this
//! function, and the Swift test harness mirrors the same algorithm.

use crate::config::{Config, Method, Mode, ToneStyle};
use crate::engine::{Engine, KeyResult, Op};

/// One parsed fixture row from `core/tests/fixtures/*.tsv` (SPEC §6).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FixtureRow {
    /// Engine config JSON built from the `method,mode,smart,tone_style` column.
    pub config_json: String,
    /// Key sequence (may contain `<BS>`, `<ESC>`, `<ENTER>`, `<TAB>`, …).
    pub keys: String,
    /// Expected document text after the final commit.
    pub expected: String,
}

/// The outcome of parsing one fixture line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FixtureLine {
    /// Blank line or comment.
    Skip,
    /// A usable fixture row.
    Row(FixtureRow),
    /// A malformed row; the message explains why.
    Error(String),
}

/// One simulated key event: a printable scalar or a non-printing key code.
///
/// Exposed so the CLI REPL and tests can drive the engine with the same lexical
/// rules the fixtures use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Token {
    /// A printable scalar, fed through `feed_char`.
    Char(char),
    /// A non-printing key code, fed through `feed_key`.
    Key(u32),
}

/// Parse one line of a fixture file (three TSV columns, `#` comments and blank
/// lines ignored).
pub fn parse_fixture_line(line: &str) -> FixtureLine {
    let line = line.trim_end_matches(['\r', '\n']);
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return FixtureLine::Skip;
    }

    let mut columns = line.split('\t');
    let (Some(config), Some(keys), Some(expected)) =
        (columns.next(), columns.next(), columns.next())
    else {
        return FixtureLine::Error("expected 3 tab-separated columns".to_owned());
    };
    if columns.next().is_some() {
        return FixtureLine::Error("expected exactly 3 tab-separated columns".to_owned());
    }

    let mut parts = config.split(',');
    let (Some(method), Some(mode), Some(smart), Some(style), None) = (
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
    ) else {
        return FixtureLine::Error("config column must be method,mode,smart,tone_style".to_owned());
    };

    let Some(method) = Method::parse(method) else {
        return FixtureLine::Error(format!("unknown method {method:?}"));
    };
    let Some(mode) = Mode::parse(mode) else {
        return FixtureLine::Error(format!("unknown mode {mode:?}"));
    };
    let smart_english = match smart {
        "0" => false,
        "1" => true,
        other => return FixtureLine::Error(format!("smart must be 0 or 1, got {other:?}")),
    };
    let Some(tone_style) = ToneStyle::parse(style) else {
        return FixtureLine::Error(format!("unknown tone_style {style:?}"));
    };

    let config = Config {
        mode,
        method,
        tone_style,
        smart_english,
    };
    FixtureLine::Row(FixtureRow {
        config_json: config.to_json(),
        keys: keys.to_owned(),
        expected: expected.to_owned(),
    })
}

/// Split a fixture key string into printable characters and `<…>` key tokens.
pub fn tokenize(keys: &str) -> Vec<Token> {
    const SPECIAL: &[(&str, u32)] = &[
        ("<BS>", 1),
        ("<DEL>", 2),
        ("<ESC>", 3),
        ("<ENTER>", 4),
        ("<TAB>", 5),
    ];
    let mut tokens = Vec::new();
    let mut rest = keys;
    while let Some(first) = rest.chars().next() {
        if let Some((tag, key)) = SPECIAL.iter().find(|(tag, _)| rest.starts_with(*tag)) {
            tokens.push(Token::Key(*key));
            rest = &rest[tag.len()..];
            continue;
        }
        tokens.push(Token::Char(first));
        rest = &rest[first.len_utf8()..];
    }
    tokens
}

/// Simulate a whole fixture key sequence and return the final document text.
///
/// This is the reference implementation of SPEC §6; the Swift test harness
/// mirrors the same host algorithm.
pub fn simulate(config_json: &str, keys: &str) -> String {
    let mut engine = Engine::new(config_json);
    let mut document = String::new();
    let mut shown = String::new();

    for token in tokenize(keys) {
        let result = match token {
            Token::Char(ch) => engine.feed_char(ch, 0),
            Token::Key(key) => engine.feed_key(key),
        };
        apply(&result, &mut document, &mut shown);
        // SPEC §6: the host also handles the key itself when the IME did not
        // consume it and the result was commit/pass.
        if !result.consumed && matches!(result.op, Op::Commit | Op::Pass) {
            host_process(token, &mut document);
        }
    }

    let result = engine.commit();
    apply(&result, &mut document, &mut shown);
    document
}

/// Apply one engine result to the simulated host buffers.
fn apply(result: &KeyResult, document: &mut String, shown: &mut String) {
    match result.op {
        Op::Append => {
            document.push_str(&result.text);
            *shown = result.word.clone();
        }
        Op::Replace => {
            remove_last_chars(document, shown.chars().count());
            document.push_str(&result.word);
            *shown = result.word.clone();
        }
        Op::Commit => {
            remove_last_chars(document, shown.chars().count());
            document.push_str(&result.text);
            shown.clear();
        }
        Op::Pass | Op::None | Op::State => {}
    }
}

/// What the host does with a key the IME did not swallow.
fn host_process(token: Token, document: &mut String) {
    match token {
        Token::Char(ch) => document.push(ch),
        Token::Key(1) => {
            document.pop();
        }
        Token::Key(4) => document.push('\n'),
        Token::Key(5) => document.push('\t'),
        Token::Key(_) => {}
    }
}

/// Remove the last `count` characters from `buffer` (char-wise, never panic).
fn remove_last_chars(buffer: &mut String, count: usize) {
    if count == 0 {
        return;
    }
    let mut chars: Vec<char> = buffer.chars().collect();
    let keep = chars.len().saturating_sub(count);
    chars.truncate(keep);
    *buffer = chars.into_iter().collect();
}

#[cfg(test)]
mod tests {
    use super::*;

    const VI_TELEX: &str = r#"{"mode":"vi","method":"telex","smart_english":true}"#;
    const VI_TELEX_NO_SMART: &str = r#"{"mode":"vi","method":"telex","smart_english":false}"#;
    const VI_VNI: &str = r#"{"mode":"vi","method":"vni","smart_english":true}"#;
    const EN_TELEX: &str = r#"{"mode":"en","method":"telex","smart_english":true}"#;

    #[test]
    fn simulates_words_and_boundaries() {
        assert_eq!(simulate(VI_TELEX, "vieejt"), "việt");
        assert_eq!(simulate(VI_TELEX, "vieejt nam"), "việt nam");
        assert_eq!(simulate(VI_TELEX, "hello, world!"), "hello, world!");
        assert_eq!(simulate(VI_TELEX, "nam2026"), "nam2026");
        assert_eq!(simulate(VI_TELEX, "abc123"), "abc123");
        assert_eq!(simulate(VI_VNI, "abc123"), "abc123");
        assert_eq!(simulate(EN_TELEX, "vieejt nam"), "vieejt nam");
    }

    #[test]
    fn simulates_editing_keys() {
        assert_eq!(simulate(VI_TELEX, "vieejt<BS>"), "việ");
        assert_eq!(simulate(VI_TELEX, "tooi<BS>"), "tô");
        assert_eq!(simulate(VI_TELEX, "nam<BS>"), "na");
        assert_eq!(simulate(VI_TELEX, "as<ESC>"), "as");
        assert_eq!(simulate(VI_TELEX, "as<ESC> nam"), "as nam");
        assert_eq!(simulate(VI_TELEX, "vieejt<DEL>"), "việ");
        assert_eq!(simulate(VI_TELEX, "tooi<ENTER>"), "tôi\n");
        assert_eq!(simulate(VI_TELEX, "tooi<TAB>"), "tôi\t");
        assert_eq!(simulate(VI_TELEX, "nam <BS>"), "nam");
    }

    #[test]
    fn simulates_undo_literals() {
        assert_eq!(simulate(VI_TELEX, "aaa"), "aa");
        assert_eq!(simulate(VI_TELEX, "ddd"), "dd");
        assert_eq!(simulate(VI_TELEX, "ass"), "as");
        assert_eq!(simulate(VI_TELEX, "aww"), "aw");
        assert_eq!(simulate(VI_TELEX, "booong"), "boong");
        assert_eq!(simulate(VI_TELEX, "aasz"), "â");
        assert_eq!(simulate(VI_TELEX, "aaszz"), "a");
        assert_eq!(simulate(VI_TELEX, "az"), "az");
    }

    #[test]
    fn simulates_smart_off_rendering() {
        assert_eq!(simulate(VI_TELEX_NO_SMART, "looks"), "lốk");
        assert_eq!(simulate(VI_TELEX_NO_SMART, "google"), "gôgle");
        assert_eq!(simulate(VI_TELEX_NO_SMART, "confirm"), "conỉm");
        assert_eq!(simulate(VI_TELEX_NO_SMART, "fresh"), "fréh");
        assert_eq!(simulate(VI_TELEX_NO_SMART, "meeting"), "mêting");
    }

    /// Regression rows expressed in the exact fixture format. These would be
    /// fixture lines if the frozen `core/tests/fixtures/*.tsv` files were ours
    /// to edit; keeping them here locks the same behaviour in.
    #[test]
    fn fixture_style_u_o_and_loanword_cases() {
        let rows = [
            ("telex,vi,1,modern", "quow", "quơ"),
            ("telex,vi,1,modern", "quowr", "quở"),
            ("telex,vi,1,modern", "quows", "quớ"),
            ("telex,vi,1,modern", "uow", "ươ"),
            ("telex,vi,1,modern", "uowng", "ương"),
            ("telex,vi,1,modern", "uowngf", "ường"),
            ("telex,vi,1,modern", "quyeets", "quyết"),
            ("telex,vi,1,modern", "thuowr", "thuở"),
            ("telex,vi,1,modern", "thuowng", "thương"),
            ("telex,vi,1,modern", "huow", "huơ"),
            ("telex,vi,1,modern", "xinee", "xinê"),
            ("vni,vi,1,modern", "quo7", "quơ"),
            ("vni,vi,1,modern", "quo73", "quở"),
            ("vni,vi,1,modern", "u7o7", "ươ"),
            ("vni,vi,1,modern", "xine6", "xinê"),
            // Smart fallback still escapes English words.
            ("telex,vi,1,modern", "hello", "hello"),
            ("telex,vi,1,modern", "google", "google"),
            ("telex,vi,1,modern", "looks", "looks"),
        ];
        for (config, keys, expected) in rows {
            let line = format!("{config}\t{keys}\t{expected}");
            let FixtureLine::Row(row) = parse_fixture_line(&line) else {
                panic!("row did not parse: {line:?}");
            };
            assert_eq!(
                simulate(&row.config_json, &row.keys),
                expected,
                "keys {keys:?} ({config})"
            );
        }
    }

    #[test]
    fn parses_fixture_lines() {
        assert_eq!(parse_fixture_line("# comment"), FixtureLine::Skip);
        assert_eq!(parse_fixture_line("   "), FixtureLine::Skip);
        let FixtureLine::Row(row) = parse_fixture_line("telex,vi,1,modern\tvieejt\tviệt") else {
            panic!("expected a row");
        };
        assert_eq!(row.keys, "vieejt");
        assert_eq!(row.expected, "việt");
        assert_eq!(
            row.config_json,
            r#"{"mode":"vi","method":"telex","tone_style":"modern","smart_english":true}"#
        );
        assert!(matches!(
            parse_fixture_line("telex,vi,1,modern\tonly-two"),
            FixtureLine::Error(_)
        ));
        assert!(matches!(
            parse_fixture_line("bogus,vi,1,modern\tkeys\texpected"),
            FixtureLine::Error(_)
        ));
        assert!(matches!(
            parse_fixture_line("telex,vi,7,modern\tkeys\texpected"),
            FixtureLine::Error(_)
        ));
    }
}
