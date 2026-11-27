//! DoctKey — the linguistic core of a personal Vietnamese + English input
//! method for macOS.
//!
//! The engine is a deterministic, single-threaded state machine: the host feeds
//! one keystroke at a time and receives a small JSON description telling it what
//! to do with the text on screen (`append`, `replace`, `commit`, `pass` or
//! `none`). The full contract lives in `docs/SPEC.md`; the frozen C ABI lives in
//! `core/include/doctkey.h`.
//!
//! # Architecture
//!
//! * [`config`] — engine-wide settings (mode / method / tone style / smart).
//! * [`letters`] — the letter model (base letter + quality mark) and the
//!   precomposed Vietnamese rendering tables.
//! * [`telex`], [`vni`] — the two operator sets, replaying raw keys into letters.
//! * [`tone`] — tone-mark placement rules (SPEC §5.3).
//! * [`syllable`] — Vietnamese syllable validity used by the smart English
//!   fallback (SPEC §5.5).
//! * [`engine`] — the per-word state machine: raw keystrokes in, results out.
//! * [`sim`] — reference host simulation used by tests and the CLI (SPEC §6).
//! * [`ffi`] — the `extern "C"` layer (the only module with `unsafe` code).
//!
//! # Example
//!
//! ```
//! use doctkey_core::Engine;
//!
//! let mut engine = Engine::new(r#"{"mode":"vi","method":"telex"}"#);
//! for ch in "vieejt".chars() {
//!     engine.feed_char(ch, 0);
//! }
//! assert_eq!(engine.word(), "việt");
//! ```
//!
//! The crate only depends on `serde_json`; it deliberately avoids `serde`
//! derive, async runtimes and global mutable state. The syllable validity table
//! is built lazily once and then read-only, so behaviour stays deterministic.

#![deny(unsafe_code)]

pub mod config;
pub mod english_words;
pub mod engine;
pub mod letters;
pub mod sim;
pub mod syllable;
pub mod telex;
pub mod tone;
pub mod vni;

// The C ABI layer is the single place where `unsafe` is allowed.
#[allow(unsafe_code)]
pub mod ffi;

pub use config::{Config, Method, Mode, ToneStyle};
pub use engine::{Engine, KeyResult, Op};

/// Semantic version of the engine, e.g. `"0.1.0"`.
pub const VERSION: &str = "0.1.0";
