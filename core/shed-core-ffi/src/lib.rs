//! UniFFI bridge over `shed-core` → Swift. Kept thin so Phase 3's GTK app can
//! link `shed-core` directly without paying for UniFFI.
//!
//! The wire DTOs live in the pure `shed-core` crate; the UniFFI records here
//! mirror them (with `From` conversions), so `shed-core` needs no uniffi
//! dependency. The Swift adapter maps these records to the app's Swift `Models`;
//! the M2 golden-JSON parity gate guards the two representations against drift.

use std::sync::Arc;

use shed_core::http::{Client, ShedError as CoreError};
use shed_core::models;

uniffi::setup_scaffolding!();

// ---- M0 FFI canary (async method + foreign async callback + cancellation) ----

/// M0 canary: an async export routed through the shared tokio runtime.
#[uniffi::export(async_runtime = "tokio")]
pub async fn ping(echo: String) -> String {
    shed_core::ping(echo).await
}

/// A Swift→Rust async callback, mirroring the shape of the real TokenMinter
/// (Rust owns the token FSM in M3; the host-agent mint stays foreign).
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait MinterProbe: Send + Sync {
    async fn mint(&self, server: String) -> String;
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn mint_via(minter: Arc<dyn MinterProbe>, server: String) -> String {
    minter.mint(server).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn slow_echo(echo: String, delay_ms: u64) -> String {
    tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
    format!("slow: {echo}")
}

// ---- ShedCore: the shed-server read client exposed to Swift (M2) ----

/// FFI error mirroring `shed-core`'s `ShedError` (and Swift's `ShedClientError`).
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ShedError {
    #[error("shed-server returned HTTP {status}")]
    BadStatus { status: u16 },
    #[error("transport error: {message}")]
    Transport { message: String },
    #[error("decode error: {message}")]
    Decode { message: String },
    #[error("create failed: {message}")]
    Create { message: String },
    #[error("{message}")]
    Config { message: String },
}

impl From<CoreError> for ShedError {
    fn from(e: CoreError) -> Self {
        match e {
            CoreError::BadStatus(status) => ShedError::BadStatus { status },
            CoreError::Transport(message) => ShedError::Transport { message },
            CoreError::Decode(message) => ShedError::Decode { message },
            CoreError::Create(message) => ShedError::Create { message },
            CoreError::Config(message) => ShedError::Config { message },
        }
    }
}

#[derive(uniffi::Enum)]
pub enum ShedStatus {
    Running,
    Stopped,
    Starting,
    Error,
    Unknown,
}

impl From<models::ShedStatus> for ShedStatus {
    fn from(s: models::ShedStatus) -> Self {
        match s {
            models::ShedStatus::Running => ShedStatus::Running,
            models::ShedStatus::Stopped => ShedStatus::Stopped,
            models::ShedStatus::Starting => ShedStatus::Starting,
            models::ShedStatus::Error => ShedStatus::Error,
            models::ShedStatus::Unknown => ShedStatus::Unknown,
        }
    }
}

#[derive(uniffi::Record)]
pub struct ServerInfo {
    pub name: String,
    pub version: String,
    pub backend: Option<String>,
    pub ssh_port: Option<i64>,
    pub http_port: Option<i64>,
}

impl From<models::ServerInfo> for ServerInfo {
    fn from(v: models::ServerInfo) -> Self {
        Self {
            name: v.name,
            version: v.version,
            backend: v.backend,
            ssh_port: v.ssh_port,
            http_port: v.http_port,
        }
    }
}

#[derive(uniffi::Record)]
pub struct Shed {
    pub host: String,
    pub name: String,
    pub status: ShedStatus,
    pub backend: Option<String>,
    pub repo: Option<String>,
    pub image: Option<String>,
    pub image_digest: Option<String>,
    pub local_dir: Option<String>,
    pub ip_address: Option<String>,
    pub cpus: Option<i64>,
    pub memory_mb: Option<i64>,
    pub created_at: Option<String>,
    pub started_at: Option<String>,
    pub active_namespaces: Vec<String>,
}

impl From<models::Shed> for Shed {
    fn from(v: models::Shed) -> Self {
        Self {
            host: v.host,
            name: v.name,
            status: v.status.into(),
            backend: v.backend,
            repo: v.repo,
            image: v.image,
            image_digest: v.image_digest,
            local_dir: v.local_dir,
            ip_address: v.ip_address,
            cpus: v.cpus,
            memory_mb: v.memory_mb,
            created_at: v.created_at,
            started_at: v.started_at,
            active_namespaces: v.active_namespaces,
        }
    }
}

#[derive(uniffi::Record)]
pub struct ShedImage {
    pub name: String,
    pub docker_ref: Option<String>,
    pub alias: Option<String>,
    pub is_default: bool,
    pub cached: bool,
    pub in_use: bool,
    pub digest: Option<String>,
    pub source: Option<String>,
    pub size_bytes: i64,
}

impl From<models::ShedImage> for ShedImage {
    fn from(v: models::ShedImage) -> Self {
        Self {
            name: v.name,
            docker_ref: v.docker_ref,
            alias: v.alias,
            is_default: v.is_default,
            cached: v.cached,
            in_use: v.in_use,
            digest: v.digest,
            source: v.source,
            size_bytes: v.size_bytes,
        }
    }
}

#[derive(uniffi::Record)]
pub struct DiskSize {
    pub logical_bytes: i64,
    pub physical_bytes: i64,
}

impl From<models::DiskSize> for DiskSize {
    fn from(v: models::DiskSize) -> Self {
        Self {
            logical_bytes: v.logical_bytes,
            physical_bytes: v.physical_bytes,
        }
    }
}

#[derive(uniffi::Record)]
pub struct DiskEntry {
    pub name: String,
    pub docker_ref: Option<String>,
    pub size: DiskSize,
}

impl From<models::DiskEntry> for DiskEntry {
    fn from(v: models::DiskEntry) -> Self {
        Self {
            name: v.name,
            docker_ref: v.docker_ref,
            size: v.size.into(),
        }
    }
}

#[derive(uniffi::Record)]
pub struct DiskTotals {
    pub images: DiskSize,
    pub sheds: DiskSize,
    pub snapshots: DiskSize,
    pub orphans: DiskSize,
    pub all: DiskSize,
}

impl From<models::DiskTotals> for DiskTotals {
    fn from(v: models::DiskTotals) -> Self {
        Self {
            images: v.images.into(),
            sheds: v.sheds.into(),
            snapshots: v.snapshots.into(),
            orphans: v.orphans.into(),
            all: v.all.into(),
        }
    }
}

#[derive(uniffi::Record)]
pub struct SystemDiskUsage {
    pub server_name: Option<String>,
    pub backend: Option<String>,
    pub images: Vec<DiskEntry>,
    pub sheds: Vec<DiskEntry>,
    pub orphans: Vec<DiskEntry>,
    pub totals: DiskTotals,
}

impl From<models::SystemDiskUsage> for SystemDiskUsage {
    fn from(v: models::SystemDiskUsage) -> Self {
        Self {
            server_name: v.server_name,
            backend: v.backend,
            images: v.images.into_iter().map(Into::into).collect(),
            sheds: v.sheds.into_iter().map(Into::into).collect(),
            orphans: v.orphans.into_iter().map(Into::into).collect(),
            totals: v.totals.into(),
        }
    }
}

#[derive(uniffi::Record)]
pub struct EgressProfile {
    pub mode: Option<String>,
    pub allow: Option<Vec<String>>,
    pub deny: Option<Vec<String>>,
    pub rule: Option<String>,
}

impl From<models::EgressProfile> for EgressProfile {
    fn from(v: models::EgressProfile) -> Self {
        Self {
            mode: v.mode,
            allow: v.allow,
            deny: v.deny,
            rule: v.rule,
        }
    }
}

#[derive(uniffi::Record)]
pub struct EgressProfileInfo {
    pub name: String,
    pub source: String,
    pub profile: EgressProfile,
}

impl From<models::EgressProfileInfo> for EgressProfileInfo {
    fn from(v: models::EgressProfileInfo) -> Self {
        Self {
            name: v.name,
            source: v.source,
            profile: v.profile.into(),
        }
    }
}

/// A read client for one shed-server host. The base URL is injected by the app
/// (the core is env-agnostic); `server_name` is stamped onto listed sheds.
#[derive(uniffi::Object)]
pub struct ShedCore {
    client: Client,
}

#[uniffi::export(async_runtime = "tokio")]
impl ShedCore {
    #[uniffi::constructor]
    pub fn new(base_url: String, server_name: String) -> Result<Arc<Self>, ShedError> {
        Ok(Arc::new(Self {
            client: Client::new(base_url, server_name)?,
        }))
    }

    /// `GET /api/info`.
    pub async fn info(&self) -> Result<ServerInfo, ShedError> {
        Ok(self.client.info().await?.into())
    }

    /// `GET /api/sheds` (host-stamped).
    pub async fn list_sheds(&self) -> Result<Vec<Shed>, ShedError> {
        Ok(self
            .client
            .list_sheds()
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// `GET /api/system/df`.
    pub async fn system_df(&self) -> Result<SystemDiskUsage, ShedError> {
        Ok(self.client.system_df().await?.into())
    }

    /// `GET /api/images`.
    pub async fn list_images(&self) -> Result<Vec<ShedImage>, ShedError> {
        Ok(self
            .client
            .list_images()
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// `GET /api/egress/profiles`.
    pub async fn egress_profiles(&self) -> Result<Vec<EgressProfileInfo>, ShedError> {
        Ok(self
            .client
            .egress_profiles()
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }
}
