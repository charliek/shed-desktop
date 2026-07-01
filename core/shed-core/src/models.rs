//! Wire DTOs ported from shed-desktop's `Models.swift`.
//!
//! These decoders must reproduce the defensive semantics pinned by
//! `ModelDecodingTests` exactly (M1): `{"sheds": null}` → `[]`, omitted
//! optionals, `host` stamped post-decode, lenient `ShedStatus`, `"?"` name
//! sentinels, and timestamps carried VERBATIM as strings (never normalized).

use serde::Deserialize;

/// `GET /api/info`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ServerInfo {
    pub name: String,
    pub version: String,
    #[serde(default)]
    pub backend: Option<String>,
    #[serde(default)]
    pub ssh_port: Option<i64>,
    #[serde(default)]
    pub http_port: Option<i64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_info_decodes_minimal() {
        let v: ServerInfo = serde_json::from_str(r#"{"name":"mini2","version":"0.6.2"}"#).unwrap();
        assert_eq!(v.name, "mini2");
        assert_eq!(v.version, "0.6.2");
        assert_eq!(v.backend, None);
        assert_eq!(v.ssh_port, None);
    }

    #[test]
    fn server_info_decodes_full() {
        let v: ServerInfo = serde_json::from_str(
            r#"{"name":"mini2","version":"0.6.2","backend":"firecracker","ssh_port":2222,"http_port":8080}"#,
        )
        .unwrap();
        assert_eq!(v.backend.as_deref(), Some("firecracker"));
        assert_eq!(v.ssh_port, Some(2222));
        assert_eq!(v.http_port, Some(8080));
    }
}
