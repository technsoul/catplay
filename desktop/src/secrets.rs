//! Xtream passwords live in the OS credential store (Windows Credential
//! Manager, macOS Keychain, Secret Service on Linux), never in the database.
//! Without a working credential store they fall back to a private file.

use parking_lot::Mutex;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::OnceLock;

const SERVICE: &str = "CAT IPTV";

fn account(source_id: i64) -> String {
    format!("source_password_{source_id}")
}

static FALLBACK: OnceLock<PathBuf> = OnceLock::new();
static LOCK: Mutex<()> = Mutex::new(());

/// Sets where passwords go when there is no credential store.
pub fn init(fallback_file: PathBuf) {
    let _ = FALLBACK.set(fallback_file);
}

fn read_fallback() -> HashMap<String, String> {
    FALLBACK
        .get()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn write_fallback(map: &HashMap<String, String>) {
    let Some(path) = FALLBACK.get() else { return };
    let Ok(json) = serde_json::to_string(map) else { return };
    if std::fs::write(path, json).is_ok() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
        }
    }
}

fn entry(key: &str) -> Option<keyring::Entry> {
    keyring::Entry::new(SERVICE, key).ok()
}

pub fn get(key: &str) -> Option<String> {
    let _g = LOCK.lock();
    if let Some(p) = entry(key).and_then(|e| e.get_password().ok()) {
        return Some(p);
    }
    read_fallback().get(key).cloned()
}

pub fn set(key: &str, value: &str) {
    let _g = LOCK.lock();
    let stored = entry(key).is_some_and(|e| e.set_password(value).is_ok());
    let mut map = read_fallback();
    if stored {
        if map.remove(key).is_some() {
            write_fallback(&map);
        }
    } else {
        log::warn!("no credential store; keeping the secret in a private file");
        map.insert(key.to_string(), value.to_string());
        write_fallback(&map);
    }
}

pub fn remove(key: &str) {
    let _g = LOCK.lock();
    if let Some(e) = entry(key) {
        let _ = e.delete_credential();
    }
    let mut map = read_fallback();
    if map.remove(key).is_some() {
        write_fallback(&map);
    }
}

pub fn password(source_id: i64) -> Option<String> {
    get(&account(source_id))
}

pub fn set_password(source_id: i64, value: &str) {
    set(&account(source_id), value);
}

pub fn delete(source_id: i64) {
    remove(&account(source_id));
}
