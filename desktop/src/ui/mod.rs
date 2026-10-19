//! The egui interface.

pub mod app;
mod data;
mod pages;
mod theme;
mod widgets;

use std::sync::OnceLock;

static CTX: OnceLock<eframe::egui::Context> = OnceLock::new();

pub fn set_context(ctx: &eframe::egui::Context) {
    let _ = CTX.set(ctx.clone());
}

/// Asks for a new frame; background work calls this when it has results.
pub fn repaint() {
    if let Some(c) = CTX.get() {
        c.request_repaint();
    }
}

pub fn repaint_after(d: std::time::Duration) {
    if let Some(c) = CTX.get() {
        c.request_repaint_after(d);
    }
}
