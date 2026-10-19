//! TV guide: a day timeline for every channel. Only the visible rows and
//! programmes are drawn, so it stays fast with thousands of channels.

use super::super::app::App;
use super::super::data::{Cached, Paged};
use super::super::theme::*;
use super::super::widgets::*;
use super::live::{Filter, categories_panel};
use crate::db::Group;
use crate::model::{Category, ItemKind, MediaItem, Programme};
use crate::repo::{self, ItemQuery, now_secs};
use chrono::{Duration as CDuration, Local, TimeZone};
use eframe::egui::{self, Align2, Color32, CornerRadius, Rect, Sense, Stroke, StrokeKind, pos2, vec2};
use std::collections::HashMap;

const CH_W: f32 = 210.0;
const ROW_H: f32 = 56.0;
const HEADER_H: f32 = 34.0;
const PX_PER_MIN: f32 = 4.0;

type ProgKey = (i64, i64, u64, i64);

#[derive(Default)]
pub struct State {
    filter: Filter,
    /// Days from today.
    day: i64,
    list: Paged,
    categories: Cached<(i64, u64), Vec<Category>>,
    programmes: HashMap<i64, Cached<ProgKey, HashMap<String, Vec<Programme>>>>,
    details: Option<(MediaItem, Programme)>,
    scroll_to_now: bool,
    shown_once: bool,
}

fn day_start(offset: i64) -> i64 {
    let today = Local::now().date_naive() + CDuration::days(offset);
    Local
        .from_local_datetime(&today.and_hms_opt(0, 0, 0).unwrap_or_default())
        .earliest()
        .map_or(0, |d| d.timestamp())
}

pub fn show(app: &mut App, ui: &mut egui::Ui) {
    let Some(source) = app.active_source().cloned() else { return };
    let db = app.db.clone();
    let now = now_secs();
    let items_v = app.version(Group::Items);
    let cats = app
        .pages
        .guide
        .categories
        .get(&(source.id, items_v), || db.read(move |c| repo::categories(c, source.id, ItemKind::Live)))
        .cloned()
        .unwrap_or_default();
    if !app.pages.guide.shown_once {
        app.pages.guide.shown_once = true;
        app.pages.guide.scroll_to_now = true;
    }

    egui::Panel::left("guide-cats")
        .exact_size(200.0)
        .resizable(false)
        .show_separator_line(false)
        .frame(egui::Frame::new().inner_margin(egui::Margin { right: 12, ..Default::default() }))
        .show(ui, |ui| {
            ui.label(egui::RichText::new("TV Guide").font(bold_font(22.0)).color(TEXT));
            ui.add_space(6.0);
            if categories_panel(ui, &cats, &mut app.pages.guide.filter, source.live_count) {
                app.pages.guide.programmes.clear();
            }
        });

    let mut q = ItemQuery::new(ItemKind::Live, source.id);
    match app.pages.guide.filter {
        Filter::All => {}
        Filter::Favorites => q.favorites_only = true,
        Filter::Category(id) => q.category_id = Some(id),
    }
    app.pages.guide.list.sync(&db, &q, items_v + app.version(Group::Favorites));

    egui::CentralPanel::no_frame().show(ui, |ui| {
        // Day picker.
        ui.horizontal(|ui| {
            let st = &mut app.pages.guide;
            for d in -1..=6 {
                let start = day_start(d);
                let label = match d {
                    -1 => "Yesterday".to_string(),
                    0 => "Today".to_string(),
                    1 => "Tomorrow".to_string(),
                    _ => chrono::DateTime::from_timestamp(start, 0)
                        .map(|t| t.with_timezone(&Local).format("%a %d").to_string())
                        .unwrap_or_default(),
                };
                if ui.selectable_label(st.day == d, label).clicked() && st.day != d {
                    st.day = d;
                    st.scroll_to_now = d == 0;
                }
            }
            if ui.button("Now").clicked() {
                st.day = 0;
                st.scroll_to_now = true;
            }
        });
        ui.add_space(6.0);
        grid(app, ui, source.id, now);
    });

    details_window(app, ui.ctx(), now);
}

fn grid(app: &mut App, ui: &mut egui::Ui, source_id: i64, now: i64) {
    let db = app.db.clone();
    let total = app.pages.guide.list.len();
    if total == 0 {
        if app.pages.guide.list.total.is_some() {
            empty_state(ui, "No channels", "Pick another category.");
        }
        return;
    }
    let day = app.pages.guide.day;
    let start = day_start(day);
    let end = day_start(day + 1);
    let minutes = ((end - start) / 60) as f32;
    let content = vec2(CH_W + minutes * PX_PER_MIN, HEADER_H + total as f32 * ROW_H);
    let epg_v = app.version(Group::Epg);

    let mut area = egui::ScrollArea::both().id_salt("guide-grid").auto_shrink(false);
    if app.pages.guide.scroll_to_now {
        app.pages.guide.scroll_to_now = false;
        let x = if day == 0 { ((now - start) as f32 / 60.0 - 30.0).max(0.0) * PX_PER_MIN } else { 0.0 };
        area = area.horizontal_scroll_offset(x);
    }
    area.show_viewport(ui, |ui, view| {
        ui.set_min_size(content);
        let origin = ui.max_rect().min;
        let at = |x: f32, y: f32| origin + vec2(x, y);
        let clip = Rect::from_min_size(at(view.min.x, view.min.y), view.size());
        let p = ui.painter().with_clip_rect(clip);

        let first = (((view.min.y - HEADER_H) / ROW_H).floor().max(0.0)) as i64;
        let last = (((view.max.y - HEADER_H) / ROW_H).ceil() as i64).min(total);

        // Programmes for the visible pages of channels.
        let mut progs: HashMap<String, Vec<Programme>> = HashMap::new();
        for page in (first / 100)..=((last.max(1) - 1) / 100) {
            let ids: Vec<String> = (page * 100..((page + 1) * 100).min(total))
                .filter_map(|i| app.pages.guide.list.get(&db, i).and_then(|it| it.epg_id.clone()))
                .collect();
            let key = (page, day, epg_v, ids.len() as i64);
            let epg_dir = db.epg_dir.clone();
            let cached = app.pages.guide.programmes.entry(page).or_default();
            if let Some(m) = cached.get(&key, || db.read(move |c| repo::guide_range(c, &epg_dir, source_id, &ids, start, end, None))) {
                progs.extend(m.iter().map(|(k, v)| (k.clone(), v.clone())));
            }
        }
        app.pages.guide.list.trim(first);

        let x_of = |t: i64| CH_W + ((t - start) as f32 / 60.0) * PX_PER_MIN;
        let grid_left = view.min.x + CH_W;
        for i in first..last {
            let y = HEADER_H + i as f32 * ROW_H;
            let Some(item) = app.pages.guide.list.get(&db, i).cloned() else { continue };
            let row_rect = Rect::from_min_size(at(view.min.x, y), vec2(view.width(), ROW_H));
            p.line_segment([row_rect.left_bottom(), row_rect.right_bottom()], Stroke::new(1.0, BORDER));
            let list = item.epg_id.as_ref().and_then(|id| progs.get(id));
            for prog in list.into_iter().flatten() {
                let x0 = x_of(prog.start.max(start)).max(grid_left);
                let x1 = x_of(prog.stop.min(end));
                if x1 <= view.min.x + CH_W || x0 >= view.max.x || x1 - x0 < 2.0 {
                    continue;
                }
                let r = Rect::from_min_max(at(x0 + 1.0, y + 4.0), at(x1 - 1.0, y + ROW_H - 4.0));
                let live = prog.is_live_at(now);
                let resp = ui.interact(r, ui.id().with(("prog", item.id, prog.start)), Sense::click());
                let fill = if resp.hovered() { RAISED } else if live { Color32::from_rgba_unmultiplied(30, 123, 242, 60) } else { SURFACE_HIGH };
                p.rect(r, CornerRadius::same(8), fill, Stroke::new(1.0, if live { ACCENT } else { BORDER }), StrokeKind::Inside);
                let inner = r.shrink2(vec2(8.0, 6.0));
                if inner.width() > 12.0 {
                    let pc = p.with_clip_rect(inner.intersect(clip));
                    pc.text(inner.left_top(), Align2::LEFT_TOP, &prog.title, font(13.0), TEXT);
                    pc.text(inner.left_bottom(), Align2::LEFT_BOTTOM, format!("{} – {}", clock(prog.start), clock(prog.stop)), font(11.0), TEXT_DIM);
                }
                if resp.clicked() {
                    app.pages.guide.details = Some((item.clone(), prog.clone()));
                }
            }
        }

        // Now line.
        if (start..end).contains(&now) {
            let x = origin.x + x_of(now);
            if x > origin.x + grid_left {
                p.line_segment([pos2(x, clip.top() + HEADER_H), pos2(x, clip.bottom())], Stroke::new(2.0, LIVE));
            }
        }

        // Sticky channel column.
        let col = Rect::from_min_size(at(view.min.x, view.min.y + HEADER_H), vec2(CH_W, view.height()));
        p.rect_filled(col, CornerRadius::ZERO, BG);
        for i in first..last {
            let y = HEADER_H + i as f32 * ROW_H;
            let Some(item) = app.pages.guide.list.get(&db, i).cloned() else { continue };
            let r = Rect::from_min_size(at(view.min.x, y), vec2(CH_W - 8.0, ROW_H));
            if r.bottom() < clip.top() + HEADER_H {
                continue;
            }
            let resp = ui.interact(r, ui.id().with(("ch", item.id)), Sense::click());
            if resp.hovered() {
                p.rect_filled(r.shrink(2.0), CornerRadius::same(8), SURFACE_HIGH);
            }
            let logo = Rect::from_min_size(r.min + vec2(6.0, 8.0), vec2(56.0, ROW_H - 16.0));
            let pp = ui.painter().with_clip_rect(col);
            if logo.top() >= col.top() - ROW_H {
                let mut child = ui.new_child(egui::UiBuilder::new().max_rect(col));
                child.set_clip_rect(col);
                picture(&child, &mut app.images, logo, item.logo.as_deref(), &item.name, 6, false);
            }
            let tr = Rect::from_min_max(pos2(logo.right() + 8.0, r.top()), r.max);
            pp.with_clip_rect(tr.intersect(col)).text(tr.left_center(), Align2::LEFT_CENTER, &item.name, font(13.5), TEXT);
            if resp.on_hover_text("Watch").clicked() {
                let q = app.pages.guide.list.query().cloned();
                super::play_item(app, &item, q.map(|q| (q, i)), false);
            }
        }

        // Sticky time header.
        let head = Rect::from_min_size(at(view.min.x, view.min.y), vec2(view.width(), HEADER_H));
        p.rect_filled(head, CornerRadius::ZERO, BG);
        let mut t = start;
        while t < end {
            let x = x_of(t);
            if x >= view.min.x + CH_W - 60.0 && x <= view.max.x {
                let sx = origin.x + x;
                if sx >= origin.x + grid_left {
                    p.text(pos2(sx + 4.0, head.center().y), Align2::LEFT_CENTER, clock(t), font(12.5), TEXT_SOFT);
                    p.line_segment([pos2(sx, head.bottom() - 8.0), pos2(sx, head.bottom())], Stroke::new(1.0, TEXT_DIM));
                }
            }
            t += 1800;
        }
    });
}

fn details_window(app: &mut App, ctx: &egui::Context, now: i64) {
    let Some((item, prog)) = app.pages.guide.details.clone() else { return };
    let modal = egui::Modal::new(egui::Id::new("prog-details")).frame(egui::Frame::popup(&ctx.global_style()).inner_margin(egui::Margin::same(22))).show(ctx, |ui| {
            ui.set_width(440.0);
            ui.label(egui::RichText::new(&prog.title).font(bold_font(20.0)).color(TEXT));
            ui.label(egui::RichText::new(&item.name).color(TEXT_SOFT));
            let day = chrono::DateTime::from_timestamp(prog.start, 0).map(|d| d.with_timezone(&Local).format("%A %d %B").to_string()).unwrap_or_default();
            ui.label(dim(format!("{day} · {} – {}", clock(prog.start), clock(prog.stop))));
            if let Some(c) = &prog.category {
                ui.label(dim(c));
            }
            if let Some(d) = &prog.description {
                ui.add_space(6.0);
                ui.add(egui::Label::new(egui::RichText::new(d).color(TEXT)).wrap());
            }
            ui.add_space(10.0);
            ui.horizontal(|ui| {
                if prog.is_live_at(now) && pill(ui, "▶  Watch live", true).clicked() {
                    super::play_item(app, &item, None, true);
                    app.pages.guide.details = None;
                }
                let can_catchup = prog.stop <= now
                    && item.catchup_days.unwrap_or(0) > 0
                    && now - prog.start <= item.catchup_days.unwrap_or(0) * 86_400
                    && item.url.as_deref().is_some_and(|u| super::xtream_from_url(u).is_some());
                if can_catchup && pill(ui, "▶  Catch up", true).clicked() {
                    app.player.open_item(&item, None, None);
                    if let Some(ch) = app.player.playable.clone() {
                        super::live::play_catchup(app, &ch, &prog);
                    }
                    app.pages.guide.details = None;
                }
                if prog.stop > now && !prog.is_live_at(now) {
                    ui.label(dim("Starts at ".to_string() + &clock(prog.start)));
                }
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.button("Close").clicked() {
                        ui.close();
                    }
                });
            });
        });
    if modal.should_close() {
        app.pages.guide.details = None;
    }
}
