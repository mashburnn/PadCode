//! "This iPad": the Alpine Linux that runs inside PadCode (vendor/ish). PadCode
//! answers the control server's requests itself (serve.rs), straight from the
//! guest's kernel through vendor/ish-shim: files with its file calls, processes
//! on host pipes, ports on the iPad's own loopback (guest sockets are host
//! sockets). No SSH and no network. The app boots the guest first
//! (LocalLinux.swift).

use crate::{
    remote::{Link, Session},
    rpc::Rpc,
    serve::{command_line, params, parse_env, q, serve, Backend, Host, NetP, PathP, RenameP, SpawnP, CHUNK},
    Error, Result,
};
use serde_json::{json, Value};
use std::{
    ffi::{c_char, c_int, c_uint, c_void, CStr, CString},
    future::Future,
    os::fd::{IntoRawFd, OwnedFd},
    sync::Arc,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::unix::pipe,
};

pub async fn connect() -> Result<Session> {
    let (client_io, server_io) = tokio::io::duplex(1 << 20);
    tokio::spawn(serve(server_io, "local", Guest));
    let (rd, wr) = tokio::io::split(client_io);
    let (rpc, version) = Rpc::start(rd, wr);
    let version = version.await.map_err(|_| Error::Closed)?;
    Session::start(rpc, Link::Local, "This iPad".into(), version).await
}

pub(crate) struct Guest;

impl Backend for Guest {
    fn handle(h: &Arc<Host<Self>>, method: &str, id: u32, frame: &[u8]) -> impl Future<Output = Result<Value>> + Send {
        h.handle(method, id, frame)
    }
}

impl Host<Guest> {
    async fn handle(&self, method: &str, id: u32, frame: &[u8]) -> Result<Value> {
        match method {
            "ping" => Ok(json!({})), // nothing in between to drop
            "get_env" => {
                let (_, out, _) = sh("uname -s; uname -r; env").await?;
                Ok(parse_env(&String::from_utf8_lossy(&out)))
            }
            "fs_stat" => {
                let p: PathP = params(frame)?;
                match blocking(move || stat(&p.path, true)).await? {
                    Ok((mode, size)) => Ok(json!({ "exists": true, "size": size, "type": kind(mode) })),
                    Err(ENOENT | ENOTDIR) => Ok(json!({ "exists": false })),
                    Err(e) => Err(errno(e)),
                }
            }
            "fs_readdir" => {
                let p: PathP = params(frame)?;
                let entries = blocking(move || list(&p.path)).await?.map_err(errno)?;
                let contents: Vec<Value> = entries.iter().map(|(name, mode)| json!({ "name": name, "type": kind(*mode) })).collect();
                Ok(json!({ "contents": contents }))
            }
            "fs_read" => {
                // ponytail: the whole file at once; the client collects it whole anyway.
                let p: PathP = params(frame)?;
                let data = blocking(move || read_all(&p.path)).await?.map_err(errno)?;
                let s = self.stream();
                self.started(id, &[s]);
                self.data(s, &data);
                self.ended(s);
                Ok(json!({}))
            }
            "fs_write" => {
                let p: PathP = params(frame)?;
                let s = self.stream();
                let mut rx = self.inbound(s);
                self.started(id, &[s]);
                let mut data = Vec::new();
                while let Some(chunk) = rx.recv().await {
                    data.extend_from_slice(&chunk);
                }
                blocking(move || write_all(&p.path, &data)).await?.map_err(errno)?;
                Ok(json!({}))
            }
            // ponytail: shell commands, as over SSH; only rare actions (new folder, rename, delete) use them.
            "fs_mkdirp" => {
                let p: PathP = params(frame)?;
                run_ok(&format!("mkdir -p -- {}", q(&p.path))).await
            }
            "fs_rename" => {
                let p: RenameP = params(frame)?;
                run_ok(&format!("mv -f -- {} {}", q(&p.from_path), q(&p.to_path))).await
            }
            "fs_rm" => {
                let p: PathP = params(frame)?;
                run_ok(&format!("rm -rf -- {}", q(&p.path))).await
            }
            "spawn" => self.spawn(id, params(frame)?).await,
            "net_connect" => self.net_connect(id, params(frame)?).await,
            m => Err(Error::Remote(format!("{m} isn't available on this iPad's Linux"))),
        }
    }

    /// A process with stdin, stdout and stderr streams; the reply is its exit code.
    async fn spawn(&self, id: u32, p: SpawnP) -> Result<Value> {
        let child = start(&command_line(&p))?;
        let (i, o, e) = (self.stream(), self.stream(), self.stream());
        let mut input = self.inbound(i);
        self.started(id, &[i, o, e]);
        let mut stdin = child.stdin;
        let feed = tokio::spawn(async move {
            while let Some(bytes) = input.recv().await {
                if stdin.write_all(&bytes).await.is_err() {
                    break; // it exited, or closed its stdin
                }
            }
        });
        let (code, _, _) = tokio::join!(exit_code(child.exit), self.pump(child.stdout, o), self.pump(child.stderr, e));
        feed.abort();
        self.close_inbound(i);
        self.ended(o);
        self.ended(e);
        Ok(json!({ "exit_code": code, "message": "" }))
    }

    async fn pump(&self, mut from: pipe::Receiver, stream: u32) {
        let mut buf = vec![0u8; CHUNK];
        while let Ok(n @ 1..) = from.read(&mut buf).await {
            self.data(stream, &buf[..n]);
        }
    }

    /// A TCP connection to one of the guest's ports: they're the iPad's own.
    async fn net_connect(&self, id: u32, p: NetP) -> Result<Value> {
        let tcp = tokio::net::TcpStream::connect((p.host.as_str(), p.port))
            .await
            .map_err(|e| Error::Remote(format!("can't reach port {}: {e}", p.port)))?;
        let _ = tcp.set_nodelay(true);
        let (mut rd, mut wr) = tcp.into_split();
        let s = self.stream();
        let mut up = self.inbound(s);
        self.started(id, &[s]);
        let upload = tokio::spawn(async move {
            while let Some(bytes) = up.recv().await {
                if wr.write_all(&bytes).await.is_err() {
                    return;
                }
            }
            let _ = wr.shutdown().await;
        });
        let mut buf = vec![0u8; CHUNK];
        while let Ok(n @ 1..) = rd.read(&mut buf).await {
            self.data(s, &buf[..n]);
        }
        upload.abort();
        self.close_inbound(s);
        self.ended(s);
        Ok(json!({}))
    }
}

// MARK: processes

struct Child {
    stdin: pipe::Sender,
    stdout: pipe::Receiver,
    stderr: pipe::Receiver,
    exit: pipe::Receiver,
}

/// Starts `/bin/sh -c command` in the guest, on fresh host pipes.
fn start(command: &str) -> Result<Child> {
    let cmd = CString::new(command).map_err(|_| Error::Remote("a NUL in a command".into()))?;
    let io = |e: std::io::Error| Error::Remote(format!("no pipe for a Linux process: {e}"));
    let (in_r, in_w) = std::io::pipe().map_err(io)?;
    let (out_r, out_w) = std::io::pipe().map_err(io)?;
    let (err_r, err_w) = std::io::pipe().map_err(io)?;
    let (exit_r, exit_w) = std::io::pipe().map_err(io)?;
    // The guest takes over its ends (and closes exit_w if this fails).
    let pid = unsafe {
        sys::padlinux_spawn(cmd.as_ptr(), in_r.into_raw_fd(), out_w.into_raw_fd(), err_w.into_raw_fd(), exit_w.into_raw_fd())
    };
    if pid < 0 {
        return Err(errno(pid));
    }
    let io = |e: std::io::Error| Error::Remote(format!("a Linux process's pipe: {e}"));
    Ok(Child {
        stdin: pipe::Sender::from_owned_fd(OwnedFd::from(in_w)).map_err(io)?,
        stdout: pipe::Receiver::from_owned_fd(OwnedFd::from(out_r)).map_err(io)?,
        stderr: pipe::Receiver::from_owned_fd(OwnedFd::from(err_r)).map_err(io)?,
        exit: pipe::Receiver::from_owned_fd(OwnedFd::from(exit_r)).map_err(io)?,
    })
}

/// The exit code the guest reports (a wait status); -1 for a signal.
async fn exit_code(mut exit: pipe::Receiver) -> i32 {
    let mut status = [0u8; 4];
    match exit.read_exact(&mut status).await {
        Ok(_) => status_code(i32::from_ne_bytes(status)),
        Err(_) => -1,
    }
}

fn status_code(status: i32) -> i32 {
    if status & 0x7f == 0 {
        (status >> 8) & 0xff
    } else {
        -1
    }
}

/// Runs a shell command to completion: (exit code, stdout, stderr).
async fn sh(command: &str) -> Result<(i32, Vec<u8>, Vec<u8>)> {
    let Child { stdin, mut stdout, mut stderr, exit } = start(command)?;
    drop(stdin);
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let (code, _, _) = tokio::join!(exit_code(exit), stdout.read_to_end(&mut out), stderr.read_to_end(&mut err));
    Ok((code, out, err))
}

async fn run_ok(command: &str) -> Result<Value> {
    let (code, _, err) = sh(command).await?;
    if code == 0 {
        Ok(json!({}))
    } else {
        Err(Error::Remote(String::from_utf8_lossy(&err).trim().to_string()))
    }
}

// MARK: files

const ENOENT: i32 = -2;
const ENOTDIR: i32 = -20;

/// A negative Linux errno from the guest, as a message.
fn errno(e: i32) -> Error {
    Error::Remote(
        match -e {
            1 => "Operation not permitted",
            2 => "No such file or directory",
            13 => "Permission denied",
            17 => "File exists",
            20 => "Not a directory",
            21 => "Is a directory",
            22 => "Not a regular file",
            28 => "No space left on device",
            36 => "File name too long",
            39 => "Directory not empty",
            19 => "Linux isn't running",
            n => return Error::Remote(format!("Linux error {n}")),
        }
        .into(),
    )
}

fn kind(mode: u32) -> &'static str {
    match mode & 0o170000 {
        0o040000 => "dir",
        0o120000 => "link",
        _ => "file",
    }
}

/// The kernel calls block (briefly); keep them off the async threads.
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Result<T> {
    tokio::task::spawn_blocking(f).await.map_err(|_| Error::Closed)
}

fn c_path(path: &str) -> std::result::Result<CString, i32> {
    CString::new(path).map_err(|_| -22)
}

fn stat(path: &str, follow: bool) -> std::result::Result<(u32, u64), i32> {
    let path = c_path(path)?;
    let (mut mode, mut size) = (0, 0);
    match unsafe { sys::padlinux_stat(path.as_ptr(), follow as c_int, &mut mode, &mut size) } {
        0 => Ok((mode, size)),
        e => Err(e),
    }
}

fn list(dir: &str) -> std::result::Result<Vec<(String, u32)>, i32> {
    extern "C" fn each(ctx: *mut c_void, name: *const c_char, mode: c_uint) {
        let entries = unsafe { &mut *(ctx as *mut Vec<(String, u32)>) };
        entries.push((unsafe { CStr::from_ptr(name) }.to_string_lossy().into_owned(), mode));
    }
    let dir = c_path(dir)?;
    let mut entries: Vec<(String, u32)> = Vec::new();
    match unsafe { sys::padlinux_list(dir.as_ptr(), each, &mut entries as *mut _ as *mut c_void) } {
        0 => Ok(entries),
        e => Err(e),
    }
}

/// An open guest file; closed on drop.
struct File(*mut c_void);

impl File {
    fn open(path: &str, write: bool) -> std::result::Result<File, i32> {
        let path = c_path(path)?;
        let mut err = 0;
        let f = unsafe { sys::padlinux_open(path.as_ptr(), write as c_int, &mut err) };
        if f.is_null() {
            Err(err)
        } else {
            Ok(File(f))
        }
    }
}

impl Drop for File {
    fn drop(&mut self) {
        unsafe { sys::padlinux_close(self.0) }
    }
}

fn read_all(path: &str) -> std::result::Result<Vec<u8>, i32> {
    let f = File::open(path, false)?;
    let mut data = Vec::new();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        match unsafe { sys::padlinux_read(f.0, buf.as_mut_ptr() as *mut c_void, buf.len() as _) } {
            0 => return Ok(data),
            n if n < 0 => return Err(n as i32),
            n => data.extend_from_slice(&buf[..n as usize]),
        }
    }
}

fn write_all(path: &str, mut data: &[u8]) -> std::result::Result<(), i32> {
    let f = File::open(path, true)?;
    while !data.is_empty() {
        match unsafe { sys::padlinux_write(f.0, data.as_ptr() as *const c_void, data.len() as _) } {
            n if n <= 0 => return Err(if n == 0 { -28 } else { n as i32 }),
            n => data = &data[n as usize..],
        }
    }
    Ok(())
}

/// vendor/ish-shim/padlinux.h, linked into the app with LinuxKernel.xcframework.
#[cfg(target_os = "ios")]
mod sys {
    use std::ffi::{c_char, c_int, c_long, c_uint, c_ulong, c_ulonglong, c_void};
    extern "C" {
        pub fn padlinux_spawn(cmd: *const c_char, in_fd: c_int, out_fd: c_int, err_fd: c_int, exit_fd: c_int) -> c_int;
        pub fn padlinux_stat(path: *const c_char, follow: c_int, mode: *mut c_uint, size: *mut c_ulonglong) -> c_int;
        pub fn padlinux_list(dir: *const c_char, each: extern "C" fn(*mut c_void, *const c_char, c_uint), ctx: *mut c_void) -> c_int;
        pub fn padlinux_open(path: *const c_char, write: c_int, err: *mut c_int) -> *mut c_void;
        pub fn padlinux_read(file: *mut c_void, buf: *mut c_void, n: c_ulong) -> c_long;
        pub fn padlinux_write(file: *mut c_void, buf: *const c_void, n: c_ulong) -> c_long;
        pub fn padlinux_close(file: *mut c_void);
    }
}

/// Elsewhere (the Mac's `cargo test`) there's no guest: everything fails with ENODEV.
#[cfg(not(target_os = "ios"))]
#[allow(clippy::missing_safety_doc)]
mod sys {
    use std::ffi::{c_char, c_int, c_long, c_uint, c_ulong, c_ulonglong, c_void};
    pub unsafe fn padlinux_spawn(_: *const c_char, i: c_int, o: c_int, e: c_int, x: c_int) -> c_int {
        for fd in [i, o, e, x] {
            libc_close(fd);
        }
        -19
    }
    pub unsafe fn padlinux_stat(_: *const c_char, _: c_int, _: *mut c_uint, _: *mut c_ulonglong) -> c_int {
        -19
    }
    pub unsafe fn padlinux_list(_: *const c_char, _: extern "C" fn(*mut c_void, *const c_char, c_uint), _: *mut c_void) -> c_int {
        -19
    }
    pub unsafe fn padlinux_open(_: *const c_char, _: c_int, err: *mut c_int) -> *mut c_void {
        *err = -19;
        std::ptr::null_mut()
    }
    pub unsafe fn padlinux_read(_: *mut c_void, _: *mut c_void, _: c_ulong) -> c_long {
        -19
    }
    pub unsafe fn padlinux_write(_: *mut c_void, _: *const c_void, _: c_ulong) -> c_long {
        -19
    }
    pub unsafe fn padlinux_close(_: *mut c_void) {}
    fn libc_close(fd: c_int) {
        use std::os::fd::FromRawFd;
        drop(unsafe { std::os::fd::OwnedFd::from_raw_fd(fd) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wait_status_and_kinds() {
        assert_eq!(status_code(3 << 8), 3);
        assert_eq!(status_code(0), 0);
        assert_eq!(status_code(9), -1); // SIGKILL
        assert_eq!((kind(0o040755), kind(0o120777), kind(0o100644)), ("dir", "link", "file"));
        assert!(errno(-2).to_string().contains("No such file"));
    }
}
