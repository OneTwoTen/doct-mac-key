//! Vietnamese syllable validity for the smart English fallback (SPEC §5.5).
//!
//! We deliberately do not write a phonology parser. Instead the crate embeds a
//! curated inventory of onsets, nuclei and finals, and directly matches any
//! `onset + nucleus + final` syllable **or any prefix of it** with zero heap
//! allocations or startup initialization cost. Being permissive is intentional:
//! a half-typed Vietnamese word must never flip to English.

/// Unaccented Vietnamese onsets; `""` is the vowel-initial case.
///
/// `gi` and `qu` are kept as onsets so `gia` / `qua` validate directly.
const ONSETS: &[&str] = &[
    "", "b", "c", "ch", "d", "g", "gh", "gi", "h", "k", "kh", "l", "m", "n", "ng", "ngh", "nh",
    "p", "ph", "qu", "r", "s", "t", "th", "tr", "v", "x",
];

/// Unaccented nuclei that may be followed by a final consonant coda.
///
/// Quality and tone marks are stripped first: `a/ă/â → a`, `e/ê → e`,
/// `o/ô/ơ → o`, `u/ư → u`, so `iê` and `yê` both become `ie`/`ye`.
/// `oo` only occurs in a handful of native/loan words (`boong`, `xoong`),
/// but those must validate, otherwise the smart fallback would escape them.
const CODA_NUCLEI: &[&str] = &[
    "a", "e", "i", "o", "u", "y", "ie", "oa", "oe", "oo", "ua", "ue", "uo", "uy", "ye", "uye",
];

/// Open-only diphthong/triphthong nuclei ending in a glide (`i/y/u/o`) that
/// cannot take a final consonant coda in Vietnamese.
const OPEN_ONLY_NUCLEI: &[&str] = &[
    "ai", "ao", "au", "ay", "eo", "eu", "ia", "iu", "oi", "ui", "uu", "ieu", "yeu", "oai", "oay",
    "oeo", "uoi", "uou", "uay", "uya", "uyu",
];

/// Vietnamese syllable finals (empty for open syllables).
const FINALS: &[&str] = &["", "c", "ch", "m", "n", "ng", "nh", "p", "t"];

/// Loanword spellings that do not fit `onset + nucleus + final` and are accepted
/// verbatim (SPEC §5.5 permits a curated inventory).
///
/// Kept deliberately tiny: adding a broad `ine` nucleus would also validate
/// English `line`/`mine`/`miner`/`liner` as Vietnamese prefixes and make the
/// smart fallback keep invalid Vietnamese renderings instead of the literal
/// keystrokes.
const EXTRA_VALID: &[&str] = &[
    "xine", // xinê (as in "ciné")
];

/// Whether `word` (unaccented, lowercase base letters) is a valid Vietnamese
/// syllable or a prefix of one.
///
/// An empty string is never valid; non-ASCII input is rejected.
pub fn is_valid_or_prefix(word: &str) -> bool {
    // Max syllable length across ONSETS (<=3) + CODA_NUCLEI (<=3) + FINALS (<=2) is 8.
    if word.is_empty() || word.len() > 8 || !word.bytes().all(|byte| byte.is_ascii_lowercase()) {
        return false;
    }
    if EXTRA_VALID.contains(&word) {
        return true;
    }
    let first_byte = word.as_bytes()[0];
    for &onset in ONSETS {
        if !onset.is_empty() && onset.as_bytes()[0] != first_byte {
            continue;
        }
        if onset.starts_with(word) {
            return true;
        }
        let Some(rest) = word.strip_prefix(onset) else {
            continue;
        };
        // Max nucleus (3) + max final (2) is 5.
        if rest.len() > 5 {
            continue;
        }
        let rest_first = rest.as_bytes()[0];
        if !matches!(rest_first, b'a' | b'e' | b'i' | b'o' | b'u' | b'y') {
            continue;
        }
        for &nucleus in CODA_NUCLEI {
            if nucleus.as_bytes()[0] != rest_first {
                continue;
            }
            if nucleus.starts_with(rest) {
                return true;
            }
            let Some(tail) = rest.strip_prefix(nucleus) else {
                continue;
            };
            if FINALS.iter().any(|&fin| fin.starts_with(tail)) {
                return true;
            }
        }
        for &nucleus in OPEN_ONLY_NUCLEI {
            if nucleus.as_bytes()[0] != rest_first {
                continue;
            }
            if nucleus.starts_with(rest) {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_common_vietnamese_words() {
        for word in [
            "viet", "tieng", "nguoi", "duong", "nguyen", "gieng", "toi", "chao", "cua", "meo",
            "biet", "nghia", "thuyen", "khuyu", "hoa", "khoe", "thuy", "quyen", "gia", "gi",
            "uong", "huou", "ruou", "khuya", "quang", "nghieng", "an", "em", "yeu", "boong",
            "xoong",
        ] {
            assert!(is_valid_or_prefix(word), "{word} should be Vietnamese");
        }
    }

    #[test]
    fn accepts_half_typed_prefixes() {
        for prefix in [
            "v", "vi", "vie", "ng", "ngh", "nghi", "nghie", "qu", "quy", "gi", "h",
        ] {
            assert!(
                is_valid_or_prefix(prefix),
                "{prefix} is a prefix of a Vietnamese syllable"
            );
        }
    }

    #[test]
    fn rejects_english_looking_words() {
        for word in [
            "hel", "hello", "look", "looks", "meet", "meeting", "goog", "google", "conim", "freh",
            "fresh", "world", "abc", "zebra", "",
        ] {
            assert!(!is_valid_or_prefix(word), "{word} should not be Vietnamese");
        }
    }

    #[test]
    fn accepts_oo_nucleus_words() {
        // `oo` is the only nucleus added for its loan/native words; it must not
        // open the door to English (`look`, `google`) — `oo` + `k` has no final.
        for word in ["boong", "xoong"] {
            assert!(is_valid_or_prefix(word), "{word} should be Vietnamese");
        }
        for word in ["look", "looks", "google", "goog", "boonk", "xoongk"] {
            assert!(!is_valid_or_prefix(word), "{word} should not be Vietnamese");
        }
    }

    #[test]
    fn accepts_loanword_xine_for_xine_circumflex() {
        // `xinee` (telex) / `xine6` (VNI) render `xinê`, whose untoned form is
        // `xine`; the curated entry must not leak into English words.
        assert!(is_valid_or_prefix("xine"));
        assert!(is_valid_or_prefix("xin"));
        for word in [
            "line", "mine", "nine", "miner", "liner", "diner", "hello", "google", "looks",
        ] {
            assert!(!is_valid_or_prefix(word), "{word} must not be Vietnamese");
        }
    }

    #[test]
    fn rejects_non_ascii_and_uppercase() {
        assert!(!is_valid_or_prefix("việt"));
        assert!(!is_valid_or_prefix("Viet"));
        assert!(!is_valid_or_prefix("123"));
    }

    #[test]
    fn matches_reference_prefix_table_exhaustively() {
        use std::collections::HashSet;

        let mut ref_set = HashSet::new();
        for onset in ONSETS {
            for nucleus in CODA_NUCLEI {
                for fin in FINALS {
                    let syllable = format!("{onset}{nucleus}{fin}");
                    for end in 1..=syllable.len() {
                        ref_set.insert(syllable[..end].to_owned());
                    }
                }
            }
            for nucleus in OPEN_ONLY_NUCLEI {
                let syllable = format!("{onset}{nucleus}");
                for end in 1..=syllable.len() {
                    ref_set.insert(syllable[..end].to_owned());
                }
            }
        }
        let expected = |w: &str| ref_set.contains(w) || EXTRA_VALID.contains(&w);

        for entry in &ref_set {
            assert!(is_valid_or_prefix(entry), "missing ref entry {entry}");
            for extra in ['a', 'k', 's', 'z'] {
                let mutated = format!("{entry}{extra}");
                assert_eq!(
                    is_valid_or_prefix(&mutated),
                    expected(&mutated),
                    "mismatch on mutated {mutated}"
                );
            }
        }

        let mut buf = [0u8; 3];
        for b0 in b'a'..=b'z' {
            buf[0] = b0;
            let s1 = std::str::from_utf8(&buf[..1]).unwrap();
            assert_eq!(is_valid_or_prefix(s1), expected(s1), "len 1: {s1}");
            for b1 in b'a'..=b'z' {
                buf[1] = b1;
                let s2 = std::str::from_utf8(&buf[..2]).unwrap();
                assert_eq!(is_valid_or_prefix(s2), expected(s2), "len 2: {s2}");
                for b2 in b'a'..=b'z' {
                    buf[2] = b2;
                    let s3 = std::str::from_utf8(&buf[..3]).unwrap();
                    assert_eq!(is_valid_or_prefix(s3), expected(s3), "len 3: {s3}");
                }
            }
        }

        for &word in crate::english_words::WORDS {
            assert_eq!(
                is_valid_or_prefix(word),
                expected(word),
                "english word mismatch: {word}"
            );
        }

        for bad in ["boing", "baic", "bain", "baon", "boit", "buit"] {
            assert!(!is_valid_or_prefix(bad), "{bad} must not take a final");
        }
        for good in [
            "viet", "nguyen", "quyet", "huynh", "xuan", "boong", "xoong", "nguoi", "ruou", "huou",
            "khuyu", "xine",
        ] {
            assert!(is_valid_or_prefix(good), "{good} must be valid");
        }

        assert!(!is_valid_or_prefix("nghiengaa"));
        assert!(!is_valid_or_prefix("abcdefghi"));
    }
}
