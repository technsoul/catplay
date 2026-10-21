//! Movies and series: poster grid with categories, sorting and a filter,
//! then a details view (plot from Xtream, seasons and episodes for series).

use super::super::app::App;
use super::super::data::{Cached, Paged};
use super::super::theme::*;
use super::super::widgets::*;
use super::live::{Filter, categories_panel};
use crate::db::{self, Group, Task};
use crate::downloads::{self, Downloads, Status};
use crate::model::{Category, Episode, ItemKind, MediaItem, Playable};
use crate::parse::xtream::{SeriesInfo, str_of};
use crate::repo::{self, ItemQuery, ItemSort};
use eframe::egui::{self, Align2, CornerRadius, Rect, Sense, vec2};
use serde_json::{Map, Value};

const CARD_W: f32 = 160.0;
const CARD_H: f32 = 282.0;

pub struct Details {
    item: MediaItem,
    info: Option<Task<Info>>,
    loaded: Option<Result<Info, String>>,
    season: i64,
    resume: Cached<u64, Option<i64>>,
}

pub enum Info {
    Movie(Map<String, Value>),
    Series(SeriesInfo),
    None,
}

#[derive(Default)]
pub struct State {
    filter: Filter,
    text: String,
    sort: ItemSort,
    list: Paged,
    categories: Cached<(i64, u64), Vec<Category>>,
    details: Option<Details>,
}

impl State {
    pub fn open_details(&mut self, item: MediaItem) {
        self.details = Some(Details { item, info: None, loaded: None, season: 0, resume: Cached::default() });
    }
}

fn state(app: &mut App, kind: ItemKind) -> &mut State {
    if kind == ItemKind::Movie { &mut app.pages.movies } else { &mut app.pages.series }
}

pub fn show(app: &mut App, ui: &mut egui::Ui, kind: ItemKind) {
    let Some(source) = app.active_source().cloned() else { return };
    if state(app, kind).details.is_some() {
        details(app, ui, kind, &source);
        return;
    }
    let db = app.db.clone();
    let items_v = app.version(Group::Items);
    let fav_v = app.version(Group::Favorites);
    let cats = state(app, kind)
        .categories
        .get(&(source.id, items_v), || db.read(move |c| repo::categories(c, source.id, kind)))
        .cloned()
        .unwrap_or_default();
    let total_all = if kind == ItemKind::Movie { source.movie_count } else { source.series_count };

    egui::Panel::left(egui::Id::new(("vod-cats", kind.index())))
        .exact_size(220.0)
        .resizable(false)
        .show_separator_line(false)
        .frame(egui::Frame::new().inner_margin(egui::Margin { right: 12, ..Default::default() }))
        .show(ui, |ui| {
            ui.label(egui::RichText::new(if kind == ItemKind::Movie { "Movies" } else { "Series" }).font(bold_font(22.0)).color(TEXT));
            ui.add_space(6.0);
            let st = state(app, kind);
            categories_panel(ui, &cats, &mut st.filter, total_all);
        });

    let st = state(app, kind);
    let mut q = ItemQuery::new(kind, source.id);
    q.text = st.text.clone();
    q.sort = st.sort;
    match st.filter {
        Filter::All => {}
        Filter::Favorites => q.favorites_only = true,
        Filter::Category(id) => q.category_id = Some(id),
    }
    st.list.sync(&db, &q, items_v + fav_v);

    egui::CentralPanel::no_frame().show(ui, |ui| {
        ui.horizontal(|ui| {
            let st = state(app, kind);
            let w = (ui.available_width() - 200.0).max(160.0);
            search_field(ui, &mut st.text, if kind == ItemKind::Movie { "Filter movies" } else { "Filter series" }, w);
            egui::ComboBox::from_id_salt(("sort", kind.index())).selected_text(st.sort.label()).width(180.0).show_ui(ui, |ui| {
                for s in ItemSort::ALL {
                    ui.selectable_value(&mut st.sort, s, s.label());
                }
            });
        });
        ui.add_space(8.0);
        poster_grid(app, ui, kind);
    });
}

fn poster_grid(app: &mut App, ui: &mut egui::Ui, kind: ItemKind) {
    let db = app.db.clone();
    let total = state(app, kind).list.len();
    if total == 0 {
        if state(app, kind).list.total.is_some() {
            empty_state(ui, "Nothing here", "Try another category or filter.");
        }
        return;
    }
    let width = ui.available_width() - 4.0;
    let cols = ((width / (CARD_W + 12.0)).floor() as i64).max(1);
    let card_w = (width / cols as f32) - 12.0;
    let card_h = card_w * CARD_H / CARD_W;
    let rows = (total + cols - 1) / cols;
    egui::ScrollArea::vertical().id_salt(("grid", kind.index())).auto_shrink(false).show_rows(ui, card_h + 12.0, rows as usize, |ui, range| {
        state(app, kind).list.trim(range.start as i64 * cols);
        for r in range {
            ui.horizontal(|ui| {
                for c in 0..cols {
                    let i = r as i64 * cols + c;
                    if i >= total {
                        break;
                    }
                    let item = state(app, kind).list.get(&db, i).cloned();
                    let (rect, resp) = ui.allocate_exact_size(vec2(card_w, card_h), Sense::click());
                    let Some(item) = item else {
                        ui.painter().rect_filled(rect, CornerRadius::same(R_CARD), SURFACE);
                        continue;
                    };
                    let hover = resp.hovered();
                    let poster = Rect::from_min_size(rect.min, vec2(card_w, card_w * 1.5));
                    picture(ui, &mut app.images, poster, item.logo.as_deref(), &item.name, R_CARD, true);
                    if hover {
                        ui.painter().rect_stroke(poster, CornerRadius::same(R_CARD), egui::Stroke::new(2.0, ACCENT), egui::StrokeKind::Inside);
                    }
                    if item.favorite {
                        ui.painter().text(poster.right_top() + vec2(-10.0, 8.0), Align2::RIGHT_TOP, "★", font(18.0), STAR);
                    }
                    if let Some(r) = item.rating.filter(|r| *r > 0.0) {
                        let badge = Rect::from_min_size(poster.left_top() + vec2(8.0, 8.0), vec2(44.0, 22.0));
                        ui.painter().rect_filled(badge, CornerRadius::same(11), egui::Color32::from_black_alpha(170));
                        ui.painter().text(badge.center(), Align2::CENTER_CENTER, format!("★ {r:.1}"), font(11.5), STAR);
                    }
                    let ty = poster.bottom() + 6.0;
                    text_in(ui, egui::pos2(rect.left() + 2.0, ty), &item.name, font(13.5), TEXT, card_w - 4.0);
                    if let Some(y) = &item.year {
                        text_in(ui, egui::pos2(rect.left() + 2.0, ty + 20.0), y, font(12.0), TEXT_DIM, card_w - 4.0);
                    }
                    if resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
                        state(app, kind).open_details(item);
                    }
                }
            });
            ui.add_space(12.0 - ui.spacing().item_spacing.y);
        }
    });
}

fn details(app: &mut App, ui: &mut egui::Ui, kind: ItemKind, source: &crate::model::Source) {
    let db = app.db.clone();
    let hist_v = app.version(Group::History);
    let fav_v = app.version(Group::Favorites);
    let Some(mut details) = state(app, kind).details.take() else { return };
    let d = &mut details;

    // Start loading details from Xtream.
    if d.info.is_none() && d.loaded.is_none() {
        let item = d.item.clone();
        let src = source.clone();
        d.info = Some(db::background(move || {
            let agent = crate::http::shared();
            match item.kind {
                ItemKind::Series => {
                    let Some(x) = super::xtream_for(&src) else { return Ok(Info::None) };
                    let Some(id) = item.ext_id.as_deref() else { return Ok(Info::None) };
                    x.series_info(agent, id).map(Info::Series)
                }
                _ => {
                    let Some((x, id)) = item.url.as_deref().and_then(super::xtream_from_url) else { return Ok(Info::None) };
                    x.vod_info(agent, &id).map(Info::Movie)
                }
            }
        }));
    }
    if let Some(t) = &d.info
        && let Some(r) = t.take()
    {
        d.loaded = Some(r);
        d.info = None;
    }
    // Favorite state can change while open.
    let item = d.item.clone();
    let (sid, key) = (item.source_id, item.key.clone());
    let resume = d.resume.get(&(hist_v + fav_v), || db.read(move |c| repo::resume_position(c, sid, &key))).cloned().flatten();

    let mut back = false;
    let mut play: Option<Playable> = None;
    let mut toggle_fav = false;
    egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
        if ui.button("← Back").clicked() {
            back = true;
        }
        ui.add_space(10.0);
        let info_map: Option<&Map<String, Value>> = match &d.loaded {
            Some(Ok(Info::Movie(m))) => m.get("info").and_then(Value::as_object),
            Some(Ok(Info::Series(s))) => Some(&s.info),
            _ => None,
        };
        let field = |k: &str| info_map.and_then(|m| str_of(m.get(k)));
        ui.horizontal_top(|ui| {
            let poster = ui.allocate_space(vec2(240.0, 360.0)).1;
            let cover = field("cover_big").or_else(|| field("movie_image")).or_else(|| item.logo.clone());
            picture(ui, &mut app.images, poster, cover.as_deref(), &item.name, R_CARD, true);
            ui.add_space(20.0);
            ui.vertical(|ui| {
                ui.set_max_width(720.0);
                ui.label(egui::RichText::new(&item.name).font(bold_font(28.0)).color(TEXT));
                let mut meta = vec![];
                if let Some(y) = item.year.clone().or_else(|| field("releasedate").or_else(|| field("releaseDate"))) {
                    meta.push(y);
                }
                if let Some(r) = item.rating.filter(|r| *r > 0.0) {
                    meta.push(format!("★ {r:.1}"));
                }
                if let Some(g) = field("genre") {
                    meta.push(g);
                }
                if let Some(dur) = field("duration") {
                    meta.push(dur);
                }
                ui.label(dim(meta.join("  ·  ")));
                ui.add_space(10.0);
                ui.horizontal(|ui| {
                    if kind == ItemKind::Movie {
                        let label = if resume.is_some() { "▶  Resume" } else { "▶  Play" };
                        if pill(ui, label, true).clicked() {
                            play = Some(movie_playable(&item, resume));
                        }
                        if resume.is_some() && pill(ui, "Start over", false).clicked() {
                            play = Some(movie_playable(&item, Some(0)));
                        }
                        if downloads::is_downloadable(item.url.as_deref()) {
                            download_button(ui, &app.downloads, item.source_id, &item.key, || app.downloads.add_item(&item));
                        }
                    }
                    let fav = if item.favorite { "★  Favorite" } else { "☆  Add to favorites" };
                    if pill(ui, fav, false).clicked() {
                        toggle_fav = true;
                    }
                });
                ui.add_space(12.0);
                match &d.loaded {
                    None => spinner_label(ui, "Loading details…"),
                    Some(Err(e)) => {
                        ui.label(dim(format!("Details are not available ({e}).")));
                    }
                    _ => {}
                }
                if let Some(plot) = field("plot").or_else(|| field("description")) {
                    ui.add(egui::Label::new(egui::RichText::new(plot).color(TEXT_SOFT).font(font(15.0))).wrap());
                }
                for (label, k) in [("Cast", "cast"), ("Director", "director")] {
                    if let Some(v) = field(k) {
                        ui.add_space(4.0);
                        ui.add(egui::Label::new(egui::RichText::new(format!("{label}: {v}")).color(TEXT_DIM)).wrap());
                    }
                }
            });
        });

        if let Some(Ok(Info::Series(s))) = &d.loaded {
            ui.add_space(18.0);
            let cover = field("cover").or_else(|| item.logo.clone());
            episodes(ui, &mut app.images, &app.downloads, s, &item, cover, &mut d.season, &mut play);
        } else if kind == ItemKind::Series && matches!(d.loaded, Some(Ok(Info::None))) {
            ui.add_space(18.0);
            ui.label(dim("Episodes are only available for Xtream Codes playlists."));
        }
    });

    if toggle_fav {
        details.item.favorite = !details.item.favorite;
        let (sid, key) = (item.source_id, item.key.clone());
        app.db.write(&[Group::Favorites], move |c| repo::toggle_favorite(c, sid, &key, kind));
    }
    if !back {
        state(app, kind).details = Some(details);
    }
    if let Some(p) = play {
        app.player.open(p, None);
        app.full_player = true;
    }
}

/// A pill showing an item's download state; starts or resumes it on click.
fn download_button(ui: &mut egui::Ui, dl: &Downloads, source_id: i64, key: &str, add: impl FnOnce()) {
    let current = dl.find(source_id, key);
    let label = match &current {
        None => "⬇  Download".to_string(),
        Some(d) => match d.status {
            Status::Queued => "⬇  Waiting…".into(),
            Status::Downloading => format!("⬇  {:.0}%", d.fraction().unwrap_or(0.0) * 100.0),
            Status::Paused => "⬇  Paused · resume".into(),
            Status::Failed => "⬇  Failed · retry".into(),
            Status::Done => "✔  Downloaded".into(),
        },
    };
    let r = pill(ui, &label, false);
    match &current {
        None => {
            if r.on_hover_text("Save to watch offline").clicked() {
                add();
            }
        }
        Some(d) if matches!(d.status, Status::Paused | Status::Failed) => {
            if r.clicked() {
                dl.resume(&d.id());
            }
        }
        Some(d) if d.status == Status::Done => {
            r.on_hover_text("Plays from your computer. Manage it in Downloads.");
        }
        _ => {}
    }
}

fn movie_playable(item: &MediaItem, resume: Option<i64>) -> Playable {
    Playable {
        source_id: item.source_id,
        key: item.key.clone(),
        kind: item.kind,
        title: item.name.clone(),
        subtitle: None,
        url: item.url.clone().unwrap_or_default(),
        logo: item.logo.clone(),
        headers: item.headers.clone(),
        epg_id: None,
        catchup_days: None,
        resume_ms: resume,
    }
}

#[allow(clippy::too_many_arguments)]
fn episodes(
    ui: &mut egui::Ui,
    images: &mut crate::images::Images,
    dl: &Downloads,
    s: &SeriesInfo,
    item: &MediaItem,
    cover: Option<String>,
    season: &mut i64,
    play: &mut Option<Playable>,
) {
    let mut seasons: Vec<i64> = s.episodes.iter().map(|e| e.season).collect();
    seasons.dedup();
    if seasons.is_empty() {
        ui.label(dim("No episodes."));
        return;
    }
    if !seasons.contains(season) {
        *season = seasons[0];
    }
    let in_season: Vec<_> = s.episodes.iter().filter(|e| e.season == *season).collect();
    ui.horizontal_wrapped(|ui| {
        for n in &seasons {
            if ui.selectable_label(*season == *n, format!("Season {n}")).clicked() {
                *season = *n;
            }
        }
        let missing: Vec<_> = in_season
            .iter()
            .filter(|e| downloads::is_downloadable(Some(&e.url)) && dl.find(item.source_id, &format!("ep:{}", e.id)).is_none())
            .collect();
        if !missing.is_empty() && ui.button(format!("⬇ Download season ({})", missing.len())).clicked() {
            for e in missing {
                dl.add_episode(item, e, cover.clone());
            }
        }
    });
    ui.add_space(8.0);
    for e in in_season {
        let (rect, resp) = row(ui, 92.0, false);
        // Download state / button on the right.
        let key = format!("ep:{}", e.id);
        let btn = Rect::from_center_size(rect.right_center() - vec2(70.0, 0.0), vec2(120.0, 30.0));
        let state = dl.find(item.source_id, &key);
        let btn_label = match &state {
            None if downloads::is_downloadable(Some(&e.url)) => Some("⬇ Download".to_string()),
            None => None,
            Some(d) => Some(match d.status {
                Status::Queued => "Waiting…".into(),
                Status::Downloading => format!("{:.0}%", d.fraction().unwrap_or(0.0) * 100.0),
                Status::Paused => "Paused".into(),
                Status::Failed => "Failed · retry".into(),
                Status::Done => "✔ Downloaded".into(),
            }),
        };
        let mut btn_clicked = false;
        if let Some(label) = &btn_label {
            let r = ui.interact(btn, ui.id().with(("ep-dl", &e.id)), egui::Sense::click());
            let color = if state.as_ref().is_some_and(|d| d.status == Status::Done) { SUCCESS } else if r.hovered() { TEXT } else { TEXT_DIM };
            if r.hovered() {
                ui.painter().rect_filled(btn, egui::CornerRadius::same(15), RAISED);
            }
            ui.painter().text(btn.center(), Align2::CENTER_CENTER, label, font(12.5), color);
            if r.clicked() {
                btn_clicked = true;
                match &state {
                    None => dl.add_episode(item, e, cover.clone()),
                    Some(d) if matches!(d.status, Status::Paused | Status::Failed) => dl.resume(&d.id()),
                    _ => {}
                }
            }
        }
        let thumb = Rect::from_min_size(rect.min + vec2(10.0, 8.0), vec2(136.0, 76.0));
        picture(ui, images, thumb, e.image.as_deref().or(item.logo.as_deref()), &e.title, 8, true);
        let x = thumb.right() + 14.0;
        let w = btn.left() - x - 14.0;
        text_in(ui, egui::pos2(x, rect.top() + 12.0), &format!("{}. {}", e.number, e.title), bold_font(14.5), TEXT, w);
        if let Some(plot) = &e.plot {
            text_in(ui, egui::pos2(x, rect.top() + 36.0), plot, font(12.5), TEXT_DIM, w);
        }
        if let Some(d) = &e.duration {
            text_in(ui, egui::pos2(x, rect.top() + 58.0), d, font(12.0), TEXT_DIM, w);
        }
        if resp.hovered() {
            ui.painter().text(thumb.center(), Align2::CENTER_CENTER, "▶", font(26.0), TEXT);
        }
        if resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() && !btn_clicked {
            *play = Some(episode_playable(item, e));
        }
    }
}

fn episode_playable(item: &MediaItem, e: &Episode) -> Playable {
    Playable {
        source_id: item.source_id,
        key: format!("ep:{}", e.id),
        kind: ItemKind::Series,
        title: downloads::episode_title(e),
        subtitle: Some(item.name.clone()),
        url: e.url.clone(),
        logo: item.logo.clone(),
        headers: Default::default(),
        epg_id: None,
        catchup_days: None,
        resume_ms: None,
    }
}
