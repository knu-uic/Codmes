//! OS adapters. Account, OAuth protocol and server lifecycle policy remain shared.

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
use macos as implementation;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
use linux as implementation;
#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
use windows as implementation;
#[cfg(unix)]
mod unix;
#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
compile_error!("Server Manager supports macOS, Linux and Windows OS adapters only.");

use std::{
    path::{Path, PathBuf},
    process::{Child, Command},
    thread,
    time::Duration,
};
use tauri::{tray::TrayIconBuilder, AppHandle, Runtime};

pub(crate) fn open_system_browser(url: &str) -> Result<(), String> {
    implementation::browser_command(url)
        .status()
        .map_err(|error| format!("Could not open the system browser: {error}"))
        .and_then(|status| {
            if status.success() {
                Ok(())
            } else {
                Err("Could not open the system browser.".into())
            }
        })
}

pub(crate) fn authorize_server_reset(cancelled: &std::sync::atomic::AtomicBool) -> Result<(), String> {
    if cancelled.load(std::sync::atomic::Ordering::SeqCst) {
        return Err("새 서버 만들기를 취소했습니다. 기존 서버를 유지합니다.".into());
    }
    let mut command = implementation::reset_authorization_command();
    configure_child_process(&mut command);
    let mut child = command.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null())
        .spawn().map_err(|_| "OS 관리자 확인을 시작할 수 없습니다. 초기화를 진행하지 않았습니다.".to_string())?;
    let deadline = std::time::Instant::now() + Duration::from_secs(180);
    loop {
        if cancelled.load(std::sync::atomic::Ordering::SeqCst) {
            let _ = child.kill(); let _ = child.wait();
            return Err("새 서버 만들기를 취소했습니다. 기존 서버를 유지합니다.".into());
        }
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            return if status.success() { Ok(()) } else { Err("컴퓨터 관리자 확인이 취소되었거나 거부되었습니다. 기존 서버를 유지합니다.".into()) };
        }
        if std::time::Instant::now() >= deadline {
            let _ = child.kill(); let _ = child.wait();
            return Err("컴퓨터 관리자 확인 시간이 초과되었습니다. 기존 서버를 유지합니다.".into());
        }
        thread::sleep(Duration::from_millis(100));
    }
}

pub(crate) fn executable_name(stem: &str) -> String {
    format!("{stem}{}", implementation::EXECUTABLE_SUFFIX)
}

pub(crate) fn configure_child_process(command: &mut Command) {
    implementation::configure_child_process(command);
}

pub(crate) fn terminate_child(child: &mut Child) -> Result<(), String> {
    implementation::request_child_stop(child)?;
    // The graceful-stop deadline and force-kill fallback are shared policy.
    for _ in 0..20 {
        if child
            .try_wait()
            .map_err(|error| error.to_string())?
            .is_some()
        {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(50));
    }
    child.kill().map_err(|error| error.to_string())?;
    child.wait().map_err(|error| error.to_string())?;
    Ok(())
}

pub(crate) fn restrict_settings_file(path: &Path) -> Result<(), String> {
    implementation::restrict_settings_file(path)
}

pub(crate) fn apply_dock_policy(app: &AppHandle, show: bool) {
    implementation::apply_dock_policy(app, show);
}

pub(crate) fn configure_tray<R: Runtime>(tray: TrayIconBuilder<R>) -> TrayIconBuilder<R> {
    implementation::configure_tray(tray)
}

pub(crate) fn autostart_plugin<R: Runtime>() -> tauri::plugin::TauriPlugin<R> {
    // Tauri owns the per-OS registration. This parameter selects LaunchAgent on Mac;
    // the same cross-platform plugin ignores that Mac-specific choice elsewhere.
    tauri_plugin_autostart::init(
        tauri_plugin_autostart::MacosLauncher::LaunchAgent,
        Some(vec!["--minimized"]),
    )
}

pub(crate) fn find_system_node() -> PathBuf {
    if let Ok(node) = std::env::var("CODMES_MANAGER_NODE") {
        return PathBuf::from(node);
    }
    if let Some(candidate) = implementation::NODE_CANDIDATES
        .iter()
        .map(PathBuf::from)
        .find(|path| path.is_file())
    {
        return candidate;
    }
    if let Ok(output) = Command::new(implementation::NODE_LOOKUP)
        .arg(executable_name("node"))
        .output()
    {
        if output.status.success() {
            if let Some(line) = String::from_utf8_lossy(&output.stdout).lines().next() {
                let candidate = PathBuf::from(line.trim());
                if candidate.is_file() {
                    return candidate;
                }
            }
        }
    }
    // Keep the existing PATH fallback, including Windows' executable resolution.
    PathBuf::from("node")
}

pub(crate) fn find_postgres_bin(server_root: &Path) -> Option<PathBuf> {
    let executable = executable_name("postgres");
    let mut candidates = vec![server_root.join("bundled/postgres/bin")];
    if let Ok(explicit) = std::env::var("CODMES_POSTGRES_BIN") {
        candidates.push(PathBuf::from(explicit));
    }
    candidates.extend(
        implementation::POSTGRES_CANDIDATES
            .iter()
            .map(PathBuf::from),
    );
    if let Some(candidate) = candidates
        .into_iter()
        .find(|directory| directory.join(&executable).is_file())
    {
        return Some(candidate);
    }
    let output = Command::new("pg_config").arg("--bindir").output().ok()?;
    if !output.status.success() {
        return None;
    }
    let candidate = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
    candidate.join(executable).is_file().then_some(candidate)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancelled_reset_never_launches_an_os_authorization_dialog() {
        let cancelled=std::sync::atomic::AtomicBool::new(true);
        assert!(authorize_server_reset(&cancelled).unwrap_err().contains("취소"));
    }

    #[test]
    fn reset_authorization_uses_an_os_tool_not_workspace_or_account_input() {
        let command=implementation::reset_authorization_command();
        let arguments=command.get_args().map(|value|value.to_string_lossy()).collect::<Vec<_>>().join(" ");
        assert!(!command.get_program().is_empty());
        assert!(!arguments.contains("remove_dir_all"));
        assert!(!arguments.contains("rm -"));
        assert!(!arguments.contains("Remove-Item"));
        assert!(!arguments.contains("client_secret"));
    }
    use std::process::Stdio;

    #[test]
    fn native_executable_names_use_the_selected_adapter() {
        let expected_suffix = if cfg!(target_os = "windows") {
            ".exe"
        } else {
            ""
        };
        for stem in ["node", "postgres", "pg_ctl"] {
            assert_eq!(executable_name(stem), format!("{stem}{expected_suffix}"));
        }
    }

    #[test]
    fn browser_arguments_preserve_the_entire_url_without_launching_a_browser() {
        let url = "https://accounts.google.com/o/oauth2/v2/auth?state=test&redirect_uri=http%3A%2F%2F127.0.0.1%3A1234";
        let command = implementation::browser_command(url);
        let args: Vec<_> = command
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();
        assert_eq!(args.last().unwrap(), url);
        #[cfg(target_os = "windows")]
        {
            assert_eq!(command.get_program(), "cmd");
            assert_eq!(args, ["/C", "start", "", url]);
        }
        #[cfg(target_os = "macos")]
        {
            assert_eq!(command.get_program(), "open");
            assert_eq!(args, [url]);
        }
        #[cfg(target_os = "linux")]
        {
            assert_eq!(command.get_program(), "xdg-open");
            assert_eq!(args, [url]);
        }
    }

    #[test]
    fn bundled_postgres_is_preferred_without_starting_a_database() {
        let root = std::env::temp_dir().join(format!(
            "codmes-platform-{}-{}",
            std::process::id(),
            rand::random::<u64>()
        ));
        let bin = root.join("bundled/postgres/bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(bin.join(executable_name("postgres")), b"fixture only").unwrap();
        let found = find_postgres_bin(&root);
        std::fs::remove_dir_all(&root).unwrap();
        assert_eq!(found, Some(bin));
    }

    #[test]
    fn owned_child_process_is_stopped_and_reaped() {
        let mut command = Command::new(find_system_node());
        command
            .args(["-e", "setInterval(() => {}, 1000)"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        configure_child_process(&mut command);
        let mut child = command.spawn().unwrap();
        let result = terminate_child(&mut child);
        if result.is_err() {
            let _ = child.kill();
            let _ = child.wait();
        }
        assert!(result.is_ok());
        assert!(child.try_wait().unwrap().is_some());
    }
}
