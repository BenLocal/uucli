// SPDX-License-Identifier: GPL-3.0-or-later
//! Writes uucli golden vectors (tests/vectors/*.json) from upstream code. Usage:
//!   UPSTREAM_DIR=/path/to/uu-remote-linux cargo run -- ../../tests/vectors
#![allow(dead_code)]

mod auth {
    include!(concat!(env!("OUT_DIR"), "/auth.rs"));
}

mod i18n {
    /// Upstream picks the UI language; vectors use the English text.
    pub fn s(_zh: &'static str, en: &'static str) -> &'static str { en }
}

mod login {
    use serde_json::Value;
    use std::time::Duration;
    include!(concat!(env!("OUT_DIR"), "/login_items.rs"));

    pub fn poll(last: i64, status: u16, body: &Value) -> Value {
        use serde_json::json;
        match qr_poll_action(last, status, body) {
            QrPollAction::Wait(s) => json!({"wait": s}),
            QrPollAction::Scanned => json!("scanned"),
            QrPollAction::Confirmed => json!("confirmed"),
            QrPollAction::Refresh(d) => json!({"refresh": d.as_millis() as u64}),
            QrPollAction::Failed(reason) => json!({"failed": match reason {
                "QR code expired" => "expired",
                "QR status check failed" => "query_failed",
                "Unexpected QR status response" => "unexpected",
                other => panic!("unknown failure {other}"),
            }}),
        }
    }
    pub fn csrf(token: &str) -> Option<String> { csrf_from_token(token) }
    pub fn ticket(gen: &Value) -> Option<String> { qr_ticket(gen).map(str::to_owned) }
}

mod protocol {
    include!(concat!(env!("OUT_DIR"), "/protocol.rs"));
}

mod viewer {
    pub mod wire {
        include!(concat!(env!("OUT_DIR"), "/wire.rs"));
    }
    pub mod tools {
        use super::wire;
        use crate::protocol::{decode_wire, WireValue};
        include!(concat!(env!("OUT_DIR"), "/tools_items.rs"));
    }
    pub mod rtc {
        use serde_json::Value;
        include!(concat!(env!("OUT_DIR"), "/rtc_items.rs"));
        pub fn answer(body: &Value) -> Result<String, String> { answer_sdp(body) }
    }
    include!(concat!(env!("OUT_DIR"), "/viewer_main_items.rs"));
    /// The shape `tool_command` (src/viewer_main.rs) builds for a tool session.
    pub fn tool_shape(capture: u32) -> wire::Shape {
        let mut shape: wire::Shape = serde_json::from_str(DEFAULT_SHAPE).unwrap();
        shape.capture_type = capture;
        shape.feature_flag.clear();
        if capture != 5 { shape.decoders.clear(); shape.display_modes.clear(); shape.displays.clear(); shape.codecs.clear(); }
        shape
    }
}

use serde_json::{json, Value};
use std::collections::BTreeMap;

fn creds(v: &Value) -> auth::Credentials {
    let g = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    auth::Credentials {
        user_id: g("user_id"), device_id: g("device_id"), client_id: g("client_id"), system_id: g("system_id"),
        token: g("token"), csrf: g("csrf"),
        sign_key: Some(g("sign_key")).filter(|k| !k.is_empty()).unwrap_or_else(|| auth::DEFAULT_SIGN_KEY.into()),
    }
}

fn auth_vectors() -> Value {
    let mut signs = Vec::new();
    let cases: Vec<(&str, &str, &str, Vec<(&str, &str)>, &str)> = vec![
        ("fixture-key", "POST", "/api/v1/qrcode/gen/login", vec![("x-param-plat", "1"), ("x-param-ts", "1700000000")], ""),
        ("fixture-key", "post", "/api/v1/device/windows/init", vec![("x-param-ts", "1"), ("x-param-client-id", "c"), ("x-param-cnt", "CN")], "{\"name\":\"uucli@h\"}"),
        (auth::DEFAULT_SIGN_KEY, "GET", "/api/v1/device/list", vec![("x-param-vn", "4.42.0.2770"), ("x-param-user-id", "u1"), ("x-param-ts", "1700000001")], ""),
        (auth::DEFAULT_SIGN_KEY, "POST", "/api/v1/room/join/by_device/abc", vec![("x-param-ts", "9")], "{\"force_join\":false}"),
        ("k", "POST", "/p", vec![], "中文 body"),
    ];
    for (key, method, path, params, body) in cases {
        let client = auth::UUAuthClient::new(auth::Credentials { sign_key: key.into(), ..Default::default() });
        let map: BTreeMap<String, String> = params.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        signs.push(json!({"key": key, "method": method, "path": path, "params": map, "body": body,
            "sign": client.sign_request(method, path, &map, body)}));
    }

    let mut headers = Vec::new();
    let configs = [
        json!({"client_id": "0b9c1d7e-3f42-4a8e-9d1a-2b3c4d5e6f70", "system_id": "0B9C1D7E-3F42-4A8E-9D1A-2B3C4D5E6F71"}),
        json!({"client_id": "c", "system_id": "S", "device_id": "d", "user_id": "u", "token": "h.p.s", "csrf": "x"}),
        json!({"client_id": "c", "device_id": "d", "sign_key": "fixture-key"}),
    ];
    for (cfg, method, path, body) in [
        (&configs[0], "POST", "/api/v1/qrcode/gen/login", ""),
        (&configs[1], "GET", "/api/v1/device/list", ""),
        (&configs[1], "POST", "/api/v1/room/join/by_device/abc", "{\"force_join\":false}"),
        (&configs[2], "POST", "/api/v1/qrcode/login/status", "{\"login_status\":1}"),
    ] {
        let client = auth::UUAuthClient::new(creds(cfg));
        let map: BTreeMap<String, String> = client.build_headers(method, path, body).iter()
            .map(|(k, v)| (k.as_str().to_string(), v.to_str().unwrap().to_string())).collect();
        headers.push(json!({"config": cfg, "method": method, "path": path, "body": body, "headers": map}));
    }

    use base64::Engine as _;
    let b64 = |s: &str| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(s);
    let tokens = [
        format!("h.{}.s", b64(r#"{"sub":"u","csrf":"c-1"}"#)),
        format!("h.{}==.s", b64(r#"{"csrf":"padded"}"#)),
        format!("h.{}.s", b64(r#"{"sub":"u"}"#)),
        format!("h.{}.s", b64(r#"{"csrf":5}"#)),
        "bad".to_string(),
        "h.!!!.s".to_string(),
    ];
    let csrf: Vec<Value> = tokens.iter().map(|t| json!({"token": t, "csrf": login::csrf(t)})).collect();

    let mut poll = Vec::new();
    let bodies = [
        json!({"code": 0, "data": {"status": 0}}), json!({"code": 0, "data": {"status": 1}}),
        json!({"code": 0, "data": {"status": 2}}), json!({"code": 0, "data": {"status": 3}}),
        json!({"code": 0, "data": {"status": 4}}), json!({"code": 0, "data": {"status": 5}}),
        json!({"code": 0, "data": {"status": "4"}}), json!({"code": 0, "data": {}}), json!({"code": 0}),
        json!({"code": 0, "data": null}), json!({"code": 1190}), json!({"code": 1190, "data": {"status": 4}}),
        json!({"code": 1}), json!(null), json!({}),
    ];
    for last in [1, 2] {
        for status in [200u16, 400, 503] {
            for body in &bodies {
                poll.push(json!({"last": last, "http_status": status, "body": body, "action": login::poll(last, status, body)}));
            }
        }
    }

    let tickets: Vec<Value> = [
        json!({"token": "old", "status_query_ticket": "new"}), json!({"token": "old"}),
        json!({"status_query_ticket": ""}), json!({"status_query_ticket": "", "token": "old"}), json!({}),
    ].iter().map(|g| json!({"gen": g, "ticket": login::ticket(g)})).collect();

    json!({"sign": signs, "headers": headers, "csrf": csrf, "qr_poll": poll, "qr_ticket": tickets})
}

fn wire_vectors() -> Value {
    use viewer::{rtc, tools, wire};
    let hex = |b: &[u8]| hex::encode(b);
    let varints: Vec<Value> = [0u64, 1, 127, 128, 300, 16383, 16384, u32::MAX as u64, u64::MAX >> 1, u64::MAX].iter()
        .map(|&n| { let mut out = Vec::new(); wire::varint(n, &mut out); json!({"value": n.to_string(), "hex": hex(&out)}) }).collect();
    let envelopes: Vec<Value> = [(0u64, 27u32, &b""[..]), (1, 3, &b"\x08\x00"[..]), (1000005, 3, &b"abc"[..]), (300, 21, &[0u8; 200][..])].iter()
        .map(|(seq, kind, payload)| json!({"seq": seq, "kind": kind, "payload": hex(payload), "hex": hex(&wire::envelope(*seq, *kind, payload))})).collect();
    let device = "aeawswhnguarjyo6";
    let app = "0b9c1d7e-3f42-4a8e-9d1a-2b3c4d5e6f70";
    let sessions: Vec<Value> = [5u32, 8, 9].iter().map(|&c| {
        let shape = viewer::tool_shape(c);
        shape.validate_session().unwrap();
        let control = shape.control("unused-client", app, "unused-ice").unwrap();
        json!({"capture_type": c, "device_id": device, "app_control_id": app,
            "connect_options": hex(&shape.connect_options(device, false).unwrap()), "control": control.to_string()})
    }).collect();
    let mut matches = Vec::new();
    let mut action = Vec::new(); wire::int(1, 1, &mut action); wire::bytes(2, br#"{"seq":7}"#, &mut action);
    let reply7 = wire::envelope(99, 3, &action);
    let mut action0 = Vec::new(); wire::bytes(4, &[8, 6], &mut action0);
    let implicit_request = wire::envelope(42, 3, &action0);
    let mut bad_then_good = Vec::new(); wire::int(1, 9, &mut bad_then_good); wire::bytes(3, &[255], &mut bad_then_good); wire::bytes(3, &[8, 0], &mut bad_then_good);
    let mut two = Vec::new(); wire::int(1, 5, &mut two); wire::bytes(3, &[8, 2], &mut two); wire::bytes(3, &[8, 0], &mut two);
    for (data, seq) in [(reply7.clone(), 7u64), (reply7.clone(), 99), (wire::echo_request(7), 7), (wire::echo_response(1000001, 1), 1),
        (vec![255u8], 7), (implicit_request.clone(), 42), (bad_then_good.clone(), 9), (two.clone(), 5)] {
        matches.push(json!({"hex": hex(&data), "seq": seq, "matches": wire::echo_matches(&data, seq), "request_seq": wire::echo_request_seq(&data)}));
    }
    let frames: Vec<Value> = [(1u64, 1u64, 2u64, 0u64, br#"{"version":1,"target_host":"127.0.0.1","target_port":22}"#.to_vec()),
        (1, 1, 2, 2, vec![0u8, 1, 2, 255]), (1, 3, 700, 1, vec![]), (1, 1, 2, 2, vec![7u8; 16384])].iter()
        .map(|(s, r, st, k, p)| json!({"session": s, "rule": r, "stream": st, "type": k, "payload": hex(p), "hex": hex(&tools::frame(*s, *r, *st, *k, p))})).collect();
    let rpcs: Vec<Value> = [(11u64, false, 5u32, &b""[..]), (2000001, true, 9, &b"\x08\x01"[..])].iter()
        .map(|(id, resp, case, body)| json!({"id": id, "response": resp, "case": case, "body": hex(body), "hex": hex(&tools::rpc(*id, *resp, *case, body))})).collect();
    let decode: Vec<Value> = [hex(&reply7), hex(&tools::frame(1, 1, 2, 2, b"x")), "ff".into(), "".into(), "0801".into(), "08".into(), "1a05616263".into(), "0d01020304".into(), "1b".into()].iter()
        .map(|h| { let b = hex::decode(h).unwrap();
            let fields: Option<Vec<Value>> = protocol::decode_wire(&b).ok().map(|f| f.iter().map(|x| json!({"number": x.number, "value": match x.value {
                protocol::WireValue::Varint(v) => json!({"varint": v.to_string()}), protocol::WireValue::Bytes(v) => json!({"bytes": hex(v)}),
                protocol::WireValue::Fixed32(v) => json!({"fixed32": hex(&v)}), protocol::WireValue::Fixed64(v) => json!({"fixed64": hex(&v)})}})).collect());
            json!({"hex": h, "fields": fields, "uint1": tools::uint(&b, 1).to_string(), "uint4": tools::uint(&b, 4).to_string(),
                "blob3": tools::blob(&b, 3).map(hex), "blob27": tools::blob(&b, 27).map(hex)}) }).collect();
    let sdps: Vec<Value> = ["m=application 9\r\na=sctp-port:5000\r\na=mid:0\r\n", "a=max-message-size:1\r\n", "a=sctp-port:5000\na=mid:0\n", "a=sctp-port:1 \r\n"].iter()
        .map(|s| json!({"sdp": s, "out": rtc::with_max_message_size(s)})).collect();
    use base64::Engine as _; use std::io::Write as _;
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    gz.write_all(b"v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n").unwrap();
    let gz = base64::engine::general_purpose::STANDARD.encode(gz.finish().unwrap());
    let answers: Vec<Value> = [json!({"sdp": "v=0\r\n"}), json!({"gzip_sdp": gz}), json!({"sdp": 5, "gzip_sdp": gz}), json!({"gzip_sdp": "invalid!"}), json!({})].iter()
        .map(|b| json!({"body": b, "sdp": rtc::answer(b).ok()})).collect();
    json!({"varint": varints, "envelope": envelopes, "sessions": sessions, "echo_request_1": hex(&wire::echo_request(1)),
        "echo_response": hex(&wire::echo_response(1000005, 5)), "echo": matches, "port_frame": frames, "rpc": rpcs,
        "decode": decode, "max_message_size": sdps, "answer_sdp": answers})
}

fn main() {
    let dir = std::env::args().nth(1).expect("usage: gen-vectors OUT_DIR");
    let write = |name: &str, v: Value| {
        let path = std::path::Path::new(&dir).join(name);
        std::fs::write(&path, serde_json::to_string_pretty(&v).unwrap() + "\n").unwrap();
        eprintln!("wrote {}", path.display());
    };
    write("auth.json", auth_vectors());
    write("wire.json", wire_vectors());
}
