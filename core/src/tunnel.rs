//! Finding the user's desktops (every `code tunnel` host) and connecting to one.

use crate::{remote::Session, rpc::Rpc, Error, Result};
use std::time::Duration;
use tunnels::{
    connections::RelayTunnelClient,
    contracts::Tunnel,
    management::{
        new_tunnel_management, Authorization, HttpError, TunnelLocator, TunnelManagementClient,
        TunnelRequestOptions,
    },
};

/// VS Code's GitHub OAuth app, as used by the open-source CLI.
pub(crate) const CLIENT_ID: &str = "01ab8ac9400c4e429b23";
/// Label the CLI puts on every `code tunnel` host (`VSCODE_CLI_TUNNEL_TAG`).
const LAUNCHER_TAG: &str = "vscode-server-launcher";
const PROTOCOL_TAG: &str = "protocolv";
/// The CLI's control server (`CONTROL_PORT` in `cli/src/constants.rs`).
const CONTROL_PORT: u16 = 31545;
/// Protocol of VS Code 1.142, the version this was built against. Older may
/// work, but unverified hosts get a clear "update" error instead of odd failures.
const MIN_PROTOCOL: u32 = 6;

#[derive(Debug, Clone)]
pub struct Machine {
    pub name: String,
    pub id: String,
    pub cluster: String,
    pub online: bool,
    pub protocol: Option<u32>,
}

fn mgmt(token: &str) -> TunnelManagementClient {
    let mut b = new_tunnel_management(concat!("padcode/", env!("CARGO_PKG_VERSION")));
    b.authorization(Authorization::Github(format!("client_id={CLIENT_ID} {token}")));
    b.into()
}

fn http_err(e: HttpError) -> Error {
    match &e {
        HttpError::ResponseError(r) if r.status_code.as_u16() == 401 => Error::AuthExpired,
        _ => Error::Tunnel(e.to_string()),
    }
}

fn to_machine(t: &Tunnel) -> Option<Machine> {
    let name = t
        .labels
        .iter()
        .find(|l| l.as_str() != LAUNCHER_TAG && !l.starts_with(PROTOCOL_TAG))
        .or(t.name.as_ref())?
        .clone();
    Some(Machine {
        name,
        id: t.tunnel_id.clone()?,
        cluster: t.cluster_id.clone()?,
        online: t
            .status
            .as_ref()
            .and_then(|s| s.host_connection_count.as_ref())
            .map(|c| c.get_count() > 0)
            .unwrap_or(false),
        protocol: t
            .labels
            .iter()
            .find_map(|l| l.strip_prefix(PROTOCOL_TAG)?.parse().ok()),
    })
}

/// Every desktop signed in to `code tunnel` with this GitHub account.
pub async fn list_machines(token: &str) -> Result<Vec<Machine>> {
    let tunnels = mgmt(token)
        .list_all_tunnels(&TunnelRequestOptions {
            labels: vec![LAUNCHER_TAG.into()],
            ..Default::default()
        })
        .await
        .map_err(http_err)?;
    let mut machines: Vec<Machine> = tunnels.iter().filter_map(to_machine).collect();
    machines.sort_by(|a, b| b.online.cmp(&a.online).then(a.name.cmp(&b.name)));
    Ok(machines)
}

/// Opens a session to one desktop's control server.
pub async fn connect(token: &str, machine: &Machine) -> Result<Session> {
    let client = mgmt(token);
    let t = client
        .get_tunnel(
            &TunnelLocator::ID { cluster: machine.cluster.clone(), id: machine.id.clone() },
            &TunnelRequestOptions {
                include_ports: true,
                token_scopes: vec!["connect".into()],
                ..Default::default()
            },
        )
        .await
        .map_err(http_err)?;
    let endpoint = t.endpoints.first().ok_or_else(|| Error::Offline(machine.name.clone()))?;
    let connect_token = t
        .access_tokens
        .as_ref()
        .and_then(|m| m.get("connect"))
        .ok_or_else(|| Error::Tunnel("no connect token for tunnel".into()))?;

    let relay = RelayTunnelClient::new(client)
        .connect(endpoint, connect_token)
        .await
        .map_err(|e| Error::Tunnel(e.to_string()))?;
    let port = relay
        .connect_to_port(CONTROL_PORT)
        .await
        .map_err(|e| Error::Tunnel(e.to_string()))?;
    let (rd, wr) = tokio::io::split(port.into_rw());
    let (rpc, version) = Rpc::start(rd, wr);

    // The control server greets every pre-authenticated (tunnel) connection.
    let version = tokio::time::timeout(Duration::from_secs(15), version)
        .await
        .map_err(|_| Error::Protocol("no greeting from control server".into()))?
        .map_err(|_| Error::Closed)?;
    if version.protocol_version < MIN_PROTOCOL {
        return Err(Error::Outdated(machine.name.clone(), version.protocol_version));
    }
    Session::start(rpc, relay, machine.name.clone(), version).await
}
