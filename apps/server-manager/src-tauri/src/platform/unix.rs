use std::{path::Path, process::Child};

pub(super) const EXECUTABLE_SUFFIX: &str = "";
pub(super) const NODE_LOOKUP: &str = "which";
// Preserve the existing development-runtime search order on Unix.
pub(super) const NODE_CANDIDATES: &[&str] = &[
    "/opt/homebrew/bin/node",
    "/usr/local/bin/node",
    "/usr/bin/node",
];

pub(super) fn request_child_stop(child: &mut Child) -> Result<(), String> {
    unsafe {
        libc::kill(child.id() as i32, libc::SIGTERM);
    }
    Ok(())
}

pub(super) fn restrict_settings_file(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn settings_are_readable_only_by_the_owner() {
        let file = std::env::temp_dir().join(format!(
            "codmes-permissions-{}-{}",
            std::process::id(),
            rand::random::<u64>()
        ));
        std::fs::write(&file, b"fixture only").unwrap();
        let result = restrict_settings_file(&file);
        let mode = std::fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        std::fs::remove_file(&file).unwrap();
        assert!(result.is_ok());
        assert_eq!(mode, 0o600);
    }
}
