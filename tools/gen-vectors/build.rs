// SPDX-License-Identifier: GPL-3.0-or-later
//! Copies upstream modules (or single items of them) into OUT_DIR so the vectors are computed by
//! upstream's own code. UPSTREAM_DIR must be a checkout of uu-remote-linux at the pinned commit.
use std::path::{Path, PathBuf};

const PINNED: &str = "5f28047a341143a033d98be95b0e8152c3e1464d";

fn main() {
    let up = PathBuf::from(std::env::var("UPSTREAM_DIR").expect("set UPSTREAM_DIR to the upstream checkout"));
    println!("cargo:rerun-if-env-changed=UPSTREAM_DIR");
    let head = std::process::Command::new("git").arg("-C").arg(&up).args(["rev-parse", "HEAD"]).output()
        .expect("git rev-parse");
    let head = String::from_utf8_lossy(&head.stdout).trim().to_string();
    assert_eq!(head, PINNED, "upstream checkout is not at the pinned commit");
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());

    // Whole module, minus inner doc comments (not allowed inside `include!`) and tests.
    let auth = read(&up, "src/auth.rs");
    std::fs::write(out.join("auth.rs"), strip(&auth)).unwrap();

    // Single items of login.rs: the module itself pulls in GTK, capture and config code.
    let login = read(&up, "src/login.rs");
    let mut items = String::new();
    for name in ["fn csrf_from_token(", "const QR_EXPIRED", "fn qr_data<", "enum QrPollAction", "fn qr_poll_action(", "fn qr_ticket("] {
        items.push_str(&extract(&login, name));
        items.push('\n');
    }
    std::fs::write(out.join("login_items.rs"), items).unwrap();

    // Wire format: protocol.rs and viewer/wire.rs are self-contained modules.
    std::fs::write(out.join("protocol.rs"), strip(&read(&up, "src/protocol.rs"))).unwrap();
    std::fs::write(out.join("wire.rs"), strip(&read(&up, "src/viewer/wire.rs"))).unwrap();
    let mut tools = String::new();
    let tools_rs = read(&up, "src/viewer/tools/mod.rs");
    for name in ["pub fn uint(", "pub fn blob(", "pub fn ints(", "pub fn nested(", "pub fn rpc("] {
        tools.push_str(&extract(&tools_rs, name));
        tools.push('\n');
    }
    tools.push_str(&extract(&read(&up, "src/viewer/tools/portmap.rs"), "pub fn frame("));
    std::fs::write(out.join("tools_items.rs"), tools).unwrap();
    let rtc = read(&up, "src/viewer/rtc.rs");
    let mut rtc_items = String::new();
    for name in ["pub fn with_max_message_size(", "fn answer_sdp("] {
        rtc_items.push_str(&extract(&rtc, name));
        rtc_items.push('\n');
    }
    std::fs::write(out.join("rtc_items.rs"), rtc_items).unwrap();
    std::fs::write(out.join("viewer_main_items.rs"), extract(&read(&up, "src/viewer_main.rs"), "const DEFAULT_SHAPE")).unwrap();
}

fn read(up: &Path, rel: &str) -> String {
    println!("cargo:rerun-if-changed={}", up.join(rel).display());
    std::fs::read_to_string(up.join(rel)).unwrap()
}

/// Drops `//!` lines and every `#[cfg(test)]` module.
fn strip(src: &str) -> String {
    let mut out = String::new();
    let mut rest = src;
    while let Some(i) = rest.find("#[cfg(test)]") {
        out.push_str(&rest[..i]);
        let body = &rest[i..];
        let open = body.find('{').unwrap();
        rest = &body[open + block_len(&body[open..])..];
    }
    out.push_str(rest);
    out.lines().filter(|l| !l.trim_start().starts_with("//!")).collect::<Vec<_>>().join("\n")
}

/// Source of the item whose header contains `needle`, with its attributes and doc comments.
fn extract(src: &str, needle: &str) -> String {
    let at = src.find(needle).unwrap_or_else(|| panic!("upstream item not found: {needle}"));
    let mut start = src[..at].rfind('\n').map_or(0, |i| i + 1);
    // Include preceding attribute and doc lines.
    while start > 0 {
        let prev_start = src[..start - 1].rfind('\n').map_or(0, |i| i + 1);
        let line = src[prev_start..start - 1].trim_start();
        if line.starts_with("#[") || line.starts_with("///") { start = prev_start; } else { break; }
    }
    let body = &src[at..];
    // `const X: &str = r#"..."#;` (raw strings may hold braces and semicolons)
    if let (Some(raw), Some(eq)) = (body.find("r#\""), body.find('=')) {
        if raw < body.find(';').unwrap_or(usize::MAX) && eq < raw {
            let end = at + body.find("\"#;").expect("unterminated raw string") + 3;
            return src[start..end].to_string();
        }
    }
    let semi = body.find(';');
    let open = body.find('{');
    let end = match (open, semi) {
        (Some(o), Some(s)) if s < o => at + s + 1,
        (Some(o), _) => at + o + block_len(&body[o..]),
        (None, Some(s)) => at + s + 1,
        _ => panic!("unterminated item {needle}"),
    };
    src[start..end].to_string()
}

/// Length of the balanced `{...}` block at the start of `s`, skipping string and char literals.
fn block_len(s: &str) -> usize {
    let b = s.as_bytes();
    let (mut depth, mut i) = (0i32, 0usize);
    while i < b.len() {
        match b[i] {
            b'"' => {
                i += 1;
                while b[i] != b'"' { if b[i] == b'\\' { i += 1; } i += 1; }
            }
            b'\'' if i + 2 < b.len() && (b[i + 2] == b'\'' || b[i + 1] == b'\\') => {
                i += if b[i + 1] == b'\\' { 3 } else { 2 };
                while b[i] != b'\'' { i += 1; }
            }
            b'/' if b.get(i + 1) == Some(&b'/') => { while b[i] != b'\n' { i += 1; } }
            b'{' => depth += 1,
            b'}' => { depth -= 1; if depth == 0 { return i + 1; } }
            _ => {}
        }
        i += 1;
    }
    panic!("unbalanced block");
}
