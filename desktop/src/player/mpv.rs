//! Minimal libmpv binding, loaded at run time so one build works with any
//! installed libmpv (`libmpv.so.2` or `.so.1` on Linux, `libmpv-2.dll` next
//! to the exe on Windows, the bundled dylib on macOS).

#![allow(non_camel_case_types)]

use libloading::Library;
use std::ffi::{CStr, CString, c_char, c_double, c_int, c_void};
use std::sync::OnceLock;

pub type Handle = *mut c_void;
pub type RenderContext = *mut c_void;

pub const FORMAT_STRING: c_int = 1;
pub const FORMAT_FLAG: c_int = 3;
pub const FORMAT_INT64: c_int = 4;
pub const FORMAT_DOUBLE: c_int = 5;

pub const EVENT_NONE: c_int = 0;
pub const EVENT_SHUTDOWN: c_int = 1;
pub const EVENT_LOG_MESSAGE: c_int = 2;
pub const EVENT_END_FILE: c_int = 7;
pub const EVENT_FILE_LOADED: c_int = 8;
pub const EVENT_PROPERTY_CHANGE: c_int = 22;

pub const END_FILE_EOF: c_int = 0;
pub const END_FILE_ERROR: c_int = 4;

pub const RENDER_PARAM_INVALID: c_int = 0;
pub const RENDER_PARAM_API_TYPE: c_int = 1;
pub const RENDER_PARAM_OPENGL_INIT_PARAMS: c_int = 2;
pub const RENDER_PARAM_OPENGL_FBO: c_int = 3;
pub const RENDER_PARAM_FLIP_Y: c_int = 4;
pub const RENDER_PARAM_X11_DISPLAY: c_int = 8;
pub const RENDER_PARAM_WL_DISPLAY: c_int = 9;
pub const RENDER_PARAM_BLOCK_FOR_TARGET_TIME: c_int = 12;
pub const RENDER_UPDATE_FRAME: u64 = 1;

#[repr(C)]
pub struct Event {
    pub event_id: c_int,
    pub error: c_int,
    pub reply_userdata: u64,
    pub data: *mut c_void,
}

#[repr(C)]
pub struct EventProperty {
    pub name: *const c_char,
    pub format: c_int,
    pub data: *mut c_void,
}

#[repr(C)]
pub struct EventEndFile {
    pub reason: c_int,
    pub error: c_int,
}

#[repr(C)]
pub struct EventLogMessage {
    pub prefix: *const c_char,
    pub level: *const c_char,
    pub text: *const c_char,
}

#[repr(C)]
pub struct RenderParam {
    pub kind: c_int,
    pub data: *mut c_void,
}

#[repr(C)]
pub struct OpenGlInitParams {
    pub get_proc_address: unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_void,
    pub get_proc_address_ctx: *mut c_void,
    /// Only read by the old (client API 1.x) libmpv; must be null.
    pub extra_exts: *const c_char,
}

#[repr(C)]
pub struct OpenGlFbo {
    pub fbo: c_int,
    pub w: c_int,
    pub h: c_int,
    pub internal_format: c_int,
}

macro_rules! api {
    ($($name:ident : fn($($arg:ty),*) $(-> $ret:ty)?;)*) => {
        pub struct Api {
            _lib: Library,
            $(pub $name: unsafe extern "C" fn($($arg),*) $(-> $ret)?,)*
        }

        impl Api {
            unsafe fn load(lib: Library) -> Result<Self, String> {
                unsafe {
                    $(
                        let $name = *lib
                            .get::<unsafe extern "C" fn($($arg),*) $(-> $ret)?>(concat!("mpv_", stringify!($name), "\0").as_bytes())
                            .map_err(|e| format!("libmpv is missing mpv_{}: {e}", stringify!($name)))?;
                    )*
                    Ok(Self { _lib: lib, $($name,)* })
                }
            }
        }
    };
}

api! {
    create: fn() -> Handle;
    initialize: fn(Handle) -> c_int;
    terminate_destroy: fn(Handle);
    set_option_string: fn(Handle, *const c_char, *const c_char) -> c_int;
    set_property_string: fn(Handle, *const c_char, *const c_char) -> c_int;
    set_property: fn(Handle, *const c_char, c_int, *mut c_void) -> c_int;
    get_property: fn(Handle, *const c_char, c_int, *mut c_void) -> c_int;
    command_async: fn(Handle, u64, *mut *const c_char) -> c_int;
    observe_property: fn(Handle, u64, *const c_char, c_int) -> c_int;
    wait_event: fn(Handle, c_double) -> *mut Event;
    free: fn(*mut c_void);
    error_string: fn(c_int) -> *const c_char;
    request_log_messages: fn(Handle, *const c_char) -> c_int;
    render_context_create: fn(*mut RenderContext, Handle, *mut RenderParam) -> c_int;
    render_context_set_update_callback: fn(RenderContext, Option<unsafe extern "C" fn(*mut c_void)>, *mut c_void);
    render_context_update: fn(RenderContext) -> u64;
    render_context_render: fn(RenderContext, *mut RenderParam) -> c_int;
    render_context_report_swap: fn(RenderContext);
    render_context_free: fn(RenderContext);
}

fn candidates() -> &'static [&'static str] {
    if cfg!(windows) {
        &["libmpv-2.dll", "mpv-2.dll", "mpv-1.dll"]
    } else if cfg!(target_os = "macos") {
        &["libmpv.2.dylib", "libmpv.dylib", "/opt/homebrew/lib/libmpv.dylib", "/usr/local/lib/libmpv.dylib"]
    } else {
        &["libmpv.so.2", "libmpv.so.1", "libmpv.so"]
    }
}

/// The loaded library, or why it could not be loaded.
pub fn api() -> Result<&'static Api, &'static str> {
    static API: OnceLock<Result<Api, String>> = OnceLock::new();
    API.get_or_init(|| {
        let exe_dir = std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.to_path_buf()));
        let mut errors = vec![];
        for name in candidates() {
            // Next to the executable first (Windows), then the app bundle's
            // Frameworks folder (macOS), then the system search path.
            let mut paths = vec![];
            if let Some(d) = &exe_dir {
                paths.push(d.join(name));
                paths.push(d.join("../Frameworks").join(name));
            }
            paths.push(std::path::PathBuf::from(name));
            for p in paths {
                match unsafe { Library::new(&p) } {
                    Ok(lib) => return unsafe { Api::load(lib) },
                    Err(e) => errors.push(format!("{}: {e}", p.display())),
                }
            }
        }
        Err(format!("libmpv was not found. Install it (on Ubuntu: sudo apt install libmpv2).\n{}", errors.join("\n")))
    })
    .as_ref()
    .map_err(String::as_str)
}

pub fn cstr(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

pub fn error_string(code: c_int) -> String {
    match api() {
        Ok(a) => unsafe { CStr::from_ptr((a.error_string)(code)) }.to_string_lossy().into_owned(),
        Err(_) => format!("error {code}"),
    }
}

/// An mpv instance. The client API is thread-safe.
pub struct Mpv {
    pub api: &'static Api,
    pub handle: Handle,
}

unsafe impl Send for Mpv {}
unsafe impl Sync for Mpv {}

impl Mpv {
    pub fn new(options: &[(&str, &str)]) -> Result<Self, String> {
        let api = api().map_err(String::from)?;
        let handle = unsafe { (api.create)() };
        if handle.is_null() {
            return Err("Could not start libmpv".into());
        }
        let mpv = Self { api, handle };
        for (k, v) in options {
            let (k, v) = (cstr(k), cstr(v));
            let r = unsafe { (api.set_option_string)(handle, k.as_ptr(), v.as_ptr()) };
            if r < 0 {
                log::warn!("mpv option {k:?}={v:?}: {}", error_string(r));
            }
        }
        let r = unsafe { (api.initialize)(handle) };
        if r < 0 {
            return Err(format!("libmpv failed to start: {}", error_string(r)));
        }
        Ok(mpv)
    }

    pub fn set(&self, name: &str, value: &str) {
        let (k, v) = (cstr(name), cstr(value));
        let r = unsafe { (self.api.set_property_string)(self.handle, k.as_ptr(), v.as_ptr()) };
        if r < 0 {
            log::debug!("mpv set {name}={value}: {}", error_string(r));
        }
    }

    pub fn set_f64(&self, name: &str, mut value: f64) {
        let k = cstr(name);
        unsafe { (self.api.set_property)(self.handle, k.as_ptr(), FORMAT_DOUBLE, &mut value as *mut f64 as *mut c_void) };
    }

    pub fn set_flag(&self, name: &str, value: bool) {
        let k = cstr(name);
        let mut v: c_int = value.into();
        unsafe { (self.api.set_property)(self.handle, k.as_ptr(), FORMAT_FLAG, &mut v as *mut c_int as *mut c_void) };
    }

    pub fn get_i64(&self, name: &str) -> Option<i64> {
        let k = cstr(name);
        let mut v: i64 = 0;
        let r = unsafe { (self.api.get_property)(self.handle, k.as_ptr(), FORMAT_INT64, &mut v as *mut i64 as *mut c_void) };
        (r >= 0).then_some(v)
    }

    pub fn get_flag(&self, name: &str) -> Option<bool> {
        let k = cstr(name);
        let mut v: c_int = 0;
        let r = unsafe { (self.api.get_property)(self.handle, k.as_ptr(), FORMAT_FLAG, &mut v as *mut c_int as *mut c_void) };
        (r >= 0).then_some(v != 0)
    }

    pub fn get_string(&self, name: &str) -> Option<String> {
        let k = cstr(name);
        let mut p: *mut c_char = std::ptr::null_mut();
        let r = unsafe { (self.api.get_property)(self.handle, k.as_ptr(), FORMAT_STRING, &mut p as *mut *mut c_char as *mut c_void) };
        if r < 0 || p.is_null() {
            return None;
        }
        let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        unsafe { (self.api.free)(p as *mut c_void) };
        Some(s)
    }

    /// Runs a command without waiting for it (e.g. `loadfile`, `seek`).
    pub fn command(&self, args: &[&str]) {
        let owned: Vec<CString> = args.iter().map(|a| cstr(a)).collect();
        let mut ptrs: Vec<*const c_char> = owned.iter().map(|c| c.as_ptr()).collect();
        ptrs.push(std::ptr::null());
        let r = unsafe { (self.api.command_async)(self.handle, 0, ptrs.as_mut_ptr()) };
        if r < 0 {
            log::warn!("mpv command {args:?}: {}", error_string(r));
        }
    }

    pub fn observe(&self, id: u64, name: &str, format: c_int) {
        let k = cstr(name);
        unsafe { (self.api.observe_property)(self.handle, id, k.as_ptr(), format) };
    }
}

impl Drop for Mpv {
    fn drop(&mut self) {
        unsafe { (self.api.terminate_destroy)(self.handle) };
    }
}
