//! Streaming XMLTV scanner working directly on UTF-8 bytes.
//!
//! XMLTV is a flat list of `<channel>` and `<programme>` elements, so instead
//! of a general XML parser this scans for those elements and decodes only the
//! fields that are stored. Programmes outside the time window are rejected
//! from their start tag alone. Only the unfinished tail of the input is kept.

use memchr::{memchr, memmem};
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq)]
pub struct XmltvProgramme {
    pub channel: String,
    pub start: i64,
    pub stop: i64,
    pub title: String,
    pub description: Option<String>,
    pub category: Option<String>,
}

/// Elements larger than this are treated as malformed and skipped.
const MAX_ELEMENT: usize = 4 * 1024 * 1024;

pub struct XmltvParser {
    pub window_start: i64,
    pub window_end: i64,
    /// XMLTV channel id -> display names (for matching channels by name).
    pub channel_names: HashMap<String, Vec<String>>,
    pub programmes: usize,
    pub skipped: usize,
    buf: Vec<u8>,
}

enum Step {
    /// Continue scanning at this index.
    Next(usize),
    /// The element at this index needs more input.
    NeedMore,
}

impl XmltvParser {
    pub fn new(window_start: i64, window_end: i64) -> Self {
        Self { window_start, window_end, channel_names: HashMap::new(), programmes: 0, skipped: 0, buf: Vec::new() }
    }

    /// Feeds a chunk; calls `on` for every programme inside the window.
    pub fn add(&mut self, chunk: &[u8], on: &mut impl FnMut(XmltvProgramme)) {
        self.buf.extend_from_slice(chunk);
        let consumed = self.scan(on);
        self.buf.drain(..consumed);
    }

    pub fn finish(&mut self, on: &mut impl FnMut(XmltvProgramme)) {
        self.scan(on);
        self.buf = Vec::new();
    }

    /// Scans complete elements; returns how many bytes can be dropped.
    fn scan(&mut self, on: &mut impl FnMut(XmltvProgramme)) -> usize {
        let buf = std::mem::take(&mut self.buf);
        let b = &buf[..];
        let mut pos = 0;
        while pos < b.len() {
            let Some(off) = memchr(b'<', &b[pos..]) else {
                pos = b.len();
                break;
            };
            let lt = pos + off;
            // Need "<programme" plus the following byte to classify the tag.
            if lt + 11 > b.len() {
                pos = lt;
                break;
            }
            let step = if b[lt + 1..].starts_with(b"programme") && is_boundary(b[lt + 10]) {
                self.element(b, lt, 10, b"</programme>", true, on)
            } else if b[lt + 1..].starts_with(b"channel") && is_boundary(b[lt + 8]) {
                self.element(b, lt, 8, b"</channel>", false, on)
            } else {
                Step::Next(lt + 1)
            };
            match step {
                Step::Next(n) => pos = n,
                Step::NeedMore => {
                    if b.len() - lt > MAX_ELEMENT {
                        self.skipped += 1;
                        pos = lt + 1;
                    } else {
                        pos = lt;
                        break;
                    }
                }
            }
        }
        self.buf = buf;
        pos
    }

    fn element(
        &mut self,
        b: &[u8],
        lt: usize,
        name_len: usize,
        close: &[u8],
        is_programme: bool,
        on: &mut impl FnMut(XmltvProgramme),
    ) -> Step {
        let Some(tag_end) = find_byte(b, b'>', lt + name_len, b.len()) else { return Step::NeedMore };
        let self_closing = b[tag_end - 1] == b'/';
        let attrs = &b[lt + name_len..if self_closing { tag_end - 1 } else { tag_end }];
        let body_and_after = |from: usize| -> Option<(usize, usize)> {
            if self_closing {
                return Some((tag_end + 1, tag_end + 1));
            }
            let end = from + memmem::find(&b[from..], close)?;
            Some((end, end + close.len()))
        };

        if is_programme {
            let start = time_attr(attrs, b"start");
            let skip = |me: &mut Self| match body_and_after(tag_end + 1) {
                Some((_, after)) => {
                    me.skipped += 1;
                    Step::Next(after)
                }
                None => Step::NeedMore,
            };
            let Some(start) = start.filter(|s| *s <= self.window_end) else { return skip(self) };
            let stop = time_attr(attrs, b"stop").filter(|s| *s > start).unwrap_or(start + 3600);
            if stop < self.window_start {
                return skip(self);
            }
            let Some(ch) = attr_range(attrs, b"channel") else { return skip(self) };
            let Some((body_end, after)) = body_and_after(tag_end + 1) else { return Step::NeedMore };
            let body = &b[tag_end + 1..body_end.max(tag_end + 1)];
            let title = child_text(body, b"title").filter(|t| !t.is_empty());
            self.programmes += 1;
            on(XmltvProgramme {
                channel: decode_entities(&String::from_utf8_lossy(&attrs[ch.0..ch.1])),
                start,
                stop,
                title: title.unwrap_or_else(|| "No title".into()),
                description: child_text(body, b"desc").filter(|t| !t.is_empty()),
                category: child_text(body, b"category").filter(|t| !t.is_empty()),
            });
            return Step::Next(after);
        }

        // <channel>
        if self_closing {
            return Step::Next(tag_end + 1);
        }
        let Some((end, after)) = body_and_after(tag_end + 1) else { return Step::NeedMore };
        if let Some(id) = attr_range(attrs, b"id") {
            let mut names = vec![];
            let mut body = &b[tag_end + 1..end];
            while let Some((s, e, next)) = child_range(body, b"display-name") {
                let name = decode_text(&body[s..e]);
                if !name.is_empty() {
                    names.push(name);
                }
                body = &body[next..];
            }
            if !names.is_empty() {
                let id = decode_entities(&String::from_utf8_lossy(&attrs[id.0..id.1]));
                self.channel_names.entry(id).or_default().extend(names);
            }
        }
        Step::Next(after)
    }
}

fn is_boundary(c: u8) -> bool {
    matches!(c, b' ' | b'>' | b'/' | b'\t' | b'\n' | b'\r')
}

fn is_space(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'\r')
}

fn find_byte(b: &[u8], byte: u8, from: usize, to: usize) -> Option<usize> {
    memchr(byte, &b[from..to]).map(|i| i + from)
}

/// Value range of attribute `name` within the attribute bytes.
fn attr_range(a: &[u8], name: &[u8]) -> Option<(usize, usize)> {
    let mut i = 0;
    loop {
        i += memmem::find(&a[i..], name)?;
        let before = if i == 0 { b' ' } else { a[i - 1] };
        let mut j = i + name.len();
        while j < a.len() && is_space(a[j]) {
            j += 1;
        }
        if is_space(before) && j < a.len() && a[j] == b'=' {
            j += 1;
            while j < a.len() && is_space(a[j]) {
                j += 1;
            }
            if j >= a.len() {
                return None;
            }
            let q = a[j];
            if q == b'"' || q == b'\'' {
                let e = find_byte(a, q, j + 1, a.len())?;
                return Some((j + 1, e));
            }
            let mut e = j;
            while e < a.len() && !is_space(a[e]) {
                e += 1;
            }
            return Some((j, e));
        }
        i += name.len();
    }
}

fn time_attr(a: &[u8], name: &[u8]) -> Option<i64> {
    let (s, e) = attr_range(a, name)?;
    parse_xmltv_time(&a[s..e])
}

/// Finds `<tag ...>text</tag>`; returns (text start, text end, index after).
fn child_range(b: &[u8], tag: &[u8]) -> Option<(usize, usize, usize)> {
    let tl = tag.len();
    let mut i = 0;
    loop {
        i += memchr(b'<', &b[i..])?;
        if i + tl + 1 >= b.len() {
            return None;
        }
        if &b[i + 1..i + 1 + tl] == tag && is_boundary(b[i + 1 + tl]) {
            break;
        }
        i += 1;
    }
    let gt = find_byte(b, b'>', i, b.len())?;
    if b[gt - 1] == b'/' {
        return Some((gt + 1, gt + 1, gt + 1));
    }
    let mut j = gt + 1;
    loop {
        j += memchr(b'<', &b[j..])?;
        if j + 2 + tl < b.len() && b[j + 1] == b'/' && &b[j + 2..j + 2 + tl] == tag && b[j + 2 + tl] == b'>' {
            return Some((gt + 1, j, j + 3 + tl));
        }
        j += 1;
    }
}

fn child_text(b: &[u8], tag: &[u8]) -> Option<String> {
    let (s, e, _) = child_range(b, tag)?;
    Some(decode_text(&b[s..e]))
}

fn decode_text(b: &[u8]) -> String {
    if b.is_empty() {
        return String::new();
    }
    let text = String::from_utf8_lossy(b);
    if !text.contains("<![CDATA[") {
        return decode_entities(&text).trim().to_string();
    }
    let mut out = String::new();
    let mut rest: &str = &text;
    loop {
        let Some(cs) = rest.find("<![CDATA[") else {
            out.push_str(&decode_entities(rest));
            break;
        };
        out.push_str(&decode_entities(&rest[..cs]));
        let inner = &rest[cs + 9..];
        match inner.find("]]>") {
            Some(ce) => {
                out.push_str(&inner[..ce]);
                rest = &inner[ce + 3..];
            }
            None => {
                out.push_str(inner);
                break;
            }
        }
    }
    out.trim().to_string()
}

/// Decodes the five XML entities and numeric character references.
pub fn decode_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        let after = &rest[amp + 1..];
        let rep = after.find(';').filter(|&semi| semi <= 9).and_then(|semi| {
            let ent = &after[..semi];
            let ch = match ent {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                _ => ent.strip_prefix('#').and_then(|n| {
                    let code = match n.strip_prefix(['x', 'X']) {
                        Some(hex) => u32::from_str_radix(hex, 16).ok(),
                        None => n.parse().ok(),
                    };
                    code.filter(|c| *c > 0).and_then(char::from_u32)
                }),
            };
            ch.map(|c| (c, semi))
        });
        match rep {
            Some((c, semi)) => {
                out.push(c);
                rest = &after[semi + 1..];
            }
            None => {
                out.push('&');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// Parses XMLTV time `YYYYMMDDhhmm[ss][ ±hhmm]` into unix seconds (UTC).
pub fn parse_xmltv_time(b: &[u8]) -> Option<i64> {
    let mut s = 0;
    while s < b.len() && is_space(b[s]) {
        s += 1;
    }
    let b = &b[s..];
    if b.len() < 12 {
        return None;
    }
    let d = |at: usize, n: usize| -> Option<i64> {
        b.get(at..at + n)?.iter().try_fold(0i64, |v, c| c.is_ascii_digit().then(|| v * 10 + (c - b'0') as i64))
    };
    let (year, month, day, hour, minute) = (d(0, 4)?, d(4, 2)?, d(6, 2)?, d(8, 2)?, d(10, 2)?);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || minute > 59 {
        return None;
    }
    let mut i = 12;
    let mut second = 0;
    if let Some(sec) = d(12, 2) {
        second = sec;
        i = 14;
    }
    while i < b.len() && is_space(b[i]) {
        i += 1;
    }
    let mut offset = 0;
    if b.len() - i >= 5 && (b[i] == b'+' || b[i] == b'-')
        && let (Some(oh), Some(om)) = (d(i + 1, 2), d(i + 3, 2))
    {
        offset = (oh * 3600 + om * 60) * if b[i] == b'-' { -1 } else { 1 };
    }
    Some(days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset)
}

/// Days since 1970-01-01 (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// "UK: BBC One HD" -> "bbcone"
pub fn normalize_channel_name(s: &str) -> String {
    let mut v = s.trim().to_lowercase();
    // Country prefix like "uk:", "ar |", "fr -".
    let b = v.as_bytes();
    let letters = b.iter().take_while(|c| c.is_ascii_lowercase()).count();
    if (2..=3).contains(&letters) {
        let mut j = letters;
        while j < b.len() && b[j] == b' ' {
            j += 1;
        }
        if j < b.len() && matches!(b[j], b':' | b'|' | b'-') {
            j += 1;
            while j < b.len() && b[j] == b' ' {
                j += 1;
            }
            v = v[j..].to_string();
        }
    }
    let words: Vec<&str> = v
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty() && !is_quality_tag(w))
        .collect();
    words.concat()
}

fn is_quality_tag(w: &str) -> bool {
    matches!(w, "hd" | "fhd" | "uhd" | "4k" | "sd" | "hevc" | "h265")
        || (w.ends_with('p') && (4..=5).contains(&w.len()) && w[..w.len() - 1].bytes().all(|c| c.is_ascii_digit()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const GUIDE: &str = r#"<?xml version="1.0"?><tv>
<channel id="bbc1.uk"><display-name>BBC One</display-name><display-name lang="en">BBC 1 &amp; Co</display-name></channel>
<programme start="20240101120000 +0100" stop="20240101130000 +0100" channel="bbc1.uk"><title lang="en">News &amp; Weather</title><desc><![CDATA[Daily <b>news</b>]]></desc><category>News</category></programme>
<programme start="20230101120000 +0000" stop="20230101130000 +0000" channel="bbc1.uk"><title>Old</title></programme>
<programme start="20240101130000 +0000" channel="bbc1.uk"><title></title></programme>
</tv>"#;

    fn run(chunk: usize) -> (Vec<XmltvProgramme>, XmltvParser) {
        let start = parse_xmltv_time(b"20231231000000 +0000").unwrap();
        let mut p = XmltvParser::new(start, start + 7 * 86_400);
        let mut out = vec![];
        for c in GUIDE.as_bytes().chunks(chunk) {
            p.add(c, &mut |x| out.push(x));
        }
        p.finish(&mut |x| out.push(x));
        (out, p)
    }

    #[test]
    fn parses_in_any_chunk_size() {
        for chunk in [1, 7, 64, 100_000] {
            let (out, p) = run(chunk);
            assert_eq!(out.len(), 2, "chunk {chunk}");
            assert_eq!(out[0].title, "News & Weather");
            assert_eq!(out[0].start, parse_xmltv_time(b"20240101110000").unwrap());
            assert_eq!(out[0].stop - out[0].start, 3600);
            assert_eq!(out[0].description.as_deref(), Some("Daily <b>news</b>"));
            assert_eq!(out[0].category.as_deref(), Some("News"));
            assert_eq!(out[1].title, "No title");
            assert_eq!(out[1].stop - out[1].start, 3600);
            assert_eq!(p.skipped, 1);
            assert_eq!(p.channel_names["bbc1.uk"], ["BBC One", "BBC 1 & Co"]);
        }
    }

    #[test]
    fn times_and_entities() {
        assert_eq!(parse_xmltv_time(b"19700101000000 +0000"), Some(0));
        assert_eq!(parse_xmltv_time(b"197001010100"), Some(3600));
        assert_eq!(parse_xmltv_time(b"197001010100 -0100"), Some(7200));
        assert_eq!(parse_xmltv_time(b"20241301000000"), None);
        assert_eq!(decode_entities("a&#65;&#x42;&bogus;&lt;"), "aAB&bogus;<");
    }

    #[test]
    fn normalizes_names() {
        assert_eq!(normalize_channel_name("UK: BBC One HD"), "bbcone");
        assert_eq!(normalize_channel_name("AR | MBC 1 1080p"), "mbc1");
        assert_eq!(normalize_channel_name("CNN"), "cnn");
    }
}
