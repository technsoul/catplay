//! Playlists: add, edit, refresh and remove.

use super::super::app::App;
use super::super::theme::*;
use super::super::widgets::*;
use crate::db::{self, Group, Task};
use crate::import::Scope;
use crate::model::{Source, SourceType};
use crate::repo::{self, SourceForm, now_secs};
use crate::secrets;
use eframe::egui::{self, vec2};

pub struct Form {
    kind: SourceType,
    name: String,
    url: String,
    username: String,
    password: String,
    epg_url: String,
    user_agent: String,
    /// Editing an existing playlist.
    editing: Option<i64>,
    saving: Option<Task<i64>>,
    error: Option<String>,
}

impl Default for Form {
    fn default() -> Self {
        Self {
            kind: SourceType::Xtream,
            name: String::new(),
            url: String::new(),
            username: String::new(),
            password: String::new(),
            epg_url: String::new(),
            user_agent: String::new(),
            editing: None,
            saving: None,
            error: None,
        }
    }
}

#[derive(Default)]
pub struct State {
    pub form: Option<Form>,
    /// The form on the welcome screen.
    pub welcome: Form,
    confirm_delete: Option<i64>,
    loading_password: Option<(i64, Task<Option<String>>)>,
}

pub fn show(app: &mut App, ui: &mut egui::Ui) {
    ui.horizontal(|ui| {
        ui.label(egui::RichText::new("Playlists").font(bold_font(22.0)).color(TEXT));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if app.pages.sources.form.is_none() && pill(ui, "+  Add playlist", true).clicked() {
                app.pages.sources.form = Some(Form::default());
            }
        });
    });
    ui.add_space(10.0);

    if app.pages.sources.form.is_some() {
        panel_frame().show(ui, |ui| {
            ui.set_max_width(620.0);
            let mut form = app.pages.sources.form.take();
            let done = form.as_mut().is_some_and(|f| form_ui(app, ui, f));
            if !done && !ui.input(|i| i.key_pressed(egui::Key::Escape)) {
                app.pages.sources.form = form;
            }
        });
        ui.add_space(14.0);
    }

    // Fill the password into an edit form once it is read.
    if let Some((id, t)) = &app.pages.sources.loading_password
        && let Some(r) = t.take()
    {
        let id = *id;
        app.pages.sources.loading_password = None;
        if let Some(f) = app.pages.sources.form.as_mut().filter(|f| f.editing == Some(id)) {
            f.password = r.ok().flatten().unwrap_or_default();
        }
    }

    let statuses = app.importer.statuses();
    let sources = app.sources_list.clone();
    egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
        for s in &sources {
            panel_frame().show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.horizontal(|ui| {
                    ui.vertical(|ui| {
                        ui.horizontal(|ui| {
                            ui.label(egui::RichText::new(&s.name).font(bold_font(17.0)).color(TEXT));
                            ui.label(dim(s.kind.label()));
                            if app.active_source().map(|a| a.id) == Some(s.id) {
                                ui.label(egui::RichText::new("● Active").font(font(12.0)).color(SUCCESS));
                            }
                        });
                        ui.label(dim(format!("{} channels · {} movies · {} series", s.live_count, s.movie_count, s.series_count)));
                        ui.label(dim(status_line(s)));
                        if let Some(e) = s.error.as_ref().filter(|_| s.status == "error") {
                            ui.label(egui::RichText::new(e).color(WARNING));
                        }
                        if let Some(st) = statuses.get(&s.id) {
                            ui.label(egui::RichText::new(&st.message).color(if st.error.is_some() { WARNING } else { ACCENT_BRIGHT }));
                        }
                    });
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if app.pages.sources.confirm_delete == Some(s.id) {
                            if ui.button("Cancel").clicked() {
                                app.pages.sources.confirm_delete = None;
                            }
                            if ui.button(egui::RichText::new("Delete").color(LIVE)).clicked() {
                                app.pages.sources.confirm_delete = None;
                                delete(app, s.id);
                            }
                            ui.label(dim("Delete this playlist?"));
                            return;
                        }
                        if ui.button("🗑").on_hover_text("Delete").clicked() {
                            app.pages.sources.confirm_delete = Some(s.id);
                        }
                        if ui.button("✏ Edit").clicked() {
                            app.pages.sources.form = Some(edit_form(s));
                            if s.kind == SourceType::Xtream {
                                let id = s.id;
                                app.pages.sources.loading_password = Some((id, db::background(move || Ok(secrets::password(id)))));
                            }
                        }
                        let busy = app.importer.is_active(s.id);
                        if ui.add_enabled(!busy, egui::Button::new("⟳ Guide")).on_hover_text("Refresh the TV guide").clicked() {
                            app.refresh(s.id, Scope::Epg);
                        }
                        if ui.add_enabled(!busy, egui::Button::new("⟳ Refresh")).clicked() {
                            app.refresh(s.id, Scope::All);
                        }
                        if app.active_source().map(|a| a.id) != Some(s.id) && ui.button("Use").clicked() {
                            app.settings.active_source_id = Some(s.id);
                            app.pages.reset_for_source();
                        }
                    });
                });
            });
            ui.add_space(8.0);
        }
    });
}

fn status_line(s: &Source) -> String {
    let ago = |t: Option<i64>| match t {
        None => "never".to_string(),
        Some(t) => {
            let m = (now_secs() - t) / 60;
            match m {
                0 => "just now".into(),
                1..=59 => format!("{m} min ago"),
                60..=2879 => format!("{} h ago", m / 60),
                _ => format!("{} days ago", m / 1440),
            }
        }
    };
    let mut parts = vec![format!("Updated {}", ago(s.last_refresh)), format!("guide {}", ago(s.last_epg))];
    if let Some(exp) = s.expires_at.filter(|e| *e > 0) {
        let date = chrono::DateTime::from_timestamp(exp, 0).map(|d| d.format("%Y-%m-%d").to_string()).unwrap_or_default();
        parts.push(format!("expires {date}"));
    }
    if let Some(m) = s.max_connections {
        parts.push(format!("{m} connections"));
    }
    parts.join(" · ")
}

fn edit_form(s: &Source) -> Form {
    Form {
        kind: s.kind,
        name: s.name.clone(),
        url: s.url.clone(),
        username: s.username.clone().unwrap_or_default(),
        password: String::new(),
        epg_url: s.epg_url.clone().unwrap_or_default(),
        user_agent: s.user_agent.clone().unwrap_or_default(),
        editing: Some(s.id),
        saving: None,
        error: None,
    }
}

fn delete(app: &mut App, id: i64) {
    if app.player.playable.as_ref().is_some_and(|p| p.source_id == id) {
        app.player.stop();
    }
    let epg_dir = app.db.epg_dir.clone();
    app.db.write(&[Group::Sources, Group::Items, Group::Favorites, Group::History, Group::Epg], move |c| {
        repo::delete_source(c, id)?;
        repo::cleanup_epg_files(c, &epg_dir)
    });
    std::thread::spawn(move || secrets::delete(id));
    if app.settings.active_source_id == Some(id) {
        app.settings.active_source_id = None;
        app.pages.reset_for_source();
    }
}

/// The add-playlist form on the welcome screen.
pub fn add_form(app: &mut App, ui: &mut egui::Ui) {
    let mut form = std::mem::take(&mut app.pages.sources.welcome);
    if form_ui(app, ui, &mut form) {
        form = Form::default();
    }
    app.pages.sources.welcome = form;
}

/// Returns true once saved.
fn form_ui(app: &mut App, ui: &mut egui::Ui, f: &mut Form) -> bool {
    if let Some(t) = &f.saving
        && let Some(r) = t.take()
    {
        f.saving = None;
        match r {
            Ok(id) => {
                if f.editing.is_none() {
                    app.settings.active_source_id = Some(id);
                    app.pages.reset_for_source();
                }
                app.refresh(id, Scope::All);
                app.notify(if f.editing.is_some() { "Playlist saved. Refreshing…" } else { "Playlist added. Loading channels…" });
                return true;
            }
            Err(e) => f.error = Some(e),
        }
    }

    let new = f.editing.is_none();
    ui.label(egui::RichText::new(if new { "Add a playlist" } else { "Edit playlist" }).font(bold_font(17.0)).color(TEXT));
    ui.add_space(6.0);
    if new {
        ui.horizontal(|ui| {
            for k in [SourceType::Xtream, SourceType::M3uUrl, SourceType::M3uFile] {
                ui.selectable_value(&mut f.kind, k, k.label());
            }
        });
        ui.add_space(6.0);
    }
    let w = ui.available_width().min(560.0);
    let field = |ui: &mut egui::Ui, label: &str, value: &mut String, hint: &str, password: bool| {
        ui.label(egui::RichText::new(label).color(TEXT_SOFT));
        ui.add(egui::TextEdit::singleline(value).hint_text(hint).password(password).desired_width(w).margin(vec2(10.0, 8.0)));
    };
    field(ui, "Name", &mut f.name, "My TV", false);
    match f.kind {
        SourceType::Xtream => {
            field(ui, "Server", &mut f.url, "http://example.com:8080", false);
            field(ui, "Username", &mut f.username, "", false);
            field(ui, "Password", &mut f.password, "", true);
        }
        SourceType::M3uUrl => field(ui, "Playlist link", &mut f.url, "http://example.com/get.php?…", false),
        SourceType::M3uFile => {
            ui.label(egui::RichText::new("Playlist file").color(TEXT_SOFT));
            ui.horizontal(|ui| {
                ui.add(egui::TextEdit::singleline(&mut f.url).hint_text("/path/to/playlist.m3u").desired_width(w - 110.0).margin(vec2(10.0, 8.0)));
                if ui.button("Browse…").clicked()
                    && let Some(p) = rfd::FileDialog::new().add_filter("Playlists", &["m3u", "m3u8", "txt"]).pick_file()
                {
                    f.url = p.display().to_string();
                    if f.name.is_empty() {
                        f.name = p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                    }
                }
            });
        }
    }
    egui::CollapsingHeader::new("Advanced").id_salt(("adv", f.editing)).show(ui, |ui| {
        field(ui, "TV guide (XMLTV) link", &mut f.epg_url, if f.kind == SourceType::Xtream { "Leave empty to use the server's guide" } else { "Leave empty to use the playlist's url-tvg" }, false);
        field(ui, "User agent", &mut f.user_agent, "Leave empty for the default", false);
    });
    if let Some(e) = &f.error {
        ui.label(egui::RichText::new(e).color(WARNING));
    }
    ui.add_space(8.0);
    let mut cancel = false;
    ui.horizontal(|ui| {
        let ready = !f.url.trim().is_empty() && (f.kind != SourceType::Xtream || !f.username.trim().is_empty());
        let busy = f.saving.is_some();
        let label = if new { "Add playlist" } else { "Save" };
        if ui.add_enabled(ready && !busy, egui::Button::new(egui::RichText::new(label).color(TEXT)).fill(ACCENT).min_size(vec2(120.0, 36.0))).clicked() {
            let form = SourceForm {
                name: if f.name.trim().is_empty() { default_name(f) } else { f.name.clone() },
                url: f.url.trim().to_string(),
                username: Some(f.username.trim().to_string()).filter(|s| !s.is_empty()),
                epg_url: Some(f.epg_url.clone()),
                user_agent: Some(f.user_agent.clone()),
            };
            let (kind, editing) = (f.kind, f.editing);
            let password = (kind == SourceType::Xtream && !f.password.is_empty()).then(|| f.password.clone());
            f.error = None;
            f.saving = Some(app.db.write(&[Group::Sources], move |c| {
                let id = match editing {
                    Some(id) => repo::update_source(c, id, &form).map(|()| id)?,
                    None => repo::add_source(c, kind, &form)?,
                };
                // Stored before the import that follows reads it.
                if let Some(pw) = password {
                    secrets::set_password(id, &pw);
                }
                Ok(id)
            }));
        }
        if busy {
            ui.add(egui::Spinner::new());
        }
        if !app.sources_list.is_empty() && ui.button("Cancel").clicked() {
            cancel = true;
        }
    });
    cancel
}

fn default_name(f: &Form) -> String {
    let host = f.url.split("://").nth(1).unwrap_or(&f.url).split(['/', ':', '?']).next().unwrap_or("");
    match f.kind {
        SourceType::M3uFile => std::path::Path::new(&f.url).file_stem().map_or("Playlist".into(), |s| s.to_string_lossy().into_owned()),
        _ if !host.is_empty() => host.to_string(),
        _ => "Playlist".into(),
    }
}
