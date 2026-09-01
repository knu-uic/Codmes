mod manager;

use manager::{apply_dock_policy, generate_token, ManagerSnapshot, ServerManager, ServerSettings};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager, RunEvent, WindowEvent,
};
use tauri_plugin_autostart::MacosLauncher;

#[tauri::command]
fn manager_snapshot(manager: tauri::State<'_, ServerManager>) -> ManagerSnapshot {
    manager.snapshot()
}

#[tauri::command]
fn save_server_settings(
    app: tauri::AppHandle,
    manager: tauri::State<'_, ServerManager>,
    settings: ServerSettings,
) -> Result<(), String> {
    manager.save_settings(settings, &app)
}

#[tauri::command]
fn start_server(manager: tauri::State<'_, ServerManager>) -> Result<(), String> {
    manager.start()
}

#[tauri::command]
fn stop_server(manager: tauri::State<'_, ServerManager>) -> Result<(), String> {
    manager.stop()
}

#[tauri::command]
fn restart_server(manager: tauri::State<'_, ServerManager>) -> Result<(), String> {
    manager.restart()
}

#[tauri::command]
fn generate_server_token() -> String {
    generate_token()
}

fn show_manager(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            Some(vec!["--minimized"]),
        ))
        .invoke_handler(tauri::generate_handler![
            manager_snapshot,
            save_server_settings,
            start_server,
            stop_server,
            restart_server,
            generate_server_token
        ])
        .setup(|app| {
            let manager = ServerManager::new(&app.handle())?;
            let snapshot = manager.snapshot();
            apply_dock_policy(&app.handle(), snapshot.settings.show_dock_icon);
            let should_start = snapshot.settings.start_on_launch && !snapshot.status.running;
            app.manage(manager);

            let open = MenuItem::with_id(app, "open", "Open Codmes Server", true, None::<&str>)?;
            let start = MenuItem::with_id(app, "start", "Start Server", true, None::<&str>)?;
            let stop = MenuItem::with_id(app, "stop", "Stop Server", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Codmes Server", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &start, &stop, &quit])?;
            let mut tray = TrayIconBuilder::new()
                .tooltip("Codmes Server")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "open" => show_manager(app),
                    "start" => {
                        let _ = app.state::<ServerManager>().start();
                    }
                    "stop" => {
                        let _ = app.state::<ServerManager>().stop();
                    }
                    "quit" => {
                        app.state::<ServerManager>().stop_if_managed();
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        show_manager(tray.app_handle());
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            #[cfg(target_os = "macos")]
            {
                tray = tray.icon_as_template(true);
            }
            tray.build(app)?;

            if std::env::args().any(|arg| arg == "--minimized") {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.hide();
                }
            }
            if should_start {
                let _ = app.state::<ServerManager>().start();
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building Codmes Server Manager");

    app.run(|app, event| match event {
        RunEvent::WindowEvent {
            label,
            event: WindowEvent::CloseRequested { api, .. },
            ..
        } if label == "main" => {
            api.prevent_close();
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.hide();
            }
        }
        RunEvent::ExitRequested { .. } => {
            app.state::<ServerManager>().stop_if_managed();
        }
        RunEvent::Exit => {
            app.state::<ServerManager>().stop_if_managed();
        }
        _ => {}
    });
}
