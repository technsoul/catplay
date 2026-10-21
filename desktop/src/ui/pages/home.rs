//! Home: continue watching, recent channels and favorites.

use super::super::app::{App, Section};
use super::super::data::Cached;
use super::super::theme::*;
use super::super::widgets::*;
use crate::db::Group;
use crate::model::{HistoryEntry, ItemKind, MediaItem};
use crate::repo::{self, ItemQuery};
use eframe::egui::{self, Align2, CornerRadius, Rect, Sense, vec2};

#[derive(Default)]
pub struct State {
    continue_watching: Cached<u64, Vec<HistoryEntry>>,
    recent: Cached<u64, Vec<HistoryEntry>>,
    favorites: Cached<(i64, u64), Vec<Vec<MediaItem>>>,
}

pub fn show(app: &mut App, ui: &mut egui::Ui) {
    let db = app.db.clone();
    let hv = app.version(Group::History);
    let Some(source) = app.active_source().cloned() else { return };
    let favs_key = (source.id, app.version(Group::Favorites) + app.version(Group::Items));

    let st = &mut app.pages.home;
    let cont = st.continue_watching.get(&hv, || db.read(|c| repo::continue_watching(c, 30))).cloned().unwrap_or_default();
    let recent = st.recent.get(&hv, || db.read(|c| repo::recent_channels(c, 20))).cloned().unwrap_or_default();
    let favs = st
        .favorites
        .get(&favs_key, || {
            db.read(move |c| {
                ItemKind::ALL
                    .iter()
                    .map(|k| repo::items(c, &ItemQuery { favorites_only: true, ..ItemQuery::new(*k, source.id) }, 0, 40))
                    .collect()
            })
        })
        .cloned()
        .unwrap_or_default();

    egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
        ui.label(egui::RichText::new(greeting()).font(bold_font(28.0)).color(TEXT));
        ui.label(dim(format!(
            "{} · {} channels · {} movies · {} series",
            source.name, source.live_count, source.movie_count, source.series_count
        )));
        ui.add_space(18.0);

        if cont.is_empty() && recent.is_empty() && favs.iter().all(Vec::is_empty) {
            panel_frame().show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.label(egui::RichText::new("Start watching").font(bold_font(17.0)).color(TEXT));
                ui.label(dim("Channels you watch, movies you start and favorites you pick show up here."));
                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    if pill(ui, "Live TV", true).clicked() {
                        app.go(Section::Live);
                    }
                    if pill(ui, "Movies", false).clicked() {
                        app.go(Section::Movies);
                    }
                    if pill(ui, "Series", false).clicked() {
                        app.go(Section::Series);
                    }
                });
            });
        }

        if !cont.is_empty() {
            section_title(ui, "Continue watching");
            history_row(app, ui, &cont, false);
        }
        if !recent.is_empty() {
            section_title(ui, "Recent channels");
            history_row(app, ui, &recent, true);
        }
        for (items, title) in favs.iter().zip(["Favorite channels", "Favorite movies", "Favorite series"]) {
            if !items.is_empty() {
                section_title(ui, title);
                item_row(app, ui, items);
            }
        }
    });
}

fn greeting() -> &'static str {
    use chrono::Timelike;
    match chrono::Local::now().hour() {
        5..=11 => "Good morning",
        12..=17 => "Good afternoon",
        _ => "Good evening",
    }
}

fn history_row(app: &mut App, ui: &mut egui::Ui, list: &[HistoryEntry], channels: bool) {
    let (w, h) = if channels { (150.0, 112.0) } else { (250.0, 150.0) };
    egui::ScrollArea::horizontal().id_salt(if channels { "recent" } else { "continue" }).show(ui, |ui| {
        ui.horizontal(|ui| {
            for e in list {
                let (rect, resp) = ui.allocate_exact_size(vec2(w, h), Sense::click());
                let hover = resp.hovered();
                let p = ui.painter();
                p.rect_filled(rect, CornerRadius::same(R_CARD), if hover { RAISED } else { SURFACE_HIGH });
                let art = Rect::from_min_size(rect.min + vec2(10.0, 10.0), vec2(w - 20.0, h - 50.0));
                picture(ui, &mut app.images, art, e.logo.as_deref(), &e.name, R_TILE, !channels);
                if !channels {
                    let bar = Rect::from_min_size(art.left_bottom() + vec2(0.0, -4.0), vec2(art.width(), 4.0));
                    progress_bar(ui, bar, e.progress(), ACCENT);
                }
                text_in(ui, rect.left_bottom() + vec2(10.0, -32.0), &e.name, font(13.5), TEXT, w - 20.0);
                if hover {
                    ui.painter().text(art.center(), Align2::CENTER_CENTER, "▶", font(28.0), TEXT);
                }
                // Remove from the row.
                let x = Rect::from_center_size(rect.right_top() + vec2(-18.0, 18.0), vec2(24.0, 24.0));
                let xr = ui.interact(x, ui.id().with(("remove", e.source_id, &e.key)), Sense::click());
                if hover || xr.hovered() {
                    ui.painter().circle_filled(x.center(), 12.0, if xr.hovered() { RAISED } else { egui::Color32::from_black_alpha(160) });
                    ui.painter().text(x.center(), Align2::CENTER_CENTER, "✖", font(11.0), TEXT);
                }
                let tip = if channels { "Remove from recent channels" } else { "Remove from Continue watching" };
                if xr.on_hover_text(tip).clicked() {
                    let (sid, key) = (e.source_id, e.key.clone());
                    app.db.write(&[Group::History], move |c| repo::remove_history(c, sid, &key));
                } else if resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
                    super::play_history(app, e);
                }
            }
        });
    });
    ui.add_space(12.0);
}

fn item_row(app: &mut App, ui: &mut egui::Ui, items: &[MediaItem]) {
    let live = items.first().is_some_and(|i| i.kind == ItemKind::Live);
    let (w, h) = if live { (150.0, 112.0) } else { (140.0, 236.0) };
    egui::ScrollArea::horizontal().id_salt(("favs", items.first().map(|i| i.kind.index()))).show(ui, |ui| {
        ui.horizontal(|ui| {
            for it in items {
                let (rect, resp) = ui.allocate_exact_size(vec2(w, h), Sense::click());
                let p = ui.painter();
                p.rect_filled(rect, CornerRadius::same(R_CARD), if resp.hovered() { RAISED } else { SURFACE_HIGH });
                let art = Rect::from_min_size(rect.min + vec2(8.0, 8.0), vec2(w - 16.0, h - 44.0));
                picture(ui, &mut app.images, art, it.logo.as_deref(), &it.name, R_TILE, !live);
                text_in(ui, rect.left_bottom() + vec2(10.0, -30.0), &it.name, font(13.5), TEXT, w - 20.0);
                if resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
                    match it.kind {
                        ItemKind::Live => super::play_item(app, it, None, false),
                        kind => {
                            let section = if kind == ItemKind::Movie { Section::Movies } else { Section::Series };
                            app.go(section);
                            let st = if kind == ItemKind::Movie { &mut app.pages.movies } else { &mut app.pages.series };
                            st.open_details(it.clone());
                        }
                    }
                }
            }
        });
    });
    ui.add_space(12.0);
}
