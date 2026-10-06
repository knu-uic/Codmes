fn main() {
    let names = [
        "CODMES_BUNDLED_GOOGLE_DESKTOP_CLIENT_ID",
        "CODMES_BUNDLED_GOOGLE_DESKTOP_CLIENT_SECRET",
        "CODMES_BUNDLED_GOOGLE_MACOS_CLIENT_ID",
        "CODMES_BUNDLED_GOOGLE_IOS_CLIENT_ID",
        "CODMES_BUNDLED_GOOGLE_ANDROID_CLIENT_ID",
        "CODMES_BUNDLED_GOOGLE_WEB_CLIENT_ID",
    ];
    let local_env_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../.env");
    println!("cargo:rerun-if-changed={}", local_env_path.display());
    let local_env = std::fs::read_to_string(&local_env_path).unwrap_or_default();
    for name in names {
        println!("cargo:rerun-if-env-changed={name}");
        if std::env::var_os(name).is_some() {
            continue;
        }
        if let Some(value) = local_env.lines().filter_map(|line| line.trim().split_once('='))
            .find_map(|(key, value)| (key.trim() == name).then_some(value.trim())) {
            if !value.is_empty() {
                println!("cargo:rustc-env={name}={value}");
            }
        }
    }
    tauri_build::build()
}
