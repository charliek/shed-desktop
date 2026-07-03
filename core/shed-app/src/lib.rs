//! shed-app — the display-free app-logic layer shared by the shed clients: the
//! shed-core-backed [`Backend`] (one HTTP client per configured host + the
//! pull-based create store), with no UI or env-prefix coupling. The GTK + Tauri
//! clients (and later the Swift app via the FFI) each build it from their own
//! `SHED_*_` env via [`Backend::from_env_parts`]. Depends only on the pure
//! `shed-core` protocol crate — this is where the per-client app logic that was
//! Swift-only (poller, df/images, the reachability rollup) will also land (A1a-add).

pub mod backend;
pub mod host_agent;
pub mod timefmt;
pub mod token_minter;
pub mod traits;

pub use backend::{Backend, HostDiskUsage, Reachability};
pub use host_agent::{HelloClientInfo, HostAgentClient, HostAgentClientError, HostAgentEvent};
pub use token_minter::HostAgentTokenMinter;
pub use traits::{Clock, ClockRef, SystemClock};
