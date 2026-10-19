// Hide the console window on Windows release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod db;
mod http;
mod images;
mod import;
mod log_file;
mod model;
mod parse;
mod paths;
mod player;
mod repo;
mod secrets;
mod settings;
mod ui;

fn main() -> eframe::Result {
    let paths = paths::Paths::new();
    if let Err(e) = paths.create() {
        eprintln!("Cannot create {}: {e}", paths.support.display());
    }
    log_file::init(&paths.logs);
    secrets::init(paths.support.join("secrets.json"));
    // Reading settings needs the database open, which also migrates it.
    let db = match db::Db::open(paths.database.clone(), paths.epg_dir.clone()) {
        Ok(db) => db,
        Err(e) => {
            log::error!("database: {e}");
            rfd::MessageDialog::new().set_title("CAT").set_description(format!("Cannot open the database:\n{e}")).show();
            std::process::exit(1);
        }
    };
    let settings = db.read(repo::load_settings);
    let settings = loop {
        if let Some(r) = settings.take() {
            break r.unwrap_or_default();
        }
        std::thread::sleep(std::time::Duration::from_millis(2));
    };
    let importer = import::Importer::new(db.clone(), paths.import_temp.clone());
    let images = images::Images::new(paths.image_cache.clone());

    let options = eframe::NativeOptions {
        renderer: eframe::Renderer::Glow,
        viewport: eframe::egui::ViewportBuilder::default()
            .with_title("CAT")
            .with_app_id("catplay")
            .with_inner_size([1360.0, 820.0])
            .with_min_inner_size([900.0, 560.0])
            .with_icon(icon()),
        ..Default::default()
    };
    eframe::run_native(
        "CAT",
        options,
        Box::new(move |cc| Ok(Box::new(ui::app::App::new(cc, db, importer, images, settings)))),
    )
}

fn icon() -> eframe::egui::IconData {
    let img = image::load_from_memory(include_bytes!("../assets/icon.png")).map(|i| i.to_rgba8()).ok();
    match img {
        Some(i) => eframe::egui::IconData { width: i.width(), height: i.height(), rgba: i.into_raw() },
        None => eframe::egui::IconData::default(),
    }
}
