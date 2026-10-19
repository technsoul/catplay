//! Settings.

use super::super::app::App;
use super::super::theme::*;
use super::super::widgets::*;
use crate::db::Group;
use crate::repo;
use eframe::egui;

pub fn show(app: &mut App, ui: &mut egui::Ui) {
    ui.label(egui::RichText::new("Settings").font(bold_font(22.0)).color(TEXT));
    ui.add_space(10.0);
    let hw_before = app.settings.hardware_decoding;
    egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
        ui.set_max_width(680.0);
        let s = &mut app.settings;

        group(ui, "Playback", |ui| {
            ui.checkbox(&mut s.hardware_decoding, "Hardware decoding (uses the GPU; much cooler and quieter)");
            ui.horizontal(|ui| {
                ui.label("Buffer");
                ui.add(egui::Slider::new(&mut s.cache_seconds, 5..=120).suffix(" s"));
            });
            ui.horizontal(|ui| {
                ui.label("Xtream live format");
                ui.selectable_value(&mut s.live_format, "ts".into(), "MPEG-TS");
                ui.selectable_value(&mut s.live_format, "m3u8".into(), "HLS (m3u8)");
            });
            ui.checkbox(&mut s.autoplay_last_channel, "Play the last channel when CAT starts");
            ui.horizontal(|ui| {
                ui.label("User agent");
                ui.add(egui::TextEdit::singleline(&mut s.user_agent).hint_text(crate::http::DEFAULT_USER_AGENT).desired_width(360.0));
            });
        });

        group(ui, "Updates", |ui| {
            ui.horizontal(|ui| {
                ui.label("Refresh playlists every");
                ui.add(egui::Slider::new(&mut s.auto_refresh_hours, 0..=168).suffix(" h"));
            });
            ui.horizontal(|ui| {
                ui.label("Refresh TV guides every");
                ui.add(egui::Slider::new(&mut s.epg_refresh_hours, 0..=72).suffix(" h"));
            });
            ui.label(dim("0 turns automatic refreshing off."));
        });

        group(ui, "TV guide", |ui| {
            ui.horizontal(|ui| {
                ui.label("Keep past programmes for");
                ui.add(egui::Slider::new(&mut s.epg_past_hours, 0..=168).suffix(" h"));
            });
            ui.horizontal(|ui| {
                ui.label("Load days ahead");
                ui.add(egui::Slider::new(&mut s.epg_future_days, 1..=14).suffix(" days"));
            });
            ui.label(dim("Changes apply at the next guide refresh."));
        });

        group(ui, "History", |ui| {
            if ui.button("Clear watch history").clicked() {
                app.db.write(&[Group::History], repo::clear_history);
                app.toast = Some(("History cleared".into(), std::time::Instant::now()));
            }
        });

        group(ui, "About", |ui| {
            ui.label(format!("CAT {} — Rust desktop build", env!("CARGO_PKG_VERSION")));
            let mpv = match &app.player.mpv {
                Some(m) => m.get_string("mpv-version").unwrap_or_else(|| "libmpv".into()),
                None => app.player.unavailable.clone().unwrap_or_default(),
            };
            ui.label(dim(mpv));
            if let Some(m) = &app.player.mpv
                && let Some(h) = m.get_string("hwdec-current").filter(|h| !h.is_empty() && h != "no")
            {
                ui.label(dim(format!("Hardware decoder in use: {h}")));
            }
            let dir = app.db.path.parent().map(|p| p.to_path_buf()).unwrap_or_default();
            ui.horizontal(|ui| {
                ui.label(dim(format!("Data: {}", dir.display())));
                if ui.small_button("Open").clicked() {
                    let _ = open::that(&dir);
                }
            });
        });
    });
    if app.settings.hardware_decoding != hw_before
        && let Some(m) = &app.player.mpv
    {
        m.set("hwdec", if app.settings.hardware_decoding { "auto-safe" } else { "no" });
    }
}

fn group(ui: &mut egui::Ui, title: &str, add: impl FnOnce(&mut egui::Ui)) {
    panel_frame().show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.label(egui::RichText::new(title).font(bold_font(16.0)).color(TEXT));
        ui.add_space(4.0);
        add(ui);
    });
    ui.add_space(10.0);
}
