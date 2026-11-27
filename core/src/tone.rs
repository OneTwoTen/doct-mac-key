//! Tone-mark placement (SPEC §5.3).
//!
//! Placement works on the rendered *letters* after quality marks have been
//! applied and before tone marks are drawn. Two subtleties:
//!
//! * the `u` of a leading `qu` and the `i` of a leading `gi` (when another
//!   vowel follows) belong to the onset and are not tone candidates;
//! * a word with several disjoint vowel runs (only possible for keystrokes that
//!   are not a valid Vietnamese word, e.g. Telex `confirm`) places the tone in
//!   the **last** contiguous run, which keeps replay deterministic.
//!
//! The engine keeps a single word-level tone value (SPEC §5.1/§5.3); the index
//! returned here is re-derived from the current letters on every render, so a
//! tone key typed early still lands on the right letter once the word grows
//! (e.g. `hoa` + tone with modern style lands on `a`).

use crate::config::ToneStyle;
use crate::letters::{is_vowel, Letter};

/// Indices of letters that may receive a tone mark, after removing onset
/// letters (`qu`, `gi`).
pub fn eligible_vowel_indices(letters: &[Letter]) -> Vec<usize> {
    let onset_skip = onset_skip_index(letters);
    letters
        .iter()
        .enumerate()
        .filter(|(index, letter)| letter.is_vowel() && Some(*index) != onset_skip)
        .map(|(index, _)| index)
        .collect()
}

/// The index of the leading `u` of `qu` / `i` of `gi`, if it is an onset.
fn onset_skip_index(letters: &[Letter]) -> Option<usize> {
    if letters.len() < 2 {
        return None;
    }
    let first = letters[0].base;
    let second = letters[1].base;
    if first == 'q' && second == 'u' {
        return Some(1);
    }
    if first == 'g' && second == 'i' && letters[2..].iter().any(|letter| letter.is_vowel()) {
        return Some(1);
    }
    None
}

/// Choose the letter index that receives the tone mark, or `None` when the
/// word has no placeable vowel (e.g. `qu`, `ng`, an empty word).
pub fn place(letters: &[Letter], style: ToneStyle) -> Option<usize> {
    let onset_skip = onset_skip_index(letters);
    let is_eligible = |index: usize| letters[index].is_vowel() && Some(index) != onset_skip;

    let run_end = (0..letters.len()).rev().find(|&index| is_eligible(index))?;
    let mut run_start = run_end;
    while run_start > 0 && is_eligible(run_start - 1) {
        run_start -= 1;
    }

    // Rule 2: a quality-marked nucleus takes the tone on its last marked vowel.
    if let Some(index) = (run_start..=run_end)
        .rev()
        .find(|&index| letters[index].quality.is_some())
    {
        return Some(index);
    }

    let run_len = run_end - run_start + 1;
    match run_len {
        1 => Some(run_start),
        2 => {
            let first = run_start;
            let second = run_end;
            let closed = letters[second + 1..]
                .iter()
                .any(|letter| !is_vowel(letter.base));
            if closed {
                // Rule 3: two vowels + coda → the second vowel.
                Some(second)
            } else {
                let nucleus = (letters[first].base, letters[second].base);
                let glide = matches!(nucleus, ('o', 'a') | ('o', 'e') | ('u', 'y'));
                if glide && style == ToneStyle::Modern {
                    Some(second)
                } else {
                    Some(first)
                }
            }
        }
        // Rule 4: three (or more) vowels → the middle one.
        _ => Some(run_start + run_len / 2),
    }
}

/// Convenience wrapper: does the word have a vowel that can take a tone?
pub fn has_placeable_vowel(letters: &[Letter]) -> bool {
    let onset_skip = onset_skip_index(letters);
    letters
        .iter()
        .enumerate()
        .any(|(index, letter)| letter.is_vowel() && Some(index) != onset_skip)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::letters::Quality;

    /// Build a letter list from plain text, with `^` marking circumflex and
    /// `+` breve / horn substitutions written literally where needed.
    fn letters(text: &str) -> Vec<Letter> {
        text.chars()
            .map(|ch| {
                let (base, quality) = match ch {
                    'â' => ('a', Some(Quality::Circumflex)),
                    'ă' => ('a', Some(Quality::Breve)),
                    'ê' => ('e', Some(Quality::Circumflex)),
                    'ô' => ('o', Some(Quality::Circumflex)),
                    'ơ' => ('o', Some(Quality::Horn)),
                    'ư' => ('u', Some(Quality::Horn)),
                    'đ' => ('d', Some(Quality::DStroke)),
                    other => (other, None),
                };
                let mut letter = Letter::new(base, false);
                letter.quality = quality;
                letter
            })
            .collect()
    }

    fn place_in(text: &str, style: ToneStyle) -> Option<usize> {
        place(&letters(text), style)
    }

    #[test]
    fn single_vowel() {
        assert_eq!(place_in("a", ToneStyle::Modern), Some(0));
        assert_eq!(place_in("tet", ToneStyle::Modern), Some(1));
        assert_eq!(place_in("xin", ToneStyle::Modern), Some(1));
    }

    #[test]
    fn closed_two_vowel_nucleus_takes_second() {
        assert_eq!(place_in("hoang", ToneStyle::Modern), Some(2));
        assert_eq!(place_in("oanh", ToneStyle::Modern), Some(1));
        assert_eq!(place_in("thuyen", ToneStyle::Modern), Some(3));
    }

    #[test]
    fn open_two_vowel_nucleus_style_matters_for_oa_oe_uy() {
        assert_eq!(place_in("hoa", ToneStyle::Modern), Some(2));
        assert_eq!(place_in("hoa", ToneStyle::Traditional), Some(1));
        assert_eq!(place_in("khoe", ToneStyle::Modern), Some(3));
        assert_eq!(place_in("khoe", ToneStyle::Traditional), Some(2));
        assert_eq!(place_in("thuy", ToneStyle::Modern), Some(3));
        assert_eq!(place_in("thuy", ToneStyle::Traditional), Some(2));
    }

    #[test]
    fn open_two_vowel_nucleus_style_ignored_otherwise() {
        assert_eq!(place_in("chao", ToneStyle::Modern), Some(2));
        assert_eq!(place_in("chao", ToneStyle::Traditional), Some(2));
        assert_eq!(place_in("meo", ToneStyle::Traditional), Some(1));
        assert_eq!(place_in("cua", ToneStyle::Traditional), Some(1));
        assert_eq!(place_in("bia", ToneStyle::Traditional), Some(1));
    }

    #[test]
    fn triphthong_takes_middle() {
        assert_eq!(place_in("oai", ToneStyle::Modern), Some(1));
        assert_eq!(place_in("ngoai", ToneStyle::Modern), Some(3));
        assert_eq!(place_in("khuyu", ToneStyle::Modern), Some(3));
        assert_eq!(place_in("chuyen", ToneStyle::Modern), Some(3));
    }

    #[test]
    fn quality_marked_nucleus_takes_last_marked_vowel() {
        assert_eq!(place_in("tiêng", ToneStyle::Modern), Some(2));
        assert_eq!(place_in("đươc", ToneStyle::Modern), Some(2));
        assert_eq!(place_in("ngươi", ToneStyle::Modern), Some(3));
        assert_eq!(place_in("muôn", ToneStyle::Modern), Some(2));
    }

    #[test]
    fn qu_and_gi_onsets_are_not_candidates() {
        assert_eq!(place_in("qua", ToneStyle::Modern), Some(2));
        assert_eq!(place_in("quy", ToneStyle::Modern), Some(2));
        assert_eq!(place_in("quyen", ToneStyle::Modern), Some(3));
        assert_eq!(place_in("gia", ToneStyle::Modern), Some(2));
        assert_eq!(place_in("giai", ToneStyle::Modern), Some(2));
        assert_eq!(place_in("giu", ToneStyle::Modern), Some(2));
        // `gi` alone keeps its `i` as the only vowel.
        assert_eq!(place_in("gi", ToneStyle::Modern), Some(1));
    }

    #[test]
    fn no_vowel_means_no_placement() {
        assert_eq!(place_in("", ToneStyle::Modern), None);
        assert_eq!(place_in("ng", ToneStyle::Modern), None);
        assert_eq!(place_in("qu", ToneStyle::Modern), None);
        assert_eq!(place_in("ddd", ToneStyle::Modern), None);
    }

    #[test]
    fn disjoint_vowel_runs_use_the_last_run() {
        // Telex `confirm` replays as c,o,n,f,i,r,m: huyền lands on `o`, then
        // hỏi lands on `i` because the last run is `i`.
        assert_eq!(place_in("conim", ToneStyle::Modern), Some(3));
    }

    #[test]
    fn placeable_vowel_detection() {
        assert!(has_placeable_vowel(&letters("a")));
        assert!(has_placeable_vowel(&letters("gi")));
        assert!(!has_placeable_vowel(&letters("qu")));
        assert!(!has_placeable_vowel(&letters("ng")));
        assert!(!has_placeable_vowel(&letters("")));
        assert_eq!(
            eligible_vowel_indices(&letters("nguoi")),
            vec![2, 3, 4],
            "all vowels are candidates in a plain word"
        );
        assert_eq!(
            eligible_vowel_indices(&letters("quyen")),
            vec![2, 3],
            "the u of qu belongs to the onset"
        );
    }
}
