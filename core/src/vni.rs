//! VNI operator rules (SPEC §5.2).
//!
//! VNI uses digits as operators: `1`..`5` set the word-level tone, `6`/`7`/`8`/`9`
//! apply `â/ê/ô`, `ơ/ư`, `ă` and `đ`, and `0` removes marks. Digits that cannot
//! act (`a9`, `qu1`, `t6`) are *break characters*: the engine commits the word
//! and lets the host type the digit (this module only reports applicability).

use crate::config::ToneStyle;
use crate::letters::{has_quality, Letter, Quality, RawKey, Tone};
use crate::tone;

/// Replay `raw` as VNI keystrokes.
///
/// Only digits that were applicable when typed are present in `raw` (the engine
/// validates before appending), so the replay is total; a stray inapplicable
/// digit is simply ignored rather than panicking.
///
/// `last_key_undo` reports whether the **last** processed key was an
/// undo/removal (repeated operator, or a `0` that removed something), mirroring
/// Telex; it is re-computed for every key and consumed by the smart English
/// fallback exception (SPEC §5.5).
pub fn replay(
    raw: &[RawKey],
    style: ToneStyle,
    letters: &mut Vec<Letter>,
    tone: &mut Option<Tone>,
    last_key_undo: &mut bool,
) {
    let _ = style; // placement style is applied at render time.
    for key in raw {
        *last_key_undo = false;
        match key.ch {
            '1'..='5' => {
                let Some(next) = Tone::from_vni(key.ch) else {
                    continue;
                };
                if !tone::has_placeable_vowel(letters) {
                    continue;
                }
                if *tone == Some(next) {
                    *tone = None;
                    *last_key_undo = true;
                } else {
                    *tone = Some(next);
                }
            }
            '6' => *last_key_undo = toggle_quality(letters, &['a', 'e', 'o'], Quality::Circumflex),
            '7' => *last_key_undo = toggle_horn(letters),
            '8' => *last_key_undo = toggle_quality(letters, &['a'], Quality::Breve),
            '9' => *last_key_undo = toggle_quality(letters, &['d'], Quality::DStroke),
            '0' => {
                if tone.is_some() {
                    *tone = None;
                    *last_key_undo = true;
                } else if has_quality(letters) {
                    for letter in letters.iter_mut() {
                        letter.quality = None;
                    }
                    *last_key_undo = true;
                }
            }
            _ => {
                if key.ch.is_ascii_alphabetic() {
                    letters.push(Letter::new(key.ch, key.upper));
                }
            }
        }
    }
}

/// Apply or undo a quality mark on the nearest target letter going backwards.
///
/// Returns `true` when this key was an undo (the mark was already present).
fn toggle_quality(letters: &mut [Letter], targets: &[char], quality: Quality) -> bool {
    let Some(index) = find_target(letters, targets) else {
        return false;
    };
    match letters[index].quality {
        Some(existing) if existing == quality => {
            letters[index].quality = None;
            letters[index].locked = true;
            true
        }
        None => {
            letters[index].quality = Some(quality);
            false
        }
        Some(_) => false,
    }
}

fn find_horn_target(letters: &[Letter]) -> Option<usize> {
    let mut index = find_target(letters, &['o', 'u'])?;
    if letters[index].base == 'u' {
        if index >= 2
            && letters[index - 1].base == 'o'
            && letters[index - 2].base == 'u'
            && !letters[index - 1].locked
        {
            index -= 1;
        } else if index >= 1
            && letters[index - 1].base == 'u'
            && !letters[index - 1].locked
        {
            index -= 1;
        }
    }
    Some(index)
}

fn toggle_horn(letters: &mut [Letter]) -> bool {
    let Some(index) = find_horn_target(letters) else {
        return false;
    };
    match letters[index].quality {
        Some(Quality::Horn) => {
            letters[index].quality = None;
            letters[index].locked = true;
            true
        }
        None => {
            letters[index].quality = Some(Quality::Horn);
            false
        }
        Some(_) => false,
    }
}

fn find_target(letters: &[Letter], targets: &[char]) -> Option<usize> {
    letters
        .iter()
        .rposition(|letter| !letter.locked && targets.contains(&letter.base))
}

fn quality_allows(letters: &[Letter], index: usize, quality: Quality) -> bool {
    match letters[index].quality {
        None => true,
        Some(existing) => existing == quality,
    }
}

fn applicable_target(letters: &[Letter], targets: &[char], quality: Quality) -> bool {
    find_target(letters, targets).is_some_and(|index| quality_allows(letters, index, quality))
}

/// Whether `digit` can act as a VNI operator on the current word.
///
/// Used by the engine *before* appending the digit to the raw word; `false`
/// means the digit must be treated as a break character.
pub fn digit_applicable(
    letters: &[Letter],
    tone: Option<Tone>,
    digit: char,
    style: ToneStyle,
) -> bool {
    match digit {
        '1'..='5' => {
            let _ = style;
            tone::has_placeable_vowel(letters)
        }
        '6' => applicable_target(letters, &['a', 'e', 'o'], Quality::Circumflex),
        '7' => find_horn_target(letters)
            .is_some_and(|index| quality_allows(letters, index, Quality::Horn)),
        '8' => applicable_target(letters, &['a'], Quality::Breve),
        '9' => applicable_target(letters, &['d'], Quality::DStroke),
        '0' => tone.is_some() || has_quality(letters),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::letters::render;

    fn replay_word(raw: &str) -> String {
        let keys: Vec<RawKey> = raw
            .chars()
            .map(|ch| RawKey::new(ch.to_ascii_lowercase(), false))
            .collect();
        let mut letters = Vec::new();
        let mut tone = None;
        let mut last_key_undo = false;
        replay(
            &keys,
            ToneStyle::Modern,
            &mut letters,
            &mut tone,
            &mut last_key_undo,
        );
        crate::letters::normalize_u_o(&mut letters);
        match tone.and_then(|tone| tone::place(&letters, ToneStyle::Modern).map(|i| (tone, i))) {
            Some((tone, index)) => render(&letters, Some(tone), Some(index)),
            None => render(&letters, None, None),
        }
    }

    fn state(raw: &str) -> (Vec<Letter>, Option<Tone>) {
        let keys: Vec<RawKey> = raw
            .chars()
            .map(|ch| RawKey::new(ch.to_ascii_lowercase(), false))
            .collect();
        let mut letters = Vec::new();
        let mut tone = None;
        let mut last_key_undo = false;
        replay(
            &keys,
            ToneStyle::Modern,
            &mut letters,
            &mut tone,
            &mut last_key_undo,
        );
        (letters, tone)
    }

    #[test]
    fn tone_digits() {
        assert_eq!(replay_word("a1"), "á");
        assert_eq!(replay_word("a2"), "à");
        assert_eq!(replay_word("a3"), "ả");
        assert_eq!(replay_word("a4"), "ã");
        assert_eq!(replay_word("a5"), "ạ");
        assert_eq!(replay_word("vie65t"), "việt");
        assert_eq!(replay_word("hoa2ng"), "hoàng");
    }

    #[test]
    fn quality_digits() {
        assert_eq!(replay_word("a6"), "â");
        assert_eq!(replay_word("e6"), "ê");
        assert_eq!(replay_word("o6"), "ô");
        assert_eq!(replay_word("o7"), "ơ");
        assert_eq!(replay_word("u7"), "ư");
        assert_eq!(replay_word("a8"), "ă");
        assert_eq!(replay_word("d9"), "đ");
        assert_eq!(replay_word("a8n"), "ăn");
        assert_eq!(replay_word("u7o7"), "ươ");
        assert_eq!(replay_word("d9u7o7ng2"), "đường");
        assert_eq!(replay_word("ngu7o7i2"), "người");
    }

    fn undo_flag(raw: &str) -> bool {
        let keys: Vec<RawKey> = raw
            .chars()
            .map(|ch| RawKey::new(ch.to_ascii_lowercase(), false))
            .collect();
        let mut letters = Vec::new();
        let mut tone = None;
        let mut last_key_undo = false;
        replay(
            &keys,
            ToneStyle::Modern,
            &mut letters,
            &mut tone,
            &mut last_key_undo,
        );
        last_key_undo
    }

    #[test]
    fn last_key_undo_tracks_only_the_final_key() {
        assert!(undo_flag("a11"), "repeated tone digit undoes");
        assert!(!undo_flag("a1"), "a plain tone digit is not an undo");
        assert!(undo_flag("a10"), "0 removing the tone is a removal");
        assert!(undo_flag("a66"), "repeated quality digit undoes");
        assert!(!undo_flag("a6"), "a plain quality digit is not an undo");
        assert!(!undo_flag("a11n"), "an earlier undo is forgotten");
    }

    #[test]
    fn open_u_o_and_xine_cases() {
        assert_eq!(replay_word("quo7"), "quơ");
        assert_eq!(replay_word("quo73"), "quở");
        assert_eq!(replay_word("thuo73"), "thuở");
        assert_eq!(replay_word("u7o7"), "ươ");
        assert_eq!(replay_word("d9u7o7ng2"), "đường");
        assert_eq!(replay_word("xine6"), "xinê");
    }

    #[test]
    fn zero_removes_tone_then_quality() {
        assert_eq!(replay_word("a10"), "a");
        assert_eq!(replay_word("a60"), "a");
        // `a0`: nothing to remove, so `0` is not applicable.
        let (letters, tone) = state("a");
        assert!(!digit_applicable(&letters, tone, '0', ToneStyle::Modern));
        assert!(digit_applicable(
            &letters,
            Some(Tone::Acute),
            '0',
            ToneStyle::Modern
        ));
    }

    #[test]
    fn repeated_operator_undoes_and_consumes_digit() {
        assert_eq!(replay_word("a11"), "a");
        assert_eq!(replay_word("a66"), "a");
        assert_eq!(replay_word("a88"), "a");
        assert_eq!(replay_word("d99"), "d");
        let (_, tone) = state("a11");
        assert_eq!(tone, None);
    }

    #[test]
    fn applicability_mirrors_the_operators() {
        let (letters, tone) = state("bcf");
        for digit in ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'] {
            assert!(
                !digit_applicable(&letters, tone, digit, ToneStyle::Modern),
                "{digit} on bcf"
            );
        }
        let (letters, tone) = state("a");
        assert!(digit_applicable(&letters, tone, '1', ToneStyle::Modern));
        assert!(digit_applicable(&letters, tone, '6', ToneStyle::Modern));
        assert!(!digit_applicable(&letters, tone, '7', ToneStyle::Modern));
        assert!(!digit_applicable(&letters, tone, '9', ToneStyle::Modern));
        let (letters, tone) = state("qu");
        assert!(!digit_applicable(&letters, tone, '1', ToneStyle::Modern));
        let (letters, tone) = state("d");
        assert!(digit_applicable(&letters, tone, '9', ToneStyle::Modern));
    }

    #[test]
    fn uu_and_uou_horn_targets() {
        assert_eq!(replay_word("uu7"), "ưu");
        assert_eq!(replay_word("cuu71"), "cứu");
        assert_eq!(replay_word("luu7"), "lưu");
        assert_eq!(replay_word("ruou75"), "rượu");
        assert_eq!(replay_word("huou7"), "hươu");
    }
}
