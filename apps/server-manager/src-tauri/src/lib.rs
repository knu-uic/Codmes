mod manager;
mod google_oauth;
mod platform;
mod server_reset;

use manager::{GoogleOAuthConfigView, ManagerSnapshot, ServerManager, ServerSettings};
use platform::apply_dock_policy;
use std::{sync::Mutex, time::Duration};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager, RunEvent, WindowEvent,
};

#[derive(Default)]
struct ManagerSession(Mutex<Option<String>>);

impl ManagerSession {
    fn token(&self) -> Result<String, String> {
        self.0.lock().map_err(|error| error.to_string())?.clone()
            .ok_or_else(|| "Sign in to Server Manager first.".into())
    }

    fn set(&self, token: String) {
        *self.0.lock().expect("manager session lock") = Some(token);
    }

    fn clear(&self) -> Option<String> {
        self.0.lock().expect("manager session lock").take()
    }
}

#[tauri::command]
fn manager_authenticated(session: tauri::State<'_, ManagerSession>) -> bool {
    session.0.lock().expect("manager session lock").is_some()
}

#[tauri::command]
fn manager_snapshot(
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
) -> ManagerSnapshot {
    let mut snapshot = manager.snapshot();
    if session.token().is_err() {
        snapshot.logs.clear();
        snapshot.settings.workspace_root.clear();
        snapshot.settings.tls_cert_path.clear();
        snapshot.settings.tls_key_path.clear();
        snapshot.status.workspace_root.clear();
        snapshot.status.message = if snapshot.status.running {
            "Server is running.".into()
        } else {
            "Server is stopped.".into()
        };
        snapshot.runtime_message = if snapshot.runtime_ready {
            "Runtime ready.".into()
        } else {
            "Runtime unavailable.".into()
        };
    }
    snapshot
}

#[tauri::command]
fn save_server_settings(
    app: tauri::AppHandle,
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
    settings: ServerSettings,
) -> Result<(), String> {
    session.token()?;
    manager.save_settings(settings, &app)
}

#[tauri::command]
fn start_server(manager: tauri::State<'_, ServerManager>) -> Result<(), String> {
    manager.start()
}

#[tauri::command]
fn stop_server(manager: tauri::State<'_, ServerManager>, session: tauri::State<'_, ManagerSession>) -> Result<(), String> {
    session.token()?;
    manager.stop()
}

#[tauri::command]
fn restart_server(manager: tauri::State<'_, ServerManager>, session: tauri::State<'_, ManagerSession>) -> Result<(), String> {
    session.token()?;
    manager.restart()
}

fn manager_http_client(manager: &ServerManager, timeout: Duration) -> Result<(reqwest::Client, String), String> {
    let snapshot = manager.snapshot();
    if !snapshot.status.managed {
        return Err("Start the server with this Manager before setting up its account.".into());
    }
    let tls = !snapshot.settings.tls_cert_path.is_empty();
    let mut builder = reqwest::Client::builder().timeout(timeout);
    if tls {
        let bytes = std::fs::read(&snapshot.settings.tls_cert_path)
            .map_err(|error| format!("Could not read the TLS certificate: {error}"))?;
        let certificate = reqwest::Certificate::from_pem(&bytes)
            .map_err(|error| format!("Invalid TLS certificate: {error}"))?;
        builder = builder.add_root_certificate(certificate);
    }
    let client = builder.build().map_err(|error| error.to_string())?;
    let scheme = if tls { "https" } else { "http" };
    Ok((client, format!("{scheme}://127.0.0.1:{}", snapshot.settings.port)))
}

fn account_client(manager: &ServerManager) -> Result<(reqwest::Client, String), String> {
    manager_http_client(manager, Duration::from_secs(20))
}

async fn manager_json_response(response: reqwest::Response) -> Result<serde_json::Value, String> {
    let status = response.status();
    let body: serde_json::Value = response.json().await.map_err(|error| error.to_string())?;
    if !status.is_success() {
        return Err(body.get("error")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
            .unwrap_or_else(|| format!("Server returned HTTP {status}.")));
    }
    Ok(body)
}

#[tauri::command]
fn manager_google_oauth_config(manager: tauri::State<'_, ServerManager>) -> GoogleOAuthConfigView {
    manager.google_oauth_config_view()
}

#[tauri::command]
async fn manager_google_server_config(manager: tauri::State<'_, ServerManager>) -> Result<serde_json::Value, String> {
    // Startup readiness is polled by the UI; one probe must not stall it for 20 seconds.
    let (client, base) = manager_http_client(&manager, Duration::from_secs(2))?;
    let response = client.get(format!("{base}/api/google-auth/config"))
        .send().await.map_err(|error| error.to_string())?;
    manager_json_response(response).await
}

#[tauri::command]
async fn manager_server_setup(manager: tauri::State<'_, ServerManager>) -> Result<serde_json::Value, String> {
    let (client, base) = account_client(&manager)?;
    let response = client.get(format!("{base}/api/auth/admin/setup"))
        .header("X-Codmes-Manager-Secret", manager.manager_secret()).send().await.map_err(|e| e.to_string())?;
    let mut body = manager_json_response(response).await?;
    let availability = manager.reset_availability();
    body["resetAllowed"] = serde_json::json!(availability.is_ok());
    body["resetUnavailableReason"] = serde_json::json!(availability.err());
    Ok(body)
}

#[tauri::command]
async fn manager_fresh_start(
    app: tauri::AppHandle,
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
    sign_in: tauri::State<'_, google_oauth::SignInController>,
    mode: String, username: String, password: String, confirmation: String,
) -> Result<serde_json::Value, String> {
    if confirmation != "기존 서버 삭제" { return Err("삭제 확인 문구를 정확히 입력하세요.".into()); }
    if !["password", "google"].contains(&mode.as_str()) { return Err("Unsupported account mode.".into()); }
    if username.trim().is_empty() || password.chars().count() < 15 || password.encode_utf16().count() > 128 {
        return Err("새 Codmes ID와 15~128자 비밀번호를 입력하세요.".into());
    }
    manager.reset_availability()?;
    let attempt = sign_in.begin()?;
    let id_token = if mode == "google" {
        Some(google_oauth::obtain_id_token(manager.google_oauth_config(), attempt.cancellation_flag()).await?)
    } else { None };
    attempt.check_cancelled()?;
    let cancelled = attempt.cancellation_flag();
    let worker_app = app.clone();
    let result = tauri::async_runtime::spawn_blocking(move || -> Result<serde_json::Value, String> {
        platform::authorize_server_reset(&cancelled)?;
        if cancelled.load(std::sync::atomic::Ordering::SeqCst) { return Err("새 서버 만들기를 취소했습니다. 기존 서버를 유지합니다.".into()); }
        let manager = worker_app.state::<ServerManager>();
        manager.fresh_start(|manager| {
            tauri::async_runtime::block_on(async {
                let deadline = std::time::Instant::now() + Duration::from_secs(90);
                loop {
                    if cancelled.load(std::sync::atomic::Ordering::SeqCst) { return Err("새 서버 만들기를 취소했습니다.".into()); }
                    let (client, base) = manager_http_client(manager, Duration::from_secs(2))?;
                    if let Ok(response) = client.get(format!("{base}/api/google-auth/config")).send().await {
                        if response.status().is_success() { break; }
                    }
                    if std::time::Instant::now() >= deadline { return Err("새 서버가 준비되지 않았습니다.".into()); }
                    std::thread::sleep(Duration::from_millis(150));
                }
                let (client, base) = account_client(manager)?;
                let endpoint = if id_token.is_some() { "/api/google-auth/admin/bootstrap" } else { "/api/auth/admin/bootstrap" };
                let response = client.post(format!("{base}{endpoint}"))
                    .header("X-Codmes-Manager-Secret", manager.manager_secret())
                    .json(&serde_json::json!({"username":username, "password":password, "idToken":id_token, "deviceName":"Server Manager"}))
                    .send().await.map_err(|e| e.to_string())?;
                let body = manager_json_response(response).await?;
                if cancelled.load(std::sync::atomic::Ordering::SeqCst) { return Err("새 서버 만들기를 취소했습니다.".into()); }
                if body.pointer("/user/role").and_then(serde_json::Value::as_str) != Some("admin")
                    || body.get("token").and_then(serde_json::Value::as_str).is_none() {
                    return Err("새 관리자 계정 확인에 실패했습니다.".into());
                }
                Ok(body)
            })
        })
    }).await.map_err(|_| "새 서버 작업이 중단되었습니다. 앱을 다시 실행하면 미완료 작업을 복구합니다.".to_string())?;
    let mut body = result?;
    session.set(body.get("token").and_then(serde_json::Value::as_str).ok_or("Missing account session.")?.to_owned());
    body.as_object_mut().ok_or("Invalid account response.")?.remove("token");
    Ok(body)
}

#[tauri::command]
async fn manager_google_sign_in(
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
    sign_in: tauri::State<'_, google_oauth::SignInController>,
    mode: String,
    username: Option<String>,
    password: Option<String>,
    current_password: Option<String>,
) -> Result<serde_json::Value, String> {
    if !["bootstrap", "login", "change"].contains(&mode.as_str()) {
        return Err("Unsupported Google sign-in mode.".into());
    }
    let attempt = sign_in.begin()?;
    let (client, base) = account_client(&manager)?;
    let current_token = if mode == "change" { Some(session.token()?) } else { None };
    let id_token = google_oauth::obtain_id_token(manager.google_oauth_config(), attempt.cancellation_flag()).await?;
    attempt.check_cancelled()?;
    let secret = manager.manager_secret();
    if mode == "change" {
        let response = client.post(format!("{base}/api/google-auth/admin/change"))
            .header("X-Codmes-Manager-Secret", secret)
            .bearer_auth(current_token.expect("current session checked"))
            .json(&serde_json::json!({"idToken": &id_token, "currentPassword": current_password}))
            .send().await.map_err(|error| error.to_string())?;
        return manager_json_response(response).await;
    }
    let endpoint = if mode == "bootstrap" { "bootstrap" } else { "login" };
    let mut payload = serde_json::json!({"idToken": &id_token, "deviceName": "Server Manager"});
    if mode == "bootstrap" {
        payload["username"] = serde_json::json!(username);
        payload["password"] = serde_json::json!(password);
        payload["workspaceName"] = serde_json::json!("My Profile");
    }
    let response = client.post(format!("{base}/api/google-auth/admin/{endpoint}"))
        .header("X-Codmes-Manager-Secret", secret)
        .json(&payload)
        .send().await.map_err(|error| error.to_string())?;
    let body = manager_json_response(response).await?;
    if body.pointer("/user/role").and_then(serde_json::Value::as_str) != Some("admin") {
        return Err("Google account is not a Server Manager administrator.".into());
    }
    let token = body.get("token").and_then(serde_json::Value::as_str)
        .ok_or_else(|| "Server did not return an account session.".to_string())?;
    session.set(token.to_owned());
    let mut visible = body;
    visible.as_object_mut().expect("login response object").remove("token");
    Ok(visible)
}

#[tauri::command]
async fn manager_codmes_account(
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
    action: String,
    payload: Option<serde_json::Value>,
) -> Result<serde_json::Value, String> {
    if manager.reset_in_progress() { return Err("새 서버를 만드는 중입니다. 완료될 때까지 기다려 주세요.".into()); }
    let endpoint = match action.as_str() {
        "login" => "/api/auth/admin/login",
        "bootstrap" => "/api/auth/admin/bootstrap",
        "info" => "/api/auth/account",
        "credentials" => "/api/auth/account/credentials",
        "password" => "/api/auth/account/password",
        "unlink" => "/api/auth/account/google/unlink",
        _ => return Err("Unsupported account action.".into()),
    };
    let (client, base) = account_client(&manager)?;
    let mut request = if action == "info" { client.get(format!("{base}{endpoint}")) }
        else { client.post(format!("{base}{endpoint}")).json(&payload.unwrap_or_else(|| serde_json::json!({}))) };
    request = request.header("X-Codmes-Manager-Secret", manager.manager_secret());
    if !["login", "bootstrap"].contains(&action.as_str()) { request = request.bearer_auth(session.token()?); }
    let response = request.send().await.map_err(|error| error.to_string())?;
    let mut body = manager_json_response(response).await?;
    if ["login", "bootstrap"].contains(&action.as_str()) {
        let token = body.get("token").and_then(serde_json::Value::as_str).ok_or("Missing account session.")?;
        session.set(token.to_owned());
        body.as_object_mut().ok_or("Invalid account response.")?.remove("token");
    }
    Ok(body)
}

#[tauri::command]
fn manager_google_cancel_sign_in(sign_in: tauri::State<'_, google_oauth::SignInController>) {
    sign_in.cancel();
}

#[tauri::command]
async fn manager_account_logout(
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
) -> Result<(), String> {
    let Some(token) = session.clear() else { return Ok(()) };
    let (client, base) = account_client(&manager)?;
    let response = client.post(format!("{base}/api/auth/logout"))
        .bearer_auth(token).json(&serde_json::json!({}))
        .send().await.map_err(|error| error.to_string())?;
    manager_json_response(response).await.map(|_| ())
}

#[tauri::command]
async fn manager_profiles(
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
) -> Result<serde_json::Value, String> {
    let token = session.token()?;
    let (client, base) = account_client(&manager)?;
    let response = client.get(format!("{base}/api/admin/profiles"))
        .header("X-Codmes-Manager-Secret", manager.manager_secret())
        .bearer_auth(token).send().await.map_err(|error| error.to_string())?;
    manager_json_response(response).await
}

#[tauri::command]
async fn manager_profile_create(
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
    name: String,
    pin: String,
) -> Result<(), String> {
    let token = session.token()?;
    let (client, base) = account_client(&manager)?;
    let response = client.post(format!("{base}/api/admin/profiles"))
        .header("X-Codmes-Manager-Secret", manager.manager_secret())
        .bearer_auth(token)
        .json(&serde_json::json!({ "name": name, "pin": pin }))
        .send().await.map_err(|error| error.to_string())?;
    manager_json_response(response).await.map(|_| ())
}

#[tauri::command]
async fn manager_profile_action(
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
    profile_id: String,
    action: String,
    value: Option<String>,
) -> Result<(), String> {
    let token = session.token()?;
    if !["rename", "pin", "archive", "restore"].contains(&action.as_str()) {
        return Err("Unsupported profile action.".into());
    }
    if profile_id.len() != 36 || !profile_id.chars().all(|character| character.is_ascii_hexdigit() || character == '-') {
        return Err("Invalid profile ID.".into());
    }
    let (client, base) = account_client(&manager)?;
    let body = match action.as_str() {
        "rename" => serde_json::json!({ "name": value }),
        "pin" => serde_json::json!({ "pin": value }),
        _ => serde_json::json!({}),
    };
    let response = client.post(format!("{base}/api/admin/profiles/{}/{}", profile_id, action))
        .header("X-Codmes-Manager-Secret", manager.manager_secret())
        .bearer_auth(token).json(&body)
        .send().await.map_err(|error| error.to_string())?;
    manager_json_response(response).await.map(|_| ())
}

#[tauri::command]
async fn manager_plugins(
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
) -> Result<serde_json::Value, String> {
    let token = session.token()?;
    let (client, base) = manager_http_client(&manager, Duration::from_secs(30))?;
    let response = client.get(format!("{base}/api/admin/plugins"))
        .bearer_auth(token).send().await.map_err(|error| error.to_string())?;
    manager_json_response(response).await
}

#[tauri::command]
async fn manager_plugin_action(
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
    plugin_id: String,
    action: String,
    version: String,
    accepted_permissions: Vec<String>,
) -> Result<(), String> {
    let token = session.token()?;
    if !["install", "update"].contains(&action.as_str()) {
        return Err("Unsupported plugin action.".into());
    }
    if plugin_id.is_empty() || !plugin_id.chars().all(|character| character.is_ascii_lowercase()
        || character.is_ascii_digit() || matches!(character, '.' | '-' | '_')) {
        return Err("Invalid plugin ID.".into());
    }
    let (client, base) = manager_http_client(&manager, Duration::from_secs(90))?;
    let response = client.post(format!("{base}/api/admin/plugins/{plugin_id}/{action}"))
        .bearer_auth(token)
        .json(&serde_json::json!({
            "version": version,
            "acceptedPermissions": accepted_permissions
        }))
        .send().await.map_err(|error| error.to_string())?;
    manager_json_response(response).await.map(|_| ())
}

fn client_registration_request(
    client: &reqwest::Client,
    base: &str,
    method: reqwest::Method,
    suffix: &str,
    token: &str,
    manager_secret: &str,
) -> reqwest::RequestBuilder {
    client.request(method, format!("{base}/api/admin/client-registrations{suffix}"))
        .bearer_auth(token)
        .header("X-Codmes-Manager-Secret", manager_secret)
}

#[tauri::command]
async fn manager_client_registrations(
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
) -> Result<serde_json::Value, String> {
    let token = session.token()?;
    let (client, base) = account_client(&manager)?;
    let response = client_registration_request(&client, &base, reqwest::Method::GET, "", &token, manager.manager_secret())
        .send().await.map_err(|error| error.to_string())?;
    manager_json_response(response).await
}

#[tauri::command]
async fn manager_client_registration_action(
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
    registration_id: String,
    action: String,
) -> Result<(), String> {
    if !["approve", "reject", "remove"].contains(&action.as_str()) {
        return Err("Unsupported registration action.".into());
    }
    if registration_id.len() != 36 || !registration_id.chars().all(|c| c.is_ascii_hexdigit() || c == '-') {
        return Err("Invalid registration ID.".into());
    }
    let token = session.token()?;
    let (client, base) = account_client(&manager)?;
    let response = client_registration_request(&client, &base, reqwest::Method::POST,
        &format!("/{registration_id}/{action}"), &token, manager.manager_secret())
        .json(&serde_json::json!({}))
        .send().await.map_err(|error| error.to_string())?;
    manager_json_response(response).await.map(|_| ())
}

#[tauri::command]
async fn manager_client_registration_mode(
    manager: tauri::State<'_, ServerManager>,
    session: tauri::State<'_, ManagerSession>,
    mode: String,
) -> Result<(), String> {
    if !["ask", "allow"].contains(&mode.as_str()) {
        return Err("Unsupported client approval mode.".into());
    }
    let token = session.token()?;
    let (client, base) = account_client(&manager)?;
    let response = client_registration_request(&client, &base, reqwest::Method::PUT, "/mode", &token, manager.manager_secret())
        .json(&serde_json::json!({"mode": mode}))
        .send().await.map_err(|error| error.to_string())?;
    manager_json_response(response).await.map(|_| ())
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
        .plugin(platform::autostart_plugin())
        .invoke_handler(tauri::generate_handler![
            manager_snapshot,
            save_server_settings,
            start_server,
            stop_server,
            restart_server,
            manager_authenticated,
            manager_codmes_account,
            manager_google_oauth_config,
            manager_google_server_config,
            manager_server_setup,
            manager_fresh_start,
            manager_google_sign_in,
            manager_google_cancel_sign_in,
            manager_account_logout,
            manager_profiles,
            manager_profile_create,
            manager_profile_action,
            manager_plugins,
            manager_plugin_action,
            manager_client_registrations,
            manager_client_registration_action,
            manager_client_registration_mode,
        ])
        .setup(|app| {
            let manager = ServerManager::new(&app.handle())?;
            let snapshot = manager.snapshot();
            apply_dock_policy(&app.handle(), snapshot.settings.show_dock_icon);
            let should_start = snapshot.settings.start_on_launch && !snapshot.status.running;
            app.manage(manager);
            app.manage(ManagerSession::default());
            app.manage(google_oauth::SignInController::default());

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
                        if app.state::<ManagerSession>().token().is_ok() {
                            let _ = app.state::<ServerManager>().stop();
                        } else {
                            show_manager(app);
                        }
                    }
                    "quit" => {
                        if app.state::<ServerManager>().reset_in_progress() { show_manager(app); return; }
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
            platform::configure_tray(tray).build(app)?;

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
        RunEvent::ExitRequested { api, .. } => {
            if app.state::<ServerManager>().reset_in_progress() { api.prevent_exit(); }
            else { app.state::<ServerManager>().stop_if_managed(); }
        }
        RunEvent::Exit => {
            app.state::<ServerManager>().stop_if_managed();
        }
        _ => {}
    });
}

#[cfg(test)]
mod registration_request_tests {
    use super::*;

    #[test]
    fn every_client_registration_request_includes_both_manager_credentials() {
        let client = reqwest::Client::new();
        for (method, suffix) in [
            (reqwest::Method::GET, ""),
            (reqwest::Method::PUT, "/mode"),
            (reqwest::Method::POST, "/test-registration/approve"),
            (reqwest::Method::POST, "/test-registration/reject"),
            (reqwest::Method::POST, "/test-registration/remove"),
        ] {
            let request = client_registration_request(&client, "http://127.0.0.1:8787",
                method.clone(), suffix, "test-admin-session", "test-manager-secret")
                .build().unwrap();
            assert_eq!(request.method(), method);
            assert_eq!(request.url().path(), format!("/api/admin/client-registrations{suffix}"));
            assert_eq!(request.headers()["authorization"], "Bearer test-admin-session");
            assert_eq!(request.headers()["x-codmes-manager-secret"], "test-manager-secret");
        }
    }
}
