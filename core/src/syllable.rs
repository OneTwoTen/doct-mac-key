//! Vietnamese syllable validity (SPEC §5.5).
//!
//! The crate embeds a curated inventory of onsets and rhymes and matches any
//! `onset + rhyme` syllable — or any prefix of one — with no heap allocation and
//! no startup cost. Being prefix-friendly is intentional: a half-typed Vietnamese
//! word must never flip to English (`viê` is not a syllable, but it is a prefix
//! of `viêng`, so it keeps its mark).
//!
//! The tables are **quality-aware**: `ê` and `e` are different letters, so a
//! shape like `tíe` is rejected (no rhyme `ie`) while `tiê` is accepted as the
//! prefix of `tiêng`. That is what makes Vietnamese-first priority usable
//! together with English typing (SPEC §5.5): an English word is only turned into
//! Vietnamese when its keystrokes really form a Vietnamese spelling.

/// Unaccented Vietnamese onsets; `""` is the vowel-initial case.
///
/// `gi` and `qu` are kept as onsets so `gia` / `qua` validate directly.
const ONSETS: &[&str] = &[
    "", "b", "c", "ch", "d", "g", "gh", "gi", "h", "k", "kh", "l", "m", "n", "ng", "ngh", "nh",
    "p", "ph", "qu", "r", "s", "t", "th", "tr", "v", "x",
];

/// Vietnamese rhymes (nucleus + optional coda), quality marks included.
///
/// Curated from a Vietnamese word list (every rhyme that occurs in a real
/// syllable) and pruned of entries that only came from foreign spellings
/// (`ie`, `eon`, `ynh`, …). `oo` covers the native/loan words `boong`, `xoong`.
const RHYMES: &[&str] = &[
    "a", "ac", "ach", "ai", "am", "an", "ang", "anh", "ao", "ap", "at", "au", "ay", "e", "ec",
    "em", "en", "eng", "eo", "ep", "et", "i", "ia", "ic", "ich", "im", "in", "inh", "ip", "it",
    "iu", "iêc", "iêm", "iên", "iêng", "iêp", "iêt", "iêu", "o", "oa", "oac", "oach", "oai",
    "oam", "oan", "oang", "oanh", "oao", "oap", "oat", "oay", "oc", "oe", "oem", "oen", "oeo",
    "oet", "oi", "om", "on", "ong", "ooc", "oong", "op", "ot", "oăc", "oăm", "oăn", "oăng",
    "oăt", "u", "ua", "uc", "ui", "um", "un", "ung", "up", "ut", "uy", "uya", "uych", "uyn",
    "uynh", "uyp", "uyt", "uyu", "uyên", "uyêt", "uân", "uât", "uây", "uê", "uêch", "uênh",
    "uôc", "uôi", "uôm", "uôn", "uông", "uôt", "uơ", "y", "yêm", "yên", "yêng", "yêt", "yêu",
    "â", "âc", "âm", "ân", "âng", "âp", "ât", "âu", "ây", "ê", "êc", "êch", "êm", "ên", "êng",
    "ênh", "êp", "êt", "êu", "ô", "ôc", "ôi", "ôm", "ôn", "ông", "ôp", "ôt", "ă", "ăc", "ăm",
    "ăn", "ăng", "ăp", "ăt", "ơ", "ơi", "ơm", "ơn", "ơp", "ơt", "ư", "ưa", "ưc", "ưi", "ưm",
    "ưn", "ưng", "ưt", "ưu", "ươc", "ươi", "ươm", "ươn", "ương", "ươp", "ươt", "ươu",
];
/// Rhyme prefixes that only exist while the rest of a word is still coming.
///
/// `ưo` is never a rhyme, but every `ngưo`/`đưo` keystroke before the next one
/// turns the pair into `ươ` (`người`, `được`): rejecting it would make the word
/// flicker back to raw keys mid-typing.
const TRANSIENT_RHYMES: &[&str] = &["ưo"];

/// Loanword spellings that do not fit `onset + rhyme` and are accepted verbatim
/// (SPEC §5.5 permits a curated inventory).
///
/// Deliberately tiny: a broad `ine` rhyme would also validate English
/// `line`/`mine`/`miner` as Vietnamese prefixes.
const EXTRA_SYLLABLES: &[&str] = &["xinê"];

/// Whether `word` (lowercase, untoned, quality marks included) is a valid
/// Vietnamese syllable or a prefix of one.
///
/// `đ` is accepted as the onset letter `d`. An empty string is never valid.
pub fn is_valid_or_prefix(word: &str) -> bool {
    // Longest syllable: onset (3) + rhyme (4) is 8 code points.
    let mut letters = [' '; 8];
    let mut len = 0usize;
    for ch in word.chars() {
        if len == letters.len() {
            return false;
        }
        letters[len] = ch;
        len += 1;
    }
    if len == 0 {
        return false;
    }
    let letters = &letters[..len];
    if EXTRA_SYLLABLES.iter().any(|syllable| eq(syllable, letters)) {
        return true;
    }
    // `đ` behaves like `d` for the onset; the rhyme half never contains it.
    let mut plain = [' '; 8];
    for (dst, src) in plain.iter_mut().zip(letters.iter()) {
        *dst = if *src == 'đ' { 'd' } else { *src };
    }
    let plain = &plain[..len];

    for onset in ONSETS {
        let onset_len = onset.chars().count();
        if plain.len() < onset_len {
            // The word is a prefix of the onset itself (`n` of `ng`).
            if starts_with(onset, plain) {
                return true;
            }
            continue;
        }
        if !chars_start_with(plain, onset) {
            continue;
        }
        let rhyme = &letters[onset_len..];
        if rhyme.is_empty() {
            // A bare onset (`đ`, `dd`): valid so the mark shows while typing.
            return true;
        }
        for &candidate in RHYMES.iter().chain(TRANSIENT_RHYMES) {
            if starts_with(candidate, rhyme) {
                return true;
            }
        }
    }
    false
}

/// Whether `chars` starts with every char of `text`.
fn chars_start_with(chars: &[char], text: &str) -> bool {
    let mut iter = chars.iter();
    for expected in text.chars() {
        match iter.next() {
            Some(&actual) if actual == expected => {}
            _ => return false,
        }
    }
    true
}

/// Whether `text` starts with every char of `prefix`.
fn starts_with(text: &str, prefix: &[char]) -> bool {
    let mut chars = text.chars();
    for &expected in prefix {
        match chars.next() {
            Some(actual) if actual == expected => {}
            _ => return false,
        }
    }
    true
}

/// Whether `text` is exactly the chars of `chars`.
fn eq(text: &str, chars: &[char]) -> bool {
    text.chars().count() == chars.len() && starts_with(text, chars)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_common_vietnamese_spellings() {
        // Unaccented, quality marks kept: the form the engine checks.
        for word in [
            "viêt",
            "tiêng",
            "ngươi",
            "đương",
            "nguyên",
            "giêng",
            "tô",
            "chao",
            "cua",
            "meo",
            "biêt",
            "nghia",
            "thuyên",
            "khuyu",
            "hoa",
            "khoe",
            "thuy",
            "quyên",
            "gia",
            "gi",
            "uông",
            "hươu",
            "rươu",
            "khuya",
            "quăng",
            "nghiêng",
            "ăn",
            "êm",
            "yêu",
            "boong",
            "xoong",
            "xinê",
        ] {
            assert!(is_valid_or_prefix(word), "{word} should be Vietnamese");
        }
    }

    #[test]
    fn accepts_half_typed_prefixes() {
        for prefix in [
            "v", "vi", "viê", "viêt", "ng", "ngh", "nghi", "nghê", "qu", "quy", "gi", "h", "tr",
            "trê", "đ", "đư", "ngư", "ngươ",
        ] {
            assert!(
                is_valid_or_prefix(prefix),
                "{prefix} is a prefix of a Vietnamese syllable"
            );
        }
        // `ưo` only exists while the next key turns it into `ươ` (`người`).
        assert!(is_valid_or_prefix("ưo"));
        assert!(is_valid_or_prefix("ngưo"));
    }

    #[test]
    fn rejects_english_looking_words() {
        for word in [
            "hel", "hello", "look", "looks", "meet", "meeting", "goog", "google", "conim",
            "freh", "fresh", "world", "abc", "zebra", "text", "two", "zw", "", "ie", "ye",
            "sưê", "tie", "sưe",
        ] {
            assert!(!is_valid_or_prefix(word), "{word} should not be Vietnamese");
        }
    }

    #[test]
    fn rejects_wrong_quality_marks() {
        // `iê` needs a coda: `tiê` is a prefix, but `tie` is not a spelling.
        assert!(is_valid_or_prefix("tiê"));
        assert!(!is_valid_or_prefix("tie"));
        // `ơ` and `o` are different rhymes.
        assert!(is_valid_or_prefix("thơ"));
        assert!(!is_valid_or_prefix("ưe"));
        assert!(is_valid_or_prefix("ưa"));
    }

    #[test]
    fn accepts_oo_nucleus_words() {
        // `oo` covers the native/loan words `boong`, `xoong`; it must not open
        // the door to English (`look`, `google`).
        for word in ["boong", "xoong"] {
            assert!(is_valid_or_prefix(word), "{word} should be Vietnamese");
        }
        for word in ["look", "looks", "google", "goog", "boonk", "xoongk"] {
            assert!(!is_valid_or_prefix(word), "{word} should not be Vietnamese");
        }
        // `lop`, `loc` are rhymes, `loo` is only a prefix of `loong`.
        assert!(is_valid_or_prefix("loo"));
        assert!(!is_valid_or_prefix("loob"));
    }

    #[test]
    fn accepts_loanword_xine_for_xine_circumflex() {
        // `xinee` (telex) / `xine6` (VNI) render `xinê`, whose untoned form is
        // `xinê`; the curated entry must not leak into English words.
        assert!(is_valid_or_prefix("xinê"));
        for word in [
            "line", "mine", "nine", "miner", "liner", "diner", "hello", "google", "looks",
        ] {
            assert!(!is_valid_or_prefix(word), "{word} must not be Vietnamese");
        }
    }

    #[test]
    fn rejects_uppercase_and_too_long_forms() {
        assert!(!is_valid_or_prefix("Viêt"));
        assert!(!is_valid_or_prefix("123"));
        assert!(!is_valid_or_prefix("nghiêngaa"));
    }

    /// Every full `onset + rhyme` form validates, and so does every prefix of
    /// it: half-typed words must never flip away from Vietnamese.
    #[test]
    fn every_table_entry_and_prefix_validates() {
        for onset in ONSETS {
            for rhyme in RHYMES.iter().chain(TRANSIENT_RHYMES) {
                let syllable = format!("{onset}{rhyme}");
                for (index, _) in syllable.char_indices() {
                    let prefix = &syllable[..index];
                    if !prefix.is_empty() {
                        assert!(is_valid_or_prefix(prefix), "prefix {prefix:?} of {syllable:?}");
                    }
                }
                assert!(is_valid_or_prefix(&syllable), "{syllable:?}");
            }
        }
    }

    #[test]
    fn rhyme_table_has_no_duplicates() {
        let mut seen = std::collections::HashSet::new();
        for rhyme in RHYMES.iter().chain(TRANSIENT_RHYMES) {
            assert!(seen.insert(*rhyme), "duplicate rhyme {rhyme:?}");
        }
    }
}
