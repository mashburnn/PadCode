//! PadCode core: GitHub sign-in, VS Code tunnel discovery/connection, and the
//! tunnel control-server protocol (files, processes, terminals) for any desktop OS.

mod auth;
mod ffi;
mod local;
mod lsp;
mod remote;
mod rpc;
mod serve;
mod ssh;
mod tunnel;

pub use auth::{finish_login, start_login, DeviceCode};
pub use remote::{
    detect_eol, join, parse_search_line, Eol, Env, EntryKind, DirEntry, Os, Output, SearchHit, SearchOpts,
    Session, Stat, TermInput, Terminal,
};
pub use lsp::{
    CodeAction, Completion, Diagnostic, Event as LspEvent, FileEdit, LanguageServer, Location, Pos, Range, SignatureHelp, Symbol,
    TextEdit,
};
pub use local::connect as connect_local;
pub use ssh::{connect as connect_ssh, generate_key as generate_ssh_key, public_key as ssh_public_key, LoginKey};
pub use tunnel::{connect, list_machines, Machine};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("GitHub sign-in failed: {0}")]
    Auth(String),
    #[error("GitHub sign-in expired, sign in again")]
    AuthExpired,
    #[error("tunnel service: {0}")]
    Tunnel(String),
    #[error("{0} is offline (is `code tunnel` running there?)")]
    Offline(String),
    #[error("{0} runs an old VS Code tunnel (protocol v{1}); update VS Code or the code CLI there")]
    Outdated(String, u32),
    #[error("{0}")]
    Remote(String),
    #[error("No {language} language server found on the desktop")]
    NoLanguageServer { language: String, install: String, detail: String },
    #[error("file changed on disk since it was opened")]
    Conflict,
    #[error("connection closed")]
    Closed,
    #[error("protocol error: {0}")]
    Protocol(String),
    #[error("first connection to this host: its key is {0}")]
    HostKeyUnknown(String),
    #[error("this host's key changed (now {0}). That can mean someone is intercepting the connection; PadCode won't connect.")]
    HostKeyChanged(String),
    #[error("{0}")]
    SshAuth(String),
}

pub type Result<T> = std::result::Result<T, Error>;

uniffi::setup_scaffolding!();
