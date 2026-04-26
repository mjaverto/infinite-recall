//! Output rendering — two modes, no TTY detection.
//!
//! - default: a compact line-oriented view tuned for eyeballing in a terminal.
//! - `--json`: pretty-printed JSON straight from the API (stable shape).
//!
//! Per the design: agents are told via `AGENTS.md` to always pass `--json`.
//! Predictable beats clever — we don't auto-switch on `isatty`.

use serde_json::Value;

/// Render `value` either as pretty JSON (when `json` is true) or via the
/// supplied human renderer.
pub fn emit(json: bool, value: &Value, human: impl FnOnce(&Value)) {
    if json {
        match serde_json::to_string_pretty(value) {
            Ok(s) => println!("{s}"),
            Err(_) => println!("{value}"),
        }
    } else {
        human(value);
    }
}

/// Truncate a string to `max` *characters* (not bytes), appending `…` when
/// shortened. Avoids panics on multi-byte input.
pub fn truncate(s: &str, max: usize) -> String {
    let count = s.chars().count();
    if count <= max {
        return s.to_string();
    }
    if max == 0 {
        return String::new();
    }
    let mut out: String = s.chars().take(max - 1).collect();
    out.push('…');
    out
}

/// Read a string field from a JSON object, returning `"-"` if missing/null.
pub fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(|x| x.as_str()).unwrap_or("-")
}

/// Read an integer field as a string (`"-"` if missing/null).
pub fn i(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(|x| x.as_i64())
        .map(|n| n.to_string())
        .unwrap_or_else(|| "-".into())
}

/// Read a boolean field with a `false` default.
pub fn b(v: &Value, key: &str) -> bool {
    v.get(key).and_then(|x| x.as_bool()).unwrap_or(false)
}

/// Read an f64 field with a `0.0` default.
pub fn f(v: &Value, key: &str) -> f64 {
    v.get(key).and_then(|x| x.as_f64()).unwrap_or(0.0)
}
