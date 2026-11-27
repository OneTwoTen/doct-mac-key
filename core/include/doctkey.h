/*
 * doctkey.h — C ABI for the DoctKey Vietnamese/English input engine.
 *
 * The engine is a pure state machine: it consumes keystrokes and returns
 * JSON descriptions of what the host (a macOS InputMethodKit controller)
 * should do with the text on screen.
 *
 * Contract rules:
 *  - Every function returning `char *` returns a heap-allocated, NUL-terminated
 *    UTF-8 JSON string owned by the caller. Free it with doctkey_string_free().
 *  - It never returns NULL. On internal failure it returns a JSON object with
 *    {"op":"pass","consumed":false,...}.
 *  - The engine is not thread-safe; use it from one thread (the main thread).
 *  - Callers must treat the returned JSON as read-only.
 */
#ifndef DOCTKEY_H
#define DOCTKEY_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DoctKeyEngine DoctKeyEngine;

/* ------------------------------------------------------------------ */
/* Lifecycle                                                          */
/* ------------------------------------------------------------------ */

/* Create an engine. `config_json` is an optional UTF-8 JSON object
 * (may be NULL or ""). Invalid JSON falls back to defaults. */
DoctKeyEngine *doctkey_engine_new(const char *config_json);

void doctkey_engine_free(DoctKeyEngine *engine);

/* Merge new settings into the config. Returns 1 on success, 0 on bad JSON
 * (in which case the previous config is kept). */
int32_t doctkey_engine_set_config(DoctKeyEngine *engine, const char *config_json);

/* ------------------------------------------------------------------ */
/* Keystroke processing                                               */
/* ------------------------------------------------------------------ */

/* Feed one Unicode scalar (the character the user typed, already carrying
 * its case, e.g. 'A' when Shift is held or Caps Lock is on).
 * `flags` is reserved: bit0 = shift, bit1 = caps lock, bit2 = option.
 * Result JSON: see docs/SPEC.md §3. */
char *doctkey_feed_char(DoctKeyEngine *engine, uint32_t ch, uint32_t flags);

/* Feed a non-printing key.
 *   1 = backspace (delete backwards)
 *   2 = forward delete
 *   3 = escape
 *   4 = return / enter
 *   5 = tab
 *   6 = caret movement / other command key
 * Result JSON: see docs/SPEC.md §3. */
char *doctkey_feed_key(DoctKeyEngine *engine, uint32_t key);

/* Commit the current composition right now (focus loss, menu action, ...).
 * When a word is being composed the result has op="commit" with the final text
 * in "text"; when there is nothing to commit the result is op="none". */
char *doctkey_commit(DoctKeyEngine *engine);

/* Throw away composition state without touching the text on screen
 * (e.g. the user clicked elsewhere and the controller lost track). */
void doctkey_reset(DoctKeyEngine *engine);

/* ------------------------------------------------------------------ */
/* Commands / introspection                                           */
/* ------------------------------------------------------------------ */

/* Execute a command object, e.g. {"cmd":"toggle_mode"}.
 * Returns the same JSON shape as a feed result (op="state" when the command
 * does not change the screen text). See docs/SPEC.md §4. */
char *doctkey_command(DoctKeyEngine *engine, const char *command_json);

/* Current state snapshot (op="state", no text changes). */
char *doctkey_status(DoctKeyEngine *engine);

/* Version string, e.g. "0.1.0". Statically allocated; do not free. */
const char *doctkey_version(void);

/* Free a string returned by any of the functions above. */
void doctkey_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* DOCTKEY_H */
