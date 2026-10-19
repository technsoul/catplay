//! Data types shared by the database, importers, player and UI. They mirror
//! the Flutter app's models so both apps read the same database.

use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ItemKind {
    #[default]
    Live = 0,
    Movie = 1,
    Series = 2,
}

impl ItemKind {
    pub const ALL: [ItemKind; 3] = [ItemKind::Live, ItemKind::Movie, ItemKind::Series];

    pub fn from_i64(v: i64) -> Self {
        match v {
            1 => Self::Movie,
            2 => Self::Series,
            _ => Self::Live,
        }
    }

    pub fn index(self) -> i64 {
        self as i64
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceType {
    M3uUrl,
    M3uFile,
    Xtream,
}

impl SourceType {
    pub fn id(self) -> &'static str {
        match self {
            Self::M3uUrl => "m3u_url",
            Self::M3uFile => "m3u_file",
            Self::Xtream => "xtream",
        }
    }

    pub fn parse(v: &str) -> Self {
        match v {
            "m3u_file" => Self::M3uFile,
            "xtream" => Self::Xtream,
            _ => Self::M3uUrl,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::M3uUrl => "M3U link",
            Self::M3uFile => "M3U file",
            Self::Xtream => "Xtream Codes",
        }
    }
}

/// A playlist.
#[derive(Debug, Clone)]
pub struct Source {
    pub id: i64,
    pub name: String,
    pub kind: SourceType,
    /// Playlist URL, file path or Xtream server.
    pub url: String,
    pub username: Option<String>,
    pub epg_url: Option<String>,
    pub user_agent: Option<String>,
    pub last_refresh: Option<i64>,
    pub last_epg: Option<i64>,
    pub status: String,
    pub error: Option<String>,
    pub live_count: i64,
    pub movie_count: i64,
    pub series_count: i64,
    pub expires_at: Option<i64>,
    pub max_connections: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct Category {
    pub id: i64,
    pub name: String,
    pub item_count: i64,
}

/// A live channel, a movie or a series.
#[derive(Debug, Clone)]
#[allow(dead_code)] // Every column is loaded; not all are shown yet.
pub struct MediaItem {
    pub id: i64,
    pub source_id: i64,
    pub kind: ItemKind,
    pub key: String,
    pub name: String,
    pub category_id: Option<i64>,
    pub logo: Option<String>,
    /// None for series (episodes are fetched on demand).
    pub url: Option<String>,
    pub epg_id: Option<String>,
    pub number: Option<i64>,
    pub ext_id: Option<String>,
    pub container: Option<String>,
    pub rating: Option<f64>,
    pub year: Option<String>,
    pub catchup_days: Option<i64>,
    pub headers: BTreeMap<String, String>,
    pub favorite: bool,
}

pub fn decode_headers(json: Option<&str>) -> BTreeMap<String, String> {
    json.filter(|s| !s.is_empty())
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default()
}

#[derive(Debug, Clone)]
pub struct Programme {
    pub channel: String,
    /// Unix seconds, UTC.
    pub start: i64,
    pub stop: i64,
    pub title: String,
    pub description: Option<String>,
    pub category: Option<String>,
}

impl Programme {
    pub fn is_live_at(&self, t: i64) -> bool {
        self.start <= t && t < self.stop
    }

    pub fn progress_at(&self, t: i64) -> f32 {
        let total = self.stop - self.start;
        if total <= 0 {
            return 0.0;
        }
        ((t - self.start) as f32 / total as f32).clamp(0.0, 1.0)
    }
}

#[derive(Debug, Clone)]
pub struct HistoryEntry {
    pub source_id: i64,
    pub key: String,
    pub kind: ItemKind,
    pub name: String,
    pub logo: Option<String>,
    pub url: String,
    pub position_ms: i64,
    pub duration_ms: i64,
}

impl HistoryEntry {
    pub fn progress(&self) -> f32 {
        if self.duration_ms <= 0 {
            return 0.0;
        }
        (self.position_ms as f32 / self.duration_ms as f32).clamp(0.0, 1.0)
    }
}

/// Something the player can open: a channel, a movie or an episode.
#[derive(Debug, Clone, PartialEq)]
pub struct Playable {
    pub source_id: i64,
    pub key: String,
    pub kind: ItemKind,
    pub title: String,
    pub subtitle: Option<String>,
    pub url: String,
    pub logo: Option<String>,
    pub headers: BTreeMap<String, String>,
    pub epg_id: Option<String>,
    /// Days of catch-up the channel offers (live only).
    pub catchup_days: Option<i64>,
    /// Where to resume, in milliseconds.
    pub resume_ms: Option<i64>,
}

impl Playable {
    pub fn is_live(&self) -> bool {
        self.kind == ItemKind::Live
    }
}

/// Series episode, from Xtream `get_series_info`.
#[derive(Debug, Clone)]
pub struct Episode {
    pub id: String,
    pub season: i64,
    pub number: i64,
    pub title: String,
    pub url: String,
    pub plot: Option<String>,
    pub image: Option<String>,
    pub duration: Option<String>,
}
