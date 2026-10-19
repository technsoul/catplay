fn main() {
    // Windows: the app icon and version info inside CAT.exe.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let mut res = winresource::WindowsResource::new();
        res.set_icon("assets/app_icon.ico");
        res.set("ProductName", "CAT");
        res.set("FileDescription", "CAT IPTV player");
        if let Err(e) = res.compile() {
            println!("cargo:warning=could not embed the Windows icon: {e}");
        }
    }
}
