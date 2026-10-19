//! Draws mpv's video into an OpenGL texture that egui shows like an image.
//!
//! mpv renders straight on the GPU into our framebuffer (no copies through
//! the CPU), and only when it has a new frame or the size changed.

use super::mpv::{self, Mpv, OpenGlFbo, OpenGlInitParams, RenderContext, RenderParam};
use eframe::egui::TextureId;
use eframe::glow::{self, HasContext};
use raw_window_handle::RawDisplayHandle;
use std::ffi::{CStr, c_char, c_void};
use std::sync::Arc;

pub type GetProcAddress = Arc<dyn Fn(&CStr) -> *const c_void + Send + Sync>;

pub struct VideoOutput {
    api: &'static mpv::Api,
    rc: RenderContext,
    fbo: glow::Framebuffer,
    texture: glow::Texture,
    pub texture_id: TextureId,
    size: (i32, i32),
    has_frame: bool,
    // Kept alive for mpv's callback.
    _get_proc: Box<GetProcAddress>,
}

unsafe extern "C" fn get_proc(ctx: *mut c_void, name: *const c_char) -> *mut c_void {
    let f = unsafe { &*(ctx as *const GetProcAddress) };
    f(unsafe { CStr::from_ptr(name) }) as *mut c_void
}

unsafe extern "C" fn on_update(_: *mut c_void) {
    crate::ui::repaint();
}

impl VideoOutput {
    pub fn new(
        mpv: &Mpv,
        gl: &glow::Context,
        frame: &mut eframe::Frame,
        get_proc_address: GetProcAddress,
        display: Option<RawDisplayHandle>,
    ) -> Result<Self, String> {
        let api = mpv.api;
        let get_proc_box = Box::new(get_proc_address);
        let mut init = OpenGlInitParams {
            get_proc_address: get_proc,
            get_proc_address_ctx: &*get_proc_box as *const GetProcAddress as *mut c_void,
            extra_exts: std::ptr::null(),
        };
        let api_type = c"opengl";
        let mut params = vec![
            RenderParam { kind: mpv::RENDER_PARAM_API_TYPE, data: api_type.as_ptr() as *mut c_void },
            RenderParam { kind: mpv::RENDER_PARAM_OPENGL_INIT_PARAMS, data: &mut init as *mut _ as *mut c_void },
        ];
        // The native display lets mpv use zero-copy hardware decoding.
        match display {
            Some(RawDisplayHandle::Xlib(x)) => {
                if let Some(d) = x.display {
                    params.push(RenderParam { kind: mpv::RENDER_PARAM_X11_DISPLAY, data: d.as_ptr() });
                }
            }
            Some(RawDisplayHandle::Wayland(w)) => {
                params.push(RenderParam { kind: mpv::RENDER_PARAM_WL_DISPLAY, data: w.display.as_ptr() });
            }
            _ => {}
        }
        params.push(RenderParam { kind: mpv::RENDER_PARAM_INVALID, data: std::ptr::null_mut() });

        let mut rc: RenderContext = std::ptr::null_mut();
        let r = unsafe { (api.render_context_create)(&mut rc, mpv.handle, params.as_mut_ptr()) };
        if r < 0 {
            return Err(format!("Video output failed: {}", mpv::error_string(r)));
        }
        unsafe { (api.render_context_set_update_callback)(rc, Some(on_update), std::ptr::null_mut()) };

        let (fbo, texture) = unsafe {
            let texture = gl.create_texture()?;
            gl.bind_texture(glow::TEXTURE_2D, Some(texture));
            for (k, v) in [
                (glow::TEXTURE_MIN_FILTER, glow::LINEAR),
                (glow::TEXTURE_MAG_FILTER, glow::LINEAR),
                (glow::TEXTURE_WRAP_S, glow::CLAMP_TO_EDGE),
                (glow::TEXTURE_WRAP_T, glow::CLAMP_TO_EDGE),
            ] {
                gl.tex_parameter_i32(glow::TEXTURE_2D, k, v as i32);
            }
            gl.tex_image_2d(glow::TEXTURE_2D, 0, glow::RGBA8 as i32, 16, 16, 0, glow::RGBA, glow::UNSIGNED_BYTE, glow::PixelUnpackData::Slice(None));
            let fbo = gl.create_framebuffer()?;
            gl.bind_framebuffer(glow::FRAMEBUFFER, Some(fbo));
            gl.framebuffer_texture_2d(glow::FRAMEBUFFER, glow::COLOR_ATTACHMENT0, glow::TEXTURE_2D, Some(texture), 0);
            gl.bind_framebuffer(glow::FRAMEBUFFER, None);
            gl.bind_texture(glow::TEXTURE_2D, None);
            (fbo, texture)
        };
        let texture_id = frame.register_native_glow_texture(texture);
        Ok(Self { api, rc, fbo, texture, texture_id, size: (16, 16), has_frame: false, _get_proc: get_proc_box })
    }

    /// Renders mpv's latest frame at `w`×`h` pixels when needed. Returns
    /// whether there is a frame to show.
    pub fn render(&mut self, gl: &glow::Context, w: i32, h: i32) -> bool {
        let (w, h) = (w.clamp(16, 8192), h.clamp(16, 8192));
        let resized = (w, h) != self.size;
        let flags = unsafe { (self.api.render_context_update)(self.rc) };
        let new_frame = flags & mpv::RENDER_UPDATE_FRAME != 0;
        // Render only once mpv has a frame (rendering before that leaves its
        // renderer showing black); a resize re-renders the last frame.
        if !new_frame && !(resized && self.has_frame) {
            return self.has_frame;
        }
        unsafe {
            if resized {
                gl.bind_texture(glow::TEXTURE_2D, Some(self.texture));
                gl.tex_image_2d(glow::TEXTURE_2D, 0, glow::RGBA8 as i32, w, h, 0, glow::RGBA, glow::UNSIGNED_BYTE, glow::PixelUnpackData::Slice(None));
                gl.bind_texture(glow::TEXTURE_2D, None);
                self.size = (w, h);
            }
            // egui leaves its last clip rect as an enabled scissor test (and
            // blending on); mpv does not reset either, so frames would be
            // clipped or blended into whatever was there.
            gl.disable(glow::SCISSOR_TEST);
            gl.disable(glow::BLEND);
            gl.disable(glow::DEPTH_TEST);
            gl.disable(glow::CULL_FACE);
            gl.color_mask(true, true, true, true);
            gl.bind_vertex_array(None);
            gl.use_program(None);
            gl.bind_buffer(glow::ARRAY_BUFFER, None);
            gl.bind_buffer(glow::ELEMENT_ARRAY_BUFFER, None);
            gl.bind_buffer(glow::PIXEL_UNPACK_BUFFER, None);
            gl.active_texture(glow::TEXTURE0);
            gl.bind_texture(glow::TEXTURE_2D, None);
            gl.pixel_store_i32(glow::UNPACK_ALIGNMENT, 4);
            gl.viewport(0, 0, w, h);
            let mut fbo = OpenGlFbo { fbo: self.fbo.0.get() as i32, w, h, internal_format: 0 };
            let mut flip: i32 = 0;
            // Never stall the UI thread waiting for the frame's display time.
            let mut block: i32 = 0;
            let mut params = [
                RenderParam { kind: mpv::RENDER_PARAM_OPENGL_FBO, data: &mut fbo as *mut _ as *mut c_void },
                RenderParam { kind: mpv::RENDER_PARAM_FLIP_Y, data: &mut flip as *mut _ as *mut c_void },
                RenderParam { kind: mpv::RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: &mut block as *mut _ as *mut c_void },
                RenderParam { kind: mpv::RENDER_PARAM_INVALID, data: std::ptr::null_mut() },
            ];
            (self.api.render_context_render)(self.rc, params.as_mut_ptr());
            (self.api.render_context_report_swap)(self.rc);
            gl.bind_framebuffer(glow::FRAMEBUFFER, None);
        }
        if !self.has_frame {
            log::info!("video: first frame at {w}x{h}");
        }
        self.has_frame = true;
        true
    }

    /// Forget the last frame (after stop), so the old picture is not shown.
    pub fn clear(&mut self) {
        self.has_frame = false;
    }

    /// Must run on the GL thread before mpv is destroyed.
    pub fn destroy(self, gl: &glow::Context) {
        unsafe {
            (self.api.render_context_free)(self.rc);
            gl.delete_framebuffer(self.fbo);
            gl.delete_texture(self.texture);
        }
    }
}
