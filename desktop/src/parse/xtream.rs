//! Xtream Codes `player_api.php` client.

use crate::http;
use crate::model::Episode;
use serde_json::{Map, Value};

pub struct Xtream {
    pub server: String,
    username: String,
    password: String,
}

pub struct Account {
    pub expires_at: Option<i64>,
    pub max_connections: Option<i64>,
}

pub struct SeriesInfo {
    pub info: Map<String, Value>,
    pub episodes: Vec<Episode>,
}

/// Percent-encodes a URL component.
pub fn encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// "host:8080/player_api.php?..." -> "http://host:8080"
pub fn normalize_server(s: &str) -> String {
    let mut v = s.trim().to_string();
    if !v.starts_with("http://") && !v.starts_with("https://") {
        v = format!("http://{v}");
    }
    let (scheme, rest) = v.split_once("://").unwrap_or(("http", &v));
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    format!("{scheme}://{host}")
}

pub fn int_of(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

pub fn str_of(v: Option<&Value>) -> Option<String> {
    let s = match v? {
        Value::String(s) => s.trim().to_string(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => return None,
    };
    (!s.is_empty() && s != "null").then_some(s)
}

pub fn f64_of(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

impl Xtream {
    pub fn new(server: &str, username: &str, password: &str) -> Self {
        Self { server: normalize_server(server), username: encode(username), password: encode(password) }
    }

    pub fn api_url(&self, action: Option<&str>, extra: &[(&str, &str)]) -> String {
        let mut q = format!("{}/player_api.php?username={}&password={}", self.server, self.username, self.password);
        if let Some(a) = action {
            q.push_str(&format!("&action={a}"));
        }
        for (k, v) in extra {
            q.push_str(&format!("&{k}={}", encode(v)));
        }
        q
    }

    pub fn epg_url(&self) -> String {
        format!("{}/xmltv.php?username={}&password={}", self.server, self.username, self.password)
    }

    pub fn live_url(&self, id: &str, ext: &str) -> String {
        format!("{}/live/{}/{}/{id}.{ext}", self.server, self.username, self.password)
    }

    pub fn movie_url(&self, id: &str, ext: &str) -> String {
        format!("{}/movie/{}/{}/{id}.{ext}", self.server, self.username, self.password)
    }

    pub fn episode_url(&self, id: &str, ext: &str) -> String {
        format!("{}/series/{}/{}/{id}.{ext}", self.server, self.username, self.password)
    }

    /// Catch-up URL for a past programme (`start` in unix seconds).
    pub fn timeshift_url(&self, stream_id: &str, start: i64, minutes: i64) -> String {
        let t = chrono::DateTime::from_timestamp(start, 0).unwrap_or_default().format("%Y-%m-%d:%H-%M");
        format!("{}/timeshift/{}/{}/{minutes}/{t}/{stream_id}.ts", self.server, self.username, self.password)
    }

    fn get(&self, agent: &ureq::Agent, url: &str) -> Result<Value, String> {
        http::get_json(agent, url)
    }

    pub fn authenticate(&self, agent: &ureq::Agent) -> Result<Account, String> {
        let json = self.get(agent, &self.api_url(None, &[]))?;
        let info = json.get("user_info").filter(|v| v.is_object()).ok_or("Unexpected server response")?;
        if str_of(info.get("auth")).as_deref() != Some("1") {
            return Err("Login failed: wrong username or password".into());
        }
        let status = str_of(info.get("status")).unwrap_or_default();
        if !status.is_empty() && !status.eq_ignore_ascii_case("active") {
            return Err(format!("Account is {status}"));
        }
        Ok(Account { expires_at: int_of(info.get("exp_date")), max_connections: int_of(info.get("max_connections")) })
    }

    pub fn list(&self, agent: &ureq::Agent, action: &str) -> Result<Vec<Map<String, Value>>, String> {
        Ok(match self.get(agent, &self.api_url(Some(action), &[]))? {
            Value::Array(a) => a
                .into_iter()
                .filter_map(|v| match v {
                    Value::Object(m) => Some(m),
                    _ => None,
                })
                .collect(),
            // Some panels return {} for empty lists.
            _ => vec![],
        })
    }

    pub fn vod_info(&self, agent: &ureq::Agent, vod_id: &str) -> Result<Map<String, Value>, String> {
        Ok(match self.get(agent, &self.api_url(Some("get_vod_info"), &[("vod_id", vod_id)]))? {
            Value::Object(m) => m,
            _ => Map::new(),
        })
    }

    pub fn series_info(&self, agent: &ureq::Agent, series_id: &str) -> Result<SeriesInfo, String> {
        let json = self.get(agent, &self.api_url(Some("get_series_info"), &[("series_id", series_id)]))?;
        Ok(self.parse_series(&json))
    }

    pub fn parse_series(&self, json: &Value) -> SeriesInfo {
        let info = json.get("info").and_then(Value::as_object).cloned().unwrap_or_default();
        let seasons: Vec<(String, &Value)> = match json.get("episodes") {
            Some(Value::Object(m)) => m.iter().map(|(k, v)| (k.clone(), v)).collect(),
            // Some panels return a list of lists.
            Some(Value::Array(a)) => a.iter().enumerate().map(|(i, v)| ((i + 1).to_string(), v)).collect(),
            _ => vec![],
        };
        let mut episodes = vec![];
        for (season_key, list) in seasons {
            let Some(list) = list.as_array() else { continue };
            for e in list.iter().filter_map(Value::as_object) {
                let id = str_of(e.get("id")).unwrap_or_default();
                let ext = str_of(e.get("container_extension")).unwrap_or_else(|| "mp4".into());
                let ep_info = e.get("info").and_then(Value::as_object);
                let field = |k: &str| ep_info.and_then(|i| str_of(i.get(k)));
                let number = int_of(e.get("episode_num")).unwrap_or(episodes.len() as i64 + 1);
                episodes.push(Episode {
                    url: self.episode_url(&id, &ext),
                    season: int_of(e.get("season")).or_else(|| season_key.parse().ok()).unwrap_or(1),
                    number,
                    title: str_of(e.get("title")).unwrap_or_else(|| format!("Episode {number}")),
                    plot: field("plot"),
                    image: field("movie_image").or_else(|| field("cover_big")),
                    duration: field("duration"),
                    id,
                });
            }
        }
        episodes.sort_by_key(|e| (e.season, e.number));
        SeriesInfo { info, episodes }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn builds_urls() {
        let x = Xtream::new(" host.tv:8080/player_api.php?x=1 ", "us er", "p&w");
        assert_eq!(x.server, "http://host.tv:8080");
        assert_eq!(x.live_url("5", "ts"), "http://host.tv:8080/live/us%20er/p%26w/5.ts");
        assert_eq!(x.api_url(Some("get_vod_info"), &[("vod_id", "9")]),
            "http://host.tv:8080/player_api.php?username=us%20er&password=p%26w&action=get_vod_info&vod_id=9");
        assert_eq!(x.timeshift_url("7", 0, 60), "http://host.tv:8080/timeshift/us%20er/p%26w/60/1970-01-01:00-00/7.ts");
    }

    #[test]
    fn parses_series_in_both_shapes() {
        let x = Xtream::new("h", "u", "p");
        let s = x.parse_series(&json!({
            "info": {"plot": "Plot", "releaseDate": "2020-01-01"},
            "episodes": {"2": [{"id": "22", "episode_num": "1", "title": "B", "container_extension": "mkv"}],
                         "1": [{"id": 11, "episode_num": 2, "info": {"movie_image": "img"}}]}
        }));
        assert_eq!(str_of(s.info.get("plot")).as_deref(), Some("Plot"));
        assert_eq!(s.episodes.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(), ["11", "22"]);
        assert_eq!(s.episodes[0].title, "Episode 2");
        assert_eq!(s.episodes[0].image.as_deref(), Some("img"));
        assert_eq!(s.episodes[1].url, "http://h/series/u/p/22.mkv");
        let s = x.parse_series(&json!({"episodes": [[{"id": "a"}], [{"id": "b"}]]}));
        assert_eq!(s.episodes[1].season, 2);
    }
}
