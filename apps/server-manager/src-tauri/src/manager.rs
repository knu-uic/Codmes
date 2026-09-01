use rand::{distr::Alphanumeric, Rng};
use serde::{Deserialize, Serialize};
use std::{
    collections::VecDeque,
    fs,
    io::{BufRead, BufReader, Read, Write},
    net::{SocketAddr, TcpStream},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
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
    pub token: String,
    pub start_on_launch: bool,
    pub launch_at_login: bool,
    pub show_dock_icon: bool,
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

struct ProcessState {
    child: Option<Child>,
    started_at: Option<u64>,
    logs: VecDeque<String>,
}

pub struct ServerManager {
    settings_path: PathBuf,
    server_root: PathBuf,
    node_path: PathBuf,
    settings: Mutex<ServerSettings>,
    process: Arc<Mutex<ProcessState>>,
}

impl ServerManager {
    pub fn new(app: &AppHandle) -> Result<Self, String> {
        let config_dir = app
            .path()
            .app_config_dir()
            .map_err(|error| error.to_string())?;
        fs::create_dir_all(&config_dir).map_err(|error| error.to_string())?;
        let settings_path = config_dir.join("server-manager.json");
        let settings = load_settings(&settings_path)
            .unwrap_or_else(|| ServerSettings::for_managed_workspace(config_dir.join("workspace")));
        let (server_root, node_path) = resolve_runtime(app);
        Ok(Self {
            settings_path,
            server_root,
            node_path,
            settings: Mutex::new(settings),
            process: Arc::new(Mutex::new(ProcessState {
                child: None,
                started_at: None,
                logs: VecDeque::new(),
            })),
        })
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
        validate_settings(&settings)?;
        if let Some(parent) = self.settings_path.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        fs::create_dir_all(&settings.workspace_root)
            .map_err(|error| format!("Could not create the Workspace folder: {error}"))?;
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
        let settings = self.settings.lock().expect("settings lock").clone();
        validate_settings(&settings)?;
        if probe_codmes(&settings) {
            return Err("A Codmes Server is already running at this address.".to_string());
        }
        let (ready, message) = self.runtime_status();
        if !ready {
            return Err(message);
        }
        fs::create_dir_all(&settings.workspace_root)
            .map_err(|error| format!("Could not create the Workspace folder: {error}"))?;

        let mut process = self.process.lock().expect("process lock");
        reap_child(&mut process);
        if process.child.is_some() {
            return Err("Codmes Server is already starting.".to_string());
        }
        append_log(&mut process.logs, "[manager] starting Codmes Server");
        let mut command = Command::new(&self.node_path);
        command
            .arg(self.server_root.join("server/index.mjs"))
            .current_dir(&self.server_root)
            .env("CODMES_WORKSPACE_ROOT", &settings.workspace_root)
            .env("CODMES_HOST", &settings.host)
            .env("CODMES_PORT", settings.port.to_string())
            .env("CODMES_SERVER_TOKEN", &settings.token)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(target_os = "windows")]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000);
        }
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
        terminate_child(&mut child)?;
        Ok(())
    }

    pub fn restart(&self) -> Result<(), String> {
        self.stop()?;
        thread::sleep(Duration::from_millis(250));
        self.start()
    }

    pub fn stop_if_managed(&self) {
        let has_child = self.process.lock().expect("process lock").child.is_some();
        if has_child {
            let _ = self.stop();
        }
    }

    fn runtime_status(&self) -> (bool, String) {
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
            token: String::new(),
            start_on_launch: true,
            launch_at_login: false,
            show_dock_icon: false,
        }
    }
}

pub fn generate_token() -> String {
    rand::rng()
        .sample_iter(&Alphanumeric)
        .take(48)
        .map(char::from)
        .collect()
}

fn load_settings(path: &Path) -> Option<ServerSettings> {
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

fn validate_settings(settings: &ServerSettings) -> Result<(), String> {
    if !["127.0.0.1", "0.0.0.0"].contains(&settings.host.as_str()) {
        return Err("Access must be limited to this computer or the local network.".to_string());
    }
    if settings.port < 1024 {
        return Err("Port must be between 1024 and 65535.".to_string());
    }
    if settings.workspace_root.trim().is_empty()
        || !Path::new(&settings.workspace_root).is_absolute()
    {
        return Err("Workspace folder must be an absolute path.".to_string());
    }
    if settings.host == "0.0.0.0" && settings.token.len() < 24 {
        return Err("Generate a server token before enabling local-network access.".to_string());
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
    let node_name = if cfg!(target_os = "windows") {
        "node.exe"
    } else {
        "node"
    };
    (
        resource_dir.join("runtime/codmes"),
        resource_dir.join("runtime/bin").join(node_name),
    )
}

fn find_system_node() -> PathBuf {
    if let Ok(node) = std::env::var("CODMES_MANAGER_NODE") {
        return PathBuf::from(node);
    }
    let candidates = if cfg!(target_os = "windows") {
        vec![PathBuf::from(r"C:\Program Files\nodejs\node.exe")]
    } else {
        vec![
            PathBuf::from("/opt/homebrew/bin/node"),
            PathBuf::from("/usr/local/bin/node"),
            PathBuf::from("/usr/bin/node"),
        ]
    };
    if let Some(path) = candidates.into_iter().find(|path| path.is_file()) {
        return path;
    }
    let lookup = if cfg!(target_os = "windows") {
        ("where", "node.exe")
    } else {
        ("which", "node")
    };
    if let Ok(output) = Command::new(lookup.0).arg(lookup.1).output() {
        if output.status.success() {
            if let Some(line) = String::from_utf8_lossy(&output.stdout).lines().next() {
                let path = PathBuf::from(line.trim());
                if path.is_file() {
                    return path;
                }
            }
        }
    }
    PathBuf::from("node")
}

fn display_url(settings: &ServerSettings) -> String {
    let host = if settings.host == "0.0.0.0" {
        "localhost"
    } else {
        &settings.host
    };
    format!("http://{host}:{}", settings.port)
}

fn probe_codmes(settings: &ServerSettings) -> bool {
    let address = SocketAddr::from(([127, 0, 0, 1], settings.port));
    let Ok(mut stream) = TcpStream::connect_timeout(&address, Duration::from_millis(180)) else {
        return false;
    };
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

fn terminate_child(child: &mut Child) -> Result<(), String> {
    #[cfg(unix)]
    unsafe {
        libc::kill(child.id() as i32, libc::SIGTERM);
    }
    #[cfg(target_os = "windows")]
    child.kill().map_err(|error| error.to_string())?;
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

fn restrict_settings_file(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

pub fn apply_dock_policy(app: &AppHandle, show: bool) {
    #[cfg(target_os = "macos")]
    {
        let policy = if show {
            tauri::ActivationPolicy::Regular
        } else {
            tauri::ActivationPolicy::Accessory
        };
        let _ = app.set_activation_policy(policy);
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (app, show);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_local_and_safe() {
        let settings = ServerSettings::default();
        assert_eq!(settings.host, "127.0.0.1");
        assert_eq!(settings.port, 8787);
        assert!(settings.token.is_empty());
        assert!(validate_settings(&settings).is_ok());
    }

    #[test]
    fn managed_workspace_uses_the_manager_data_directory() {
        let settings =
            ServerSettings::for_managed_workspace(PathBuf::from("/tmp/codmes/workspace"));
        assert_eq!(settings.workspace_root, "/tmp/codmes/workspace");
    }

    #[test]
    fn network_access_requires_a_long_token() {
        let mut settings = ServerSettings::default();
        settings.host = "0.0.0.0".to_string();
        assert!(validate_settings(&settings).is_err());
        settings.token = generate_token();
        assert!(validate_settings(&settings).is_ok());
    }

    #[test]
    fn generated_tokens_are_suitable_for_server_auth() {
        let token = generate_token();
        assert_eq!(token.len(), 48);
        assert!(token.chars().all(|value| value.is_ascii_alphanumeric()));
    }
}
