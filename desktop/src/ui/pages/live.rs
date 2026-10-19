//! Live TV: categories, the channel list with what is on now, and the
//! preview player with the channel's schedule.

use super::super::app::App;
use super::super::data::{Cached, Paged};
use super::super::theme::*;
use super::super::widgets::*;
use crate::db::{Group, Task};
use crate::model::{Category, ItemKind, MediaItem, Playable, Programme};
use crate::repo::{self, ItemQuery, now_secs};
use eframe::egui::{self, Align2, Key, Rect, Sense, vec2};
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Filter {
    #[default]
    All,
    Favorites,
    Category(i64),
}

#[derive(Default)]
pub struct State {
    pub filter: Filter,
    pub text: String,
    list: Paged,
    categories: Cached<(i64, u64), Vec<Category>>,
    now_next: Cached<(i64, i64, String, u64, i64), HashMap<String, Vec<Programme>>>,
    schedule: Cached<(i64, String, u64, i64), Vec<Programme>>,
    /// Item to highlight after arriving from another page.
    pub select_key: Option<String>,
    pub autoplay: Option<Task<Option<MediaItem>>>,
    last_zap_index: Option<i64>,
}

pub fn query(app: &App, source_id: i64) -> ItemQuery {
    let st = &app.pages.live;
    let mut q = ItemQuery::new(ItemKind::Live, source_id);
    q.text = st.text.clone();
    match st.filter {
        Filter::All => {}
        Filter::Favorites => q.favorites_only = true,
        Filter::Category(id) => q.category_id = Some(id),
    }
    q
}

pub fn categories_panel(ui: &mut egui::Ui, cats: &[Category], filter: &mut Filter, total: i64) -> bool {
    let mut changed = false;
    egui::ScrollArea::vertical().id_salt("cats").auto_shrink(false).show(ui, |ui| {
        let mut entry = |ui: &mut egui::Ui, f: Filter, label: &str, count: Option<i64>| {
            let (rect, resp) = row(ui, 36.0, *filter == f);
            let p = ui.painter();
            let count_w = if let Some(n) = count {
                let g = p.text(rect.right_center() - vec2(10.0, 0.0), Align2::RIGHT_CENTER, n.to_string(), font(12.0), TEXT_DIM);
                g.width() + 14.0
            } else {
                0.0
            };
            text_in(ui, rect.left_center() + vec2(14.0, -9.0), label, font(14.0), TEXT, rect.width() - 24.0 - count_w);
            if resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() && *filter != f {
                *filter = f;
                changed = true;
            }
        };
        entry(ui, Filter::All, "All", Some(total));
        entry(ui, Filter::Favorites, "★  Favorites", None);
        ui.separator();
        for c in cats {
            entry(ui, Filter::Category(c.id), &c.name, Some(c.item_count));
        }
    });
    changed
}

pub fn show(app: &mut App, ui: &mut egui::Ui) {
    let Some(source) = app.active_source().cloned() else { return };
    let db = app.db.clone();
    let now = now_secs();

    // Autoplay the last channel at start-up.
    if let Some(t) = &app.pages.live.autoplay
        && let Some(r) = t.take()
    {
        app.pages.live.autoplay = None;
        if let Ok(Some(item)) = r {
            app.pages.live.select_key = Some(item.key.clone());
            app.player.open_item(&item, None, None);
        }
    }

    let items_v = app.version(Group::Items);
    let cats = app
        .pages
        .live
        .categories
        .get(&(source.id, items_v), || db.read(move |c| repo::categories(c, source.id, ItemKind::Live)))
        .cloned()
        .unwrap_or_default();

    let q = query(app, source.id);
    let list_v = items_v + app.version(Group::Favorites);
    app.pages.live.list.sync(&db, &q, list_v);

    // Channel up/down from the keyboard.
    if !ui.ctx().egui_wants_keyboard_input() {
        let (up, down, enter) = ui.input(|i| (i.key_pressed(Key::ArrowUp), i.key_pressed(Key::ArrowDown), i.key_pressed(Key::Enter)));
        if app.player.can_zap() {
            if up {
                app.player.zap(-1);
            }
            if down {
                app.player.zap(1);
            }
        }
        if enter && app.player.playable.is_some() {
            app.full_player = true;
        }
    }

    egui::Panel::left("live-cats")
        .exact_size(220.0)
        .resizable(false)
        .show_separator_line(false)
        .frame(egui::Frame::new().inner_margin(egui::Margin { right: 12, ..Default::default() }))
        .show(ui, |ui| {
            ui.label(egui::RichText::new("Live TV").font(bold_font(22.0)).color(TEXT));
            ui.add_space(6.0);
            let st = &mut app.pages.live;
            if categories_panel(ui, &cats, &mut st.filter, source.live_count) {
                st.text.clear();
            }
        });

    let preview_w = (ui.available_width() * 0.42).clamp(320.0, 720.0);
    egui::Panel::right("live-preview")
        .exact_size(preview_w)
        .resizable(false)
        .show_separator_line(false)
        .frame(egui::Frame::new().inner_margin(egui::Margin { left: 16, ..Default::default() }))
        .show(ui, |ui| preview(app, ui, source.id, now));

    egui::CentralPanel::no_frame().show(ui, |ui| {
        ui.horizontal(|ui| {
            let w = ui.available_width();
            search_field(ui, &mut app.pages.live.text, "Filter channels", w);
        });
        ui.add_space(6.0);
        channel_list(app, ui, &q, source.id, now);
    });
}

fn channel_list(app: &mut App, ui: &mut egui::Ui, q: &ItemQuery, source_id: i64, now: i64) {
    let db = app.db.clone();
    let total = app.pages.live.list.len();
    if total == 0 {
        if app.pages.live.list.total.is_some() {
            let body = if app.pages.live.filter == Filter::Favorites { "Click ☆ on a channel to add it here." } else { "Nothing matches." };
            empty_state(ui, "No channels", body);
        }
        return;
    }
    let playing = app.player.playable.as_ref().filter(|p| p.is_live()).map(|p| p.key.clone());
    let row_h = 62.0;

    // Keep the playing channel in view while zapping.
    let zap_index = app.player.zap_index();
    let scroll_to = (zap_index != app.pages.live.last_zap_index).then_some(zap_index).flatten();
    app.pages.live.last_zap_index = zap_index;

    let mut area = egui::ScrollArea::vertical().id_salt(("channels", q.category_id, q.favorites_only)).auto_shrink(false);
    if let Some(i) = scroll_to {
        let offset = ui.ctx().memory(|m| m.data.get_temp::<f32>(egui::Id::new("channels-offset"))).unwrap_or(0.0);
        let view_h = ui.available_height();
        let y = i as f32 * row_h;
        if y < offset || y + row_h > offset + view_h {
            area = area.vertical_scroll_offset((y - view_h / 2.0).max(0.0));
        }
    }
    let out = area.show_rows(ui, row_h, total as usize, |ui, range| {
        // Now/next for the page of channels on screen.
        let first = range.start as i64;
        let page = first / 100;
        let ids: Vec<String> = (page * 100..(page * 100 + 200).min(total))
            .filter_map(|i| app.pages.live.list.get(&db, i).and_then(|it| it.epg_id.clone()))
            .collect();
        let key = (source_id, page, ids.join(","), app.version(Group::Epg), now / 60);
        let epg_dir = db.epg_dir.clone();
        let nn = app
            .pages
            .live
            .now_next
            .get(&key, || db.read(move |c| repo::now_next(c, &epg_dir, source_id, &ids, now)))
            .cloned()
            .unwrap_or_default();
        app.pages.live.list.trim(first);

        for i in range {
            let Some(item) = app.pages.live.list.get(&db, i as i64).cloned() else {
                ui.allocate_space(vec2(ui.available_width(), row_h));
                continue;
            };
            let selected = playing.as_deref() == Some(item.key.as_str()) || app.pages.live.select_key.as_deref() == Some(item.key.as_str()) && playing.is_none();
            let (rect, resp) = row(ui, row_h - 4.0, selected);
            ui.add_space(4.0 - ui.spacing().item_spacing.y);
            let p = ui.painter();
            let mut x = rect.left() + 12.0;
            if let Some(n) = item.number {
                p.text(egui::pos2(x + 26.0, rect.center().y), Align2::RIGHT_CENTER, n.to_string(), font(12.5), TEXT_DIM);
            }
            x += 36.0;
            let logo = Rect::from_min_size(egui::pos2(x, rect.top() + 7.0), vec2(64.0, rect.height() - 14.0));
            picture(ui, &mut app.images, logo, item.logo.as_deref(), &item.name, 8, false);
            x = logo.right() + 12.0;
            let star = Rect::from_center_size(rect.right_center() - vec2(22.0, 0.0), vec2(30.0, 30.0));
            let text_w = star.left() - x - 8.0;
            let now_prog = item.epg_id.as_ref().and_then(|id| nn.get(id)).and_then(|l| l.iter().find(|p| p.is_live_at(now)));
            match now_prog {
                Some(prog) => {
                    text_in(ui, egui::pos2(x, rect.top() + 8.0), &item.name, bold_font(14.5), TEXT, text_w);
                    text_in(ui, egui::pos2(x, rect.top() + 28.0), &prog.title, font(12.5), TEXT_DIM, text_w);
                    let bar = Rect::from_min_size(egui::pos2(x, rect.bottom() - 9.0), vec2(text_w.min(180.0), 3.0));
                    progress_bar(ui, bar, prog.progress_at(now), ACCENT);
                }
                None => {
                    text_in(ui, egui::pos2(x, rect.center().y - 10.0), &item.name, bold_font(14.5), TEXT, text_w);
                }
            }
            let star_resp = ui.interact(star, ui.id().with(("fav", item.id)), Sense::click());
            let star_color = if item.favorite { STAR } else if resp.hovered() || star_resp.hovered() { TEXT_DIM } else { egui::Color32::TRANSPARENT };
            ui.painter().text(star.center(), Align2::CENTER_CENTER, if item.favorite { "★" } else { "☆" }, font(18.0), star_color);
            if star_resp.clicked() {
                let (sid, key) = (item.source_id, item.key.clone());
                app.db.write(&[Group::Favorites], move |c| repo::toggle_favorite(c, sid, &key, ItemKind::Live));
            } else if resp.double_clicked() {
                app.full_player = true;
            } else if resp.clicked() {
                app.pages.live.select_key = Some(item.key.clone());
                if playing.as_deref() != Some(item.key.as_str()) {
                    app.player.open_item(&item, None, Some((q.clone(), i as i64)));
                }
            }
        }
    });
    ui.ctx().memory_mut(|m| m.data.insert_temp(egui::Id::new("channels-offset"), out.state.offset.y));
}

fn preview(app: &mut App, ui: &mut egui::Ui, source_id: i64, now: i64) {
    let w = ui.available_width();
    let rect = ui.allocate_space(vec2(w, w * 9.0 / 16.0)).1;
    let resp = app.video_surface(ui, rect);
    if resp.double_clicked() || (resp.clicked() && app.player.playable.is_some()) {
        app.full_player = true;
    }
    if app.player.playable.is_some() {
        resp.on_hover_text("Click for full screen");
    }
    ui.add_space(10.0);

    let Some(p) = app.player.playable.clone().filter(Playable::is_live) else {
        ui.label(dim("Select a channel to watch it here. Double-click or press Enter for full screen; ↑/↓ change channel."));
        return;
    };
    ui.horizontal(|ui| {
        ui.label(egui::RichText::new("● LIVE").font(bold_font(12.0)).color(LIVE));
        ui.add(egui::Label::new(egui::RichText::new(&p.title).font(bold_font(18.0)).color(TEXT)).truncate());
    });

    let Some(epg_id) = p.epg_id.clone() else {
        ui.label(dim("No TV guide for this channel."));
        return;
    };
    let db = app.db.clone();
    let epg_dir = db.epg_dir.clone();
    let key = (source_id, epg_id.clone(), app.version(Group::Epg), now / 600);
    let list = app
        .pages
        .live
        .schedule
        .get(&key, || {
            let ids = vec![epg_id.clone()];
            db.read(move |c| {
                let mut m = repo::guide_range(c, &epg_dir, source_id, &ids, now - 6 * 3600, now + 24 * 3600, None)?;
                Ok(m.remove(&ids[0]).unwrap_or_default())
            })
        })
        .cloned()
        .unwrap_or_default();
    if list.is_empty() {
        ui.label(dim("No programme information right now."));
        return;
    }
    if let Some(cur) = list.iter().find(|x| x.is_live_at(now)) {
        ui.label(egui::RichText::new(&cur.title).font(bold_font(15.0)).color(TEXT_SOFT));
        ui.label(dim(format!("{} – {}", clock(cur.start), clock(cur.stop))));
        let bar = ui.allocate_space(vec2(ui.available_width(), 4.0)).1;
        progress_bar(ui, bar, cur.progress_at(now), ACCENT);
        if let Some(d) = &cur.description {
            ui.add(egui::Label::new(egui::RichText::new(d).color(TEXT_DIM)).wrap());
        }
    }
    ui.add_space(8.0);
    section_title(ui, "Schedule");
    let can_catchup = p.catchup_days.unwrap_or(0) > 0 && super::xtream_from_url(&p.url).is_some();
    egui::ScrollArea::vertical().id_salt("schedule").auto_shrink(false).show(ui, |ui| {
        for prog in list.iter().filter(|x| x.stop > now - 3 * 3600) {
            let live = prog.is_live_at(now);
            let past = prog.stop <= now;
            ui.horizontal(|ui| {
                let color = if live { ACCENT_BRIGHT } else if past { TEXT_DIM } else { TEXT_SOFT };
                ui.label(egui::RichText::new(clock(prog.start)).color(color).font(font(13.0)));
                ui.add(egui::Label::new(egui::RichText::new(&prog.title).color(color)).truncate());
                if past && can_catchup && ui.small_button("▶ Catch up").clicked() {
                    play_catchup(app, &p, prog);
                }
            });
        }
    });
}

pub fn play_catchup(app: &mut App, channel: &Playable, prog: &Programme) {
    let Some((x, id)) = super::xtream_from_url(&channel.url) else { return };
    let minutes = ((prog.stop - prog.start) / 60).max(1);
    let p = Playable {
        source_id: channel.source_id,
        key: format!("catchup:{}:{}", channel.key, prog.start * 1000),
        kind: ItemKind::Movie,
        title: prog.title.clone(),
        subtitle: Some(format!("{} · {}", channel.title, clock(prog.start))),
        url: x.timeshift_url(&id, prog.start, minutes),
        logo: channel.logo.clone(),
        headers: channel.headers.clone(),
        epg_id: None,
        catchup_days: None,
        resume_ms: None,
    };
    app.player.open(p, None);
    app.full_player = true;
}
