//! User preferences, stored as one JSON blob in the `settings` table (same
//! keys as the Flutter app).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub hardware_decoding: bool,
    pub cache_seconds: i64,
    /// `ts` or `m3u8`.
    pub live_format: String,
    pub user_agent: String,
    pub epg_past_hours: i64,
    pub epg_future_days: i64,
    /// 0 = off.
    pub auto_refresh_hours: i64,
    /// 0 = off.
    pub epg_refresh_hours: i64,
    pub epg_offset_minutes: i64,
    pub volume: f64,
    pub active_source_id: Option<i64>,
    pub last_channel_key: Option<String>,
    pub autoplay_last_channel: bool,
    /// How video fills the player: `fit`, `fill` (crop) or `stretch`.
    pub video_fit: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            hardware_decoding: true,
            cache_seconds: 20,
            live_format: "ts".into(),
            user_agent: String::new(),
            epg_past_hours: 24,
            epg_future_days: 3,
            auto_refresh_hours: 24,
            epg_refresh_hours: 12,
            epg_offset_minutes: 0,
            volume: 100.0,
            active_source_id: None,
            last_channel_key: None,
            autoplay_last_channel: false,
            video_fit: "fit".into(),
        }
    }
}

impl Settings {
    pub fn decode(json: Option<&str>) -> Self {
        json.and_then(|s| serde_json::from_str(s).ok()).unwrap_or_default()
    }

    pub fn encode(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_flutter_settings() {
        let s = Settings::decode(Some(r#"{"hardwareDecoding":false,"volume":55,"activeSourceId":3,"unknown":1}"#));
        assert!(!s.hardware_decoding);
        assert_eq!(s.volume, 55.0);
        assert_eq!(s.active_source_id, Some(3));
        assert_eq!(s.cache_seconds, 20);
        assert_eq!(Settings::decode(Some("garbage")), Settings::default());
    }
}
