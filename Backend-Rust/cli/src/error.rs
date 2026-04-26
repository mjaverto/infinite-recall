//! CLI error type. Each variant maps to a stable, documented exit code so
//! shell scripts and coding agents can branch on failure mode without parsing
//! stderr. The mapping mirrors the table in the design doc:
//!
//! | Code | Variant       | Cause                                                |
//! |------|---------------|------------------------------------------------------|
//! | 1    | `Runtime`     | Generic runtime / parse / unexpected error           |
//! | 2    | (clap)        | Usage error — surfaced by clap, never constructed here |
//! | 3    | `Unreachable` | Could not reach the daemon (connect / timeout)       |
//! | 4    | `AuthFailed`  | 401 from API or missing/empty token file             |
//! | 5    | `NotFound`    | 404 from API                                         |

use std::fmt;

#[derive(Debug)]
pub enum CliError {
    Runtime(String),
    Unreachable(String),
    AuthFailed(String),
    NotFound(String),
}

impl CliError {
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Runtime(_) => 1,
            Self::Unreachable(_) => 3,
            Self::AuthFailed(_) => 4,
            Self::NotFound(_) => 5,
        }
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Runtime(m) => write!(f, "error: {m}"),
            Self::Unreachable(m) => write!(
                f,
                "daemon unreachable: {m}\n\
                 hint: launchctl kickstart gui/$(id -u)/com.infiniterecall.api"
            ),
            Self::AuthFailed(m) => write!(f, "auth failed: {m}"),
            Self::NotFound(m) => write!(f, "not found: {m}"),
        }
    }
}

impl From<anyhow::Error> for CliError {
    fn from(e: anyhow::Error) -> Self {
        Self::Runtime(format!("{e:#}"))
    }
}
