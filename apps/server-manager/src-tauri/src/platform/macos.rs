use std::process::Command;
use tauri::{tray::TrayIconBuilder, AppHandle, Runtime};

pub(super) use super::unix::{
    request_child_stop, restrict_settings_file, EXECUTABLE_SUFFIX, NODE_CANDIDATES, NODE_LOOKUP,
};
pub(super) const POSTGRES_CANDIDATES: &[&str] = &[
    "/opt/homebrew/opt/postgresql@16/bin",
    "/usr/local/opt/postgresql@16/bin",
    "/Library/PostgreSQL/16/bin",
];

pub(super) fn browser_command(url: &str) -> Command {
    let mut command = Command::new("open");
    command.arg(url);
    command
}

pub(super) fn configure_child_process(_: &mut Command) {}

pub(super) fn reset_authorization_command() -> Command {
    let mut command = Command::new("/usr/bin/osascript");
    // A fresh script avoids reusing the same script's five-minute authorization.
    // Only an elevated no-op is executed. The OS, not Codmes, receives the password.
    command.args(["-e", &format!("do shell script \"/usr/bin/true # codmes-reset-{:016x}\" with prompt \"Codmes Server: 기존 서버 계정과 모든 서버 자료를 초기화합니다.\" with administrator privileges", rand::random::<u64>())]);
    command
}

pub(super) fn apply_dock_policy(app: &AppHandle, show: bool) {
    let policy = if show {
        tauri::ActivationPolicy::Regular
    } else {
        tauri::ActivationPolicy::Accessory
    };
    let _ = app.set_activation_policy(policy);
}

pub(super) fn configure_tray<R: Runtime>(tray: TrayIconBuilder<R>) -> TrayIconBuilder<R> {
    tray.icon(menu_bar_template_icon('C'))
        .icon_as_template(true)
}

fn distance_to_segment(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) -> f32 {
    let dx = bx - ax;
    let dy = by - ay;
    let length_squared = dx * dx + dy * dy;
    let t = (((px - ax) * dx + (py - ay) * dy) / length_squared).clamp(0.0, 1.0);
    ((px - (ax + t * dx)).powi(2) + (py - (ay + t * dy)).powi(2)).sqrt()
}

fn menu_bar_template_icon(letter: char) -> tauri::image::Image<'static> {
    const SIZE: u32 = 32;
    const SAMPLES: u32 = 4;
    let mut rgba = Vec::with_capacity((SIZE * SIZE * 4) as usize);
    for y in 0..SIZE {
        for x in 0..SIZE {
            let mut covered = 0;
            for sy in 0..SAMPLES {
                for sx in 0..SAMPLES {
                    let px =
                        ((x * SAMPLES + sx) as f32 + 0.5) / (SIZE * SAMPLES) as f32 * 2.0 - 1.0;
                    let py =
                        ((y * SAMPLES + sy) as f32 + 0.5) / (SIZE * SAMPLES) as f32 * 2.0 - 1.0;
                    let filled = match letter {
                        'C' => {
                            let radius = (px * px + py * py).sqrt();
                            (0.47..=0.82).contains(&radius) && !(px > 0.16 && py.abs() < 0.57)
                        }
                        'K' => {
                            (-0.58..=-0.38).contains(&px) && py.abs() <= 0.82
                                || distance_to_segment(px, py, -0.40, 0.02, 0.55, -0.80) <= 0.12
                                || distance_to_segment(px, py, -0.40, -0.02, 0.55, 0.80) <= 0.12
                        }
                        _ => false,
                    };
                    covered += u32::from(filled);
                }
            }
            rgba.extend_from_slice(&[255, 255, 255, (covered * 255 / (SAMPLES * SAMPLES)) as u8]);
        }
    }
    tauri::image::Image::new_owned(rgba, SIZE, SIZE)
}

#[cfg(test)]
mod tests {
    use super::menu_bar_template_icon;

    #[test]
    fn menu_bar_icon_has_a_transparent_background() {
        let icon = menu_bar_template_icon('C');
        assert_eq!(icon.width(), 32);
        assert_eq!(icon.height(), 32);
        assert_eq!(icon.rgba()[3], 0);
        assert!(icon.rgba().chunks_exact(4).any(|pixel| pixel[3] > 0));
    }
}
