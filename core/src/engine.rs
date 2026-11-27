//! The per-word state machine (SPEC §5) and the JSON result it returns.
//!
//! The engine stores the raw keystrokes of the word being composed and
//! **recomputes** the rendered word from scratch on every keystroke ("canonical
//! recompute", SPEC §5.2). That makes backspace, escape and operator undo
//! deterministic: nothing derived is ever stored, only raw keys plus the last
//! rendered string (used to decide between `append` and `replace`).
//!
//! All state is per engine instance and the engine is single-threaded; the C
//! ABI keeps one instance per IME process.

use serde_json::Value;

use crate::config::{Config, Method, Mode};
use crate::letters::{
    normalize_u_o, quality_string, raw_string, render, Letter, Quality, RawKey, Tone,
};
use crate::syllable;
use crate::telex;
use crate::tone;
use crate::vni;

/// What the host should do with the text on screen (SPEC §3).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    /// The composition grew by `text` (insert it at the caret).
    Append,
    /// Replace the visible composition with `word`.
    Replace,
    /// End the composition: replace the visible composition with `text`.
    Commit,
    /// The IME did nothing: let the host process the key normally.
    Pass,
    /// The key was consumed but nothing on screen changes.
    None,
    /// Command/status snapshot (SPEC §4).
    State,
}

impl Op {
    /// The wire name used in the JSON result.
    pub fn as_str(self) -> &'static str {
        match self {
            Op::Append => "append",
            Op::Replace => "replace",
            Op::Commit => "commit",
            Op::Pass => "pass",
            Op::None => "none",
            Op::State => "state",
        }
    }
}

/// The result of one engine call, serialised to JSON for the C ABI (SPEC §3).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyResult {
    /// Operation the host must perform.
    pub op: Op,
    /// Suffix to append (append), or full replacement text (replace/commit).
    pub text: String,
    /// The full visible composition.
    pub word: String,
    /// The literal keystrokes of the current word.
    pub raw: String,
    /// Whether a word is being composed.
    pub composing: bool,
    /// Whether the physical key event must be swallowed by the IME.
    pub consumed: bool,
    /// Present only for command/status results (SPEC §4).
    pub changed: Option<bool>,
}

fn push_json_str(out: &mut String, s: &str) {
    out.push('"');
    if !s.bytes().any(|b| b < 0x20 || b == b'"' || b == b'\\') {
        out.push_str(s);
        out.push('"');
        return;
    }
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\x08' => out.push_str("\\b"),
            '\x0c' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let code = c as u8;
                out.push_str("\\u00");
                out.push(HEX[(code >> 4) as usize] as char);
                out.push(HEX[(code & 0x0f) as usize] as char);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

impl KeyResult {
    /// Serialise this result as the JSON object described in SPEC §3.
    pub fn to_json(&self, cfg: &Config) -> String {
        let mut out = String::with_capacity(160 + self.text.len() + self.word.len() + self.raw.len());
        out.push_str("{\"op\":\"");
        out.push_str(self.op.as_str());
        out.push_str("\",\"text\":");
        push_json_str(&mut out, &self.text);
        out.push_str(",\"word\":");
        push_json_str(&mut out, &self.word);
        out.push_str(",\"raw\":");
        push_json_str(&mut out, &self.raw);
        out.push_str(",\"composing\":");
        out.push_str(if self.composing { "true" } else { "false" });
        out.push_str(",\"consumed\":");
        out.push_str(if self.consumed { "true" } else { "false" });
        out.push_str(",\"mode\":\"");
        out.push_str(cfg.mode.as_str());
        out.push_str("\",\"method\":\"");
        out.push_str(cfg.method.as_str());
        out.push_str("\",\"tone_style\":\"");
        out.push_str(cfg.tone_style.as_str());
        out.push_str("\",\"smart\":");
        out.push_str(if cfg.smart_english { "true" } else { "false" });
        if let Some(changed) = self.changed {
            out.push_str(",\"changed\":");
            out.push_str(if changed { "true" } else { "false" });
        }
        out.push('}');
        out
    }
}

fn is_valid_vietnamese_letters(letters: &[Letter]) -> bool {
    if letters.is_empty() || letters.len() > 8 {
        return false;
    }
    syllable::is_valid_or_prefix(&quality_string(letters))
}

fn has_forbidden_checked_tone(letters: &[Letter], tone: Option<Tone>) -> bool {
    if !matches!(tone, Some(Tone::Grave | Tone::Hook | Tone::Tilde)) {
        return false;
    }
    let Some(last) = letters.last() else {
        return false;
    };
    matches!(last.base, 'c' | 'p' | 't')
        || (letters.len() >= 2 && letters[letters.len() - 2].base == 'c' && last.base == 'h')
}

/// One full rendering of the current raw keystrokes (SPEC §5.2, §5.5).
struct Rendered {
    /// The visible text: Vietnamese, or the literal keystrokes when escaped.
    word: String,
    /// Whether the smart fallback took the literal keystrokes.
    escaped: bool,
    /// Index of a letter produced by a standalone `w` (`w → ư`), if any.
    standalone_w: Option<usize>,
}

/// Whether the letters end with the blind `ưo` pair (`tưo`, from `two`).
fn ends_with_blind_horn_o(letters: &[Letter]) -> bool {
    let len = letters.len();
    len >= 2
        && letters[len - 1].base == 'o'
        && letters[len - 1].quality.is_none()
        && letters[len - 2].base == 'u'
        && letters[len - 2].quality == Some(Quality::Horn)
}

/// Whether `next` may follow a `ư` in a Vietnamese syllable.
///
/// `ư` continues with `a`/`i`/`u`/`ơ` and with the codas `c m n ng p t`; `o` is
/// allowed because the next key turns the pair into `ươ` (`người`, `được`).
/// Everything else (`sưê`, `sưi` + coda, `tưem`, …) cannot be Vietnamese.
fn vietnamese_after_horn(next: Option<&Letter>) -> bool {
    match next {
        None => true,
        Some(letter) => matches!(letter.base, 'a' | 'i' | 'o' | 'u' | 'c' | 'm' | 'n' | 'p' | 't'),
    }
}

/// Recompute the rendering of raw keystrokes (SPEC §5.2, §5.5).
///
/// Priority is Vietnamese-first, the way UniKey behaves: whenever the untoned
/// form is a Vietnamese syllable/prefix, its rendering wins — even when the same
/// keystrokes spell an English word (`test → tét`, `this → thí`). Only a form
/// that cannot be Vietnamese falls back to the literal keystrokes, which is what
/// keeps `hello`, `meeting` or `google` intact.
///
/// The fallback has one exception — "keep the Vietnamese rendering even though
/// it is not valid" — which is deliberately narrow: it applies only when the
/// **last** raw key was itself an undo/removal (a repeated operator undo, or
/// `z`/`0` clearing a mark). An undo earlier in the word does not exempt later
/// ordinary keystrokes, so `aaa` keeps `aa` but `hardware` and `message` fall
/// back to their literal keystrokes.
fn render_word_into(cfg: &Config, raw: &[RawKey], letters: &mut Vec<Letter>) -> Rendered {
    letters.clear();
    let mut tone = None;
    let mut last_key_undo = false;
    let mut standalone_w = None;
    match cfg.method {
        Method::Telex => telex::replay(
            raw,
            cfg.tone_style,
            letters,
            &mut tone,
            &mut last_key_undo,
            &mut standalone_w,
        ),
        Method::Vni => vni::replay(
            raw,
            cfg.tone_style,
            letters,
            &mut tone,
            &mut last_key_undo,
        ),
    }
    // `u` + `ơ` → `ươ` needs the following letters (open `uơ` words such as
    // `quơ`/`thuở` must stay), so it is applied once, after the replay.
    normalize_u_o(letters);
    // `w → ư` (SPEC §5.2) must not eat English: a `ư` that the following letter
    // can never continue in Vietnamese (`sweet` → `sưêt`) gives the key back.
    if let Some(index) = standalone_w {
        if !vietnamese_after_horn(letters.get(index + 1)) {
            letters[index] = Letter::new('w', letters[index].upper);
            standalone_w = None;
        }
    }

    let valid = is_valid_vietnamese_letters(letters) && !has_forbidden_checked_tone(letters, tone);
    // The undo exception lets repeated operator keys undo cleanly (`aaa → aa`,
    // `ass → as`) instead of flipping mid-word to the literal keystrokes. It must
    // stay narrow: an ordinary English word can also end with an operator that
    // happens to undo an earlier one (`deliveryor` → the second `r`, `order`,
    // `class`, `staff`). Keep the exception only when the untoned result is still
    // a Vietnamese syllable/prefix, or when the whole word is a tiny undo
    // pattern.
    let undo_exemption = last_key_undo && (valid || raw.len() <= 3);
    // Vietnamese-first (UniKey parity): a valid Vietnamese form always wins, no
    // matter what English word the same keystrokes could spell. English survives
    // only because it is *not* Vietnamese (`hello`, `meeting`, `google`) or
    // because the last key was an undo (see above).
    let escaped = cfg.mode == Mode::Vi
        && cfg.smart_english
        && !raw.is_empty()
        && !valid
        && !undo_exemption;

    let word = if escaped {
        raw_string(raw)
    } else {
        let placement =
            tone.and_then(|tone| tone::place(letters, cfg.tone_style).map(|index| (tone, index)));
        match placement {
            Some((tone, index)) => render(letters, Some(tone), Some(index)),
            None => render(letters, None, None),
        }
    };

    Rendered {
        word,
        escaped,
        standalone_w,
    }
}

/// The DoctKey composition engine.
///
/// One instance represents one IME process: configuration (mode, method, tone
/// style, literal fallback) is engine-wide, while the composition state is cleared
/// by [`Engine::reset`].
#[derive(Clone, Debug)]
pub struct Engine {
    cfg: Config,
    raw: Vec<RawKey>,
    shown: String,
    letters_buf: Vec<Letter>,
}

impl Engine {
    /// Create an engine from an optional config JSON object. Invalid JSON falls
    /// back to the defaults (SPEC §4).
    pub fn new(config_json: &str) -> Engine {
        Engine {
            cfg: Config::from_json(config_json),
            raw: Vec::with_capacity(16),
            shown: String::with_capacity(32),
            letters_buf: Vec::with_capacity(16),
        }
    }

    /// The current configuration.
    pub fn config(&self) -> &Config {
        &self.cfg
    }

    /// The currently visible word (may be empty).
    pub fn word(&self) -> &str {
        &self.shown
    }

    /// The literal keystrokes of the current word.
    pub fn raw(&self) -> String {
        raw_string(&self.raw)
    }

    /// Merge a config JSON object, keeping the current composition in sync with
    /// the new settings. Returns `false` (and changes nothing) on bad JSON.
    pub fn set_config(&mut self, config_json: &str) -> bool {
        let mut next = self.cfg.clone();
        if !next.merge_json(config_json) {
            return false;
        }
        self.cfg = next;
        self.refresh();
        true
    }

    /// Re-render the current composition (after a settings change) so the
    /// engine's mirror of the screen stays accurate.
    fn refresh(&mut self) {
        if self.raw.is_empty() {
            self.shown.clear();
        } else {
            let rendered = render_word_into(&self.cfg, &self.raw, &mut self.letters_buf);
            self.shown.clear();
            self.shown.push_str(&rendered.word);
        }
    }

    /// Feed one printable character (already carrying its case, SPEC §3).
    ///
    /// `flags` mirrors the C ABI: bit 0 = Shift, bit 1 = Caps Lock (bit 2 =
    /// Option, ignored).
    pub fn feed_char(&mut self, ch: char, flags: u32) -> KeyResult {
        if self.cfg.mode == Mode::En {
            if self.raw.is_empty() {
                return self.pass();
            }
            // A composition can only survive here after a config switch;
            // commit it so the host is not left with stale marked text.
            return self.commit_composition(false);
        }

        if ch.is_ascii_alphabetic() {
            let upper = ch.is_ascii_uppercase() || flags & 0b11 != 0;
            self.raw.push(RawKey::new(ch.to_ascii_lowercase(), upper));
            return self.after_change();
        }

        if ch.is_ascii_digit() {
            return match self.cfg.method {
                // Telex: digits always break the word.
                Method::Telex => self.break_char(),
                Method::Vni => self.vni_digit(ch),
            };
        }

        // Space, punctuation, control characters, or any non-ASCII scalar.
        self.break_char()
    }

    /// Feed a non-printing key (SPEC §3):
    /// 1 = backspace, 2 = forward delete, 3 = escape, 4 = return, 5 = tab,
    /// 6 = caret movement / other command key.
    pub fn feed_key(&mut self, key: u32) -> KeyResult {
        match key {
            1 | 2 => self.backspace(),
            3 => self.escape(),
            4 | 5 | 6 => self.break_key(),
            _ => self.pass(),
        }
    }

    /// Commit the current composition (focus loss, menu action, …).
    pub fn commit(&mut self) -> KeyResult {
        if self.raw.is_empty() {
            return KeyResult {
                op: Op::None,
                text: String::new(),
                word: String::new(),
                raw: String::new(),
                composing: false,
                consumed: true,
                changed: None,
            };
        }
        self.commit_composition(true)
    }

    /// Drop composition state without emitting text (e.g. the controller lost
    /// track of the screen).
    pub fn reset(&mut self) {
        self.raw.clear();
        self.shown.clear();
    }

    /// Execute a command object (SPEC §4).
    pub fn command(&mut self, command_json: &str) -> KeyResult {
        let value: Value = match serde_json::from_str(command_json) {
            Ok(value) => value,
            Err(_) => return self.state_result(false),
        };
        let Some(object) = value.as_object() else {
            return self.state_result(false);
        };
        let cmd = object.get("cmd").and_then(Value::as_str).unwrap_or("");
        match cmd {
            "set_mode" => match object
                .get("mode")
                .and_then(Value::as_str)
                .and_then(Mode::parse)
            {
                Some(mode) => self.change_mode(mode),
                None => self.state_result(false),
            },
            "toggle_mode" => {
                let mode = if self.cfg.mode == Mode::Vi {
                    Mode::En
                } else {
                    Mode::Vi
                };
                self.change_mode(mode)
            }
            "set_method" => match object
                .get("method")
                .and_then(Value::as_str)
                .and_then(Method::parse)
            {
                Some(method) => self.change_method(method),
                None => self.state_result(false),
            },
            "toggle_method" => {
                let method = if self.cfg.method == Method::Telex {
                    Method::Vni
                } else {
                    Method::Telex
                };
                self.change_method(method)
            }
            "set_tone_style" => {
                match object
                    .get("tone_style")
                    .and_then(Value::as_str)
                    .and_then(crate::config::ToneStyle::parse)
                {
                    Some(style) => {
                        let changed = self.cfg.tone_style != style;
                        self.cfg.tone_style = style;
                        self.refresh();
                        self.state_result(changed)
                    }
                    None => self.state_result(false),
                }
            }
            "toggle_tone_style" => {
                let style = if self.cfg.tone_style == crate::config::ToneStyle::Modern {
                    crate::config::ToneStyle::Traditional
                } else {
                    crate::config::ToneStyle::Modern
                };
                self.cfg.tone_style = style;
                self.refresh();
                self.state_result(true)
            }
            "set_smart" => match object.get("smart").and_then(Value::as_bool) {
                Some(smart) => {
                    let changed = self.cfg.smart_english != smart;
                    self.cfg.smart_english = smart;
                    self.refresh();
                    self.state_result(changed)
                }
                None => self.state_result(false),
            },
            "toggle_smart" => {
                self.cfg.smart_english = !self.cfg.smart_english;
                self.refresh();
                self.state_result(true)
            }
            "set_config" => self.command_set_config(object.get("config")),
            "commit" => {
                if self.raw.is_empty() {
                    self.state_result(false)
                } else {
                    let mut result = self.commit_composition(true);
                    result.changed = Some(true);
                    result
                }
            }
            "reset" => {
                let had_composition = !self.raw.is_empty();
                self.raw.clear();
                self.shown.clear();
                let mut result = self.state_result(had_composition);
                // SPEC §4: `reset` reports op="none".
                result.op = Op::None;
                result.consumed = true;
                result
            }
            _ => self.state_result(false),
        }
    }

    /// Current state snapshot (op="state", `changed: false`).
    pub fn status(&self) -> KeyResult {
        self.state_result(false)
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// Re-render after a raw key changed and produce append/replace.
    fn after_change(&mut self) -> KeyResult {
        let rendered = render_word_into(&self.cfg, &self.raw, &mut self.letters_buf);
        let new_word = rendered.word;
        let escaped = rendered.escaped;
        let (op, text) = if let Some(suffix) = new_word.strip_prefix(self.shown.as_str()) {
            // First key of a word: `self.shown` is "" so this appends the whole word.
            (Op::Append, suffix.to_owned())
        } else {
            (Op::Replace, new_word.clone())
        };
        self.shown.clear();
        self.shown.push_str(&new_word);
        let raw = if escaped {
            new_word.clone()
        } else {
            raw_string(&self.raw)
        };
        KeyResult {
            op,
            text,
            word: new_word,
            raw,
            composing: !self.raw.is_empty(),
            consumed: true,
            changed: None,
        }
    }

    /// Try to use a VNI digit as an operator; fall back to a break character
    /// when it cannot act (SPEC §5.2).
    ///
    /// Applicability is decided by *simulation*: the digit only acts when it
    /// changes the rendered word and the result is Vietnamese. That keeps the
    /// retroactive quality marks working (`vie` + `6` → `viê`, `thuo` + `7` →
    /// `thuơ`) while digits after English or after an impossible target stay
    /// literal (`abc` + `1`, `a9`, `qu` + `1`).
    fn vni_digit(&mut self, ch: char) -> KeyResult {
        if self.raw.is_empty() {
            return self.pass();
        }
        let before = render_word_into(&self.cfg, &self.raw, &mut self.letters_buf);
        let mut probe_raw = self.raw.clone();
        probe_raw.push(RawKey::new(ch, false));
        let mut probe_letters = Vec::with_capacity(16);
        let after = render_word_into(&self.cfg, &probe_raw, &mut probe_letters);
        if after.escaped || after.word == before.word {
            return self.break_char();
        }
        self.raw.push(RawKey::new(ch, false));
        self.after_change()
    }

    /// Remove the last raw key and recompute (backspace / forward delete).
    fn backspace(&mut self) -> KeyResult {
        if self.raw.is_empty() {
            return self.pass();
        }
        self.raw.pop();
        self.after_replace()
    }

    /// Replace the visible composition with the recomputed word (may be empty).
    fn after_replace(&mut self) -> KeyResult {
        let rendered = render_word_into(&self.cfg, &self.raw, &mut self.letters_buf);
        let word = rendered.word;
        self.shown.clear();
        self.shown.push_str(&word);
        let raw = if rendered.escaped {
            word.clone()
        } else {
            raw_string(&self.raw)
        };
        KeyResult {
            op: Op::Replace,
            text: word.clone(),
            word,
            raw,
            composing: !self.raw.is_empty(),
            consumed: true,
            changed: None,
        }
    }

    /// Escape: restore the literal raw keystrokes and end the composition.
    fn escape(&mut self) -> KeyResult {
        if self.raw.is_empty() {
            return self.pass();
        }
        let literal = raw_string(&self.raw);
        self.raw.clear();
        self.shown.clear();
        KeyResult {
            op: Op::Replace,
            text: literal.clone(),
            word: literal,
            raw: String::new(),
            composing: false,
            consumed: true,
            changed: None,
        }
    }

    /// A break character or command key while composing.
    fn break_char(&mut self) -> KeyResult {
        if self.raw.is_empty() {
            self.pass()
        } else {
            self.commit_composition(false)
        }
    }

    fn break_key(&mut self) -> KeyResult {
        if self.raw.is_empty() {
            self.pass()
        } else {
            self.commit_composition(false)
        }
    }

    /// End the composition, inserting `text` where it was.
    fn commit_composition(&mut self, consumed: bool) -> KeyResult {
        let mut text = std::mem::take(&mut self.shown);
        // A standalone `w` that became `ư` + `o` at the end of the word (`tw` +
        // `o` → `tưo`) is not Vietnamese — that shape only exists while a coda
        // is still coming (`người`, `được`). Give the key back so `two` commits
        // as `two`; the `ưo` variants of real words are never word-final.
        if !self.raw.is_empty() {
            let rendered = render_word_into(&self.cfg, &self.raw, &mut self.letters_buf);
            if rendered.standalone_w.is_some() && ends_with_blind_horn_o(&self.letters_buf) {
                text = raw_string(&self.raw);
            }
        }
        self.raw.clear();
        KeyResult {
            op: Op::Commit,
            text,
            word: String::new(),
            raw: String::new(),
            composing: false,
            consumed,
            changed: None,
        }
    }

    /// A `pass` result: the host handles the key normally.
    fn pass(&self) -> KeyResult {
        KeyResult {
            op: Op::Pass,
            text: String::new(),
            word: self.shown.clone(),
            raw: raw_string(&self.raw),
            composing: !self.raw.is_empty(),
            consumed: false,
            changed: None,
        }
    }

    fn state_result(&self, changed: bool) -> KeyResult {
        KeyResult {
            op: Op::State,
            text: String::new(),
            word: self.shown.clone(),
            raw: raw_string(&self.raw),
            composing: !self.raw.is_empty(),
            consumed: false,
            changed: Some(changed),
        }
    }

    fn change_mode(&mut self, mode: Mode) -> KeyResult {
        if self.cfg.mode == mode {
            return self.state_result(false);
        }
        if !self.raw.is_empty() {
            // SPEC §4: mode changes must not silently lose a half-typed word.
            let mut result = self.commit_composition(true);
            self.cfg.mode = mode;
            result.changed = Some(true);
            return result;
        }
        self.cfg.mode = mode;
        self.refresh();
        self.state_result(true)
    }

    fn change_method(&mut self, method: Method) -> KeyResult {
        if self.cfg.method == method {
            return self.state_result(false);
        }
        if !self.raw.is_empty() {
            // SPEC §4: method changes commit the visible composition.
            let mut result = self.commit_composition(true);
            self.cfg.method = method;
            result.changed = Some(true);
            return result;
        }
        self.cfg.method = method;
        self.refresh();
        self.state_result(true)
    }

    fn command_set_config(&mut self, config: Option<&Value>) -> KeyResult {
        let Some(Value::Object(object)) = config else {
            return self.state_result(false);
        };
        let mut next = self.cfg.clone();
        next.merge_object(object);
        let changed = next != self.cfg;
        if !changed {
            return self.state_result(false);
        }
        let switches_interpretation = next.method != self.cfg.method || next.mode != self.cfg.mode;
        if switches_interpretation && !self.raw.is_empty() {
            let mut result = self.commit_composition(true);
            self.cfg = next;
            result.changed = Some(true);
            return result;
        }
        self.cfg = next;
        self.refresh();
        self.state_result(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ToneStyle;

    fn new_engine(config: &str) -> Engine {
        Engine::new(config)
    }

    fn type_keys(engine: &mut Engine, keys: &str) {
        for ch in keys.chars() {
            engine.feed_char(ch, 0);
        }
    }

    fn word_of(config: &str, keys: &str) -> String {
        let mut engine = new_engine(config);
        type_keys(&mut engine, keys);
        engine.shown.clone()
    }

    const TELEX_VI: &str = r#"{"mode":"vi","method":"telex","smart_english":true}"#;
    const TELEX_VI_NO_SMART: &str = r#"{"mode":"vi","method":"telex","smart_english":false}"#;
    const VNI_VI: &str = r#"{"mode":"vi","method":"vni","smart_english":true}"#;
    const TELEX_EN: &str = r#"{"mode":"en","method":"telex","smart_english":true}"#;

    #[test]
    fn result_json_has_the_spec_shape() {
        let mut engine = new_engine(TELEX_VI);
        let result = engine.feed_char('a', 0);
        let json = result.to_json(&engine.cfg);
        let value: Value = serde_json::from_str(&json).expect("result must be valid JSON");
        for field in [
            "op",
            "text",
            "word",
            "raw",
            "composing",
            "consumed",
            "mode",
            "method",
            "tone_style",
            "smart",
        ] {
            assert!(value.get(field).is_some(), "missing field {field}");
        }
        assert_eq!(value["op"], "append");
        assert_eq!(value["text"], "a");
        assert_eq!(value["raw"], "a");
        assert!(value["composing"].as_bool().unwrap());
        assert_eq!(value["mode"], "vi");
        assert_eq!(value["method"], "telex");
        assert_eq!(value["tone_style"], "modern");
        assert!(value["smart"].as_bool().unwrap());
        assert!(value.get("changed").is_none());
    }

    #[test]
    fn append_versus_replace() {
        let mut engine = new_engine(TELEX_VI);
        let first = engine.feed_char('v', 0);
        assert_eq!((first.op, first.text.as_str()), (Op::Append, "v"));
        let second = engine.feed_char('i', 0);
        assert_eq!((second.op, second.text.as_str()), (Op::Append, "i"));
        // `vi` + `ee` merges into `viê`: no shared prefix with `vi`.
        engine.feed_char('e', 0);
        let merged = engine.feed_char('e', 0);
        assert_eq!(merged.op, Op::Replace);
        assert_eq!(merged.word, "viê");
    }

    #[test]
    fn tone_and_case() {
        assert_eq!(word_of(TELEX_VI, "as"), "á");
        assert_eq!(word_of(TELEX_VI, "VIEEJT"), "VIỆT");
        assert_eq!(word_of(TELEX_VI, "DDI"), "ĐI");
        assert_eq!(word_of(TELEX_VI, "Dd"), "Đ");
        assert_eq!(word_of(TELEX_VI, "Chaof"), "Chào");
    }

    #[test]
    fn shift_and_caps_flags_mark_uppercase() {
        let mut engine = new_engine(TELEX_VI);
        engine.feed_char('d', 0b01);
        engine.feed_char('d', 0b01);
        assert_eq!(engine.shown, "Đ");
        let mut engine = new_engine(TELEX_VI);
        engine.feed_char('a', 0b01);
        engine.feed_char('s', 0);
        assert_eq!(engine.shown, "Á");
    }

    #[test]
    fn break_characters_commit_and_pass() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "vieejt");
        let result = engine.feed_char(' ', 0);
        assert_eq!(result.op, Op::Commit);
        assert_eq!(result.text, "việt");
        assert!(!result.consumed);
        assert!(!result.composing);
        assert_eq!(result.word, "");
    }

    #[test]
    fn break_character_without_composition_passes() {
        let mut engine = new_engine(TELEX_VI);
        let result = engine.feed_char(' ', 0);
        assert_eq!(result.op, Op::Pass);
        assert!(!result.consumed);
    }

    #[test]
    fn digits_break_in_telex_and_operate_in_vni() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "nam");
        let result = engine.feed_char('2', 0);
        assert_eq!(result.op, Op::Commit);
        assert!(!result.consumed);
        assert_eq!(result.text, "nam");

        assert_eq!(word_of(VNI_VI, "a1"), "á");
        assert_eq!(word_of(VNI_VI, "vie65t"), "việt");
        // `a9` has no target: the digit is a break character.
        let mut engine = new_engine(VNI_VI);
        type_keys(&mut engine, "a");
        let result = engine.feed_char('9', 0);
        assert_eq!(result.op, Op::Commit);
        assert!(!result.consumed);
        // `qu1`: vowel exists but cannot carry a tone → break.
        let mut engine = new_engine(VNI_VI);
        type_keys(&mut engine, "qu");
        let result = engine.feed_char('1', 0);
        assert_eq!(result.op, Op::Commit);
        assert!(!result.consumed);
    }

    #[test]
    fn vni_escaped_word_does_not_swallow_digits() {
        let mut engine = new_engine(VNI_VI);
        type_keys(&mut engine, "abc");
        assert_eq!(engine.shown, "abc");
        let result = engine.feed_char('1', 0);
        assert_eq!(result.op, Op::Commit);
        assert!(!result.consumed);
    }

    #[test]
    fn backspace_removes_one_raw_key() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "vieejt");
        let result = engine.feed_key(1);
        assert_eq!(result.op, Op::Replace);
        assert_eq!(result.word, "việ");
        assert!(result.consumed);
        assert!(result.composing);
        assert_eq!(result.raw, "vieej");
    }

    #[test]
    fn backspace_to_empty_word_reports_empty_replace() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "a");
        engine.feed_key(1);
        let last = engine.feed_key(1);
        assert_eq!(last.op, Op::Pass);
        // The transition to an empty word used replace with empty text.
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "a");
        let result = engine.feed_key(1);
        assert_eq!(result.op, Op::Replace);
        assert_eq!(result.word, "");
        assert!(!result.composing);
        assert!(result.consumed);
    }

    #[test]
    fn forward_delete_behaves_like_backspace() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "tooi");
        let result = engine.feed_key(2);
        assert_eq!(result.word, "tô");
    }

    #[test]
    fn escape_restores_literal_keystrokes() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "vieejt");
        let result = engine.feed_key(3);
        assert_eq!(result.op, Op::Replace);
        assert_eq!(result.text, "vieejt");
        assert_eq!(result.word, "vieejt");
        assert!(!result.composing);
        assert!(result.consumed);
        assert_eq!(engine.feed_key(3).op, Op::Pass);
    }

    #[test]
    fn return_tab_and_command_keys_commit_and_pass() {
        for key in [4, 5, 6] {
            let mut engine = new_engine(TELEX_VI);
            type_keys(&mut engine, "tooi");
            let result = engine.feed_key(key);
            assert_eq!(result.op, Op::Commit);
            assert_eq!(result.text, "tôi");
            assert!(!result.consumed);
        }
    }

    #[test]
    fn english_mode_passes_everything() {
        let mut engine = new_engine(TELEX_EN);
        for ch in "vieejt nam".chars() {
            let result = engine.feed_char(ch, 0);
            assert_eq!(result.op, Op::Pass, "char {ch:?}");
            assert!(!result.consumed);
        }
        assert_eq!(engine.shown, "");
        assert_eq!(engine.feed_key(1).op, Op::Pass);
    }

    /// Priority is Vietnamese-first, exactly like UniKey: the same keystrokes
    /// produce the Vietnamese syllable whenever they *are* a Vietnamese spelling.
    #[test]
    fn vietnamese_spelling_beats_the_english_reading() {
        for (keys, expected) in [
            ("test", "tét"),
            ("best", "bét"),
            ("cost", "cót"),
            ("reset", "rết"),
            ("sense", "sến"),
            ("tense", "tến"),
            ("dense", "dến"),
            ("deed", "đê"),
            ("most", "mót"),
            ("this", "thí"),
            ("there", "thể"),
            ("these", "thế"),
            ("here", "hể"),
            ("queen", "quên"),
            ("chair", "chải"),
            ("treen", "trên"),
            ("texts", "tét"),
        ] {
            assert_eq!(word_of(TELEX_VI, keys), expected, "keys {keys:?}");
        }
        // Smart off keeps the same Vietnamese rendering for these.
        assert_eq!(word_of(TELEX_VI_NO_SMART, "test"), "tét");
    }

    /// English only survives when the keystrokes cannot be Vietnamese.
    #[test]
    fn english_words_that_are_not_vietnamese_stay_literal() {
        for word in [
            "hello",
            "meeting",
            "looks",
            "google",
            "confirm",
            "fresh",
            "world",
            "church",
            "boring",
            "choose",
            "order",
            "class",
            "staff",
            "deliveryor",
            "hardware",
            "message",
            "business",
            "software",
            "directory",
            "different",
            "current",
            "commission",
            // `text` would be `tẽt`, but `~` cannot precede `t` (SPEC §5.3).
            "text",
            // UniKey's `w → ư` must not eat `sweet` either.
            "sweet",
            "twelve",
            "between",
        ] {
            assert_eq!(word_of(TELEX_VI, word), word, "word {word:?}");
        }
        // `tw` + `o` is a `ưo` only while a coda is still coming (`người`), so
        // `two` is given back when the word ends (see `commit`).
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "two");
        assert_eq!(engine.commit().text, "two");
        assert_eq!(word_of(TELEX_VI_NO_SMART, "looks"), "lốk");
        assert_eq!(word_of(TELEX_VI_NO_SMART, "confirm"), "conỉm");
        // Undo literals keep the Vietnamese rendering even when invalid.
        assert_eq!(word_of(TELEX_VI, "aaa"), "aa");
        assert_eq!(word_of(TELEX_VI, "ass"), "as");
    }

    #[test]
    fn smart_fallback_can_switch_back_to_replace() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "look");
        assert_eq!(engine.shown, "look");
        let result = engine.feed_char('s', 0);
        assert_eq!(result.op, Op::Append);
        assert_eq!(result.text, "s");
        assert_eq!(result.word, "looks");
    }

    #[test]
    fn commit_reports_text_and_resets() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "tooi");
        let result = engine.commit();
        assert_eq!(result.op, Op::Commit);
        assert_eq!(result.text, "tôi");
        assert!(result.consumed);
        assert_eq!(engine.commit().op, Op::None);
    }

    #[test]
    fn reset_drops_state() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "tooi");
        engine.reset();
        assert_eq!(engine.shown, "");
        assert_eq!(engine.commit().op, Op::None);
    }

    #[test]
    fn tone_style_changes_rerender_the_composition() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "hoas");
        assert_eq!(engine.shown, "hoá");
        let result = engine.command(r#"{"cmd":"set_tone_style","tone_style":"traditional"}"#);
        assert_eq!(result.op, Op::State);
        assert_eq!(result.changed, Some(true));
        assert_eq!(result.word, "hóa");
        assert_eq!(engine.shown, "hóa");
    }

    #[test]
    fn mode_and_method_changes_commit_a_composition() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "tooi");
        let result = engine.command(r#"{"cmd":"toggle_mode"}"#);
        assert_eq!(result.op, Op::Commit);
        assert_eq!(result.text, "tôi");
        assert_eq!(result.changed, Some(true));
        assert_eq!(engine.config().mode, Mode::En);

        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "tooi");
        let result = engine.command(r#"{"cmd":"set_method","method":"vni"}"#);
        assert_eq!(result.op, Op::Commit);
        assert_eq!(result.text, "tôi");
        assert_eq!(engine.config().method, Method::Vni);
    }

    #[test]
    fn toggles_are_idempotent_state_changes() {
        let mut engine = new_engine(TELEX_VI);
        let result = engine.command(r#"{"cmd":"toggle_smart"}"#);
        assert_eq!(result.op, Op::State);
        assert_eq!(result.changed, Some(true));
        assert!(!engine.config().smart_english);
        let again = engine.command(r#"{"cmd":"toggle_smart"}"#);
        assert_eq!(again.changed, Some(true));
        assert!(engine.config().smart_english);
        // `set_mode` to the current mode is a no-op.
        let same = engine.command(r#"{"cmd":"set_mode","mode":"vi"}"#);
        assert_eq!(same.changed, Some(false));
    }

    #[test]
    fn command_commit_and_reset() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "tooi");
        let result = engine.command(r#"{"cmd":"commit"}"#);
        assert_eq!(result.op, Op::Commit);
        assert_eq!(result.text, "tôi");
        assert_eq!(result.changed, Some(true));

        type_keys(&mut engine, "tooi");
        let result = engine.command(r#"{"cmd":"reset"}"#);
        assert_eq!(result.op, Op::None);
        assert_eq!(result.changed, Some(true));
        assert_eq!(result.word, "");
        assert!(!result.composing);
    }

    #[test]
    fn set_config_command_merges_without_losing_settings() {
        let mut engine = new_engine(TELEX_VI);
        let result =
            engine.command(r#"{"cmd":"set_config","config":{"tone_style":"traditional"}}"#);
        assert_eq!(result.op, Op::State);
        assert_eq!(result.changed, Some(true));
        assert_eq!(engine.config().tone_style, ToneStyle::Traditional);
        assert_eq!(engine.config().method, Method::Telex);
    }

    #[test]
    fn malformed_commands_are_harmless() {
        let mut engine = new_engine(TELEX_VI);
        for command in ["", "{", "[]", "null", r#"{"cmd":"nope"}"#, r#"{"cmd":42}"#] {
            let result = engine.command(command);
            assert_eq!(result.op, Op::State);
            assert_eq!(result.changed, Some(false));
            let value: Value = serde_json::from_str(&result.to_json(engine.config())).unwrap();
            assert_eq!(value["op"], "state");
        }
    }

    #[test]
    fn status_reports_config_and_composition() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "vieejt");
        let status = engine.status();
        assert_eq!(status.op, Op::State);
        assert_eq!(status.changed, Some(false));
        assert_eq!(status.word, "việt");
        assert_eq!(status.raw, "vieejt");
        assert!(status.composing);
    }

    #[test]
    fn set_config_returns_false_on_bad_json() {
        let mut engine = new_engine(TELEX_VI);
        assert!(!engine.set_config("{bad"));
        assert_eq!(engine.config(), &Config::from_json(TELEX_VI));
        assert!(engine.set_config(r#"{"method":"vni"}"#));
        assert_eq!(engine.config().method, Method::Vni);
    }

    #[test]
    fn external_set_config_keeps_composition() {
        let mut engine = new_engine(TELEX_VI);
        type_keys(&mut engine, "hoa");
        assert!(engine.set_config(r#"{"tone_style":"traditional"}"#));
        engine.feed_char('s', 0);
        assert_eq!(engine.shown, "hóa");
    }

    #[test]
    fn smart_undo_exception_only_applies_when_the_last_key_undoes() {
        // The undo key is the last processed key: keep the Vietnamese rendering
        // even though the untoned form is not a valid syllable. These are the
        // fixture-backed behaviours.
        assert_eq!(word_of(TELEX_VI, "aaa"), "aa");
        assert_eq!(word_of(TELEX_VI, "ddd"), "dd");
        assert_eq!(word_of(TELEX_VI, "ass"), "as");
        assert_eq!(word_of(TELEX_VI, "aww"), "aw");
        assert_eq!(word_of(TELEX_VI, "aasz"), "â");
        assert_eq!(word_of(TELEX_VI, "aaszz"), "a");
        assert_eq!(word_of(TELEX_VI, "vieejtz"), "viêt");
        assert_eq!(word_of(TELEX_VI, "dduwowngfz"), "đương");

        // An undo earlier in the word stops counting once ordinary keys follow,
        // so the smart fallback (literal keystrokes) takes over.
        assert_eq!(word_of(TELEX_VI, "aaab"), "aaab");
        assert_eq!(word_of(TELEX_VI, "assx"), "assx");
        assert_eq!(word_of(TELEX_VI, "dddd"), "dddd");
        assert_eq!(word_of(TELEX_VI, "awwa"), "awwa");

        // Smart off is unaffected: it always renders the Vietnamese form.
        assert_eq!(word_of(TELEX_VI_NO_SMART, "aaab"), "aab");
    }

    #[test]
    fn smart_undo_exception_does_not_mangle_english_words() {
        // A final key that repeats an earlier Telex operator used to exempt the
        // whole word from the smart fallback, so the operator was eaten as a
        // tone mark and a letter vanished (`deliveryor` -> `deliveyor`).
        for word in [
            "deliveryor",
            "deliveryorder",
            "order",
            "class",
            "staff",
            "boss",
            "address",
            "success",
            "less",
            "pass",
        ] {
            assert_eq!(word_of(TELEX_VI, word), word, "smart fallback for {word}");
        }
        // The narrow undo patterns must still render as Vietnamese.
        assert_eq!(word_of(TELEX_VI, "ass"), "as");
        assert_eq!(word_of(TELEX_VI, "aaa"), "aa");
        assert_eq!(word_of(TELEX_VI, "aasz"), "â");
        assert_eq!(word_of(TELEX_VI, "vieejtz"), "viêt");
    }

    #[test]
    fn smart_english_survives_an_earlier_operator_undo() {
        // Regression: `hardware` used to render `hădare` because a repeated `w`
        // (undo) exempted the whole word from the smart fallback.
        for word in [
            "hardware",
            "message",
            "business",
            "software",
            "directory",
            "different",
            "current",
            "commission",
        ] {
            assert_eq!(word_of(TELEX_VI, word), word, "smart fallback for {word}");
        }
    }

    #[test]
    fn boong_validates_without_the_undo_exception() {
        // `booong` ends with `g` (not an undo), so validity alone keeps the
        // Vietnamese rendering; the `oo` nucleus makes `boong` valid.
        assert_eq!(word_of(TELEX_VI, "booong"), "boong");
        assert!(crate::syllable::is_valid_or_prefix("boong"));
        assert!(crate::syllable::is_valid_or_prefix("xoong"));
    }

    #[test]
    fn open_u_o_words_are_reachable() {
        // `quơ`/`quở`: the `u` of a `qu` onset never takes the horn.
        assert_eq!(word_of(TELEX_VI, "quow"), "quơ");
        assert_eq!(word_of(TELEX_VI, "quowr"), "quở");
        assert_eq!(word_of(TELEX_VI, "quows"), "quớ");
        // Open `uơ` after another consonant onset is kept as well.
        assert_eq!(word_of(TELEX_VI, "thuowr"), "thuở");
        assert_eq!(word_of(TELEX_VI, "huow"), "huơ");
        // With a coda (or word-initially) the nucleus is `ươ` as before.
        assert_eq!(word_of(TELEX_VI, "uow"), "ươ");
        assert_eq!(word_of(TELEX_VI, "uowng"), "ương");
        assert_eq!(word_of(TELEX_VI, "uowngf"), "ường");
        assert_eq!(word_of(TELEX_VI, "thuowng"), "thương");
        assert_eq!(word_of(TELEX_VI, "quyeets"), "quyết");
        // VNI equivalents.
        assert_eq!(word_of(VNI_VI, "quo7"), "quơ");
        assert_eq!(word_of(VNI_VI, "quo73"), "quở");
        assert_eq!(word_of(VNI_VI, "thuo73"), "thuở");
        assert_eq!(word_of(VNI_VI, "u7o7"), "ươ");
    }

    #[test]
    fn xine_loanword_renders_with_circumflex() {
        assert_eq!(word_of(TELEX_VI, "xinee"), "xinê");
        assert_eq!(word_of(VNI_VI, "xine6"), "xinê");
        // Smart fallback still escapes ordinary English.
        assert_eq!(word_of(TELEX_VI, "hello"), "hello");
        assert_eq!(word_of(TELEX_VI, "google"), "google");
        assert_eq!(word_of(TELEX_VI, "looks"), "looks");
    }

    #[test]
    fn vni_undo_exception_also_requires_the_last_key() {
        // `a11` ends with an undoing digit → Vietnamese rendering kept.
        let mut engine = new_engine(VNI_VI);
        type_keys(&mut engine, "a11");
        assert_eq!(engine.shown, "a");
        // `a11n` appends a letter after the undo → validity decides (valid here).
        let mut engine = new_engine(VNI_VI);
        type_keys(&mut engine, "a11n");
        assert_eq!(engine.shown, "an");
    }

    #[test]
    fn result_json_escapes_special_characters_and_round_trips() {
        let cfg = Config::default();
        let result = KeyResult {
            op: Op::State,
            text: "a\"b\\c\nd\te\x01f\u{0008}\u{000c}\r".to_owned(),
            word: "tiếng \"việt\"".to_owned(),
            raw: "tieengs\\n".to_owned(),
            composing: true,
            consumed: false,
            changed: Some(true),
        };
        let json = result.to_json(&cfg);
        let value: Value = serde_json::from_str(&json).expect("valid escaped JSON");
        assert_eq!(value["op"], "state");
        assert_eq!(value["text"], result.text);
        assert_eq!(value["word"], result.word);
        assert_eq!(value["raw"], result.raw);
        assert_eq!(value["composing"], true);
        assert_eq!(value["consumed"], false);
        assert_eq!(value["changed"], true);
    }

    #[test]
    fn everyday_vietnamese_words_are_not_hijacked_by_english_fallback() {
        for (keys, expected) in [
            ("been", "bên"),
            ("teen", "tên"),
            ("treen", "trên"),
            ("chaus", "cháu"),
            ("quar", "quả"),
            ("hoon", "hôn"),
            ("khar", "khả"),
            ("char", "chả"),
            ("thar", "thả"),
            ("khir", "khỉ"),
            ("toon", "tôn"),
            ("ghee", "ghê"),
            ("phos", "phó"),
            ("phoo", "phô"),
            ("thow", "thơ"),
            ("thoo", "thô"),
            ("quis", "quí"),
            ("naos", "náo"),
            ("reen", "rên"),
            ("mootj", "một"),
            ("toots", "tốt"),
            ("teets", "tết"),
            ("keets", "kết"),
            ("meetj", "mệt"),
            ("bats", "bát"),
            ("hoof", "hồ"),
            ("boof", "bồ"),
            ("beef", "bề"),
            ("beer", "bể"),
            ("bees", "bế"),
            ("moon", "môn"),
            ("noon", "nôn"),
            ("hair", "hải"),
            ("lawn", "lăn"),
            ("sawn", "săn"),
            ("maam", "mâm"),
            ("caam", "câm"),
            ("mias", "mía"),
            ("vair", "vải"),
            ("coif", "còi"),
            ("neer", "nể"),
            ("neem", "nêm"),
            ("boor", "bổ"),
            ("benj", "bẹn"),
            ("tiar", "tỉa"),
            ("sair", "sải"),
        ] {
            assert_eq!(word_of(TELEX_VI, keys), expected, "keys={keys:?}");
        }
    }

    #[test]
    fn free_order_telex_and_horn_render_correctly() {
        for (keys, expected) in [
            ("toio", "tôi"),
            ("toiso", "tối"),
            ("uuw", "ưu"),
            ("cuuws", "cứu"),
            ("luuw", "lưu"),
            ("quawng", "quăng"),
            ("quawnj", "quặn"),
            ("ruouwj", "rượu"),
            ("huouw", "hươu"),
            ("dduwongf", "đường"),
            ("nguwoif", "người"),
            ("duocwdj", "được"),
            ("doiod", "đôi"),
            ("theme", "thêm"),
        ] {
            assert_eq!(word_of(TELEX_VI, keys), expected, "keys={keys:?}");
        }
    }
}
