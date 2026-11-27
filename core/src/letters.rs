//! The letter model: unaccented base letters, quality marks and tone marks,
//! plus the rendering tables that turn them into precomposed Vietnamese text.
//!
//! The engine keeps only ASCII raw keystrokes for a word and re-derives a
//! [`Letter`] list from them. A letter always has a plain `a`–`z` [`Letter::base`];
//! diacritics live in [`Letter::quality`] (â/ă/ê/ô/ơ/ư/đ) and [`Letter::tone`]
//! (sắc/huyền/hỏi/ngã/nặng), so un-accenting is trivial and deterministic.

/// A diacritic that changes the base letter itself.
///
/// It is applied by the Telex keys `aa ee oo aw ow uw dd` or the VNI digits
/// `6 7 8 9` (SPEC §5.2).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Quality {
    /// `â`, `ê`, `ô`.
    Circumflex,
    /// `ă`.
    Breve,
    /// `ơ`, `ư`.
    Horn,
    /// `đ`.
    DStroke,
}

/// One of the five Vietnamese tone marks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tone {
    /// `s` in Telex / `1` in VNI: sắc (´).
    Acute,
    /// `f` in Telex / `2` in VNI: huyền (`).
    Grave,
    /// `r` in Telex / `3` in VNI: hỏi (̉).
    Hook,
    /// `x` in Telex / `4` in VNI: ngã (~).
    Tilde,
    /// `j` in Telex / `5` in VNI: nặng (̣).
    Dot,
}

impl Tone {
    /// Map a Telex tone key to its tone, if it is one.
    pub fn from_telex(key: char) -> Option<Tone> {
        match key {
            's' => Some(Tone::Acute),
            'f' => Some(Tone::Grave),
            'r' => Some(Tone::Hook),
            'x' => Some(Tone::Tilde),
            'j' => Some(Tone::Dot),
            _ => None,
        }
    }

    /// Map a VNI tone digit (`1`..`5`) to its tone, if it is one.
    pub fn from_vni(key: char) -> Option<Tone> {
        match key {
            '1' => Some(Tone::Acute),
            '2' => Some(Tone::Grave),
            '3' => Some(Tone::Hook),
            '4' => Some(Tone::Tilde),
            '5' => Some(Tone::Dot),
            _ => None,
        }
    }

    fn index(self) -> usize {
        match self {
            Tone::Acute => 0,
            Tone::Grave => 1,
            Tone::Hook => 2,
            Tone::Tilde => 3,
            Tone::Dot => 4,
        }
    }
}

/// One letter of the word being rendered.
///
/// Tone marks are **word-level** (SPEC §5.3: placement is recomputed from the
/// current letters on every render), so a letter only stores its quality mark.
/// `locked` marks letters that were produced as a *literal* operator key after
/// an operator undo (e.g. the second `a` of `aaa`); locked letters are never
/// merged into again (SPEC §5.2).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Letter {
    /// Unaccented base letter, always a lowercase ASCII `a`–`z`.
    pub base: char,
    /// Quality mark, if any.
    pub quality: Option<Quality>,
    /// Whether the raw key that created this letter was typed with Shift/Caps.
    pub upper: bool,
    /// Locked letters cannot be merged into by a repeated operator.
    pub locked: bool,
}

impl Letter {
    /// A plain letter with no marks.
    pub fn new(base: char, upper: bool) -> Letter {
        Letter {
            base,
            quality: None,
            upper,
            locked: false,
        }
    }

    /// A letter created from a literal operator key after an undo.
    pub fn literal(base: char, upper: bool) -> Letter {
        Letter {
            base,
            quality: None,
            upper,
            locked: true,
        }
    }

    /// Whether the base letter is a vowel.
    pub fn is_vowel(&self) -> bool {
        is_vowel(self.base)
    }
}

/// One raw keystroke of the current word.
///
/// `ch` is stored lowercase; `upper` remembers Shift/Caps Lock so that case can
/// be re-derived at render time (SPEC §5.4).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RawKey {
    /// Lowercase ASCII character: a letter, or a VNI operator digit.
    pub ch: char,
    /// Shift/Caps Lock was held when the key was typed.
    pub upper: bool,
}

impl RawKey {
    /// Create a raw key from a lowercased character and its case flag.
    pub fn new(ch: char, upper: bool) -> RawKey {
        RawKey { ch, upper }
    }

    /// The character this key contributes when it is rendered literally.
    pub fn literal(self) -> char {
        if self.upper {
            self.ch.to_ascii_uppercase()
        } else {
            self.ch
        }
    }
}

/// Whether `ch` is an unaccented Vietnamese vowel letter.
pub fn is_vowel(ch: char) -> bool {
    matches!(ch, 'a' | 'e' | 'i' | 'o' | 'u' | 'y')
}

/// The precomposed lowercase form of `base` with `quality` applied.
///
/// Returns `None` for combinations that do not exist in Vietnamese (e.g. `b`
/// with a circumflex); callers fall back to the plain base letter.
pub fn quality_char(base: char, quality: Option<Quality>) -> Option<char> {
    match (base, quality) {
        ('a', None) => Some('a'),
        ('a', Some(Quality::Circumflex)) => Some('â'),
        ('a', Some(Quality::Breve)) => Some('ă'),
        ('e', None) => Some('e'),
        ('e', Some(Quality::Circumflex)) => Some('ê'),
        ('i', None) => Some('i'),
        ('o', None) => Some('o'),
        ('o', Some(Quality::Circumflex)) => Some('ô'),
        ('o', Some(Quality::Horn)) => Some('ơ'),
        ('u', None) => Some('u'),
        ('u', Some(Quality::Horn)) => Some('ư'),
        ('y', None) => Some('y'),
        ('d', None) => Some('d'),
        ('d', Some(Quality::DStroke)) => Some('đ'),
        _ => None,
    }
}

/// Toned forms indexed by [`Tone::index`]: sắc, huyền, hỏi, ngã, nặng.
fn tone_char(quality_letter: char, tone: Tone) -> Option<char> {
    let forms = match quality_letter {
        'a' => ['á', 'à', 'ả', 'ã', 'ạ'],
        'ă' => ['ắ', 'ằ', 'ẳ', 'ẵ', 'ặ'],
        'â' => ['ấ', 'ầ', 'ẩ', 'ẫ', 'ậ'],
        'e' => ['é', 'è', 'ẻ', 'ẽ', 'ẹ'],
        'ê' => ['ế', 'ề', 'ể', 'ễ', 'ệ'],
        'i' => ['í', 'ì', 'ỉ', 'ĩ', 'ị'],
        'o' => ['ó', 'ò', 'ỏ', 'õ', 'ọ'],
        'ô' => ['ố', 'ồ', 'ổ', 'ỗ', 'ộ'],
        'ơ' => ['ớ', 'ờ', 'ở', 'ỡ', 'ợ'],
        'u' => ['ú', 'ù', 'ủ', 'ũ', 'ụ'],
        'ư' => ['ứ', 'ừ', 'ử', 'ữ', 'ự'],
        'y' => ['ý', 'ỳ', 'ỷ', 'ỹ', 'ỵ'],
        _ => return None,
    };
    Some(forms[tone.index()])
}

/// The lowercase precomposed character for one letter, with or without a tone.
pub fn glyph(letter: &Letter, tone: Option<Tone>) -> char {
    let plain = quality_char(letter.base, letter.quality).unwrap_or(letter.base);
    match tone {
        Some(tone) => tone_char(plain, tone).unwrap_or(plain),
        None => plain,
    }
}

/// Render a letter list as precomposed Vietnamese text.
///
/// `tone` is the word-level tone mark and `tone_index` the letter it belongs to
/// (as computed by [`crate::tone::place`]). When either is missing the word is
/// rendered without a tone mark. Case is re-applied after the diacritics.
pub fn render(letters: &[Letter], tone: Option<Tone>, tone_index: Option<usize>) -> String {
    let mut out = String::with_capacity(letters.len() * 3);
    for (index, letter) in letters.iter().enumerate() {
        let letter_tone = if tone_index == Some(index) {
            tone
        } else {
            None
        };
        let lower = glyph(letter, letter_tone);
        if letter.upper {
            out.extend(lower.to_uppercase());
        } else {
            out.push(lower);
        }
    }
    out
}

/// The unaccented form of a letter list: only the base letters (`viêt` → `viet`).
///
/// This is exactly what the smart-English validity check consumes (SPEC §5.5).
pub fn bases(letters: &[Letter]) -> String {
    let mut out = String::with_capacity(letters.len());
    for letter in letters {
        out.push(letter.base);
    }
    out
}

/// The untoned Vietnamese spelling of a letter list, lowercase (`viêt` → `viê`).
///
/// This is what the syllable validity tables consume: quality marks are part of
/// the spelling (`ê` ≠ `e`), the tone is not.
pub fn quality_string(letters: &[Letter]) -> String {
    let mut out = String::with_capacity(letters.len() * 3);
    for letter in letters {
        out.push(glyph(letter, None));
    }
    out
}

/// Render the raw keystrokes literally (used by Escape and smart fallback).
pub fn raw_string(raw: &[RawKey]) -> String {
    let mut out = String::with_capacity(raw.len());
    for key in raw {
        out.push(key.literal());
    }
    out
}

/// Whether any letter carries a quality mark (including `đ`).
pub fn has_quality(letters: &[Letter]) -> bool {
    letters.iter().any(|letter| letter.quality.is_some())
}

/// Remove every quality mark from the word (including `đ`).
pub fn clear_qualities(letters: &mut [Letter]) {
    for letter in letters.iter_mut() {
        letter.quality = None;
    }
}

/// The `u` + `ơ` → `ươ` normalisation, applied after the raw keys have been
/// replayed (so the following letters are known).
///
/// This is deliberately context-aware: Vietnamese uses **open** `uơ` after a
/// consonant onset in a handful of words (`quơ`, `thuở`, `huơ`) but `ươ` when a
/// coda or glide follows (`thương`, `người`), and word-initially (`uow` in
/// Telex) the normalised form is expected. Conditions:
///
/// * the `u` of a leading `qu` onset is part of the onset and never takes a
///   horn, so `quow` → `quơ`, not `qươ`;
/// * after a consonant onset an open `uơ` (nothing after the pair) is kept:
///   `thuowr` → `thuở`, `huow` → `huơ`;
/// * otherwise (word-initial, or followed by another letter) `u` takes the
///   horn: `uow` → `ươ`, `uowng` → `ương`, `thuowng` → `thương`.
pub fn normalize_u_o(letters: &mut [Letter]) {
    if letters.len() < 2 {
        return;
    }
    for index in 0..letters.len() - 1 {
        if letters[index].base != 'u' || letters[index + 1].base != 'o' {
            continue;
        }
        // The `u` of a leading `qu` onset belongs to the onset.
        if index == 1 && letters[0].base == 'q' {
            continue;
        }
        let after_a_consonant_onset = index > 0;
        let has_following_letter = letters.len() > index + 2;

        if letters[index + 1].quality == Some(Quality::Horn) {
            if after_a_consonant_onset && !has_following_letter {
                continue;
            }
            if letters[index].quality.is_none() {
                letters[index].quality = Some(Quality::Horn);
            }
        } else if letters[index].quality == Some(Quality::Horn)
            && letters[index + 1].quality.is_none()
            && !letters[index + 1].locked
            && has_following_letter
        {
            // `ư` + `o` + coda/glide -> `ươ` (`dduwongf -> đường`, `nguwoif -> người`).
            letters[index + 1].quality = Some(Quality::Horn);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain(text: &str) -> Vec<Letter> {
        text.chars()
            .map(|ch| Letter::new(ch.to_ascii_lowercase(), ch.is_ascii_uppercase()))
            .collect()
    }

    #[test]
    fn renders_quality_and_tone_marks() {
        let mut letters = plain("viet");
        letters[2].quality = Some(Quality::Circumflex);
        assert_eq!(render(&letters, Some(Tone::Dot), Some(2)), "việt");
        assert_eq!(render(&letters, None, None), "viêt");
        assert_eq!(bases(&letters), "viet");
    }

    #[test]
    fn renders_case_after_marks() {
        let mut letters = plain("VIET");
        letters[2].quality = Some(Quality::Circumflex);
        assert_eq!(render(&letters, Some(Tone::Dot), Some(2)), "VIỆT");
    }

    #[test]
    fn tone_table_covers_every_vowel() {
        for base in ["a", "ă", "â", "e", "ê", "i", "o", "ô", "ơ", "u", "ư", "y"] {
            let base = base.chars().next().unwrap();
            for tone in [Tone::Acute, Tone::Grave, Tone::Hook, Tone::Tilde, Tone::Dot] {
                assert!(tone_char(base, tone).is_some(), "{base} with {tone:?}");
            }
        }
    }

    #[test]
    fn invalid_quality_falls_back_to_base() {
        let mut letter = Letter::new('b', false);
        letter.quality = Some(Quality::Horn);
        assert_eq!(glyph(&letter, None), 'b');
        assert_eq!(glyph(&letter, Some(Tone::Acute)), 'b');
    }

    #[test]
    fn u_o_normalisation_is_context_aware() {
        fn render_text(text: &str) -> String {
            let mut letters = plain(text);
            // `ơ` is not plain ASCII; build the pair explicitly instead.
            for letter in letters.iter_mut() {
                if letter.base == 'o' {
                    letter.quality = Some(Quality::Horn);
                }
            }
            normalize_u_o(&mut letters);
            render(&letters, None, None)
        }
        // word-initial pair: normalised
        assert_eq!(render_text("uo"), "ươ");
        // leading qu onset: u stays part of the onset
        assert_eq!(render_text("quo"), "quơ");
        // open uơ after a consonant onset: kept
        assert_eq!(render_text("thuo"), "thuơ");
        assert_eq!(render_text("huo"), "huơ");
        // coda after the pair: normalised
        assert_eq!(render_text("thuong"), "thương");

        // `ư` + `o` + coda -> `ươ`; open `ưo` stays untouched.
        let mut closed = plain("duong");
        closed[1].quality = Some(Quality::Horn);
        normalize_u_o(&mut closed);
        assert_eq!(render(&closed, None, None), "dương");

        let mut glide = plain("nguoi");
        glide[2].quality = Some(Quality::Horn);
        normalize_u_o(&mut glide);
        assert_eq!(render(&glide, None, None), "ngươi");

        let mut open = plain("thuo");
        open[2].quality = Some(Quality::Horn);
        normalize_u_o(&mut open);
        assert_eq!(render(&open, None, None), "thưo");
    }

    #[test]
    fn raw_string_restores_case() {
        let raw = vec![
            RawKey::new('v', false),
            RawKey::new('i', false),
            RawKey::new('e', true),
        ];
        assert_eq!(raw_string(&raw), "viE");
    }
}
