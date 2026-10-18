//! One connected desktop: files, processes, search and terminals, for macOS,
//! Linux and Windows hosts alike. Everything goes through the CLI control
//! server's methods (`cli/src/tunnels/control_server.rs`).

use crate::{
    lsp::{self, LanguageServer},
    rpc::{wait_reply, Rpc, StreamRx, StreamTx, VersionInfo},
    Error, Result,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{sync::oneshot, task::JoinSet};
use tunnels::connections::ClientRelayHandle;

const PTY_UNIX: &str = include_str!("../helpers/pty_unix.py");
const CONPTY_PS1: &str = include_str!("../helpers/conpty.ps1");

/// Directories never worth walking for Quick Open.
const SKIP_DIRS: &[&str] = &[
    ".git", "node_modules", "target", ".venv", "venv", "__pycache__", ".next", "dist", "build",
    "Pods", "DerivedData", ".gradle", ".idea",
];
const WALK_CONCURRENCY: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Os {
    Mac,
    Linux,
    Windows,
}

#[derive(Debug, Clone)]
pub struct Env {
    pub os: Os,
    pub os_release: String,
    pub home: String,
    pub vars: HashMap<String, String>,
    pub cli_version: String,
    pub protocol: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub enum EntryKind {
    #[serde(rename = "dir")]
    Dir,
    #[serde(rename = "file")]
    File,
    #[serde(rename = "link")]
    Link,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DirEntry {
    pub name: String,
    #[serde(rename = "type")]
    pub kind: Option<EntryKind>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Stat {
    pub exists: bool,
    pub size: Option<u64>,
    #[serde(rename = "type")]
    pub kind: Option<EntryKind>,
}

#[derive(Debug, Clone)]
pub struct Output {
    pub code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct SearchOpts {
    pub match_case: bool,
    pub whole_word: bool,
    pub regex: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchHit {
    /// Path relative to the search root, always with `/`.
    pub path: String,
    pub line: u32,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Eol {
    Lf,
    Crlf,
}

/// How terminals are hosted on a given desktop.
#[derive(Debug, Clone)]
enum PtyMode {
    /// Python pty helper (resizable). Holds the interpreter path.
    Python(String),
    /// `script(1)` fallback when no Python: works, but can't resize.
    Script,
    /// PowerShell + ConPTY helper written to this path (resizable).
    ConPty(String),
}

#[derive(Deserialize)]
struct GetEnv {
    env: HashMap<String, String>,
    os_platform: String,
    os_release: String,
}

#[derive(Deserialize)]
struct ReadDir {
    contents: Vec<DirEntry>,
}

#[derive(Deserialize)]
struct SpawnResult {
    exit_code: i32,
}

#[derive(Deserialize)]
struct Empty {}

#[derive(Serialize)]
struct SpawnParams<'a> {
    command: &'a str,
    args: &'a [String],
    cwd: Option<&'a str>,
    env: HashMap<String, String>,
}

pub struct Session {
    rpc: Rpc,
    // Dropping the relay handle closes the SSH session, so it lives here.
    _relay: ClientRelayHandle,
    pub machine: String,
    pub env: Env,
    pty: tokio::sync::Mutex<Option<PtyMode>>,
    /// Language-server binaries found on the desktop, and its login-shell PATH.
    lsp_bins: tokio::sync::Mutex<Option<(HashMap<String, Vec<String>>, Option<String>)>>,
    /// Running servers by "spec key \0 root folder".
    lsp_servers: tokio::sync::Mutex<HashMap<String, Arc<LanguageServer>>>,
    /// Desktop port -> (iPad port, accept loop).
    forwards: Mutex<HashMap<u16, (u16, tokio::task::JoinHandle<()>)>>,
    /// pid of this connection's lease process on the desktop (see `leashed`).
    lease: tokio::sync::OnceCell<Option<u32>>,
}

impl Session {
    pub(crate) async fn start(
        rpc: Rpc,
        relay: ClientRelayHandle,
        machine: String,
        version: VersionInfo,
    ) -> Result<Session> {
        let e: GetEnv = rpc.call("get_env", json!({})).await?;
        let os = match e.os_platform.as_str() {
            "darwin" => Os::Mac,
            "win32" => Os::Windows,
            _ => Os::Linux,
        };
        let home_var = if os == Os::Windows { "USERPROFILE" } else { "HOME" };
        let home = e.env.get(home_var).cloned().unwrap_or_else(|| {
            if os == Os::Windows { "C:\\".into() } else { "/".into() }
        });
        Ok(Session {
            rpc,
            _relay: relay,
            machine,
            env: Env {
                os,
                os_release: e.os_release,
                home,
                vars: e.env,
                cli_version: version.version,
                protocol: version.protocol_version,
            },
            pty: tokio::sync::Mutex::new(None),
            lsp_bins: tokio::sync::Mutex::new(None),
            lsp_servers: tokio::sync::Mutex::new(HashMap::new()),
            lease: tokio::sync::OnceCell::new(),
            forwards: Mutex::new(HashMap::new()),
        })
    }

    pub fn join(&self, base: &str, name: &str) -> String {
        join(self.env.os, base, name)
    }

    /// Quick liveness check. A connection that died while the iPad slept can
    /// look open for a minute (no FIN), so don't wait longer than a few seconds.
    pub async fn ping(&self) -> Result<()> {
        if self._relay.is_closed() {
            return Err(Error::Closed);
        }
        match tokio::time::timeout(Duration::from_secs(5), self.rpc.call::<_, Empty>("ping", json!({}))).await {
            Ok(r) => r.map(|_| ()),
            Err(_) => Err(Error::Closed),
        }
    }

    pub async fn stat(&self, path: &str) -> Result<Stat> {
        self.rpc.call("fs_stat", json!({ "path": path })).await
    }

    /// Directory listing, folders first, then case-insensitive by name.
    pub async fn list_dir(&self, path: &str) -> Result<Vec<DirEntry>> {
        let mut entries = read_dir(&self.rpc, path).await?;
        entries.sort_by(|a, b| {
            let dir = |e: &DirEntry| e.kind != Some(EntryKind::Dir);
            dir(a).cmp(&dir(b)).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        Ok(entries)
    }

    pub async fn read_file(&self, path: &str) -> Result<Vec<u8>> {
        let mut d = self.rpc.call_duplex("fs_read", json!({ "path": path })).await?;
        let (_, rx) = d.streams.pop().ok_or_else(|| Error::Protocol("fs_read: no stream".into()))?;
        let data = collect(rx).await;
        wait_reply::<Empty>(d.reply).await?;
        Ok(data)
    }

    pub async fn write_file(&self, path: &str, data: &[u8]) -> Result<()> {
        let mut d = self.rpc.call_duplex("fs_write", json!({ "path": path })).await?;
        let (tx, _) = d.streams.pop().ok_or_else(|| Error::Protocol("fs_write: no stream".into()))?;
        tx.write(data)?;
        tx.end()?;
        wait_reply::<Empty>(d.reply).await.map(|_| ())
    }

    /// Saves only if the file still holds `original` (what the editor loaded).
    /// The control server's stat has no mtime, so compare contents instead.
    pub async fn save_file(&self, path: &str, data: &[u8], original: &[u8]) -> Result<()> {
        match self.read_file(path).await {
            Ok(current) if current != original => return Err(Error::Conflict),
            _ => {} // unchanged, or deleted meanwhile: write it back
        }
        self.write_file(path, data).await
    }

    pub async fn mkdirp(&self, path: &str) -> Result<()> {
        self.rpc.call::<_, Empty>("fs_mkdirp", json!({ "path": path })).await.map(|_| ())
    }

    /// Deletes a file or folder. The CLI's `fs_rm` is `remove_dir_all`, which
    /// refuses plain files, so a file is first moved into a scratch folder
    /// beside it (same volume, so the rename is cheap) and that folder removed.
    pub async fn remove(&self, path: &str) -> Result<()> {
        let st = self.stat(path).await?;
        if !st.exists {
            return Ok(());
        }
        if st.kind == Some(EntryKind::Dir) {
            return self.rpc.call::<_, Empty>("fs_rm", json!({ "path": path })).await.map(|_| ());
        }
        let trimmed = path.trim_end_matches(['/', '\\']);
        let cut = trimmed.rfind(['/', '\\']).ok_or_else(|| Error::Remote(format!("can't delete {path}")))?;
        let (parent, name) = (&trimmed[..cut.max(1)], &trimmed[cut + 1..]);
        let scratch = join(self.env.os, parent, &format!(".padcode-delete-{:016x}", fnv1a(format!("{path}{:?}", std::time::SystemTime::now()).as_bytes())));
        self.mkdirp(&scratch).await?;
        if let Err(e) = self.rename(path, &join(self.env.os, &scratch, name)).await {
            let _ = self.rpc.call::<_, Empty>("fs_rm", json!({ "path": scratch })).await;
            return Err(e);
        }
        self.rpc.call::<_, Empty>("fs_rm", json!({ "path": scratch })).await.map(|_| ())
    }

    pub async fn rename(&self, from: &str, to: &str) -> Result<()> {
        self.rpc
            .call::<_, Empty>("fs_rename", json!({ "from_path": from, "to_path": to }))
            .await
            .map(|_| ())
    }

    pub(crate) async fn spawn(
        &self,
        command: &str,
        args: &[String],
        cwd: Option<&str>,
        env: HashMap<String, String>,
    ) -> Result<(StreamTx, StreamRx, StreamRx, oneshot::Receiver<Result<Vec<u8>>>)> {
        let d = self
            .rpc
            .call_duplex("spawn", SpawnParams { command, args, cwd, env })
            .await?;
        let mut it = d.streams.into_iter();
        match (it.next(), it.next(), it.next()) {
            (Some((stdin, _)), Some((_, stdout)), Some((_, stderr))) => {
                Ok((stdin, stdout, stderr, d.reply))
            }
            _ => Err(Error::Protocol("spawn: expected 3 streams".into())),
        }
    }

    /// The VS Code CLI never kills what `spawn` started, even after the
    /// connection drops, so language servers and terminal helpers would pile up
    /// on the desktop. Each connection runs a lease process the iPad pings every
    /// 30 s; it exits after 2 minutes without one, and a watcher next to every
    /// long-lived process kills it once the lease is gone.
    async fn lease(&self) -> Option<u32> {
        *self
            .lease
            .get_or_init(|| async {
                // ponytail: Unix with Python only; on Windows spawned processes still outlive the connection.
                let PtyMode::Python(py) = self.pty_mode().await.ok()? else { return None };
                let script = "# padcode-lease\nimport os,select\nprint(os.getpid(),flush=True)\n\
                              while select.select([0],[],[],120)[0] and os.read(0,64): pass";
                let (stdin, mut stdout, _, _) =
                    self.spawn(&py, &["-c".into(), script.into()], None, HashMap::new()).await.ok()?;
                let first = tokio::time::timeout(Duration::from_secs(10), stdout.recv()).await.ok()??;
                let pid = String::from_utf8_lossy(&first).trim().parse().ok()?;
                tokio::spawn(async move {
                    while stdin.write(b"\n").is_ok() {
                        tokio::time::sleep(Duration::from_secs(30)).await;
                    }
                });
                Some(pid)
            })
            .await
    }

    /// `command args` wrapped so it's killed when this connection's lease ends.
    async fn leashed(&self, command: String, args: Vec<String>) -> (String, Vec<String>) {
        match self.lease().await {
            Some(lease) => leash(lease, command, args),
            None => (command, args),
        }
    }

    /// Runs a command to completion (no stdin).
    pub async fn run(&self, command: &str, args: &[&str], cwd: Option<&str>) -> Result<Output> {
        let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        let (stdin, stdout, stderr, reply) = self.spawn(command, &args, cwd, HashMap::new()).await?;
        stdin.end()?;
        let (stdout, stderr) = tokio::join!(collect(stdout), collect(stderr));
        let r: SpawnResult = wait_reply(reply).await?;
        Ok(Output { code: r.exit_code, stdout, stderr })
    }

    /// Relative paths (with `/`) of files under `root`, for Quick Open.
    pub async fn walk(&self, root: &str, limit: usize) -> Result<Vec<String>> {
        let os = self.env.os;
        let mut files = Vec::new();
        let mut queue = vec![String::new()];
        let mut jobs = JoinSet::new();
        loop {
            while jobs.len() < WALK_CONCURRENCY {
                let Some(rel) = queue.pop() else { break };
                let rpc = self.rpc.clone();
                let full = if rel.is_empty() { root.to_string() } else { join(os, root, &rel) };
                jobs.spawn(async move { (rel, read_dir(&rpc, &full).await) });
            }
            let Some(done) = jobs.join_next().await else { break };
            let (rel, entries) = done.map_err(|e| Error::Protocol(e.to_string()))?;
            let entries = match entries {
                Ok(e) => e,
                Err(_) if !rel.is_empty() => continue, // unreadable subfolder
                Err(e) => return Err(e),
            };
            for e in entries {
                let child = if rel.is_empty() { e.name.clone() } else { format!("{rel}/{}", e.name) };
                match e.kind {
                    Some(EntryKind::Dir) if !SKIP_DIRS.contains(&e.name.as_str()) => queue.push(child),
                    Some(EntryKind::File) | Some(EntryKind::Link) => files.push(child),
                    _ => {}
                }
            }
            if files.len() >= limit {
                files.truncate(limit);
                break;
            }
        }
        files.sort();
        Ok(files)
    }

    /// Case-insensitive literal text search under `root`: ripgrep where there
    /// is one, else grep (macOS/Linux) or findstr (Windows).
    /// Text search under `root`: ripgrep where there is one, else grep
    /// (macOS/Linux) or findstr (Windows). Literal unless `opts.regex`.
    pub async fn search(&self, root: &str, query: &str, max: usize, opts: SearchOpts) -> Result<Vec<SearchHit>> {
        let mut rg_args = vec!["-n", "--no-heading", "--color", "never", "-M", "400"];
        rg_args.push(if opts.match_case { "-s" } else { "-i" });
        if !opts.regex {
            rg_args.push("-F");
        }
        if opts.whole_word {
            rg_args.push("-w");
        }
        rg_args.extend(["--", query, "."]);
        let mut tools: Vec<(String, Vec<&str>)> =
            rg_candidates(self.env.os, &self.env.vars).into_iter().map(|p| (p, rg_args.clone())).collect();
        let findstr_query = format!("/c:{query}");
        let grep_flags = format!(
            "-rnI{}{}{}",
            if opts.regex { "E" } else { "F" },
            if opts.match_case { "" } else { "i" },
            if opts.whole_word { "w" } else { "" }
        );
        match self.env.os {
            // findstr has no whole-word mode; its regex dialect is minimal.
            Os::Windows => {
                let mut a = vec!["/s", "/n", "/p", if opts.regex { "/r" } else { "/l" }];
                if !opts.match_case {
                    a.push("/i");
                }
                a.extend([findstr_query.as_str(), "*"]);
                tools.push(("findstr".into(), a))
            }
            _ => tools.push((
                "grep".into(),
                vec![grep_flags.as_str(), "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=target", "--", query, "."],
            )),
        }
        for (tool, args) in tools {
            // A missing tool fails to spawn; exit 1 just means "no matches".
            let Ok(out) = self.run(&tool, &args, Some(root)).await else { continue };
            if out.code > 1 {
                continue;
            }
            return Ok(String::from_utf8_lossy(&out.stdout)
                .lines()
                .filter_map(parse_search_line)
                .take(max)
                .collect());
        }
        Err(Error::Remote("no search tool (rg, grep or findstr) on the desktop".into()))
    }

    /// Opens a login shell on a real pty (ConPTY on Windows) on the desktop.
    /// `session`: a persistent shell to attach to (created if missing), with
    /// `offset` = output bytes already received. Persistence needs the Python
    /// helper (macOS/Linux); elsewhere it's a plain shell.
    pub async fn open_terminal(&self, cols: u16, rows: u16, cwd: Option<&str>, session: Option<&str>, offset: u64) -> Result<Terminal> {
        let mode = self.pty_mode().await?;
        let (c, r) = (cols.to_string(), rows.to_string());
        let mut env = HashMap::new();
        env.insert("TERM".to_string(), "xterm-256color".to_string());
        env.insert("COLORTERM".to_string(), "truecolor".to_string());
        let (command, args): (String, Vec<String>) = match &mode {
            PtyMode::Python(py) => match session {
                Some(id) => (py.clone(), vec!["-c".into(), PTY_UNIX.into(), "attach".into(), id.into(), c, r, offset.to_string()]),
                None => (py.clone(), vec!["-c".into(), PTY_UNIX.into(), c, r]),
            },
            PtyMode::Script if self.env.os == Os::Mac => (
                "/usr/bin/script".into(),
                vec!["-q".into(), "/dev/null".into(), "/bin/sh".into(), "-c".into(), script_shell(&c, &r, "/bin/zsh")],
            ),
            PtyMode::Script => (
                "script".into(),
                vec!["-qfc".into(), script_shell(&c, &r, "/bin/bash"), "/dev/null".into()],
            ),
            PtyMode::ConPty(ps1) => (
                "powershell.exe".into(),
                ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ps1]
                    .iter()
                    .map(|s| s.to_string())
                    .chain([c, r])
                    .collect(),
            ),
        };
        let cwd = cwd.unwrap_or(&self.env.home);
        let (command, args) = self.leashed(command, args).await;
        let (stdin, stdout, stderr, reply) = self.spawn(&command, &args, Some(cwd), env).await?;

        let (out_tx, output) = tokio::sync::mpsc::unbounded_channel();
        for mut rx in [stdout, stderr] {
            let out_tx = out_tx.clone();
            tokio::spawn(async move {
                while let Some(chunk) = rx.recv().await {
                    if out_tx.send(chunk).is_err() {
                        break;
                    }
                }
            });
        }
        let (exit_tx, exit) = oneshot::channel();
        tokio::spawn(async move {
            // None = the tunnel dropped, so the shell's fate is unknown.
            let code = match wait_reply::<SpawnResult>(reply).await {
                Ok(r) => Some(r.exit_code),
                Err(Error::Closed) => None,
                Err(_) => Some(-1),
            };
            let _ = exit_tx.send(code);
        });
        Ok(Terminal {
            input: TermInput { stdin, resizable: !matches!(mode, PtyMode::Script) },
            output,
            exit,
        })
    }

    // MARK: ports

    /// Serves a desktop port on 127.0.0.1:<returned port> on the iPad: each
    /// connection is piped through the tunnel to the desktop's localhost.
    pub async fn forward_port(&self, remote_port: u16) -> Result<u16> {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .map_err(|e| Error::Remote(format!("can't listen locally: {e}")))?;
        let local = listener.local_addr().map_err(|e| Error::Remote(e.to_string()))?.port();
        let rpc = self.rpc.clone();
        let task = tokio::spawn(async move {
            while let Ok((sock, _)) = listener.accept().await {
                let _ = sock.set_nodelay(true);
                let rpc = rpc.clone();
                tokio::spawn(async move {
                    let Ok(mut d) = rpc
                        .call_duplex("net_connect", json!({ "host": "127.0.0.1", "port": remote_port }))
                        .await
                    else {
                        return;
                    };
                    let Some((tx, mut rx)) = d.streams.pop() else { return };
                    let (mut rd, mut wr) = sock.into_split();
                    let up = tokio::spawn(async move {
                        use tokio::io::AsyncReadExt;
                        let mut buf = vec![0u8; 64 * 1024];
                        while let Ok(n) = rd.read(&mut buf).await {
                            if n == 0 || tx.write(&buf[..n]).is_err() {
                                break;
                            }
                        }
                        let _ = tx.end();
                    });
                    use tokio::io::AsyncWriteExt;
                    while let Some(chunk) = rx.recv().await {
                        if wr.write_all(&chunk).await.is_err() {
                            break;
                        }
                    }
                    let _ = wr.shutdown().await;
                    up.abort();
                });
            }
        });
        self.forwards.lock().unwrap().insert(remote_port, (local, task));
        Ok(local)
    }

    pub fn stop_forward(&self, remote_port: u16) {
        if let Some((_, task)) = self.forwards.lock().unwrap().remove(&remote_port) {
            task.abort();
        }
    }

    /// TCP ports something is listening on at the desktop, with process names.
    pub async fn listening_ports(&self) -> Result<Vec<(u16, String)>> {
        let out = match self.env.os {
            Os::Mac => self.run("/usr/sbin/lsof", &["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "cn"], None).await?,
            Os::Linux => self.run("/bin/sh", &["-c", "ss -ltnpH 2>/dev/null || netstat -ltnp 2>/dev/null"], None).await?,
            Os::Windows => self
                .run("powershell.exe", &["-NoProfile", "-Command",
                    "Get-NetTCPConnection -State Listen | ForEach-Object { \"$($_.LocalPort) $((Get-Process -Id $_.OwningProcess -EA SilentlyContinue).ProcessName)\" }"], None)
                .await?,
        };
        Ok(parse_listening(self.env.os, &String::from_utf8_lossy(&out.stdout)))
    }

    // MARK: language servers

    /// The shared language server for `language` (a VS Code language id) in
    /// `root`, started on first use.
    pub async fn language_server(&self, language: &str, root: &str, on_event: lsp::EventFn) -> Result<Arc<LanguageServer>> {
        let spec = lsp::spec_for(language).ok_or_else(|| Error::NoLanguageServer {
            language: language.to_string(),
            install: String::new(),
            detail: "PadCode has no language server for this language yet".into(),
        })?;
        let key = format!("{}\0{root}", spec.key);
        let mut servers = self.lsp_servers.lock().await;
        if let Some(s) = servers.get(&key).filter(|s| s.alive()) {
            return Ok(s.clone());
        }
        let (bins, path) = self.find_language_servers().await;
        let mut errors = Vec::new();
        for (bin, args) in spec.candidates {
            for exe in bins.get(*bin).into_iter().flatten() {
                match self.start_language_server(exe, args, root, path.as_deref(), on_event.clone()).await {
                    Ok(server) => {
                        servers.insert(key, server.clone());
                        return Ok(server);
                    }
                    Err(e) => errors.push(e.to_string()),
                }
            }
        }
        Err(Error::NoLanguageServer {
            language: spec.name.to_string(),
            install: lsp::install_hint(spec.key, self.env.os).to_string(),
            detail: errors.join("\n"),
        })
    }

    /// Shuts down every language server (folder closed or switched).
    pub async fn stop_language_servers(&self) {
        let servers: Vec<_> = self.lsp_servers.lock().await.drain().map(|(_, s)| s).collect();
        for s in servers {
            s.shutdown().await;
        }
    }

    async fn start_language_server(
        &self,
        exe: &str,
        args: &[&str],
        root: &str,
        path_env: Option<&str>,
        on_event: lsp::EventFn,
    ) -> Result<Arc<LanguageServer>> {
        let lower = exe.to_ascii_lowercase();
        // npm installs .cmd shims on Windows, which only cmd.exe can run.
        let (command, mut argv) = if self.env.os == Os::Windows && (lower.ends_with(".cmd") || lower.ends_with(".bat")) {
            ("cmd.exe".to_string(), vec!["/d".to_string(), "/c".to_string(), exe.to_string()])
        } else {
            (exe.to_string(), vec![])
        };
        argv.extend(args.iter().map(|a| a.to_string()));
        let mut env = HashMap::new();
        if let Some(p) = path_env {
            env.insert("PATH".to_string(), p.to_string());
        }
        let (command, argv) = self.leashed(command, argv).await;
        let (stdin, stdout, mut stderr, _exit) = self.spawn(&command, &argv, Some(root), env).await?;
        let tail = Arc::new(Mutex::new(Vec::new()));
        let sink = tail.clone();
        tokio::spawn(async move {
            while let Some(chunk) = stderr.recv().await {
                let mut t = sink.lock().unwrap();
                t.extend_from_slice(&chunk);
                let n = t.len();
                if n > 4096 {
                    t.drain(..n - 4096);
                }
            }
        });
        let name = exe.rsplit(['/', '\\']).next().unwrap_or(exe);
        let name = name.split('.').next().unwrap_or(name).to_string();
        let end = stdin.clone();
        LanguageServer::start(
            name,
            self.env.os,
            root,
            Box::new(move |b| stdin.write(b)),
            Box::new(move || {
                let _ = end.end();
            }),
            stdout,
            tail,
            on_event,
        )
        .await
    }

    /// Looks up every known server binary once per connection, through the
    /// user's login shell so ~/.cargo/bin, npm globals etc. are on PATH (the
    /// tunnel service itself runs with a minimal PATH).
    async fn find_language_servers(&self) -> (HashMap<String, Vec<String>>, Option<String>) {
        let mut cached = self.lsp_bins.lock().await;
        if let Some(c) = cached.as_ref() {
            return c.clone();
        }
        let names: Vec<&str> = lsp::SPECS.iter().flat_map(|s| s.candidates.iter().map(|c| c.0)).collect();
        let outputs = match self.env.os {
            Os::Windows => {
                let list = names.iter().map(|n| format!("'{n}'")).collect::<Vec<_>>().join(",");
                let script = format!(
                    "$ErrorActionPreference='SilentlyContinue'; foreach ($c in @({list})) {{ Get-Command $c -All | \
                     Where-Object {{ $_.Source -match '\\.(exe|cmd|bat)$' }} | ForEach-Object {{ \"__PCBIN__$c=$($_.Source)\" }} }}; \
                     Get-ChildItem \"$env:USERPROFILE\\.vscode\\extensions\\rust-lang.rust-analyzer-*\\server\\rust-analyzer.exe\" | \
                     ForEach-Object {{ \"__PCBIN__rust-analyzer=$($_.FullName)\" }}"
                );
                let args = ["-NoProfile", "-NonInteractive", "-Command", script.as_str()];
                vec![self.run_with_timeout("powershell.exe", &args).await]
            }
            _ => {
                let script = format!(
                    "printf '__PCPATH__%s\\n' \"$PATH\"; \
                     for c in {}; do p=$(command -v \"$c\" 2>/dev/null) && printf '__PCBIN__%s=%s\\n' \"$c\" \"$p\"; done; \
                     for p in \"$HOME\"/.vscode/extensions/rust-lang.rust-analyzer-*/server/rust-analyzer; do \
                       [ -x \"$p\" ] && printf '__PCBIN__rust-analyzer=%s\\n' \"$p\"; done; true",
                    names.join(" ")
                );
                let shell = self.env.vars.get("SHELL").cloned().unwrap_or_else(|| "/bin/sh".into());
                let first = self.run_with_timeout(&shell, &["-ilc", &script]).await;
                // Non-POSIX login shells (fish) can't run the script: fall back to sh.
                if first.contains("__PCPATH__") {
                    vec![first]
                } else {
                    vec![self.run_with_timeout("/bin/sh", &["-lc", &script]).await]
                }
            }
        };
        let mut bins: HashMap<String, Vec<String>> = HashMap::new();
        let mut path = None;
        for line in outputs.iter().flat_map(|o| o.lines()) {
            if let Some(p) = line.strip_prefix("__PCPATH__") {
                path = Some(p.trim().to_string());
            } else if let Some((name, exe)) = line.strip_prefix("__PCBIN__").and_then(|l| l.split_once('=')) {
                let exe = exe.trim();
                // zsh's `command -v` prints alias definitions; only keep real paths
                let real = exe.starts_with('/') || exe.get(1..2) == Some(":");
                let list = bins.entry(name.to_string()).or_default();
                if real && !list.iter().any(|e| e == exe) {
                    list.push(exe.to_string());
                }
            }
        }
        *cached = Some((bins, path));
        cached.clone().unwrap()
    }

    async fn run_with_timeout(&self, command: &str, args: &[&str]) -> String {
        match tokio::time::timeout(Duration::from_secs(20), self.run(command, args, None)).await {
            Ok(Ok(out)) => String::from_utf8_lossy(&out.stdout).into_owned(),
            _ => String::new(),
        }
    }

    async fn pty_mode(&self) -> Result<PtyMode> {
        let mut cached = self.pty.lock().await;
        if let Some(m) = cached.as_ref() {
            return Ok(m.clone());
        }
        let mode = match self.env.os {
            // /usr/bin/python3 is only real once Xcode or its Command Line
            // Tools are installed; otherwise it pops an install dialog.
            Os::Mac => match self.run("/usr/bin/xcode-select", &["-p"], None).await {
                Ok(o) if o.code == 0 => PtyMode::Python("/usr/bin/python3".into()),
                _ => PtyMode::Script,
            },
            Os::Linux => match self.run("/bin/sh", &["-c", "command -v python3"], None).await {
                Ok(o) if o.code == 0 => PtyMode::Python("python3".into()),
                _ => PtyMode::Script,
            },
            Os::Windows => PtyMode::ConPty(self.install_conpty_helper().await?),
        };
        *cached = Some(mode.clone());
        Ok(mode)
    }

    /// Writes the ConPTY helper to %TEMP%\padcode once per helper version.
    async fn install_conpty_helper(&self) -> Result<String> {
        let temp = self
            .env
            .vars
            .get("TEMP")
            .or_else(|| self.env.vars.get("TMP"))
            .cloned()
            .unwrap_or_else(|| join(Os::Windows, &self.env.home, "AppData\\Local\\Temp"));
        let dir = join(Os::Windows, &temp, "padcode");
        let path = join(Os::Windows, &dir, &format!("conpty-{:016x}.ps1", fnv1a(CONPTY_PS1.as_bytes())));
        if !self.stat(&path).await?.exists {
            self.mkdirp(&dir).await?;
            self.write_file(&path, CONPTY_PS1.as_bytes()).await?;
        }
        Ok(path)
    }
}

/// A shell on the desktop. Read `output` until it closes; `exit` then yields
/// the exit code.
pub struct Terminal {
    pub input: TermInput,
    pub output: tokio::sync::mpsc::UnboundedReceiver<Vec<u8>>,
    /// Exit code, or None if the connection was lost first.
    pub exit: oneshot::Receiver<Option<i32>>,
}

#[derive(Clone)]
pub struct TermInput {
    stdin: StreamTx,
    /// False on the `script(1)` fallback, where resize is a no-op.
    pub resizable: bool,
}

impl TermInput {
    pub fn write(&self, data: &[u8]) -> Result<()> {
        self.stdin.write(data)
    }

    pub fn resize(&self, cols: u16, rows: u16) -> Result<()> {
        if !self.resizable {
            return Ok(());
        }
        self.stdin.write(resize_frame(cols, rows).as_bytes())
    }

    /// Ends stdin: a plain shell is hung up; a persistent one is detached
    /// (it keeps running for a later reattach).
    pub fn close(&self) -> Result<()> {
        self.stdin.end()
    }

    /// Ends the shell itself, persistent or not.
    pub fn kill(&self) -> Result<()> {
        if self.resizable {
            let _ = self.stdin.write(b"\x1b]7777;kill\x07");
        }
        self.stdin.end()
    }
}

/// In-band resize message understood by both helpers.
fn resize_frame(cols: u16, rows: u16) -> String {
    format!("\x1b]7777;{cols};{rows}\x07")
}

fn script_shell(cols: &str, rows: &str, default_shell: &str) -> String {
    format!("stty cols {cols} rows {rows} 2>/dev/null; exec \"${{SHELL:-{default_shell}}}\" -l")
}

async fn read_dir(rpc: &Rpc, path: &str) -> Result<Vec<DirEntry>> {
    rpc.call::<_, ReadDir>("fs_readdir", json!({ "path": path })).await.map(|r| r.contents)
}

async fn collect(mut rx: StreamRx) -> Vec<u8> {
    let mut data = Vec::new();
    while let Some(chunk) = rx.recv().await {
        data.extend(chunk);
    }
    data
}

/// ripgrep on PATH first, then the copy bundled inside desktop VS Code.
fn rg_candidates(os: Os, vars: &HashMap<String, String>) -> Vec<String> {
    const BUNDLED: &str = "node_modules.asar.unpacked/@vscode/ripgrep/bin/rg";
    match os {
        Os::Mac => vec![
            "rg".into(),
            format!("/Applications/Visual Studio Code.app/Contents/Resources/app/{BUNDLED}"),
        ],
        Os::Linux => vec![
            "rg".into(),
            format!("/usr/share/code/resources/app/{BUNDLED}"),
            format!("/snap/code/current/usr/share/code/resources/app/{BUNDLED}"),
        ],
        Os::Windows => {
            let mut v = vec!["rg.exe".to_string()];
            if let Some(local) = vars.get("LOCALAPPDATA") {
                v.push(format!(
                    "{local}\\Programs\\Microsoft VS Code\\resources\\app\\{}.exe",
                    BUNDLED.replace('/', "\\")
                ));
            }
            v
        }
    }
}

/// Joins a path for the desktop's OS (Windows accepts `/` too, but keep it native).
pub fn join(os: Os, base: &str, name: &str) -> String {
    let sep = if os == Os::Windows { '\\' } else { '/' };
    let name = if os == Os::Windows { name.replace('/', "\\") } else { name.to_string() };
    if base.ends_with(sep) || (os == Os::Windows && base.ends_with('/')) {
        format!("{base}{name}")
    } else {
        format!("{base}{sep}{name}")
    }
}

/// Line ending of a file, decided by its first newline (LF if none).
pub fn detect_eol(text: &[u8]) -> Eol {
    match text.iter().position(|&b| b == b'\n') {
        Some(i) if i > 0 && text[i - 1] == b'\r' => Eol::Crlf,
        _ => Eol::Lf,
    }
}

/// Parses `path:line:text` as printed by rg -n, grep -rn and findstr /s /n.
pub fn parse_search_line(line: &str) -> Option<SearchHit> {
    let mut parts = line.splitn(3, ':');
    let path = parts.next()?;
    let num = parts.next()?.parse().ok()?;
    let text = parts.next().unwrap_or("");
    let path = path.trim_start_matches("./").trim_start_matches(".\\").replace('\\', "/");
    Some(SearchHit { path, line: num, text: text.trim_end_matches('\r').to_string() })
}

/// Parses `lsof -F cn`, `ss -ltnpH` / `netstat -ltnp`, or "port name" lines.
pub(crate) fn parse_listening(os: Os, text: &str) -> Vec<(u16, String)> {
    let mut out: Vec<(u16, String)> = Vec::new();
    let port_of = |addr: &str| addr.rsplit(':').next().and_then(|p| p.parse::<u16>().ok());
    match os {
        Os::Mac => {
            let mut name = String::new();
            for line in text.lines() {
                if let Some(c) = line.strip_prefix('c') {
                    name = c.to_string();
                } else if let Some(p) = line.strip_prefix('n').and_then(port_of) {
                    out.push((p, name.clone()));
                }
            }
        }
        Os::Linux => {
            for line in text.lines() {
                let cols: Vec<&str> = line.split_whitespace().collect();
                // ss: State Recv Send Local Peer [Process]; netstat: Proto Recv Send Local Foreign State PID/Prog
                let (local, proc_col) = if cols.first() == Some(&"LISTEN") {
                    (cols.get(3), cols.get(5))
                } else if cols.first().is_some_and(|c| c.starts_with("tcp")) {
                    (cols.get(3), cols.get(6))
                } else {
                    continue;
                };
                let Some(p) = local.and_then(|a| port_of(a)) else { continue };
                let name = proc_col
                    .map(|c| c.split('"').nth(1).or_else(|| c.split('/').nth(1)).unwrap_or("").to_string())
                    .unwrap_or_default();
                out.push((p, name));
            }
        }
        Os::Windows => {
            for line in text.lines() {
                let mut it = line.trim().splitn(2, ' ');
                if let Some(p) = it.next().and_then(|p| p.parse().ok()) {
                    out.push((p, it.next().unwrap_or("").trim().to_string()));
                }
            }
        }
    }
    out.sort();
    out.dedup_by_key(|(p, _)| *p);
    out
}

fn fnv1a(data: &[u8]) -> u64 {
    data.iter().fold(0xcbf29ce484222325, |h, &b| (h ^ b as u64).wrapping_mul(0x100000001b3))
}

/// `sh -c … cmd args`: execs cmd (keeping its pid, stdin and stdout) next to a
/// watcher that SIGTERMs it once the `lease` process has exited.
fn leash(lease: u32, command: String, args: Vec<String>) -> (String, Vec<String>) {
    let script = format!(
        "P=$$; (while kill -0 {lease} && kill -0 $P; do sleep 10; done; kill -0 {lease} || kill $P) \
         </dev/null >/dev/null 2>&1 & exec \"$@\""
    );
    let argv = ["-c".to_string(), script, "sh".into(), command].into_iter().chain(args).collect();
    ("/bin/sh".into(), argv)
}

#[cfg(test)]
mod tests {
    #[test]
    fn leash_kills_when_lease_ends() {
        use std::process::{Command, Stdio};
        let mut lease = Command::new("sleep").arg("30").spawn().unwrap();
        let (sh, argv) = super::leash(lease.id(), "cat".into(), vec!["-u".into()]);
        let mut child = Command::new(sh)
            .args(argv)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(300));
        assert!(child.try_wait().unwrap().is_none(), "runs while the lease lives");
        lease.kill().unwrap();
        lease.wait().unwrap();
        for _ in 0..150 {
            if child.try_wait().unwrap().is_some() {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        panic!("still running 15 s after the lease ended");
    }

    use super::*;

    #[test]
    fn joins_per_os() {
        assert_eq!(join(Os::Mac, "/Users/me", "src/a.rs"), "/Users/me/src/a.rs");
        assert_eq!(join(Os::Linux, "/", "etc"), "/etc");
        assert_eq!(join(Os::Windows, "C:\\Users\\me", "src/a.rs"), "C:\\Users\\me\\src\\a.rs");
        assert_eq!(join(Os::Windows, "C:\\", "x"), "C:\\x");
        assert_eq!(join(Os::Windows, "C:/proj/", "x"), "C:/proj/x");
    }

    #[test]
    fn eol_detection() {
        assert_eq!(detect_eol(b"a\r\nb\r\n"), Eol::Crlf);
        assert_eq!(detect_eol(b"a\nb\r\n"), Eol::Lf);
        assert_eq!(detect_eol(b"\nx"), Eol::Lf);
        assert_eq!(detect_eol(b"no newline"), Eol::Lf);
    }

    #[test]
    fn search_lines_from_every_tool() {
        let hit = |p: &str, l, t: &str| Some(SearchHit { path: p.into(), line: l, text: t.into() });
        assert_eq!(parse_search_line("./src/main.rs:12:fn main() {"), hit("src/main.rs", 12, "fn main() {"));
        assert_eq!(parse_search_line("src\\lib.rs:3:let a = b::c;\r"), hit("src/lib.rs", 3, "let a = b::c;"));
        assert_eq!(parse_search_line("a.txt:7:"), hit("a.txt", 7, ""));
        assert_eq!(parse_search_line("Binary file x matches"), None);
    }

    #[test]
    fn listening_ports_per_os() {
        let mac = "p501\ncnode\nn*:3000\nn[::1]:3000\np77\ncPython\nn127.0.0.1:8000\n";
        assert_eq!(parse_listening(Os::Mac, mac), [(3000, "node".into()), (8000, "Python".into())]);
        let ss = "LISTEN 0 511 0.0.0.0:5173 0.0.0.0:* users:((\"node\",pid=9,fd=20))\nLISTEN 0 4096 [::]:22 [::]:*\n";
        assert_eq!(parse_listening(Os::Linux, ss), [(22, "".into()), (5173, "node".into())]);
        let ns = "tcp 0 0 0.0.0.0:8080 0.0.0.0:* LISTEN 1234/python3\n";
        assert_eq!(parse_listening(Os::Linux, ns), [(8080, "python3".into())]);
        assert_eq!(parse_listening(Os::Windows, "3000 node\r\n445 System\n"), [(445, "System".into()), (3000, "node".into())]);
    }

    #[test]
    fn resize_frame_format() {
        assert_eq!(resize_frame(120, 40), "\x1b]7777;120;40\x07");
    }
}
