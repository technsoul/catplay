//! Streaming M3U / M3U8 parser: feed it lines, receive entries one at a time,
//! so memory use does not depend on the playlist size.

use crate::model::ItemKind;
use std::collections::{BTreeMap, HashMap};

#[derive(Debug, Clone, Default)]
pub struct M3uEntry {
    pub name: String,
    pub url: String,
    pub attrs: HashMap<String, String>,
    pub group: Option<String>,
    pub headers: BTreeMap<String, String>,
}

fn non_empty(s: Option<&String>) -> Option<String> {
    s.map(|s| s.trim()).filter(|s| !s.is_empty()).map(String::from)
}

impl M3uEntry {
    pub fn tvg_id(&self) -> Option<String> {
        non_empty(self.attrs.get("tvg-id"))
    }

    pub fn logo(&self) -> Option<String> {
        non_empty(self.attrs.get("tvg-logo")).or_else(|| non_empty(self.attrs.get("logo")))
    }

    pub fn channel_number(&self) -> Option<i64> {
        self.attrs.get("tvg-chno").or_else(|| self.attrs.get("channel-number"))?.trim().parse().ok()
    }

    pub fn catchup_days(&self) -> Option<i64> {
        self.attrs.get("catchup-days").or_else(|| self.attrs.get("timeshift"))?.trim().parse().ok()
    }

    /// Live, movie or series, guessed from Xtream-style URLs and group names.
    pub fn kind(&self) -> ItemKind {
        let u = self.url.to_lowercase();
        if u.contains("/movie/") {
            return ItemKind::Movie;
        }
        if u.contains("/series/") {
            return ItemKind::Series;
        }
        let g = self.group.as_deref().unwrap_or("").to_lowercase();
        if is_vod_ext(&u) && !u.contains("/live/") {
            if g.contains("series") || looks_like_episode(&self.name) {
                return ItemKind::Series;
            }
            return ItemKind::Movie;
        }
        ItemKind::Live
    }
}

fn is_vod_ext(u: &str) -> bool {
    let path = u.split('?').next().unwrap_or(u);
    [".mp4", ".mkv", ".avi", ".mov", ".wmv", ".m4v", ".webm"].iter().any(|e| path.ends_with(e))
}

/// Matches `S01E02` / `s1 e2` as a word.
fn looks_like_episode(name: &str) -> bool {
    let b = name.as_bytes();
    for i in 0..b.len() {
        if !(b[i] == b'S' || b[i] == b's') || (i > 0 && b[i - 1].is_ascii_alphanumeric()) {
            continue;
        }
        let mut j = i + 1;
        let digits = |j: &mut usize, max: usize| {
            let s = *j;
            while *j < b.len() && b[*j].is_ascii_digit() && *j - s < max {
                *j += 1;
            }
            *j > s
        };
        if !digits(&mut j, 2) {
            continue;
        }
        if j < b.len() && b[j] == b' ' {
            j += 1;
        }
        if j >= b.len() || !(b[j] == b'E' || b[j] == b'e') {
            continue;
        }
        j += 1;
        if digits(&mut j, 3) && (j >= b.len() || !b[j].is_ascii_alphanumeric()) {
            return true;
        }
    }
    false
}

fn starts_with_ci(s: &str, prefix: &str) -> bool {
    s.len() >= prefix.len() && s.as_bytes()[..prefix.len()].eq_ignore_ascii_case(prefix.as_bytes())
}

#[derive(Default)]
pub struct M3uParser {
    /// `url-tvg` / `x-tvg-url` from the `#EXTM3U` header.
    pub epg_url: Option<String>,
    pub count: usize,
    pending_info: Option<String>,
    pending_group: Option<String>,
    pending_headers: BTreeMap<String, String>,
    first: bool,
}

impl M3uParser {
    pub fn new() -> Self {
        Self { first: true, ..Default::default() }
    }

    pub fn add_line(&mut self, raw: &str) -> Option<M3uEntry> {
        let mut line = raw;
        if self.first {
            self.first = false;
            line = line.strip_prefix('\u{feff}').unwrap_or(line);
        }
        let line = line.trim();
        if line.is_empty() {
            return None;
        }
        if line.starts_with('#') {
            if starts_with_ci(line, "#EXTINF") {
                self.pending_info = Some(line.to_string());
                self.pending_group = None;
                self.pending_headers.clear();
            } else if starts_with_ci(line, "#EXTGRP:") {
                self.pending_group = Some(line[8..].trim().to_string());
            } else if starts_with_ci(line, "#EXTVLCOPT:") {
                self.add_option(&line[11..]);
            } else if starts_with_ci(line, "#KODIPROP:") {
                self.add_option(&line[10..]);
            } else if starts_with_ci(line, "#EXTM3U") {
                let attrs = parse_attributes(&line[7..]);
                self.epg_url = non_empty(attrs.get("url-tvg"))
                    .or_else(|| non_empty(attrs.get("x-tvg-url")))
                    .map(|u| u.split(',').next().unwrap_or("").trim().to_string());
            }
            return None;
        }
        // A URL line.
        let entry = match self.pending_info.take() {
            None => M3uEntry { name: name_from_url(line), url: line.to_string(), ..Default::default() },
            Some(info) => self.build_entry(&info, line),
        };
        self.pending_group = None;
        self.pending_headers.clear();
        self.count += 1;
        Some(entry)
    }

    fn add_option(&mut self, opt: &str) {
        let Some((k, v)) = opt.split_once('=') else { return };
        let v = v.trim().to_string();
        match k.trim().to_lowercase().as_str() {
            "http-user-agent" => self.pending_headers.insert("User-Agent".into(), v),
            "http-referrer" | "http-referer" => self.pending_headers.insert("Referer".into(), v),
            "http-origin" => self.pending_headers.insert("Origin".into(), v),
            _ => None,
        };
    }

    fn build_entry(&self, info: &str, url: &str) -> M3uEntry {
        // #EXTINF:<duration> <attrs...>,<title>
        let body = info.get(8..).unwrap_or("");
        let dur_end = body.find([' ', ',']).unwrap_or(body.len());
        let rest = &body[dur_end..];
        // Title separator: first comma outside quotes.
        let mut in_quote = false;
        let mut comma = None;
        for (i, ch) in rest.char_indices() {
            match ch {
                '"' => in_quote = !in_quote,
                ',' if !in_quote => {
                    comma = Some(i);
                    break;
                }
                _ => {}
            }
        }
        let attrs = parse_attributes(&rest[..comma.unwrap_or(rest.len())]);
        let mut name = comma.map_or("", |c| rest[c + 1..].trim()).to_string();
        if name.is_empty() {
            name = attrs.get("tvg-name").cloned().unwrap_or_else(|| name_from_url(url));
        }

        let mut headers = self.pending_headers.clone();
        if let Some(ua) = attrs.get("user-agent").or_else(|| attrs.get("http-user-agent")).filter(|s| !s.is_empty()) {
            headers.insert("User-Agent".into(), ua.clone());
        }
        if let Some(r) = attrs.get("http-referrer").or_else(|| attrs.get("referer")).filter(|s| !s.is_empty()) {
            headers.insert("Referer".into(), r.clone());
        }
        // Kodi style "url|User-Agent=...&Referer=...".
        let mut clean = url;
        if let Some((u, opts)) = url.split_once('|') {
            clean = u;
            for part in opts.split('&') {
                if let Some((k, v)) = part.split_once('=').filter(|(k, _)| !k.is_empty()) {
                    headers.insert(k.to_string(), percent_decode(v));
                }
            }
        }
        M3uEntry {
            name,
            url: clean.to_string(),
            group: non_empty(attrs.get("group-title")).or_else(|| non_empty(self.pending_group.as_ref())),
            attrs,
            headers,
        }
    }
}

/// Parses `key="value"` / `key=value` pairs.
pub fn parse_attributes(s: &str) -> HashMap<String, String> {
    let b = s.as_bytes();
    let end = b.len();
    let mut out = HashMap::new();
    let mut i = 0;
    while i < end {
        while i < end && b[i] == b' ' {
            i += 1;
        }
        let key_start = i;
        while i < end && b[i] != b'=' && b[i] != b' ' {
            i += 1;
        }
        if i >= end || b[i] != b'=' {
            i += 1;
            continue;
        }
        let key = s[key_start..i].to_lowercase();
        i += 1;
        let value;
        if i < end && b[i] == b'"' {
            i += 1;
            let vs = i;
            while i < end && b[i] != b'"' {
                i += 1;
            }
            value = &s[vs..i];
            i += 1;
        } else {
            let vs = i;
            while i < end && b[i] != b' ' {
                i += 1;
            }
            value = &s[vs..i];
        }
        if !key.is_empty() {
            out.insert(key, value.to_string());
        }
    }
    out
}

fn name_from_url(url: &str) -> String {
    let path = url.split(['?', '#']).next().unwrap_or(url);
    let path = path.split_once("://").map_or(path, |(_, p)| p.split_once('/').map_or("", |(_, p)| p));
    path.split('/').rfind(|s| !s.is_empty()).map_or_else(|| url.to_string(), percent_decode)
}

pub fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%'
            && i + 2 < b.len()
            && let Some(v) = std::str::from_utf8(&b[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok())
        {
            out.push(v);
            i += 3;
            continue;
        }
        out.push(if b[i] == b'+' { b' ' } else { b[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> (Vec<M3uEntry>, M3uParser) {
        let mut p = M3uParser::new();
        let entries = text.lines().filter_map(|l| p.add_line(l)).collect();
        (entries, p)
    }

    #[test]
    fn parses_extended_playlist() {
        let (e, p) = parse(
            "\u{feff}#EXTM3U url-tvg=\"http://epg/a.xml,http://b\"\n\
             #EXTINF:-1 tvg-id=\"bbc1\" tvg-logo=\"http://l/bbc.png\" group-title=\"UK, News\" tvg-chno=\"101\",BBC One\n\
             #EXTVLCOPT:http-user-agent=Foo\n\
             http://s/live/u/p/1.ts\n\
             #EXTINF:0,Film (2020)\n\
             http://s/movie/u/p/2.mkv|Referer=http%3A%2F%2Fx\n\
             #EXTINF:-1 group-title=\"Shows\",Show S01E02\n\
             http://s/vod/show.mp4\n\
             http://plain/stream/chan.m3u8\n",
        );
        assert_eq!(p.epg_url.as_deref(), Some("http://epg/a.xml"));
        assert_eq!(e.len(), 4);
        assert_eq!(e[0].name, "BBC One");
        assert_eq!(e[0].group.as_deref(), Some("UK, News"));
        assert_eq!(e[0].tvg_id().as_deref(), Some("bbc1"));
        assert_eq!(e[0].channel_number(), Some(101));
        assert_eq!(e[0].headers.get("User-Agent").map(String::as_str), Some("Foo"));
        assert_eq!(e[0].kind(), ItemKind::Live);
        assert_eq!(e[1].kind(), ItemKind::Movie);
        assert_eq!(e[1].url, "http://s/movie/u/p/2.mkv");
        assert_eq!(e[1].headers.get("Referer").map(String::as_str), Some("http://x"));
        assert!(e[1].headers.get("User-Agent").is_none());
        assert_eq!(e[2].kind(), ItemKind::Series);
        assert_eq!(e[3].name, "chan.m3u8");
    }

    #[test]
    fn episode_detection() {
        assert!(looks_like_episode("Show S01E02"));
        assert!(looks_like_episode("show s1 e10 x"));
        assert!(!looks_like_episode("BS01E02"));
        assert!(!looks_like_episode("Season 1"));
    }
}
