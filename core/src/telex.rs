//! Telex operator rules (SPEC §5.2).
//!
//! Replaying a raw key sequence left to right reconstructs the letter list and
//! the word-level tone. Every keystroke in the word goes through this function;
//! the engine never mutates rendered text incrementally, it re-renders.

use crate::config::ToneStyle;
use crate::letters::{has_quality, Letter, Quality, RawKey, Tone};
use crate::tone;

/// Replay `raw` as Telex keystrokes.
///
/// * `letters` is the output letter list (quality marks included, no tones).
/// * `tone` is the output word-level tone.
/// * `last_key_undo` reports whether the **last** processed key was an
///   undo/removal: a repeated quality/tone operator that removed a mark, or a
///   `z` that removed a tone/quality mark. It is re-computed for every key, so
///   an undo earlier in the word does not leak into the final value; the smart
///   English fallback uses it as its narrow exception (SPEC §5.5).
pub fn replay(
    raw: &[RawKey],
    style: ToneStyle,
    letters: &mut Vec<Letter>,
    tone: &mut Option<Tone>,
    last_key_undo: &mut bool,
) {
    let _ = style; // Telex placement uses the style at render time, not here.
    for key in raw {
        *last_key_undo = false;
        let upper = key.upper;
        match key.ch {
            'a' | 'e' | 'o' => apply_circumflex(letters, key.ch, upper, last_key_undo),
            'd' => apply_dstroke(letters, upper, last_key_undo),
            'w' => apply_horn_after_ua(letters, upper, last_key_undo),
            'z' => *last_key_undo = remove_marks(letters, tone, upper),
            _ => {
                if let Some(next) = Tone::from_telex(key.ch) {
                    // Tone keys only act when there is a vowel that can carry
                    // the mark; otherwise (`s` of `sang`, the `u` of `qu`) the
                    // key stays a literal letter.
                    if tone::has_placeable_vowel(letters) {
                        if *tone == Some(next) {
                            // Same tone again: remove it and emit the literal key.
                            *tone = None;
                            letters.push(Letter::literal(key.ch, upper));
                            *last_key_undo = true;
                        } else {
                            *tone = Some(next);
                        }
                    } else {
                        letters.push(Letter::new(key.ch, upper));
                    }
                } else if key.ch.is_ascii_alphabetic() {
                    letters.push(Letter::new(key.ch, upper));
                }
                // Digits and punctuation never enter a Telex raw word.
            }
        }
    }
}

/// `aa` / `ee` / `oo`: apply â / ê / ô to the nearest previous matching letter.
fn apply_circumflex(letters: &mut Vec<Letter>, base: char, upper: bool, undone: &mut bool) {
    let target = letters
        .iter()
        .rposition(|letter| !letter.locked && letter.base == base);
    let Some(index) = target else {
        letters.push(Letter::new(base, upper));
        return;
    };
    match letters[index].quality {
        Some(Quality::Circumflex) => {
            // Re-applying the same mark: undo it and emit the literal key.
            letters[index].quality = None;
            letters[index].locked = true;
            letters.push(Letter::literal(base, upper));
            *undone = true;
        }
        None => letters[index].quality = Some(Quality::Circumflex),
        Some(_) => letters.push(Letter::new(base, upper)),
    }
}

/// `dd`: merge into đ when the word begins with `d`.
fn apply_dstroke(letters: &mut Vec<Letter>, upper: bool, undone: &mut bool) {
    if letters.is_empty() || letters[0].base != 'd' || letters[0].locked {
        letters.push(Letter::new('d', upper));
        return;
    }
    match letters[0].quality {
        Some(Quality::DStroke) => {
            letters[0].quality = None;
            letters[0].locked = true;
            letters.push(Letter::literal('d', upper));
            *undone = true;
        }
        None => letters[0].quality = Some(Quality::DStroke),
        Some(_) => letters.push(Letter::new('d', upper)),
    }
}

/// `w` after `ua` gives `ư` + `a`, so `suawr` and `suwra` both render `sửa`.
/// Excludes `qua` (`quaw -> quă`) and undoes `ư` when pressed again (`suaww -> suaw`).
/// Every other `w` keeps the normal nearest-vowel horn rule.
fn apply_horn_after_ua(letters: &mut Vec<Letter>, upper: bool, undone: &mut bool) {
    let n = letters.len();
    if n >= 2
        && !(n == 3 && letters[0].base == 'q')
        && letters[n - 2].base == 'u'
        && !letters[n - 2].locked
        && letters[n - 1].base == 'a'
        && letters[n - 1].quality.is_none()
        && !letters[n - 1].locked
    {
        match letters[n - 2].quality {
            None => {
                letters[n - 2].quality = Some(Quality::Horn);
                return;
            }
            Some(Quality::Horn) => {
                letters[n - 2].quality = None;
                letters[n - 2].locked = true;
                letters.push(Letter::literal('w', upper));
                *undone = true;
                return;
            }
            Some(_) => {}
        }
    }
    apply_horn(letters, upper, undone);
}

/// `aw` / `ow` / `uw`: apply ă / ơ / ư to the nearest previous `a` / `o` / `u`.
///
/// A lone `w` at the very start of a word produces `ư`; in every other case
/// where no target exists it is a literal `w`.
fn apply_horn(letters: &mut Vec<Letter>, upper: bool, undone: &mut bool) {
    let target = letters
        .iter()
        .rposition(|letter| !letter.locked && matches!(letter.base, 'a' | 'o' | 'u'));
    let Some(mut index) = target else {
        if letters.is_empty() {
            let mut letter = Letter::new('u', upper);
            letter.quality = Some(Quality::Horn);
            letters.push(letter);
        } else {
            letters.push(Letter::new('w', upper));
        }
        return;
    };
    // In `uou` (`rượu`, `hươu`, `bướu`), `w` modifies `o` (then `normalize_u_o` gives `ươu`).
    // In `uu` (`ưu`, `cứu`, `lưu`, `hữu`), `w` modifies the first `u` to produce `ưu`.
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
    let wanted = if letters[index].base == 'a' {
        Quality::Breve
    } else {
        Quality::Horn
    };
    match letters[index].quality {
        Some(quality) if quality == wanted => {
            letters[index].quality = None;
            letters[index].locked = true;
            letters.push(Letter::literal('w', upper));
            *undone = true;
        }
        None => letters[index].quality = Some(wanted),
        Some(_) => letters.push(Letter::new('w', upper)),
    }
}

/// `z`: remove the tone first, then every quality mark; otherwise literal `z`.
///
/// Returns `true` when a mark was actually removed (the key was a removal, which
/// the smart English fallback treats as an undo).
fn remove_marks(letters: &mut Vec<Letter>, tone: &mut Option<Tone>, upper: bool) -> bool {
    if tone.is_some() {
        *tone = None;
        return true;
    }
    if has_quality(letters) {
        for letter in letters.iter_mut() {
            letter.quality = None;
        }
        return true;
    }
    letters.push(Letter::new('z', upper));
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::letters::{bases, render};

    fn letters_of(raw: &str) -> (Vec<Letter>, Option<Tone>, bool) {
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
        (letters, tone, last_key_undo)
    }

    fn word_of(raw: &str) -> String {
        let (mut letters, tone, _) = letters_of(raw);
        crate::letters::normalize_u_o(&mut letters);
        match tone.and_then(|tone| tone::place(&letters, ToneStyle::Modern).map(|i| (tone, i))) {
            Some((tone, index)) => render(&letters, Some(tone), Some(index)),
            None => render(&letters, None, None),
        }
    }

    #[test]
    fn quality_operators() {
        for (keys, expected) in [
            ("aa", "â"),
            ("ee", "ê"),
            ("oo", "ô"),
            ("aw", "ă"),
            ("ow", "ơ"),
            ("uw", "ư"),
            ("dd", "đ"),
            ("w", "ư"),
            ("uow", "ươ"),
            ("uwow", "ươ"),
            ("ddau", "đau"),
            ("aas", "ấ"),
        ] {
            assert_eq!(word_of(keys), expected, "keys {keys:?}");
        }
    }

    #[test]
    fn w_targets_nearest_previous_a_o_u_through_consonants() {
        assert_eq!(word_of("banw"), "băn");
        assert_eq!(word_of("tw"), "tw");
        assert_eq!(word_of("iew"), "iew");
    }

    #[test]
    fn w_after_ua_gives_u_horn_plus_a() {
        // Both spellings render `sửa`; `suawr` no longer gives `suẳ`.
        assert_eq!(word_of("suawr"), "sửa");
        assert_eq!(word_of("suwra"), "sửa");
        assert_eq!(word_of("nuawr"), "nửa");
        assert_eq!(word_of("uaw"), "ưa");
        // Other `w` uses keep the normal nearest-vowel rule.
        assert_eq!(word_of("hoawcj"), "hoặc");
    }

    #[test]
    fn repeated_quality_operator_undoes_and_emits_literal() {
        assert_eq!(word_of("aaa"), "aa");
        assert_eq!(word_of("ddd"), "dd");
        assert_eq!(word_of("aww"), "aw");
        assert_eq!(word_of("booong"), "boong");
        assert!(letters_of("aaa").2);
        assert!(!letters_of("aa").2);
    }

    #[test]
    fn dd_only_merges_at_word_start() {
        assert_eq!(word_of("dd"), "đ");
        assert_eq!(word_of("add"), "add");
        assert_eq!(word_of("ddd"), "dd");
        assert_eq!(word_of("did"), "đi");
        assert_eq!(word_of("duongd"), "đuong");
        assert_eq!(word_of("duwongd"), "đương");
        assert_eq!(word_of("doiod"), "đôi");
        assert_eq!(word_of("daxd"), "đã");
    }

    #[test]
    fn free_order_circumflex_and_horn_sequences() {
        assert_eq!(word_of("toio"), "tôi");
        assert_eq!(word_of("toiso"), "tối");
        assert_eq!(word_of("toios"), "tối");
        assert_eq!(word_of("vietej"), "việt");
        assert_eq!(word_of("vietje"), "việt");
        assert_eq!(word_of("tienges"), "tiếng");
        assert_eq!(word_of("khongo"), "không");
        assert_eq!(word_of("motoj"), "một");
        assert_eq!(word_of("canaf"), "cần");
        assert_eq!(word_of("loixo"), "lỗi");
        assert_eq!(word_of("caya"), "cây");
        assert_eq!(word_of("giengse"), "giếng");

        assert_eq!(word_of("uuw"), "ưu");
        assert_eq!(word_of("cuuws"), "cứu");
        assert_eq!(word_of("luuw"), "lưu");
        assert_eq!(word_of("huuwx"), "hữu");

        assert_eq!(word_of("quaw"), "quă");
        assert_eq!(word_of("quawng"), "quăng");
        assert_eq!(word_of("quawnj"), "quặn");
        assert_eq!(word_of("suaww"), "suaw");

        assert_eq!(word_of("ruouwj"), "rượu");
        assert_eq!(word_of("huouw"), "hươu");
    }

    #[test]
    fn last_key_undo_tracks_only_the_final_key() {
        assert!(letters_of("aaa").2, "repeated aa undoes");
        assert!(!letters_of("aa").2, "plain merge is not an undo");
        assert!(letters_of("aasz").2, "z removing the tone is a removal");
        assert!(letters_of("aaszz").2, "z removing the quality is a removal");
        assert!(!letters_of("az").2, "literal z is not a removal");
        assert!(!letters_of("aaab").2, "an earlier undo is forgotten");
        assert!(!letters_of("as").2, "a plain tone is not an undo");
    }

    #[test]
    fn tone_keys_need_a_placeable_vowel() {
        assert_eq!(word_of("as"), "á");
        assert_eq!(word_of("sang"), "sang");
        assert_eq!(word_of("quas"), "quá");
        assert_eq!(word_of("qus"), "qus");
        assert_eq!(word_of("gif"), "gì");
    }

    #[test]
    fn repeated_tone_operator_undoes_and_emits_literal() {
        assert_eq!(word_of("ass"), "as");
        assert_eq!(word_of("asf"), "à");
        assert!(letters_of("ass").2);
    }

    #[test]
    fn z_removes_tone_then_qualities_then_becomes_literal() {
        assert_eq!(word_of("aasz"), "â");
        assert_eq!(word_of("aaszz"), "a");
        assert_eq!(word_of("az"), "az");
    }

    #[test]
    fn u_plus_o_horn_becomes_u_o_horn() {
        assert_eq!(word_of("uow"), "ươ");
        assert_eq!(word_of("uowng"), "ương");
        assert_eq!(word_of("thuowng"), "thương");
    }

    #[test]
    fn open_u_o_is_not_normalised_after_an_onset() {
        assert_eq!(word_of("quow"), "quơ");
        assert_eq!(word_of("quowr"), "quở");
        assert_eq!(word_of("thuowr"), "thuở");
        assert_eq!(word_of("huow"), "huơ");
        // Word-initial / closed forms keep the `ươ` normalisation.
        assert_eq!(word_of("uow"), "ươ");
        assert_eq!(word_of("uowng"), "ương");
        assert_eq!(word_of("thuowng"), "thương");
    }

    #[test]
    fn case_is_preserved_across_merges() {
        fn replay_cased(raw: &str) -> String {
            let keys: Vec<RawKey> = raw
                .chars()
                .map(|ch| RawKey::new(ch.to_ascii_lowercase(), ch.is_ascii_uppercase()))
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
            let index =
                tone.and_then(|tone| tone::place(&letters, ToneStyle::Modern).map(|i| (tone, i)));
            match index {
                Some((tone, index)) => render(&letters, Some(tone), Some(index)),
                None => render(&letters, None, None),
            }
        }
        assert_eq!(replay_cased("DD"), "Đ");
        assert_eq!(replay_cased("Dd"), "Đ");
        assert_eq!(replay_cased("VIEEJT"), "VIỆT");
        assert_eq!(replay_cased("Chaof"), "Chào");
    }

    #[test]
    fn bases_strip_all_quality_marks() {
        assert_eq!(bases(&letters_of("dduwowng").0), "duong");
        assert_eq!(bases(&letters_of("nguyeen").0), "nguyen");
    }
}
