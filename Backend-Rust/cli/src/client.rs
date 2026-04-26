//! Thin blocking HTTP client over `reqwest`.
//!
//! Single responsibility: send a request, return parsed JSON, map transport
//! and HTTP-status failures to [`CliError`] variants. Command modules don't
//! know `reqwest` exists.

use std::time::Duration;

use reqwest::blocking::{Client as HttpClient, RequestBuilder, Response};
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION};
use reqwest::StatusCode;
use serde_json::Value;

use crate::error::CliError;

pub struct Client {
    base_url: String,
    token: Option<String>,
    http: HttpClient,
}

impl Client {
    pub fn new(
        base_url: String,
        token: Option<String>,
        timeout_secs: u64,
    ) -> Result<Self, CliError> {
        let http = HttpClient::builder()
            .timeout(Duration::from_secs(timeout_secs))
            .build()
            .map_err(|e| CliError::Runtime(format!("building http client: {e}")))?;
        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            token,
            http,
        })
    }

    /// GET `path` with optional query params. Returns the parsed JSON body
    /// on 2xx, or maps the status code to a typed [`CliError`].
    pub fn get(&self, path: &str, query: &[(&str, String)]) -> Result<Value, CliError> {
        let url = format!("{}{}", self.base_url, path);
        let req = self.http.get(&url).query(query);
        self.send(req)
    }

    fn send(&self, builder: RequestBuilder) -> Result<Value, CliError> {
        let mut headers = HeaderMap::new();
        headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
        if let Some(t) = &self.token {
            let v = HeaderValue::from_str(&format!("Bearer {t}"))
                .map_err(|e| CliError::Runtime(format!("invalid token: {e}")))?;
            headers.insert(AUTHORIZATION, v);
        }

        let resp = builder.headers(headers).send().map_err(|e| {
            // Connect failures and timeouts are the daemon-down case;
            // everything else is a generic transport error.
            if e.is_connect() || e.is_timeout() {
                CliError::Unreachable(format!("{e}"))
            } else {
                CliError::Runtime(format!("http error: {e}"))
            }
        })?;

        handle_response(resp)
    }
}

fn handle_response(resp: Response) -> Result<Value, CliError> {
    let status = resp.status();
    if status.is_success() {
        return resp
            .json::<Value>()
            .map_err(|e| CliError::Runtime(format!("decoding response: {e}")));
    }

    // Surface the daemon's `{error, message}` body when present.
    let body_text = resp.text().unwrap_or_default();
    let body_msg = serde_json::from_str::<Value>(&body_text)
        .ok()
        .and_then(|v| {
            v.get("message")
                .and_then(|m| m.as_str())
                .map(|s| s.to_string())
        })
        .unwrap_or_else(|| body_text.trim().to_string());

    let msg_or = |fallback: &str| -> String {
        if body_msg.is_empty() {
            fallback.to_string()
        } else {
            body_msg.clone()
        }
    };

    match status {
        StatusCode::UNAUTHORIZED => Err(CliError::AuthFailed(msg_or("401 Unauthorized"))),
        StatusCode::NOT_FOUND => Err(CliError::NotFound(msg_or("404 Not Found"))),
        s => Err(CliError::Runtime(format!(
            "http {}: {}",
            s.as_u16(),
            msg_or("(no body)")
        ))),
    }
}
