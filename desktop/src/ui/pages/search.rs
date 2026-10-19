//! Instant search across every playlist.

use super::super::app::{App, Section};
use super::super::data::Cached;
use super::super::theme::*;
use super::super::widgets::*;
use crate::db::Group;
use crate::model::{ItemKind, MediaItem};
use crate::repo;
use eframe::egui::{self, Rect, vec2};

#[derive(Default)]
pub struct State {
    pub text: String,
    pub focus: bool,
    results: Cached<(String, u64), Vec<MediaItem>>,
}

pub fn show(app: &mut App, ui: &mut egui::Ui) {
    let db = app.db.clone();
    let version = app.version(Group::Items) + app.version(Group::Favorites);
    ui.label(egui::RichText::new("Search").font(bold_font(22.0)).color(TEXT));
    ui.add_space(6.0);
    let st = &mut app.pages.search;
    let r = search_field(ui, &mut st.text, "Channels, movies and series in all playlists", ui.available_width().min(720.0));
    if st.focus {
        r.request_focus();
        st.focus = false;
    }
    ui.add_space(10.0);
    let text = st.text.trim().to_string();
    if text.is_empty() {
        ui.label(dim("Type to search. Every word matches the start of a word (\"bbc on\" finds \"BBC One\")."));
        return;
    }
    let key = (text.clone(), version);
    let results = st.results.get(&key, || db.read(move |c| repo::search(c, &text, None, None, 300))).cloned().unwrap_or_default();
    if results.is_empty() {
        if !app.pages.search.results.is_loading() {
            ui.label(dim("No matches."));
        }
        return;
    }
    let sources = app.sources_list.clone();
    egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
        for (kind, title) in [(ItemKind::Live, "Channels"), (ItemKind::Movie, "Movies"), (ItemKind::Series, "Series")] {
            let list: Vec<&MediaItem> = results.iter().filter(|i| i.kind == kind).collect();
            if list.is_empty() {
                continue;
            }
            section_title(ui, &format!("{title} ({})", list.len()));
            for item in list {
                let (rect, resp) = row(ui, 54.0, false);
                let logo = Rect::from_min_size(rect.min + vec2(10.0, 6.0), vec2(if kind == ItemKind::Live { 60.0 } else { 28.0 }, 42.0));
                picture(ui, &mut app.images, logo, item.logo.as_deref(), &item.name, 6, kind != ItemKind::Live);
                let x = logo.right() + 12.0;
                text_in(ui, egui::pos2(x, rect.top() + 8.0), &item.name, bold_font(14.5), TEXT, rect.right() - x - 12.0);
                let src = sources.iter().find(|s| s.id == item.source_id).map_or("", |s| s.name.as_str());
                let meta = [Some(src.to_string()), item.year.clone()].into_iter().flatten().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" · ");
                text_in(ui, egui::pos2(x, rect.top() + 30.0), &meta, font(12.0), TEXT_DIM, rect.right() - x - 12.0);
                if resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
                    app.settings.active_source_id = Some(item.source_id);
                    match kind {
                        ItemKind::Live => super::play_item(app, item, None, false),
                        ItemKind::Movie => {
                            app.go(Section::Movies);
                            app.pages.movies.open_details(item.clone());
                        }
                        ItemKind::Series => {
                            app.go(Section::Series);
                            app.pages.series.open_details(item.clone());
                        }
                    }
                }
            }
            ui.add_space(8.0);
        }
    });
}
