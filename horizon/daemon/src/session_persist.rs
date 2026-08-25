use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const CATALOG_VERSION: i32 = 1;
pub const DEFAULT_ROWS: u16 = 24;
pub const DEFAULT_COLS: u16 = 80;

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionCatalog {
    #[serde(default)]
    pub version: i32,
    #[serde(default)]
    pub sessions: Vec<PersistedSession>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PersistedSession {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default = "default_rows")]
    pub rows: u16,
    #[serde(default = "default_cols")]
    pub cols: u16,
    #[serde(default)]
    pub history_base_offset: usize,
}

fn default_rows() -> u16 {
    DEFAULT_ROWS
}

fn default_cols() -> u16 {
    DEFAULT_COLS
}

impl PersistedSession {
    pub fn from_id(id: String) -> Self {
        Self {
            id,
            cwd: None,
            rows: DEFAULT_ROWS,
            cols: DEFAULT_COLS,
            history_base_offset: 0,
        }
    }
}

pub fn catalog_path(dir: &Path) -> PathBuf {
    dir.join("session_catalog.json")
}

pub fn history_path(dir: &Path, session_id: &str) -> PathBuf {
    dir.join("sessions").join(session_id).join("history")
}

pub fn load_catalog(dir: &Path) -> SessionCatalog {
    let path = catalog_path(dir);
    if !path.exists() {
        return SessionCatalog {
            version: CATALOG_VERSION,
            sessions: Vec::new(),
        };
    }
    match fs::read_to_string(&path) {
        Ok(content) => serde_json::from_str(&content).unwrap_or_default(),
        Err(_) => SessionCatalog::default(),
    }
}

pub fn save_catalog(dir: &Path, catalog: &SessionCatalog) -> io::Result<()> {
    let mut catalog = catalog.clone();
    catalog.version = CATALOG_VERSION;
    let text = serde_json::to_string_pretty(&catalog)
        .map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err))?;
    write_atomic(&catalog_path(dir), text.as_bytes())
}

pub fn write_history(dir: &Path, session_id: &str, bytes: &[u8]) -> io::Result<()> {
    write_atomic(&history_path(dir, session_id), bytes)
}

pub fn read_history(dir: &Path, session_id: &str) -> Option<Vec<u8>> {
    let path = history_path(dir, session_id);
    fs::read(&path).ok()
}

pub fn remove_session_files(dir: &Path, session_id: &str) {
    let history = history_path(dir, session_id);
    let _ = fs::remove_file(&history);
    let _ = fs::remove_file(history.with_extension("tmp"));
    if let Some(parent) = history.parent() {
        let _ = fs::remove_dir(parent);
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, bytes)?;
    if cfg!(windows) {
        let _ = fs::remove_file(path);
    }
    match fs::rename(&tmp, path) {
        Ok(()) => Ok(()),
        Err(err) => {
            let _ = fs::remove_file(&tmp);
            Err(err)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir() -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("horizon-persist-{nanos}"));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn catalog_roundtrip_preserves_cwd_and_offsets() {
        let dir = temp_dir();
        let catalog = SessionCatalog {
            version: CATALOG_VERSION,
            sessions: vec![PersistedSession {
                id: "ABC12345".to_string(),
                cwd: Some("/tmp/project".to_string()),
                rows: 40,
                cols: 120,
                history_base_offset: 4096,
            }],
        };
        save_catalog(&dir, &catalog).unwrap();
        assert_eq!(load_catalog(&dir), catalog);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn missing_catalog_is_empty() {
        let dir = temp_dir();
        let catalog = load_catalog(&dir);
        assert!(catalog.sessions.is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn history_roundtrip_and_remove() {
        let dir = temp_dir();
        let bytes = b"hello\nworld\n";
        write_history(&dir, "SESS0001", bytes).unwrap();
        assert_eq!(read_history(&dir, "SESS0001").as_deref(), Some(&bytes[..]));
        remove_session_files(&dir, "SESS0001");
        assert!(read_history(&dir, "SESS0001").is_none());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn persisted_session_from_id_uses_defaults() {
        let session = PersistedSession::from_id("ZZZZZZZZ".to_string());
        assert_eq!(session.rows, DEFAULT_ROWS);
        assert_eq!(session.cols, DEFAULT_COLS);
        assert_eq!(session.cwd, None);
        assert_eq!(session.history_base_offset, 0);
    }
}
