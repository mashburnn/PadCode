//! The VS Code CLI's control-server protocol, answered by PadCode itself: for
//! SSH desktops (ssh.rs) and for Linux on this iPad (local.rs). `Session`
//! (remote.rs) and everything built on it work unchanged on either.

use crate::{
    rpc::{encode, next_frame},
    Error, Result,
};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    future::Future,
    sync::{
        atomic::{AtomicU32, Ordering},
        Arc, Mutex,
    },
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, DuplexStream},
    sync::mpsc,
};

/// The protocol version announced to `Rpc` (what tunnels' CLI 1.142 reports).
const PROTOCOL: u32 = 6;
pub(crate) const CHUNK: usize = 64 * 1024;

#[derive(Deserialize)]
struct Msg<P> {
    params: P,
}

#[derive(Serialize)]
struct DataOut<'a> {
    stream: u32,
    #[serde(with = "serde_bytes")]
    segment: &'a [u8],
}

#[derive(Deserialize)]
struct DataIn {
    stream: u32,
    #[serde(with = "serde_bytes")]
    segment: Vec<u8>,
}

#[derive(Deserialize)]
struct Ended {
    stream: u32,
}

#[derive(Deserialize)]
pub(crate) struct PathP {
    pub path: String,
}

#[derive(Deserialize)]
pub(crate) struct RenameP {
    pub from_path: String,
    pub to_path: String,
}

#[derive(Deserialize)]
pub(crate) struct SpawnP {
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    pub cwd: Option<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
}

#[derive(Deserialize)]
pub(crate) struct NetP {
    pub host: String,
    pub port: u16,
}

pub(crate) struct Host<B> {
    /// What answers the requests (an SSH connection, or the guest kernel).
    pub b: B,
    out: mpsc::UnboundedSender<Vec<u8>>,
    next_stream: AtomicU32,
    /// Client-to-host streams (stdin, file uploads, port traffic). Dropping a
    /// sender is the stream's end.
    inbound: Mutex<HashMap<u32, mpsc::UnboundedSender<Vec<u8>>>>,
}

/// One way of answering the control server's requests.
pub(crate) trait Backend: Send + Sync + Sized + 'static {
    fn handle(h: &Arc<Host<Self>>, method: &str, id: u32, frame: &[u8]) -> impl Future<Output = Result<Value>> + Send;
}

/// Answers `Rpc`'s requests with `b` until the session goes away. `version`
/// is what `Env.cli_version` reports ("ssh", "local").
pub(crate) async fn serve<B: Backend>(io: DuplexStream, version: &str, b: B) {
    let (mut rd, mut wr) = tokio::io::split(io);
    let (out, mut out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    tokio::spawn(async move {
        while let Some(m) = out_rx.recv().await {
            if wr.write_all(&m).await.is_err() {
                break;
            }
        }
    });
    let host = Arc::new(Host { b, out, next_stream: AtomicU32::new(0), inbound: Mutex::new(HashMap::new()) });
    host.notify("version", json!({ "version": version, "protocol_version": PROTOCOL }));
    let mut buf = Vec::new();
    let mut chunk = vec![0u8; CHUNK];
    'read: loop {
        match rd.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
        loop {
            let (p, frame) = match next_frame(&mut buf) {
                Ok(Some(f)) => f,
                Ok(None) => break,
                Err(_) => break 'read,
            };
            match p.method.as_deref() {
                Some("stream_data") => {
                    if let Ok(m) = rmp_serde::from_slice::<Msg<DataIn>>(&frame) {
                        if let Some(tx) = host.inbound.lock().unwrap().get(&m.params.stream) {
                            let _ = tx.send(m.params.segment);
                        }
                    }
                }
                Some("stream_ended") => {
                    if let Ok(m) = rmp_serde::from_slice::<Msg<Ended>>(&frame) {
                        host.inbound.lock().unwrap().remove(&m.params.stream);
                    }
                }
                Some(method) => {
                    let Some(id) = p.id else { continue };
                    let (h, method) = (host.clone(), method.to_string());
                    tokio::spawn(async move {
                        match B::handle(&h, &method, id, &frame).await {
                            Ok(v) => h.reply(id, v),
                            Err(e) => h.fail(id, &e.to_string()),
                        }
                    });
                }
                None => {}
            }
        }
    }
    // The session is gone: every process's stdin ends, as when an SSH
    // connection drops (the lease then stops what it guards).
    host.inbound.lock().unwrap().clear();
}

pub(crate) fn params<P: DeserializeOwned>(frame: &[u8]) -> Result<P> {
    rmp_serde::from_slice::<Msg<P>>(frame).map(|m| m.params).map_err(|e| Error::Protocol(e.to_string()))
}

/// POSIX single quotes. ponytail: fish reads `\'` inside quotes differently; bash, zsh and sh are fine.
pub(crate) fn q(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// `cd` into `cwd`, then `exec` the command with the extra environment.
pub(crate) fn command_line(p: &SpawnP) -> String {
    let mut s = String::new();
    if let Some(cwd) = &p.cwd {
        s += &format!("cd {} && ", q(cwd));
    }
    s += "exec ";
    if !p.env.is_empty() {
        s += "env ";
        for (k, v) in &p.env {
            s += &q(&format!("{k}={v}"));
            s.push(' ');
        }
    }
    s += &q(&p.command);
    for a in &p.args {
        s.push(' ');
        s += &q(a);
    }
    s
}

/// `uname -s; uname -r; env` output, as the control server's get_env reply.
pub(crate) fn parse_env(text: &str) -> Value {
    let mut lines = text.lines();
    let os = lines.next().unwrap_or("").trim();
    let release = lines.next().unwrap_or("").trim();
    let env: HashMap<&str, &str> = lines
        .filter_map(|l| l.split_once('='))
        .filter(|(k, _)| !k.is_empty() && !k.contains(char::is_whitespace))
        .collect();
    json!({ "env": env, "os_platform": if os == "Darwin" { "darwin" } else { "linux" }, "os_release": release })
}

impl<B> Host<B> {
    pub(crate) fn send(&self, msg: Vec<u8>) {
        let _ = self.out.send(msg);
    }
    pub(crate) fn notify(&self, method: &str, params: Value) {
        self.send(encode(None, method, params));
    }
    pub(crate) fn reply(&self, id: u32, result: Value) {
        self.send(rmp_serde::to_vec_named(&json!({ "id": id, "result": result })).unwrap_or_default());
    }
    pub(crate) fn fail(&self, id: u32, message: &str) {
        self.send(rmp_serde::to_vec_named(&json!({ "id": id, "error": { "code": -1, "message": message } })).unwrap_or_default());
    }
    pub(crate) fn stream(&self) -> u32 {
        self.next_stream.fetch_add(1, Ordering::Relaxed)
    }
    pub(crate) fn started(&self, id: u32, streams: &[u32]) {
        self.notify("streams_started", json!({ "for_request_id": id, "stream_ids": streams }));
    }
    pub(crate) fn data(&self, stream: u32, bytes: &[u8]) {
        for segment in bytes.chunks(CHUNK) {
            self.send(encode(None, "stream_data", DataOut { stream, segment }));
        }
    }
    pub(crate) fn ended(&self, stream: u32) {
        self.notify("stream_ended", json!({ "stream": stream }));
    }
    /// Registered before `streams_started` goes out, so no early bytes are lost.
    pub(crate) fn inbound(&self, stream: u32) -> mpsc::UnboundedReceiver<Vec<u8>> {
        let (tx, rx) = mpsc::unbounded_channel();
        self.inbound.lock().unwrap().insert(stream, tx);
        rx
    }
    pub(crate) fn close_inbound(&self, stream: u32) {
        self.inbound.lock().unwrap().remove(&stream);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoting_and_command_line() {
        assert_eq!(q("it's"), r"'it'\''s'");
        let p = SpawnP {
            command: "python3".into(),
            args: vec!["-c".into(), "print('hi')".into()],
            cwd: Some("/home/me/my project".into()),
            env: HashMap::from([("A".to_string(), "1 2".to_string())]),
        };
        assert_eq!(command_line(&p), r"cd '/home/me/my project' && exec env 'A=1 2' 'python3' '-c' 'print('\''hi'\'')'");
    }

    #[test]
    fn env_parsing() {
        let v = parse_env("Linux\n6.8.0-45-generic\nHOME=/home/me\nPATH=/usr/bin:/bin\n  continued line\nEMPTY=\n");
        assert_eq!(v["os_platform"], "linux");
        assert_eq!(v["os_release"], "6.8.0-45-generic");
        assert_eq!(v["env"]["HOME"], "/home/me");
        assert_eq!(v["env"]["EMPTY"], "");
        assert!(v["env"].get("  continued line").is_none());
    }
}
