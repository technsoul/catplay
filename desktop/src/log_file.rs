//! Writes log lines to `logs/app.log` (rotated at 2 MB) and stderr.

use log::{Level, LevelFilter, Metadata, Record};
use parking_lot::Mutex;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::Path;

struct Logger {
    file: Mutex<Option<File>>,
}

impl log::Log for Logger {
    fn enabled(&self, m: &Metadata) -> bool {
        m.level() <= Level::Info && !m.target().starts_with("eframe") && !m.target().starts_with("egui")
            || m.level() <= Level::Warn
    }

    fn log(&self, r: &Record) {
        if !self.enabled(r.metadata()) {
            return;
        }
        let line = format!("{} {:5} {}\n", chrono::Local::now().format("%Y-%m-%d %H:%M:%S"), r.level(), r.args());
        if cfg!(debug_assertions) {
            eprint!("{line}");
        }
        if let Some(f) = self.file.lock().as_mut() {
            let _ = f.write_all(line.as_bytes());
        }
    }

    fn flush(&self) {
        if let Some(f) = self.file.lock().as_mut() {
            let _ = f.flush();
        }
    }
}

pub fn init(dir: &Path) {
    let path = dir.join("app.log");
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > 2 * 1024 * 1024) {
        let _ = std::fs::rename(&path, dir.join("app.old.log"));
    }
    let file = OpenOptions::new().create(true).append(true).open(&path).ok();
    let logger = Box::leak(Box::new(Logger { file: Mutex::new(file) }));
    if log::set_logger(logger).is_ok() {
        log::set_max_level(LevelFilter::Info);
    }
}
