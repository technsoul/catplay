//! Where CAT keeps its files. These are the same folders the Flutter app
//! used, so an existing install keeps its playlists, favorites and history.

use std::path::PathBuf;

pub struct Paths {
    pub support: PathBuf,
    pub database: PathBuf,
    pub epg_dir: PathBuf,
    pub import_temp: PathBuf,
    pub image_cache: PathBuf,
    pub logs: PathBuf,
}

fn app_folder() -> PathBuf {
    if cfg!(windows) {
        PathBuf::from("IPTV Player").join("IPTV Player")
    } else if cfg!(target_os = "macos") {
        PathBuf::from("com.iptvplayer.iptvPlayer")
    } else {
        PathBuf::from("com.iptvplayer.iptv_player")
    }
}

impl Paths {
    pub fn new() -> Self {
        let support = dirs::data_dir().unwrap_or_else(|| PathBuf::from(".")).join(app_folder());
        let cache = dirs::cache_dir().unwrap_or_else(std::env::temp_dir).join(app_folder());
        Self {
            database: support.join("iptv.db"),
            epg_dir: support.join("epg"),
            logs: support.join("logs"),
            import_temp: std::env::temp_dir().join("iptv_import"),
            image_cache: cache.join("images"),
            support,
        }
    }

    pub fn create(&self) -> std::io::Result<()> {
        for d in [&self.support, &self.epg_dir, &self.logs, &self.image_cache] {
            std::fs::create_dir_all(d)?;
        }
        Ok(())
    }
}
