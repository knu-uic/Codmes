use crate::platform::{self, apply_dock_policy, find_postgres_bin, find_system_node, restrict_settings_file, terminate_child};
use crate::server_reset::{self, ResetTransaction};
use serde::{Deserialize, Serialize};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use std::{
    collections::VecDeque,
    fs,
    io::{BufRead, BufReader, Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{atomic::{AtomicBool, Ordering}, Arc, Mutex, MutexGuard},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::{AppHandle, Manager};
use tauri_plugin_autostart::ManagerExt;

const MAX_LOG_LINES: usize = 500;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerSettings {
    pub workspace_root: String,
    pub host: String,
    pub port: u16,
    #[serde(default = "default_postgres_port")]
    pub postgres_port: u16,
    pub start_on_launch: bool,
    pub launch_at_login: bool,
    pub show_dock_icon: bool,
    #[serde(default)]
    pub tls_cert_path: String,
    #[serde(default)]
    pub tls_key_path: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerStatus {
    pub running: bool,
    pub managed: bool,
    pub pid: Option<u32>,
    pub url: String,
    pub workspace_root: String,
    pub started_at: Option<u64>,
    pub message: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ManagerSnapshot {
    pub settings: ServerSettings,
    pub status: ServerStatus,
    pub logs: Vec<String>,
    pub runtime_ready: bool,
    pub runtime_message: String,
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GoogleOAuthConfig {
    pub desktop_client_id: String,
    #[serde(default, skip_serializing)]
    pub desktop_client_secret: String,
    #[serde(default)]
    pub macos_client_id: String,
    #[serde(default)]
    pub ios_client_id: String,
    #[serde(default)]
    pub android_client_id: String,
    #[serde(default)]
    pub web_client_id: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GoogleOAuthConfigView {
    pub configured: bool,
}

struct ProcessState {
    child: Option<Child>,
    started_at: Option<u64>,
    logs: VecDeque<String>,
}

pub struct ServerManager {
    settings_path: PathBuf,
    oauth: GoogleOAuthConfig,
    manager_secret: String,
    server_root: PathBuf,
    node_path: PathBuf,
    postgres_bin_path: Option<PathBuf>,
    settings: Mutex<ServerSettings>,
    process: Arc<Mutex<ProcessState>>,
    operation: Mutex<()>,
    resetting: AtomicBool,
    recovery_error: Mutex<Option<String>>,
}

impl ServerManager {
    pub fn new(app: &AppHandle) -> Result<Self, String> {
        let config_dir = app
            .path()
            .app_config_dir()
            .map_err(|error| error.to_string())?;
        fs::create_dir_all(&config_dir).map_err(|error| error.to_string())?;
        let settings_path = config_dir.join("server-manager.json");
        let oauth = embedded_google_oauth_config();
        let settings = load_settings(&settings_path)
            .unwrap_or_else(|| ServerSettings::for_managed_workspace(config_dir.join("workspace")));
        let (server_root, node_path) = resolve_runtime(app);
        let postgres_bin_path = find_postgres_bin(&server_root);
        let manager = Self {
            settings_path,
            oauth,
            manager_secret: URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>()),
            server_root,
            node_path,
            postgres_bin_path,
            settings: Mutex::new(settings),
            process: Arc::new(Mutex::new(ProcessState {
                child: None,
                started_at: None,
                logs: VecDeque::new(),
            })),
            operation: Mutex::new(()),
            resetting: AtomicBool::new(false),
            recovery_error: Mutex::new(None),
        };
        if let Err(error) = manager.recover_pending_reset() {
            *manager.recovery_error.lock().expect("recovery lock") = Some(error);
        }
        Ok(manager)
    }

    pub fn manager_secret(&self) -> &str {
        &self.manager_secret
    }

    pub fn google_oauth_config(&self) -> GoogleOAuthConfig {
        self.oauth.clone()
    }

    pub fn google_oauth_config_view(&self) -> GoogleOAuthConfigView {
        GoogleOAuthConfigView {
            configured: valid_google_client_id(&self.oauth.desktop_client_id)
                && !self.oauth.desktop_client_secret.is_empty(),
        }
    }

    pub fn snapshot(&self) -> ManagerSnapshot {
        let settings = self.settings.lock().expect("settings lock").clone();
        let (runtime_ready, runtime_message) = self.runtime_status();
        let mut process = self.process.lock().expect("process lock");
        reap_child(&mut process);
        let managed = process.child.is_some();
        let pid = process.child.as_ref().map(Child::id);
        let running = probe_codmes(&settings);
        let message = if running && managed {
            "Codmes Server is running under this Manager.".to_string()
        } else if running {
            "A Codmes Server is already running outside this Manager.".to_string()
        } else if managed {
            "Codmes Server is starting…".to_string()
        } else {
            "Codmes Server is stopped.".to_string()
        };
        ManagerSnapshot {
            status: ServerStatus {
                running: running || managed,
                managed,
                pid,
                url: display_url(&settings),
                workspace_root: settings.workspace_root.clone(),
                started_at: process.started_at,
                message,
            },
            settings,
            logs: process.logs.iter().cloned().collect(),
            runtime_ready,
            runtime_message,
        }
    }

    pub fn save_settings(&self, settings: ServerSettings, app: &AppHandle) -> Result<(), String> {
        let _operation = self.lock_operation()?;
        validate_settings(&settings)?;
        if let Some(parent) = self.settings_path.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        fs::create_dir_all(&settings.workspace_root)
            .map_err(|error| format!("Could not create the Workspace folder: {error}"))?;
        server_reset::mark_workspace(Path::new(&settings.workspace_root), &self.default_workspace())?;
        let bytes = serde_json::to_vec_pretty(&settings).map_err(|error| error.to_string())?;
        fs::write(&self.settings_path, bytes).map_err(|error| error.to_string())?;
        restrict_settings_file(&self.settings_path)?;
        if settings.launch_at_login {
            app.autolaunch()
                .enable()
                .map_err(|error| error.to_string())?;
        } else {
            app.autolaunch()
                .disable()
                .map_err(|error| error.to_string())?;
        }
        apply_dock_policy(app, settings.show_dock_icon);
        *self.settings.lock().expect("settings lock") = settings;
        Ok(())
    }

    pub fn start(&self) -> Result<(), String> {
        let _operation = self.lock_operation()?;
        self.start_inner()
    }

    fn start_inner(&self) -> Result<(), String> {
        if let Some(error) = self.recovery_error.lock().expect("recovery lock").as_ref() {
            return Err(error.clone());
        }
        let mut settings = self.settings.lock().expect("settings lock").clone();
        validate_settings(&settings)?;
        if probe_codmes(&settings) {
            return Err("A Codmes Server is already running at this address.".to_string());
        }
        let original_api_port = settings.port;
        settings.port = select_available_port(settings.port, 8787, 8806, "Codmes API")?;
        let original_postgres_port = settings.postgres_port;
        settings.postgres_port = if let Some(port) = running_managed_postgres_port(
            Path::new(&settings.workspace_root),
            self.postgres_bin_path.as_deref(),
        ) {
            port
        } else {
            select_available_port(settings.postgres_port, 55432, 55449, "PostgreSQL")?
        };
        if settings.port != original_api_port || settings.postgres_port != original_postgres_port {
            persist_settings(&self.settings_path, &settings)?;
            *self.settings.lock().expect("settings lock") = settings.clone();
        }
        let (ready, message) = self.runtime_status();
        if !ready {
            return Err(message);
        }
        fs::create_dir_all(&settings.workspace_root)
            .map_err(|error| format!("Could not create the Workspace folder: {error}"))?;
        server_reset::mark_workspace(Path::new(&settings.workspace_root), &self.default_workspace())?;

        let mut process = self.process.lock().expect("process lock");
        reap_child(&mut process);
        if process.child.is_some() {
            return Err("Codmes Server is already starting.".to_string());
        }
        if settings.port != original_api_port || settings.postgres_port != original_postgres_port {
            append_log(
                &mut process.logs,
                &format!(
                    "[manager] adjusted occupied ports: API {} -> {}, PostgreSQL {} -> {}",
                    original_api_port,
                    settings.port,
                    original_postgres_port,
                    settings.postgres_port
                ),
            );
        }
        append_log(&mut process.logs, "[manager] starting Codmes Server");
        let mut command = Command::new(&self.node_path);
        command
            .arg(self.server_root.join("server/index.mjs"))
            .current_dir(&self.server_root)
            .env("CODMES_WORKSPACE_ROOT", &settings.workspace_root)
            .env("CODMES_HOST", &settings.host)
            .env("CODMES_PORT", settings.port.to_string())
            .env("CODMES_DATA_ROOT", &settings.workspace_root)
            .env("CODMES_POSTGRES_PORT", settings.postgres_port.to_string())
            .env("CODMES_GOOGLE_DESKTOP_CLIENT_ID", self.google_oauth_config().desktop_client_id)
            .env("CODMES_GOOGLE_MACOS_CLIENT_ID", self.google_oauth_config().macos_client_id)
            .env("CODMES_GOOGLE_IOS_CLIENT_ID", self.google_oauth_config().ios_client_id)
            .env("CODMES_GOOGLE_ANDROID_CLIENT_ID", self.google_oauth_config().android_client_id)
            .env("CODMES_GOOGLE_WEB_CLIENT_ID", self.google_oauth_config().web_client_id)
            .env("CODMES_MANAGER_BOOTSTRAP_SECRET", &self.manager_secret)
            .env(
                "CODMES_MULTIUSER_ENABLED",
                "true",
            )
            .env(
                "CODMES_MANAGED_POSTGRES",
                "true",
            )
            .env(
                "CODMES_SEARCH_BACKEND",
                "postgres",
            )
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if !settings.tls_cert_path.is_empty() {
            command.env("CODMES_TLS_CERT", &settings.tls_cert_path)
                .env("CODMES_TLS_KEY", &settings.tls_key_path);
        }
        if let Some(postgres_bin_path) = &self.postgres_bin_path {
            command.env("CODMES_POSTGRES_BIN", postgres_bin_path);
        }
        platform::configure_child_process(&mut command);
        let mut child = command
            .spawn()
            .map_err(|error| format!("Could not start the bundled Codmes runtime: {error}"))?;
        if let Some(stdout) = child.stdout.take() {
            stream_logs(stdout, self.process.clone(), "server");
        }
        if let Some(stderr) = child.stderr.take() {
            stream_logs(stderr, self.process.clone(), "error");
        }
        process.started_at = Some(now_seconds());
        process.child = Some(child);
        Ok(())
    }

    pub fn stop(&self) -> Result<(), String> {
        let _operation = self.lock_operation()?;
        self.stop_inner()
    }

    fn stop_inner(&self) -> Result<(), String> {
        let mut child = {
            let mut process = self.process.lock().expect("process lock");
            reap_child(&mut process);
            let Some(child) = process.child.take() else {
                return Err("This Manager did not start the running server.".to_string());
            };
            append_log(&mut process.logs, "[manager] stopping Codmes Server");
            process.started_at = None;
            child
        };
        if let Err(error) = terminate_child(&mut child) {
            self.process.lock().expect("process lock").child = Some(child);
            return Err(error);
        }
        Ok(())
    }

    pub fn restart(&self) -> Result<(), String> {
        let _operation = self.lock_operation()?;
        self.stop_inner()?;
        thread::sleep(Duration::from_millis(250));
        self.start_inner()
    }

    fn lock_operation(&self) -> Result<MutexGuard<'_, ()>, String> {
        self.operation.try_lock().map_err(|_| "서버 작업이 진행 중입니다. 완료될 때까지 기다려 주세요.".into())
    }

    fn default_workspace(&self) -> PathBuf {
        self.settings_path.parent().expect("settings directory").join("workspace")
    }

    pub fn reset_in_progress(&self) -> bool { self.resetting.load(Ordering::SeqCst) }

    pub fn reset_availability(&self) -> Result<(), String> {
        let settings = self.settings.lock().expect("settings lock").clone();
        server_reset::validate_workspace(Path::new(&settings.workspace_root), &self.default_workspace())
    }

    // Called only from a native command after explicit confirmation and OS authentication.
    // Signup is performed on the clean server; failure restores the original server.
    pub fn fresh_start<F>(&self, signup: F) -> Result<serde_json::Value, String>
    where F: FnOnce(&Self) -> Result<serde_json::Value, String> {
        let _operation = self.lock_operation()?;
        self.reset_availability()?;
        let old = self.settings.lock().expect("settings lock").clone();
        if !self.process.lock().expect("process lock").child.is_some() {
            return Err("이 Manager에서 시작한 서버만 초기화할 수 있습니다.".into());
        }
        self.resetting.store(true, Ordering::SeqCst);
        struct ResetFlag<'a>(&'a AtomicBool);
        impl Drop for ResetFlag<'_> { fn drop(&mut self) { self.0.store(false, Ordering::SeqCst); } }
        let _reset_flag = ResetFlag(&self.resetting);
        self.stop_inner()?;
        if let Err(error) = self.stop_postgres(Path::new(&old.workspace_root)) {
            let _ = self.start_inner(); return Err(error);
        }
        let mut transaction = match ResetTransaction::begin(&self.settings_path, &old, &self.default_workspace()) {
            Ok(transaction) => transaction,
            Err(error) => { let _ = self.start_inner(); return Err(error); }
        };
        let mut fresh = ServerSettings::for_managed_workspace(PathBuf::from(&old.workspace_root));
        fresh.port = old.port;
        fresh.postgres_port = old.postgres_port;
        // Native app presentation/autostart preferences are not server access rights.
        fresh.start_on_launch = old.start_on_launch;
        fresh.launch_at_login = old.launch_at_login;
        fresh.show_dock_icon = old.show_dock_icon;
        *self.settings.lock().expect("settings lock") = fresh;
        let result = self.start_inner().and_then(|_| signup(self));
        let mut body = match result {
            Ok(body) => body,
            Err(error) => {
                self.rollback_reset(&transaction)?;
                return Err(format!("새 서버 생성에 실패했습니다. 기존 서버를 복원했습니다. {error}"));
            }
        };
        if let Err(error) = persist_settings(&self.settings_path, &self.settings.lock().expect("settings lock")) {
            self.rollback_reset(&transaction)?; return Err(error);
        }
        match transaction.commit() {
            Ok(warning) => {
                body["resetCleanupWarning"] = warning.map_or(serde_json::Value::Null, serde_json::Value::String);
                self.process.lock().expect("process lock").logs.clear();
                Ok(body)
            }
            Err(error) => { self.rollback_reset(&transaction)?; Err(error) }
        }
    }

    fn rollback_reset(&self, transaction: &ResetTransaction) -> Result<(), String> {
        if self.process.lock().expect("process lock").child.is_some() { self.stop_inner()?; }
        self.stop_postgres(transaction.roots()[0])?;
        transaction.rollback()?;
        let old = transaction.previous_settings().clone();
        persist_settings(&self.settings_path, &old)?;
        *self.settings.lock().expect("settings lock") = old;
        self.start_inner().map_err(|e| format!("기존 자료는 복원했지만 서버를 다시 시작하지 못했습니다: {e}"))
    }

    fn recover_pending_reset(&self) -> Result<(), String> {
        let Some(transaction) = ResetTransaction::pending(&self.settings_path, &self.default_workspace())? else { return Ok(()) };
        if probe_codmes(&self.settings.lock().expect("settings lock")) {
            return Err("중단된 초기화가 있으나 서버 프로세스가 실행 중입니다. 해당 서버를 종료한 뒤 다시 실행하세요. 자료는 변경하지 않았습니다.".into());
        }
        for root in transaction.roots() { self.stop_postgres(root)?; }
        if transaction.committed() { transaction.cleanup() }
        else {
            transaction.rollback()?;
            let old = transaction.previous_settings().clone();
            persist_settings(&self.settings_path, &old)?;
            *self.settings.lock().expect("settings lock") = old;
            Ok(())
        }
    }

    fn stop_postgres(&self, root: &Path) -> Result<(), String> {
        let data = root.join("postgres/data");
        if !data.join("PG_VERSION").exists() { return Ok(()); }
        let bin = self.postgres_bin_path.as_ref().ok_or("데이터베이스를 안전하게 종료할 실행 환경이 없습니다.")?;
        let pg_ctl = bin.join(platform::executable_name("pg_ctl"));
        let mut status_command = Command::new(&pg_ctl);
        status_command.arg("-D").arg(&data).arg("status");
        platform::configure_child_process(&mut status_command);
        let status = status_command.output().map_err(|e| e.to_string())?;
        if status.status.code() == Some(3) { return Ok(()); } // pg_ctl: not running
        if !status.status.success() { return Err("데이터베이스 상태를 확인하지 못했습니다. 데이터는 삭제하지 않았습니다.".into()); }
        let mut stop = Command::new(pg_ctl);
        stop.arg("-D").arg(data).args(["-m", "fast", "-w", "-t", "20", "stop"]);
        platform::configure_child_process(&mut stop);
        if stop.output().map_err(|e| e.to_string())?.status.success() { Ok(()) }
        else { Err("데이터베이스 종료에 실패했습니다. 데이터는 삭제하지 않았습니다.".into()) }
    }

    pub fn stop_if_managed(&self) {
        let has_child = self.process.lock().expect("process lock").child.is_some();
        if has_child {
            let _ = self.stop();
        }
    }

    fn runtime_status(&self) -> (bool, String) {
        if let Some(error) = self.recovery_error.lock().expect("recovery lock").as_ref() {
            return (false, error.clone());
        }
        if !self.node_path.is_file() {
            return (
                false,
                format!("Node runtime not found at {}", self.node_path.display()),
            );
        }
        let server_entry = self.server_root.join("server/index.mjs");
        if !server_entry.is_file() {
            return (
                false,
                format!(
                    "Codmes server files not found at {}",
                    self.server_root.display()
                ),
            );
        }
        if self.postgres_bin_path.is_none() {
            return (
                false,
                "PostgreSQL runtime not found. Reinstall the complete Server package.".to_string(),
            );
        }
        (
            true,
            format!(
                "Runtime ready · {} · {}",
                self.node_path.display(),
                self.server_root.display()
            ),
        )
    }
}

fn valid_google_client_id(value: &str) -> bool {
    value.strip_suffix(".apps.googleusercontent.com")
        .is_some_and(|prefix| !prefix.is_empty()
            && prefix.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_')))
}

fn embedded_google_oauth_config() -> GoogleOAuthConfig {
    GoogleOAuthConfig {
        desktop_client_id: option_env!("CODMES_BUNDLED_GOOGLE_DESKTOP_CLIENT_ID").unwrap_or("").trim().to_owned(),
        desktop_client_secret: option_env!("CODMES_BUNDLED_GOOGLE_DESKTOP_CLIENT_SECRET").unwrap_or("").trim().to_owned(),
        macos_client_id: option_env!("CODMES_BUNDLED_GOOGLE_MACOS_CLIENT_ID").unwrap_or("").trim().to_owned(),
        ios_client_id: option_env!("CODMES_BUNDLED_GOOGLE_IOS_CLIENT_ID").unwrap_or("").trim().to_owned(),
        android_client_id: option_env!("CODMES_BUNDLED_GOOGLE_ANDROID_CLIENT_ID").unwrap_or("").trim().to_owned(),
        web_client_id: option_env!("CODMES_BUNDLED_GOOGLE_WEB_CLIENT_ID").unwrap_or("").trim().to_owned(),
    }
}

impl Default for ServerSettings {
    fn default() -> Self {
        let workspace = directories::BaseDirs::new()
            .map(|dirs| dirs.data_local_dir().join("Codmes").join("workspace"))
            .unwrap_or_else(|| PathBuf::from("CodmesData").join("workspace"));
        Self::for_managed_workspace(workspace)
    }
}

impl ServerSettings {
    fn for_managed_workspace(workspace: PathBuf) -> Self {
        Self {
            workspace_root: workspace.to_string_lossy().to_string(),
            host: "127.0.0.1".to_string(),
            port: 8787,
            postgres_port: default_postgres_port(),
            start_on_launch: true,
            launch_at_login: false,
            show_dock_icon: false,
            tls_cert_path: String::new(),
            tls_key_path: String::new(),
        }
    }
}

fn load_settings(path: &Path) -> Option<ServerSettings> {
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

fn default_postgres_port() -> u16 {
    55432
}

fn persist_settings(path: &Path, settings: &ServerSettings) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let bytes = serde_json::to_vec_pretty(settings).map_err(|error| error.to_string())?;
    fs::write(path, bytes).map_err(|error| error.to_string())?;
    restrict_settings_file(path)
}

fn select_available_port(preferred: u16, start: u16, end: u16, name: &str) -> Result<u16, String> {
    if TcpListener::bind(("127.0.0.1", preferred)).is_ok() {
        return Ok(preferred);
    }
    (start..=end)
        .find(|port| *port != preferred && TcpListener::bind(("127.0.0.1", *port)).is_ok())
        .ok_or_else(|| format!("No available port for {name} in the {start}-{end} range."))
}

fn running_managed_postgres_port(data_root: &Path, bin_directory: Option<&Path>) -> Option<u16> {
    let bin_directory = bin_directory?;
    let data_directory = data_root.join("postgres/data");
    let pg_ctl = bin_directory.join(platform::executable_name("pg_ctl"));
    let status = Command::new(pg_ctl)
        .args(["-D", &data_directory.to_string_lossy(), "status"])
        .output()
        .ok()?;
    if !status.status.success() {
        return None;
    }
    let pid_file = fs::read_to_string(data_directory.join("postmaster.pid")).ok()?;
    let port = pid_file.lines().nth(3)?.trim().parse::<u16>().ok()?;
    TcpStream::connect_timeout(
        &SocketAddr::from(([127, 0, 0, 1], port)),
        Duration::from_millis(150),
    )
    .ok()
    .map(|_| port)
}

fn validate_settings(settings: &ServerSettings) -> Result<(), String> {
    if !["127.0.0.1", "0.0.0.0"].contains(&settings.host.as_str()) {
        return Err("Access must be limited to this computer or the local network.".to_string());
    }
    if settings.port < 1024 {
        return Err("Port must be between 1024 and 65535.".to_string());
    }
    if settings.postgres_port < 1024 {
        return Err("PostgreSQL port must be between 1024 and 65535.".to_string());
    }
    if settings.workspace_root.trim().is_empty()
        || !Path::new(&settings.workspace_root).is_absolute()
    {
        return Err("Workspace folder must be an absolute path.".to_string());
    }
    let cert = settings.tls_cert_path.trim();
    let key = settings.tls_key_path.trim();
    if cert.is_empty() != key.is_empty() {
        return Err("Provide both a TLS certificate and private key, or neither.".into());
    }
    if !cert.is_empty() && (!Path::new(cert).is_absolute() || !Path::new(cert).is_file()) {
        return Err("TLS certificate must be an existing absolute PEM file.".into());
    }
    if !key.is_empty() && (!Path::new(key).is_absolute() || !Path::new(key).is_file()) {
        return Err("TLS private key must be an existing absolute PEM file.".into());
    }
    Ok(())
}

fn resolve_runtime(app: &AppHandle) -> (PathBuf, PathBuf) {
    if let (Ok(root), Ok(node)) = (
        std::env::var("CODMES_MANAGER_SERVER_ROOT"),
        std::env::var("CODMES_MANAGER_NODE"),
    ) {
        return (PathBuf::from(root), PathBuf::from(node));
    }

    if cfg!(debug_assertions) {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(Path::parent)
            .and_then(Path::parent)
            .expect("server manager lives under apps/server-manager/src-tauri")
            .to_path_buf();
        return (repo_root, find_system_node());
    }

    let resource_dir = app
        .path()
        .resource_dir()
        .unwrap_or_else(|_| PathBuf::from("."));
    let node_name = platform::executable_name("node");
    (
        resource_dir.join("runtime/codmes"),
        resource_dir.join("runtime/bin").join(node_name),
    )
}

fn display_url(settings: &ServerSettings) -> String {
    let host = if settings.host == "0.0.0.0" {
        "localhost"
    } else {
        &settings.host
    };
    let scheme = if settings.tls_cert_path.is_empty() { "http" } else { "https" };
    format!("{scheme}://{host}:{}", settings.port)
}

fn probe_codmes(settings: &ServerSettings) -> bool {
    let address = SocketAddr::from(([127, 0, 0, 1], settings.port));
    let Ok(mut stream) = TcpStream::connect_timeout(&address, Duration::from_millis(180)) else {
        return false;
    };
    if !settings.tls_cert_path.is_empty() {
        // TLS health is verified by subsequent authenticated HTTPS requests. A TCP
        // connection is enough here to avoid sending cleartext to the TLS socket.
        return true;
    }
    let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(250)));
    let request = format!(
        "GET /api/health HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nConnection: close\r\n\r\n",
        settings.port
    );
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }
    let mut response = String::new();
    stream.read_to_string(&mut response).is_ok()
        && response.starts_with("HTTP/1.1 200")
        && response.contains("\"service\": \"codmes\"")
}

fn stream_logs<R: Read + Send + 'static>(
    reader: R,
    state: Arc<Mutex<ProcessState>>,
    source: &'static str,
) {
    thread::spawn(move || {
        for line in BufReader::new(reader).lines().map_while(Result::ok) {
            let mut process = state.lock().expect("process lock");
            append_log(&mut process.logs, &format!("[{source}] {line}"));
        }
    });
}

fn append_log(logs: &mut VecDeque<String>, line: &str) {
    if logs.len() >= MAX_LOG_LINES {
        logs.pop_front();
    }
    logs.push_back(line.to_string());
}

fn reap_child(process: &mut ProcessState) {
    let exited = process
        .child
        .as_mut()
        .and_then(|child| child.try_wait().ok().flatten());
    if let Some(status) = exited {
        append_log(
            &mut process.logs,
            &format!("[manager] server exited with {status}"),
        );
        process.child = None;
        process.started_at = None;
    }
}

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Real lifecycle/database fixture: never uses the app's config directory, ports,
    // accounts or documents. OS authorization is deliberately not invoked by tests.
    struct IsolatedServer { base: PathBuf, manager: ServerManager }
    impl IsolatedServer {
        fn new() -> Self {
            let base = fs::canonicalize(std::env::temp_dir()).unwrap().join(format!("codmes-manager-reset-{:016x}",rand::random::<u64>()));
            let root = base.join("workspace"); fs::create_dir_all(&root).unwrap();
            let server_root = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(3).unwrap().to_path_buf();
            let staged = server_root.join("apps/server-manager/builds/runtime/codmes");
            let mut settings = ServerSettings::for_managed_workspace(root);
            let free_port = || TcpListener::bind(("127.0.0.1",0)).unwrap().local_addr().unwrap().port();
            settings.port=free_port(); settings.postgres_port=free_port();
            let manager = ServerManager {
                settings_path:base.join("server-manager.json"), oauth:GoogleOAuthConfig::default(),
                manager_secret:URL_SAFE_NO_PAD.encode(rand::random::<[u8;32]>()),
                postgres_bin_path:find_postgres_bin(&staged), node_path:find_system_node(), server_root,
                settings:Mutex::new(settings), process:Arc::new(Mutex::new(ProcessState {child:None,started_at:None,logs:VecDeque::new()})),
                operation:Mutex::new(()),resetting:AtomicBool::new(false),recovery_error:Mutex::new(None),
            };
            persist_settings(&manager.settings_path,&manager.settings.lock().unwrap()).unwrap();
            Self {base,manager}
        }
        fn ready(manager:&ServerManager) {
            let deadline=std::time::Instant::now()+Duration::from_secs(90);
            while !probe_codmes(&manager.settings.lock().unwrap()) {
                assert!(std::time::Instant::now()<deadline,"isolated server failed to start");
                thread::sleep(Duration::from_millis(50));
            }
        }
        fn request(manager:&ServerManager,route:&str,token:&str,body:Option<serde_json::Value>) -> (u16,serde_json::Value) {
            tauri::async_runtime::block_on(async {
                let port=manager.settings.lock().unwrap().port;
                let client=reqwest::Client::builder().timeout(Duration::from_secs(15)).build().unwrap();
                let url=format!("http://127.0.0.1:{port}{route}");
                let request=match body {Some(body)=>client.post(url).json(&body),None=>client.get(url)};
                let response=request.header("X-Codmes-Manager-Secret",manager.manager_secret()).bearer_auth(token).send().await.unwrap();
                let status=response.status().as_u16();
                (status,response.json().await.unwrap())
            })
        }
        fn bootstrap(manager:&ServerManager,username:&str,password:&str) -> Result<serde_json::Value,String> {
            Self::ready(manager);
            let (status,body)=Self::request(manager,"/api/auth/admin/bootstrap","",Some(serde_json::json!({"username":username,"password":password})));
            if status==201 {Ok(body)} else {Err(format!("bootstrap rejected ({status})"))}
        }
    }
    impl Drop for IsolatedServer {
        fn drop(&mut self) {
            let _=self.manager.stop();
            let stopped=self.manager.stop_postgres(&self.base.join("workspace")).is_ok();
            // Leave fixture data rather than delete files under a running database.
            if stopped {let _=fs::remove_dir_all(&self.base);}
        }
    }

    #[test]
    #[ignore = "requires isolated Node/PostgreSQL runtime; run with CODMES_TEST_MANAGED_POSTGRES=true and --ignored"]
    fn isolated_server_reset_rolls_back_failure_then_replaces_accounts_and_documents() {
        assert_eq!(std::env::var("CODMES_TEST_MANAGED_POSTGRES").as_deref(),Ok("true"),"explicit isolated test opt-in required");
        let fixture=IsolatedServer::new(); let manager=&fixture.manager;
        let password="isolated reset test password 12345";
        manager.start().unwrap();
        let old=IsolatedServer::bootstrap(manager,"old-admin",password).unwrap();
        let old_token=old["token"].as_str().unwrap();
        let profile_id=old["workspace"]["id"].as_str().unwrap();
        let (status,opened)=IsolatedServer::request(manager,&format!("/api/profiles/{profile_id}/open"),old_token,Some(serde_json::json!({})));
        assert_eq!(status,200);
        let profile_token=opened["token"].as_str().unwrap();
        let (status,_)=IsolatedServer::request(manager,"/api/file",profile_token,Some(serde_json::json!({"path":"Notes/keep.md","content":"old note"})));
        assert_eq!(status,201);
        let sentinel=fixture.base.join("workspace/old-private-plugin-settings"); fs::write(&sentinel,b"old settings").unwrap();
        let external=fixture.base.join("client-local-file"); fs::write(&external,b"untouched").unwrap();
        let (status,registration)=IsolatedServer::request(manager,"/api/auth/client/register","",Some(serde_json::json!({"username":"old-client","password":password,"deviceId":URL_SAFE_NO_PAD.encode(rand::random::<[u8;32]>()),"deviceName":"isolated client"})));
        assert_eq!(status,200); assert_eq!(registration["status"],"pending");

        // A process crash between workspace separation and signup is recovered on relaunch.
        manager.stop().unwrap(); manager.stop_postgres(&fixture.base.join("workspace")).unwrap();
        let saved=manager.settings.lock().unwrap().clone();
        drop(ResetTransaction::begin(&manager.settings_path,&saved,&manager.default_workspace()).unwrap());
        fs::write(fixture.base.join("workspace/incomplete-signup"),b"partial").unwrap();
        manager.recover_pending_reset().unwrap(); manager.start().unwrap(); IsolatedServer::ready(manager);
        assert!(sentinel.is_file()); assert!(!fixture.base.join("workspace/incomplete-signup").exists());
        assert_eq!(IsolatedServer::request(manager,"/api/auth/account",old_token,None).0,200);

        let cancelled=manager.fresh_start(|manager| {
            IsolatedServer::ready(manager);
            assert!(manager.stop().is_err(),"other lifecycle operations cannot race a reset");
            Err("test cancellation before commit".into())
        });
        assert!(cancelled.unwrap_err().contains("복원")); IsolatedServer::ready(manager); assert!(sentinel.is_file());

        let failure=manager.fresh_start(|manager|IsolatedServer::bootstrap(manager,"new-admin","too short"));
        assert!(failure.unwrap_err().contains("복원"));
        IsolatedServer::ready(manager);
        assert!(sentinel.is_file());
        assert_eq!(IsolatedServer::request(manager,"/api/auth/account",old_token,None).0,200);
        let (status,note)=IsolatedServer::request(manager,"/api/file?path=Notes%2Fkeep.md",profile_token,None);
        assert_eq!(status,200); assert_eq!(note["content"],"old note");
        assert!(!manager.reset_in_progress());

        let new=manager.fresh_start(|manager|IsolatedServer::bootstrap(manager,"new-admin",password)).unwrap();
        assert_ne!(old["user"]["id"],new["user"]["id"]);
        assert_eq!(IsolatedServer::request(manager,"/api/auth/account",old_token,None).0,401);
        assert_eq!(IsolatedServer::request(manager,"/api/auth/admin/login","",Some(serde_json::json!({"username":"old-admin","password":password}))).0,401);
        assert!(!sentinel.exists()); assert_eq!(fs::read(external).unwrap(),b"untouched");
        let (status,summary)=IsolatedServer::request(manager,"/api/auth/admin/setup","",None);
        assert_eq!(status,200); assert_eq!(summary["maskedAccount"]["id"],"n***in");
        let (_,profiles)=IsolatedServer::request(manager,"/api/admin/profiles",new["token"].as_str().unwrap(),None);
        assert!(!profiles.to_string().contains(profile_id));
        let (status,registrations)=IsolatedServer::request(manager,"/api/admin/client-registrations",new["token"].as_str().unwrap(),None);
        assert_eq!(status,200); assert_eq!(registrations["registrations"],serde_json::json!([]));
        assert!(ResetTransaction::pending(&manager.settings_path,&manager.default_workspace()).unwrap().is_none());
        assert!(!manager.reset_in_progress());
    }

    #[test]
    fn defaults_are_local_and_safe() {
        let settings = ServerSettings::default();
        assert_eq!(settings.host, "127.0.0.1");
        assert_eq!(settings.port, 8787);
        assert_eq!(settings.postgres_port, 55432);
        assert!(validate_settings(&settings).is_ok());
    }

    #[test]
    fn managed_workspace_uses_the_manager_data_directory() {
        let settings =
            ServerSettings::for_managed_workspace(PathBuf::from("/tmp/codmes/workspace"));
        assert_eq!(settings.workspace_root, "/tmp/codmes/workspace");
    }

    #[test]
    fn old_mode_settings_load_without_changing_workspace() {
        let saved = serde_json::json!({
            "workspaceRoot": "/tmp/codmes/existing-workspace",
            "host": "127.0.0.1",
            "port": 8787,
            "token": "old-server-token",
            "multiuserEnabled": false,
            "managedPostgres": false,
            "startOnLaunch": true,
            "launchAtLogin": false,
            "showDockIcon": false
        });
        let settings: ServerSettings = serde_json::from_value(saved).unwrap();
        assert_eq!(settings.workspace_root, "/tmp/codmes/existing-workspace");
        assert_eq!(settings.postgres_port, 55432);
    }

    #[test]
    fn network_access_uses_account_auth() {
        let mut settings = ServerSettings::default();
        settings.host = "0.0.0.0".to_string();
        assert!(validate_settings(&settings).is_ok());
    }

    #[test]
    fn recognizes_valid_google_client_ids() {
        assert!(valid_google_client_id("official.apps.googleusercontent.com"));
        assert!(!valid_google_client_id(".apps.googleusercontent.com"));
    }

    #[test]
    fn selects_an_alternate_port_when_the_preferred_port_is_busy() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let occupied = listener.local_addr().unwrap().port();
        let range_start = if occupied < 65530 {
            occupied
        } else {
            occupied - 5
        };
        let range_end = range_start + 5;
        let selected = select_available_port(occupied, range_start, range_end, "test").unwrap();
        assert_ne!(selected, occupied);
        assert!((range_start..=range_end).contains(&selected));
    }
}
