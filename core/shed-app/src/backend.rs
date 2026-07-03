//! The shed-core-backed data layer shared by every client: it owns one HTTP
//! client per configured server (+ a create store) and performs the reads,
//! lifecycle actions, and creates. In test mode every client is pointed at the
//! single mock base URL (hermetic), mirroring the Swift ShedBackend/AppModel.
//!
//! Env-agnostic: [`from_env_parts`](Backend::from_env_parts) takes the resolved
//! `(test_mode, mock_base_url, config_path)` rather than a client's `SHED_*_` env
//! struct, so the GTK + Tauri clients share one implementation.

use std::path::Path;

use tokio::runtime::Handle;

use shed_core::config::ShedConfig;
use shed_core::create::{CreateProgress, CreateStore};
use shed_core::http::{Client, ShedError};
use shed_core::models::{CreateShedRequest, Shed};

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
    /// Build from a client's resolved env parts: load the config file, then
    /// construct the per-server clients.
    ///
    /// Hermeticity: test mode must have a mock to redirect every client to; a
    /// partial test env (`test_mode` without `mock_base_url`) builds NO clients
    /// rather than dialing the developer's real hosts.
    pub fn from_env_parts(
        test_mode: bool,
        mock_base_url: Option<&str>,
        config_path: &Path,
    ) -> Self {
        if test_mode && mock_base_url.is_none() {
            return Self {
                clients: Vec::new(),
                default_server: None,
                creates: CreateStore::new(),
            };
        }
        let config = ShedConfig::load(&config_path.to_string_lossy());
        Self::from_config(&config, mock_base_url)
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
                // minting is deferred (Phase B / the approval spine).
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

    /// Fetch sheds from every configured host concurrently (host-stamped by
    /// shed-core). `join_all` so a slow/down host doesn't serialize the others —
    /// each is bounded by shed-core's per-request timeout. A per-host failure is
    /// dropped rather than blanking the whole dashboard; surfacing per-host errors
    /// is A1a-add (the reachability rollup).
    pub async fn list_sheds(&self) -> Vec<Shed> {
        let fetches = self.clients.iter().map(|(_, client)| client.list_sheds());
        futures::future::join_all(fetches)
            .await
            .into_iter()
            .filter_map(Result::ok)
            .flatten()
            .collect()
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

#[cfg(test)]
mod tests {
    use super::*;
    use httpmock::prelude::*;
    use std::path::PathBuf;

    /// A backend with clients pointed at explicit URLs (bypasses config + the
    /// mock-redirect) so the multi-host concurrent path is exercised directly.
    fn backend_with(clients: Vec<(String, Client)>) -> Backend {
        Backend {
            clients,
            default_server: None,
            creates: CreateStore::new(),
        }
    }

    fn client_at(name: &str, base_url: String) -> (String, Client) {
        let client = Client::new(base_url, name.to_string(), String::new(), None, None).unwrap();
        (name.to_string(), client)
    }

    #[tokio::test]
    async fn from_env_parts_test_mode_without_mock_builds_no_clients() {
        // Hermeticity: a partial test env must not dial the developer's real hosts.
        let backend =
            Backend::from_env_parts(true, None, &PathBuf::from("/does/not/matter"));
        assert!(backend.list_sheds().await.is_empty());
    }

    #[tokio::test]
    async fn list_sheds_zero_hosts_is_empty() {
        assert!(backend_with(Vec::new()).list_sheds().await.is_empty());
    }

    #[tokio::test]
    async fn list_sheds_keeps_healthy_host_when_another_fails() {
        // One host 500s, the other returns a shed → only the healthy one's sheds;
        // the failing host doesn't blank the dashboard (concurrent join_all).
        let bad = MockServer::start_async().await;
        bad.mock_async(|w, t| {
            w.method(GET).path("/api/sheds");
            t.status(500);
        })
        .await;
        let good = MockServer::start_async().await;
        good.mock_async(|w, t| {
            w.method(GET).path("/api/sheds");
            t.status(200)
                .body(r#"{"sheds":[{"name":"g","status":"running"}]}"#);
        })
        .await;
        let backend = backend_with(vec![
            client_at("bad", bad.base_url()),
            client_at("good", good.base_url()),
        ]);
        let sheds = backend.list_sheds().await;
        assert_eq!(sheds.len(), 1);
        assert_eq!(sheds[0].name, "g");
        assert_eq!(sheds[0].host, "good");
    }

    #[tokio::test]
    async fn host_less_op_falls_back_to_first_when_default_missing() {
        // A `default_server` naming a server that isn't configured resolves a
        // host-less lifecycle op to the FIRST client (Vec order) — not an error,
        // and not the (alphabetically-first) second. The second client points at an
        // unused address, so a wrong fallback surfaces as a transport failure rather
        // than a false pass.
        let first = MockServer::start_async().await;
        let hit = first
            .mock_async(|w, t| {
                w.method(POST).path("/api/sheds/thing/start");
                t.status(200);
            })
            .await;
        let backend = Backend {
            clients: vec![
                client_at("z-first", first.base_url()),
                client_at("a-second", "http://127.0.0.1:1".to_string()),
            ],
            default_server: Some("nonexistent".to_string()),
            creates: CreateStore::new(),
        };
        backend
            .start(None, "thing")
            .await
            .expect("host-less op falls back to the first configured client");
        hit.assert_async().await;
    }

    #[tokio::test]
    async fn list_sheds_decodes_null_sheds_as_empty() {
        // Defensive decode: `{"sheds": null}` → [] (never an error), per shed-core.
        let server = MockServer::start_async().await;
        server
            .mock_async(|w, t| {
                w.method(GET).path("/api/sheds");
                t.status(200).body(r#"{"sheds": null}"#);
            })
            .await;
        let backend = backend_with(vec![client_at("s", server.base_url())]);
        assert!(backend.list_sheds().await.is_empty());
    }
}
