//! Client side of the VS Code CLI's msgpack RPC (`cli/src/rpc.rs`, `msgpack_rpc.rs`).
//!
//! Wire format: back-to-back msgpack maps, no length prefix.
//! Requests `{id, method, params}`, replies `{id, result}` / `{id, error}`.
//! Duplex methods (fs_read, fs_write, spawn) first get a server-sent
//! `streams_started {for_request_id, stream_ids}`, then bytes flow both ways as
//! `stream_data {stream, segment}` until `stream_ended {stream}`.

use crate::{Error, Result};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{
    collections::HashMap,
    io,
    sync::{
        atomic::{AtomicBool, AtomicU32, Ordering},
        Arc, Mutex,
    },
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::{mpsc, oneshot},
};

/// Longest wait for a plain (non-streaming) call's reply.
const CALL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// Segment size for outgoing stream data.
const CHUNK: usize = 64 * 1024;

#[derive(Deserialize, Debug, Default)]
pub(crate) struct Partial {
    pub id: Option<u32>,
    pub method: Option<String>,
    pub error: Option<RpcError>,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub(crate) struct RpcError {
    pub code: i32,
    pub message: String,
}

#[derive(Deserialize, Debug, Clone)]
pub struct VersionInfo {
    pub version: String,
    pub protocol_version: u32,
}

#[derive(Serialize)]
struct Request<'a, P> {
    id: Option<u32>,
    method: &'a str,
    params: P,
}

#[derive(Deserialize)]
struct Notification<P> {
    params: P,
}

#[derive(Deserialize)]
struct Reply<R> {
    result: R,
}

#[derive(Deserialize)]
struct StreamsStarted {
    for_request_id: u32,
    stream_ids: Vec<u32>,
}

#[derive(Deserialize)]
struct StreamDataIn {
    stream: u32,
    #[serde(with = "serde_bytes")]
    segment: Vec<u8>,
}

#[derive(Serialize)]
struct StreamDataOut<'a> {
    stream: u32,
    #[serde(with = "serde_bytes")]
    segment: &'a [u8],
}

#[derive(Serialize, Deserialize)]
struct StreamEnded {
    stream: u32,
}

/// Pops one complete msgpack value off the front of `buf`, the same way the
/// CLI's `MsgPackCodec` does. `Ok(None)` means "need more bytes".
pub(crate) fn next_frame(buf: &mut Vec<u8>) -> io::Result<Option<(Partial, Vec<u8>)>> {
    if buf.is_empty() {
        return Ok(None);
    }
    let mut cur = io::Cursor::new(&buf[..]);
    match rmp_serde::decode::from_read::<_, Partial>(&mut cur) {
        Ok(p) => {
            let n = cur.position() as usize;
            Ok(Some((p, buf.drain(..n).collect())))
        }
        Err(
            rmp_serde::decode::Error::InvalidDataRead(e)
            | rmp_serde::decode::Error::InvalidMarkerRead(e),
        ) if e.kind() == io::ErrorKind::UnexpectedEof => Ok(None),
        Err(e) => Err(io::Error::new(io::ErrorKind::InvalidData, e.to_string())),
    }
}

/// Incoming bytes of one server stream; `recv()` returns None once it ended.
pub(crate) type StreamRx = mpsc::UnboundedReceiver<Vec<u8>>;
type Streams = Vec<(u32, StreamRx)>;

struct PendingCall {
    reply: oneshot::Sender<Result<Vec<u8>>>,
    streams: Option<oneshot::Sender<Streams>>,
}

#[derive(Default)]
struct Shared {
    pending: HashMap<u32, PendingCall>,
    // ponytail: unbounded per-stream queues keep the reader from ever blocking;
    // a huge fs_read is buffered in memory. Bound it if multi-GB files matter.
    streams: HashMap<u32, mpsc::UnboundedSender<Vec<u8>>>,
    closed: bool,
}

/// Write half of one server stream (e.g. a process's stdin). Writes are
/// synchronous and queue in call order, so keystrokes can't overtake each other.
#[derive(Clone)]
pub(crate) struct StreamTx {
    id: u32,
    out: Out,
}

impl StreamTx {
    pub fn write(&self, data: &[u8]) -> Result<()> {
        for segment in data.chunks(CHUNK) {
            let msg = encode(None, "stream_data", StreamDataOut { stream: self.id, segment });
            self.out.send(msg).map_err(|_| Error::Closed)?;
        }
        Ok(())
    }

    pub fn end(&self) -> Result<()> {
        let msg = encode(None, "stream_ended", StreamEnded { stream: self.id });
        self.out.send(msg).map_err(|_| Error::Closed)
    }
}

// ponytail: unbounded outgoing queue; a huge fs_write sits in memory once more
// (the caller already holds it). Bound it if multi-GB uploads matter.
type Out = mpsc::UnboundedSender<Vec<u8>>;

/// Most bytes coalesced into one socket write.
const MAX_BATCH: usize = 256 * 1024;

/// A started duplex call: one (writer, reader) pair per server stream, plus the
/// final reply, which can arrive before the last stream bytes.
pub(crate) struct Duplex {
    pub streams: Vec<(StreamTx, StreamRx)>,
    pub reply: oneshot::Receiver<Result<Vec<u8>>>,
}

#[derive(Clone)]
pub(crate) struct Rpc {
    out: Out,
    next_id: Arc<AtomicU32>,
    shared: Arc<Mutex<Shared>>,
}

pub(crate) fn encode<P: Serialize>(id: Option<u32>, method: &str, params: P) -> Vec<u8> {
    rmp_serde::to_vec_named(&Request { id, method, params }).expect("msgpack encode")
}

pub(crate) fn decode_reply<R: DeserializeOwned>(frame: &[u8]) -> Result<R> {
    rmp_serde::from_slice::<Reply<R>>(frame)
        .map(|r| r.result)
        .map_err(|e| Error::Protocol(e.to_string()))
}

pub(crate) async fn wait_reply<R: DeserializeOwned>(
    reply: oneshot::Receiver<Result<Vec<u8>>>,
) -> Result<R> {
    decode_reply(&reply.await.map_err(|_| Error::Closed)??)
}

impl Rpc {
    /// Spawns the reader/writer tasks; the receiver yields the server greeting.
    pub fn start<R, W>(rd: R, mut wr: W) -> (Rpc, oneshot::Receiver<VersionInfo>)
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let (out, mut out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let shared = Arc::new(Mutex::new(Shared::default()));
        let (version_tx, version_rx) = oneshot::channel();

        let nudger = out.clone();
        tokio::spawn(async move {
            let nudge = encode(None, "stream_data", StreamDataOut { stream: NUDGE_STREAM, segment: &[] });
            let pending = Arc::new(AtomicBool::new(false));
            // Coalesce whatever queued up meanwhile into one write + flush,
            // i.e. one SSH packet instead of one per message.
            while let Some(mut batch) = out_rx.recv().await {
                while batch.len() < MAX_BATCH {
                    match out_rx.try_recv() {
                        Ok(more) => batch.extend_from_slice(&more),
                        Err(_) => break,
                    }
                }
                if wr.write_all(&batch).await.is_err() || wr.flush().await.is_err() {
                    break;
                }
                // The desktop's tunnel socket uses Nagle: of a reply made of several
                // messages (fs_read: streams_started, data, ended, reply; a redraw in
                // several writes) only the first leaves until the relay ACKs it, and
                // the relay delays that ACK ~70 ms. Any bytes we send carry the ACK,
                // so a few ms after each request, send a message the server drops
                // (data for a stream that doesn't exist). Measured: fs_read 126 → 59 ms.
                if has_call(&batch) && !pending.swap(true, Ordering::Relaxed) {
                    let (tx, pending, nudge) = (nudger.clone(), pending.clone(), nudge.clone());
                    tokio::spawn(async move {
                        tokio::time::sleep(NUDGE_AFTER).await;
                        pending.store(false, Ordering::Relaxed);
                        let _ = tx.send(nudge);
                    });
                }
            }
        });
        tokio::spawn(read_loop(rd, shared.clone(), version_tx));

        (Rpc { out, next_id: Arc::new(AtomicU32::new(1)), shared }, version_rx)
    }

    fn begin<P: Serialize>(
        &self,
        method: &str,
        params: P,
        want_streams: bool,
    ) -> Result<(u32, Vec<u8>, oneshot::Receiver<Result<Vec<u8>>>, Option<oneshot::Receiver<Streams>>)>
    {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (reply, reply_rx) = oneshot::channel();
        let (streams, streams_rx) = if want_streams {
            let (tx, rx) = oneshot::channel();
            (Some(tx), Some(rx))
        } else {
            (None, None)
        };
        let mut s = self.shared.lock().unwrap();
        if s.closed {
            return Err(Error::Closed);
        }
        s.pending.insert(id, PendingCall { reply, streams });
        Ok((id, encode(Some(id), method, params), reply_rx, streams_rx))
    }

    pub async fn call<P: Serialize, R: DeserializeOwned>(&self, method: &str, params: P) -> Result<R> {
        let (id, msg, reply, _) = self.begin(method, params, false)?;
        self.out.send(msg).map_err(|_| Error::Closed)?;
        // A handler that panics on the desktop never replies (the VS Code CLI
        // does this for sockets/FIFOs in fs_stat and fs_readdir), so don't wait forever.
        match tokio::time::timeout(CALL_TIMEOUT, wait_reply(reply)).await {
            Ok(r) => r,
            Err(_) => {
                self.shared.lock().unwrap().pending.remove(&id);
                Err(Error::Remote(format!("the desktop didn't answer {method}")))
            }
        }
    }

    pub async fn call_duplex<P: Serialize>(&self, method: &str, params: P) -> Result<Duplex> {
        let (_, msg, reply, streams) = self.begin(method, params, true)?;
        self.out.send(msg).map_err(|_| Error::Closed)?;
        match streams.expect("requested streams").await {
            Ok(streams) => Ok(Duplex {
                streams: streams
                    .into_iter()
                    .map(|(id, rx)| (StreamTx { id, out: self.out.clone() }, rx))
                    .collect(),
                reply,
            }),
            // The reply came without streams: the server rejected the call.
            Err(_) => match reply.await.map_err(|_| Error::Closed)? {
                Err(e) => Err(e),
                Ok(_) => Err(Error::Protocol(format!("{method}: no streams in reply"))),
            },
        }
    }
}

/// Whether a batch holds a request, not just notifications (stream data).
/// Every message is the map {id, method, params}; a notification's id is nil.
fn has_call(batch: &[u8]) -> bool {
    // ponytail: a byte search; typed bytes could fake a match, which only costs a nudge.
    batch.windows(5).any(|w| w[..4] == [0x83, 0xa2, b'i', b'd'] && w[4] != 0xc0)
}

/// A stream id the control server never hands out (it counts up from 0).
// ponytail: relies on the CLI ignoring data for unknown streams (it does, as of 1.142).
const NUDGE_STREAM: u32 = u32::MAX;
/// Measured on the iPad: 3 ms and 10 ms help alike; nudging after keystrokes too changed nothing.
const NUDGE_AFTER: std::time::Duration = std::time::Duration::from_millis(3);

async fn read_loop<R: AsyncRead + Unpin>(
    mut rd: R,
    shared: Arc<Mutex<Shared>>,
    version_tx: oneshot::Sender<VersionInfo>,
) {
    let mut version_tx = Some(version_tx);
    let mut buf = Vec::new();
    let mut chunk = vec![0u8; 64 * 1024];
    'outer: loop {
        match rd.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
        loop {
            match next_frame(&mut buf) {
                Ok(Some((p, frame))) => dispatch(&shared, p, &frame, &mut version_tx),
                Ok(None) => break,
                Err(e) => {
                    log::warn!("bad frame from control server: {e}");
                    break 'outer;
                }
            }
        }
    }
    let mut s = shared.lock().unwrap();
    s.closed = true;
    s.streams.clear();
    for (_, call) in s.pending.drain() {
        let _ = call.reply.send(Err(Error::Closed));
    }
}

fn dispatch(
    shared: &Mutex<Shared>,
    p: Partial,
    frame: &[u8],
    version_tx: &mut Option<oneshot::Sender<VersionInfo>>,
) {
    let mut s = shared.lock().unwrap();
    match p.method.as_deref() {
        Some("stream_data") => {
            if let Ok(m) = rmp_serde::from_slice::<Notification<StreamDataIn>>(frame) {
                if let Some(tx) = s.streams.get(&m.params.stream) {
                    let _ = tx.send(m.params.segment);
                }
            }
        }
        Some("stream_ended") => {
            if let Ok(m) = rmp_serde::from_slice::<Notification<StreamEnded>>(frame) {
                s.streams.remove(&m.params.stream);
            }
        }
        Some("streams_started") => {
            if let Ok(m) = rmp_serde::from_slice::<Notification<StreamsStarted>>(frame) {
                let mut rxs = Vec::with_capacity(m.params.stream_ids.len());
                for id in m.params.stream_ids {
                    let (tx, rx) = mpsc::unbounded_channel();
                    s.streams.insert(id, tx);
                    rxs.push((id, rx));
                }
                if let Some(waiter) = s
                    .pending
                    .get_mut(&m.params.for_request_id)
                    .and_then(|c| c.streams.take())
                {
                    let _ = waiter.send(rxs);
                }
            }
        }
        Some("version") => {
            if let (Some(tx), Ok(m)) =
                (version_tx.take(), rmp_serde::from_slice::<Notification<VersionInfo>>(frame))
            {
                let _ = tx.send(m.params);
            }
        }
        Some(_) => {} // serverlog and other host-initiated calls we don't use
        None => {
            if let Some(call) = p.id.and_then(|id| s.pending.remove(&id)) {
                let r = match p.error {
                    Some(e) => Err(Error::Remote(e.message)),
                    None => Ok(frame.to_vec()),
                };
                let _ = call.reply.send(r);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Serialize)]
    struct Resp<T> {
        id: u32,
        result: T,
    }

    fn wire() -> Vec<Vec<u8>> {
        vec![
            encode(None, "version", serde_json::json!({"version": "1.142.0", "protocol_version": 6})),
            encode(None, "streams_started", serde_json::json!({"for_request_id": 7, "stream_ids": [3, 4]})),
            encode(None, "stream_data", StreamDataOut { stream: 3, segment: &[0u8, 1, 2, 255] }),
            encode(None, "stream_ended", StreamEnded { stream: 3 }),
            rmp_serde::to_vec_named(&Resp { id: 7, result: serde_json::json!({"exit_code": 0, "message": ""}) }).unwrap(),
        ]
    }

    /// Frames must come out intact no matter how TCP splits the bytes.
    #[test]
    fn has_call_tells_requests_from_notifications() {
        assert!(has_call(&encode(Some(7), "ping", serde_json::json!({}))));
        assert!(!has_call(&encode(None, "stream_data", StreamDataOut { stream: 1, segment: b"id" })));
    }

    #[test]
    fn frames_survive_any_split() {
        let frames = wire();
        let all: Vec<u8> = frames.concat();
        for step in [1, 2, 3, 7, 64, all.len()] {
            let mut buf = Vec::new();
            let mut got = Vec::new();
            for piece in all.chunks(step) {
                buf.extend_from_slice(piece);
                while let Some((_, f)) = next_frame(&mut buf).unwrap() {
                    got.push(f);
                }
            }
            assert_eq!(got, frames, "split step {step}");
            assert!(buf.is_empty());
        }
    }

    #[tokio::test]
    async fn duplex_call_and_streams() {
        let (client, mut server) = tokio::io::duplex(1 << 16);
        let (rd, wr) = tokio::io::split(client);
        let (rpc, version) = Rpc::start(rd, wr);

        // Fake host: greet, then answer the first request with one stream.
        let host = tokio::spawn(async move {
            server.write_all(&wire()[0]).await.unwrap();
            let mut buf = Vec::new();
            let mut chunk = [0u8; 4096];
            let req = loop {
                let n = server.read(&mut chunk).await.unwrap();
                buf.extend_from_slice(&chunk[..n]);
                if let Some((p, _)) = next_frame(&mut buf).unwrap() {
                    break p;
                }
            };
            assert_eq!(req.method.as_deref(), Some("fs_read"));
            let id = req.id.unwrap();
            for msg in [
                encode(None, "streams_started", serde_json::json!({"for_request_id": id, "stream_ids": [9]})),
                encode(None, "stream_data", StreamDataOut { stream: 9, segment: b"hello " }),
                // reply overtakes the tail of the stream, as the real host can
                rmp_serde::to_vec_named(&Resp { id, result: serde_json::json!({}) }).unwrap(),
                encode(None, "stream_data", StreamDataOut { stream: 9, segment: b"world" }),
                encode(None, "stream_ended", StreamEnded { stream: 9 }),
            ] {
                server.write_all(&msg).await.unwrap();
            }
            server
        });

        assert_eq!(version.await.unwrap().protocol_version, 6);
        let mut d = rpc.call_duplex("fs_read", serde_json::json!({"path": "/x"})).await.unwrap();
        let (_, mut rx) = d.streams.remove(0);
        let mut data = Vec::new();
        while let Some(chunk) = rx.recv().await {
            data.extend(chunk);
        }
        wait_reply::<serde_json::Value>(d.reply).await.unwrap();
        assert_eq!(data, b"hello world");
        drop(host.await.unwrap());
    }

    #[tokio::test]
    async fn errors_and_disconnect() {
        let (client, mut server) = tokio::io::duplex(1 << 16);
        let (rd, wr) = tokio::io::split(client);
        let (rpc, _version) = Rpc::start(rd, wr);
        let host = tokio::spawn(async move {
            let mut chunk = [0u8; 4096];
            let n = server.read(&mut chunk).await.unwrap();
            let (p, _) = next_frame(&mut chunk[..n].to_vec()).unwrap().unwrap();
            let err = serde_json::json!({"id": p.id.unwrap(), "error": {"code": -1, "message": "file not found"}});
            server.write_all(&rmp_serde::to_vec_named(&err).unwrap()).await.unwrap();
            server // dropped by the test after the first call -> disconnect
        });
        let e = rpc.call::<_, serde_json::Value>("fs_stat", serde_json::json!({"path": "/nope"})).await;
        assert!(matches!(e, Err(Error::Remote(m)) if m == "file not found"));
        drop(host.await.unwrap());
        let e = rpc.call::<_, serde_json::Value>("ping", serde_json::json!({})).await;
        assert!(matches!(e, Err(Error::Closed)));
    }
}
