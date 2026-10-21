//! Settings.

use super::super::app::App;
use super::super::theme::*;
use super::super::widgets::*;
use crate::db::Group;
use crate::repo;
use eframe::egui;

/// The PIN dialog open in Settings.
pub enum PinDialog {
    /// Choosing a new PIN: typed once, then again to confirm.
    Choose { first: Option<String>, pin: String, error: Option<String> },
    /// The current PIN, before turning the lock off or changing it.
    Verify { then: AfterVerify, pin: String, error: Option<String> },
}

#[derive(Clone, Copy, PartialEq)]
pub enum AfterVerify {
    Disable,
    Change,
}

#[derive(Default)]
pub struct State {
    pub dialog: Option<PinDialog>,
}

fn pin_dialog(app: &mut App, ctx: &egui::Context) {
    let Some(mut dialog) = app.pages.settings.dialog.take() else { return };
    let cooldown = app.lock.cooldown();
    let mut close = false;
    let modal = egui::Modal::new(egui::Id::new("pin-dialog"))
        .frame(egui::Frame::popup(&ctx.global_style()).inner_margin(egui::Margin::same(24)))
        .show(ctx, |ui| {
            ui.set_width(320.0);
            ui.vertical_centered(|ui| {
                let (title, hint) = match &dialog {
                    PinDialog::Choose { first: None, .. } => ("Choose a PIN", "4 to 8 digits"),
                    PinDialog::Choose { first: Some(_), .. } => ("Confirm the PIN", "Type it again"),
                    PinDialog::Verify { .. } => ("Current PIN", "Enter the PIN you use now"),
                };
                ui.label(egui::RichText::new(title).font(bold_font(19.0)).color(TEXT));
                ui.label(dim(hint));
                ui.add_space(14.0);
                let blocked = matches!(dialog, PinDialog::Verify { .. }) && cooldown > std::time::Duration::ZERO;
                let (pin, error) = match &mut dialog {
                    PinDialog::Choose { pin, error, .. } | PinDialog::Verify { pin, error, .. } => (pin, error),
                };
                let submit = super::lock::pin_pad(ui, pin, !blocked);
                ui.add_space(10.0);
                if blocked {
                    ui.label(egui::RichText::new(format!("Too many attempts. Try again in {} s", cooldown.as_secs() + 1)).color(WARNING));
                    ui.ctx().request_repaint_after(std::time::Duration::from_millis(500));
                } else if let Some(e) = error {
                    ui.label(egui::RichText::new(e.as_str()).color(WARNING));
                }
                if submit && !blocked {
                    let typed = std::mem::take(pin);
                    match &mut dialog {
                        PinDialog::Choose { first, error, .. } => {
                            if !crate::lock::valid_pin(&typed) {
                                *error = Some("Use 4 to 8 digits".into());
                            } else if let Some(f) = first.clone() {
                                if f == typed {
                                    let was = app.lock.enabled();
                                    app.lock.enable(&typed);
                                    app.notify(if was { "PIN changed" } else { "App lock is on" });
                                    close = true;
                                } else {
                                    *first = None;
                                    *error = Some("The PINs did not match. Choose it again.".into());
                                }
                            } else {
                                *first = Some(typed);
                                *error = None;
                            }
                        }
                        PinDialog::Verify { then, error, .. } => {
                            if app.lock.verify(&typed) {
                                match then {
                                    AfterVerify::Disable => {
                                        app.lock.disable();
                                        app.notify("App lock is off");
                                        close = true;
                                    }
                                    AfterVerify::Change => {
                                        dialog = PinDialog::Choose { first: None, pin: String::new(), error: None };
                                    }
                                }
                            } else {
                                *error = Some("Wrong PIN".into());
                            }
                        }
                    }
                }
                ui.add_space(8.0);
                if ui.button("Cancel").clicked() {
                    close = true;
                }
            });
        });
    if !close && !modal.should_close() {
        app.pages.settings.dialog = Some(dialog);
    }
}

pub fn show(app: &mut App, ui: &mut egui::Ui) {
    pin_dialog(app, &ui.ctx().clone());
    ui.label(egui::RichText::new("Settings").font(bold_font(22.0)).color(TEXT));
    ui.add_space(10.0);
    let hw_before = app.settings.hardware_decoding;
    egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
        ui.set_max_width(680.0);

        group(ui, "Playback", |ui| {
            let s = &mut app.settings;
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
            let s = &mut app.settings;
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
            let s = &mut app.settings;
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

        group(ui, "Security", |ui| {
            if app.lock.enabled() {
                ui.label(egui::RichText::new("🔒 App lock is on: CAT asks for the PIN when it starts.").color(TEXT_SOFT));
                ui.horizontal(|ui| {
                    if ui.button("Lock now").on_hover_text("Pauses playback and shows the PIN screen (Ctrl+L)").clicked() {
                        app.lock.lock_now();
                    }
                    if ui.button("Change PIN").clicked() {
                        app.pages.settings.dialog = Some(PinDialog::Verify { then: AfterVerify::Change, pin: String::new(), error: None });
                    }
                    if ui.button("Turn off").clicked() {
                        app.pages.settings.dialog = Some(PinDialog::Verify { then: AfterVerify::Disable, pin: String::new(), error: None });
                    }
                });
            } else {
                ui.label(dim("Protect CAT with a PIN. It is asked for each time CAT starts."));
                if ui.button("🔒 Turn on app lock").clicked() {
                    app.pages.settings.dialog = Some(PinDialog::Choose { first: None, pin: String::new(), error: None });
                }
            }
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
