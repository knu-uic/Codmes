import { spawn } from "node:child_process";
import readline from "node:readline";
import path from "node:path";
import fs from "node:fs/promises";
import { createWriteStream } from "node:fs";
import os from "node:os";

export function validateCommand(command) {
  if (!command || typeof command !== "string") {
    throw new Error("MCP command must be a non-empty string.");
  }
  const dangerousChars = /[;&|`$\n\r()<>]/;
  if (dangerousChars.test(command)) {
    throw new Error(`MCP command '${command}' contains illegal characters.`);
  }
}

export async function executableExists(command) {
  try {
    validateCommand(command);
  } catch {
    return false;
  }

  if (command.includes(path.sep) || (os.platform() === "win32" && command.includes("/"))) {
    try {
      await fs.access(command, fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  }

  const pathEnv = process.env.PATH || "";
  const pathDirs = pathEnv.split(os.platform() === "win32" ? ";" : ":");
  const extensions = os.platform() === "win32" ? [".exe", ".cmd", ".bat", ".ps1", ""] : [""];

  for (const dir of pathDirs) {
    for (const ext of extensions) {
      const fullPath = path.join(dir, command + ext);
      try {
        await fs.access(fullPath, fs.constants.X_OK);
        return true;
      } catch {
        // Continue
      }
    }
  }
  return false;
}

export class McpClient {
  constructor(name, command, args = [], { workspaceRoot, idleTimeoutMs = 60000, logger = console, env = {} } = {}) {
    this.name = name;
    this.command = command;
    this.args = args;
    this.workspaceRoot = workspaceRoot;
    this.idleTimeoutMs = idleTimeoutMs;
    this.logger = logger;
    this.env = env && typeof env === "object" ? normalizeProcessEnv(env) : {};
    this.child = null;
    this.rl = null;
    this.stderrStream = null;
    this.pendingRequests = new Map();
    this.requestId = 0;
    this.status = "stopped"; // stopped, starting, running, error
    this.tools = [];
    this.idleTimer = null;
  }

  resetIdleTimer() {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
    if (this.status === "running" && this.pendingRequests.size === 0 && this.idleTimeoutMs > 0) {
      this.idleTimer = setTimeout(() => {
        if (this.logger) {
          this.logger.log(`[MCP:${this.name}] Idle timeout reached. Stopping server.`);
        }
        this.stop();
      }, this.idleTimeoutMs);
      if (this.idleTimer.unref) {
        this.idleTimer.unref();
      }
    }
  }

  async start() {
    if (this.status === "running" || this.status === "starting") {
      return;
    }
    this.status = "starting";

    // Validate command security
    validateCommand(this.command);

    // Setup stderr file redirect if workspaceRoot is available
    if (this.workspaceRoot) {
      try {
        const logDir = path.join(this.workspaceRoot, ".codmes", "tool-logs");
        await fs.mkdir(logDir, { recursive: true });
        const logPath = path.join(logDir, `mcp-${this.name}.stderr.log`);
        this.stderrStream = createWriteStream(logPath, { flags: "a" });
      } catch (err) {
        if (this.logger) {
          this.logger.error(`[MCP:${this.name}] Failed to open stderr log file: ${err.message}`);
        }
      }
    }

    try {
      this.child = spawn(this.command, this.args || [], {
        env: { ...process.env, ...this.env },
        stdio: ["pipe", "pipe", "pipe"]
      });
    } catch (err) {
      this.status = "error";
      if (this.stderrStream) {
        this.stderrStream.end();
        this.stderrStream = null;
      }
      throw new Error(`Failed to spawn MCP server '${this.name}': ${err.message}`);
    }

    this.child.on("error", (err) => {
      this.status = "error";
      this.rejectAllPending(err);
    });

    this.rl = readline.createInterface({
      input: this.child.stdout,
      terminal: false
    });

    this.rl.on("line", (line) => {
      this.handleLine(line);
    });

    this.child.stderr.on("data", (chunk) => {
      const msg = chunk.toString().trim();
      if (this.stderrStream) {
        this.stderrStream.write(chunk);
      }
      if (msg && this.logger) {
        this.logger.error(`[MCP:${this.name}] stderr: ${msg}`);
      }
    });

    this.child.on("exit", (code, signal) => {
      this.status = "stopped";
      this.rejectAllPending(new Error(`MCP server '${this.name}' exited with code ${code}, signal ${signal}`));
    });

    // Run initialize protocol handshake
    try {
      await this.sendRequest("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "codmes-client", version: "1.0.0" }
      });
      this.status = "running";
      this.sendNotification("notifications/initialized");
      this.resetIdleTimer();
    } catch (err) {
      this.status = "error";
      this.stop();
      throw err;
    }
  }

  async listTools() {
    if (this.status !== "running") {
      await this.start();
    }
    const result = await this.sendRequest("tools/list", {});
    this.tools = result.tools || [];
    return this.tools;
  }

  async callTool(name, argumentsObj) {
    if (this.status !== "running") {
      await this.start();
    }
    const result = await this.sendRequest("tools/call", {
      name,
      arguments: argumentsObj
    });
    return result;
  }

  sendRequest(method, params = {}, timeoutMs = 15000) {
    return new Promise((resolve, reject) => {
      if (this.idleTimer) {
        clearTimeout(this.idleTimer);
        this.idleTimer = null;
      }
      if (!this.child || !this.child.stdin || this.child.stdin.destroyed) {
        return reject(new Error(`MCP server '${this.name}' is not running.`));
      }
      const id = ++this.requestId;
      const msg = {
        jsonrpc: "2.0",
        id,
        method,
        params
      };

      let timer = null;
      if (timeoutMs > 0) {
        timer = setTimeout(() => {
          this.pendingRequests.delete(id);
          reject(Object.assign(new Error(`MCP request ${method} (id: ${id}) timed out after ${timeoutMs}ms`), { code: "TIMEOUT" }));
          this.resetIdleTimer();
        }, timeoutMs);
      }

      this.pendingRequests.set(id, { resolve, reject, timer });
      try {
        this.child.stdin.write(JSON.stringify(msg) + "\n");
      } catch (err) {
        if (timer) clearTimeout(timer);
        this.pendingRequests.delete(id);
        reject(err);
        this.resetIdleTimer();
      }
    });
  }

  sendNotification(method, params = {}) {
    if (!this.child || !this.child.stdin || this.child.stdin.destroyed) {
      return;
    }
    const msg = {
      jsonrpc: "2.0",
      method,
      params
    };
    try {
      this.child.stdin.write(JSON.stringify(msg) + "\n");
    } catch (err) {
      if (this.logger) {
        this.logger.error(`Failed to send notification ${method}: ${err.message}`);
      }
    }
  }

  handleLine(line) {
    if (!line.trim()) return;
    try {
      const msg = JSON.parse(line);
      if (msg.id !== undefined && msg.id !== null) {
        const pending = this.pendingRequests.get(msg.id);
        if (pending) {
          this.pendingRequests.delete(msg.id);
          if (pending.timer) clearTimeout(pending.timer);
          if (msg.error) {
            pending.reject(Object.assign(new Error(msg.error.message || "MCP error"), { code: msg.error.code }));
          } else {
            pending.resolve(msg.result);
          }
          this.resetIdleTimer();
        }
      }
    } catch (err) {
      if (this.logger) {
        this.logger.error(`[MCP:${this.name}] Failed to parse line as JSON: ${line}`);
      }
    }
  }

  rejectAllPending(error) {
    for (const [id, pending] of this.pendingRequests.entries()) {
      if (pending.timer) clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pendingRequests.clear();
  }

  stop() {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
    this.rejectAllPending(new Error(`MCP server '${this.name}' stopped.`));
    if (this.rl) {
      try {
        this.rl.close();
      } catch {}
      this.rl = null;
    }
    if (this.stderrStream) {
      try {
        this.stderrStream.end();
      } catch {}
      this.stderrStream = null;
    }
    if (this.child) {
      try {
        this.child.kill();
      } catch {}
      this.child = null;
    }
    this.status = "stopped";
  }
}

export class StreamableHttpMcpClient {
  constructor(name, url, { tokenAccessor, allowUnauthenticated = false, logger = console, timeoutMs = 15000, fetchImpl = globalThis.fetch } = {}) {
    this.name = name;
    this.url = url;
    this.tokenAccessor = tokenAccessor;
    this.allowUnauthenticated = allowUnauthenticated;
    this.logger = logger;
    this.timeoutMs = timeoutMs;
    this.fetch = fetchImpl;
    this.client = null;
    this.transport = null;
    this.status = "stopped";
    this.tools = [];
    this.activeAbortControllers = new Set();
  }

  async start() {
    if (this.status === "running") return;
    this.status = "starting";
    try {
      const [{ Client }, { StreamableHTTPClientTransport }] = await Promise.all([
        import("@modelcontextprotocol/sdk/client/index.js"),
        import("@modelcontextprotocol/sdk/client/streamableHttp.js")
      ]);
      const authenticatedFetch = async (input, init = {}) => {
        const token = await this.tokenAccessor?.();
        if (!token && !this.allowUnauthenticated) throw new Error(`MCP credential for '${this.name}' is not configured.`);
        const headers = new Headers(init.headers || {});
        if (token) headers.set("authorization", `Bearer ${token}`);
        const controller = new AbortController();
        this.activeAbortControllers.add(controller);
        try { return await this.fetch(input, { ...init, headers, signal: controller.signal }); }
        finally { this.activeAbortControllers.delete(controller); }
      };
      this.client = new Client({ name: "codmes-client", version: "1.0.0" }, { capabilities: {} });
      this.transport = new StreamableHTTPClientTransport(new URL(this.url), { fetch: authenticatedFetch });
      await this.withTimeout(this.client.connect(this.transport), "initialize");
      this.status = "running";
    } catch (error) {
      this.status = "error";
      this.stop();
      throw redactMcpError(error);
    }
  }

  async listTools() {
    if (this.status !== "running") await this.start();
    try {
      const result = await this.withTimeout(this.client.listTools(), "tools/list");
      this.tools = result.tools || [];
      return this.tools;
    } catch (error) { throw redactMcpError(error); }
  }

  async callTool(name, argumentsObj) {
    if (this.status !== "running") await this.start();
    try { return await this.withTimeout(this.client.callTool({ name, arguments: argumentsObj }), "tools/call"); }
    catch (error) { throw redactMcpError(error); }
  }

  async withTimeout(promise, operation) {
    let timer;
    try {
      return await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => {
          for (const controller of this.activeAbortControllers) controller.abort();
          reject(Object.assign(new Error(`MCP ${operation} timed out after ${this.timeoutMs}ms`), { code: "TIMEOUT" }));
        }, this.timeoutMs);
      })]);
    } finally { if (timer) clearTimeout(timer); }
  }

  stop() {
    const transport = this.transport;
    this.client = null;
    this.transport = null;
    this.status = "stopped";
    for (const controller of this.activeAbortControllers) controller.abort();
    this.activeAbortControllers.clear();
    if (transport) Promise.resolve(transport.close()).catch(() => {});
  }
}

export function createMcpClient(config, options = {}) {
  if (config.transport === "streamable_http") {
    return new StreamableHttpMcpClient(config.name, config.url, options);
  }
  return new McpClient(config.name, config.command, config.args || [], options);
}

export function redactMcpError(error) {
  const message = String(error?.message || error || "MCP request failed")
    .replace(/authorization\s*[:=]\s*bearer\s+[^\s,;]+/gi, "Authorization: Bearer [REDACTED]")
    .replace(/bearer\s+[A-Za-z0-9._~+\/-]+=*/gi, "Bearer [REDACTED]");
  return Object.assign(new Error(message), { code: error?.code, status: error?.status });
}

function normalizeProcessEnv(env) {
  const result = {};
  for (const [key, value] of Object.entries(env || {})) {
    if (!key || value === undefined || value === null) continue;
    result[key] = String(value);
  }
  return result;
}
