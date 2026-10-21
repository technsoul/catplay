//! The PIN screen, and the PIN pad also used by the Settings dialogs.

use super::super::app::App;
use super::super::theme::*;
use super::super::widgets::*;
use crate::lock::{PIN_MAX, PIN_MIN};
use eframe::egui::{self, Align2, CornerRadius, Key, Rect, Sense, Stroke, StrokeKind, vec2};
use std::time::Duration;

#[derive(Default)]
pub struct State {
    pin: String,
    error: Option<String>,
}

/// Dots for the digits typed so far, then a 3×4 keypad. Digits, Backspace
/// and Enter also work from the keyboard. Returns true when Enter (or the
/// last allowed digit) submits the PIN.
pub fn pin_pad(ui: &mut egui::Ui, pin: &mut String, enabled: bool) -> bool {
    let mut submit = false;
    if enabled {
        ui.input(|i| {
            for e in &i.events {
                match e {
                    egui::Event::Text(t) => {
                        for c in t.chars().filter(char::is_ascii_digit) {
                            if pin.len() < PIN_MAX {
                                pin.push(c);
                            }
                        }
                    }
                    egui::Event::Key { key: Key::Backspace, pressed: true, .. } => {
                        pin.pop();
                    }
                    egui::Event::Key { key: Key::Enter, pressed: true, .. } => submit = true,
                    _ => {}
                }
            }
        });
    }

    // Dots.
    let shown = pin.len().max(PIN_MIN);
    let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 28.0), Sense::hover());
    let step = 26.0;
    let x0 = rect.center().x - (shown as f32 - 1.0) * step / 2.0;
    for i in 0..shown {
        let c = egui::pos2(x0 + i as f32 * step, rect.center().y);
        if i < pin.len() {
            ui.painter().circle_filled(c, 7.0, TEXT);
        } else {
            ui.painter().circle_stroke(c, 7.0, Stroke::new(1.5, TEXT_DIM));
        }
    }
    ui.add_space(14.0);

    // Keypad.
    let key = 64.0;
    let gap = 14.0;
    let width = key * 3.0 + gap * 2.0;
    let (pad, _) = ui.allocate_exact_size(vec2(ui.available_width(), key * 4.0 + gap * 3.0), Sense::hover());
    let left = pad.center().x - width / 2.0;
    let labels = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "OK"];
    for (i, label) in labels.iter().enumerate() {
        let (r, c) = (i / 3, i % 3);
        let rect = Rect::from_min_size(egui::pos2(left + c as f32 * (key + gap), pad.top() + r as f32 * (key + gap)), vec2(key, key));
        let resp = ui.interact(rect, ui.id().with(("pin-key", i)), if enabled { Sense::click() } else { Sense::hover() });
        let ok = *label == "OK";
        let fill = match (ok, resp.hovered() && enabled) {
            (true, false) => ACCENT,
            (true, true) => ACCENT_BRIGHT,
            (false, true) => RAISED,
            (false, false) => SURFACE_HIGH,
        };
        ui.painter().rect(rect, CornerRadius::same(32), fill, Stroke::new(1.0, BORDER), StrokeKind::Inside);
        let text = if *label == "⌫" { "←" } else { label };
        ui.painter().text(rect.center(), Align2::CENTER_CENTER, text, bold_font(if ok { 16.0 } else { 22.0 }), TEXT);
        if resp.clicked() {
            match *label {
                "⌫" => {
                    pin.pop();
                }
                "OK" => submit = true,
                d if pin.len() < PIN_MAX => pin.push_str(d),
                _ => {}
            }
        }
    }
    submit || pin.len() == PIN_MAX
}

pub fn show(app: &mut App, ui: &mut egui::Ui) {
    let cooldown = app.lock.cooldown();
    let blocked = cooldown > Duration::ZERO;
    let st = &mut app.pages.lock;
    ui.vertical_centered(|ui| {
        ui.add_space((ui.available_height() - 560.0).max(20.0) / 2.0);
        ui.label(egui::RichText::new("CAT").font(bold_font(40.0)).color(TEXT));
        ui.add_space(6.0);
        ui.label(egui::RichText::new("Enter PIN").font(bold_font(20.0)).color(TEXT_SOFT));
        ui.add_space(22.0);
        ui.set_max_width(320.0);
        let submit = pin_pad(ui, &mut st.pin, !blocked);
        if submit && !blocked && st.pin.len() >= PIN_MIN {
            if app.lock.unlock(&st.pin) {
                st.error = None;
            } else {
                st.error = Some("Wrong PIN".into());
            }
            st.pin.clear();
        }
        ui.add_space(16.0);
        let msg = if blocked {
            ui.ctx().request_repaint_after(Duration::from_millis(500));
            Some(format!("Too many attempts. Try again in {} s", cooldown.as_secs() + 1))
        } else {
            st.error.clone()
        };
        if let Some(m) = msg {
            ui.label(egui::RichText::new(m).color(WARNING));
        } else {
            ui.label(dim("Type the PIN or click the keys."));
        }
    });
}
