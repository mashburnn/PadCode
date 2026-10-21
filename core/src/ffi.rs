//! Swift-facing API (UniFFI). Thin wrappers over the core; every async call
//! runs on our own tokio runtime so Swift needs no Rust-side executor.

use crate::{remote, tunnel, Error};
use std::sync::{Arc, LazyLock};

static RT: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("tokio runtime")
});

/// Runs a future on the core runtime and awaits it from any executor.
async fn on_rt<F, T>(f: F) -> T
where
    F: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    RT.spawn(f).await.expect("core task panicked")
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum PadError {
    #[error("{msg}")]
    AuthExpired { msg: String },
    #[error("{msg}")]
    Offline { msg: String },
    #[error("{msg}")]
    Conflict { msg: String },
    #[error("{msg}")]
    Closed { msg: String },
    #[error("{msg}")]
    NoServer { msg: String, install: String, detail: String },
    #[error("{msg}")]
    HostKeyUnknown { msg: String, fingerprint: String },
    #[error("{msg}")]
    HostKeyChanged { msg: String, fingerprint: String },
    #[error("{msg}")]
    SshAuth { msg: String },
    #[error("{msg}")]
    Other { msg: String },
}

impl From<Error> for PadError {
    fn from(e: Error) -> Self {
        let msg = e.to_string();
        match e {
            Error::AuthExpired => PadError::AuthExpired { msg },
            Error::Offline(_) => PadError::Offline { msg },
            Error::Conflict => PadError::Conflict { msg },
            Error::Closed => PadError::Closed { msg },
            Error::NoLanguageServer { install, detail, .. } => PadError::NoServer { msg, install, detail },
            Error::HostKeyUnknown(fingerprint) => PadError::HostKeyUnknown { msg, fingerprint },
            Error::HostKeyChanged(fingerprint) => PadError::HostKeyChanged { msg, fingerprint },
            Error::SshAuth(_) => PadError::SshAuth { msg },
            _ => PadError::Other { msg },
        }
    }
}

type R<T> = Result<T, PadError>;

#[derive(uniffi::Record)]
pub struct DeviceLogin {
    pub user_code: String,
    pub verification_uri: String,
}

#[derive(uniffi::Object)]
pub struct Login(crate::DeviceCode);

#[uniffi::export]
impl Login {
    pub fn info(&self) -> DeviceLogin {
        DeviceLogin { user_code: self.0.user_code.clone(), verification_uri: self.0.verification_uri.clone() }
    }

    /// Resolves with the GitHub token once the user approves the code.
    pub async fn wait(&self) -> R<String> {
        let code = self.0.clone();
        Ok(on_rt(async move { crate::finish_login(&code).await }).await?)
    }
}

#[uniffi::export]
pub async fn start_login() -> R<Arc<Login>> {
    Ok(Arc::new(Login(on_rt(crate::start_login()).await?)))
}

#[derive(uniffi::Record, Clone)]
pub struct MachineInfo {
    pub name: String,
    pub id: String,
    pub cluster: String,
    pub online: bool,
    pub protocol: Option<u32>,
}

impl From<tunnel::Machine> for MachineInfo {
    fn from(m: tunnel::Machine) -> Self {
        MachineInfo { name: m.name, id: m.id, cluster: m.cluster, online: m.online, protocol: m.protocol }
    }
}

impl From<MachineInfo> for tunnel::Machine {
    fn from(m: MachineInfo) -> Self {
        tunnel::Machine { name: m.name, id: m.id, cluster: m.cluster, online: m.online, protocol: m.protocol }
    }
}

#[uniffi::export]
pub async fn list_machines(token: String) -> R<Vec<MachineInfo>> {
    let ms = on_rt(async move { crate::list_machines(&token).await }).await?;
    Ok(ms.into_iter().map(Into::into).collect())
}

#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq)]
pub enum HostOs {
    Mac,
    Linux,
    Windows,
}

#[derive(uniffi::Record)]
pub struct HostEnv {
    pub os: HostOs,
    pub os_release: String,
    pub home: String,
    pub cli_version: String,
    pub protocol: u32,
    /// APPDATA etc., for locating the desktop's VS Code settings.
    pub appdata: Option<String>,
}

#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Dir,
    File,
    Link,
    Other,
}

#[derive(uniffi::Record)]
pub struct Entry {
    pub name: String,
    pub kind: Kind,
}

#[derive(uniffi::Record)]
pub struct FileStat {
    pub exists: bool,
    pub size: Option<u64>,
    pub kind: Kind,
}

#[derive(uniffi::Record)]
pub struct RunOutput {
    pub code: i32,
    pub stdout: String,
}

#[derive(uniffi::Record)]
pub struct PortInfo {
    pub port: u16,
    pub process: String,
}

#[derive(uniffi::Record)]
pub struct Hit {
    pub path: String,
    pub line: u32,
    pub text: String,
}

fn kind(k: Option<remote::EntryKind>) -> Kind {
    match k {
        Some(remote::EntryKind::Dir) => Kind::Dir,
        Some(remote::EntryKind::File) => Kind::File,
        Some(remote::EntryKind::Link) => Kind::Link,
        None => Kind::Other,
    }
}

/// A live connection to one desktop.
#[derive(uniffi::Object)]
pub struct Desktop(Arc<remote::Session>);

#[uniffi::export]
pub async fn connect(token: String, machine: MachineInfo) -> R<Arc<Desktop>> {
    let s = on_rt(async move { crate::connect(&token, &machine.into()).await }).await?;
    Ok(Arc::new(Desktop(Arc::new(s))))
}

/// PadCode's SSH login key: the private half stays in the iPad Keychain.
#[derive(uniffi::Record)]
pub struct SshKey {
    pub private_pem: String,
    pub public_openssh: String,
}

/// The public line for a key already in the Keychain.
#[uniffi::export]
pub fn ssh_public_key(private_pem: String) -> R<String> {
    Ok(crate::ssh_public_key(&private_pem)?)
}

#[uniffi::export]
pub fn ssh_generate_key() -> R<SshKey> {
    let k = crate::generate_ssh_key()?;
    Ok(SshKey { private_pem: k.private_pem, public_openssh: k.public_openssh })
}

/// An SSH desktop. `fingerprint` is the host key the user trusted (None the
/// first time: that fails with HostKeyUnknown carrying the key to show).
#[uniffi::export]
pub async fn connect_ssh(host: String, port: u16, user: String, private_pem: String, fingerprint: Option<String>) -> R<Arc<Desktop>> {
    let s = on_rt(async move { crate::connect_ssh(&host, port, &user, &private_pem, fingerprint.as_deref()).await }).await?;
    Ok(Arc::new(Desktop(Arc::new(s))))
}

/// Linux on this iPad, in-process (the app boots it first, LocalLinux.swift).
#[uniffi::export]
pub async fn connect_local() -> R<Arc<Desktop>> {
    let s = on_rt(crate::connect_local()).await?;
    Ok(Arc::new(Desktop(Arc::new(s))))
}

macro_rules! with_session {
    ($self:ident, |$s:ident| $body:expr) => {{
        let $s = $self.0.clone();
        on_rt(async move { $body }).await.map_err(PadError::from)
    }};
}

#[uniffi::export]
impl Desktop {
    pub fn name(&self) -> String {
        self.0.machine.clone()
    }

    pub fn env(&self) -> HostEnv {
        let e = &self.0.env;
        HostEnv {
            os: match e.os {
                remote::Os::Mac => HostOs::Mac,
                remote::Os::Linux => HostOs::Linux,
                remote::Os::Windows => HostOs::Windows,
            },
            os_release: e.os_release.clone(),
            home: e.home.clone(),
            cli_version: e.cli_version.clone(),
            protocol: e.protocol,
            appdata: e.vars.get("APPDATA").cloned(),
        }
    }

    pub fn join(&self, base: String, name: String) -> String {
        self.0.join(&base, &name)
    }

    pub async fn ping(&self) -> R<()> {
        with_session!(self, |s| s.ping().await)
    }

    pub async fn list_dir(&self, path: String) -> R<Vec<Entry>> {
        let entries: Vec<remote::DirEntry> = with_session!(self, |s| s.list_dir(&path).await)?;
        Ok(entries.into_iter().map(|e| Entry { kind: kind(e.kind), name: e.name }).collect())
    }

    pub async fn stat(&self, path: String) -> R<FileStat> {
        let st: remote::Stat = with_session!(self, |s| s.stat(&path).await)?;
        Ok(FileStat { exists: st.exists, size: st.size, kind: kind(st.kind) })
    }

    pub async fn read_file(&self, path: String) -> R<Vec<u8>> {
        with_session!(self, |s| s.read_file(&path).await)
    }

    pub async fn write_file(&self, path: String, data: Vec<u8>) -> R<()> {
        with_session!(self, |s| s.write_file(&path, &data).await)
    }

    /// Fails with `Conflict` if the file no longer holds `original`.
    pub async fn save_file(&self, path: String, data: Vec<u8>, original: Vec<u8>) -> R<()> {
        with_session!(self, |s| s.save_file(&path, &data, &original).await)
    }

    pub async fn mkdirp(&self, path: String) -> R<()> {
        with_session!(self, |s| s.mkdirp(&path).await)
    }

    pub async fn remove(&self, path: String) -> R<()> {
        with_session!(self, |s| s.remove(&path).await)
    }

    pub async fn rename(&self, from: String, to: String) -> R<()> {
        with_session!(self, |s| s.rename(&from, &to).await)
    }

    /// Runs a command to completion; returns (exit code, stdout).
    pub async fn run(&self, command: String, args: Vec<String>, cwd: Option<String>) -> R<RunOutput> {
        let out: crate::Output = with_session!(self, |s| {
            let a: Vec<&str> = args.iter().map(String::as_str).collect();
            s.run(&command, &a, cwd.as_deref()).await
        })?;
        Ok(RunOutput { code: out.code, stdout: String::from_utf8_lossy(&out.stdout).into_owned() })
    }

    /// Serves the desktop's `port` on the returned iPad port (127.0.0.1).
    pub async fn forward_port(&self, port: u16) -> R<u16> {
        with_session!(self, |s| s.forward_port(port).await)
    }

    pub fn stop_forward(&self, port: u16) {
        self.0.stop_forward(port)
    }

    pub async fn listening_ports(&self) -> R<Vec<PortInfo>> {
        let ports: Vec<(u16, String)> = with_session!(self, |s| s.listening_ports().await)?;
        Ok(ports.into_iter().map(|(port, process)| PortInfo { port, process }).collect())
    }

    pub async fn walk(&self, root: String, limit: u32) -> R<Vec<String>> {
        with_session!(self, |s| s.walk(&root, limit as usize).await)
    }

    pub async fn search(&self, root: String, query: String, max: u32, match_case: bool, whole_word: bool, regex: bool) -> R<Vec<Hit>> {
        let opts = crate::SearchOpts { match_case, whole_word, regex };
        let hits: Vec<remote::SearchHit> = with_session!(self, |s| s.search(&root, &query, max as usize, opts).await)?;
        Ok(hits.into_iter().map(|h| Hit { path: h.path, line: h.line, text: h.text }).collect())
    }

    /// Starts a shell; output and exit are delivered to `sink` on a core thread.
    pub async fn open_terminal(
        &self,
        cols: u16,
        rows: u16,
        cwd: Option<String>,
        session: Option<String>,
        offset: u64,
        sink: Arc<dyn TermSink>,
    ) -> R<Arc<Term>> {
        let s = self.0.clone();
        let input = on_rt(async move {
            let term = s.open_terminal(cols, rows, cwd.as_deref(), session.as_deref(), offset).await?;
            let remote::Terminal { input, mut output, exit } = term;
            tokio::spawn(async move {
                while let Some(mut chunk) = output.recv().await {
                    // Merge whatever else already arrived: one FFI call and one
                    // terminal parse per burst instead of per 4 KB segment.
                    while let Ok(more) = output.try_recv() {
                        chunk.extend_from_slice(&more);
                    }
                    sink.on_data(chunk);
                }
                match exit.await {
                    Ok(Some(code)) => sink.on_exit(code),
                    _ => sink.on_lost(),
                }
            });
            Ok::<_, Error>(input)
        })
        .await?;
        Ok(Arc::new(Term(input)))
    }
}

#[uniffi::export(with_foreign)]
pub trait TermSink: Send + Sync {
    fn on_data(&self, data: Vec<u8>);
    fn on_exit(&self, code: i32);
    /// The tunnel dropped; the shell is gone with it.
    fn on_lost(&self);
}

#[derive(uniffi::Object)]
pub struct Term(remote::TermInput);

/// Input methods are synchronous: they only enqueue (microseconds) and keep
/// keystrokes in order, so Swift calls them straight from the key handler.
#[uniffi::export]
impl Term {
    pub fn write(&self, data: Vec<u8>) -> R<()> {
        Ok(self.0.write(&data)?)
    }

    pub fn resize(&self, cols: u16, rows: u16) -> R<()> {
        Ok(self.0.resize(cols, rows)?)
    }

    pub fn close(&self) -> R<()> {
        Ok(self.0.close()?)
    }

    pub fn kill(&self) -> R<()> {
        Ok(self.0.kill()?)
    }

    pub fn resizable(&self) -> bool {
        self.0.resizable
    }
}

// MARK: language servers

#[derive(uniffi::Record, Clone, Copy)]
pub struct LspPos {
    pub line: u32,
    pub character: u32,
}

#[derive(uniffi::Record, Clone, Copy)]
pub struct LspRange {
    pub start: LspPos,
    pub end: LspPos,
}

impl From<crate::Range> for LspRange {
    fn from(r: crate::Range) -> Self {
        LspRange {
            start: LspPos { line: r.start.line, character: r.start.character },
            end: LspPos { line: r.end.line, character: r.end.character },
        }
    }
}

#[derive(uniffi::Record)]
pub struct Diag {
    pub range: LspRange,
    /// 1 error, 2 warning, 3 information, 4 hint.
    pub severity: u8,
    pub message: String,
    pub source: Option<String>,
    pub code: Option<String>,
}

#[derive(uniffi::Record)]
pub struct CompletionItem {
    pub label: String,
    pub kind: u8,
    pub detail: Option<String>,
    pub sort_text: String,
    pub filter_text: String,
    pub insert_text: String,
    pub edit_range: Option<LspRange>,
}

#[derive(uniffi::Record)]
pub struct DocSymbol {
    pub name: String,
    pub detail: Option<String>,
    pub kind: u8,
    pub depth: u32,
    pub selection: LspRange,
    pub range: LspRange,
}

#[derive(uniffi::Record)]
pub struct WorkspaceSymbol {
    pub name: String,
    pub kind: u8,
    pub container: Option<String>,
    pub path: String,
    pub selection: LspRange,
}

#[derive(uniffi::Record)]
pub struct Edit {
    pub range: LspRange,
    pub new_text: String,
}

#[derive(uniffi::Record)]
pub struct Loc {
    pub path: String,
    pub range: LspRange,
}

/// Events from a language server, delivered on a core thread.
#[uniffi::export(with_foreign)]
pub trait LspSink: Send + Sync {
    fn on_diagnostics(&self, path: String, items: Vec<Diag>);
    fn on_status(&self, text: Option<String>);
    fn on_exit(&self, message: String);
    /// The server wants these edits applied (e.g. a code action's command).
    fn on_apply_edit(&self, files: Vec<FileEdits>);
}

#[derive(uniffi::Record)]
pub struct FileEdits {
    pub path: String,
    pub edits: Vec<Edit>,
}

impl From<crate::FileEdit> for FileEdits {
    fn from(f: crate::FileEdit) -> Self {
        FileEdits { path: f.path, edits: f.edits.into_iter().map(|e| Edit { range: e.range.into(), new_text: e.new_text }).collect() }
    }
}

#[derive(uniffi::Record)]
pub struct Action {
    pub title: String,
    pub kind: Option<String>,
    pub preferred: bool,
    /// Opaque JSON handed back to `run_code_action`.
    pub raw: String,
}

#[derive(uniffi::Record)]
pub struct Signature {
    pub label: String,
    pub active_start: Option<u32>,
    pub active_end: Option<u32>,
    pub doc: Option<String>,
}

#[derive(uniffi::Object)]
pub struct LspServer(Arc<crate::LanguageServer>);

#[uniffi::export]
impl Desktop {
    /// The shared language server for a VS Code language id in `root`; starts it
    /// on first use. Fails with `NoServer` (carrying an install command) when the
    /// desktop has none.
    pub async fn language_server(&self, language_id: String, root: String, sink: Arc<dyn LspSink>) -> R<Arc<LspServer>> {
        let s = self.0.clone();
        let on_event: crate::lsp::EventFn = Arc::new(move |e| match e {
            crate::LspEvent::Diagnostics { path, items } => sink.on_diagnostics(
                path,
                items
                    .into_iter()
                    .map(|d| Diag { range: d.range.into(), severity: d.severity, message: d.message, source: d.source, code: d.code })
                    .collect(),
            ),
            crate::LspEvent::Status(t) => sink.on_status(t),
            crate::LspEvent::ApplyEdit(files) => sink.on_apply_edit(files.into_iter().map(Into::into).collect()),
            crate::LspEvent::Exited(m) => sink.on_exit(m),
        });
        let server = on_rt(async move { s.language_server(&language_id, &root, on_event).await }).await?;
        Ok(Arc::new(LspServer(server)))
    }

    pub async fn stop_language_servers(&self) {
        let s = self.0.clone();
        on_rt(async move { s.stop_language_servers().await }).await
    }
}

#[uniffi::export]
impl LspServer {
    pub fn name(&self) -> String {
        self.0.name.clone()
    }

    pub fn alive(&self) -> bool {
        self.0.alive()
    }

    pub fn trigger_characters(&self) -> Vec<String> {
        self.0.trigger_characters()
    }

    pub fn can_format(&self) -> bool {
        self.0.can_format()
    }

    pub fn can_symbols(&self) -> bool {
        self.0.can_symbols()
    }

    pub async fn symbols(&self, path: String) -> R<Vec<DocSymbol>> {
        let s = self.0.clone();
        let syms = on_rt(async move { s.symbols(&path).await }).await?;
        Ok(syms
            .into_iter()
            .map(|y| DocSymbol { name: y.name, detail: y.detail, kind: y.kind, depth: y.depth, selection: y.selection.into(), range: y.range.into() })
            .collect())
    }

    pub async fn workspace_symbols(&self, query: String) -> R<Vec<WorkspaceSymbol>> {
        let s = self.0.clone();
        let syms = on_rt(async move { s.workspace_symbols(&query).await }).await?;
        Ok(syms
            .into_iter()
            .map(|y| WorkspaceSymbol { name: y.name, kind: y.kind, container: y.container, path: y.location.path, selection: y.location.range.into() })
            .collect())
    }

    pub async fn rename(&self, path: String, line: u32, character: u32, new_name: String) -> R<Vec<FileEdits>> {
        let s = self.0.clone();
        let files = on_rt(async move { s.rename(&path, line, character, &new_name).await }).await?;
        Ok(files.into_iter().map(Into::into).collect())
    }

    pub async fn references(&self, path: String, line: u32, character: u32) -> R<Vec<Loc>> {
        let s = self.0.clone();
        let locs = on_rt(async move { s.references(&path, line, character).await }).await?;
        Ok(locs.into_iter().map(|l| Loc { path: l.path, range: l.range.into() }).collect())
    }

    /// Actions for a range; `diagnostics` are the problems there (from on_diagnostics).
    pub async fn code_actions(&self, path: String, range: LspRange, diagnostics: Vec<Diag>) -> R<Vec<Action>> {
        let s = self.0.clone();
        let pos = |p: LspPos| crate::Pos { line: p.line, character: p.character };
        let r = crate::Range { start: pos(range.start), end: pos(range.end) };
        let diags: Vec<crate::Diagnostic> = diagnostics
            .into_iter()
            .map(|d| crate::Diagnostic {
                range: crate::Range { start: pos(d.range.start), end: pos(d.range.end) },
                severity: d.severity,
                message: d.message,
                source: d.source,
                code: d.code,
            })
            .collect();
        let acts = on_rt(async move { s.code_actions(&path, r, &diags).await }).await?;
        Ok(acts.into_iter().map(|a| Action { title: a.title, kind: a.kind, preferred: a.preferred, raw: a.raw.to_string() }).collect())
    }

    pub async fn run_code_action(&self, raw: String) -> R<Vec<FileEdits>> {
        let s = self.0.clone();
        let v: serde_json::Value = serde_json::from_str(&raw).map_err(|e| PadError::Other { msg: e.to_string() })?;
        let files = on_rt(async move { s.run_code_action(&v).await }).await?;
        Ok(files.into_iter().map(Into::into).collect())
    }

    pub async fn signature_help(&self, path: String, line: u32, character: u32) -> R<Option<Signature>> {
        let s = self.0.clone();
        let sig = on_rt(async move { s.signature_help(&path, line, character).await }).await?;
        Ok(sig.map(|s| Signature { label: s.label, active_start: s.active.map(|a| a.0), active_end: s.active.map(|a| a.1), doc: s.doc }))
    }

    pub async fn format(&self, path: String, tab_size: u32, insert_spaces: bool) -> R<Vec<Edit>> {
        let s = self.0.clone();
        let edits = on_rt(async move { s.format(&path, tab_size, insert_spaces).await }).await?;
        Ok(edits.into_iter().map(|e| Edit { range: e.range.into(), new_text: e.new_text }).collect())
    }

    pub fn open(&self, path: String, language_id: String, text: String) -> R<()> {
        Ok(self.0.open(&path, &language_id, &text)?)
    }

    /// Cheap to call on every keystroke: the text is sent after a short pause.
    pub fn change(&self, path: String, text: String) {
        self.0.change(&path, text)
    }

    pub fn save(&self, path: String, text: String) -> R<()> {
        Ok(self.0.save(&path, &text)?)
    }

    pub fn close(&self, path: String) -> R<()> {
        Ok(self.0.close(&path)?)
    }

    pub async fn completion(&self, path: String, line: u32, character: u32) -> R<Vec<CompletionItem>> {
        let s = self.0.clone();
        let items = on_rt(async move { s.completion(&path, line, character).await }).await?;
        Ok(items
            .into_iter()
            .map(|c| CompletionItem {
                label: c.label,
                kind: c.kind,
                detail: c.detail,
                sort_text: c.sort_text,
                filter_text: c.filter_text,
                insert_text: c.insert_text,
                edit_range: c.edit_range.map(Into::into),
            })
            .collect())
    }

    pub async fn hover(&self, path: String, line: u32, character: u32) -> R<Option<String>> {
        let s = self.0.clone();
        Ok(on_rt(async move { s.hover(&path, line, character).await }).await?)
    }

    pub async fn definition(&self, path: String, line: u32, character: u32) -> R<Vec<Loc>> {
        let s = self.0.clone();
        let locs = on_rt(async move { s.definition(&path, line, character).await }).await?;
        Ok(locs.into_iter().map(|l| Loc { path: l.path, range: l.range.into() }).collect())
    }
}

/// Display name ("Rust", "C/C++") if PadCode knows a language server for this
/// VS Code language id.
#[uniffi::export]
pub fn lsp_language_name(language_id: String) -> Option<String> {
    crate::lsp::spec_for(&language_id).map(|s| s.name.to_string())
}

