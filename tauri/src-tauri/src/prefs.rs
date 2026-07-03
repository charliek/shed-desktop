//! The app's persisted preferences — currently the terminal preset + custom
//! template that `terminal.open` uses (the in-app Preferences view sets them, the
//! shed-card "Open in Terminal" button reads them). A small JSON file in the app
//! config dir; the mac app uses UserDefaults, this is the windowed-app analog.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use shed_core::terminal::TerminalPreset;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Prefs {
    #[serde(default)]
    pub terminal_preset: TerminalPreset,
    /// Used only when `terminal_preset == Custom` (`{cmd}`/`{shed}` template).
    #[serde(default)]
    pub terminal_template: String,
}

/// Owns the prefs file path + the in-memory copy; writes through on every set.
pub struct PrefsStore {
    path: PathBuf,
    inner: Mutex<Prefs>,
}

impl PrefsStore {
    /// Load from `path` (a `prefs.json` in the app config dir), defaulting when
    /// absent or unreadable (a corrupt file is not fatal — the app still runs).
    pub fn load(path: PathBuf) -> Self {
        let inner = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        Self {
            path,
            inner: Mutex::new(inner),
        }
    }

    pub fn get(&self) -> Prefs {
        self.inner.lock().map(|p| p.clone()).unwrap_or_default()
    }

    /// Set the terminal preset (+ optional custom template) and persist.
    pub fn set_terminal(&self, preset: TerminalPreset, template: Option<String>) {
        if let Ok(mut prefs) = self.inner.lock() {
            prefs.terminal_preset = preset;
            if let Some(template) = template {
                prefs.terminal_template = template;
            }
            self.save(&prefs);
        }
    }

    fn save(&self, prefs: &Prefs) {
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_string_pretty(prefs) {
            let _ = std::fs::write(&self.path, json);
        }
    }
}

pub type SharedPrefs = Arc<PrefsStore>;
