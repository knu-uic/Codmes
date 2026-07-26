import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { WorkspaceAgentEngine, WorkspaceAgentStateStore } from "./agent-engine.mjs";
import { OpenAICompatibleRuntime } from "./runtime/openai-compatible-runtime.mjs";
import { setCredentialValue, setDefaultModel, setMcpCredential, writeRuntimeConfig } from "./runtime/config-store.mjs";
import { checkAction, writeSecurityConfig } from "./runtime/security-policy.mjs";

test("workspace agent engine resolves context and records task state", async () => {
  const root = await fixtureWorkspace();
  const runtime = new FakeAgentRuntime();
  const engine = new WorkspaceAgentEngine({ workspaceRoot: root }, runtime);

  const session = await engine.createSession({
    provider: "local",
    model: "test-model",
    accessMode: "confirm",
    reasoningEffort: "medium"
  });
  assert.equal(session.sessionId, "stored-1");
  assert.equal(session.engine, "workspace-agent");

  const prompt = await engine.submitPrompt({
    sessionId: session.sessionId,
    message: "이 노트 설명해줘",
    contextRequest: {
      scopeType: "note",
      scopePath: "Notes/a.md",
      activePath: "Notes/a.md"
    }
  });
  assert.equal(prompt.ok, true);
  assert.equal(runtime.lastPrompt.context.workspaceContext.workspace.activePath, "Notes/a.md");
  assert.equal(runtime.lastPrompt.context.workspaceContext.inlineBlocks[0].path, "Notes/a.md");

  const taskDir = path.join(root, ".codmes", "tasks");
  const allFiles = await fs.readdir(taskDir);
  const taskFiles = allFiles.filter(f => f.startsWith("task-") && f.endsWith(".json"));
  assert.equal(taskFiles.length > 0, true);
  const task = JSON.parse(await fs.readFile(path.join(taskDir, taskFiles[0]), "utf8"));
  assert.equal(task.sessionId, session.sessionId);
  assert.equal(task.status, "submitted");

  const events = await fs.readFile(path.join(root, ".codmes", "sessions", "events.jsonl"), "utf8");
  assert.match(events, /session.create/);
});

test("workspace agent engine records live tool events under workspace state", async () => {
  const root = await fixtureWorkspace();
  const runtime = new FakeAgentRuntime();
  const engine = new WorkspaceAgentEngine({ workspaceRoot: root }, runtime);

  runtime.emit("event", {
    type: "tool.start",
    sessionId: "stored-1",
    text: "search_files"
  });
  await engine.flush();

  const allEvents = await fs.readFile(path.join(root, ".codmes", "tool-logs", "live-events.jsonl"), "utf8");
  const toolEvents = await fs.readFile(path.join(root, ".codmes", "tool-logs", "tool-events.jsonl"), "utf8");
  assert.match(allEvents, /workspace-agent/);
  assert.match(toolEvents, /tool.start/);
  assert.match(toolEvents, /search_files/);
});

test("workspace agent engine persists streamed assistant replies into sessions", async () => {
  const root = await fixtureWorkspace();
  const runtime = new StreamingAgentRuntime();
  const engine = new WorkspaceAgentEngine({ workspaceRoot: root }, runtime);

  const session = await engine.createSession({
    provider: "custom",
    model: "demo-model"
  });

  const first = await engine.submitPrompt({
    sessionId: session.sessionId,
    message: "안녕"
  });
  assert.equal(first.reply, "안녕하세요");

  const stored = await engine.getSessionMessages(session.sessionId);
  assert.deepEqual(stored.messages.map((message) => message.role), ["user", "assistant"]);
  assert.equal(stored.messages[0].content, "안녕");
  assert.equal(stored.messages[1].content, "안녕하세요");
  assert.equal(stored.messages[1].reasoning, "생각 중입니다.");

  await engine.submitPrompt({
    sessionId: session.sessionId,
    message: "이전 답변 기억해?"
  });

  assert.deepEqual(runtime.lastPrompt.history.map((message) => message.role), ["user", "assistant"]);
  assert.deepEqual(runtime.lastPrompt.history.map((message) => message.content), ["안녕", "안녕하세요"]);
});

test("workspace agent state creates the unified state directory shape", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "agent-state-"));
  await new WorkspaceAgentStateStore(root).ensure();
  for (const folder of ["sessions", "tasks", "memory", "approvals", "decisions", "tool-logs", "diffs", "index"]) {
    const stat = await fs.stat(path.join(root, ".codmes", folder));
    assert.equal(stat.isDirectory(), true);
  }
});

test("workspace agent state lists task summaries", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "agent-state-list-"));
  const state = new WorkspaceAgentStateStore(root);
  const codeTask = await state.startTask({
    type: "code",
    status: "started",
    message: "change renderer",
    scopePath: "Code/demo"
  });
  await state.finishTask(codeTask.id, {
    status: "inspected",
    plan: { summary: "Code task prepared." }
  });
  await state.startTask({
    type: "chat",
    message: "hello"
  });

  const listed = await state.listTasks({ type: "code" });
  assert.equal(listed.tasks.length, 1);
  assert.equal(listed.tasks[0].id, codeTask.id);
  assert.equal(listed.tasks[0].summary, "Code task prepared.");
  assert.equal(listed.tasks[0].scopePath, "Code/demo");
});

test("workspace agent state records and resolves approval inbox items", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "agent-state-approvals-"));
  const state = new WorkspaceAgentStateStore(root);
  const approval = await state.recordApprovalRequest({
    category: "code.patch.apply",
    taskId: "task-1",
    proposalId: "patch-1",
    scopePath: "Code/demo",
    summary: "Apply patch"
  });

  assert.match(approval.id, /^approval-/);
  assert.equal(approval.status, "pending");

  const listed = await state.listApprovals({ status: "pending" });
  assert.equal(listed.approvals.length, 1);
  assert.equal(listed.approvals[0].id, approval.id);

  const resolved = await state.resolveApproval(approval.id, {
    approved: false,
    reason: "No thanks."
  });
  assert.equal(resolved.status, "rejected");
  assert.equal(resolved.reason, "No thanks.");

  const pending = await state.listApprovals({ status: "pending" });
  assert.equal(pending.approvals.length, 0);
});

test("workspace agent engine stores approval_required task and resumes approved MCP pending state", async () => {
  const root = await fixtureWorkspace();
  const runtime = new ApprovalRequiredRuntime();
  const engine = new WorkspaceAgentEngine({ workspaceRoot: root }, runtime);

  const session = await engine.createSession({});
  const result = await engine.submitPrompt({
    sessionId: session.sessionId,
    message: "dangerous tool please"
  });

  assert.equal(result.status, "approval_required", JSON.stringify(result));
  assert.match(result.approvalId, /^approval-/);

  const task = await engine.readTask(result.taskId);
  assert.equal(task.status, "approval_required");
  assert.equal(task.approvalIds.includes(result.approvalId), true);
  assert.equal(task.pendingState.type, "mcp.tool.call");

  const approvals = await engine.listApprovals({ status: "pending" });
  assert.equal(approvals.approvals.length, 1);
  assert.equal(approvals.approvals[0].category, "mcp.tool.call");
  assert.equal(approvals.approvals[0].hasPendingState ?? Boolean(approvals.approvals[0].payload?.pendingState), true);

  const approved = await engine.respondToWorkspaceApproval(result.approvalId, { approved: true });
  assert.equal(approved.status, "approved");
  assert.equal(runtime.resumed.length, 1);

  const resumedTask = await engine.readTask(result.taskId);
  assert.equal(resumedTask.status, "completed");
  assert.equal(resumedTask.pendingState, null);
  assert.equal(resumedTask.result.result.output, "ok");
});

test("MCP dangerous tool call creates approval_required task and approved inbox response resumes only that tool call", async () => {
  const root = await fixtureWorkspace();
  await setDefaultModel(root, "custom", "demo-model");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_BASE_URL", "http://model.test/v1");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_API_KEY", "test-key");
  await writeSecurityConfig(root, {
    approvalMode: "auto",
    allowShell: true,
    allowedCommands: [],
    deniedCommands: [],
    requireApproval: ["mcp.tool.call"]
  });
  const mcpServerPath = await writeApprovalMcpServer(root);
  await writeRuntimeConfig(root, {
    defaultModel: { provider: "custom", model: "demo-model" },
    mcpServers: [
      { name: "files", command: "node", args: [mcpServerPath], enabled: true }
    ]
  });

  let modelRequestCount = 0;
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async () => {
      modelRequestCount += 1;
      return {
        ok: true,
        headers: { get: () => "text/event-stream" },
        body: streamChunks([
          'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_delete","type":"function","function":{"name":"mcp__files__delete_file","arguments":"{\\"path\\":\\"Notes/a.md\\"}"}}]}}]}\n\n',
          "data: [DONE]\n\n"
        ])
      };
    }
  });
  const engine = new WorkspaceAgentEngine({ workspaceRoot: root }, runtime);
  const events = [];
  engine.on("event", (event) => events.push(event));

  const session = await engine.createSession({});
  const result = await engine.submitPrompt({
    sessionId: session.sessionId,
    message: "delete risky file"
  });

  assert.equal(result.status, "approval_required");
  assert.equal(modelRequestCount, 1);

  const task = await engine.readTask(result.taskId);
  assert.equal(task.status, "approval_required");
  assert.equal(task.approvalIds.includes(result.approvalId), true);
  assert.equal(task.pendingState.type, "mcp.tool.call");
  assert.equal(task.pendingState.toolName, "delete_file");

  const approvals = await engine.listApprovals({ status: "pending" });
  assert.equal(approvals.approvals.length, 1);
  assert.equal(approvals.approvals[0].id, result.approvalId);
  assert.equal(approvals.approvals[0].category, "mcp.tool.call");
  assert.equal(approvals.approvals[0].hasPendingState, true);
  assert.equal(events.some((event) => event.type === "approval.request"), true);

  const approved = await engine.respondToWorkspaceApproval(result.approvalId, { approved: true });
  assert.equal(approved.status, "approved");
  assert.equal(approved.result.status, "completed");

  const resumedTask = await engine.readTask(result.taskId);
  assert.equal(resumedTask.status, "completed");
  assert.equal(resumedTask.pendingState, null);
  assert.deepEqual(resumedTask.result.result.output, [{ type: "text", text: "delete_file called 1" }]);
  assert.equal(modelRequestCount, 1);

  runtime.close();
});

test("remote Chat MCP keeps bearer out of approval state and calls exactly once only after approval", async () => {
  const root = await fixtureWorkspace();
  await setDefaultModel(root, "custom", "demo-model");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_BASE_URL", "http://model.test/v1");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_API_KEY", "test-key");
  await setMcpCredential(root, "knu-rag", "remote-bearer-secret");
  await writeRuntimeConfig(root, { defaultModel: { provider: "custom", model: "demo-model" }, mcpServers: [{ name: "knu-rag", transport: "streamable_http", url: "https://example.test/api/mcp/", credential_id: "knu-rag", surfaces: ["chat"], enabled: true }] });
  await writeSecurityConfig(root, { approvalMode: "manual", allowShell: true, allowedCommands: [], deniedCommands: [], requireApproval: ["mcp.tool.call"] });
  assert.equal((await checkAction(root, { type: "mcp.tool.call" })).status, "approve");
  let calls = 0;
  let modelRequests = 0;
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    mcpClientFactory: () => ({ status: "stopped", async start() { this.status = "running"; }, async listTools() { return [{ name: "search_knu_notices", inputSchema: { type: "object" } }]; }, async callTool() { calls += 1; return { content: [{ type: "text", text: "notice" }] }; }, stop() {} }),
    fetchImpl: async () => {
      modelRequests += 1;
      const chunks = modelRequests === 1
        ? ['data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_knu","type":"function","function":{"name":"mcp__knu_rag__search_knu_notices","arguments":"{\\"query\\":\\"registration\\"}"}}]}}]}\n\n', "data: [DONE]\n\n"]
        : ['data: {"choices":[{"delta":{"content":"notice found"}}]}\n\n', "data: [DONE]\n\n"];
      return { ok: true, headers: { get: () => "text/event-stream" }, body: streamChunks(chunks) };
    }
  });
  const engine = new WorkspaceAgentEngine({ workspaceRoot: root }, runtime);
  const session = await engine.createSession({});
  const result = await engine.submitPrompt({ sessionId: session.sessionId, message: "공지 찾아줘", surface: "chat", approved: false });
  assert.equal(result.status, "approval_required", JSON.stringify(result));
  assert.equal(calls, 0);
  const task = await engine.readTask(result.taskId);
  assert.equal(task.pendingState.type, "mcp.tool.call");
  assert.equal(JSON.stringify(task).includes("remote-bearer-secret"), false);
  await engine.respondToWorkspaceApproval(result.approvalId, { approved: true });
  assert.equal(calls, 1);
  modelRequests = 0;
  const rejectedSession = await engine.createSession({});
  const rejected = await engine.submitPrompt({ sessionId: rejectedSession.sessionId, message: "공지 찾아줘", surface: "chat", approved: false });
  assert.equal(rejected.status, "approval_required");
  assert.equal(calls, 1);
  await engine.respondToWorkspaceApproval(rejected.approvalId, { approved: false, reason: "not now" });
  assert.equal(calls, 1);
  runtime.close();
});

test("approval.inbox.respond rejected marks MCP approval task failed", async () => {
  const root = await fixtureWorkspace();
  await setDefaultModel(root, "custom", "demo-model");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_BASE_URL", "http://model.test/v1");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_API_KEY", "test-key");
  await writeSecurityConfig(root, {
    approvalMode: "auto",
    allowShell: true,
    allowedCommands: [],
    deniedCommands: [],
    requireApproval: ["mcp.tool.call"]
  });
  const mcpServerPath = await writeApprovalMcpServer(root);
  await writeRuntimeConfig(root, {
    defaultModel: { provider: "custom", model: "demo-model" },
    mcpServers: [
      { name: "files", command: "node", args: [mcpServerPath], enabled: true }
    ]
  });

  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async () => ({
      ok: true,
      headers: { get: () => "text/event-stream" },
      body: streamChunks([
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_delete","type":"function","function":{"name":"mcp__files__delete_file","arguments":"{\\"path\\":\\"Notes/a.md\\"}"}}]}}]}\n\n',
        "data: [DONE]\n\n"
      ])
    })
  });
  const engine = new WorkspaceAgentEngine({ workspaceRoot: root }, runtime);
  const session = await engine.createSession({});
  const result = await engine.submitPrompt({
    sessionId: session.sessionId,
    message: "delete risky file"
  });

  const rejected = await engine.respondToWorkspaceApproval(result.approvalId, {
    approved: false,
    reason: "Too risky."
  });
  assert.equal(rejected.status, "rejected");

  const task = await engine.readTask(result.taskId);
  assert.equal(task.status, "failed");
  assert.equal(task.pendingState, null);
  assert.equal(task.error, "Too risky.");

  runtime.close();
});

test("workspace agent engine cancels approval_required tasks", async () => {
  const root = await fixtureWorkspace();
  const runtime = new ApprovalRequiredRuntime();
  const engine = new WorkspaceAgentEngine({ workspaceRoot: root }, runtime);

  const session = await engine.createSession({});
  const result = await engine.submitPrompt({
    sessionId: session.sessionId,
    message: "cancel me"
  });

  const cancelled = await engine.cancelTask(result.taskId, { reason: "User cancelled." });
  assert.equal(cancelled.status, "cancelled");

  const task = await engine.readTask(result.taskId);
  assert.equal(task.status, "cancelled");
  assert.equal(task.pendingState, null);
  assert.equal(task.error, "User cancelled.");
});

test("code surface prompt auto-creates and links a current code task", async () => {
  const root = await fixtureWorkspace();
  await fs.mkdir(path.join(root, "Code", "demo"), { recursive: true });
  const runtime = new FakeAgentRuntime();
  const engine = new WorkspaceAgentEngine({ workspaceRoot: root }, runtime);

  const session = await engine.createSession({
    surface: "code",
    provider: "custom",
    model: "demo-model"
  });
  const result = await engine.submitPrompt({
    sessionId: session.sessionId,
    message: "이 코드 프로젝트 봐줘",
    surface: "code",
    scopePath: "Code/demo"
  });

  assert.equal(result.ok, true);
  assert.match(runtime.lastPrompt.currentCodeTaskId, /^task-/);
  assert.equal(runtime.lastPrompt.currentCodeScopePath, "Code/demo");
  const codeTask = await engine.readTask(runtime.lastPrompt.currentCodeTaskId);
  assert.equal(codeTask.type, "code");
  assert.equal(codeTask.scopePath, "Code/demo");

  const storedSession = await engine.state.readSession(session.sessionId);
  assert.equal(storedSession.activeCodeTaskId, runtime.lastPrompt.currentCodeTaskId);
});

test("chat surface prompt auto-routes to code when current context is code", async () => {
  const root = await fixtureWorkspace();
  await fs.mkdir(path.join(root, "Code", "demo"), { recursive: true });
  await fs.writeFile(path.join(root, "Code", "demo", "main.swift"), "print(\"hi\")");
  const runtime = new FakeAgentRuntime();
  const engine = new WorkspaceAgentEngine({ workspaceRoot: root }, runtime);

  const session = await engine.createSession({
    surface: "chat",
    provider: "custom",
    model: "demo-model"
  });
  await engine.submitPrompt({
    sessionId: session.sessionId,
    message: "이 파일 설명해줘",
    surface: "chat",
    contextRequest: {
      scopeType: "current",
      scopePath: "Code/demo/main.swift",
      activePath: "Code/demo/main.swift"
    }
  });

  assert.equal(runtime.lastPrompt.surface, "code");
  assert.match(runtime.lastPrompt.currentCodeTaskId, /^task-/);
});

test("chat surface router can use an LLM classifier for ambiguous prompts", async () => {
  const previous = process.env.CODMES_SURFACE_ROUTER;
  process.env.CODMES_SURFACE_ROUTER = "llm";
  try {
    const root = await fixtureWorkspace();
    const runtime = new FakeAgentRuntime({ classifierResult: "notes" });
    const engine = new WorkspaceAgentEngine({ workspaceRoot: root }, runtime);

    const session = await engine.createSession({
      surface: "chat",
      provider: "custom",
      model: "demo-model"
    });
    await engine.submitPrompt({
      sessionId: session.sessionId,
      message: "이 내용 좀 정리해줘",
      surface: "chat"
    });

    assert.equal(runtime.lastPrompt.surface, "notes");
  } finally {
    if (previous === undefined) delete process.env.CODMES_SURFACE_ROUTER;
    else process.env.CODMES_SURFACE_ROUTER = previous;
  }
});

class FakeAgentRuntime extends EventEmitter {
  constructor(options = {}) {
    super();
    this.name = "fake-agent";
    this.lastPrompt = null;
    this.classifierResult = options.classifierResult || null;
  }

  async connect() {}

  async createSession() {
    return {
      sessionId: "stored-1",
      runtimeSessionId: "runtime-1",
      source: "fake"
    };
  }

  async resumeSession() {
    return "runtime-1";
  }

  async submitPrompt(params) {
    this.lastPrompt = params;
    return {
      ok: true,
      sessionId: params.sessionId,
      runtimeSessionId: "runtime-1"
    };
  }

  async respondToApproval(params) {
    return {
      ok: true,
      sessionId: params.sessionId,
      runtimeSessionId: "runtime-1",
      choice: params.approved === false ? "deny" : "once"
    };
  }

  async setAccessMode() {}

  async setReasoning() {}

  async classifySurface() {
    return this.classifierResult;
  }

  close() {}
}

class ApprovalRequiredRuntime extends EventEmitter {
  constructor() {
    super();
    this.name = "approval-runtime";
    this.resumed = [];
  }

  async connect() {}

  async createSession() {
    return {
      sessionId: "approval-session",
      runtimeSessionId: "approval-session",
      source: "fake"
    };
  }

  async resumeSession() {
    return "approval-session";
  }

  async submitPrompt(params) {
    const pendingState = {
      type: "mcp.tool.call",
      sessionId: params.sessionId,
      taskId: params.taskId,
      serverName: "mock",
      toolName: "danger",
      arguments: { value: 1 },
      toolCall: {
        id: "call-danger",
        name: "mcp__mock__danger",
        arguments: "{\"value\":1}"
      }
    };
    throw Object.assign(new Error("Approval required."), {
      status: 409,
      approvalRequired: true,
      category: "mcp.tool.call",
      summary: "Execute dangerous MCP tool",
      reason: "Test requires approval.",
      pendingState
    });
  }

  async resumePendingState(pendingState) {
    this.resumed.push(pendingState);
    return {
      ok: true,
      status: "completed",
      result: {
        ok: true,
        output: "ok"
      }
    };
  }

  async respondToApproval() {
    return { ok: true };
  }

  async setAccessMode() {}

  async setReasoning() {}

  close() {}
}

class StreamingAgentRuntime extends EventEmitter {
  constructor() {
    super();
    this.name = "streaming-agent";
    this.lastPrompt = null;
    this.sessionId = "streamed-1";
  }

  async connect() {}

  async createSession() {
    return {
      sessionId: this.sessionId,
      runtimeSessionId: this.sessionId,
      source: "fake"
    };
  }

  async resumeSession() {
    return this.sessionId;
  }

  async submitPrompt(params) {
    this.lastPrompt = params;
    this.emit("event", {
      type: "reasoning.delta",
      sessionId: params.sessionId,
      taskId: params.taskId,
      text: "생각 "
    });
    this.emit("event", {
      type: "reasoning.delta",
      sessionId: params.sessionId,
      taskId: params.taskId,
      text: "중입니다."
    });
    this.emit("event", {
      type: "message.delta",
      sessionId: params.sessionId,
      taskId: params.taskId,
      text: "안녕"
    });
    this.emit("event", {
      type: "message.delta",
      sessionId: params.sessionId,
      taskId: params.taskId,
      text: "하세요"
    });
    this.emit("event", {
      type: "turn.complete",
      sessionId: params.sessionId,
      taskId: params.taskId,
      text: "안녕하세요"
    });
    return {
      ok: true,
      sessionId: params.sessionId,
      runtimeSessionId: params.sessionId,
      reply: "안녕하세요",
      reasoning: "생각 중입니다."
    };
  }

  async respondToApproval() {
    return { ok: true };
  }

  async setAccessMode() {}

  async setReasoning() {}

  close() {}
}

async function fixtureWorkspace() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "agent-engine-"));
  await fs.mkdir(path.join(root, "Notes"), { recursive: true });
  await fs.writeFile(path.join(root, "Notes", "a.md"), "# Alpha note\n\nHello.", "utf8");
  return root;
}

async function writeApprovalMcpServer(root) {
  const script = `
import readline from "readline";

let callCount = 0;
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

rl.on("line", (line) => {
  if (!line.trim()) return;
  try {
    const req = JSON.parse(line);
    if (req.method === "initialize") {
      process.stdout.write(JSON.stringify({
        jsonrpc: "2.0",
        id: req.id,
        result: {
          protocolVersion: "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: "approval-mcp", version: "1.0.0" }
        }
      }) + "\\n");
    } else if (req.method === "tools/list") {
      process.stdout.write(JSON.stringify({
        jsonrpc: "2.0",
        id: req.id,
        result: {
          tools: [
            {
              name: "delete_file",
              description: "Delete a file from the workspace",
              inputSchema: {
                type: "object",
                properties: { path: { type: "string" } },
                required: ["path"]
              }
            }
          ]
        }
      }) + "\\n");
    } else if (req.method === "tools/call") {
      callCount += 1;
      process.stdout.write(JSON.stringify({
        jsonrpc: "2.0",
        id: req.id,
        result: {
          content: [
            { type: "text", text: "delete_file called " + callCount }
          ]
        }
      }) + "\\n");
    }
  } catch (err) {}
});
`;
  const serverPath = path.join(root, "approval-mcp.mjs");
  await fs.writeFile(serverPath, script, "utf8");
  return serverPath;
}

async function* streamChunks(chunks) {
  for (const chunk of chunks) yield Buffer.from(chunk, "utf8");
}
