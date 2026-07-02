//! The shed-core-backed data layer, shared by the IPC handler and the GTK UI: it
//! owns one HTTP client per configured server and fetches sheds. In test mode
//! every client is pointed at the single mock base URL (hermetic), mirroring the
//! Swift `ShedBackend`/`AppModel` client construction.

use shed_core::config::ShedConfig;
use shed_core::http::Client;
use shed_core::models::Shed;

use crate::env::Env;

pub struct Backend {
    /// One client per configured server; shed-core stamps each shed's `host`.
    clients: Vec<Client>,
}

impl Backend {
    /// Build from the process `Env`: load the config file, then construct the
    /// per-server clients.
    pub fn new(env: &Env) -> Self {
        // Hermeticity: test mode must have a mock to redirect every client to; a
        // partial test env (TEST_MODE without MOCK_BASE_URL) builds NO clients
        // rather than dialing the developer's real hosts.
        if env.test_mode && env.mock_base_url.is_none() {
            return Self {
                clients: Vec::new(),
            };
        }
        let config = ShedConfig::load(&env.config_path.to_string_lossy());
        Self::from_config(&config, env.mock_base_url.as_deref())
    }

    /// Build clients from an already-parsed config. When `mock_base_url` is set
    /// (test mode) every server is redirected to that single hermetic mock —
    /// plain HTTP, no pin, no token — so no real host is touched.
    pub fn from_config(config: &ShedConfig, mock_base_url: Option<&str>) -> Self {
        let clients = config
            .servers
            .iter()
            .filter_map(|s| {
                let (base_url, pin, token) = match mock_base_url {
                    Some(mock) => (mock.to_string(), String::new(), String::new()),
                    None => {
                        let r = s.resolved_endpoint();
                        (r.base_url, r.pin, s.control_token.clone())
                    }
                };
                // Host-agent token minting is deferred for GTK (M6); open/static
                // servers work now. A pin on a non-https URL fails closed in
                // Client::new → that server is skipped rather than sent plaintext.
                Client::new(
                    base_url,
                    s.name.clone(),
                    token,
                    (!pin.is_empty()).then_some(pin),
                    None,
                )
                .ok()
            })
            .collect();
        Self { clients }
    }

    /// Fetch sheds from every configured host (host-stamped by shed-core). A
    /// per-host failure is dropped rather than blanking the whole dashboard;
    /// surfacing per-host errors is a later milestone.
    pub async fn list_sheds(&self) -> Vec<Shed> {
        let mut out = Vec::new();
        for client in &self.clients {
            if let Ok(sheds) = client.list_sheds().await {
                out.extend(sheds);
            }
        }
        out
    }
}
