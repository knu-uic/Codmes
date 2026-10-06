use std::process::Command;
use tauri::{tray::TrayIconBuilder, AppHandle, Runtime};

pub(super) use super::unix::{
    request_child_stop, restrict_settings_file, EXECUTABLE_SUFFIX, NODE_CANDIDATES, NODE_LOOKUP,
};
pub(super) const POSTGRES_CANDIDATES: &[&str] =
    &["/usr/lib/postgresql/16/bin", "/usr/local/pgsql/bin"];

pub(super) fn browser_command(url: &str) -> Command {
    let mut command = Command::new("xdg-open");
    command.arg(url);
    command
}

pub(super) fn configure_child_process(_: &mut Command) {}
pub(super) fn reset_authorization_command() -> Command {
    // Requires a functioning polkit authentication agent; absence fails closed.
    let mut command = Command::new("pkexec");
    command.arg("/usr/bin/true");
    command
}
pub(super) fn apply_dock_policy(_: &AppHandle, _: bool) {}
pub(super) fn configure_tray<R: Runtime>(tray: TrayIconBuilder<R>) -> TrayIconBuilder<R> {
    tray
}
