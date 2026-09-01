import { invoke } from "@tauri-apps/api/core";
import "./styles.css";

type ServerSettings = {
  workspaceRoot: string;
  host: string;
  port: number;
  token: string;
  startOnLaunch: boolean;
  launchAtLogin: boolean;
  showDockIcon: boolean;
};

type ServerStatus = {
  running: boolean;
  managed: boolean;
  pid: number | null;
  url: string;
  workspaceRoot: string;
  startedAt: number | null;
  message: string;
};

type ManagerSnapshot = {
  settings: ServerSettings;
  status: ServerStatus;
  logs: string[];
  runtimeReady: boolean;
  runtimeMessage: string;
};

const app = document.querySelector<HTMLElement>("#app");
if (!app) throw new Error("Missing app root");

app.innerHTML = `
  <section class="shell">
    <header class="hero">
      <div class="brand-mark" aria-hidden="true"><span>C</span></div>
      <div>
        <p class="eyebrow">CODMES WORKSPACE</p>
        <h1>Server Manager</h1>
        <p class="lede">Keep your workspace available to every Codmes client.</p>
      </div>
      <div id="status-pill" class="status-pill"><i></i><span>Checking</span></div>
    </header>

    <section class="status-card">
      <div>
        <p class="label">Server address</p>
        <div class="address-row">
          <code id="server-url">http://127.0.0.1:8787</code>
          <button id="copy-url" class="icon-button" title="Copy server address">Copy</button>
        </div>
        <p id="status-message" class="muted">Checking server status…</p>
      </div>
      <div class="server-actions">
        <button id="start" class="primary">Start server</button>
        <button id="restart">Restart</button>
        <button id="stop" class="danger">Stop</button>
      </div>
    </section>

    <section class="grid">
      <form id="settings-form" class="panel settings-panel">
        <div class="panel-heading">
          <div>
            <p class="eyebrow">CONFIGURATION</p>
            <h2>Server settings</h2>
          </div>
          <button type="submit" class="secondary">Save</button>
        </div>

        <div class="managed-storage">
          <span>Data storage</span>
          <code id="workspace-root">Managed automatically</code>
          <small>Codmes Server safely manages Notes, Code, conversations and plugin state.</small>
        </div>

        <div class="field-row">
          <label>
            <span>Access</span>
            <select id="host">
              <option value="127.0.0.1">This computer only</option>
              <option value="0.0.0.0">Local network</option>
            </select>
          </label>
          <label>
            <span>Port</span>
            <input id="port" type="number" min="1024" max="65535" />
          </label>
        </div>

        <label>
          <span>Connection password (server token)</span>
          <div class="token-row">
            <input id="token" type="password" autocomplete="new-password" />
            <button id="reveal-token" type="button" class="icon-button">Show</button>
            <button id="generate-token" type="button" class="icon-button">Generate</button>
          </div>
          <small>Not needed on this computer only. Required when iPhone, iPad, Android or another PC connects.</small>
        </label>

        <div class="toggles">
          <label class="toggle"><input id="start-on-launch" type="checkbox" /><span>Start server when Manager opens</span></label>
          <label class="toggle"><input id="launch-at-login" type="checkbox" /><span>Open Manager at login</span></label>
          <label class="toggle platform-mac"><input id="show-dock-icon" type="checkbox" /><span>Show Dock icon on macOS</span></label>
        </div>
      </form>

      <section class="panel diagnostics-panel">
        <div class="panel-heading">
          <div>
            <p class="eyebrow">DIAGNOSTICS</p>
            <h2>Recent activity</h2>
          </div>
          <button id="refresh" class="icon-button">Refresh</button>
        </div>
        <div id="runtime-state" class="runtime-state"></div>
        <pre id="logs">No server output yet.</pre>
      </section>
    </section>

    <footer>
      <span>Closing this window keeps Codmes Server running in the menu bar or system tray.</span>
      <span id="operation-message"></span>
    </footer>
  </section>
`;

const elements = {
  statusPill: byId("status-pill"),
  serverUrl: byId("server-url"),
  statusMessage: byId("status-message"),
  start: button("start"),
  restart: button("restart"),
  stop: button("stop"),
  copyUrl: button("copy-url"),
  form: document.querySelector<HTMLFormElement>("#settings-form")!,
  workspaceRoot: byId("workspace-root"),
  host: document.querySelector<HTMLSelectElement>("#host")!,
  port: input("port"),
  token: input("token"),
  revealToken: button("reveal-token"),
  generateToken: button("generate-token"),
  startOnLaunch: input("start-on-launch"),
  launchAtLogin: input("launch-at-login"),
  showDockIcon: input("show-dock-icon"),
  refresh: button("refresh"),
  runtimeState: byId("runtime-state"),
  logs: byId("logs"),
  operationMessage: byId("operation-message")
};

let lastSnapshot: ManagerSnapshot | null = null;
let busy = false;

async function refresh(): Promise<void> {
  try {
    const snapshot = await invoke<ManagerSnapshot>("manager_snapshot");
    lastSnapshot = snapshot;
    render(snapshot);
  } catch (error) {
    showOperation(errorMessage(error), true);
  }
}

function render(snapshot: ManagerSnapshot): void {
  const { settings, status } = snapshot;
  elements.statusPill.className = `status-pill ${status.running ? "running" : "stopped"}`;
  elements.statusPill.innerHTML = `<i></i><span>${status.running ? "Running" : "Stopped"}</span>`;
  elements.serverUrl.textContent = status.url;
  elements.statusMessage.textContent = status.message;
  elements.start.disabled = busy || status.running || !snapshot.runtimeReady;
  elements.restart.disabled = busy || !status.running || !status.managed;
  elements.stop.disabled = busy || !status.running || !status.managed;

  if (document.activeElement?.closest("#settings-form") == null) {
    elements.workspaceRoot.textContent = settings.workspaceRoot;
    elements.host.value = settings.host;
    elements.port.value = String(settings.port);
    elements.token.value = settings.token;
    elements.startOnLaunch.checked = settings.startOnLaunch;
    elements.launchAtLogin.checked = settings.launchAtLogin;
    elements.showDockIcon.checked = settings.showDockIcon;
  }

  elements.runtimeState.className = `runtime-state ${snapshot.runtimeReady ? "ready" : "warning"}`;
  elements.runtimeState.textContent = snapshot.runtimeMessage;
  elements.logs.textContent = snapshot.logs.length ? snapshot.logs.join("\n") : "No server output yet.";
  elements.logs.scrollTop = elements.logs.scrollHeight;
}

async function runOperation(command: string, success: string): Promise<void> {
  if (busy) return;
  busy = true;
  if (lastSnapshot) render(lastSnapshot);
  showOperation("Working…");
  try {
    await invoke(command);
    showOperation(success);
  } catch (error) {
    showOperation(errorMessage(error), true);
  } finally {
    busy = false;
    await refresh();
  }
}

elements.start.addEventListener("click", () => runOperation("start_server", "Server started."));
elements.stop.addEventListener("click", () => runOperation("stop_server", "Server stopped."));
elements.restart.addEventListener("click", () => runOperation("restart_server", "Server restarted."));
elements.refresh.addEventListener("click", refresh);

elements.copyUrl.addEventListener("click", async () => {
  const value = lastSnapshot?.status.url ?? elements.serverUrl.textContent ?? "";
  try {
    await navigator.clipboard.writeText(value);
    showOperation("Server address copied.");
  } catch {
    showOperation("Select the address and copy it manually.", true);
  }
});

elements.revealToken.addEventListener("click", () => {
  const reveal = elements.token.type === "password";
  elements.token.type = reveal ? "text" : "password";
  elements.revealToken.textContent = reveal ? "Hide" : "Show";
});

elements.generateToken.addEventListener("click", async () => {
  elements.token.value = await invoke<string>("generate_server_token");
  elements.token.type = "text";
  elements.revealToken.textContent = "Hide";
});

elements.host.addEventListener("change", async () => {
  if (elements.host.value === "0.0.0.0" && elements.token.value.trim().length < 24) {
    elements.token.value = await invoke<string>("generate_server_token");
    showOperation("A secure connection password was generated for other devices.");
  }
});

elements.form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (busy) return;
  busy = true;
  showOperation("Saving…");
  const settings: ServerSettings = {
    workspaceRoot: lastSnapshot?.settings.workspaceRoot ?? "",
    host: elements.host.value,
    port: Number(elements.port.value),
    token: elements.token.value.trim(),
    startOnLaunch: elements.startOnLaunch.checked,
    launchAtLogin: elements.launchAtLogin.checked,
    showDockIcon: elements.showDockIcon.checked
  };
  try {
    await invoke("save_server_settings", { settings });
    showOperation(lastSnapshot?.status.running ? "Saved. Restart the server to apply changes." : "Settings saved.");
  } catch (error) {
    showOperation(errorMessage(error), true);
  } finally {
    busy = false;
    await refresh();
  }
});

function byId(id: string): HTMLElement {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing #${id}`);
  return element;
}

function button(id: string): HTMLButtonElement {
  return byId(id) as HTMLButtonElement;
}

function input(id: string): HTMLInputElement {
  return byId(id) as HTMLInputElement;
}

function showOperation(message: string, isError = false): void {
  elements.operationMessage.textContent = message;
  elements.operationMessage.className = isError ? "error" : "";
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

void refresh();
window.setInterval(() => void refresh(), 2_000);
