//! Downloads: progress, pause/resume, play and delete saved files.

use super::super::app::App;
use super::super::theme::*;
use super::super::widgets::*;
use crate::downloads::{Download, Status, format_bytes};
use crate::model::Playable;
use eframe::egui::{self, Rect, vec2};

#[derive(Default)]
pub struct State {
    confirm_delete: Option<String>,
}

pub fn show(app: &mut App, ui: &mut egui::Ui) {
    let list = app.downloads.list();
    ui.horizontal(|ui| {
        ui.label(egui::RichText::new("Downloads").font(bold_font(22.0)).color(TEXT));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if ui.button("📂 Open folder").clicked() {
                let _ = std::fs::create_dir_all(&app.downloads.dir);
                let _ = open::that(&app.downloads.dir);
            }
        });
    });
    ui.add(egui::Label::new(dim(format!("Saved in {}", app.downloads.dir.display()))).truncate());
    ui.add_space(10.0);
    if list.is_empty() {
        empty_state(ui, "No downloads yet", "Use “Download” on a movie or an episode to watch it offline.");
        return;
    }
    // Newest first.
    let mut list = list;
    list.sort_by_key(|d| std::cmp::Reverse(d.created_at));
    egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
        for d in &list {
            row_ui(app, ui, d);
            ui.add_space(6.0);
        }
    });
}

fn row_ui(app: &mut App, ui: &mut egui::Ui, d: &Download) {
    let id = d.id();
    panel_frame().show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.horizontal(|ui| {
            let art = ui.allocate_space(vec2(52.0, 74.0)).1;
            picture(ui, &mut app.images, art, d.logo.as_deref(), &d.title, 8, true);
            ui.add_space(8.0);
            ui.vertical(|ui| {
                ui.set_width((ui.available_width() - 260.0).max(200.0));
                ui.add(egui::Label::new(egui::RichText::new(&d.title).font(bold_font(15.0)).color(TEXT)).truncate());
                if let Some(s) = &d.subtitle {
                    ui.label(dim(s));
                }
                let size = |b: u64| format_bytes(b as f64);
                let line = match d.status {
                    Status::Queued => "Waiting…".to_string(),
                    Status::Downloading => match d.total {
                        Some(t) => format!("{} of {} · {}/s", size(d.received), size(t), format_bytes(d.speed)),
                        None => format!("{} · {}/s", size(d.received), format_bytes(d.speed)),
                    },
                    Status::Paused => format!("Paused · {}{}", size(d.received), d.total.map(|t| format!(" of {}", size(t))).unwrap_or_default()),
                    Status::Done => format!("Downloaded · {}", size(d.received)),
                    Status::Failed => d.error.clone().unwrap_or_else(|| "Failed".into()),
                };
                let color = match d.status {
                    Status::Failed => WARNING,
                    Status::Done => SUCCESS,
                    _ => TEXT_DIM,
                };
                ui.label(egui::RichText::new(line).color(color).font(font(13.0)));
                if !matches!(d.status, Status::Done) {
                    let bar = ui.allocate_space(vec2(ui.available_width(), 4.0)).1;
                    let color = if d.status == Status::Downloading { ACCENT } else { TEXT_DIM };
                    progress_bar(ui, Rect::from_min_size(bar.min, bar.size()), d.fraction().unwrap_or(0.0), color);
                }
            });
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if app.pages.downloads.confirm_delete.as_deref() == Some(&id) {
                    if ui.button("Cancel").clicked() {
                        app.pages.downloads.confirm_delete = None;
                    }
                    if ui.button(egui::RichText::new("Delete").color(LIVE)).clicked() {
                        app.pages.downloads.confirm_delete = None;
                        app.downloads.remove(&id);
                    }
                    return;
                }
                if ui.button("🗑").on_hover_text("Delete the file").clicked() {
                    app.pages.downloads.confirm_delete = Some(id.clone());
                }
                match d.status {
                    Status::Queued | Status::Downloading => {
                        if ui.button("⏸ Pause").clicked() {
                            app.downloads.pause(&id);
                        }
                    }
                    Status::Paused | Status::Failed => {
                        let label = if d.status == Status::Failed { "↻ Retry" } else { "▶ Resume" };
                        if ui.button(label).clicked() {
                            app.downloads.resume(&id);
                        }
                    }
                    Status::Done => {
                        if ui.button("📂").on_hover_text("Show in folder").clicked() {
                            let dir = std::path::Path::new(&d.path).parent().map(|p| p.to_path_buf()).unwrap_or_default();
                            let _ = open::that(dir);
                        }
                        if pill(ui, "▶  Play", true).clicked() {
                            play(app, d);
                        }
                    }
                }
            });
        });
    });
}

fn play(app: &mut App, d: &Download) {
    let p = Playable {
        source_id: d.source_id,
        key: d.key.clone(),
        kind: d.kind,
        title: d.title.clone(),
        subtitle: d.subtitle.clone(),
        url: d.url.clone(),
        logo: d.logo.clone(),
        headers: d.headers.clone(),
        epg_id: None,
        catchup_days: None,
        resume_ms: None,
    };
    // The player picks the local file for downloaded items.
    app.player.open(p, None);
    app.full_player = true;
}
