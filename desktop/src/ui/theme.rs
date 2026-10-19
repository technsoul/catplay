//! CAT's look: deep navy ground, flat translucent panels, white text and the
//! logo blue as the one accent. No blur or animated backdrops: they are what
//! kept the GPU busy in the Flutter app.

use eframe::egui::{
    self, Color32, CornerRadius, FontData, FontDefinitions, FontFamily, FontId, Margin, Stroke, TextStyle, Visuals,
};

pub const BG: Color32 = Color32::from_rgb(0x0B, 0x11, 0x20);
pub const SHADE: Color32 = Color32::from_rgb(0x08, 0x0C, 0x16);
pub const SHEET: Color32 = Color32::from_rgb(0x14, 0x1C, 0x2E);
pub const SHEET_HIGH: Color32 = Color32::from_rgb(0x1D, 0x28, 0x40);
pub const SURFACE: Color32 = Color32::from_rgba_premultiplied(10, 10, 10, 10);
pub const SURFACE_HIGH: Color32 = Color32::from_rgba_premultiplied(15, 15, 15, 15);
pub const RAISED: Color32 = Color32::from_rgba_premultiplied(41, 41, 41, 41);
pub const BORDER: Color32 = Color32::from_rgba_premultiplied(26, 26, 26, 26);

pub const TEXT: Color32 = Color32::from_rgb(0xF3, 0xF6, 0xFB);
pub const TEXT_SOFT: Color32 = Color32::from_rgb(0xC4, 0xCD, 0xDD);
pub const TEXT_DIM: Color32 = Color32::from_rgb(0x8E, 0x9A, 0xB0);

pub const ACCENT: Color32 = Color32::from_rgb(0x1E, 0x7B, 0xF2);
pub const ACCENT_BRIGHT: Color32 = Color32::from_rgb(0x5A, 0xA2, 0xFF);
pub const LIVE: Color32 = Color32::from_rgb(0xE5, 0x48, 0x4D);
pub const SUCCESS: Color32 = Color32::from_rgb(0x3D, 0xD6, 0x8C);
pub const WARNING: Color32 = Color32::from_rgb(0xFF, 0x9A, 0x5C);
pub const STAR: Color32 = Color32::from_rgb(0xFF, 0xC2, 0x4D);

pub const R_CARD: u8 = 14;
pub const R_TILE: u8 = 10;

pub fn bold() -> FontFamily {
    FontFamily::Name("bold".into())
}

pub fn font(size: f32) -> FontId {
    FontId::new(size, FontFamily::Proportional)
}

pub fn bold_font(size: f32) -> FontId {
    FontId::new(size, bold())
}

fn weighted(data: &'static [u8], weight: f32) -> FontData {
    let mut f = FontData::from_static(data);
    f.tweak.coords = egui::epaint::text::VariationCoords::new([(b"wght", weight)]);
    f
}

pub fn install(ctx: &egui::Context) {
    static SANS: &[u8] = include_bytes!("../../assets/fonts/NotoSans.ttf");
    static ARABIC: &[u8] = include_bytes!("../../assets/fonts/NotoSansArabic.ttf");

    let mut fonts = FontDefinitions::default();
    // egui's own fonts stay as fallbacks for symbols and emoji.
    fonts.font_data.insert("sans".into(), weighted(SANS, 420.0).into());
    fonts.font_data.insert("arabic".into(), weighted(ARABIC, 420.0).into());
    fonts.font_data.insert("sans-bold".into(), weighted(SANS, 640.0).into());
    fonts.font_data.insert("arabic-bold".into(), weighted(ARABIC, 640.0).into());
    let prop = fonts.families.entry(FontFamily::Proportional).or_default();
    prop.insert(0, "sans".into());
    prop.insert(1, "arabic".into());
    // Arrows and shapes (← ● ↑) only exist in the monospace font.
    prop.push("Hack".into());
    let mut bold_list = vec!["sans-bold".to_string(), "arabic-bold".to_string()];
    bold_list.extend(fonts.families[&FontFamily::Proportional].iter().skip(2).cloned());
    fonts.families.insert(bold(), bold_list);
    ctx.set_fonts(fonts);

    ctx.options_mut(|o| o.theme_preference = egui::ThemePreference::Dark);
    ctx.all_styles_mut(|s| {
        s.text_styles = [
            (TextStyle::Small, font(12.0)),
            (TextStyle::Body, font(14.5)),
            (TextStyle::Button, font(14.5)),
            (TextStyle::Heading, bold_font(22.0)),
            (TextStyle::Monospace, FontId::monospace(13.0)),
        ]
        .into();
        s.spacing.item_spacing = egui::vec2(8.0, 8.0);
        s.spacing.button_padding = egui::vec2(14.0, 8.0);
        s.spacing.interact_size.y = 34.0;
        s.spacing.window_margin = Margin::same(18);
        s.spacing.menu_margin = Margin::same(8);
        s.spacing.scroll.bar_width = 8.0;
        s.spacing.scroll.floating = true;
        s.interaction.selectable_labels = false;

        let mut v = Visuals::dark();
        v.panel_fill = BG;
        v.window_fill = SHEET;
        v.extreme_bg_color = SHADE;
        v.faint_bg_color = SURFACE_HIGH;
        v.code_bg_color = SHEET_HIGH;
        v.window_stroke = Stroke::new(1.0, BORDER);
        v.window_corner_radius = CornerRadius::same(18);
        v.menu_corner_radius = CornerRadius::same(12);
        v.window_shadow = egui::Shadow { offset: [0, 8], blur: 24, spread: 0, color: Color32::from_black_alpha(110) };
        v.popup_shadow = egui::Shadow { offset: [0, 4], blur: 16, spread: 0, color: Color32::from_black_alpha(90) };
        v.selection.bg_fill = ACCENT;
        v.selection.stroke = Stroke::new(1.0, TEXT);
        v.hyperlink_color = ACCENT_BRIGHT;
        v.override_text_color = None;
        for (w, fill, text) in [
            (&mut v.widgets.noninteractive, Color32::TRANSPARENT, TEXT_SOFT),
            (&mut v.widgets.inactive, SURFACE_HIGH, TEXT),
            (&mut v.widgets.hovered, RAISED, TEXT),
            (&mut v.widgets.active, ACCENT, TEXT),
            (&mut v.widgets.open, RAISED, TEXT),
        ] {
            w.bg_fill = fill;
            w.weak_bg_fill = fill;
            w.bg_stroke = Stroke::NONE;
            w.fg_stroke = Stroke::new(1.5, text);
            w.corner_radius = CornerRadius::same(R_TILE);
            w.expansion = 0.0;
        }
        v.widgets.noninteractive.bg_stroke = Stroke::new(1.0, BORDER);
        v.widgets.inactive.bg_stroke = Stroke::new(1.0, BORDER);
        s.visuals = v;
    });
}
