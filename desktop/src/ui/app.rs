//! The application: sidebar, pages, the shared video surface and the
//! full-screen player.

use super::data::Cached;
use super::pages;
use super::theme::{self, *};
use super::widgets::*;
use crate::db::{Db, Group};
use crate::images::Images;
use crate::import::{Importer, Scope};
use crate::model::{ItemKind, Source};
use crate::player::render::{GetProcAddress, VideoOutput};
use crate::player::{Phase, Player};
use crate::repo;
use crate::settings::Settings;
use eframe::egui::{self, Align2, Color32, CornerRadius, Key, Rect, Sense, Vec2, vec2};
use eframe::glow;
use raw_window_handle::{HasDisplayHandle, RawDisplayHandle};
use std::sync::Arc;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Section {
    Home,
    Live,
    Guide,
    Movies,
    Series,
    Search,
    Playlists,
    Settings,
}

impl Section {
    const NAV: [(Section, &'static str, &'static str); 8] = [
        (Section::Home, "🏠", "Home"),
        (Section::Live, "📺", "Live TV"),
        (Section::Guide, "☰", "TV Guide"),
        (Section::Movies, "🎬", "Movies"),
        (Section::Series, "🎞", "Series"),
        (Section::Search, "🔍", "Search"),
        (Section::Playlists, "📂", "Playlists"),
        (Section::Settings, "⚙", "Settings"),
    ];
}

pub struct App {
    pub db: Db,
    pub importer: Importer,
    pub player: Player,
    pub images: Images,
    pub settings: Settings,
    saved_settings: Settings,
    settings_changed_at: Option<Instant>,
    pub section: Section,
    sources: Cached<u64, Vec<Source>>,
    pub sources_list: Vec<Source>,
    pub full_player: bool,
    gl: Option<Arc<glow::Context>>,
    get_proc: Option<GetProcAddress>,
    display: Option<RawDisplayHandle>,
    video: Option<VideoOutput>,
    video_error: Option<String>,
    /// Last time the mouse moved over the player (controls auto-hide).
    pointer_moved_at: Instant,
    started: Instant,
    started_refresh: bool,
    autoplay_done: bool,
    pub toast: Option<(String, Instant)>,
    pub pages: pages::Pages,
}

impl App {
    pub fn new(cc: &eframe::CreationContext<'_>, db: Db, importer: Importer, images: Images, settings: Settings) -> Self {
        super::set_context(&cc.egui_ctx);
        theme::install(&cc.egui_ctx);
        let display = cc.display_handle().ok().map(|h| h.as_raw());
        let player = Player::new(db.clone(), &settings);
        Self {
            player,
            db,
            importer,
            images,
            saved_settings: settings.clone(),
            settings,
            settings_changed_at: None,
            section: Section::Home,
            sources: Cached::default(),
            sources_list: vec![],
            full_player: false,
            gl: cc.gl.clone(),
            get_proc: cc.get_proc_address.clone(),
            display,
            video: None,
            video_error: None,
            pointer_moved_at: Instant::now(),
            started: Instant::now(),
            started_refresh: false,
            autoplay_done: false,
            toast: None,
            pages: pages::Pages::default(),
        }
    }

    /// The playlist being browsed (falls back to the first one).
    pub fn active_source(&self) -> Option<&Source> {
        let id = self.settings.active_source_id;
        self.sources_list.iter().find(|s| Some(s.id) == id).or(self.sources_list.first())
    }

    pub fn version(&self, g: Group) -> u64 {
        self.db.versions.get(g)
    }

    pub fn go(&mut self, s: Section) {
        self.section = s;
        self.full_player = false;
    }

    pub fn notify(&mut self, msg: impl Into<String>) {
        self.toast = Some((msg.into(), Instant::now()));
    }

    pub fn refresh(&mut self, source_id: i64, scope: Scope) {
        self.importer.enqueue(source_id, scope, &self.settings);
    }

    // ---- video -------------------------------------------------------------------

    fn ensure_video(&mut self, frame: &mut eframe::Frame) {
        if self.video.is_some() || self.video_error.is_some() {
            return;
        }
        let (Some(m), Some(gl), Some(gp)) = (self.player.mpv.clone(), self.gl.clone(), self.get_proc.clone()) else {
            self.video_error = Some(self.player.unavailable.clone().unwrap_or_else(|| "Video output needs OpenGL".into()));
            return;
        };
        match VideoOutput::new(&m, &gl, frame, gp, self.display) {
            Ok(v) => self.video = Some(v),
            Err(e) => {
                log::error!("{e}");
                self.video_error = Some(e);
            }
        }
    }

    /// Draws the current video into `rect` (letterboxed), or a status card.
    pub fn video_surface(&mut self, ui: &mut egui::Ui, rect: Rect) -> egui::Response {
        let resp = ui.allocate_rect(rect, Sense::click());
        let p = ui.painter_at(rect);
        p.rect_filled(rect, CornerRadius::ZERO, Color32::BLACK);
        let ppp = ui.ctx().pixels_per_point();
        let mut shown = false;
        if self.player.playable.is_some()
            && let (Some(v), Some(gl)) = (&mut self.video, &self.gl)
        {
            // Fit the video's aspect ratio inside the rect.
            let aspect = self.player.video_size().map_or(16.0 / 9.0, |(w, h)| w / h) as f32;
            let mut size = rect.size();
            if size.x / size.y > aspect {
                size.x = size.y * aspect;
            } else {
                size.y = size.x / aspect;
            }
            let target = Rect::from_center_size(rect.center(), size);
            let (w, h) = ((target.width() * ppp).round() as i32, (target.height() * ppp).round() as i32);
            if v.render(gl, w, h) {
                egui::Image::new((v.texture_id, target.size())).paint_at(ui, target);
                shown = true;
            }
        } else if let Some(v) = &mut self.video {
            v.clear();
        }

        let overlay = |text: &str, color: Color32| {
            p.text(rect.center(), Align2::CENTER_CENTER, text, font(15.0), color);
        };
        match self.player.phase {
            Phase::Idle if !shown => {
                if let Some(e) = &self.video_error {
                    overlay(e, WARNING);
                } else {
                    overlay("Pick a channel to start watching", TEXT_DIM);
                }
            }
            Phase::Loading if !shown || self.player.position() < 0.1 => {
                ui.put(Rect::from_center_size(rect.center(), Vec2::splat(36.0)), egui::Spinner::new().size(36.0).color(TEXT));
            }
            Phase::Reconnecting => {
                p.rect_filled(rect, CornerRadius::ZERO, Color32::from_black_alpha(140));
                overlay(&format!("Reconnecting… (attempt {})", self.player.attempt), TEXT);
            }
            Phase::Error => {
                p.rect_filled(rect, CornerRadius::ZERO, Color32::from_black_alpha(170));
                let msg = self.player.error.clone().unwrap_or_default();
                let mut job = egui::text::LayoutJob::simple(msg, font(15.0), TEXT, rect.width() * 0.8);
                job.halign = egui::Align::Center;
                let galley = ui.fonts_mut(|f| f.layout_job(job));
                p.galley(rect.center() - vec2(0.0, galley.size().y / 2.0 + 16.0), galley, TEXT);
                let b = Rect::from_center_size(rect.center() + vec2(0.0, 36.0), vec2(110.0, 36.0));
                if ui.put(b, egui::Button::new("Try again")).clicked() {
                    self.player.retry();
                }
            }
            _ if self.player.buffering() => {
                ui.put(Rect::from_center_size(rect.center(), Vec2::splat(30.0)), egui::Spinner::new().size(30.0).color(TEXT));
            }
            _ => {}
        }
        resp
    }

    // ---- full-screen player --------------------------------------------------------

    fn player_view(&mut self, ui: &mut egui::Ui) {
        let rect = ui.max_rect();
        let resp = self.video_surface(ui, rect);
        if resp.double_clicked() {
            toggle_fullscreen(ui.ctx());
        } else if resp.clicked() && !self.player.is_live() {
            self.player.toggle_pause();
        }
        let moved = ui.input(|i| i.pointer.delta() != Vec2::ZERO || i.pointer.any_down() || !i.keys_down.is_empty());
        if moved {
            self.pointer_moved_at = Instant::now();
        }
        let idle = self.pointer_moved_at.elapsed();
        let show_controls = idle < Duration::from_secs(3) || self.player.phase != Phase::Playing || self.player.paused();
        if !show_controls {
            ui.ctx().set_cursor_icon(egui::CursorIcon::None);
            return;
        }
        ui.ctx().request_repaint_after(Duration::from_secs(3) - idle.min(Duration::from_secs(3)) + Duration::from_millis(50));

        let p = ui.painter();
        // Gradients behind the controls.
        let top = Rect::from_min_size(rect.min, vec2(rect.width(), 90.0));
        let bottom = Rect::from_min_max(egui::pos2(rect.min.x, rect.max.y - 130.0), rect.max);
        gradient(p, top, true);
        gradient(p, bottom, false);

        let Some(playable) = self.player.playable.clone() else {
            let mut back = ui.new_child(egui::UiBuilder::new().max_rect(Rect::from_min_size(rect.min + vec2(20.0, 20.0), Vec2::splat(40.0))));
            if icon_button(&mut back, "←", 40.0, "Back (Esc)").clicked() {
                self.full_player = false;
            }
            return;
        };

        // Top bar: back, title.
        let mut top_ui = ui.new_child(egui::UiBuilder::new().max_rect(top.shrink2(vec2(20.0, 16.0))).layout(egui::Layout::left_to_right(egui::Align::Center)));
        if icon_button(&mut top_ui, "←", 40.0, "Back (Esc)").clicked() {
            self.full_player = false;
        }
        top_ui.add_space(8.0);
        top_ui.vertical(|ui| {
            ui.label(egui::RichText::new(&playable.title).font(bold_font(19.0)).color(TEXT));
            if let Some(s) = &playable.subtitle {
                ui.label(dim(s));
            }
        });

        // Bottom: seek bar (VOD) above a row of buttons.
        let inner = bottom.shrink2(vec2(24.0, 18.0));
        let buttons = Rect::from_min_max(egui::pos2(inner.left(), inner.bottom() - 52.0), inner.max);
        let live = playable.is_live();
        let row_layout = |ui: &mut egui::Ui, rect: Rect, layout: egui::Layout| ui.new_child(egui::UiBuilder::new().max_rect(rect).layout(layout));
        let mut left = row_layout(ui, buttons, egui::Layout::left_to_right(egui::Align::Center));
        if live {
            if self.player.can_zap() {
                if icon_button(&mut left, "▲", 44.0, "Previous channel (↑)").clicked() {
                    self.player.zap(-1);
                }
                if icon_button(&mut left, "▼", 44.0, "Next channel (↓)").clicked() {
                    self.player.zap(1);
                }
                left.add_space(6.0);
            }
            left.label(egui::RichText::new("● LIVE").font(bold_font(13.0)).color(LIVE));
        } else {
            if icon_button(&mut left, "↺", 44.0, "Back 10 s (←)").clicked() {
                self.player.seek_relative(-10.0);
            }
            let icon = if self.player.paused() { "▶" } else { "⏸" };
            if icon_button(&mut left, icon, 52.0, "Play / pause (Space)").clicked() {
                self.player.toggle_pause();
            }
            if icon_button(&mut left, "↻", 44.0, "Forward 30 s (→)").clicked() {
                self.player.seek_relative(30.0);
            }
            left.add_space(6.0);
            left.label(egui::RichText::new(format!("{} / {}", duration_text(self.player.position()), duration_text(self.player.duration()))).color(TEXT_SOFT));
        }

        let mut right = row_layout(ui, buttons, egui::Layout::right_to_left(egui::Align::Center));
        if icon_button(&mut right, "⛶", 40.0, "Full screen (F)").clicked() {
            toggle_fullscreen(right.ctx());
        }
        self.tracks_menu(&mut right);
        let mut vol = self.player.volume();
        right.spacing_mut().slider_width = 110.0;
        if right.add(egui::Slider::new(&mut vol, 0.0..=100.0).show_value(false)).changed() {
            self.player.set_volume(vol);
        }
        let icon = if self.player.muted() || vol <= 0.0 { "🔇" } else { "🔊" };
        if icon_button(&mut right, icon, 40.0, "Mute (M)").clicked() {
            self.player.toggle_mute();
        }

        let dur = self.player.duration();
        if !live && dur > 0.0 {
            let bar = Rect::from_min_max(egui::pos2(inner.left(), buttons.top() - 30.0), egui::pos2(inner.right(), buttons.top() - 6.0));
            let mut seek = row_layout(ui, bar, egui::Layout::left_to_right(egui::Align::Center));
            seek.spacing_mut().slider_width = bar.width();
            let mut pos = self.player.position();
            let r = seek.add(egui::Slider::new(&mut pos, 0.0..=dur).show_value(false));
            if r.drag_stopped() || (r.changed() && !r.dragged()) {
                self.player.seek_to(pos);
            }
        }
    }

    fn tracks_menu(&mut self, ui: &mut egui::Ui) {
        let r = icon_button(ui, "💬", 40.0, "Audio and subtitles");
        egui::Popup::menu(&r).show(|ui| {
            let tracks = self.player.tracks();
            ui.label(dim("Audio"));
            for t in tracks.iter().filter(|t| t.kind == "audio") {
                if ui.selectable_label(t.selected, &t.label).clicked() {
                    self.player.select_track("aid", Some(t.id));
                }
            }
            ui.separator();
            ui.label(dim("Subtitles"));
            let any = tracks.iter().any(|t| t.kind == "sub" && t.selected);
            if ui.selectable_label(!any, "Off").clicked() {
                self.player.select_track("sid", None);
            }
            for t in tracks.iter().filter(|t| t.kind == "sub") {
                if ui.selectable_label(t.selected, &t.label).clicked() {
                    self.player.select_track("sid", Some(t.id));
                }
            }
        });
    }

    fn shortcuts(&mut self, ctx: &egui::Context) {
        if ctx.egui_wants_keyboard_input() {
            return;
        }
        let (esc, f, space, left, right, up, down, m, ctrl_f) = ctx.input(|i| {
            (
                i.key_pressed(Key::Escape),
                i.key_pressed(Key::F),
                i.key_pressed(Key::Space),
                i.key_pressed(Key::ArrowLeft),
                i.key_pressed(Key::ArrowRight),
                i.key_pressed(Key::ArrowUp) || i.key_pressed(Key::PageUp),
                i.key_pressed(Key::ArrowDown) || i.key_pressed(Key::PageDown),
                i.key_pressed(Key::M),
                i.modifiers.command && i.key_pressed(Key::F),
            )
        });
        if ctrl_f {
            self.go(Section::Search);
            self.pages.search.focus = true;
            return;
        }
        if !self.full_player {
            return;
        }
        if esc {
            if ctx.input(|i| i.viewport().fullscreen.unwrap_or(false)) {
                ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(false));
            } else {
                self.full_player = false;
            }
        }
        if f {
            toggle_fullscreen(ctx);
        }
        if m {
            self.player.toggle_mute();
        }
        if self.player.is_live() {
            if up {
                self.player.zap(-1);
            }
            if down {
                self.player.zap(1);
            }
        } else {
            if space {
                self.player.toggle_pause();
            }
            if left {
                self.player.seek_relative(-10.0);
            }
            if right {
                self.player.seek_relative(30.0);
            }
            if up {
                let v = self.player.volume() + 5.0;
                self.player.set_volume(v);
            }
            if down {
                let v = self.player.volume() - 5.0;
                self.player.set_volume(v);
            }
        }
    }

    // ---- shell ---------------------------------------------------------------------------

    fn sidebar(&mut self, ui: &mut egui::Ui) {
        egui::Panel::left("nav")
            .exact_size(212.0)
            .resizable(false)
            .show_separator_line(false)
            .frame(egui::Frame::new().fill(SHADE).inner_margin(egui::Margin { left: 12, right: 12, top: 18, bottom: 12 }))
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.add_space(6.0);
                    ui.label(egui::RichText::new("CAT").font(bold_font(26.0)).color(TEXT));
                    ui.label(egui::RichText::new("●").font(font(12.0)).color(ACCENT));
                });
                ui.add_space(14.0);
                self.source_picker(ui);
                ui.add_space(10.0);
                for (s, icon, label) in Section::NAV {
                    let (rect, resp) = row(ui, 40.0, self.section == s && !self.full_player);
                    let p = ui.painter();
                    p.text(rect.left_center() + vec2(16.0, 0.0), Align2::LEFT_CENTER, icon, font(16.0), if self.section == s { ACCENT_BRIGHT } else { TEXT_SOFT });
                    p.text(rect.left_center() + vec2(46.0, 0.0), Align2::LEFT_CENTER, label, font(15.0), TEXT);
                    if resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
                        self.go(s);
                    }
                }
                egui::Panel::bottom("nav-bottom")
                    .resizable(false)
                    .show_separator_line(false)
                    .frame(egui::Frame::new())
                    .show(ui, |ui| {
                        self.import_status(ui);
                        self.mini_player(ui);
                    });
            });
    }

    fn source_picker(&mut self, ui: &mut egui::Ui) {
        if self.sources_list.len() < 2 {
            return;
        }
        let current = self.active_source().map(|s| (s.id, s.name.clone()));
        let mut chosen = None;
        egui::ComboBox::from_id_salt("source")
            .width(ui.available_width())
            .selected_text(current.as_ref().map_or("", |c| c.1.as_str()))
            .show_ui(ui, |ui| {
                for s in &self.sources_list {
                    if ui.selectable_label(current.as_ref().map(|c| c.0) == Some(s.id), &s.name).clicked() {
                        chosen = Some(s.id);
                    }
                }
            });
        if let Some(id) = chosen {
            self.settings.active_source_id = Some(id);
            self.pages.reset_for_source();
        }
    }

    fn mini_player(&mut self, ui: &mut egui::Ui) {
        if self.full_player || self.section == Section::Live {
            return;
        }
        let Some(p) = self.player.playable.clone() else { return };
        ui.add_space(8.0);
        let w = ui.available_width();
        let rect = ui.allocate_space(vec2(w, w * 9.0 / 16.0)).1;
        let resp = self.video_surface(ui, rect);
        if resp.clicked() {
            self.full_player = true;
        }
        ui.horizontal(|ui| {
            ui.set_width(w);
            ui.add(egui::Label::new(egui::RichText::new(&p.title).color(TEXT)).truncate());
        });
        ui.horizontal(|ui| {
            if ui.small_button("⛶ Open").clicked() {
                self.full_player = true;
            }
            if ui.small_button("⏹ Stop").clicked() {
                self.player.stop();
            }
        });
    }

    fn import_status(&mut self, ui: &mut egui::Ui) {
        let statuses = self.importer.statuses();
        if statuses.is_empty() {
            return;
        }
        for (id, st) in statuses {
            let name = self.sources_list.iter().find(|s| s.id == id).map_or("Playlist".into(), |s| s.name.clone());
            panel_frame().show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.label(egui::RichText::new(name).font(bold_font(13.0)).color(TEXT));
                let color = if st.error.is_some() { WARNING } else { TEXT_DIM };
                ui.label(egui::RichText::new(&st.message).font(font(12.0)).color(color));
                if st.running {
                    let r = ui.allocate_space(vec2(ui.available_width(), 4.0)).1;
                    progress_bar(ui, r, st.fraction.unwrap_or(0.0), ACCENT);
                }
                if st.error.is_some() && ui.small_button("Dismiss").clicked() {
                    self.importer.dismiss(id);
                }
            });
            ui.add_space(6.0);
        }
        if self.importer.any_running() {
            ui.ctx().request_repaint_after(Duration::from_millis(250));
        }
    }

    fn welcome(&mut self, ui: &mut egui::Ui) {
        egui::CentralPanel::no_frame().frame(egui::Frame::new().fill(BG).inner_margin(egui::Margin::same(40))).show(ui, |ui| {
            ui.vertical_centered(|ui| {
                ui.add_space(30.0);
                ui.label(egui::RichText::new("Welcome to CAT").font(bold_font(30.0)).color(TEXT));
                ui.label(dim("Add your IPTV playlist to get started: Xtream Codes login, M3U link or M3U file."));
                ui.add_space(24.0);
            });
            // A centered column with left-aligned fields.
            let w = 560.0_f32.min(ui.available_width());
            ui.horizontal(|ui| {
                ui.add_space(((ui.available_width() - w) / 2.0).max(0.0));
                ui.vertical(|ui| {
                    ui.set_width(w);
                    pages::sources::add_form(self, ui);
                });
            });
        });
    }

    fn persist_settings(&mut self) {
        if let Some(k) = self.player.last_live.take() {
            self.settings.last_channel_key = Some(k);
        }
        if self.player.volume_dirty {
            self.player.volume_dirty = false;
            self.settings.volume = self.player.volume();
        }
        if self.settings != self.saved_settings {
            let changed_at = *self.settings_changed_at.get_or_insert_with(Instant::now);
            // Debounced: sliders change many times a second.
            if changed_at.elapsed() > Duration::from_millis(600) {
                let s = self.settings.clone();
                self.saved_settings = s.clone();
                self.settings_changed_at = None;
                self.db.write(&[], move |c| repo::save_settings(c, &s));
            } else {
                super::repaint_after(Duration::from_millis(650));
            }
        }
    }

    fn startup_tasks(&mut self) {
        if !self.started_refresh && !self.sources_list.is_empty() && self.started.elapsed() > Duration::from_secs(2) {
            self.started_refresh = true;
            self.importer.refresh_stale(&self.sources_list, &self.settings);
        }
        if !self.started_refresh {
            super::repaint_after(Duration::from_secs(2));
        }
        if !self.autoplay_done && !self.sources_list.is_empty() {
            self.autoplay_done = true;
            if self.settings.autoplay_last_channel
                && let Some((sid, key)) = self.settings.last_channel_key.as_deref().and_then(|k| k.split_once('|'))
                && let Ok(sid) = sid.parse::<i64>()
            {
                let key = key.to_string();
                self.pages.live.autoplay = Some(self.db.read(move |c| repo::item_by_key(c, sid, &key)));
                self.section = Section::Live;
            }
        }
    }
}

fn gradient(p: &egui::Painter, rect: Rect, top: bool) {
    let mut mesh = egui::Mesh::default();
    let (a, b) = (Color32::from_black_alpha(170), Color32::TRANSPARENT);
    let (c_top, c_bottom) = if top { (a, b) } else { (b, a) };
    mesh.colored_vertex(rect.left_top(), c_top);
    mesh.colored_vertex(rect.right_top(), c_top);
    mesh.colored_vertex(rect.left_bottom(), c_bottom);
    mesh.colored_vertex(rect.right_bottom(), c_bottom);
    mesh.add_triangle(0, 1, 2);
    mesh.add_triangle(1, 2, 3);
    p.add(mesh);
}

pub fn toggle_fullscreen(ctx: &egui::Context) {
    let fs = ctx.input(|i| i.viewport().fullscreen.unwrap_or(false));
    ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(!fs));
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        self.images.begin_frame(&ctx);
        // The video output is created the first time something plays.
        if self.player.playable.is_some() {
            self.ensure_video(frame);
        }
        self.player.tick();

        let v = self.version(Group::Sources);
        let db = self.db.clone();
        if let Some(list) = self.sources.get(&v, || db.read(repo::sources)) {
            self.sources_list = list.clone();
        }
        self.startup_tasks();
        self.shortcuts(&ctx);

        if self.full_player {
            egui::CentralPanel::no_frame().frame(egui::Frame::new().fill(Color32::BLACK)).show(ui, |ui| self.player_view(ui));
        } else if self.sources_list.is_empty() {
            if self.sources.get(&v, || db.read(repo::sources)).is_some() {
                self.welcome(ui);
            }
        } else {
            self.sidebar(ui);
            egui::CentralPanel::no_frame()
                .frame(egui::Frame::new().fill(BG).inner_margin(egui::Margin { left: 24, right: 24, top: 20, bottom: 16 }))
                .show(ui, |ui| match self.section {
                    Section::Home => pages::home::show(self, ui),
                    Section::Live => pages::live::show(self, ui),
                    Section::Guide => pages::guide::show(self, ui),
                    Section::Movies => pages::vod::show(self, ui, ItemKind::Movie),
                    Section::Series => pages::vod::show(self, ui, ItemKind::Series),
                    Section::Search => pages::search::show(self, ui),
                    Section::Playlists => pages::sources::show(self, ui),
                    Section::Settings => pages::settings::show(self, ui),
                });
        }

        if let Some((msg, at)) = &self.toast {
            if at.elapsed() < Duration::from_secs(4) {
                egui::Area::new("toast".into()).anchor(Align2::CENTER_BOTTOM, vec2(0.0, -30.0)).show(&ctx, |ui| {
                    egui::Frame::new().fill(SHEET_HIGH).corner_radius(CornerRadius::same(12)).inner_margin(egui::Margin::symmetric(16, 10)).show(ui, |ui| {
                        ui.label(egui::RichText::new(msg.as_str()).color(TEXT));
                    });
                });
                ctx.request_repaint_after(Duration::from_millis(500));
            } else {
                self.toast = None;
            }
        }
        self.persist_settings();
    }

    fn on_exit(&mut self, gl: Option<&glow::Context>) {
        if let (Some(v), Some(gl)) = (self.video.take(), gl) {
            v.destroy(gl);
        }
        self.player.shutdown();
        let s = self.settings.clone();
        let t = self.db.write(&[], move |c| repo::save_settings(c, &s));
        let until = Instant::now() + Duration::from_secs(2);
        while !t.is_done() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
