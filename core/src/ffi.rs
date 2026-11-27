//! The `extern "C"` layer implementing the frozen C ABI in
//! `core/include/doctkey.h`.
//!
//! This is the only module in the crate that is allowed to contain `unsafe`
//! code (the crate denies `unsafe_code` elsewhere). Every function returning
//! `char *` hands out a heap-allocated `CString` that the caller must free with
//! [`doctkey_string_free`]; no function ever returns NULL. Panics are caught at
//! the boundary so a bug can never unwind into the Swift host.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::engine::Engine;

/// Opaque engine handle exposed to C (`DoctKeyEngine *` in `doctkey.h`).
pub struct DoctKeyEngine {
    engine: Engine,
}

/// JSON returned if a call inside the FFI boundary panics.
const FALLBACK_JSON: &str = concat!(
    r#"{"op":"pass","text":"","word":"","raw":"","composing":false,"consumed":false,"#,
    r#""mode":"vi","method":"telex","tone_style":"modern","smart":true}"#
);

/// Statically allocated version string (`"0.1.0\0"`), as promised by the header.
const VERSION: &[u8] = b"0.1.0\0";

/// Move a Rust JSON string into a caller-owned C string.
///
/// Interior NUL bytes cannot appear in our JSON, but they are stripped anyway so
/// the conversion can never fail.
fn json_to_c(json: String) -> *mut c_char {
    let bytes = if json.as_bytes().contains(&0) {
        json.replace('\0', "").into_bytes()
    } else {
        json.into_bytes()
    };
    match CString::new(bytes) {
        Ok(cstring) => cstring.into_raw(),
        Err(_) => CString::new(FALLBACK_JSON).unwrap_or_default().into_raw(),
    }
}

/// Read a caller-provided C string; NULL becomes `""`.
///
/// # Safety
///
/// `pointer` must be NULL or point to a valid NUL-terminated string.
unsafe fn read_c_string(pointer: *const c_char) -> String {
    if pointer.is_null() {
        return String::new();
    }
    // SAFETY: the caller guarantees a valid NUL-terminated string (header
    // contract); `to_string_lossy` tolerates invalid UTF-8.
    let cstr = unsafe { CStr::from_ptr(pointer) };
    cstr.to_string_lossy().into_owned()
}

/// Run `task`, converting its JSON to a C string; panics become a `pass` JSON.
fn guarded<F: FnOnce() -> String>(task: F) -> *mut c_char {
    let json = catch_unwind(AssertUnwindSafe(task)).unwrap_or_else(|_| FALLBACK_JSON.to_owned());
    json_to_c(json)
}

/// Create an engine. `config_json` may be NULL or `""`; invalid JSON falls back
/// to the defaults.
///
/// # Safety
///
/// `config_json` must be NULL or a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub extern "C" fn doctkey_engine_new(config_json: *const c_char) -> *mut DoctKeyEngine {
    // SAFETY: documented pointer contract of the C ABI.
    let config = unsafe { read_c_string(config_json) };
    Box::into_raw(Box::new(DoctKeyEngine {
        engine: Engine::new(&config),
    }))
}

/// Destroy an engine. Passing NULL is a no-op.
///
/// # Safety
///
/// `engine` must be a pointer returned by [`doctkey_engine_new`] that has not
/// been freed yet.
#[no_mangle]
pub extern "C" fn doctkey_engine_free(engine: *mut DoctKeyEngine) {
    if engine.is_null() {
        return;
    }
    // SAFETY: pointer originated from `Box::into_raw` in `doctkey_engine_new`.
    unsafe { drop(Box::from_raw(engine)) };
}

/// Merge new settings into the config. Returns 1 on success, 0 on bad JSON or a
/// NULL engine (the previous config is kept).
///
/// # Safety
///
/// `engine` must be a live engine pointer; `config_json` must be NULL or a valid
/// NUL-terminated string.
#[no_mangle]
pub extern "C" fn doctkey_engine_set_config(
    engine: *mut DoctKeyEngine,
    config_json: *const c_char,
) -> i32 {
    if engine.is_null() {
        return 0;
    }
    // SAFETY: documented pointer contracts.
    let config = unsafe { read_c_string(config_json) };
    // SAFETY: engine is non-null and not aliased (single-threaded contract).
    let engine = unsafe { &mut *engine };
    let ok = catch_unwind(AssertUnwindSafe(|| engine.engine.set_config(&config))).unwrap_or(false);
    i32::from(ok)
}

/// Feed one Unicode scalar (the character the user typed, case included).
///
/// # Safety
///
/// `engine` must be a live engine pointer.
#[no_mangle]
pub extern "C" fn doctkey_feed_char(
    engine: *mut DoctKeyEngine,
    ch: u32,
    flags: u32,
) -> *mut c_char {
    guarded(|| {
        // SAFETY: documented pointer contract.
        let Some(engine) = (unsafe { engine.as_mut() }) else {
            return FALLBACK_JSON.to_owned();
        };
        let ch = char::from_u32(ch).unwrap_or('\u{fffd}');
        let result = engine.engine.feed_char(ch, flags);
        result.to_json(engine.engine.config())
    })
}

/// Feed a non-printing key (1 = backspace, 2 = delete, 3 = escape, 4 = return,
/// 5 = tab, 6 = caret movement / other command key).
///
/// # Safety
///
/// `engine` must be a live engine pointer.
#[no_mangle]
pub extern "C" fn doctkey_feed_key(engine: *mut DoctKeyEngine, key: u32) -> *mut c_char {
    guarded(|| {
        // SAFETY: documented pointer contract.
        let Some(engine) = (unsafe { engine.as_mut() }) else {
            return FALLBACK_JSON.to_owned();
        };
        let result = engine.engine.feed_key(key);
        result.to_json(engine.engine.config())
    })
}

/// Commit the current composition. Returns `op:"commit"` (or `op:"none"` when
/// there is nothing to commit).
///
/// # Safety
///
/// `engine` must be a live engine pointer.
#[no_mangle]
pub extern "C" fn doctkey_commit(engine: *mut DoctKeyEngine) -> *mut c_char {
    guarded(|| {
        // SAFETY: documented pointer contract.
        let Some(engine) = (unsafe { engine.as_mut() }) else {
            return FALLBACK_JSON.to_owned();
        };
        let result = engine.engine.commit();
        result.to_json(engine.engine.config())
    })
}

/// Throw away composition state without touching the screen.
///
/// # Safety
///
/// `engine` must be a live engine pointer or NULL.
#[no_mangle]
pub extern "C" fn doctkey_reset(engine: *mut DoctKeyEngine) {
    if engine.is_null() {
        return;
    }
    // SAFETY: documented pointer contract.
    let engine = unsafe { &mut *engine };
    let _ = catch_unwind(AssertUnwindSafe(|| engine.engine.reset()));
}

/// Execute a command object, e.g. `{"cmd":"toggle_mode"}`.
///
/// # Safety
///
/// `engine` must be a live engine pointer; `command_json` must be NULL or a
/// valid NUL-terminated string.
#[no_mangle]
pub extern "C" fn doctkey_command(
    engine: *mut DoctKeyEngine,
    command_json: *const c_char,
) -> *mut c_char {
    // SAFETY: documented pointer contract.
    let command = unsafe { read_c_string(command_json) };
    guarded(|| {
        // SAFETY: documented pointer contract.
        let Some(engine) = (unsafe { engine.as_mut() }) else {
            return FALLBACK_JSON.to_owned();
        };
        let result = engine.engine.command(&command);
        result.to_json(engine.engine.config())
    })
}

/// Current state snapshot (`op:"state"`).
///
/// # Safety
///
/// `engine` must be a live engine pointer.
#[no_mangle]
pub extern "C" fn doctkey_status(engine: *mut DoctKeyEngine) -> *mut c_char {
    guarded(|| {
        // SAFETY: documented pointer contract.
        let Some(engine) = (unsafe { engine.as_ref() }) else {
            return FALLBACK_JSON.to_owned();
        };
        let result = engine.engine.status();
        result.to_json(engine.engine.config())
    })
}

/// Version string ("0.1.0"). Statically allocated; do not free.
#[no_mangle]
pub extern "C" fn doctkey_version() -> *const c_char {
    VERSION.as_ptr().cast()
}

/// Free a string returned by any of the functions above. NULL is a no-op.
///
/// # Safety
///
/// `s` must be NULL or a pointer previously returned by this library that has
/// not been freed yet.
#[no_mangle]
pub extern "C" fn doctkey_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    // SAFETY: pointer originated from `CString::into_raw` in `json_to_c`.
    unsafe { drop(CString::from_raw(s)) };
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    /// Owns a C string returned by the ABI and frees it on drop.
    struct Owned(*mut c_char);

    impl Owned {
        fn new(pointer: *mut c_char) -> Owned {
            assert!(!pointer.is_null(), "ABI must never return NULL");
            Owned(pointer)
        }

        fn as_str(&self) -> &str {
            // SAFETY: pointer is valid until drop.
            unsafe { CStr::from_ptr(self.0) }
                .to_str()
                .expect("ABI returns UTF-8 JSON")
        }
    }

    impl Drop for Owned {
        fn drop(&mut self) {
            doctkey_string_free(self.0);
        }
    }

    fn cstring(text: &str) -> CString {
        CString::new(text).expect("test string without NUL")
    }

    #[test]
    fn version_is_static_and_correct() {
        // SAFETY: doctkey_version returns a static NUL-terminated string.
        let version = unsafe { CStr::from_ptr(doctkey_version()) };
        assert_eq!(version.to_str().unwrap(), "0.1.0");
    }

    #[test]
    fn engine_lifecycle_and_feed() {
        let config = cstring(r#"{"mode":"vi","method":"telex","smart_english":true}"#);
        let engine = doctkey_engine_new(config.as_ptr());
        assert!(!engine.is_null());

        let v = Owned::new(doctkey_feed_char(engine, u32::from('v'), 0));
        assert!(v.as_str().contains(r#""op":"append""#));
        let i = Owned::new(doctkey_feed_char(engine, u32::from('i'), 0));
        assert!(i.as_str().contains(r#""text":"i""#));
        let commit = Owned::new(doctkey_commit(engine));
        assert!(commit.as_str().contains(r#""op":"commit""#));
        let status = Owned::new(doctkey_status(engine));
        assert!(status.as_str().contains(r#""op":"state""#));

        doctkey_engine_free(engine);
    }

    #[test]
    fn null_pointers_are_tolerated() {
        let engine = doctkey_engine_new(std::ptr::null());
        assert!(!engine.is_null());
        assert_eq!(doctkey_engine_set_config(engine, std::ptr::null()), 0);
        let pass = Owned::new(doctkey_feed_char(engine, u32::from('a'), 0));
        assert!(pass.as_str().contains(r#""op":"append""#));
        doctkey_reset(engine);
        doctkey_engine_free(engine);
        doctkey_engine_free(std::ptr::null_mut());
        doctkey_reset(std::ptr::null_mut());
        doctkey_string_free(std::ptr::null_mut());
        // A NULL engine yields the safe fallback instead of crashing.
        let fallback = Owned::new(doctkey_feed_key(std::ptr::null_mut(), 1));
        assert!(fallback.as_str().contains(r#""op":"pass""#));
    }

    #[test]
    fn config_and_command_work_through_the_abi() {
        let engine = doctkey_engine_new(std::ptr::null());
        let config = cstring(r#"{"method":"vni"}"#);
        assert_eq!(doctkey_engine_set_config(engine, config.as_ptr()), 1);
        let bad = cstring("{");
        assert_eq!(doctkey_engine_set_config(engine, bad.as_ptr()), 0);

        let command = cstring(r#"{"cmd":"set_mode","mode":"en"}"#);
        let result = Owned::new(doctkey_command(engine, command.as_ptr()));
        assert!(result.as_str().contains(r#""op":"state""#));
        assert!(result.as_str().contains(r#""mode":"en""#));

        let garbage = cstring("not json at all");
        let result = Owned::new(doctkey_command(engine, garbage.as_ptr()));
        assert!(result.as_str().contains(r#""op":"state""#));

        // Invalid scalar values must not panic.
        let result = Owned::new(doctkey_feed_char(engine, 0x0011_0000, 0));
        assert!(!result.as_str().is_empty());

        doctkey_engine_free(engine);
    }
}
