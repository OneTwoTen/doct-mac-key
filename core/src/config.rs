//! Engine configuration and its JSON representation (SPEC §4).
//!
//! Configuration is parsed by hand from [`serde_json::Value`]: the crate
//! deliberately does not depend on `serde` derive. Unknown fields are ignored,
//! missing fields keep the previous value and malformed values are ignored, so
//! bad user JSON can never break the engine or panic.

use serde_json::{Map, Value};

/// Language mode (SPEC §5).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Vietnamese: keystrokes are composed into Vietnamese words.
    Vi,
    /// English: every printable keystroke is passed straight to the host.
    En,
}

impl Mode {
    /// The wire name used in JSON (`"vi"` / `"en"`).
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Vi => "vi",
            Mode::En => "en",
        }
    }

    /// Parse a wire name, returning `None` for anything unknown.
    pub fn parse(value: &str) -> Option<Mode> {
        match value {
            "vi" => Some(Mode::Vi),
            "en" => Some(Mode::En),
            _ => None,
        }
    }
}

/// Input method (operator set) used to interpret keystrokes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    /// Telex: `aa ee oo aw ow uw dd` quality keys, `s f r x j` tone keys, `z`.
    Telex,
    /// VNI: `1`..`5` tones, `6 7 8 9` quality keys, `0` removes marks.
    Vni,
}

impl Method {
    /// The wire name used in JSON (`"telex"` / `"vni"`).
    pub fn as_str(self) -> &'static str {
        match self {
            Method::Telex => "telex",
            Method::Vni => "vni",
        }
    }

    /// Parse a wire name, returning `None` for anything unknown.
    pub fn parse(value: &str) -> Option<Method> {
        match value {
            "telex" => Some(Method::Telex),
            "vni" => Some(Method::Vni),
            _ => None,
        }
    }
}

/// Tone-mark placement style (SPEC §5.3).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToneStyle {
    /// "New" style: `hoà`, `khoẻ`, `thuỷ` (tone on the second vowel of oa/oe/uy).
    Modern,
    /// "Old" style: `hòa`, `khỏe`, `thủy` (tone on the first vowel of oa/oe/uy).
    Traditional,
}

impl ToneStyle {
    /// The wire name used in JSON (`"modern"` / `"traditional"`).
    pub fn as_str(self) -> &'static str {
        match self {
            ToneStyle::Modern => "modern",
            ToneStyle::Traditional => "traditional",
        }
    }

    /// Parse a wire name, returning `None` for anything unknown.
    pub fn parse(value: &str) -> Option<ToneStyle> {
        match value {
            "modern" => Some(ToneStyle::Modern),
            "traditional" => Some(ToneStyle::Traditional),
            _ => None,
        }
    }
}

/// Complete engine configuration. Defaults are `vi`, Telex, modern tone
/// placement and smart English enabled.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    /// Language mode.
    pub mode: Mode,
    /// Operator set.
    pub method: Method,
    /// Tone placement style.
    pub tone_style: ToneStyle,
    /// Smart English fallback in Vietnamese mode.
    pub smart_english: bool,
}

impl Default for Config {
    fn default() -> Config {
        Config {
            mode: Mode::Vi,
            method: Method::Telex,
            tone_style: ToneStyle::Modern,
            smart_english: true,
        }
    }
}

impl Config {
    /// Build a config from optional JSON. Invalid JSON (or JSON that is not an
    /// object) yields the defaults.
    pub fn from_json(json: &str) -> Config {
        let mut cfg = Config::default();
        let _ = cfg.merge_json(json);
        cfg
    }

    /// Merge a JSON object into this config.
    ///
    /// Returns `false` if `json` is not valid JSON or is not an object, in
    /// which case the config is left untouched.
    pub fn merge_json(&mut self, json: &str) -> bool {
        match serde_json::from_str::<Value>(json) {
            Ok(Value::Object(object)) => {
                self.merge_object(&object);
                true
            }
            _ => false,
        }
    }

    /// Merge the recognised fields of a JSON object; unknown fields ignored.
    pub fn merge_object(&mut self, object: &Map<String, Value>) {
        if let Some(mode) = object
            .get("mode")
            .and_then(Value::as_str)
            .and_then(Mode::parse)
        {
            self.mode = mode;
        }
        if let Some(method) = object
            .get("method")
            .and_then(Value::as_str)
            .and_then(Method::parse)
        {
            self.method = method;
        }
        if let Some(style) = object
            .get("tone_style")
            .and_then(Value::as_str)
            .and_then(ToneStyle::parse)
        {
            self.tone_style = style;
        }
        // `smart_english` is the config-file spelling; `smart` is accepted too
        // because `{"cmd":"set_smart","smart":…}` uses the short form.
        if let Some(smart) = object.get("smart_english").and_then(Value::as_bool) {
            self.smart_english = smart;
        } else if let Some(smart) = object.get("smart").and_then(Value::as_bool) {
            self.smart_english = smart;
        }
    }

    /// Serialise the config as a JSON object (field order is not significant).
    pub fn to_json(&self) -> String {
        format!(
            "{{\"mode\":\"{}\",\"method\":\"{}\",\"tone_style\":\"{}\",\"smart_english\":{}}}",
            self.mode.as_str(),
            self.method.as_str(),
            self.tone_style.as_str(),
            self.smart_english
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_sane() {
        let cfg = Config::from_json("");
        assert_eq!(cfg, Config::default());
        assert_eq!(cfg.mode, Mode::Vi);
        assert_eq!(cfg.method, Method::Telex);
        assert_eq!(cfg.tone_style, ToneStyle::Modern);
        assert!(cfg.smart_english);
    }

    #[test]
    fn merges_known_fields_and_ignores_unknown() {
        let mut cfg = Config::default();
        assert!(cfg.merge_json(
            r#"{"mode":"en","method":"vni","tone_style":"traditional",
                "smart_english":false,"unknown":[1,2,3]}"#
        ));
        assert_eq!(cfg.mode, Mode::En);
        assert_eq!(cfg.method, Method::Vni);
        assert_eq!(cfg.tone_style, ToneStyle::Traditional);
        assert!(!cfg.smart_english);
    }

    #[test]
    fn bad_json_is_rejected_without_touching_config() {
        let mut cfg = Config::default();
        let before = cfg.clone();
        assert!(!cfg.merge_json("{not json"));
        assert!(!cfg.merge_json("null"));
        assert!(!cfg.merge_json("[1,2]"));
        assert_eq!(cfg, before);
    }

    #[test]
    fn invalid_values_keep_previous_setting() {
        let mut cfg = Config::default();
        cfg.merge_json(r#"{"mode":"xx","method":42,"tone_style":null}"#);
        assert_eq!(cfg, Config::default());
    }

    #[test]
    fn json_round_trip() {
        let cfg = Config {
            mode: Mode::En,
            method: Method::Vni,
            tone_style: ToneStyle::Traditional,
            smart_english: false,
        };
        let parsed = Config::from_json(&cfg.to_json());
        assert_eq!(parsed, cfg);
    }
}
