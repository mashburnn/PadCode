//! Language servers (rust-analyzer, clangd, pyright, gopls, …) running on the
//! desktop, spoken to over LSP on the spawned process's stdio. v1 covers
//! diagnostics, completion, hover and go to definition.
//!
//! Documents use full-text sync, debounced: the editor never has to map its
//! edits (auto-pairs, indentation, undo, paste…) onto LSP ranges, so the server
//! can't drift out of sync. Requests flush pending text first.

use crate::{remote::Os, Error, Result};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicI64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tokio::sync::{mpsc, oneshot};

const CHANGE_DEBOUNCE: Duration = Duration::from_millis(120);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
// rust-analyzer/clangd answer `initialize` before indexing, but a cold
// toolchain proxy (rustup) can take a while to start.
const INIT_TIMEOUT: Duration = Duration::from_secs(60);

/// A language and the servers that can handle it, in preference order.
pub struct Spec {
    pub key: &'static str,
    pub name: &'static str,
    /// VS Code language ids this server takes.
    pub languages: &'static [&'static str],
    pub candidates: &'static [(&'static str, &'static [&'static str])],
}

pub const SPECS: &[Spec] = &[
    Spec { key: "rust", name: "Rust", languages: &["rust"], candidates: &[("rust-analyzer", &[])] },
    Spec {
        key: "python",
        name: "Python",
        languages: &["python"],
        candidates: &[
            ("pyright-langserver", &["--stdio"]),
            ("basedpyright-langserver", &["--stdio"]),
            ("pylsp", &[]),
            ("jedi-language-server", &[]),
        ],
    },
    Spec {
        key: "typescript",
        name: "TypeScript/JavaScript",
        languages: &["javascript", "javascriptreact", "typescript", "typescriptreact"],
        candidates: &[("typescript-language-server", &["--stdio"])],
    },
    Spec { key: "go", name: "Go", languages: &["go"], candidates: &[("gopls", &[])] },
    Spec { key: "c", name: "C/C++", languages: &["c", "cpp"], candidates: &[("clangd", &[])] },
    Spec { key: "swift", name: "Swift", languages: &["swift"], candidates: &[("sourcekit-lsp", &[])] },
    Spec { key: "lua", name: "Lua", languages: &["lua"], candidates: &[("lua-language-server", &[])] },
    Spec { key: "ruby", name: "Ruby", languages: &["ruby"], candidates: &[("ruby-lsp", &[])] },
];

pub fn spec_for(language: &str) -> Option<&'static Spec> {
    SPECS.iter().find(|s| s.languages.contains(&language))
}

/// Command that installs a server for `key` on that desktop.
pub fn install_hint(key: &str, os: Os) -> &'static str {
    match (key, os) {
        ("rust", _) => "rustup component add rust-analyzer",
        ("python", _) => "npm install -g pyright",
        ("typescript", _) => "npm install -g typescript typescript-language-server",
        ("go", _) => "go install golang.org/x/tools/gopls@latest",
        ("c" | "swift", Os::Mac) => "xcode-select --install",
        ("c", Os::Linux) => "sudo apt install clangd",
        ("c", Os::Windows) => "winget install LLVM.LLVM",
        ("lua", Os::Mac) => "brew install lua-language-server",
        ("ruby", _) => "gem install ruby-lsp",
        _ => "",
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pos {
    pub line: u32,
    pub character: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Range {
    pub start: Pos,
    pub end: Pos,
}

#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub range: Range,
    /// 1 error, 2 warning, 3 information, 4 hint.
    pub severity: u8,
    pub message: String,
    pub source: Option<String>,
    pub code: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Completion {
    pub label: String,
    pub kind: u8,
    pub detail: Option<String>,
    pub sort_text: String,
    pub filter_text: String,
    /// Plain text to insert (snippets already flattened).
    pub insert_text: String,
    /// Range to replace; None means "the word before the cursor".
    pub edit_range: Option<Range>,
}

#[derive(Debug, Clone)]
pub struct Symbol {
    pub name: String,
    pub detail: Option<String>,
    /// LSP SymbolKind (5 class, 6 method, 12 function, 13 variable…).
    pub kind: u8,
    /// Nesting level in the outline (0 = top).
    pub depth: u32,
    /// Where the name is; jump target.
    pub selection: Range,
    /// The whole declaration, for "which symbol is the cursor in".
    pub range: Range,
}

#[derive(Debug, Clone)]
pub struct TextEdit {
    pub range: Range,
    pub new_text: String,
}

#[derive(Debug, Clone)]
pub struct Location {
    pub path: String,
    pub range: Range,
}

/// Edits for one file, from a rename / code action / applyEdit.
#[derive(Debug, Clone)]
pub struct FileEdit {
    pub path: String,
    pub edits: Vec<TextEdit>,
}

#[derive(Debug, Clone)]
pub struct CodeAction {
    pub title: String,
    pub kind: Option<String>,
    pub preferred: bool,
    /// The raw action/command, sent back to resolve or run it.
    pub raw: Value,
}

#[derive(Debug, Clone)]
pub struct SignatureHelp {
    pub label: String,
    /// UTF-16 offsets of the active parameter within `label`.
    pub active: Option<(u32, u32)>,
    pub doc: Option<String>,
}

#[derive(Debug, Clone)]
pub enum Event {
    Diagnostics { path: String, items: Vec<Diagnostic> },
    /// Server-initiated edit (workspace/applyEdit), e.g. from a code action command.
    ApplyEdit(Vec<FileEdit>),
    /// Progress text ("Indexing 40%"), None when idle.
    Status(Option<String>),
    Exited(String),
}

pub type EventFn = Arc<dyn Fn(Event) + Send + Sync>;
type Reply = std::result::Result<Value, String>;

#[derive(Default)]
struct Doc {
    version: i32,
    pending: Option<String>,
    scheduled: bool,
}

pub struct LanguageServer {
    pub name: String,
    os: Os,
    root_uri: String,
    rt: tokio::runtime::Handle,
    write: Box<dyn Fn(&[u8]) -> Result<()> + Send + Sync>,
    end: Box<dyn Fn() + Send + Sync>,
    next_id: AtomicI64,
    pending: Mutex<HashMap<i64, oneshot::Sender<Reply>>>,
    docs: Mutex<HashMap<String, Doc>>,
    /// uri key -> the path the editor used, so results map back exactly.
    paths: Mutex<HashMap<String, String>>,
    progress: Mutex<Vec<(String, String)>>,
    trigger_chars: Mutex<Vec<String>>,
    save_text: AtomicBool,
    can_format: AtomicBool,
    can_symbols: AtomicBool,
    exited: AtomicBool,
    on_event: EventFn,
}

impl LanguageServer {
    /// Wires up a started server process and runs the `initialize` handshake.
    /// Must be called inside a tokio runtime.
    pub(crate) async fn start(
        name: String,
        os: Os,
        root: &str,
        write: Box<dyn Fn(&[u8]) -> Result<()> + Send + Sync>,
        end: Box<dyn Fn() + Send + Sync>,
        mut stdout: mpsc::UnboundedReceiver<Vec<u8>>,
        stderr_tail: Arc<Mutex<Vec<u8>>>,
        on_event: EventFn,
    ) -> Result<Arc<LanguageServer>> {
        let root_uri = path_to_uri(os, root);
        let me = Arc::new(LanguageServer {
            name,
            os,
            root_uri: root_uri.clone(),
            rt: tokio::runtime::Handle::current(),
            write,
            end,
            next_id: AtomicI64::new(1),
            pending: Mutex::default(),
            docs: Mutex::default(),
            paths: Mutex::default(),
            progress: Mutex::default(),
            trigger_chars: Mutex::default(),
            save_text: AtomicBool::new(false),
            can_format: AtomicBool::new(false),
            can_symbols: AtomicBool::new(false),
            exited: AtomicBool::new(false),
            on_event,
        });

        let reader = me.clone();
        tokio::spawn(async move {
            let mut buf = Vec::new();
            while let Some(chunk) = stdout.recv().await {
                buf.extend_from_slice(&chunk);
                while let Some(body) = next_message(&mut buf) {
                    match serde_json::from_slice::<Value>(&body) {
                        Ok(msg) => reader.handle(msg),
                        Err(e) => log::warn!("{}: bad LSP message: {e}", reader.name),
                    }
                }
            }
            reader.exited.store(true, Ordering::SeqCst);
            for (_, tx) in reader.pending.lock().unwrap().drain() {
                let _ = tx.send(Err("server exited".into()));
            }
            (reader.on_event)(Event::Exited(format!("{} stopped", reader.name)));
        });

        let folder = root.rsplit(['/', '\\']).find(|s| !s.is_empty()).unwrap_or(root);
        let init = me
            .request(
                "initialize",
                json!({
                    "processId": null,
                    "clientInfo": { "name": "PadCode", "version": env!("CARGO_PKG_VERSION") },
                    "rootUri": root_uri,
                    "rootPath": root,
                    "workspaceFolders": [{ "uri": root_uri, "name": folder }],
                    "capabilities": client_capabilities(),
                }),
                INIT_TIMEOUT,
            )
            .await;
        let init = match init {
            Ok(v) => v,
            Err(e) => {
                // Give stderr a moment to arrive; it usually says why.
                tokio::time::sleep(Duration::from_millis(300)).await;
                let tail = String::from_utf8_lossy(&stderr_tail.lock().unwrap()).trim().to_string();
                (me.end)();
                let why = if tail.is_empty() { e.to_string() } else { tail };
                return Err(Error::Remote(format!("{} failed to start: {why}", me.name)));
            }
        };
        let caps = &init["capabilities"];
        if let Some(chars) = caps["completionProvider"]["triggerCharacters"].as_array() {
            *me.trigger_chars.lock().unwrap() =
                chars.iter().filter_map(|c| c.as_str().map(str::to_string)).collect();
        }
        let enabled = |v: &Value| v.as_bool().unwrap_or(v.is_object());
        me.can_format.store(enabled(&caps["documentFormattingProvider"]), Ordering::Relaxed);
        me.can_symbols.store(enabled(&caps["documentSymbolProvider"]), Ordering::Relaxed);
        me.save_text.store(
            caps["textDocumentSync"]["save"]["includeText"].as_bool().unwrap_or(false),
            Ordering::Relaxed,
        );
        me.notify("initialized", json!({}))?;
        Ok(me)
    }

    pub fn alive(&self) -> bool {
        !self.exited.load(Ordering::SeqCst)
    }

    pub fn can_format(&self) -> bool {
        self.can_format.load(Ordering::Relaxed)
    }

    pub fn can_symbols(&self) -> bool {
        self.can_symbols.load(Ordering::Relaxed)
    }

    pub fn trigger_characters(&self) -> Vec<String> {
        self.trigger_chars.lock().unwrap().clone()
    }

    fn send(&self, msg: Value) -> Result<()> {
        let body = serde_json::to_vec(&msg).expect("json encode");
        let mut out = format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes();
        out.extend_from_slice(&body);
        (self.write)(&out)
    }

    fn notify(&self, method: &str, params: Value) -> Result<()> {
        self.send(json!({ "jsonrpc": "2.0", "method": method, "params": params }))
    }

    async fn request(&self, method: &str, params: Value, timeout: Duration) -> Result<Value> {
        if !self.alive() {
            return Err(Error::Remote(format!("{} is not running", self.name)));
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        self.send(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }))?;
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(Ok(v))) => Ok(v),
            Ok(Ok(Err(e))) => Err(Error::Remote(format!("{}: {e}", self.name))),
            Ok(Err(_)) => Err(Error::Closed),
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                let _ = self.notify("$/cancelRequest", json!({ "id": id }));
                Err(Error::Remote(format!("{} took too long ({method})", self.name)))
            }
        }
    }

    fn handle(&self, msg: Value) {
        let method = msg.get("method").and_then(Value::as_str);
        match (method, msg.get("id")) {
            // Server -> client request: always answer, or the server can stall.
            (Some(m), Some(id)) => {
                let reply = match self.answer(m, &msg["params"]) {
                    Some(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
                    None => json!({
                        "jsonrpc": "2.0", "id": id,
                        "error": { "code": -32601, "message": format!("PadCode does not support {m}") },
                    }),
                };
                let _ = self.send(reply);
            }
            (Some(m), None) => self.notification(m, &msg["params"]),
            (None, Some(id)) => {
                let Some(id) = id.as_i64() else { return };
                if let Some(tx) = self.pending.lock().unwrap().remove(&id) {
                    let r = match msg.get("error") {
                        Some(e) => Err(e["message"].as_str().unwrap_or("error").to_string()),
                        None => Ok(msg.get("result").cloned().unwrap_or(Value::Null)),
                    };
                    let _ = tx.send(r);
                }
            }
            _ => {}
        }
    }

    fn answer(&self, method: &str, params: &Value) -> Option<Value> {
        match method {
            // null = "use your defaults" for each requested section
            "workspace/configuration" => {
                let n = params["items"].as_array().map_or(0, Vec::len);
                Some(Value::Array(vec![Value::Null; n]))
            }
            "window/workDoneProgress/create"
            | "client/registerCapability"
            | "client/unregisterCapability"
            | "window/showMessageRequest" => Some(Value::Null),
            "workspace/workspaceFolders" => Some(json!([{ "uri": self.root_uri, "name": "root" }])),
            "workspace/applyEdit" => {
                (self.on_event)(Event::ApplyEdit(self.workspace_edit(&params["edit"])));
                Some(json!({ "applied": true }))
            }
            _ => None,
        }
    }

    fn notification(&self, method: &str, params: &Value) {
        match method {
            "textDocument/publishDiagnostics" => {
                let Some(uri) = params["uri"].as_str() else { return };
                let items = params["diagnostics"]
                    .as_array()
                    .map(|a| a.iter().filter_map(parse_diagnostic).collect())
                    .unwrap_or_default();
                (self.on_event)(Event::Diagnostics { path: self.path_for(uri), items });
            }
            "$/progress" => {
                let token = match &params["token"] {
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                };
                let v = &params["value"];
                let mut progress = self.progress.lock().unwrap();
                match v["kind"].as_str() {
                    Some("begin") => {
                        let title = v["title"].as_str().unwrap_or("").to_string();
                        progress.retain(|(t, _)| *t != token);
                        progress.push((token, progress_text(&title, v)));
                    }
                    Some("report") => {
                        if let Some(entry) = progress.iter_mut().find(|(t, _)| *t == token) {
                            let title = entry.1.split(':').next().unwrap_or("").to_string();
                            entry.1 = progress_text(&title, v);
                        }
                    }
                    Some("end") => progress.retain(|(t, _)| *t != token),
                    _ => return,
                }
                let status = progress.last().map(|(_, text)| text.clone());
                drop(progress);
                (self.on_event)(Event::Status(status));
            }
            _ => {} // logMessage, showMessage, telemetry, server-specific
        }
    }

    fn path_for(&self, uri: &str) -> String {
        let key = uri_key(self.os, uri);
        self.paths.lock().unwrap().get(&key).cloned().unwrap_or_else(|| uri_to_path(self.os, uri))
    }

    fn uri_for(&self, path: &str) -> String {
        let uri = path_to_uri(self.os, path);
        self.paths.lock().unwrap().insert(uri_key(self.os, &uri), path.to_string());
        uri
    }

    // MARK: documents

    pub fn open(&self, path: &str, language_id: &str, text: &str) -> Result<()> {
        let uri = self.uri_for(path);
        {
            let mut docs = self.docs.lock().unwrap();
            if let Some(doc) = docs.get_mut(&uri) {
                // Re-opened (e.g. reloaded from disk): just send the new text.
                doc.pending = Some(text.to_string());
                drop(docs);
                return self.flush(&uri);
            }
            docs.insert(uri.clone(), Doc { version: 1, ..Doc::default() });
        }
        self.notify(
            "textDocument/didOpen",
            json!({ "textDocument": { "uri": uri, "languageId": language_id, "version": 1, "text": text } }),
        )
    }

    /// Records the document's new full text; sent after a short pause in typing.
    pub fn change(self: &Arc<Self>, path: &str, text: String) {
        let uri = path_to_uri(self.os, path);
        let mut docs = self.docs.lock().unwrap();
        let Some(doc) = docs.get_mut(&uri) else { return };
        doc.pending = Some(text);
        if !doc.scheduled {
            doc.scheduled = true;
            let me = self.clone();
            self.rt.spawn(async move {
                tokio::time::sleep(CHANGE_DEBOUNCE).await;
                let _ = me.flush(&uri);
            });
        }
    }

    fn flush(&self, uri: &str) -> Result<()> {
        let (version, text) = {
            let mut docs = self.docs.lock().unwrap();
            let Some(doc) = docs.get_mut(uri) else { return Ok(()) };
            doc.scheduled = false;
            let Some(text) = doc.pending.take() else { return Ok(()) };
            doc.version += 1;
            (doc.version, text)
        };
        self.notify(
            "textDocument/didChange",
            json!({ "textDocument": { "uri": uri, "version": version }, "contentChanges": [{ "text": text }] }),
        )
    }

    pub fn save(&self, path: &str, text: &str) -> Result<()> {
        let uri = path_to_uri(self.os, path);
        self.flush(&uri)?;
        let mut params = json!({ "textDocument": { "uri": uri } });
        if self.save_text.load(Ordering::Relaxed) {
            params["text"] = json!(text);
        }
        self.notify("textDocument/didSave", params)
    }

    pub fn close(&self, path: &str) -> Result<()> {
        let uri = path_to_uri(self.os, path);
        if self.docs.lock().unwrap().remove(&uri).is_none() {
            return Ok(());
        }
        self.notify("textDocument/didClose", json!({ "textDocument": { "uri": uri } }))
    }

    fn position_params(&self, path: &str, line: u32, character: u32) -> Result<Value> {
        let uri = path_to_uri(self.os, path);
        self.flush(&uri)?;
        Ok(json!({ "textDocument": { "uri": uri }, "position": { "line": line, "character": character } }))
    }

    // MARK: features

    pub async fn completion(&self, path: &str, line: u32, character: u32) -> Result<Vec<Completion>> {
        let params = self.position_params(path, line, character)?;
        Ok(parse_completions(&self.request("textDocument/completion", params, REQUEST_TIMEOUT).await?))
    }

    pub async fn hover(&self, path: &str, line: u32, character: u32) -> Result<Option<String>> {
        let params = self.position_params(path, line, character)?;
        Ok(hover_text(&self.request("textDocument/hover", params, REQUEST_TIMEOUT).await?))
    }

    pub async fn definition(&self, path: &str, line: u32, character: u32) -> Result<Vec<Location>> {
        let params = self.position_params(path, line, character)?;
        let v = self.request("textDocument/definition", params, REQUEST_TIMEOUT).await?;
        let list = match v {
            Value::Array(a) => a,
            Value::Null => vec![],
            other => vec![other],
        };
        Ok(list
            .iter()
            .filter_map(|l| {
                let uri = l.get("uri").or_else(|| l.get("targetUri"))?.as_str()?;
                let range = parse_range(l.get("targetSelectionRange").or_else(|| l.get("range"))?)?;
                Some(Location { path: self.path_for(uri), range })
            })
            .collect())
    }

    /// Outline of a document, flattened depth-first.
    pub async fn symbols(&self, path: &str) -> Result<Vec<Symbol>> {
        let uri = path_to_uri(self.os, path);
        self.flush(&uri)?;
        let v = self
            .request("textDocument/documentSymbol", json!({ "textDocument": { "uri": uri } }), REQUEST_TIMEOUT)
            .await?;
        Ok(parse_symbols(&v))
    }

    /// Edits that format the whole document.
    pub async fn format(&self, path: &str, tab_size: u32, insert_spaces: bool) -> Result<Vec<TextEdit>> {
        let uri = path_to_uri(self.os, path);
        self.flush(&uri)?;
        let v = self
            .request(
                "textDocument/formatting",
                json!({ "textDocument": { "uri": uri }, "options": { "tabSize": tab_size, "insertSpaces": insert_spaces } }),
                REQUEST_TIMEOUT,
            )
            .await?;
        Ok(v.as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|e| Some(TextEdit { range: parse_range(&e["range"])?, new_text: e["newText"].as_str()?.to_string() }))
                    .collect()
            })
            .unwrap_or_default())
    }

    /// Rename the symbol at a position; edits per file.
    pub async fn rename(&self, path: &str, line: u32, character: u32, new_name: &str) -> Result<Vec<FileEdit>> {
        let mut params = self.position_params(path, line, character)?;
        params["newName"] = json!(new_name);
        let v = self.request("textDocument/rename", params, REQUEST_TIMEOUT).await?;
        Ok(self.workspace_edit(&v))
    }

    pub async fn references(&self, path: &str, line: u32, character: u32) -> Result<Vec<Location>> {
        let mut params = self.position_params(path, line, character)?;
        params["context"] = json!({ "includeDeclaration": true });
        let v = self.request("textDocument/references", params, REQUEST_TIMEOUT).await?;
        Ok(v.as_array()
            .map(|a| a.iter().filter_map(|l| Some(Location { path: self.path_for(l["uri"].as_str()?), range: parse_range(&l["range"])? })).collect())
            .unwrap_or_default())
    }

    /// Quick fixes and refactors for a range, given the problems there.
    pub async fn code_actions(&self, path: &str, range: Range, diagnostics: &[Diagnostic]) -> Result<Vec<CodeAction>> {
        let uri = path_to_uri(self.os, path);
        self.flush(&uri)?;
        let r = |r: Range| json!({ "start": { "line": r.start.line, "character": r.start.character }, "end": { "line": r.end.line, "character": r.end.character } });
        let diags: Vec<Value> = diagnostics
            .iter()
            .map(|d| {
                let mut v = json!({ "range": r(d.range), "severity": d.severity, "message": d.message });
                if let Some(s) = &d.source { v["source"] = json!(s); }
                if let Some(c) = &d.code { v["code"] = json!(c); }
                v
            })
            .collect();
        let v = self
            .request("textDocument/codeAction", json!({ "textDocument": { "uri": uri }, "range": r(range), "context": { "diagnostics": diags } }), REQUEST_TIMEOUT)
            .await?;
        Ok(v.as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|it| Some(CodeAction {
                        title: it["title"].as_str()?.to_string(),
                        kind: it["kind"].as_str().map(str::to_string),
                        preferred: it["isPreferred"].as_bool().unwrap_or(false),
                        raw: it.clone(),
                    }))
                    .collect()
            })
            .unwrap_or_default())
    }

    /// Runs a code action: returns its edits; a command it carries runs on the
    /// server, whose own edits arrive as `Event::ApplyEdit`.
    pub async fn run_code_action(&self, raw: &Value) -> Result<Vec<FileEdit>> {
        let mut action = raw.clone();
        if action["command"].is_string() {
            // A bare Command, not a CodeAction.
            self.execute(&action).await?;
            return Ok(vec![]);
        }
        if action.get("edit").is_none() && action.get("data").is_some() {
            if let Ok(resolved) = self.request("codeAction/resolve", action.clone(), REQUEST_TIMEOUT).await {
                action = resolved;
            }
        }
        let edits = self.workspace_edit(&action["edit"]);
        if action["command"].is_object() {
            self.execute(&action["command"]).await?;
        }
        Ok(edits)
    }

    async fn execute(&self, cmd: &Value) -> Result<()> {
        let params = json!({ "command": cmd["command"], "arguments": cmd.get("arguments").cloned().unwrap_or(json!([])) });
        self.request("workspace/executeCommand", params, REQUEST_TIMEOUT).await.map(|_| ())
    }

    pub async fn signature_help(&self, path: &str, line: u32, character: u32) -> Result<Option<SignatureHelp>> {
        let params = self.position_params(path, line, character)?;
        let v = self.request("textDocument/signatureHelp", params, REQUEST_TIMEOUT).await?;
        let sigs = v["signatures"].as_array().cloned().unwrap_or_default();
        let Some(sig) = sigs.get(v["activeSignature"].as_u64().unwrap_or(0) as usize).or(sigs.first()) else { return Ok(None) };
        let label = sig["label"].as_str().unwrap_or("").to_string();
        let ap = sig["activeParameter"].as_u64().or(v["activeParameter"].as_u64()).unwrap_or(0) as usize;
        let active = sig["parameters"].as_array().and_then(|ps| ps.get(ap)).and_then(|p| match &p["label"] {
            Value::String(s) => label.find(s.as_str()).map(|i| {
                let start = label[..i].encode_utf16().count() as u32;
                (start, start + s.encode_utf16().count() as u32)
            }),
            Value::Array(a) => Some((a.first()?.as_u64()? as u32, a.get(1)?.as_u64()? as u32)),
            _ => None,
        });
        let doc = match &sig["documentation"] {
            Value::String(s) => Some(s.clone()),
            Value::Object(o) => o.get("value").and_then(Value::as_str).map(str::to_string),
            _ => None,
        };
        Ok(Some(SignatureHelp { label, active, doc }))
    }

    /// WorkspaceEdit: `changes` map or `documentChanges` list -> per-file edits.
    fn workspace_edit(&self, v: &Value) -> Vec<FileEdit> {
        let edits = |a: &Value| -> Vec<TextEdit> {
            a.as_array()
                .map(|a| a.iter().filter_map(|e| Some(TextEdit { range: parse_range(&e["range"])?, new_text: e["newText"].as_str()?.to_string() })).collect())
                .unwrap_or_default()
        };
        let mut out = Vec::new();
        if let Some(map) = v["changes"].as_object() {
            for (uri, list) in map {
                out.push(FileEdit { path: self.path_for(uri), edits: edits(list) });
            }
        }
        for dc in v["documentChanges"].as_array().into_iter().flatten() {
            if let Some(uri) = dc["textDocument"]["uri"].as_str() {
                out.push(FileEdit { path: self.path_for(uri), edits: edits(&dc["edits"]) });
            }
        }
        out
    }

    pub async fn shutdown(&self) {
        if self.alive() {
            let _ = self.request("shutdown", Value::Null, Duration::from_secs(3)).await;
            let _ = self.notify("exit", Value::Null);
        }
        (self.end)();
    }
}

fn client_capabilities() -> Value {
    json!({
        "general": { "positionEncodings": ["utf-16"] },
        "window": { "workDoneProgress": true },
        "workspace": { "configuration": true, "workspaceFolders": true, "applyEdit": true, "workspaceEdit": { "documentChanges": true } },
        "textDocument": {
            "synchronization": { "didSave": true },
            "completion": {
                "completionItem": {
                    "snippetSupport": false,
                    "documentationFormat": ["plaintext"],
                    "labelDetailsSupport": true
                },
                "contextSupport": false
            },
            "hover": { "contentFormat": ["markdown", "plaintext"] },
            "definition": { "linkSupport": true },
            "documentSymbol": { "hierarchicalDocumentSymbolSupport": true },
            "rename": { "prepareSupport": false },
            "references": {},
            "signatureHelp": { "signatureInformation": { "parameterInformation": { "labelOffsetSupport": true }, "activeParameterSupport": true } },
            "codeAction": {
                "codeActionLiteralSupport": { "codeActionKind": { "valueSet": ["", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite", "source", "source.organizeImports"] } },
                "isPreferredSupport": true,
                "dataSupport": true,
                "resolveSupport": { "properties": ["edit"] }
            },
            "formatting": {},
            "publishDiagnostics": { "relatedInformation": false }
        }
    })
}

fn progress_text(title: &str, v: &Value) -> String {
    let mut s = title.to_string();
    if let Some(m) = v["message"].as_str().filter(|m| !m.is_empty()) {
        s = if s.is_empty() { m.to_string() } else { format!("{s}: {m}") };
    }
    if let Some(p) = v["percentage"].as_u64() {
        s = format!("{s} {p}%");
    }
    s
}

/// Pops one `Content-Length`-framed message body off the front of `buf`.
pub(crate) fn next_message(buf: &mut Vec<u8>) -> Option<Vec<u8>> {
    let end = buf.windows(4).position(|w| w == b"\r\n\r\n")?;
    let header = String::from_utf8_lossy(&buf[..end]).to_ascii_lowercase();
    let len = header.lines().find_map(|l| l.strip_prefix("content-length:")?.trim().parse::<usize>().ok());
    let Some(len) = len else {
        buf.drain(..end + 4); // not a header we understand: skip it
        return None;
    };
    if buf.len() < end + 4 + len {
        return None;
    }
    let body = buf[end + 4..end + 4 + len].to_vec();
    buf.drain(..end + 4 + len);
    Some(body)
}

fn parse_pos(v: &Value) -> Option<Pos> {
    Some(Pos { line: v["line"].as_u64()? as u32, character: v["character"].as_u64()? as u32 })
}

fn parse_range(v: &Value) -> Option<Range> {
    Some(Range { start: parse_pos(&v["start"])?, end: parse_pos(&v["end"])? })
}

fn parse_diagnostic(v: &Value) -> Option<Diagnostic> {
    Some(Diagnostic {
        range: parse_range(&v["range"])?,
        severity: v["severity"].as_u64().unwrap_or(1) as u8,
        message: v["message"].as_str()?.to_string(),
        source: v["source"].as_str().map(str::to_string),
        code: match &v["code"] {
            Value::String(s) => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        },
    })
}

pub(crate) fn parse_completions(v: &Value) -> Vec<Completion> {
    let items = match v {
        Value::Array(a) => a.as_slice(),
        Value::Object(_) => v["items"].as_array().map(Vec::as_slice).unwrap_or(&[]),
        _ => &[],
    };
    items
        .iter()
        .filter_map(|it| {
            let label = it["label"].as_str()?.to_string();
            let (edit_range, text) = match it.get("textEdit") {
                Some(te) => (
                    te.get("range").or_else(|| te.get("replace")).and_then(parse_range),
                    te["newText"].as_str().unwrap_or(&label).to_string(),
                ),
                None => (None, it["insertText"].as_str().unwrap_or(&label).to_string()),
            };
            let insert_text = if it["insertTextFormat"].as_u64() == Some(2) { strip_snippet(&text) } else { text };
            let detail = it["detail"]
                .as_str()
                .or_else(|| it["labelDetails"]["description"].as_str())
                .map(str::to_string);
            Some(Completion {
                kind: it["kind"].as_u64().unwrap_or(0) as u8,
                detail,
                sort_text: it["sortText"].as_str().unwrap_or(&label).to_string(),
                filter_text: it["filterText"].as_str().unwrap_or(&label).to_string(),
                insert_text,
                edit_range,
                label,
            })
        })
        .collect()
}

/// Flattens LSP snippet syntax: `${1:x}` -> x, `$1`/`$0` -> "", `${1|a,b|}` -> a.
pub(crate) fn strip_snippet(s: &str) -> String {
    let cs: Vec<char> = s.chars().collect();
    let mut out = String::new();
    let mut depth = 0;
    let mut i = 0;
    while i < cs.len() {
        let c = cs[i];
        if c == '\\' && matches!(cs.get(i + 1), Some('$' | '}' | '\\')) {
            out.push(cs[i + 1]);
            i += 2;
            continue;
        }
        if c == '$' {
            if cs.get(i + 1).is_some_and(char::is_ascii_digit) {
                i += 1;
                while cs.get(i).is_some_and(char::is_ascii_digit) {
                    i += 1;
                }
                continue;
            }
            if cs.get(i + 1) == Some(&'{') {
                let mut j = i + 2;
                while cs.get(j).is_some_and(char::is_ascii_digit) {
                    j += 1;
                }
                match cs.get(j) {
                    Some(':') if j > i + 2 => {
                        depth += 1;
                        i = j + 1;
                        continue;
                    }
                    Some('}') if j > i + 2 => {
                        i = j + 1;
                        continue;
                    }
                    Some('|') if j > i + 2 => {
                        let mut k = j + 1;
                        while k < cs.len() && cs[k] != ',' && cs[k] != '|' {
                            out.push(cs[k]);
                            k += 1;
                        }
                        while k < cs.len() && cs[k] != '}' {
                            k += 1;
                        }
                        i = k + 1;
                        continue;
                    }
                    _ => {}
                }
            }
        }
        if c == '}' && depth > 0 {
            depth -= 1;
            i += 1;
            continue;
        }
        out.push(c);
        i += 1;
    }
    out
}

/// DocumentSymbol[] (nested) or SymbolInformation[] (flat) -> depth-first list.
pub(crate) fn parse_symbols(v: &Value) -> Vec<Symbol> {
    fn walk(items: &[Value], depth: u32, out: &mut Vec<Symbol>) {
        for it in items {
            let Some(name) = it["name"].as_str() else { continue };
            // DocumentSymbol has range + selectionRange; SymbolInformation has location.range
            let range = parse_range(&it["range"]).or_else(|| parse_range(&it["location"]["range"]));
            let Some(range) = range else { continue };
            let selection = parse_range(&it["selectionRange"]).unwrap_or(range);
            out.push(Symbol {
                name: name.to_string(),
                detail: it["detail"].as_str().filter(|d| !d.is_empty()).map(str::to_string),
                kind: it["kind"].as_u64().unwrap_or(0) as u8,
                depth,
                selection,
                range,
            });
            if let Some(children) = it["children"].as_array() {
                walk(children, depth + 1, out);
            }
        }
    }
    let mut out = Vec::new();
    if let Some(items) = v.as_array() {
        walk(items, 0, &mut out);
    }
    out
}

pub(crate) fn hover_text(v: &Value) -> Option<String> {
    fn one(m: &Value) -> Option<String> {
        match m {
            Value::String(s) => Some(s.clone()),
            Value::Object(o) => {
                let value = o.get("value")?.as_str()?;
                match o.get("language").and_then(Value::as_str) {
                    Some(lang) => Some(format!("```{lang}\n{value}\n```")),
                    None => Some(value.to_string()),
                }
            }
            _ => None,
        }
    }
    let contents = v.get("contents")?;
    let text = match contents {
        Value::Array(a) => a.iter().filter_map(one).collect::<Vec<_>>().join("\n\n"),
        other => one(other)?,
    };
    (!text.trim().is_empty()).then_some(text)
}

pub fn path_to_uri(os: Os, path: &str) -> String {
    let p = if os == Os::Windows { format!("/{}", path.replace('\\', "/")) } else { path.to_string() };
    let mut out = String::from("file://");
    for b in p.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/:".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

pub fn uri_to_path(os: Os, uri: &str) -> String {
    let rest = uri.strip_prefix("file://").unwrap_or(uri).as_bytes();
    let mut bytes = Vec::with_capacity(rest.len());
    let mut i = 0;
    while i < rest.len() {
        if rest[i] == b'%' && i + 2 < rest.len() {
            if let Ok(b) = u8::from_str_radix(&String::from_utf8_lossy(&rest[i + 1..i + 3]), 16) {
                bytes.push(b);
                i += 3;
                continue;
            }
        }
        bytes.push(rest[i]);
        i += 1;
    }
    let s = String::from_utf8_lossy(&bytes).into_owned();
    if os == Os::Windows {
        s.strip_prefix('/').unwrap_or(&s).replace('/', "\\")
    } else {
        s
    }
}

/// Servers may re-case Windows drive letters or re-encode; compare decoded paths.
fn uri_key(os: Os, uri: &str) -> String {
    let p = uri_to_path(os, uri);
    if os == Os::Windows { p.to_lowercase() } else { p }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(v: &Value) -> Vec<u8> {
        let body = serde_json::to_vec(v).unwrap();
        [format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes(), body].concat()
    }

    #[test]
    fn frames_split_anywhere() {
        let msgs = [json!({"id": 1, "result": {"a": "é"}}), json!({"method": "x", "params": [1, 2]})];
        let wire: Vec<u8> = msgs.iter().flat_map(frame).collect();
        for step in [1, 3, 17, wire.len()] {
            let mut buf = Vec::new();
            let mut got = vec![];
            for piece in wire.chunks(step) {
                buf.extend_from_slice(piece);
                while let Some(b) = next_message(&mut buf) {
                    got.push(serde_json::from_slice::<Value>(&b).unwrap());
                }
            }
            assert_eq!(got, msgs, "step {step}");
        }
    }

    #[test]
    fn snippets_flatten() {
        assert_eq!(strip_snippet("foo(${1:a}, ${2:b})$0"), "foo(a, b)");
        assert_eq!(strip_snippet("println!(\"$1\")"), "println!(\"\")");
        assert_eq!(strip_snippet("${1|one,two|} x"), "one x");
        assert_eq!(strip_snippet("a \\$b \\} ${1:{x\\}}"), "a $b } {x}");
        assert_eq!(strip_snippet("${1:outer ${2:inner}}"), "outer inner");
        assert_eq!(strip_snippet("cost $ 5"), "cost $ 5");
    }

    #[test]
    fn uris_round_trip() {
        assert_eq!(path_to_uri(Os::Mac, "/Users/me/a b/c#.rs"), "file:///Users/me/a%20b/c%23.rs");
        assert_eq!(uri_to_path(Os::Mac, "file:///Users/me/a%20b/c%23.rs"), "/Users/me/a b/c#.rs");
        assert_eq!(path_to_uri(Os::Windows, "C:\\src\\main.rs"), "file:///C:/src/main.rs");
        assert_eq!(uri_to_path(Os::Windows, "file:///c%3A/src/main.rs"), "c:\\src\\main.rs");
        assert_eq!(uri_key(Os::Windows, "file:///c%3A/src/Main.rs"), uri_key(Os::Windows, "file:///C:/src/main.rs"));
    }

    #[test]
    fn completion_shapes() {
        let v = json!({"isIncomplete": false, "items": [
            {"label": "len", "kind": 2, "detail": "fn len(&self) -> usize", "textEdit": {"range": {"start": {"line": 1, "character": 4}, "end": {"line": 1, "character": 6}}, "newText": "len()"}},
            {"label": "push", "insertTextFormat": 2, "insertText": "push(${1:value})$0", "sortText": "0"},
        ]});
        let c = parse_completions(&v);
        assert_eq!(c[0].insert_text, "len()");
        assert_eq!(c[0].edit_range.unwrap().start, Pos { line: 1, character: 4 });
        assert_eq!(c[1].insert_text, "push(value)");
        assert_eq!(c[1].sort_text, "0");
        assert!(parse_completions(&Value::Null).is_empty());
    }

    #[test]
    fn symbol_shapes() {
        let r = |l: u32| json!({"start": {"line": l, "character": 0}, "end": {"line": l, "character": 5}});
        let nested = json!([{"name": "Point", "kind": 23, "range": r(0), "selectionRange": r(0),
            "children": [{"name": "x", "kind": 8, "detail": "i32", "range": r(1), "selectionRange": r(1)}]},
            {"name": "main", "kind": 12, "range": r(4), "selectionRange": r(4)}]);
        let s = parse_symbols(&nested);
        assert_eq!(s.iter().map(|s| (s.name.as_str(), s.depth)).collect::<Vec<_>>(), [("Point", 0), ("x", 1), ("main", 0)]);
        assert_eq!(s[1].detail.as_deref(), Some("i32"));
        let flat = json!([{"name": "f", "kind": 12, "location": {"uri": "file:///a", "range": r(7)}}]);
        assert_eq!(parse_symbols(&flat)[0].selection.start.line, 7);
    }

    #[test]
    fn hover_shapes() {
        assert_eq!(hover_text(&json!({"contents": {"kind": "markdown", "value": "**x**"}})).unwrap(), "**x**");
        assert_eq!(
            hover_text(&json!({"contents": [{"language": "rust", "value": "fn a()"}, "doc"]})).unwrap(),
            "```rust\nfn a()\n```\n\ndoc"
        );
        assert!(hover_text(&json!({"contents": ""})).is_none());
    }

    /// End to end against a real server, when the machine has clangd.
    #[tokio::test]
    async fn clangd_end_to_end() {
        let clangd = ["/usr/bin/clangd", "/usr/local/bin/clangd"].into_iter().find(|p| std::path::Path::new(p).exists());
        let Some(clangd) = clangd else { return };
        let dir = std::env::temp_dir().join(format!("padcode-lsp-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("a.c");
        let src = "struct point { int x; int y; };\nint main(void) {\n  struct point p;\n  p.x = 1;\n  return undefined_thing;\n}\n";
        std::fs::write(&file, src).unwrap();

        let mut child = tokio::process::Command::new(clangd)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let mut stdin = child.stdin.take().unwrap();
        let mut stdout = child.stdout.take().unwrap();
        let (in_tx, mut in_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        tokio::spawn(async move {
            use tokio::io::AsyncWriteExt;
            while let Some(b) = in_rx.recv().await {
                if stdin.write_all(&b).await.is_err() {
                    break;
                }
            }
        });
        let (out_tx, out_rx) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            use tokio::io::AsyncReadExt;
            let mut buf = vec![0u8; 8192];
            while let Ok(n) = stdout.read(&mut buf).await {
                if n == 0 || out_tx.send(buf[..n].to_vec()).is_err() {
                    break;
                }
            }
        });
        let (ev_tx, mut ev_rx) = mpsc::unbounded_channel();
        let server = LanguageServer::start(
            "clangd".into(),
            Os::Mac,
            dir.to_str().unwrap(),
            Box::new(move |b| in_tx.send(b.to_vec()).map_err(|_| Error::Closed)),
            Box::new(|| {}),
            out_rx,
            Arc::default(),
            Arc::new(move |e| {
                let _ = ev_tx.send(e);
            }),
        )
        .await
        .unwrap();
        assert!(server.trigger_characters().contains(&".".to_string()));

        let path = file.to_str().unwrap();
        server.open(path, "c", src).unwrap();
        // completion right after "p." on line 3 (0-based), character 4
        let items = server.completion(path, 3, 4).await.unwrap();
        let labels: Vec<_> = items.iter().map(|c| c.filter_text.as_str()).collect();
        assert!(labels.contains(&"x") && labels.contains(&"y"), "{labels:?}");

        // diagnostics arrive for the undeclared identifier
        let diags = tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                if let Some(Event::Diagnostics { path: p, items }) = ev_rx.recv().await {
                    if p == path && !items.is_empty() {
                        return items;
                    }
                }
            }
        })
        .await
        .unwrap();
        assert!(diags.iter().any(|d| d.message.contains("undefined_thing")), "{diags:?}");

        // go to definition of `p` (line 3, char 2) -> its declaration on line 2
        let defs = server.definition(path, 3, 2).await.unwrap();
        assert_eq!(defs.first().map(|d| d.range.start.line), Some(2), "{defs:?}");

        // hover on `p` mentions its type
        let hover = server.hover(path, 3, 2).await.unwrap().unwrap_or_default();
        assert!(hover.contains("point"), "{hover}");

        // outline: struct point (with fields) and main
        assert!(server.can_symbols());
        let syms = server.symbols(path).await.unwrap();
        let names: Vec<_> = syms.iter().map(|s| s.name.as_str()).collect();
        assert!(names.contains(&"point") && names.contains(&"main"), "{names:?}");

        // formatting: clangd reflows the badly spaced struct
        assert!(server.can_format());
        server.change(path, src.replace("struct point { int x; int y; };", "struct   point{int x;int y;};"));
        let edits = server.format(path, 4, true).await.unwrap();
        assert!(!edits.is_empty());

        // references to `p`: declaration + uses; rename edits each one
        let refs = server.references(path, 3, 2).await.unwrap();
        assert!(refs.len() >= 2, "{refs:?}");
        let ren = server.rename(path, 3, 2, "pt").await.unwrap();
        assert_eq!(ren.first().map(|f| f.edits.len()), Some(refs.len()), "{ren:?}");
        // signature help inside a call to a 2-arg function
        let call = src.replace("  p.x = 1;", "  p.x = add(1, 2);")
            .replace("struct point { int x; int y; };", "struct point { int x; int y; };\nint add(int a, int b) { return a + b; }");
        server.change(path, call);
        let sh = server.signature_help(path, 4, 12).await.unwrap(); // just after "add("
        assert!(sh.as_ref().is_some_and(|s| s.label.contains("int a") && s.active.is_some()), "{sh:?}");
        // code actions request must round-trip (clangd may offer none here)
        let r = Range { start: Pos { line: 6, character: 9 }, end: Pos { line: 6, character: 24 } };
        server.code_actions(path, r, &[]).await.unwrap();
        server.change(path, src.to_string());

        // edits are picked up (full sync): declare the identifier, error goes away
        server.change(path, src.replace("  return undefined_thing;", "  int undefined_thing = 0;\n  return undefined_thing;"));
        let cleared = tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                if let Some(Event::Diagnostics { path: p, items }) = ev_rx.recv().await {
                    if p == path && !items.iter().any(|d| d.message.contains("undefined_thing")) {
                        return true;
                    }
                }
            }
        })
        .await;
        assert!(cleared.is_ok());
        server.shutdown().await;
        let _ = std::fs::remove_dir_all(&dir);
    }
}
