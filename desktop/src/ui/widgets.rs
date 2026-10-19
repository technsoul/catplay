//! Small reusable pieces of the interface.

use super::theme::*;
use crate::images::Images;
use eframe::egui::{self, Align2, Color32, CornerRadius, Rect, Response, Sense, Stroke, StrokeKind, Ui, Vec2, pos2, vec2};

/// A full-width clickable row with hover and selected states.
pub fn row(ui: &mut Ui, height: f32, selected: bool) -> (Rect, Response) {
    let (rect, resp) = ui.allocate_exact_size(vec2(ui.available_width(), height), Sense::click());
    let fill = if selected {
        RAISED
    } else if resp.hovered() {
        SURFACE_HIGH
    } else {
        Color32::TRANSPARENT
    };
    ui.painter().rect_filled(rect, CornerRadius::same(R_TILE), fill);
    if selected {
        let bar = Rect::from_min_size(rect.left_top() + vec2(0.0, 8.0), vec2(3.0, rect.height() - 16.0));
        ui.painter().rect_filled(bar, CornerRadius::same(2), ACCENT);
    }
    (rect, resp)
}

/// Text cut with an ellipsis to fit `width`.
pub fn text_in(ui: &Ui, pos: egui::Pos2, text: &str, font: egui::FontId, color: Color32, width: f32) -> Rect {
    let mut job = egui::text::LayoutJob::simple_singleline(text.to_string(), font, color);
    job.wrap = egui::text::TextWrapping::truncate_at_width(width.max(4.0));
    let galley = ui.fonts_mut(|f| f.layout_job(job));
    let rect = Rect::from_min_size(pos, galley.size());
    ui.painter().galley(pos, galley, color);
    rect
}

/// Logo or poster from `url`, fitted into `rect`; a lettered tile until it loads.
pub fn picture(ui: &Ui, images: &mut Images, rect: Rect, url: Option<&str>, name: &str, radius: u8, cover: bool) {
    let p = ui.painter();
    let tex = url.and_then(|u| images.get(u));
    match tex {
        Some(t) => {
            p.rect_filled(rect, CornerRadius::same(radius), SURFACE_HIGH);
            let size = t.size_vec2();
            let scale = if cover { (rect.width() / size.x).max(rect.height() / size.y) } else { (rect.width() / size.x).min(rect.height() / size.y) };
            let shown = size * scale;
            let mut img = Rect::from_center_size(rect.center(), shown);
            let mut uv = Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0));
            if cover {
                // Crop to the rect.
                let vis = img.intersect(rect);
                uv = Rect::from_min_max(
                    pos2((vis.min.x - img.min.x) / shown.x, (vis.min.y - img.min.y) / shown.y),
                    pos2((vis.max.x - img.min.x) / shown.x, (vis.max.y - img.min.y) / shown.y),
                );
                img = vis;
            }
            egui::Image::new((t.id(), img.size())).uv(uv).corner_radius(CornerRadius::same(radius)).paint_at(ui, img);
        }
        None => {
            p.rect_filled(rect, CornerRadius::same(radius), SHEET_HIGH);
            let letter: String = name.chars().find(|c| c.is_alphanumeric()).map(|c| c.to_uppercase().collect()).unwrap_or_default();
            p.text(rect.center(), Align2::CENTER_CENTER, letter, bold_font((rect.height() * 0.4).clamp(10.0, 34.0)), TEXT_DIM);
        }
    }
}

pub fn progress_bar(ui: &Ui, rect: Rect, fraction: f32, color: Color32) {
    let p = ui.painter();
    p.rect_filled(rect, CornerRadius::same(2), Color32::from_white_alpha(30));
    let mut fill = rect;
    fill.set_width(rect.width() * fraction.clamp(0.0, 1.0));
    p.rect_filled(fill, CornerRadius::same(2), color);
}

/// A rounded button; `primary` uses the accent color.
pub fn pill(ui: &mut Ui, label: &str, primary: bool) -> Response {
    let font = bold_font(14.0);
    let galley = ui.fonts_mut(|f| f.layout_no_wrap(label.to_string(), font, TEXT));
    let size = vec2(galley.size().x + 32.0, 36.0);
    let (rect, resp) = ui.allocate_exact_size(size, Sense::click());
    let fill = match (primary, resp.hovered()) {
        (true, false) => ACCENT,
        (true, true) => ACCENT_BRIGHT,
        (false, false) => SURFACE_HIGH,
        (false, true) => RAISED,
    };
    ui.painter().rect(rect, CornerRadius::same(18), fill, Stroke::new(1.0, if primary { Color32::TRANSPARENT } else { BORDER }), StrokeKind::Inside);
    ui.painter().galley(rect.center() - galley.size() / 2.0, galley, TEXT);
    resp.on_hover_cursor(egui::CursorIcon::PointingHand)
}

/// Round icon button showing a symbol.
pub fn icon_button(ui: &mut Ui, icon: &str, size: f32, tip: &str) -> Response {
    let (rect, resp) = ui.allocate_exact_size(Vec2::splat(size), Sense::click());
    let fill = if resp.hovered() { RAISED } else { Color32::from_black_alpha(90) };
    ui.painter().circle_filled(rect.center(), size / 2.0, fill);
    ui.painter().text(rect.center(), Align2::CENTER_CENTER, icon, font(size * 0.45), TEXT);
    resp.on_hover_text(tip).on_hover_cursor(egui::CursorIcon::PointingHand)
}

pub fn section_title(ui: &mut Ui, text: &str) {
    ui.add_space(4.0);
    ui.label(egui::RichText::new(text).font(bold_font(17.0)).color(TEXT));
    ui.add_space(2.0);
}

pub fn dim(text: impl Into<String>) -> egui::RichText {
    egui::RichText::new(text.into()).color(TEXT_DIM)
}

/// A soft panel background for a region.
pub fn panel_frame() -> egui::Frame {
    egui::Frame::new().fill(SURFACE).corner_radius(CornerRadius::same(R_CARD)).inner_margin(egui::Margin::same(10))
}

/// A search field with a placeholder.
pub fn search_field(ui: &mut Ui, text: &mut String, hint: &str, width: f32) -> Response {
    ui.add(egui::TextEdit::singleline(text).hint_text(format!("🔍  {hint}")).desired_width(width).margin(vec2(10.0, 8.0)))
}

/// Centered message for empty states.
pub fn empty_state(ui: &mut Ui, title: &str, body: &str) {
    ui.vertical_centered(|ui| {
        ui.add_space(ui.available_height() * 0.3);
        ui.label(egui::RichText::new(title).font(bold_font(18.0)).color(TEXT));
        ui.label(dim(body));
    });
}

pub fn spinner_label(ui: &mut Ui, text: &str) {
    ui.horizontal(|ui| {
        ui.add(egui::Spinner::new().size(16.0).color(TEXT_DIM));
        ui.label(dim(text));
    });
}

/// "21:05" in local time.
pub fn clock(t: i64) -> String {
    chrono::DateTime::from_timestamp(t, 0)
        .map(|d| d.with_timezone(&chrono::Local).format("%H:%M").to_string())
        .unwrap_or_default()
}

pub fn duration_text(secs: f64) -> String {
    let s = secs.max(0.0) as i64;
    if s >= 3600 { format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60) } else { format!("{}:{:02}", s / 60, s % 60) }
}
