//! GitHub OAuth device flow, same parameters as the VS Code CLI (`cli/src/auth.rs`).

use crate::{tunnel::CLIENT_ID, Error, Result};
use serde::Deserialize;
use std::time::Duration;

const CODE_URI: &str = "https://github.com/login/device/code";
const GRANT_URI: &str = "https://github.com/login/oauth/access_token";
const SCOPES: &str = "read:user+read:org";

#[derive(Debug, Clone, Deserialize)]
pub struct DeviceCode {
    /// Code the user types at `verification_uri`.
    pub user_code: String,
    pub verification_uri: String,
    device_code: String,
    #[serde(default = "default_interval")]
    interval: u64,
}

fn default_interval() -> u64 {
    5
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: Option<String>,
    error: Option<String>,
    error_description: Option<String>,
}

async fn post_form<T: for<'de> Deserialize<'de>>(url: &str, body: String) -> Result<T> {
    reqwest::Client::new()
        .post(url)
        .header("Accept", "application/json")
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(body)
        .send()
        .await
        .map_err(|e| Error::Auth(e.to_string()))?
        .json()
        .await
        .map_err(|e| Error::Auth(e.to_string()))
}

/// Step 1: ask GitHub for a device code to show the user.
pub async fn start_login() -> Result<DeviceCode> {
    post_form(CODE_URI, format!("client_id={CLIENT_ID}&scope={SCOPES}")).await
}

/// Step 2: poll until the user approves; returns the GitHub access token.
pub async fn finish_login(code: &DeviceCode) -> Result<String> {
    let body = format!(
        "client_id={CLIENT_ID}&grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code={}",
        code.device_code
    );
    let mut interval = code.interval.max(1);
    loop {
        tokio::time::sleep(Duration::from_secs(interval)).await;
        let r: TokenResponse = post_form(GRANT_URI, body.clone()).await?;
        if let Some(token) = r.access_token {
            return Ok(token);
        }
        match r.error.as_deref() {
            Some("authorization_pending") => {}
            // https://www.rfc-editor.org/rfc/rfc8628#section-3.5
            Some("slow_down") => interval += 5,
            _ => {
                return Err(Error::Auth(
                    r.error_description.or(r.error).unwrap_or_else(|| "no token".into()),
                ))
            }
        }
    }
}
