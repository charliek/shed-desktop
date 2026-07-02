//! The shed-core-backed data layer, shared by the IPC handler and the GTK UI: it
//! owns one HTTP client per configured server (+ a create store) and performs the
//! reads, lifecycle actions, and creates. In test mode every client is pointed at
//! the single mock base URL (hermetic), mirroring the Swift ShedBackend/AppModel.

use tokio::runtime::Handle;

use shed_core::config::ShedConfig;
use shed_core::create::{CreateProgress, CreateStore};
use shed_core::http::{Client, ShedError};
use shed_core::models::{CreateShedRequest, Shed};

use crate::env::Env;

pub struct Backend {
    /// (server_name, client) — shed-core stamps each shed's `host` with the name.
    clients: Vec<(String, Client)>,
    /// The config's `default_server`, used to resolve host-less lifecycle/create
    /// ops (`ShedConfig` sorts servers by name, so "first" is not the default).
    default_server: Option<String>,
    /// Pull-based store of in-flight creates (the pure shed-core orchestration).
    creates: CreateStore,
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
                default_server: None,
                creates: CreateStore::new(),
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
                // A pin on a non-https URL fails closed in Client::new → that
                // server is skipped rather than sent plaintext. Host-agent token
                // minting is deferred for GTK (M6).
                let client = Client::new(
                    base_url,
                    s.name.clone(),
                    token,
                    (!pin.is_empty()).then_some(pin),
                    None,
                )
                .ok()?;
                Some((s.name.clone(), client))
            })
            .collect();
        Self {
            clients,
            default_server: config.default_server.clone(),
            creates: CreateStore::new(),
        }
    }

    /// Resolve a client by host name; a host-less op targets the config's
    /// `default_server`, falling back to the first configured host.
    fn client_for(&self, host: Option<&str>) -> Result<&Client, ShedError> {
        let by_name = |n: &str| {
            self.clients
                .iter()
                .find(|(name, _)| name == n)
                .map(|(_, c)| c)
        };
        let found = match host {
            Some(h) => by_name(h),
            None => self
                .default_server
                .as_deref()
                .and_then(by_name)
                .or_else(|| self.clients.first().map(|(_, c)| c)),
        };
        found.ok_or_else(|| {
            let which = host.map(|h| format!(": {h}")).unwrap_or_default();
            ShedError::Config(format!("no configured host{which}"))
        })
    }

    /// Fetch sheds from every configured host (host-stamped by shed-core). A
    /// per-host failure is dropped rather than blanking the whole dashboard;
    /// surfacing per-host errors is a later milestone.
    pub async fn list_sheds(&self) -> Vec<Shed> {
        let mut out = Vec::new();
        for (_, client) in &self.clients {
            if let Ok(sheds) = client.list_sheds().await {
                out.extend(sheds);
            }
        }
        out
    }

    // -- lifecycle --------------------------------------------------------

    pub async fn start(&self, host: Option<&str>, name: &str) -> Result<(), ShedError> {
        self.client_for(host)?.start(name).await
    }
    pub async fn stop(&self, host: Option<&str>, name: &str) -> Result<(), ShedError> {
        self.client_for(host)?.stop(name).await
    }
    pub async fn reset(&self, host: Option<&str>, name: &str) -> Result<(), ShedError> {
        self.client_for(host)?.reset(name).await
    }
    pub async fn delete(&self, host: Option<&str>, name: &str) -> Result<(), ShedError> {
        self.client_for(host)?.delete(name).await
    }

    // -- create (on the pure shed-core CreateStore) -----------------------

    /// Start a create on `host`; the SSE stream runs on `rt` in the background.
    /// Returns the id the caller polls via [`create_status`](Self::create_status).
    pub fn create_start(
        &self,
        rt: &Handle,
        host: Option<&str>,
        req: CreateShedRequest,
    ) -> Result<String, ShedError> {
        let client = self.client_for(host)?;
        Ok(self.creates.start(rt, client, req))
    }

    pub fn create_status(&self, id: &str) -> Option<CreateProgress> {
        self.creates.status(id)
    }

    pub fn create_cancel(&self, id: &str) {
        self.creates.cancel(id);
    }
}
