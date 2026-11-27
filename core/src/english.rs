//! English words whose literal keystrokes look like Vietnamese Telex
//! (SPEC §5.5, the "literal fallback").
//!
//! Telex eats operator letters: the `s` of `best` becomes `sắc`, the `o`+`w` of
//! `down` becomes `ơ`. When the same keystrokes also spell a Vietnamese
//! syllable, spelling alone cannot tell the two readings apart, so the engine
//! needs a list. This is a list of *collisions*, not a dictionary.
//!
//! # Curation policy
//!
//! A word belongs here only if its raw keystrokes would otherwise be turned into
//! a **different** rendering *and* that Vietnamese reading is **not a common
//! Vietnamese word**. When both readings are common the Vietnamese one wins —
//! the project's Vietnamese-first rule — so words such as `these` (`thế`),
//! `there` (`thể`), `been` (`bên`), `queen` (`quên`), `chair` (`chải`), `cats`
//! (`cát`), `hats` (`hát`), `sets` (`sét`), `songs` (`sóng`), `sense` (`sến`),
//! `reset` (`rết`), `hair` (`hải`), `theme` (`thêm`) are deliberately **absent**
//! below: typing them stays Vietnamese. Use the alternative operator order
//! (`thees`, `theer`, `theem`, `reets`) or English mode (`⌃⌥V`) instead.
//!
//! Seeds: the 10 000 most frequent English words plus common short collisions
//! whose Vietnamese reading is not a common word (`of`, `is`, `or`, `if`,
//! `air`, `box`, `was`, `how`, `now`, `see`, …). Short words that *are* common
//! Vietnamese (`as` → `á`, `us` → `ú`, `at` → `át`, `it` → `ít`) are never
//! listed.
//!
//! To extend the list, add the lowercase word in sorted order and a fixture row
//! in `core/tests/fixtures/smart.tsv`.

/// Shortest word considered; shorter words are always Telex.
pub const MIN_WORD_LEN: usize = 2;
/// Longest word considered; longer keystroke runs are never a single syllable.
pub const MAX_WORD_LEN: usize = 16;

/// Sorted, lowercase English words that must keep their literal keystrokes.
pub const WORDS: &[&str] = &[
    "air", "axis", "bars", "boats",
    "boom", "boot", "box", "boxes",
    "busy", "buys", "cars", "casa",
    "chairs", "cheers", "choir", "chose",
    "chosen", "congo", "cons", "core",
    "data", "dawn", "days", "deep",
    "deer", "def", "dense", "dir",
    "docs", "does", "donor", "donors",
    "doom", "door", "doors", "dos",
    "dose", "down", "gaps", "gary",
    "gas", "gene", "genes", "genre",
    "genres", "gets", "ghana", "goes",
    "gore", "goto", "guns", "guys",
    "has", "her", "here", "hero",
    "his", "honor", "honors", "horse",
    "hose", "how", "if", "inf",
    "is", "keen", "keep", "keeps",
    "kits", "laura", "law", "laws",
    "lets", "lips", "lisa", "loans",
    "loop", "lose", "lows", "luis",
    "major", "manga", "maps", "mars",
    "mary", "meet", "meets", "mens",
    "mere", "meters", "metres", "mins",
    "mix", "moms", "more", "nasa",
    "nor", "nose", "now", "of",
    "off", "oops", "or", "pair",
    "pairs", "para", "paris", "paso",
    "pays", "peer", "peers", "pens",
    "per", "pete", "pets", "photo",
    "phys", "pics", "piece", "pieces",
    "pins", "poems", "poor", "pos",
    "pose", "puts", "queens", "queue",
    "raw", "reef", "ref", "refers",
    "refuse", "res", "roof", "room",
    "rooms", "root", "rosa", "rose",
    "row", "rows", "runs", "sara",
    "saw", "says", "see", "seem",
    "seems", "sees", "sims", "sofa",
    "sons", "soon", "surf", "sys",
    "taxi", "teens", "tense", "tex",
    "thats", "this", "thongs", "those",
    "tips", "tons", "tops", "town",
    "towns", "tree", "trees", "trips",
    "troops", "usa", "usr", "virus",
    "war", "wars", "was", "wax",
    "won", "wow", "wrong", "xanax",
    "xerox",
];

/// Whether `word` (lowercase literal keystrokes) is a known English collision.
///
/// Binary search over [`WORDS`]; `word` must already be lowercase.
pub fn is_english(word: &str) -> bool {
    if !(MIN_WORD_LEN..=MAX_WORD_LEN).contains(&word.len()) {
        return false;
    }
    WORDS.binary_search(&word).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_whole_word_collisions() {
        // These keys spell a valid Vietnamese syllable *and* a common English
        // word whose Vietnamese reading is obscure; the list keeps them English.
        // (`best`/`test`/`last`/`most` never need this list: the Telex cluster
        // rule already gives their tone key back.)
        for word in [
            "this", "those", "does", "goes", "door", "down", "says", "wrong", "photo", "here",
            "hero", "virus", "roof", "docs", "was", "how", "now", "see", "his", "box", "air",
            "data", "tense", "dense",
        ] {
            assert!(is_english(word), "{word} should be English");
        }
    }

    #[test]
    fn leaves_common_vietnamese_spellings_to_vietnamese() {
        for word in [
            "these", "there", "been", "queen", "chair", "char", "cats", "hats", "sets", "mats",
            "lots", "songs", "sense", "seen", "reset", "hair", "theme", "themes", "photos",
            "teen", "thus", "moon", "noon", "bus", "tax", "sir", "as", "us", "at", "its",
        ] {
            assert!(!is_english(word), "{word} must not be English");
        }
    }

    #[test]
    fn list_is_sorted_lowercase_and_within_bounds() {
        assert!(WORDS.windows(2).all(|pair| pair[0] < pair[1]), "WORDS must be sorted");
        for &word in WORDS {
            assert_eq!(word, word.to_ascii_lowercase(), "not lowercase: {word}");
            assert!(
                (MIN_WORD_LEN..=MAX_WORD_LEN).contains(&word.len()),
                "out of bounds: {word}"
            );
            assert!(word.bytes().all(|b| b.is_ascii_lowercase()), "bad byte: {word}");
        }
    }

    #[test]
    fn rejects_uncollided_and_non_ascii_input() {
        for word in ["", "vieejt", "tieengs", "hello", "meeting", "google", "x", "ñ"] {
            assert!(!is_english(word), "{word} should not be English");
        }
    }
}
