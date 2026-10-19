//! HTTP and file input for imports: playlists, guides and Xtream JSON.

use std::fs::File;
use std::io::{self, BufReader, Read, Write};
use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;

pub const DEFAULT_USER_AGENT: &str = concat!("CAT/", env!("CARGO_PKG_VERSION"), " libmpv");

pub fn agent(user_agent: Option<&str>) -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_connect(Some(Duration::from_secs(20)))
        .timeout_recv_response(Some(Duration::from_secs(60)))
        .user_agent(user_agent.filter(|s| !s.is_empty()).unwrap_or(DEFAULT_USER_AGENT))
        .build()
        .into()
}

/// Shared agent for small requests (images, Xtream details).
pub fn shared() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| agent(None))
}

pub fn is_local_path(url: &str) -> bool {
    let b = url.as_bytes();
    url.starts_with("file://")
        || url.starts_with('/')
        || url.starts_with("\\\\")
        || (b.len() > 2 && b[0].is_ascii_alphabetic() && b[1] == b':' && (b[2] == b'\\' || b[2] == b'/'))
}

pub fn friendly(e: &ureq::Error, url: &str) -> String {
    let host = url.split("://").nth(1).and_then(|r| r.split(['/', '?']).next()).unwrap_or(url);
    match e {
        ureq::Error::StatusCode(code) => format!("Server returned HTTP {code} for {host}"),
        ureq::Error::Timeout(_) => "The server took too long to respond".into(),
        ureq::Error::HostNotFound => format!("Server not found: {host}"),
        ureq::Error::ConnectionFailed => format!("Could not connect to {host}"),
        ureq::Error::Io(e) => format!("Network error: {e}"),
        ureq::Error::Tls(_) | ureq::Error::Rustls(_) => "Secure connection failed (TLS)".into(),
        e => format!("Network error: {e}"),
    }
}

/// Body of `url` (http(s) or a local file), with its size when known.
/// Gzip files (`.xml.gz`) are decompressed transparently.
pub fn open(
    agent: &ureq::Agent,
    url: &str,
    headers: &[(String, String)],
) -> Result<(Box<dyn Read + Send>, Option<u64>), String> {
    let (raw, total): (Box<dyn Read + Send>, Option<u64>) = if is_local_path(url) {
        let path = url.strip_prefix("file://").unwrap_or(url);
        let f = File::open(path).map_err(|e| format!("Cannot open {path}: {e}"))?;
        let len = f.metadata().ok().map(|m| m.len());
        (Box::new(f), len)
    } else {
        let mut req = agent.get(url);
        for (k, v) in headers {
            req = req.header(k.as_str(), v.as_str());
        }
        let resp = req.call().map_err(|e| friendly(&e, url))?;
        let len = resp.headers().get("content-length").and_then(|v| v.to_str().ok()?.parse().ok());
        (Box::new(resp.into_body().into_with_config().limit(u64::MAX).reader()), len)
    };
    Ok((maybe_gunzip(raw), total))
}

/// Counts bytes read through it.
pub struct Counted<R> {
    pub inner: R,
    pub read: u64,
}

impl<R: Read> Read for Counted<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.read += n as u64;
        Ok(n)
    }
}

/// Peeks at the first two bytes and decompresses gzip.
fn maybe_gunzip(mut r: Box<dyn Read + Send>) -> Box<dyn Read + Send> {
    let mut head = [0u8; 2];
    let mut n = 0;
    while n < 2 {
        match r.read(&mut head[n..]) {
            Ok(0) | Err(_) => break,
            Ok(k) => n += k,
        }
    }
    let chained = io::Cursor::new(head[..n].to_vec()).chain(r);
    if n == 2 && head == [0x1f, 0x8b] {
        Box::new(flate2::read::MultiGzDecoder::new(BufReader::new(chained)))
    } else {
        Box::new(chained)
    }
}

/// Streams `url` into `target`, reporting (bytes, total).
pub fn download_to_file(
    agent: &ureq::Agent,
    url: &str,
    target: &Path,
    mut progress: impl FnMut(u64, Option<u64>),
) -> Result<u64, String> {
    let (mut r, total) = open(agent, url, &[])?;
    let mut f = File::create(target).map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; 256 * 1024];
    let mut n = 0u64;
    loop {
        let k = r.read(&mut buf).map_err(|e| format!("Download failed: {e}"))?;
        if k == 0 {
            break;
        }
        f.write_all(&buf[..k]).map_err(|e| e.to_string())?;
        n += k as u64;
        progress(n, total);
    }
    Ok(n)
}

/// GET + JSON decode (Xtream lists can be tens of MB).
pub fn get_json(agent: &ureq::Agent, url: &str) -> Result<serde_json::Value, String> {
    let (mut r, _) = open(agent, url, &[])?;
    let mut bytes = Vec::new();
    r.read_to_end(&mut bytes).map_err(|e| format!("Download failed: {e}"))?;
    let start = bytes.iter().position(|b| !b.is_ascii_whitespace()).unwrap_or(bytes.len());
    let body = &bytes[start..];
    if body.is_empty() {
        return Ok(serde_json::Value::Null);
    }
    if body[0] != b'{' && body[0] != b'[' {
        return Err("Server did not return JSON (check the URL)".into());
    }
    serde_json::from_slice(body).map_err(|e| format!("Invalid data from server: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_paths() {
        assert!(is_local_path("/home/a.m3u"));
        assert!(is_local_path("C:\\list.m3u"));
        assert!(is_local_path("file:///tmp/x"));
        assert!(!is_local_path("http://x/a.m3u"));
    }

    #[test]
    fn gunzips_by_magic() {
        let mut enc = flate2::write::GzEncoder::new(Vec::new(), Default::default());
        enc.write_all(b"<tv></tv>").unwrap();
        let gz = enc.finish().unwrap();
        let mut out = String::new();
        maybe_gunzip(Box::new(io::Cursor::new(gz))).read_to_string(&mut out).unwrap();
        assert_eq!(out, "<tv></tv>");
        out.clear();
        maybe_gunzip(Box::new(io::Cursor::new(b"plain".to_vec()))).read_to_string(&mut out).unwrap();
        assert_eq!(out, "plain");
    }
}
