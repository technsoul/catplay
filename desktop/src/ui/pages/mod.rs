//! The app's pages and the state each keeps between frames.

pub mod guide;
pub mod home;
pub mod live;
pub mod search;
pub mod settings;
pub mod sources;
pub mod vod;

use super::app::App;
use crate::model::{HistoryEntry, ItemKind, MediaItem, Playable, Source, SourceType};
use crate::parse::xtream::Xtream;

#[derive(Default)]
pub struct Pages {
    pub home: home::State,
    pub live: live::State,
    pub guide: guide::State,
    pub movies: vod::State,
    pub series: vod::State,
    pub search: search::State,
    pub sources: sources::State,
}

impl Pages {
    /// Clears per-playlist selections after switching playlists.
    pub fn reset_for_source(&mut self) {
        self.live = live::State::default();
        self.guide = guide::State::default();
        self.movies = vod::State::default();
        self.series = vod::State::default();
    }
}

/// Xtream credentials recovered from a stream URL
/// (`server/live|movie|series/user/pass/id.ext`), so playing catch-up or
/// loading details needs no credential-store lookup.
pub fn xtream_from_url(url: &str) -> Option<(Xtream, String)> {
    let (scheme, rest) = url.split_once("://")?;
    let mut parts = rest.split('/');
    let host = parts.next()?;
    let kind = parts.next()?;
    if !matches!(kind, "live" | "movie" | "series") {
        return None;
    }
    let user = crate::parse::m3u::percent_decode(parts.next()?);
    let pass = crate::parse::m3u::percent_decode(parts.next()?);
    let file = parts.next()?;
    let id = file.split('.').next()?.to_string();
    Some((Xtream::new(&format!("{scheme}://{host}"), &user, &pass), id))
}

/// Xtream client for a playlist, reading its password (call off the UI thread).
pub fn xtream_for(source: &Source) -> Option<Xtream> {
    (source.kind == SourceType::Xtream).then(|| {
        let password = crate::secrets::password(source.id).unwrap_or_default();
        Xtream::new(&source.url, source.username.as_deref().unwrap_or(""), &password)
    })
}

/// Plays an item: live channels play in the Live TV preview, movies open the
/// full-screen player.
pub fn play_item(app: &mut App, item: &MediaItem, zap: Option<(crate::repo::ItemQuery, i64)>, full: bool) {
    if item.kind == ItemKind::Live && !full && app.settings.active_source_id != Some(item.source_id) {
        app.settings.active_source_id = Some(item.source_id);
        app.pages.reset_for_source();
    }
    app.player.open_item(item, None, zap);
    if item.kind == ItemKind::Live && !full {
        app.go(super::app::Section::Live);
        app.pages.live.select_key = Some(item.key.clone());
    } else {
        app.full_player = true;
    }
}

/// Resumes a history entry.
pub fn play_history(app: &mut App, h: &HistoryEntry) {
    if h.kind == ItemKind::Live {
        // Look the channel up so it plays with its guide and catch-up info.
        let (sid, key) = (h.source_id, h.key.clone());
        if app.settings.active_source_id != Some(sid) {
            app.settings.active_source_id = Some(sid);
            app.pages.reset_for_source();
        }
        app.pages.live.autoplay = Some(app.db.read(move |c| crate::repo::item_by_key(c, sid, &key)));
        app.go(super::app::Section::Live);
        return;
    }
    let (title, subtitle) = match h.name.split_once(" · ") {
        Some((s, t)) if h.kind != ItemKind::Live => (t.to_string(), Some(s.to_string())),
        _ => (h.name.clone(), None),
    };
    let p = Playable {
        source_id: h.source_id,
        key: h.key.clone(),
        kind: h.kind,
        title,
        subtitle,
        url: h.url.clone(),
        logo: h.logo.clone(),
        headers: Default::default(),
        epg_id: None,
        catchup_days: None,
        resume_ms: (h.kind != ItemKind::Live && h.position_ms > 0).then_some(h.position_ms),
    };
    app.player.open(p, None);
    app.full_player = true;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credentials_from_stream_urls() {
        let (x, id) = xtream_from_url("http://h.tv:8080/live/us%20er/pw/123.ts").unwrap();
        assert_eq!(id, "123");
        assert_eq!(x.server, "http://h.tv:8080");
        assert_eq!(x.timeshift_url("123", 0, 30), "http://h.tv:8080/timeshift/us%20er/pw/30/1970-01-01:00-00/123.ts");
        assert!(xtream_from_url("http://h/stream/x.m3u8").is_none());
    }
}
