use std::{
    os::windows::process::CommandExt,
    path::Path,
    process::{Child, Command},
};
use tauri::{tray::TrayIconBuilder, AppHandle, Runtime};

pub(super) const EXECUTABLE_SUFFIX: &str = ".exe";
pub(super) const NODE_LOOKUP: &str = "where";
pub(super) const NODE_CANDIDATES: &[&str] = &[r"C:\Program Files\nodejs\node.exe"];
pub(super) const POSTGRES_CANDIDATES: &[&str] = &[
    r"C:\Program Files\PostgreSQL\16\bin",
    r"C:\Program Files\PostgreSQL\17\bin",
];

pub(super) fn browser_command(url: &str) -> Command {
    let mut command = Command::new("cmd");
    command.args(["/C", "start", "", url]);
    command
}

pub(super) fn configure_child_process(command: &mut Command) {
    command.creation_flags(0x08000000); // CREATE_NO_WINDOW, as before.
}

pub(super) fn reset_authorization_command() -> Command {
    let mut command = Command::new("powershell.exe");
    command.args(["-NoProfile", "-NonInteractive", "-Command",
        "$ErrorActionPreference='Stop'; try { $p=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList '-NoProfile','-NonInteractive','-Command','exit 0' -Verb RunAs -Wait -PassThru; if ($null -eq $p.ExitCode) { exit 1 }; exit $p.ExitCode } catch { exit 1 }"]);
    command
}

pub(super) fn request_child_stop(child: &mut Child) -> Result<(), String> {
    child.kill().map_err(|error| error.to_string())
}

// This refactor retains the old Windows behavior; it does not add an ACL policy.
pub(super) fn restrict_settings_file(_: &Path) -> Result<(), String> {
    Ok(())
}
pub(super) fn apply_dock_policy(_: &AppHandle, _: bool) {}
pub(super) fn configure_tray<R: Runtime>(tray: TrayIconBuilder<R>) -> TrayIconBuilder<R> {
    tray
}
