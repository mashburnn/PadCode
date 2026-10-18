//! Desktop harness for the core, against real tunnels:
//!   probe login | list
//!   probe <machine> env | ls [dir] | cat <file> | walk [dir] | search <dir> <text> | shell

use padcore::{Error, Machine, Session};
use std::{path::PathBuf, process::Command, time::Duration};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn token_path() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap()).join(".config/padcode/github-token")
}

async fn login() -> padcore::Result<String> {
    let code = padcore::start_login().await?;
    eprintln!("Open {} and enter code: {}", code.verification_uri, code.user_code);
    let token = padcore::finish_login(&code).await?;
    let p = token_path();
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(&p, &token).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    eprintln!("signed in");
    Ok(token)
}

async fn token() -> padcore::Result<String> {
    match std::fs::read_to_string(token_path()) {
        Ok(t) => Ok(t.trim().to_string()),
        Err(_) => login().await,
    }
}

async fn find(token: &str, name: &str) -> padcore::Result<Machine> {
    padcore::list_machines(token)
        .await?
        .into_iter()
        .find(|m| m.name.eq_ignore_ascii_case(name))
        .ok_or_else(|| Error::Tunnel(format!("no machine named {name}")))
}

fn stty(args: &[&str]) -> String {
    let out = Command::new("stty").args(args).stdin(std::process::Stdio::inherit()).output();
    out.map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default()
}

fn local_size() -> (u16, u16) {
    let s = stty(&["size"]);
    let mut it = s.split_whitespace().filter_map(|v| v.parse().ok());
    match (it.next(), it.next()) {
        (Some(rows), Some(cols)) => (cols, rows),
        _ => (80, 24),
    }
}

async fn shell(s: &Session) -> padcore::Result<()> {
    let (cols, rows) = local_size();
    let saved = stty(&["-g"]);
    stty(&["raw", "-echo"]);
    let result = run_shell(s, cols, rows).await;
    stty(&[&saved]);
    println!();
    result
}

async fn run_shell(s: &Session, cols: u16, rows: u16) -> padcore::Result<()> {
    let mut term = s.open_terminal(cols, rows, None, None, 0).await?;
    let mut stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();
    let mut size = (cols, rows);
    let mut tick = tokio::time::interval(Duration::from_millis(500));
    let mut buf = vec![0u8; 4096];
    loop {
        tokio::select! {
            chunk = term.output.recv() => match chunk {
                Some(c) => { stdout.write_all(&c).await.ok(); stdout.flush().await.ok(); }
                None => break,
            },
            n = stdin.read(&mut buf) => match n {
                Ok(0) | Err(_) => { term.input.close()?; }
                Ok(n) => term.input.write(&buf[..n])?,
            },
            _ = tick.tick() => {
                let now = local_size();
                if now != size { size = now; term.input.resize(now.0, now.1)?; }
            }
        }
    }
    let code = (&mut term.exit).await.ok().flatten().unwrap_or(-1);
    eprint!("\r\n[shell exited with {code}]");
    Ok(())
}

#[tokio::main]
async fn main() -> padcore::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    match a.as_slice() {
        ["login"] => {
            login().await?;
        }
        ["list"] => {
            for m in padcore::list_machines(&token().await?).await? {
                println!(
                    "{:<24} {:<8} protocol v{}",
                    m.name,
                    if m.online { "online" } else { "offline" },
                    m.protocol.map(|p| p.to_string()).unwrap_or("?".into())
                );
            }
        }
        [name, cmd, rest @ ..] => {
            let t = token().await?;
            let m = find(&t, name).await?;
            let started = std::time::Instant::now();
            let s = padcore::connect(&t, &m).await?;
            eprintln!("connected to {} in {:?}", s.machine, started.elapsed());
            let home = s.env.home.clone();
            match (*cmd, rest) {
                ("env", _) => println!(
                    "os={:?} release={} home={} cli={} protocol={}",
                    s.env.os, s.env.os_release, s.env.home, s.env.cli_version, s.env.protocol
                ),
                ("ls", dir) => {
                    for e in s.list_dir(dir.first().copied().unwrap_or(&home)).await? {
                        println!("{:?}\t{}", e.kind, e.name);
                    }
                }
                ("cat", [file]) => {
                    tokio::io::stdout().write_all(&s.read_file(file).await?).await.ok();
                }
                ("walk", dir) => {
                    let t0 = std::time::Instant::now();
                    let files = s.walk(dir.first().copied().unwrap_or(&home), 50_000).await?;
                    for f in files.iter().take(20) {
                        println!("{f}");
                    }
                    eprintln!("{} files in {:?}", files.len(), t0.elapsed());
                }
                ("search", [dir, text]) => {
                    for h in s.search(dir, text, 50, Default::default()).await? {
                        println!("{}:{}: {}", h.path, h.line, h.text);
                    }
                }
                ("shell", _) => shell(&s).await?,
                ("lsp", [file, lang, line, col]) => {
                    // probe <machine> lsp <file> <language-id> <line> <col>  (0-based)
                    let root = file.rsplit_once('/').map(|(d, _)| d).unwrap_or("/");
                    let t0 = std::time::Instant::now();
                    let srv = s
                        .language_server(lang, root, std::sync::Arc::new(|e| eprintln!("event: {e:?}")))
                        .await?;
                    eprintln!("{} started in {:?}", srv.name, t0.elapsed());
                    let text = String::from_utf8_lossy(&s.read_file(file).await?).into_owned();
                    srv.open(file, lang, &text)?;
                    let (l, c) = (line.parse().unwrap(), col.parse().unwrap());
                    let items = srv.completion(file, l, c).await?;
                    println!("{} completions: {:?}", items.len(), items.iter().take(8).map(|i| &i.label).collect::<Vec<_>>());
                    println!("hover: {:?}", srv.hover(file, l, c).await?);
                    println!("definition: {:?}", srv.definition(file, l, c).await?);
                    tokio::time::sleep(Duration::from_secs(3)).await; // let diagnostics arrive
                    srv.shutdown().await;
                }
                _ => eprintln!("unknown command"),
            }
        }
        _ => eprintln!("usage: probe login | list | <machine> env|ls|cat|walk|search|shell"),
    }
    Ok(())
}
