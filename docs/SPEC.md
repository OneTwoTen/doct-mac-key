# DoctKey — Specification (v1)

A personal Vietnamese + English input method for macOS. The linguistic engine is
written in Rust; a thin Swift/InputMethodKit shell glues it to the OS.

Status: this document is the **authoritative contract** for the implementation.
If code and spec disagree, the spec is right — or raise it with the lead before
changing behaviour.

---

## 1. Repository layout

```
doct-mac-key/
├── README.md                 # user-facing docs (Vietnamese)
├── Makefile                  # build / test / install / uninstall
├── docs/SPEC.md              # this file
├── core/                     # Rust engine (the "lõi")
│   ├── Cargo.toml
│   ├── include/doctkey.h     # C ABI (frozen contract)
│   ├── src/
│   │   ├── lib.rs
│   │   ├── config.rs         # Config struct + JSON parsing
│   │   ├── engine.rs         # per-word state machine, key dispatch
│   │   ├── telex.rs          # Telex operator rules
│   │   ├── vni.rs            # VNI operator rules
│   │   ├── tone.rs           # tone placement
│   │   ├── letters.rs        # Letter/Quality/Tone model + rendering
│   │   ├── syllable.rs       # Vietnamese syllable validity (smart English)
│   │   ├── sim.rs            # reference host simulation (tests/CLI)
│   │   ├── ffi.rs            # extern "C" layer + JSON results
│   │   └── bin/doctkey-cli.rs
│   └── tests/
│       ├── fixtures/*.tsv    # acceptance fixtures (DO NOT EDIT)
│       └── fixtures_test.rs
├── macos/
│   ├── Sources/              # Swift app (InputMethodKit)
│   │   ├── main.swift
│   │   ├── AppDelegate.swift
│   │   ├── DoctKeyCore.swift # Swift wrapper over the C ABI
│   │   ├── KeyHandler.swift  # pure logic, host-agnostic (testable)
│   │   ├── InputController.swift
│   │   ├── HotkeyManager.swift
│   │   ├── Config.swift
│   │   ├── StatusMenu.swift
│   │   └── Bridging.h
│   ├── Tests/
│   │   ├── main.swift        # fixture runner
│   │   └── MockHost.swift
│   └── Resources/Info.plist
└── scripts/
    ├── build.sh              # cargo + swiftc + bundle + ad-hoc codesign
    ├── test-swift.sh         # compile & run macos/Tests against real Rust core
    ├── install.sh
    ├── uninstall.sh
    └── enable-input-source.swift
```

Artifacts:

* Rust static library: `core/target/release/libdoctkey_core.a`
* App bundle: `build/DoctKey.app` (`Contents/MacOS/DoctKey`, `Contents/Info.plist`)
* Install location: macOS 26+ → `/Library/Input Methods/DoctKey.app` (system-wide,
  root-owned, requires admin; the per-user directory is not scanned on Tahoe).
  macOS 13–15 → `~/Library/Input Methods/DoctKey.app`.

---

## 2. C ABI

Frozen in `core/include/doctkey.h`. Key points:

* `DoctKeyEngine *doctkey_engine_new(const char *config_json)`
* `void doctkey_engine_free(DoctKeyEngine *)`
* `int32_t doctkey_engine_set_config(DoctKeyEngine *, const char *config_json)`
* `char *doctkey_feed_char(DoctKeyEngine *, uint32_t ch, uint32_t flags)`
* `char *doctkey_feed_key(DoctKeyEngine *, uint32_t key)`
* `char *doctkey_commit(DoctKeyEngine *)`
* `void doctkey_reset(DoctKeyEngine *)`
* `char *doctkey_command(DoctKeyEngine *, const char *command_json)`
* `char *doctkey_status(DoctKeyEngine *)`
* `const char *doctkey_version(void)`
* `void doctkey_string_free(char *)`

All returned strings are owned by the caller. Crate types:
`crate-type = ["staticlib", "rlib", "cdylib"]`, lib name `doctkey_core`,
version `0.1.0`, edition 2021, no async, only `serde_json` as a dependency
(keep the dependency tree tiny; no serde derive needed).

---

## 3. Result JSON for keystrokes

Every `feed_char` / `feed_key` / `commit` call returns:

```json
{
  "op": "append",
  "text": "á",
  "word": "á",
  "raw": "as",
  "composing": true,
  "consumed": true,
  "mode": "vi",
  "method": "telex",
  "tone_style": "modern",
  "smart": true
}
```

| field       | meaning |
|-------------|---------|
| `op`        | `append` — the composition grew by `text` (append at caret / after marked text)<br>`replace` — the whole visible composition must be replaced by `word` (empty string = delete it)<br>`commit` — composition ends; insert `text` in place of the visible composition, then reset<br>`pass` — the IME did nothing; the host must process the original key normally<br>`none` — the key was consumed but nothing on screen changes |
| `text`      | for `append`: the suffix to add; for `replace`/`commit`: the full new composition text; else `""` |
| `word`      | the full visible composition (may be `""`) |
| `raw`       | the literal keystrokes of the current word, e.g. `"vieejt"` |
| `composing` | `true` while a word is being composed |
| `consumed`  | `true` if the physical key event must be swallowed by the IME |
| `mode`      | `"vi"` or `"en"` |
| `method`    | `"telex"` or `"vni"` |
| `tone_style`| `"modern"` or `"traditional"` |
| `smart`     | smart English fallback enabled |

Invariants the host relies on:

1. `append` means `word == previous_word + text`; the host can insert `text`
   directly without deleting anything.
2. `replace` means "delete the currently visible composition (the host knows its
   length) and insert `word` there".
3. `commit` is followed by the host clearing its composition; `consumed == false`
   means the original key (space, punctuation, return, tab, arrow…) must still
   be delivered to the application after committing.
4. `pass` never changes the screen.

Commands (`doctkey_command`) and `doctkey_status` return the same object with
`op: "state"` and field `changed: true/false`. Commands that commit a
composition (`{"cmd":"commit"}`) return `op:"commit"` with the usual fields.

Engine state is *global per engine instance*: mode/method/tone_style/smart are
engine-wide (one engine is shared by all clients of the IME process); the
per-word composition state is what `doctkey_reset` clears.

---

## 4. Config JSON

```json
{
  "mode": "vi",                 // "vi" | "en"
  "method": "telex",            // "telex" | "vni"
  "tone_style": "modern",       // "modern" | "traditional"
  "smart_english": true
}
```

Unknown fields are ignored. Missing fields keep defaults. `doctkey_engine_set_config`
merges (does not reset unrelated fields) and keeps the current composition.

Commands accepted by `doctkey_command`:

| command JSON | effect |
|---|---|
| `{"cmd":"set_mode","mode":"vi"}` | switch language mode |
| `{"cmd":"toggle_mode"}` | vi ↔ en |
| `{"cmd":"set_method","method":"vni"}` | telex ↔ vni |
| `{"cmd":"toggle_method"}` | telex ↔ vni |
| `{"cmd":"set_tone_style","tone_style":"traditional"}` | tone placement style |
| `{"cmd":"toggle_tone_style"}` | modern ↔ traditional |
| `{"cmd":"set_smart","smart":true}` | smart English fallback on/off |
| `{"cmd":"toggle_smart"}` | toggle |
| `{"cmd":"set_config","config":{…}}` | merge config object |
| `{"cmd":"commit"}` | commit composition now (op="commit") |
| `{"cmd":"reset"}` | drop composition state (op="none") |

Mode/method changes **must not** silently lose a half-typed word: they commit
the visible composition (`op:"commit"` with its text) before applying the new
setting, and report that in the result (`"changed": true`).

---

## 5. Engine behaviour (authoritative)

The engine keeps the raw keystrokes of the current word and **recomputes** the
rendered word from scratch on every keystroke ("canonical recompute"). This makes
backspace and restore behaviour deterministic. Words are pure ASCII key sequences;
each key remembers whether it was typed with Shift/Caps Lock for case.

### 5.1 State

```rust
struct Engine {
    cfg: Config,
    mode: Mode,            // Vi | En
    raw: Vec<RawKey>,      // current word keys: { ch: char (a-z), upper: bool, kind }
    shown: String,         // last rendered word (mirror of the screen)
    // plus derived fields for the last result
}
```

`break` characters: space, tab, return, every ASCII non-letter that is not a
letter/digit used as an operator, and any non-ASCII scalar that is not a
Vietnamese letter. Digits: always break in Telex; in VNI they are operators when
applicable, otherwise break.

### 5.2 Rendering a word from raw keys

Process keys left to right, maintaining:

* `letters: Vec<Letter { base: char, quality: Option<Quality>, tone: Option<Tone>,
  upper: bool, locked: bool }>` — `base` is always an unaccented a–z letter.
* a single word-level `tone: Option<Tone>`.
* `had_undo: bool` — set whenever a repeated operator was interpreted as an undo.

**Telex operators**

| key | effect |
|---|---|
| `aa` `ee` `oo` | merge the **immediately preceding** letter into â / ê / ô |
| `aw` `ow` `uw` | apply ă / ơ / ư to the nearest previous `a`/`o`/`u` (search backwards through the letters, skipping consonants); `w` with no target at word start = `ư`, otherwise literal `w` |
| `dd` | merge into `đ` **only at the start of the word** (first two keys) |
| `s` `f` `r` `x` `j` | tone: sắc / huyền / hỏi / ngã / nặng — applies only when the word has a vowel, otherwise it is a literal letter |
| `z` | remove: tone first; if no tone, all quality marks (including `đ`); if nothing to remove, literal `z` |

Normalisation (once, after replaying the whole word, because it is context
dependent): `u` + `ơ` becomes `ươ` **except** (a) when the `u` is the `u` of a
leading `qu` onset (`quow → quơ`, `quowr → quở`) and (b) when `uơ` is an open
syllable after another consonant onset (`thuowr → thuở`, `huow → huơ`); so
`uow/uowng/uowngf → ươ/ương/ường` still work while `quơ/quở/thuở/huơ` are
typeable. The VNI `7` operator follows the same rules (`quo7 → quơ`,
`thuo73 → thuở`).

**Repeated operator = undo + literal key.** If `aa`/`ee`/`oo`/`dd`/`aw`/`ow`/`uw`
would re-apply a mark that is already present on that letter, the mark is removed,
the letter is marked `locked` (so it cannot merge again) and the operator key is
appended as a **literal, locked letter**. Examples: `aaa → aa`, `ddd → dd`,
`aww → aw`. For tone keys: if the same tone is already applied, remove the tone
and append the literal tone letter (`ass → as`). `had_undo` is set in both cases.

**VNI operators** (digits)

| key | effect |
|---|---|
| `1` `2` `3` `4` `5` | tone sắc/huyền/hỏi/ngã/nặng (only if the word has a vowel) |
| `6` | â/ê/ô on the nearest previous `a`/`e`/`o` (search backwards from the end) |
| `7` | ơ on `o`, ư on `u` (nearest previous, backwards), plus `u`+`ơ` → `ươ` |
| `8` | ă on the nearest previous `a` |
| `9` | đ on the nearest previous `d` |
| `0` | remove tone, else remove quality marks |

VNI repeated operator: remove the mark and consume the digit (no literal digit is
inserted); `had_undo = true`. If an operator has no applicable target, the digit
is a break character (commit the word, pass the digit to the host). If
`smart_english` is on and the current word rendered **without** the digit is an
escaped literal (cannot be Vietnamese), a digit operator also behaves as a break
character, so English words such as `abc123` keep their digits.

Telex tone keys: if a tone key is pressed while the word has vowels but **no
placeable vowel** (e.g. the `u` of `qu`), it stays a literal letter.

### 5.3 Tone placement

Work on the vowel letters of the rendered word (after quality marks, before tone).
The tone is a **single word-level value**: a new tone key replaces any previous
tone, and placement is recomputed from the current letters on every render (so
`asf → à`, and in an invalid word with disjoint vowel runs the mark can move to
the last run, e.g. `confirm` smart-off → `conỉm`).

1. Onset exceptions: the `u` of a leading `q u` and the `i` of a leading
   `g i` followed by another vowel belong to the onset, not the vowel cluster.
   (`quas → quá`, `gif → gì`, `giuwx → giữ`, `giaf → già`.)
2. If there are several disjoint vowel runs (only possible in words that are not
   valid Vietnamese), placement works on the **last** contiguous run.
3. If the vowel cluster contains at least one quality mark, put the tone on the
   **last** quality-marked vowel: `tiêng → tiếng`, `được`, `muốn`, `người`,
   `hoặc`, `chuyển`.
4. Otherwise, by vowel count:
   * 1 vowel → that vowel.
   * 2 vowels and a coda (consonant after the cluster) → the **second** vowel.
   * 2 vowels, open syllable → the first vowel, **except** the nuclei `oa`, `oe`,
     `uy` where the style decides: `traditional` → first, `modern` → second
     (`hòa`/`hoà`, `khỏe`/`khoẻ`, `thủy`/`thuỷ`). `chào` and `mèo` are not
     affected (their nuclei are `ao`, `eo`).
   * 3 vowels → the middle vowel (`oài`, `khuỷu`, `ngoáy`).
5. No vowel → no tone; then the tone key stays a literal letter.

### 5.4 Case

Each rendered letter is uppercase iff the raw key that created its base letter
was typed with Shift/Caps Lock. Merged marks keep the case of their base letter.
Tone marks never change case.

### 5.5 Smart English fallback (config `smart_english`)

Only in `mode == "vi"`. After rendering, take the rendered word **without the
tone mark** (quality marks kept, then map to unaccented letters: `viêt → viet`).

* If the literal keystrokes spell a **known English word** of 4+ letters, keep
  them verbatim (`test → test`, `text → text`, `choose → choose`,
  `church → church`, `boring → boring`). The curated list lives in
  `core/src/english_words.rs`; it contains only words that actually collide with
  Telex operators, so Vietnamese sequences are unaffected.
* If that unaccented form is a valid Vietnamese syllable **or a prefix of one**
  (so a half-typed word never flips to English), keep the Vietnamese rendering.
* Otherwise render the **literal raw keystrokes**, e.g. `hello → hello`,
  `meeting → meeting`, `looks → looks` (smart off: `lốk`), `confirm`,
  `fresh`, `google`.
* Exception (narrow): if the **last processed raw key** was an undo/removal
  (repeated operator that removed a mark, or `z`/`0` that actually removed a
  tone or a quality), keep the Vietnamese rendering when the resulting untoned
  form is still a Vietnamese syllable/prefix, or when the whole word is a tiny
  2–3 key undo pattern (`aaa → aa`, `ass → as`, `ddd → dd`, `aww → aw`,
  `aasz → â`, `aaszz → a`, `vieejtz → viêt`). An undo in a longer word whose
  untoned form is not Vietnamese no longer exempts it, so English words that
  end in a repeated operator keep their literal keystrokes (`order`, `class`,
  `staff`, `deliveryor`, `hardware`, `message`). An undo that happened earlier
  and was followed by more keys never exempted the word.

Validity data: embed a curated set of Vietnamese onsets/rimes/nuclei and accept
all combinations plus all their prefixes; be permissive rather than strict, so
that ordinary Vietnamese words are never mis-classified. See
`core/src/syllable.rs`. The inventory includes the loanword nucleus `oo`
(`boong`, `xoong`).

### 5.6 Per-key results

| input | op / behaviour |
|---|---|
| letter that keeps/extents the word | `append` if the new word starts with the old one, else `replace` |
| first letter of a word | `append` with `text == word` (host starts composing) |
| backspace while composing | remove the last raw key, recompute: `replace` (empty word → `text:""`, `composing:false`); `consumed:true` |
| backspace with no composition | `pass` |
| escape while composing | restore the literal raw keystrokes: `replace` with `text == raw`, `composing:false`, `consumed:true`; `had_undo` irrelevant |
| escape with no composition | `pass` |
| space/punctuation/other break while composing | `commit`, `consumed:false` (host commits `text`, then delivers the break character) |
| break with no composition | `pass` |
| return / tab / arrows (feed_key 4,5,6) while composing | `commit`, `consumed:false` |
| same keys with no composition | `pass` |
| forward delete while composing | treat like backspace at the caret: same as backspace (or `pass` when empty) |
| `mode == "en"` | every printable key: `pass` (no composition at all) |
| auto-repeat key (host-level, see Swift) | host swallows it |

Backspace must work per **raw key**, not per visible character: `tooi<BS>` →
`tô`, `as<BS>` → `a`, `aa<BS>` → `a`.

### 5.7 Commit

`doctkey_commit` → `op:"commit"`, `text = word`, `word:""`, `composing:false`,
`consumed:true`; if there is no composition → `op:"none"`.

---

## 6. Reference host simulation (used by tests, CLI and fixtures)

`core/src/sim.rs` exposes:

```rust
pub fn simulate(config_json: &str, keys: &str) -> String
```

It mimics the macOS controller in **direct insert** mode, i.e. the host keeps a
text buffer and applies results:

```
out: String          // text already in the document
shown: String        // the composition currently on screen (suffix of out)

apply(result):
  append   -> out += text;  shown += text
  replace  -> remove shown (char count) from the end of out; out += word; shown = word
  commit   -> remove shown from the end of out; out += text; shown = ""
  pass     -> no change
  none     -> no change
```

Loop over the key string:

* `<BS>` → `feed_key(1)`, `<DEL>` → `feed_key(2)`, `<ESC>` → `feed_key(3)`,
  `<ENTER>` → `feed_key(4)`, `<TAB>` → `feed_key(5)`;
* any other character (including a literal space) → `feed_char(scalar, 0)`;
* after applying, if `op` is `commit` or `pass` **and** `consumed == false` the
  host processes the key itself: a printable character / space is appended to
  `out`, `<ENTER>` appends `"\n"`, `<TAB>` appends `"\t"`, and `<BS>` removes the
  last character of `out` (if any); `<ESC>`, `<DEL>` do nothing;
* at the end, call `doctkey_commit` and apply it.

`null`/`none` results never change `out`.

### Fixture format (`core/tests/fixtures/*.tsv`)

TSV, three columns, `#` comments and blank lines ignored:

```
telex,vi,1,modern<TAB>vieejt<TAB>việt
```

* column 1: `method,mode,smart,tone_style` (smart: `0`/`1`)
* column 2: key sequence (may contain spaces, `<BS>`, `<ESC>`, `<ENTER>`, `<TAB>`)
* column 3: expected final document text

`core/tests/fixtures_test.rs` must run every fixture through `simulate` and fail
on any mismatch. The Swift test suite (`macos/Tests`) runs the *same* fixtures
through the real `KeyHandler` + a mock host in both insert modes.

---

## 7. macOS application

Swift 6 / InputMethodKit, no third-party dependencies.

### 7.1 Bundle

* Bundle id: `com.doct.doctkey`
* Executable: `DoctKey`
* `LSMinimumSystemVersion`: `13.0`
* `LSUIElement`: `true` (menu-bar agent, no Dock icon)
* `NSPrincipalClass`: `NSApplication`
* `InputMethodConnectionName`: `DoctKey_Connection`
* `InputMethodServerControllerClass`: `DoctKeyInputController`
* `tsInputMethodCharacterRepertoireKey`: `["Latn"]`
* Platform: `arm64` (Apple Silicon; universal binary optional)

`main.swift` creates the `IMKServer` (connection name + bundle id) **before**
`NSApp.run()`, keeps a strong reference, installs the app delegate and runs
`NSApplication.shared`.

### 7.2 Classes

* `DoctKeyCore` — Swift wrapper of the C ABI. `init(configJSON:)`, `setConfig`,
  `feedChar`, `feedKey`, `commit`, `reset`, `command`, `status`, `version`.
  Decodes the JSON into a `KeyResult` struct. Must always free the C string.
  A single shared instance is used by the app (mode is global).
* `KeyHandler` — host-agnostic key processing (this is the testable part):
  takes a `KeyInput { characters: String?, keyCode: UInt16, modifiers:
  Modifiers, isRepeat: Bool }`, asks the engine, and applies the result to a
  `TextHost` protocol:

  ```swift
  protocol TextHost: AnyObject {
      func insertText(_ text: String)                       // insert at caret
      func replaceTrailing(_ utf16Length: Int, with text: String) // replace N units before caret
      func setMarkedText(_ text: String)
      func commitMarkedText(with text: String)
  }
  ```

  Insert modes (`insert_mode` config: `"marked"` default, `"direct"`):
  * marked: `append`/`replace` → `setMarkedText(word)`; `commit` →
    `commitMarkedText(with: text)`; track nothing else.
  * direct: `append` → `insertText(text)` and append to `shown`;
    `replace` → `replaceTrailing(shown.utf16.count, with: word)`;
    `commit` → if `shown` non-empty replace it with `text`, clear `shown`.

  Modifier/command keys (`⌘`, `⌃`, `⌥`), key codes for backspace/delete/escape/
  return/tab/arrows/home/end/page/F-keys are handled explicitly; auto-repeat of
  character keys is swallowed while composing, backspace repeat is passed through
  when nothing is being composed.
* `InputController: IMKInputController` — adapts `IMKTextInput` to `TextHost`,
  converts `NSEvent` → `KeyInput`, implements `recognizedEvents` (keyDown),
  `handle(_:client:)`, `activateServer`, `deactivateServer`,
  `commitComposition`, and returns `false` for everything it does not consume.
* `HotkeyManager` — global hotkeys with Carbon `RegisterEventHotKey`
  (no accessibility permission needed). Defaults:
  * toggle Vietnamese/English: `⌃⌥V`
  * toggle Telex/VNI: `⌃⌥T`
  * toggle tone style: `⌃⌥D`
  * toggle smart English: `⌃⌥E`
  * reload config: `⌃⌥R`
* `Config` — loads `~/.config/doctkey/config.json` (creating defaults when
  absent), persists user toggles back to that file, hotkey strings like
  `"ctrl+alt+v"`.
* `StatusMenu` — `NSStatusItem` titled `VI` / `EN`; menu with the toggles,
  insert mode, reload config, open config, **Cài đặt… (⌘,)**, about, quit. Title
  briefly shows the full state (e.g. `VI · Telex`) after a toggle, then shrinks
  back.
* `SettingsWindowController` — the management window (`DoctKey — Cài đặt`, four
  tabs: **Chung**, **Phím tắt**, **Trạng thái**, **Giới thiệu**). Bound to the
  live AppDelegate state; changes are applied through `KeyHandler.command` and
  persisted. The Status tab reports install path, version, signature
  (ad-hoc/Apple Development/Developer ID), code-signing identities, TIS
  input-source state (registered/enabled/selected), with buttons to register,
  enable, select, open System Settings → Input Sources, copy diagnostics, install
  or update system-wide (privileged copy via `osascript … with administrator
  privileges`, optional signing identity), and uninstall. It explains that
  macOS 26 requires logout/login before the new input source appears.
* `CompatibilityMode` — signing-independent fallback: a session `CGEventTap`
  (head-insert, keyDown+keyUp, own `DoctKeyCore` instance) that composes
  Vietnamese directly into the focused app. Events we post are tagged with a
  magic `kCGEventSourceUserData` and skipped; secure input is passed through;
  ⌘/⌃/⌥ combos, delimiters and unhandled keys pass through; a repeatable
  keyUp is swallowed with its consumed keyDown. Requires Accessibility trust;
  never crashes when the tap cannot be created. `CompatEditPlan` /
  `CompatKeyClassifier` / `CompatibilityStatusText` are pure and headless-tested
  (the fixture suite is replayed through the compat pipeline as well).
* `LaunchAtLogin` — `SMAppService.mainApp` login item (status in Vietnamese),
  needed so compatibility mode survives logout/login.
* `SettingsHelpers` / `InputSourceManager` — pure, headless-testable helpers:
  install-path rules (`/Library/Input Methods` system-wide on 26+, `~/Library/Input Methods`
  otherwise), status text mapping, signing-identity and `codesign` output
  parsing, privileged-install shell/AppleScript command construction, launch
  heuristics (never show a window when `imklaunchagent` started the process;
  `--settings` shows immediately; Finder double-click shows when activated), and
  the TIS queries/actions themselves.

Runtime config file:

```json
{
  "mode": "vi",
  "method": "telex",
  "tone_style": "modern",
  "smart_english": true,
  "insert_mode": "marked",
  "hotkeys": {
    "toggle_mode": "ctrl+alt+v",
    "toggle_method": "ctrl+alt+t",
    "toggle_tone_style": "ctrl+alt+d",
    "toggle_smart": "ctrl+alt+e",
    "reload_config": "ctrl+alt+r"
  }
}
```

When the user toggles a setting at runtime, write the updated file (keep unknown
keys). The engine receives `{mode, method, tone_style, smart_english}`.

### 7.3 Swift test harness (`scripts/test-swift.sh`)

Compiles `macos/Tests/main.swift`, `MockHost.swift` and the app sources **except**
`main.swift` together with the Rust static library, then runs fixture files from
`core/tests/fixtures/`. For every fixture and for **both** insert modes
(`direct` and `marked`), it builds a fresh engine with the fixture config, feeds
the key string through `KeyHandler`, commits at the end, and compares the mock
host's resulting document text with column 3. Exit code 0 only if everything
passes. The mock host must faithfully implement marked-text semantics:

* `text` document string, `markedRange` + `markedText`;
* `setMarkedText` replaces `markedRange` (or inserts at caret), updates selection;
* `commitMarkedText` replaces `markedRange` with the text and clears it;
* `replaceTrailing(n, with:)` replaces the last `n` UTF-16 units before caret;
* after commit, caret sits at the end of inserted text.

### 7.4 Build / install

* `scripts/build.sh`: `cargo build --release` → `swiftc -O` (all app Swift
  sources, bridging header `macos/Sources/Bridging.h`,
  `-I core/include`, `-L core/target/release -ldoctkey_core`,
  `-framework Cocoa -framework InputMethodKit -framework Carbon`) → assemble
  `build/DoctKey.app` with `Resources/Info.plist` and `PkgInfo` → ad-hoc
  `codesign --force --sign -`. Must be re-runnable, `set -euo pipefail`, and
  print the artifact path.
* `scripts/install.sh`: build, quit a running copy, pick the install directory by
  macOS version (`/Library/Input Methods` on 26+, `~/Library/Input Methods` on
  13–15; `TARGET_DIR` overrides), copy + re-sign the bundle, then invoke the
  installed app's `--register-input-source` / `--enable-input-source` (best
  effort). Print: log out/in, then System Settings → Keyboard → Input Sources →
  "+" → DoctKey. Support `SIGN_ID=<cert>` for Apple Development/Developer ID
  signing instead of ad-hoc.
* `scripts/uninstall.sh`: kill the process, remove the bundle + config dir,
  print how to remove the input source in System Settings.
* `scripts/enable-input-source.swift`: a small utility (compiled on the fly)
  that calls `TISRegisterInputSource`, finds `com.doct.doctkey`, enables it with
  `TISEnableInputSource` and selects it with `TISSelectInputSource`; prints a
  clear result and always exits 0 unless the bundle is missing.

---

## 8. Acceptance criteria

1. `cargo test --manifest-path core/Cargo.toml` passes, including **all** fixtures
   in `core/tests/fixtures/` (do not edit them) plus unit tests for tone
   placement, VNI, Telex, smart fallback, backspace/escape, case.
2. `cargo build --release` produces `core/target/release/libdoctkey_core.a`.
3. `scripts/build.sh` produces `build/DoctKey.app`; `codesign -dv` shows a valid
   signature; the bundle contains the required Info.plist keys.
4. `scripts/test-swift.sh` passes all fixtures in both insert modes.
5. `scripts/install.sh` installs to the version-appropriate directory: `/Library/Input Methods/DoctKey.app` on macOS 26+ (sudo), `~/Library/Input Methods/DoctKey.app` on macOS 13–15; the app binary supports `--register-input-source`, `--enable-input-source`, `--select-input-source`, `--print-status`.
6. The app launches, keeps running, creates its `IMKServer`, and shows the menu
   bar item; it is visible to `TISCreateInputSourceList` as
   `com.doct.doctkey` (on macOS 26 this can require a logout/login).
6b. `--settings` opens the management window (`DoctKey — Cài đặt`) with the four
   tabs above; a normal (IME) launch shows no window; `scripts/test-swift.sh`
   covers the pure settings/status helpers.
6c. Without a valid Apple signature the system may never register the input
   source. In that case the CGEvent compatibility mode is the supported
   fallback: enable it in the Chung tab, grant Accessibility, use the ABC
   layout, optionally enable launch-at-login. `scripts/test-swift.sh` replays
   all fixtures through the compatibility pipeline (engine → edit plan →
   document).
7. `README.md` (Vietnamese) explains install, add input source, hotkeys, config,
   troubleshooting, uninstall.

## 9. Non-goals (v1)

* No candidate window / predictive text / spell checking.
* No iOS, no Windows, no Linux.
* No auto-update, no sandboxing, no notarization.
