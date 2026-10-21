//! SSH desktops (Linux). Files, processes and ports go over plain SSH (SFTP,
//! exec, direct-tcpip), answered as the VS Code CLI's control server would
//! answer them (serve.rs), so `Session` (remote.rs) and everything built on it
//! work unchanged.
//! The CLI's own control server (`code command-shell`) can't be used here: it
//! requires VS Code's closed `vsda` handshake.

use crate::{
    remote::{Link, Session},
    rpc::Rpc,
    serve::{command_line, params, parse_env, q, serve, Backend, Host, NetP, PathP, RenameP, SpawnP},
    Error, Result,
};
use russh::{client, ChannelMsg};
use russh_keys::{key, PublicKeyBase64};
use russh_sftp::{client::SftpSession, protocol::StatusCode};
use serde_json::{json, Value};
use std::{
    future::Future,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::OnceCell,
};

/// PadCode's login key: PKCS#8 PEM (kept in the iPad Keychain) and the
/// OpenSSH public line that goes in `~/.ssh/authorized_keys`.
pub struct LoginKey {
    pub private_pem: String,
    pub public_openssh: String,
}

pub fn generate_key() -> Result<LoginKey> {
    let kp = key::KeyPair::generate_ed25519().ok_or_else(|| Error::Remote("couldn't generate a key".into()))?;
    let mut pem = Vec::new();
    russh_keys::encode_pkcs8_pem(&kp, &mut pem).map_err(|e| Error::Remote(e.to_string()))?;
    Ok(LoginKey { private_pem: String::from_utf8_lossy(&pem).into_owned(), public_openssh: public_line(&kp)? })
}

/// The OpenSSH public line for a saved private key.
pub fn public_key(private_pem: &str) -> Result<String> {
    let kp = russh_keys::decode_secret_key(private_pem, None).map_err(|e| Error::Remote(e.to_string()))?;
    public_line(&kp)
}

fn public_line(kp: &key::KeyPair) -> Result<String> {
    let pk = kp.clone_public_key().map_err(|e| Error::Remote(e.to_string()))?;
    Ok(format!("ssh-ed25519 {} padcode@ipad", pk.public_key_base64()))
}

/// Accepts only the host key the user already trusted; records what it saw.
struct Client {
    expected: Option<String>,
    seen: Arc<Mutex<Option<String>>>,
}

#[async_trait::async_trait]
impl client::Handler for Client {
    type Error = russh::Error;
    async fn check_server_key(self, key: &key::PublicKey) -> std::result::Result<(Self, bool), Self::Error> {
        let fp = format!("SHA256:{}", key.fingerprint());
        let ok = self.expected.as_deref() == Some(fp.as_str());
        *self.seen.lock().unwrap() = Some(fp);
        Ok((self, ok))
    }
}

type Handle = client::Handle<Client>;

/// Keeps the SSH connection open while the session lives.
pub(crate) struct Conn(Arc<Handle>);

impl Conn {
    pub fn is_closed(&self) -> bool {
        self.0.is_closed()
    }
}

/// Connects and logs in with PadCode's key. A host key other than
/// `fingerprint` fails with `HostKeyUnknown` (none saved yet: the app asks)
/// or `HostKeyChanged`.
pub async fn connect(host: &str, port: u16, user: &str, private_pem: &str, fingerprint: Option<&str>) -> Result<Session> {
    let kp = russh_keys::decode_secret_key(private_pem, None)
        .map_err(|e| Error::Remote(format!("PadCode's SSH key can't be read: {e}")))?;
    let seen = Arc::new(Mutex::new(None));
    let handler = Client { expected: fingerprint.map(str::to_string), seen: seen.clone() };
    let tcp = match tokio::time::timeout(Duration::from_secs(12), tokio::net::TcpStream::connect((host, port))).await {
        Err(_) => return Err(Error::Remote(format!("{host}:{port} didn't answer"))),
        Ok(Err(e)) => return Err(Error::Remote(format!("can't reach {host}:{port}: {e}"))),
        Ok(Ok(s)) => s,
    };
    let _ = tcp.set_nodelay(true); // keystrokes leave at once, not batched (Nagle)
    let connecting = client::connect_stream(Arc::new(config()), tcp, handler);
    let mut handle = match tokio::time::timeout(Duration::from_secs(12), connecting).await {
        Err(_) => return Err(Error::Remote(format!("{host}:{port} didn't answer"))),
        Ok(Ok(h)) => h,
        Ok(Err(e)) => {
            let saw = seen.lock().unwrap().clone();
            return Err(match (saw, fingerprint) {
                (Some(fp), None) => Error::HostKeyUnknown(fp),
                (Some(fp), Some(want)) if fp != want => Error::HostKeyChanged(fp),
                _ => Error::Remote(format!("can't reach {host}:{port}: {e}")),
            });
        }
    };
    let accepted = handle
        .authenticate_publickey(user, Arc::new(kp))
        .await
        .map_err(|e| Error::Remote(format!("SSH login failed: {e}")))?;
    if !accepted {
        return Err(Error::SshAuth(format!(
            "{user}@{host} didn't accept PadCode's key. Add it to ~/.ssh/authorized_keys there."
        )));
    }
    interactive(&handle).await;
    let handle = Arc::new(handle);
    let (client_io, server_io) = tokio::io::duplex(1 << 20);
    tokio::spawn(serve(server_io, "ssh", Ssh { ssh: handle.clone(), sftp: OnceCell::new() }));
    let (rd, wr) = tokio::io::split(client_io);
    let (rpc, version) = Rpc::start(rd, wr);
    let version = version.await.map_err(|_| Error::Closed)?;
    Session::start(rpc, Link::Ssh(Conn(handle)), host.to_string(), version).await
}

/// Modern algorithms only: no SHA-1 key exchange or MACs, no 1024-bit groups,
/// no "none" MAC (russh's defaults keep them as fallbacks).
fn config() -> client::Config {
    client::Config {
        preferred: russh::Preferred {
            kex: &[russh::kex::CURVE25519, russh::kex::DH_G14_SHA256, russh::kex::EXTENSION_SUPPORT_AS_CLIENT],
            key: &[key::ED25519, key::RSA_SHA2_256, key::RSA_SHA2_512],
            cipher: &[
                russh::cipher::CHACHA20_POLY1305,
                russh::cipher::AES_256_GCM,
                russh::cipher::AES_256_CTR,
                russh::cipher::AES_128_CTR,
            ],
            mac: &[russh::mac::HMAC_SHA512_ETM, russh::mac::HMAC_SHA256_ETM, russh::mac::HMAC_SHA512, russh::mac::HMAC_SHA256],
            compression: &["none"],
        },
        ..Default::default()
    }
}

/// OpenSSH decides once per connection, from its first session, whether the
/// connection is interactive (TCP_NODELAY, low-delay QoS): only a tty makes it
/// so. PadCode's sessions are plain execs, so without this the desktop holds
/// back each terminal echo behind Nagle (measured on the iPad: 59 ms echo on a
/// 20 ms network). So the first session asks for a tty and runs `true`.
async fn interactive(handle: &Handle) {
    let Ok(mut ch) = handle.channel_open_session().await else { return };
    if ch.request_pty(false, "dumb", 80, 24, 0, 0, &[]).await.is_ok() && ch.exec(true, "true").await.is_ok() {
        let _ = tokio::time::timeout(Duration::from_secs(5), async { while ch.wait().await.is_some() {} }).await;
    }
}

// MARK: the control server, over SSH

pub(crate) struct Ssh {
    ssh: Arc<Handle>,
    sftp: OnceCell<SftpSession>,
}

impl Backend for Ssh {
    fn handle(h: &Arc<Host<Self>>, method: &str, id: u32, frame: &[u8]) -> impl Future<Output = Result<Value>> + Send {
        h.handle(method, id, frame)
    }
}

fn ssh_err(e: russh::Error) -> Error {
    Error::Remote(format!("SSH: {e}"))
}

fn fs_err(e: russh_sftp::client::error::Error) -> Error {
    Error::Remote(e.to_string())
}

fn kind(t: &russh_sftp::protocol::FileType) -> &'static str {
    if t.is_dir() {
        "dir"
    } else if t.is_symlink() {
        "link"
    } else {
        "file"
    }
}

impl Host<Ssh> {
    async fn handle(&self, method: &str, id: u32, frame: &[u8]) -> Result<Value> {
        match method {
            "ping" => {
                let ch = tokio::time::timeout(Duration::from_secs(5), self.b.ssh.channel_open_session())
                    .await
                    .map_err(|_| Error::Closed)?
                    .map_err(ssh_err)?;
                let _ = ch.close().await;
                Ok(json!({}))
            }
            "get_env" => {
                let (_, out, _) = self.sh("uname -s; uname -r; env").await?;
                Ok(parse_env(&String::from_utf8_lossy(&out)))
            }
            "fs_stat" => {
                let p: PathP = params(frame)?;
                match self.sftp().await?.metadata(p.path).await {
                    Ok(m) => Ok(json!({ "exists": true, "size": m.size, "type": kind(&m.file_type()) })),
                    Err(russh_sftp::client::error::Error::Status(s)) if s.status_code == StatusCode::NoSuchFile => {
                        Ok(json!({ "exists": false }))
                    }
                    Err(e) => Err(fs_err(e)),
                }
            }
            "fs_readdir" => {
                let p: PathP = params(frame)?;
                let dir = self.sftp().await?.read_dir(p.path).await.map_err(fs_err)?;
                let contents: Vec<Value> = dir
                    .filter(|e| e.file_name() != "." && e.file_name() != "..")
                    .map(|e| json!({ "name": e.file_name(), "type": kind(&e.file_type()) }))
                    .collect();
                Ok(json!({ "contents": contents }))
            }
            "fs_read" => {
                let p: PathP = params(frame)?;
                let sftp = self.sftp().await?;
                // Stat alongside the open, so a whole file needs no extra round trip
                // to read its EOF. A size of 0 isn't trusted (Linux /proc files).
                let (f, m) = tokio::join!(sftp.open(p.path.clone()), sftp.metadata(p.path));
                let mut f = f.map_err(fs_err)?;
                let size = m.ok().and_then(|m| m.size).filter(|&n| n > 0);
                let s = self.stream();
                self.started(id, &[s]);
                let mut buf = vec![0u8; 256 * 1024];
                let mut got = 0u64;
                let r = loop {
                    if size.is_some_and(|n| got >= n) {
                        break Ok(json!({}));
                    }
                    match f.read(&mut buf).await {
                        Ok(0) => break Ok(json!({})),
                        Ok(n) => {
                            got += n as u64;
                            self.data(s, &buf[..n])
                        }
                        Err(e) => break Err(Error::Remote(e.to_string())),
                    }
                };
                self.ended(s); // even on failure, so the reader isn't left waiting
                r
            }
            "fs_write" => {
                let p: PathP = params(frame)?;
                let sftp = self.sftp().await?;
                let s = self.stream();
                let mut rx = self.inbound(s);
                self.started(id, &[s]);
                let mut f = sftp.create(p.path).await.map_err(fs_err)?;
                while let Some(chunk) = rx.recv().await {
                    f.write_all(&chunk).await.map_err(|e| Error::Remote(e.to_string()))?;
                }
                f.flush().await.map_err(|e| Error::Remote(e.to_string()))?;
                f.close().await.map_err(|e| Error::Remote(e.to_string()))?;
                Ok(json!({}))
            }
            // ponytail: shell commands rather than SFTP walks; the hosts are Linux.
            "fs_mkdirp" => {
                let p: PathP = params(frame)?;
                self.run_ok(&format!("mkdir -p -- {}", q(&p.path))).await
            }
            "fs_rename" => {
                let p: RenameP = params(frame)?;
                self.run_ok(&format!("mv -f -- {} {}", q(&p.from_path), q(&p.to_path))).await
            }
            "fs_rm" => {
                let p: PathP = params(frame)?;
                self.run_ok(&format!("rm -rf -- {}", q(&p.path))).await
            }
            "spawn" => self.spawn(id, params(frame)?).await,
            "net_connect" => self.net_connect(id, params(frame)?).await,
            m => Err(Error::Remote(format!("{m} isn't available over SSH"))),
        }
    }

    async fn sftp(&self) -> Result<&SftpSession> {
        self.b.sftp
            .get_or_try_init(|| async {
                let mut ch = self.b.ssh.channel_open_session().await.map_err(ssh_err)?;
                ch.request_subsystem(true, "sftp").await.map_err(ssh_err)?;
                SftpSession::new(ch.into_stream()).await.map_err(|e| Error::Remote(format!("SFTP: {e}")))
            })
            .await
    }

    /// Runs a shell command to completion: (exit code, stdout, stderr).
    async fn sh(&self, cmd: &str) -> Result<(u32, Vec<u8>, Vec<u8>)> {
        let mut ch = self.b.ssh.channel_open_session().await.map_err(ssh_err)?;
        ch.exec(true, cmd).await.map_err(ssh_err)?;
        let (mut out, mut err, mut code) = (Vec::new(), Vec::new(), None);
        while let Some(msg) = ch.wait().await {
            match msg {
                ChannelMsg::Data { data } => out.extend_from_slice(&data),
                ChannelMsg::ExtendedData { data, .. } => err.extend_from_slice(&data),
                ChannelMsg::ExitStatus { exit_status } => code = Some(exit_status),
                _ => {}
            }
        }
        Ok((code.unwrap_or(255), out, err))
    }

    async fn run_ok(&self, cmd: &str) -> Result<Value> {
        let (code, _, err) = self.sh(cmd).await?;
        if code == 0 {
            Ok(json!({}))
        } else {
            Err(Error::Remote(String::from_utf8_lossy(&err).trim().to_string()))
        }
    }

    /// A process with stdin, stdout and stderr streams; the reply is its exit code.
    async fn spawn(&self, id: u32, p: SpawnP) -> Result<Value> {
        let mut ch = self.b.ssh.channel_open_session().await.map_err(ssh_err)?;
        ch.exec(true, command_line(&p)).await.map_err(ssh_err)?;
        let (i, o, e) = (self.stream(), self.stream(), self.stream());
        let mut stdin = self.inbound(i);
        self.started(id, &[i, o, e]);
        let (mut code, mut stdin_open) = (None, true);
        loop {
            tokio::select! {
                msg = ch.wait() => match msg {
                    Some(ChannelMsg::Data { data }) => self.data(o, &data),
                    Some(ChannelMsg::ExtendedData { data, .. }) => self.data(e, &data),
                    Some(ChannelMsg::ExitStatus { exit_status }) => code = Some(exit_status as i32),
                    Some(ChannelMsg::ExitSignal { .. }) => code = code.or(Some(-1)),
                    Some(_) => {}
                    None => break,
                },
                input = stdin.recv(), if stdin_open => match input {
                    Some(bytes) => {
                        if ch.data(&bytes[..]).await.is_err() {
                            stdin_open = false;
                        }
                    }
                    None => {
                        stdin_open = false;
                        let _ = ch.eof().await;
                    }
                },
            }
        }
        self.close_inbound(i);
        self.ended(o);
        self.ended(e);
        Ok(json!({ "exit_code": code.unwrap_or(-1), "message": "" }))
    }

    /// A TCP connection to the host's own port: one stream both ways.
    async fn net_connect(&self, id: u32, p: NetP) -> Result<Value> {
        let mut ch = self
            .b
            .ssh
            .channel_open_direct_tcpip(p.host, p.port as u32, "127.0.0.1", 0)
            .await
            .map_err(ssh_err)?;
        let s = self.stream();
        let mut up = self.inbound(s);
        self.started(id, &[s]);
        let mut open = true;
        loop {
            tokio::select! {
                msg = ch.wait() => match msg {
                    Some(ChannelMsg::Data { data }) => self.data(s, &data),
                    Some(ChannelMsg::Eof) | None => break,
                    Some(_) => {}
                },
                input = up.recv(), if open => match input {
                    Some(bytes) => {
                        if ch.data(&bytes[..]).await.is_err() {
                            break;
                        }
                    }
                    None => {
                        open = false;
                        let _ = ch.eof().await;
                    }
                },
            }
        }
        self.close_inbound(s);
        self.ended(s);
        let _ = ch.close().await;
        Ok(json!({}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Against a real sshd: `PADCODE_TEST_SSH=user@127.0.0.1:2222` and
    /// `PADCODE_TEST_AUTHKEYS=<that sshd's AuthorizedKeysFile>`.
    #[tokio::test]
    #[ignore]
    async fn live_ssh() {
        let target = std::env::var("PADCODE_TEST_SSH").unwrap();
        let (user, rest) = target.split_once('@').unwrap();
        let (host, port) = rest.split_once(':').unwrap();
        let port: u16 = port.parse().unwrap();
        let k = generate_key().unwrap();
        std::fs::write(std::env::var("PADCODE_TEST_AUTHKEYS").unwrap(), format!("{}\n", k.public_openssh)).unwrap();

        let fp = match connect(host, port, user, &k.private_pem, None).await {
            Err(Error::HostKeyUnknown(fp)) => fp,
            other => panic!("first connect: {:?}", other.err()),
        };
        assert!(matches!(connect(host, port, user, &k.private_pem, Some("SHA256:nope")).await, Err(Error::HostKeyChanged(_))));
        let stranger = generate_key().unwrap();
        assert!(matches!(connect(host, port, user, &stranger.private_pem, Some(&fp)).await, Err(Error::SshAuth(_))));

        let s = connect(host, port, user, &k.private_pem, Some(&fp)).await.unwrap();
        s.ping().await.unwrap();
        let dir = s.join(&s.env.home, "padcode-ssh-test");
        let _ = s.remove(&dir).await;
        s.mkdirp(&s.join(&dir, "a/b")).await.unwrap();
        let file = s.join(&dir, "it's here.txt");
        let big: Vec<u8> = (0..600_000u32).map(|i| (i % 251) as u8).collect();
        s.write_file(&file, &big).await.unwrap();
        assert_eq!(s.read_file(&file).await.unwrap(), big);
        assert_eq!(s.stat(&file).await.unwrap().size, Some(big.len() as u64));
        s.write_file(&s.join(&dir, "a/empty"), b"").await.unwrap();
        assert!(s.read_file(&s.join(&dir, "a/empty")).await.unwrap().is_empty());
        let names: Vec<String> = s.list_dir(&dir).await.unwrap().into_iter().map(|e| e.name).collect();
        assert_eq!(names, vec!["a".to_string(), "it's here.txt".to_string()]);
        s.rename(&file, &s.join(&dir, "moved.txt")).await.unwrap();
        assert!(!s.stat(&file).await.unwrap().exists);
        let out = s.run("sh", &["-c", "pwd; echo err >&2; exit 3"], Some(&dir)).await.unwrap();
        assert_eq!((out.code, String::from_utf8_lossy(&out.stdout).trim().ends_with("padcode-ssh-test"), out.stderr), (3, true, b"err\n".to_vec()));
        s.remove(&dir).await.unwrap();
        assert!(!s.stat(&dir).await.unwrap().exists);
    }

    #[test]
    fn key_round_trip() {
        let k = generate_key().unwrap();
        assert!(k.public_openssh.starts_with("ssh-ed25519 "));
        let back = russh_keys::decode_secret_key(&k.private_pem, None).unwrap();
        assert_eq!(public_line(&back).unwrap(), k.public_openssh);
        assert_eq!(public_key(&k.private_pem).unwrap(), k.public_openssh); // after a reinstall
    }
}
