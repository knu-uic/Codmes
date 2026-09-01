import { EventEmitter } from "node:events";
import { createHash, randomUUID } from "node:crypto";
import {
  BUILTIN_PROVIDERS,
  listRuntimeModels,
  patchProviderCredentialEntry,
  providerBaseUrlKeys,
  providerEnvKeys,
  readCredentials,
  readProviderCredentialEntry,
  readRuntimeConfig
} from "./config-store.mjs";
import {
  executeWorkspaceTool,
  WORKSPACE_TOOL_DEFINITIONS
} from "./workspace-tools.mjs";
import { listInstalledPlugins } from "./plugin-registry.mjs";
import {
  getRuntimeContribution,
  listRuntimeToolProviders,
  listRuntimeViews
} from "./plugin-runtime.mjs";
import { ToolRegistry } from "./tool-registry.mjs";

const OPENAI_COMPATIBLE_DEFAULTS = {
  "openai-api": "https://api.openai.com/v1",
  openrouter: "https://openrouter.ai/api/v1",
  lmstudio: "http://127.0.0.1:1234/v1",
  deepseek: "https://api.deepseek.com/v1",
  xai: "https://api.x.ai/v1",
  "ollama-cloud": "https://ollama.com/v1",
  "ollama-local": "http://127.0.0.1:11434/v1",
  custom: ""
};

const CODEX_OAUTH_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const CODEX_OAUTH_TOKEN_URL = "https://auth.openai.com/oauth/token";
const CODEX_BASE_URL = "https://chatgpt.com/backend-api/codex";

export class OpenAICompatibleRuntime extends EventEmitter {
  constructor({ workspaceRoot, env = process.env, fetchImpl = globalThis.fetch, mcpClientFactory = null } = {}) {
    super();
    this.name = "codmes-openai-compatible";
    this.workspaceRoot = workspaceRoot;
    this.env = env;
    this.fetch = fetchImpl;
    this.mcpClientFactory = mcpClientFactory;
    this.sessions = new Map();
    this.mcpClients = new Map();
    this.mcpToolNameMap = new Map();
    this.toolRegistry = new ToolRegistry();
  }

  async connect() {
    if (!this.fetch) {
      throw Object.assign(new Error("This Node runtime does not provide fetch()."), { status: 500 });
    }
    return { ok: true };
  }

  async listModels() {
    return {
      models: await listRuntimeModels(this.workspaceRoot)
    };
  }

  async classifySurface(params = {}) {
    const surfaces = (await listRuntimeViews(this.workspaceRoot)).filter((view) => view.enabled !== false);
    const ids = new Set(surfaces.map((surface) => surface.id));
    if (!ids.size) return null;

    const selection = await this.resolveModelSelection(params);
    if (selection.apiMode === "codex_responses" || selection.provider.id === "openai-codex") {
      return null;
    }

    const surfaceLines = surfaces
      .map((surface) => `- ${surface.id}: ${surface.title}${surface.description ? ` — ${surface.description}` : ""}`)
      .join("\n");
    const contextRequest = params.contextRequest
      ? JSON.stringify(params.contextRequest)
      : "{}";
    const body = {
      model: selection.model,
      stream: false,
      temperature: 0,
      max_tokens: 16,
      messages: [
        {
          role: "system",
          content: [
            "Classify the user's request into exactly one Codmes surface id.",
            "Return only the id, with no punctuation or explanation.",
            "Prefer chat when uncertain.",
            surfaceLines
          ].join("\n")
        },
        {
          role: "user",
          content: `Message: ${params.message || params.prompt || ""}\nContext: ${contextRequest}`
        }
      ]
    };
    const response = await this.fetch(`${selection.baseUrl}/chat/completions`, {
      method: "POST",
      headers: {
        authorization: selection.apiKey ? `Bearer ${selection.apiKey}` : "",
        "content-type": "application/json"
      },
      body: JSON.stringify(body)
    });
    if (!response.ok) return null;
    const data = await response.json().catch(() => null);
    const raw = String(data?.choices?.[0]?.message?.content || "").trim().toLowerCase();
    const id = raw.replace(/[^a-z0-9_-]+/g, "");
    return ids.has(id) ? id : null;
  }

  async createSession(params = {}) {
    const sessionId = params.sessionId || `session-${new Date().toISOString().replace(/[:.]/g, "-")}-${randomUUID()}`;
    this.sessions.set(sessionId, {
      id: sessionId,
      createdAt: new Date().toISOString(),
      provider: params.provider || "",
      model: params.model || "",
      accessMode: params.accessMode || "",
      reasoningEffort: params.reasoningEffort || ""
    });
    return {
      ok: true,
      sessionId,
      runtimeSessionId: sessionId,
      source: "codmes"
    };
  }

  async resumeSession(sessionId) {
    if (!this.sessions.has(sessionId)) {
      this.sessions.set(sessionId, {
        id: sessionId,
        resumedAt: new Date().toISOString()
      });
    }
    return sessionId;
  }

  async submitPrompt(params = {}) {
    // The client chooses its provider/model when it creates a session. Prompt
    // submission only carries the session id, so restore that selection before
    // resolving the runtime model instead of silently falling back to the
    // workspace default model.
    const sessionParams = this.sessions.get(params.sessionId) || {};
    let activeParams = { ...sessionParams, ...params };
    let attempts = 0;
    let lastError = null;

    // Get fallback chain from config
    let chain = [];
    try {
      const config = await readRuntimeConfig(this.workspaceRoot);
      chain = config.fallbackChain || [];
    } catch {}

    for (;;) {
      let selection;
      try {
        selection = await this.resolveModelSelection(activeParams);
        const systemPrompt = await this.buildSystemPrompt(activeParams);
        const messages = buildMessages(activeParams, systemPrompt);
        const promptTokenEstimate = estimateMessagesTokens(messages);
        const contextWindow = estimateContextWindow(selection.model);

        this.emit("event", {
          type: "turn.start",
          sessionId: params.sessionId,
          taskId: params.taskId,
          provider: selection.provider.id,
          model: selection.model,
          promptTokenEstimate,
          contextWindow,
          contextUsageRatio: contextWindow ? promptTokenEstimate / contextWindow : null
        });

        const result = await this.runChatLoop(selection, messages, activeParams);

        this.emit("event", {
          type: "turn.complete",
          sessionId: params.sessionId,
          taskId: params.taskId,
          text: result.reply
        });

        return {
          ok: true,
          sessionId: params.sessionId,
          runtimeSessionId: params.sessionId,
          reply: result.reply,
          reasoning: result.reasoning,
          provider: selection.provider.id,
          model: selection.model,
          toolRounds: result.toolRounds
        };
      } catch (error) {
        lastError = error;
        // Try fallback chain
        if (attempts < chain.length) {
          const nextTarget = chain[attempts];
          attempts += 1;
          const colonIdx = nextTarget.indexOf(":");
          if (colonIdx !== -1) {
            const nextProvider = nextTarget.slice(0, colonIdx).trim();
            const nextModel = nextTarget.slice(colonIdx + 1).trim();

            this.emit("event", {
              type: "fallback.attempt",
              sessionId: params.sessionId,
              taskId: params.taskId,
              fromProvider: selection ? selection.provider.id : params.provider,
              fromModel: selection ? selection.model : params.model,
              toProvider: nextProvider,
              toModel: nextModel,
              error: error.message,
              condition: classifyError(error)
            });

            activeParams.provider = nextProvider;
            activeParams.model = nextModel;
            continue;
          }
        }
        throw error;
      }
    }
  }

  async runChatLoop(selection, messages, params) {
    let reply = "";
    let reasoning = "";
    let toolRounds = 0;
    let activeParams = {
      ...params,
      expandedToolsForThisTurn: []
    };
    const maxToolRounds = clampNumber(params.maxToolRounds, 0, 6, 3);

    for (let round = 0; round <= maxToolRounds; round += 1) {
      const result = await this.requestChatCompletion(selection, messages, activeParams);
      reply += result.text;
      if (result.reasoning) reasoning += result.reasoning;
      if (!result.toolCalls.length) {
        return { reply, reasoning, toolRounds };
      }

      toolRounds += 1;
      messages.push({
        role: "assistant",
        content: result.text || null,
        tool_calls: result.toolCalls.map((call) => ({
          id: call.id,
          type: "function",
          function: {
            name: call.name,
            arguments: call.arguments
          }
        }))
      });

      for (const call of result.toolCalls) {
        let toolResult;
        try {
          toolResult = await this.executeToolCall(call, activeParams);
        } catch (error) {
          if (error?.approvalRequired && error.pendingState) {
            const assistantMessage = messages[messages.length - 1];
            error.pendingState.continuation = {
              messages: [
                ...messages.slice(0, -1),
                {
                  ...assistantMessage,
                  tool_calls: assistantMessage.tool_calls.filter((item) => item.id === call.id)
                }
              ],
              provider: selection.provider.id,
              model: selection.model,
              reasoningEffort: params.reasoningEffort,
              maxToolRounds: Math.max(0, maxToolRounds - round)
            };
          }
          throw error;
        }
        if (call.name === "tool_discovery") {
          const expansion = expandToolsForTurn(activeParams, toolResult);
          activeParams = expansion.params;
          if (expansion.applied.length) {
            this.emit("event", {
              type: "tool.expansion.applied",
              sessionId: params.sessionId,
              taskId: params.taskId,
              surface: params.surface || "chat",
              expandedTools: expansion.applied,
              reason: toolResult.reason || toolResult.recommendation?.reason || "",
              createdAt: new Date().toISOString()
            });
          }
          if (expansion.blocked.length) {
            this.emit("event", {
              type: "tool.expansion.blocked",
              sessionId: params.sessionId,
              taskId: params.taskId,
              surface: params.surface || "chat",
              blockedTools: expansion.blocked,
              reason: "Tool discovery suggested tools that are disabled by surface mode or require approval.",
              createdAt: new Date().toISOString()
            });
          }
        }
        messages.push({
          role: "tool",
          tool_call_id: call.id,
          name: call.name,
          content: JSON.stringify(toolResult)
        });
      }
    }

    throw Object.assign(new Error("Tool call loop exceeded the maximum number of rounds."), { status: 502 });
  }

  async requestChatCompletion(selection, messages, params) {
    let text = "";
    const toolCalls = [];
    const headers = {
      "content-type": "application/json",
      accept: "text/event-stream, application/json",
      ...selection.extraHeaders
    };
    if (selection.apiKey) headers.authorization = `Bearer ${selection.apiKey}`;

    // Read toggles & MCP servers to merge active tools
    const config = await readRuntimeConfig(this.workspaceRoot);
    const { CORE_RECALL_TOOLS, getEffectiveToolMode } = await import("./tool-mode-registry.mjs");
    const { TOOL_DISCOVERY_DEFINITION } = await import("./tool-discovery.mjs");
    const { CONVERSATION_SEARCH_DEFINITION, CONVERSATION_READ_DEFINITION } = await import("./conversation-tools.mjs");
    const { MEMORY_SEARCH_DEFINITION } = await import("./memory-retrieval.mjs");

    const effectiveMode = await getEffectiveToolMode(this.workspaceRoot, params.surface || "chat");
    const enabledTools = new Set(effectiveMode.enabledTools || []);
    const expandedTools = new Set(params.expandedToolsForThisTurn || []);
    const modeDisabledTools = new Set(effectiveMode.disabledTools || []);
    const globallyDisabledTools = new Set(config.disabledTools || []);
    const coreRecallTools = new Set(CORE_RECALL_TOOLS);

    const toolRegistry = new ToolRegistry();
    for (const tool of WORKSPACE_TOOL_DEFINITIONS) {
      toolRegistry.registerOpenAITool(tool, {
        provider: {
          type: "native",
          id: "workspace",
          tool: tool.function.name
        }
      });
    }
    
    // Inject mandatory ones if not present (only when surface is specified)
    if (params.surface) {
      for (const tool of [
        TOOL_DISCOVERY_DEFINITION,
        CONVERSATION_SEARCH_DEFINITION,
        CONVERSATION_READ_DEFINITION,
        MEMORY_SEARCH_DEFINITION
      ]) {
        if (!toolRegistry.get(tool.function.name)) {
          toolRegistry.registerOpenAITool(tool, {
            provider: {
              type: "native",
              id: "codmes",
              tool: tool.function.name
            }
          });
        }
      }
    }

    this.mcpToolNameMap.clear();
    const installedPlugins = await listInstalledPlugins(this.workspaceRoot);
    const toolProviders = await listRuntimeToolProviders(this.workspaceRoot);
    for (const plugin of toolProviders) {
      for (const descriptor of plugin.tools || []) {
        if (descriptor.provider.type === "plugin") {
          toolRegistry.register(descriptor);
        }
      }
    }
    if (config.mcpServers) {
      const enabledMcpNames = new Set(
        config.mcpServers
          .filter((mcp) => mcp.enabled !== false)
          .map((mcp) => mcp.name)
      );
      // Stop any running MCP clients that were disabled or removed
      for (const [name, client] of this.mcpClients.entries()) {
        if (!enabledMcpNames.has(name)) {
          try {
            client.stop();
          } catch {}
        }
      }

      for (const mcp of config.mcpServers) {
        if (mcp.enabled !== false && (!mcp.surfaces || mcp.surfaces.includes(params.surface || "chat"))) {
          try {
            const client = await this.getOrStartMcpClient(mcp);
            const mcpTools = await client.listTools();
            for (const tool of mcpTools) {
              const plugin = installedPlugins.find((item) => item.id === mcp.pluginId);
              const declared = plugin?.tools?.find(
                (item) => item.provider.id === mcp.name && item.provider.tool === tool.name
              );
              const publicName = declared?.name || this.publicMcpToolName(mcp.name, tool.name);
              toolRegistry.register({
                name: publicName,
                description: declared?.description || tool.description || `Call ${tool.name} on ${mcp.name}.`,
                inputSchema: tool.inputSchema || declared?.inputSchema || { type: "object", properties: {} },
                provider: {
                  type: "mcp",
                  id: mcp.name,
                  tool: tool.name
                },
                surfaces: declared?.surfaces || mcp.surfaces || [],
                group: declared?.group || `mcp:${mcp.name}`,
                requiresApproval: declared?.requiresApproval === true || mcp.requiresApproval !== false,
                readOnly: declared?.readOnly === true,
                pluginId: plugin?.id || null
              });
              this.mcpToolNameMap.set(publicName, {
                serverName: mcp.name,
                originalToolName: tool.name
              });
            }
          } catch (err) {
            this.emit("event", {
              type: "mcp.error",
              sessionId: params.sessionId,
              taskId: params.taskId,
              serverName: mcp.name,
              error: err.message
            });
          }
        }
      }
    }
    this.toolRegistry = toolRegistry;
    const activeTools = toolRegistry.openAITools();

    // Filter tools based on tool mode enabledTools list
    const filteredTools = activeTools.filter((t) => {
      const name = t.function.name;
      if (globallyDisabledTools.has(name)) {
        return false;
      }
      const mappedMcpTool = this.mcpToolNameMap.get(name);
      if (mappedMcpTool) {
        const mcp = config.mcpServers?.find((server) => server.name === mappedMcpTool.serverName);
        if (mcp?.transport === "streamable_http" && mcp.surfaces?.includes(params.surface || "chat")) return true;
      }
      const descriptor = toolRegistry.get(name);
      if (descriptor?.provider.type === "plugin"
          && (!descriptor.surfaces.length || descriptor.surfaces.includes(params.surface || "chat"))) return true;
      if (coreRecallTools.has(name)) return true;
      if (modeDisabledTools.has(name)) return false;
      if (params.surface) {
        return enabledTools.has(name) || expandedTools.has(name);
      }
      return true;
    });

    if (selection.apiMode === "codex_responses" || selection.provider.id === "openai-codex") {
      return await this.requestCodexResponses(selection, messages, params, filteredTools);
    }

    const requestPayload = {
      model: selection.model,
      messages,
      stream: true,
      tools: filteredTools.length > 0 ? filteredTools : undefined,
      tool_choice: filteredTools.length > 0 ? "auto" : undefined,
      ...reasoningOptions(params.reasoningEffort)
    };

    if (this.env.CODMES_DEBUG_LLM_REQUEST === "1") {
      console.error("[codmes] LLM request", JSON.stringify({
        provider: selection.provider.id,
        model: selection.model,
        messageCount: messages.length,
        toolCount: filteredTools.length,
        stream: true
      }));
    }

    const response = await this.fetch(`${selection.baseUrl}/chat/completions`, {
      method: "POST",
      headers,
      body: JSON.stringify(requestPayload)
    });

    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw Object.assign(
        new Error(`Model request failed: ${response.status} ${text.slice(0, 500)}`),
        { status: response.status }
      );
    }

    let reasoningText = "";
    const contentType = response.headers.get("content-type") || "";
    if (contentType.includes("application/json")) {
      const json = await response.json();
      text = extractNonStreamingText(json);
      const reasoning = extractReasoningField(json.choices?.[0]?.message)
        || extractReasoningField(json.choices?.[0]?.delta)
        || "";
      
      let finalContent = text;
      let finalReasoning = reasoning;
      
      if (!reasoning && text.includes("<think>")) {
        const parsed = parseThinkTags(text);
        finalContent = parsed.text;
        finalReasoning = parsed.reasoning;
      }

      if (finalReasoning) {
        reasoningText = finalReasoning;
        this.emit("event", {
          type: "reasoning.delta",
          sessionId: params.sessionId,
          taskId: params.taskId,
          text: finalReasoning
        });
      }
      if (finalContent) {
        text = finalContent;
        this.emit("event", {
          type: "message.delta",
          sessionId: params.sessionId,
          taskId: params.taskId,
          text: finalContent
        });
      }
      toolCalls.push(...extractNonStreamingToolCalls(json));
    } else {
      for await (const chunk of parseOpenAIStream(response)) {
        if (chunk.reasoning) {
          reasoningText += chunk.reasoning;
          this.emit("event", {
            type: "reasoning.delta",
            sessionId: params.sessionId,
            taskId: params.taskId,
            text: chunk.reasoning
          });
        }
        if (chunk.text) {
          text += chunk.text;
          this.emit("event", {
            type: "message.delta",
            sessionId: params.sessionId,
            taskId: params.taskId,
            text: chunk.text
          });
        }
        if (chunk.toolCallDelta) mergeToolCallDelta(toolCalls, chunk.toolCallDelta);
      }
    }
    return {
      text,
      reasoning: reasoningText,
      toolCalls: normalizeToolCalls(toolCalls)
    };
  }

  async requestCodexResponses(selection, messages, params, filteredTools = []) {
    let text = "";
    const toolCalls = [];
    const { instructions, input } = chatMessagesToResponsesInput(messages);
    const responseTools = responsesTools(filteredTools);
    const headers = {
      "content-type": "application/json",
      accept: "text/event-stream, application/json",
      ...selection.extraHeaders
    };
    if (selection.apiKey) headers.authorization = `Bearer ${selection.apiKey}`;
    const cacheScopeId = codexCacheScopeId(params.sessionId);
    if (cacheScopeId) {
      headers.session_id = cacheScopeId;
      headers["x-client-request-id"] = cacheScopeId;
    }

    const body = {
      model: selection.model,
      instructions,
      input,
      store: false,
      stream: true,
      prompt_cache_key: codexPromptCacheKey(instructions, responseTools) || cacheScopeId,
      ...responsesReasoningOptions(params.reasoningEffort)
    };
    if (responseTools.length) {
      body.tools = responseTools;
      body.tool_choice = "auto";
      body.parallel_tool_calls = true;
    }

    const response = await this.fetch(`${selection.baseUrl}/responses`, {
      method: "POST",
      headers,
      body: JSON.stringify(body)
    });

    if (!response.ok) {
      const bodyText = await response.text().catch(() => "");
      throw Object.assign(
        new Error(`Model request failed: ${response.status} ${bodyText.slice(0, 500)}`),
        { status: response.status }
      );
    }

    const contentType = response.headers.get("content-type") || "";
    if (contentType.includes("application/json")) {
      const json = await response.json();
      text = extractResponsesText(json);
      if (text) {
        this.emit("event", {
          type: "message.delta",
          sessionId: params.sessionId,
          taskId: params.taskId,
          text
        });
      }
      toolCalls.push(...extractResponsesToolCalls(json));
    } else {
      for await (const chunk of parseResponsesStream(response)) {
        if (chunk.reasoning) {
          this.emit("event", {
            type: "reasoning.delta",
            sessionId: params.sessionId,
            taskId: params.taskId,
            text: chunk.reasoning
          });
        }
        if (chunk.text) {
          text += chunk.text;
          this.emit("event", {
            type: "message.delta",
            sessionId: params.sessionId,
            taskId: params.taskId,
            text: chunk.text
          });
        }
        if (chunk.toolCall) toolCalls.push(chunk.toolCall);
        if (chunk.completed && !text) {
          const completedText = extractResponsesText(chunk.completed);
          if (completedText) {
            text += completedText;
            this.emit("event", {
              type: "message.delta",
              sessionId: params.sessionId,
              taskId: params.taskId,
              text: completedText
            });
          }
          toolCalls.push(...extractResponsesToolCalls(chunk.completed));
        }
      }
    }

    return {
      text,
      toolCalls: normalizeToolCalls(toolCalls)
    };
  }

  async executeToolCall(call, params) {
    const config = await readRuntimeConfig(this.workspaceRoot);
    const { CORE_RECALL_TOOLS, getEffectiveToolMode } = await import("./tool-mode-registry.mjs");
    const effectiveMode = await getEffectiveToolMode(this.workspaceRoot, params.surface || "chat");
    const enabledTools = new Set(effectiveMode.enabledTools || []);
    const expandedTools = new Set(params.expandedToolsForThisTurn || []);
    const mandatory = new Set(CORE_RECALL_TOOLS);

    // Check if tool is disabled in config first
    const disabledTools = new Set(config.disabledTools || []);
    if (disabledTools.has(call.name)) {
      const errorMsg = `Tool '${call.name}' is currently disabled in config.`;
      this.emit("event", {
        type: "tool.error",
        sessionId: params.sessionId,
        taskId: params.taskId,
        toolCallId: call.id,
        toolName: call.name,
        text: errorMsg,
        error: errorMsg
      });
      return { ok: false, error: errorMsg };
    }

    // Gating check by tool modes (only when surface is specified)
    const mappedMcp = this.resolveMcpToolName(call.name);
    const registeredTool = this.toolRegistry.get(call.name);
    const mappedPlugin = registeredTool?.provider.type === "plugin"
      ? registeredTool
      : null;
    const mappedMcpConfig = mappedMcp ? config.mcpServers?.find((server) => server.name === mappedMcp.serverName) : null;
    const allowedRemoteMcp = mappedMcpConfig?.transport === "streamable_http" && mappedMcpConfig.surfaces?.includes(params.surface || "chat");
    const allowedPlugin = mappedPlugin && mappedPlugin.surfaces.includes(params.surface || "chat");
    if (params.surface && !allowedRemoteMcp && !allowedPlugin && !mandatory.has(call.name) && !enabledTools.has(call.name) && !expandedTools.has(call.name)) {
      const errorMsg = `Tool '${call.name}' is not enabled in current mode.`;
      this.emit("event", {
        type: "tool.error",
        sessionId: params.sessionId,
        taskId: params.taskId,
        toolCallId: call.id,
        toolName: call.name,
        text: errorMsg,
        error: errorMsg
      });
      return { ok: false, error: errorMsg };
    }

    // Requires approval check for workspace tools (only when surface is specified)
    const requiresApprovalList = new Set(effectiveMode.requiresApproval || []);
    const accessMode = params.accessMode || this.sessions.get(params.sessionId)?.accessMode || "confirm";
    const pluginApprovalRequired = mappedPlugin?.requiresApproval && accessMode !== "full";
    const modeApprovalRequired = !mappedPlugin && requiresApprovalList.has(call.name);
    if (params.surface && (modeApprovalRequired || pluginApprovalRequired) && params.approved !== true && !mappedMcp) {
      let preview = null;
      if (mappedPlugin) {
        const { previewPluginCollectionTool } = await import("./plugin-collection-store.mjs");
        const args = typeof call.arguments === "string" ? JSON.parse(call.arguments || "{}") : call.arguments;
        preview = await previewPluginCollectionTool(this.workspaceRoot, mappedPlugin, args);
      }
      const pendingState = {
        type: "workspace.tool.call",
        sessionId: params.sessionId,
        taskId: params.taskId,
        surface: params.surface || null,
        folderId: params.folderId || null,
        projectId: params.projectId || null,
        expandedToolsForThisTurn: params.expandedToolsForThisTurn || [],
        currentCodeTaskId: params.currentCodeTaskId || null,
        currentCodeScopePath: params.currentCodeScopePath || null,
        toolCall: call,
        toolName: call.name,
        arguments: call.arguments,
        preview,
        reason: "Approval required for this tool in current mode."
      };
      this.emit("event", {
        type: "approval.required",
        sessionId: params.sessionId,
        taskId: params.taskId,
        category: "workspace.tool.call",
        summary: `Execute tool '${call.name}'`,
        reason: "Tool execution requires approval in this mode.",
        pendingState
      });
      throw Object.assign(
        new Error(`Approval required for tool '${call.name}'.`),
        {
          status: 409,
          approvalRequired: true,
          category: "workspace.tool.call",
          summary: `Execute tool '${call.name}'`,
          reason: "Tool execution requires approval in this mode.",
          pendingState
        }
      );
    }

    // Check if it is MCP tool execution
    if (mappedMcp) {
      const resolvedMcpTool = this.resolveMcpToolName(call.name);
      if (!resolvedMcpTool) {
        const errorMsg = `MCP public tool '${call.name}' is not registered in the current runtime tool map.`;
        return { ok: false, error: errorMsg };
      }
      const mcpName = resolvedMcpTool.serverName;
      const originalToolName = resolvedMcpTool.originalToolName;

      const mcp = config.mcpServers?.find((s) => s.name === mcpName);
      if (!mcp) {
        const client = this.mcpClients.get(mcpName);
        if (client) {
          try { client.stop(); } catch {}
        }
        const errorMsg = `MCP server '${mcpName}' not found.`;
        return { ok: false, error: errorMsg };
      }
      if (mcp.enabled === false) {
        const client = this.mcpClients.get(mcpName);
        if (client) {
          try { client.stop(); } catch {}
        }
        const errorMsg = `MCP server '${mcpName}' is disabled.`;
        return { ok: false, error: errorMsg };
      }

      let argsObj = call.arguments;
      if (typeof argsObj === "string") {
        try {
          argsObj = JSON.parse(argsObj);
        } catch {
          argsObj = {};
        }
      }

      if (
        mcp.transport === "streamable_http"
        && mcp.requiresApproval !== false
        && accessMode !== "full"
        && params.approved !== true
      ) {
        const reason = "Remote plugin MCP tools require approval before contacting the service.";
        const pendingState = {
          type: "mcp.tool.call",
          sessionId: params.sessionId,
          taskId: params.taskId,
          surface: params.surface || null,
          folderId: params.folderId || null,
          projectId: params.projectId || null,
          expandedToolsForThisTurn: params.expandedToolsForThisTurn || [],
          currentCodeTaskId: params.currentCodeTaskId || null,
          currentCodeScopePath: params.currentCodeScopePath || null,
          toolCall: call,
          serverName: mcpName,
          toolName: originalToolName,
          arguments: argsObj,
          reason
        };
        this.emit("event", {
          type: "approval.required",
          sessionId: params.sessionId,
          taskId: params.taskId,
          category: "mcp.tool.call",
          summary: `Execute MCP tool '${originalToolName}' on server '${mcpName}'`,
          reason,
          pendingState
        });
        throw Object.assign(
          new Error(`Approval required for MCP tool '${originalToolName}' on server '${mcpName}'.`),
          {
            status: 409,
            approvalRequired: true,
            category: "mcp.tool.call",
            summary: `Execute MCP tool '${originalToolName}' on server '${mcpName}'`,
            reason,
            pendingState
          }
        );
      }

      this.emit("event", {
        type: "tool.start",
        sessionId: params.sessionId,
        taskId: params.taskId,
        toolCallId: call.id,
        toolName: call.name,
        text: call.name
      });

      try {
        const client = await this.getOrStartMcpClient(mcp);

        // Fetch tool metadata from client to check if it's dangerous
        const toolMeta = (client.tools || []).find(t => t.name === originalToolName) || { name: originalToolName };
        const dangerous = isDangerousMcpTool(toolMeta);

        // Security Policy Check
        const { checkAction } = await import("./security-policy.mjs");
        const policyCheck = await checkAction(this.workspaceRoot, {
          type: "mcp.tool.call",
          serverName: mcpName,
          toolName: originalToolName,
          arguments: argsObj,
          dangerous
        });

        if (policyCheck.status === "deny") {
          throw new Error(`Security block: ${policyCheck.reason}`);
        }

        if (
          policyCheck.status === "approve"
          && accessMode !== "full"
          && params.approved !== true
        ) {
          const pendingState = {
            type: "mcp.tool.call",
            sessionId: params.sessionId,
            taskId: params.taskId,
            surface: params.surface || null,
            folderId: params.folderId || null,
            projectId: params.projectId || null,
            expandedToolsForThisTurn: params.expandedToolsForThisTurn || [],
            currentCodeTaskId: params.currentCodeTaskId || null,
            currentCodeScopePath: params.currentCodeScopePath || null,
            toolCall: call,
            serverName: mcpName,
            toolName: originalToolName,
            arguments: argsObj,
            reason: policyCheck.reason
          };

          this.emit("event", {
            type: "approval.required",
            sessionId: params.sessionId,
            taskId: params.taskId,
            category: "mcp.tool.call",
            summary: `Execute MCP tool '${originalToolName}' on server '${mcpName}'`,
            reason: policyCheck.reason,
            pendingState
          });
          throw Object.assign(
            new Error(`Approval required for MCP tool '${originalToolName}' on server '${mcpName}'.`),
            {
              status: 409,
              approvalRequired: true,
              category: "mcp.tool.call",
              summary: `Execute MCP tool '${originalToolName}' on server '${mcpName}'`,
              reason: policyCheck.reason,
              pendingState
            }
          );
        }

        const mcpResult = await client.callTool(originalToolName, argsObj);
        const structuredContent = mcpResult.structuredContent
          ?? mcpResult.structured_content
          ?? null;
        const output = structuredContent === null
          ? (mcpResult.content || mcpResult)
          : {
              content: mcpResult.content || [],
              structuredContent
            };

        this.emit("event", {
          type: "tool.complete",
          sessionId: params.sessionId,
          taskId: params.taskId,
          toolCallId: call.id,
          toolName: call.name,
          text: call.name,
          result: { ok: true, output }
        });
        return { ok: true, output };
      } catch (error) {
        if (error?.approvalRequired) {
          throw error;
        }
        const errorMsg = error?.message || "MCP tool execution failed.";
        this.emit("event", {
          type: "tool.error",
          sessionId: params.sessionId,
          taskId: params.taskId,
          toolCallId: call.id,
          toolName: call.name,
          text: errorMsg,
          error: errorMsg
        });
        this.emit("event", {
          type: "mcp.error",
          sessionId: params.sessionId,
          taskId: params.taskId,
          serverName: mcpName,
          error: errorMsg
        });
        return { ok: false, error: errorMsg };
      }
    }

    if (mappedPlugin) {
      const plugin = await getRuntimeContribution(
        this.workspaceRoot,
        mappedPlugin.pluginId || mappedPlugin.provider.id
      );
      if (!plugin) return { ok: false, error: "Tool provider is not available." };
      const args = typeof call.arguments === "string" ? JSON.parse(call.arguments || "{}") : call.arguments;
      const { executePluginCollectionTool } = await import("./plugin-collection-store.mjs");
      return await executePluginCollectionTool(this.workspaceRoot, plugin, mappedPlugin, args);
    }

    this.emit("event", {
      type: "tool.start",
      sessionId: params.sessionId,
      taskId: params.taskId,
      toolCallId: call.id,
      toolName: call.name,
      text: call.name
    });
    try {
      let result;
      const args = typeof call.arguments === "string" ? JSON.parse(call.arguments || "{}") : call.arguments;
      if (call.name === "tool_discovery") {
        const { executeToolDiscovery } = await import("./tool-discovery.mjs");
        this.emit("event", {
          type: "tool.discovery.request",
          sessionId: params.sessionId,
          taskId: params.taskId,
          surface: params.surface || "chat",
          reason: args.reason || "",
          desiredCapability: args.desiredCapability || "",
          createdAt: new Date().toISOString()
        });
        result = await executeToolDiscovery(this.workspaceRoot, params.surface || "chat", {
          ...args,
          taskId: params.taskId
        }, {
          disabledTools: effectiveMode.disabledTools || []
        });
        this.emit("event", {
          type: "tool.discovery.result",
          sessionId: params.sessionId,
          taskId: params.taskId,
          surface: params.surface || "chat",
          expandedTools: result.expandedToolsForThisTurn || [],
          blockedTools: result.blockedTools || [],
          reason: result.reason || "",
          createdAt: new Date().toISOString()
        });
      } else if (call.name === "conversation_search") {
        const { executeConversationSearch } = await import("./conversation-tools.mjs");
        result = await executeConversationSearch(this.workspaceRoot, args);
      } else if (call.name === "conversation_read") {
        const { executeConversationRead } = await import("./conversation-tools.mjs");
        result = await executeConversationRead(this.workspaceRoot, args);
      } else if (call.name === "memory_search") {
        const { searchMemory } = await import("./memory-retrieval.mjs");
        result = {
          results: await searchMemory(this.workspaceRoot, args.query || "", {
            ...args,
            currentFolderId: args.currentFolderId || params.folderId || params.context?.workspaceContext?.workspace?.folderId,
            currentProjectId: args.currentProjectId || params.projectId || params.context?.workspaceContext?.workspace?.projectId
          })
        };
      } else {
        if (call.name === "codmes_search") {
          result = await this.executeCodmesSearch(args, params);
        } else {
          result = await executeWorkspaceTool(this.workspaceRoot, call.name, call.arguments, {
            codeRuntime: params.codeRuntime,
            approved: params.approved === true,
            currentCodeTaskId: params.currentCodeTaskId,
            currentCodeScopePath: params.currentCodeScopePath
          });
        }
      }
      this.emit("event", {
        type: "tool.complete",
        sessionId: params.sessionId,
        taskId: params.taskId,
        toolCallId: call.id,
        toolName: call.name,
        text: call.name,
        result
      });
      return result;
    } catch (error) {
      if (error?.approvalRequired) {
        throw error;
      }
      const result = {
        ok: false,
        error: error?.message || "Tool execution failed."
      };
      this.emit("event", {
        type: "tool.error",
        sessionId: params.sessionId,
        taskId: params.taskId,
        toolCallId: call.id,
        toolName: call.name,
        text: result.error,
        error: result.error
      });
      return result;
    }
  }

  async respondToApproval(params = {}) {
    return {
      ok: true,
      sessionId: params.sessionId,
      choice: params.approved === false ? "deny" : "once"
    };
  }

  async setAccessMode(sessionId, accessMode) {
    const session = this.sessions.get(sessionId) || { id: sessionId };
    session.accessMode = accessMode;
    this.sessions.set(sessionId, session);
  }

  async setReasoning(sessionId, reasoningEffort) {
    const session = this.sessions.get(sessionId) || { id: sessionId };
    session.reasoningEffort = reasoningEffort;
    this.sessions.set(sessionId, session);
  }

  async resumePendingState(pendingState = {}, params = {}) {
    if (pendingState.type !== "mcp.tool.call" && pendingState.type !== "workspace.tool.call") {
      throw Object.assign(new Error(`Unsupported pending state: ${pendingState.type || "(none)"}`), { status: 400 });
    }
    const result = await this.executeToolCall(pendingState.toolCall, {
      sessionId: pendingState.sessionId || params.sessionId,
      taskId: pendingState.taskId || params.taskId,
      surface: pendingState.surface || params.surface,
      folderId: pendingState.folderId || params.folderId,
      projectId: pendingState.projectId || params.projectId,
      expandedToolsForThisTurn: pendingState.expandedToolsForThisTurn || params.expandedToolsForThisTurn || [],
      codeRuntime: params.codeRuntime,
      currentCodeTaskId: pendingState.currentCodeTaskId || params.currentCodeTaskId,
      currentCodeScopePath: pendingState.currentCodeScopePath || params.currentCodeScopePath,
      approved: true
    });
    const continuation = pendingState.continuation;
    if (result?.ok !== false && continuation?.messages?.length) {
      const continuationParams = {
        sessionId: pendingState.sessionId || params.sessionId,
        taskId: pendingState.taskId || params.taskId,
        surface: pendingState.surface || params.surface,
        folderId: pendingState.folderId || params.folderId,
        projectId: pendingState.projectId || params.projectId,
        expandedToolsForThisTurn: pendingState.expandedToolsForThisTurn || params.expandedToolsForThisTurn || [],
        reasoningEffort: continuation.reasoningEffort,
        provider: continuation.provider,
        model: continuation.model,
        maxToolRounds: continuation.maxToolRounds
      };
      const selection = await this.resolveModelSelection(continuationParams);
      const messages = [
        ...continuation.messages,
        {
          role: "tool",
          tool_call_id: pendingState.toolCall.id,
          name: pendingState.toolCall.name,
          content: JSON.stringify(result)
        }
      ];
      const completed = await this.runChatLoop(selection, messages, continuationParams);
      this.emit("event", {
        type: "turn.complete",
        sessionId: continuationParams.sessionId,
        taskId: continuationParams.taskId,
        text: completed.reply
      });
      return {
        ok: true,
        status: "completed",
        type: pendingState.type,
        result,
        reply: completed.reply,
        reasoning: completed.reasoning,
        toolRounds: completed.toolRounds
      };
    }
    return {
      ok: result?.ok !== false,
      status: result?.ok === false ? "failed" : "completed",
      type: pendingState.type,
      result
    };
  }

  async getOrStartMcpClient(mcpConfig) {
    const { checkAction } = await import("./security-policy.mjs");
    const check = await checkAction(this.workspaceRoot, { type: "mcp.server.start", serverName: mcpConfig.name });
    if (check.status === "deny") {
      throw new Error(`Security block: Starting MCP server '${mcpConfig.name}' is blocked.`);
    }

    let client = this.mcpClients.get(mcpConfig.name);
    const identity = mcpConfig.transport === "streamable_http"
      ? `${mcpConfig.transport}:${mcpConfig.url}:${mcpConfig.credential_id}`
      : `stdio:${mcpConfig.command}:${JSON.stringify(mcpConfig.args || [])}:${JSON.stringify(mcpConfig.env || {})}`;
    if (client && client.connectionIdentity !== identity) {
      try { client.stop(); } catch {}
      this.mcpClients.delete(mcpConfig.name);
      client = null;
    }
    if (!client) {
      const [{ createMcpClient }, { getMcpCredential }] = await Promise.all([
        import("./mcp-client.mjs"), import("./config-store.mjs")
      ]);
      client = (this.mcpClientFactory || createMcpClient)(mcpConfig, {
        workspaceRoot: this.workspaceRoot,
        env: mcpConfig.env || {},
        tokenAccessor: () => mcpConfig.credential_id
          ? getMcpCredential(this.workspaceRoot, mcpConfig.credential_id)
          : null,
        allowUnauthenticated: mcpConfig.allowUnauthenticated === true
      });
      client.connectionIdentity = identity;
      this.mcpClients.set(mcpConfig.name, client);
    }
    if (client.status !== "running") {
      await client.start();
    }
    return client;
  }

  publicMcpToolName(serverName, originalToolName) {
    const base = `mcp__${safeToolSegment(serverName)}__${safeToolSegment(originalToolName)}`;
    const existing = this.mcpToolNameMap.get(base);
    if (!existing || (existing.serverName === serverName && existing.originalToolName === originalToolName)) {
      return base;
    }
    const suffix = createHash("sha256").update(`${serverName}\0${originalToolName}`).digest("hex").slice(0, 8);
    return `${base}__${suffix}`;
  }

  resolveMcpToolName(publicToolName) {
    const mapped = this.mcpToolNameMap.get(publicToolName);
    if (mapped) return mapped;
    if (publicToolName.startsWith("mcp__")) {
      const parts = publicToolName.split("__");
      if (parts.length >= 3) {
        return {
          serverName: parts[1],
          originalToolName: parts.slice(2).join("__")
        };
      }
      return null;
    }

    return null;
  }

  async executeCodmesSearch(args = {}) {
    const { searchWorkspace } = await import("../search-service.mjs");
    const search = await searchWorkspace(this.workspaceRoot, {
      query: args.query || "",
      scopePath: args.scopePath || "",
      maxResults: clampNumber(args.maxResults, 1, 20, 8)
    });
    return {
      ok: true,
      source: "codmes-search",
      results: normalizeWorkspaceSearchResults(search),
      fallbackUsed: false
    };
  }

  close() {
    for (const client of this.mcpClients.values()) {
      try {
        client.stop();
      } catch {}
    }
    this.mcpClients.clear();
  }

  async buildSystemPrompt(params) {
    const context = params.context?.workspaceContext || params.context || {};
    const surface = await this.surfaceForPrompt(params.surface || "chat");
    const parts = [
      "You are Codmes's built-in assistant.",
      "Answer in the same language as the user's latest message.",
      "Use provided workspace context when relevant, but do not expose it as raw metadata.",
      ...surfacePolicyLines(surface?.id || params.surface || "chat"),
      ...recallToolPolicyLines()
    ];
    if (surface?.prompt) {
      parts.push(`Surface prompt: ${surface.prompt}`);
    }

    const workspace = context.workspace || {};
    if (params.sessionSummary?.content) {
      parts.push("Current session summary:");
      parts.push(String(params.sessionSummary.content));
      if (Array.isArray(params.sessionSummary.decisions) && params.sessionSummary.decisions.length) {
        parts.push(`Session decisions: ${params.sessionSummary.decisions.slice(0, 6).join(" / ")}`);
      }
    }

    if (Array.isArray(params.memoryResults) && params.memoryResults.length) {
      parts.push("Relevant long-term memory:");
      for (const memory of params.memoryResults.slice(0, 8)) {
        parts.push(`- [${memory.type || "memory"}] ${memory.content || ""}`);
      }
    }

    if (workspace.scopeType || workspace.scopePath || workspace.activePath) {
      parts.push(`Workspace scope: ${workspace.scopeType || "none"}`);
      if (workspace.scopePath) parts.push(`Scope path: ${workspace.scopePath}`);
      if (workspace.activePath) parts.push(`Active path: ${workspace.activePath}`);
      if (workspace.ragRecommended) {
        parts.push("Search may be needed for broader folder/workspace questions.");
      }
    }

    if (params.currentCodeTaskId) {
      parts.push(`Current code task id: ${params.currentCodeTaskId}`);
      if (params.currentCodeScopePath) parts.push(`Current code task scope: ${params.currentCodeScopePath}`);
    }

    if (Array.isArray(context.inlineBlocks) && context.inlineBlocks.length) {
      parts.push("Inline workspace context:");
      for (const block of context.inlineBlocks) {
        parts.push(`--- ${block.title || block.kind || "Context"}${block.path ? `: ${block.path}` : ""} ---`);
        parts.push(String(block.content || ""));
      }
    }

    if (Array.isArray(context.searchResults) && context.searchResults.length) {
      parts.push("Search results context:");
      for (const result of context.searchResults.slice(0, 12)) {
        parts.push(`--- Search result: ${result.path || "(unknown)"}${result.kind ? ` (${result.kind})` : ""} ---`);
        parts.push(String(result.snippet || result.text || "").slice(0, 2000));
      }
    }

    if (Array.isArray(context.ragChunks) && context.ragChunks.length) {
      parts.push("RAG chunk context:");
      for (const chunk of context.ragChunks.slice(0, 12)) {
        const page = chunk.page !== undefined && chunk.page !== null ? ` page ${chunk.page}` : "";
        parts.push(`--- Chunk: ${chunk.path || "(unknown)"}${page} ---`);
        parts.push(String(chunk.text || "").slice(0, 2000));
      }
    }

    if (Array.isArray(context.fileList) && context.fileList.length) {
      parts.push("Workspace file list:");
      for (const item of context.fileList.slice(0, 200)) {
        parts.push(`- ${item.path} (${item.kind})`);
      }
    }

    if (Array.isArray(context.resources) && context.resources.length) {
      parts.push("Linked resources:");
      for (const item of context.resources.slice(0, 100)) {
        parts.push(`- ${item.path} (${item.kind})`);
      }
    }

    try {
      const { listSkills } = await import("./skill-registry.mjs");
      const skills = await listSkills(this.workspaceRoot);
      const userPrompt = String(params.prompt || params.message || "").toLowerCase();
      const historyText = (params.history || [])
        .map((h) => String(h.content || ""))
        .join(" ")
        .toLowerCase();
      const fullTextContext = `${userPrompt} ${historyText}`;

      const taskType = params.taskId ? "code" : "chat";

      for (const skill of skills) {
        if (skill.config.enabled === false) continue;

        if (Array.isArray(skill.config.taskTypes) && skill.config.taskTypes.length > 0) {
          if (!skill.config.taskTypes.includes(taskType)) continue;
        }

        if (Array.isArray(skill.config.triggers) && skill.config.triggers.length > 0) {
          const matched = skill.config.triggers.some((trigger) =>
            fullTextContext.includes(String(trigger).toLowerCase())
          );
          if (!matched) continue;
        }

        parts.push(`\n--- Skill: ${skill.name} ---`);
        parts.push(skill.skillMd);
      }
    } catch (err) {
      // ignore
    }

    return parts.join("\n");
  }

  async surfaceForPrompt(surfaceId) {
    try {
      const surfaces = await listRuntimeViews(this.workspaceRoot);
      return surfaces.find((surface) => surface.id === surfaceId) || null;
    } catch {
      return null;
    }
  }

  async resolveModelSelection(params = {}) {
    const config = await readRuntimeConfig(this.workspaceRoot);
    const providerId = params.provider || config.defaultModel?.provider || "";
    const model = params.model || config.defaultModel?.model || "";
    if (!providerId || !model) {
      throw Object.assign(
        new Error("No default model is configured. Run `codmes model set-default <provider> <model>`."),
        { status: 503, setupRequired: true }
      );
    }

    const provider = BUILTIN_PROVIDERS.find((item) => item.id === providerId);
    if (!provider) {
      throw Object.assign(new Error(`Unknown provider: ${providerId}`), { status: 400 });
    }

    const baseUrl = await this.resolveBaseUrl(provider, config);
    if (!baseUrl) {
      throw Object.assign(
        new Error(`Provider '${providerId}' needs a base URL. Store ${provider.baseUrlEnv || "baseUrl"} with codmes auth set or set the matching environment variable.`),
        { status: 503, setupRequired: true }
      );
    }

    const apiKey = provider.id === "openai-codex"
      ? await this.resolveCodexApiKey()
      : await this.resolveApiKey(provider);
    if (provider.authType === "api_key" && !apiKey && !["lmstudio", "custom"].includes(provider.id)) {
      throw Object.assign(
        new Error(`Provider '${providerId}' needs an API key. Run codmes auth set ${providerId} <KEY_NAME> <VALUE>.`),
        { status: 503, setupRequired: true }
      );
    }

    return {
      provider,
      model,
      baseUrl: trimTrailingSlash(baseUrl),
      apiKey,
      apiMode: params.apiMode || config.defaultModel?.apiMode || (provider.id === "openai-codex" ? "codex_responses" : "chat_completions"),
      extraHeaders: provider.id === "openrouter" ? {
        "HTTP-Referer": "http://localhost",
        "X-Title": "Codmes"
      } : provider.id === "openai-codex" ? codexBackendHeaders(apiKey) : {}
    };
  }

  async resolveBaseUrl(provider, config = null) {
    const credentials = await readCredentials(this.workspaceRoot);
    const values = credentials.providers?.[provider.id]?.values || {};
    const baseKeys = providerBaseUrlKeys(provider);
    return (config?.defaultModel?.provider === provider.id ? config.defaultModel?.baseUrl : "")
      || values.baseUrl
      || values.BASE_URL
      || firstValue(values, baseKeys)
      || firstValue(this.env, baseKeys)
      || provider.defaultBaseUrl
      || (provider.id === "openai-codex" ? CODEX_BASE_URL : "")
      || OPENAI_COMPATIBLE_DEFAULTS[provider.id]
      || "";
  }

  async resolveApiKey(provider) {
    const credentials = await readCredentials(this.workspaceRoot);
    const values = credentials.providers?.[provider.id]?.values || {};
    for (const key of providerEnvKeys(provider)) {
      if (values[key]) return values[key];
      if (this.env[key]) return this.env[key];
    }
    return values.apiKey || values.API_KEY || values.token || values.TOKEN || "";
  }

  async resolveCodexApiKey() {
    const entry = await readProviderCredentialEntry(this.workspaceRoot, "openai-codex");
    let accessToken = String(entry?.access_token || "").trim();
    const refreshToken = String(entry?.refresh_token || "").trim();
    if (!accessToken) {
      throw Object.assign(
        new Error("OpenAI Codex is not authenticated. Run `codmes model` and sign in to OpenAI Codex."),
        { status: 503, setupRequired: true }
      );
    }
    if (refreshToken && jwtExpiresSoon(accessToken, 120)) {
      const refreshed = await this.refreshCodexToken(accessToken, refreshToken);
      accessToken = refreshed.accessToken;
      await patchProviderCredentialEntry(this.workspaceRoot, "openai-codex", {
        access_token: refreshed.accessToken,
        refresh_token: refreshed.refreshToken || refreshToken,
        last_refresh: new Date().toISOString()
      });
    }
    return accessToken;
  }

  async refreshCodexToken(accessToken, refreshToken) {
    const response = await this.fetch(CODEX_OAUTH_TOKEN_URL, {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        accept: "application/json",
        "user-agent": "codmes-cli/0.0.0"
      },
      body: new URLSearchParams({
        grant_type: "refresh_token",
        refresh_token: refreshToken,
        client_id: CODEX_OAUTH_CLIENT_ID
      })
    });
    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw Object.assign(
        new Error(`OpenAI Codex token refresh failed: ${response.status} ${text.slice(0, 300)}`),
        { status: 401, setupRequired: true }
      );
    }
    const payload = await response.json();
    const nextAccess = String(payload.access_token || "").trim();
    if (!nextAccess) {
      throw Object.assign(new Error("OpenAI Codex token refresh returned no access token."), { status: 401, setupRequired: true });
    }
    return {
      accessToken: nextAccess,
      refreshToken: String(payload.refresh_token || refreshToken || "").trim()
    };
  }
}

function buildMessages(params, systemPrompt) {
  const messages = [];
  const system = systemPrompt || buildSystemMessage(params);
  if (system) messages.push({ role: "system", content: system });
  for (const item of params.history || []) {
    if ((item.role === "user" || item.role === "assistant") && item.content) {
      messages.push({ role: item.role, content: String(item.content) });
    }
  }
  messages.push({
    role: "user",
    content: params.prompt || params.message || ""
  });
  return messages;
}

function firstValue(source, keys) {
  for (const key of keys || []) {
    if (source?.[key]) return source[key];
  }
  return "";
}

function buildSystemMessage(params) {
  const context = params.context?.workspaceContext || params.context || {};
  const parts = [
    "You are Codmes's built-in assistant.",
    "Answer in the same language as the user's latest message.",
    "Use provided workspace context when relevant, but do not expose it as raw metadata.",
    ...recallToolPolicyLines()
  ];

  const workspace = context.workspace || {};
  if (params.sessionSummary?.content) {
    parts.push("Current session summary:");
    parts.push(String(params.sessionSummary.content));
    if (Array.isArray(params.sessionSummary.decisions) && params.sessionSummary.decisions.length) {
      parts.push(`Session decisions: ${params.sessionSummary.decisions.slice(0, 6).join(" / ")}`);
    }
  }

  if (Array.isArray(params.memoryResults) && params.memoryResults.length) {
    parts.push("Relevant long-term memory:");
    for (const memory of params.memoryResults.slice(0, 8)) {
      parts.push(`- [${memory.type || "memory"}] ${memory.content || ""}`);
    }
  }

  if (workspace.scopeType || workspace.scopePath || workspace.activePath) {
    parts.push(`Workspace scope: ${workspace.scopeType || "none"}`);
    if (workspace.scopePath) parts.push(`Scope path: ${workspace.scopePath}`);
    if (workspace.activePath) parts.push(`Active path: ${workspace.activePath}`);
    if (workspace.ragRecommended) {
      parts.push("Search may be needed for broader folder/workspace questions.");
    }
  }

  if (params.currentCodeTaskId) {
    parts.push(`Current code task id: ${params.currentCodeTaskId}`);
    if (params.currentCodeScopePath) parts.push(`Current code task scope: ${params.currentCodeScopePath}`);
  }

  if (Array.isArray(context.inlineBlocks) && context.inlineBlocks.length) {
    parts.push("Inline workspace context:");
    for (const block of context.inlineBlocks) {
      parts.push(`--- ${block.title || block.kind || "Context"}${block.path ? `: ${block.path}` : ""} ---`);
      parts.push(String(block.content || ""));
    }
  }

  if (Array.isArray(context.searchResults) && context.searchResults.length) {
    parts.push("Search results context:");
    for (const result of context.searchResults.slice(0, 12)) {
      parts.push(`--- Search result: ${result.path || "(unknown)"}${result.kind ? ` (${result.kind})` : ""} ---`);
      parts.push(String(result.snippet || result.text || "").slice(0, 2000));
    }
  }

  if (Array.isArray(context.ragChunks) && context.ragChunks.length) {
    parts.push("RAG chunk context:");
    for (const chunk of context.ragChunks.slice(0, 12)) {
      const page = chunk.page !== undefined && chunk.page !== null ? ` page ${chunk.page}` : "";
      parts.push(`--- Chunk: ${chunk.path || "(unknown)"}${page} ---`);
      parts.push(String(chunk.text || "").slice(0, 2000));
    }
  }

  if (Array.isArray(context.fileList) && context.fileList.length) {
    parts.push("Workspace file list:");
    for (const item of context.fileList.slice(0, 200)) {
      parts.push(`- ${item.path} (${item.kind})`);
    }
  }

  if (Array.isArray(context.resources) && context.resources.length) {
    parts.push("Linked resources:");
    for (const item of context.resources.slice(0, 100)) {
      parts.push(`- ${item.path} (${item.kind})`);
    }
  }

  return parts.join("\n");
}

function reasoningOptions(value) {
  const effort = String(value || "").toLowerCase();
  if (!effort || effort === "medium" || effort === "med") return {};
  if (effort === "fast" || effort === "low") return { reasoning_effort: "low" };
  if (effort === "deep" || effort === "high") return { reasoning_effort: "high" };
  return { reasoning_effort: effort };
}

function responsesReasoningOptions(value) {
  const effort = String(value || "").toLowerCase();
  const normalized = effort === "fast" || effort === "low" ? "low"
    : effort === "deep" || effort === "high" ? "high"
      : "medium";
  return {
    reasoning: { effort: normalized, summary: "auto" },
    include: ["reasoning.encrypted_content"]
  };
}

function codexPromptCacheKey(instructions, tools) {
  if (!instructions && (!tools || !tools.length)) return null;
  const sortedTools = (tools || [])
    .filter((tool) => tool && typeof tool === "object")
    .slice()
    .sort((a, b) => String(a.name || a.type || "").localeCompare(String(b.name || b.type || "")));
  const toolsPart = sortedTools.length
    ? JSON.stringify(sortedTools)
    : "";
  const digest = createHash("sha256")
    .update(`${instructions || ""}\0${toolsPart}`)
    .digest("hex")
    .slice(0, 24);
  return `pck_${digest}`;
}

function codexCacheScopeId(sessionId) {
  const raw = String(sessionId || "").trim();
  if (!raw) return "";
  const digest = createHash("sha256").update(raw).digest("hex").slice(0, 24);
  return `codmes_${digest}`;
}

function estimateMessagesTokens(messages = []) {
  const text = (messages || []).map((message) => {
    if (!message || typeof message !== "object") return "";
    const content = message.content;
    if (typeof content === "string") return content;
    if (Array.isArray(content)) {
      return content.map((part) => typeof part === "string" ? part : JSON.stringify(part || {})).join(" ");
    }
    return JSON.stringify(content || "");
  }).join("\n");
  return Math.max(1, Math.ceil(text.length / 4));
}

function estimateContextWindow(model = "") {
  const id = String(model || "").toLowerCase();
  if (!id) return null;
  if (id.includes("gpt-5") || id.includes("gpt-4.1") || id.includes("gemini-2.5") || id.includes("gemini-3")) return 1_000_000;
  if (id.includes("claude") || id.includes("opus") || id.includes("sonnet")) return 200_000;
  if (id.includes("qwen") || id.includes("deepseek") || id.includes("kimi")) return 128_000;
  if (id.includes("llama") || id.includes("gemma") || id.includes("mistral")) return 32_000;
  return 128_000;
}

function getPartialMatch(str, target) {
  for (let len = Math.min(str.length, target.length - 1); len > 0; len--) {
    if (target.startsWith(str.slice(-len))) {
      return len;
    }
  }
  return 0;
}

function parseThinkTags(str) {
  let text = "";
  let reasoning = "";
  let cursor = 0;
  
  while (cursor < str.length) {
    const openIdx = str.indexOf("<think>", cursor);
    if (openIdx === -1) {
      const tail = str.slice(cursor);
      const partialOpen = getPartialMatch(tail, "<think>");
      if (partialOpen > 0) {
        text += tail.slice(0, tail.length - partialOpen);
      } else {
        text += tail;
      }
      break;
    }
    
    text += str.slice(cursor, openIdx);
    
    const closeIdx = str.indexOf("</think>", openIdx);
    if (closeIdx === -1) {
      const tail = str.slice(openIdx + 7);
      const partialClose = getPartialMatch(tail, "</think>");
      if (partialClose > 0) {
        reasoning += tail.slice(0, tail.length - partialClose);
      } else {
        reasoning += tail;
      }
      break;
    }
    
    reasoning += str.slice(openIdx + 7, closeIdx);
    cursor = closeIdx + 8;
    
    while (cursor < str.length && /\s/.test(str[cursor])) {
      cursor++;
    }
  }
  
  return { text, reasoning };
}

function extractReasoningField(value) {
  if (!value || typeof value !== "object") return "";
  return String(
    value.reasoning_content
      || value.reasoning
      || value.thinking
      || value.reasoningContent
      || value.thinking_content
      || ""
  );
}

async function* parseOpenAIStream(response) {
  const decoder = new TextDecoder();
  let buffer = "";
  let fullTextAccumulator = "";
  let lastEmittedTextLength = 0;
  let lastEmittedReasoningLength = 0;

  for await (const rawChunk of response.body) {
    buffer += decoder.decode(rawChunk, { stream: true });
    let boundary;
    while ((boundary = buffer.indexOf("\n\n")) !== -1) {
      const frame = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);
      for (const line of frame.split(/\r?\n/)) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("data:")) continue;
        const data = trimmed.slice(5).trim();
        if (!data || data === "[DONE]") continue;
        try {
          const json = JSON.parse(data);
          const text = json.choices?.[0]?.delta?.content
            || json.choices?.[0]?.message?.content
            || json.output_text
            || "";
          const reasoning = extractReasoningField(json.choices?.[0]?.delta);
          const toolCalls = json.choices?.[0]?.delta?.tool_calls || [];
          
          if (reasoning) {
            yield {
              text: "",
              reasoning,
              toolCallDelta: toolCalls.length ? toolCalls : null,
              raw: json
            };
          } else if (text) {
            fullTextAccumulator += text;
            const parsed = parseThinkTags(fullTextAccumulator);
            
            const deltaText = parsed.text.slice(lastEmittedTextLength);
            const deltaReasoning = parsed.reasoning.slice(lastEmittedReasoningLength);
            
            if (deltaText) lastEmittedTextLength = parsed.text.length;
            if (deltaReasoning) lastEmittedReasoningLength = parsed.reasoning.length;
            
            if (deltaText || deltaReasoning || toolCalls.length) {
              yield {
                text: deltaText,
                reasoning: deltaReasoning,
                toolCallDelta: toolCalls.length ? toolCalls : null,
                raw: json
              };
            }
          } else if (toolCalls.length) {
            yield {
              text: "",
              reasoning: "",
              toolCallDelta: toolCalls,
              raw: json
            };
          }
        } catch {}
      }
    }
  }
}

async function* parseResponsesStream(response) {
  const decoder = new TextDecoder();
  let buffer = "";
  for await (const rawChunk of response.body) {
    buffer += decoder.decode(rawChunk, { stream: true });
    let boundary;
    while ((boundary = buffer.indexOf("\n\n")) !== -1) {
      const frame = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);
      for (const line of frame.split(/\r?\n/)) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("data:")) continue;
        const data = trimmed.slice(5).trim();
        if (!data || data === "[DONE]") continue;
        let json;
        try {
          json = JSON.parse(data);
        } catch {
          continue;
        }
        const eventType = String(json.type || "");
        if (eventType === "error") {
          const error = json.error || {};
          throw new Error(error.message || JSON.stringify(error));
        }
        if (eventType.includes("output_text.delta")) {
          yield { text: String(json.delta || ""), raw: json };
          continue;
        }
        if (eventType.includes("reasoning") && eventType.includes("delta")) {
          yield { reasoning: String(json.delta || ""), raw: json };
          continue;
        }
        if (eventType === "response.output_item.done") {
          const call = responseOutputItemToToolCall(json.item);
          if (call) yield { toolCall: call, raw: json };
          continue;
        }
        if (eventType === "response.completed") {
          yield { completed: json.response || json, raw: json };
          continue;
        }
        if (eventType === "response.failed") {
          const error = json.response?.error || json.error || {};
          throw new Error(error.message || JSON.stringify(error));
        }
      }
    }
  }
}

function extractNonStreamingText(json) {
  return json.choices?.[0]?.message?.content
    || json.choices?.[0]?.delta?.content
    || json.output_text
    || "";
}

function extractResponsesText(json) {
  if (!json || typeof json !== "object") return "";
  if (typeof json.output_text === "string") return json.output_text;
  const output = Array.isArray(json.output) ? json.output : [];
  const chunks = [];
  for (const item of output) {
    if (item?.type !== "message") continue;
    for (const part of item.content || []) {
      if ((part.type === "output_text" || part.type === "text") && typeof part.text === "string") {
        chunks.push(part.text);
      }
    }
  }
  return chunks.join("");
}

function extractResponsesToolCalls(json) {
  const output = Array.isArray(json?.output) ? json.output : [];
  return output.map(responseOutputItemToToolCall).filter(Boolean);
}

function responseOutputItemToToolCall(item) {
  if (!item || typeof item !== "object") return null;
  if (item.type !== "function_call" && item.type !== "custom_tool_call") return null;
  const name = String(item.name || "").trim();
  if (!name) return null;
  const args = item.arguments ?? item.input ?? "{}";
  return {
    id: String(item.call_id || item.id || ""),
    name,
    arguments: typeof args === "string" ? args : JSON.stringify(args)
  };
}

function extractNonStreamingToolCalls(json) {
  const calls = json.choices?.[0]?.message?.tool_calls || [];
  return calls.map((call, index) => ({
    id: call.id || `call_${index}`,
    name: call.function?.name || "",
    arguments: call.function?.arguments || "{}"
  })).filter((call) => call.name);
}

function chatMessagesToResponsesInput(messages) {
  let instructions = "";
  const input = [];
  for (const msg of messages || []) {
    if (!msg || typeof msg !== "object") continue;
    if (msg.role === "system") {
      instructions = instructions ? `${instructions}\n\n${msg.content || ""}` : String(msg.content || "");
      continue;
    }
    if (msg.role === "assistant" && Array.isArray(msg.tool_calls)) {
      if (msg.content) {
        input.push({
          role: "assistant",
          content: [{ type: "output_text", text: String(msg.content) }]
        });
      }
      for (const call of msg.tool_calls) {
        const fn = call.function || {};
        input.push({
          type: "function_call",
          call_id: String(call.id || ""),
          name: String(fn.name || ""),
          arguments: typeof fn.arguments === "string" ? fn.arguments : JSON.stringify(fn.arguments || {})
        });
      }
      continue;
    }
    if (msg.role === "tool") {
      input.push({
        type: "function_call_output",
        call_id: String(msg.tool_call_id || ""),
        output: String(msg.content || "")
      });
      continue;
    }
    if (msg.role === "user" || msg.role === "assistant") {
      input.push({
        role: msg.role,
        content: [{
          type: msg.role === "assistant" ? "output_text" : "input_text",
          text: String(msg.content || "")
        }]
      });
    }
  }
  return { instructions, input };
}

function responsesTools(tools = []) {
  return (tools || [])
    .map((tool) => {
      const fn = tool?.function || {};
      const name = String(fn.name || "").trim();
      if (!name) return null;
      return {
        type: "function",
        name,
        description: typeof fn.description === "string" ? fn.description : "",
        strict: false,
        parameters: fn.parameters || { type: "object", properties: {} }
      };
    })
    .filter(Boolean);
}

function mergeToolCallDelta(toolCalls, deltas) {
  for (const delta of deltas || []) {
    const index = Number.isInteger(delta.index) ? delta.index : toolCalls.length;
    if (!toolCalls[index]) {
      toolCalls[index] = {
        id: "",
        name: "",
        arguments: ""
      };
    }
    const target = toolCalls[index];
    if (delta.id) target.id += delta.id;
    if (delta.function?.name) target.name += delta.function.name;
    if (delta.function?.arguments) target.arguments += delta.function.arguments;
  }
}

function normalizeToolCalls(toolCalls) {
  return toolCalls
    .filter(Boolean)
    .map((call, index) => ({
      id: call.id || `call_${index}`,
      name: call.name || "",
      arguments: call.arguments || "{}"
    }))
    .filter((call) => call.name);
}

function clampNumber(value, min, max, fallback) {
  const number = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(max, Math.max(min, number));
}

function expandToolsForTurn(params, toolResult = {}) {
  const current = new Set(params.expandedToolsForThisTurn || []);
  const discovered = toolResult.expandedToolsForThisTurn
    || toolResult.recommendation?.enableForThisTurn
    || [];
  const blockedNames = new Set((toolResult.blockedTools || []).map((item) => typeof item === "string" ? item : item.name));
  const applied = [];
  for (const name of discovered) {
    if (!name || blockedNames.has(String(name))) continue;
    if (!current.has(String(name))) applied.push(String(name));
    current.add(String(name));
  }
  return {
    params: {
      ...params,
      expandedToolsForThisTurn: Array.from(current)
    },
    applied,
    blocked: toolResult.blockedTools || []
  };
}

function isMcpPublicToolName(name) {
  return String(name || "").startsWith("mcp_");
}

function safeToolSegment(value) {
  const safe = String(value || "")
    .replace(/[^a-zA-Z0-9_]/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "");
  return safe || "tool";
}

function recallToolPolicyLines() {
  return [
    "Recall policy: use memory_search for compact long-term facts, preferences, project memories, folder memories, and session summaries.",
    "Recall policy: if relevant long-term memory directly answers the latest user question, use it directly and do not search again.",
    "Recall policy: use conversation_search to find past sessions/messages and conversation_read only after conversation_search returns concrete sessionId/messageIds.",
    "Recall policy: do not treat memory_search results as exact transcripts; use conversation_read for exact wording and surrounding context."
  ];
}

function surfacePolicyLines(surface) {
  switch (String(surface || "chat").toLowerCase()) {
    case "code":
      return [
        "Surface mode: Code.",
        "Prefer code-oriented planning, repository inspection, precise file reads, proposed patches, checks, git inspection, and approval-aware tool calls.",
        "For code changes, inspect before editing, explain the plan briefly, propose or apply patches through the available Code tools, and verify with checks when appropriate."
      ];
    case "notes":
      return [
        "Surface mode: Notes.",
        "Prefer Codmes built-in note/document/PDF/code/conversation search, file metadata, and concise citations to workspace-relative paths.",
        "For broad folder or document questions, search before answering instead of guessing from filenames alone."
      ];
    case "chat":
    default:
      return [
        "Surface mode: Chat.",
        "Use recall and tool discovery when the latest request appears to need a more specialized surface capability such as notes search or code tools."
      ];
  }
}

function normalizeWorkspaceSearchResults(result = {}) {
  const rows = Array.isArray(result.results) ? result.results : [];
  return rows.map((item, index) => ({
    path: item.path || "",
    title: item.title || item.name || item.path || "",
    snippet: item.snippet || item.text || "",
    score: Number.isFinite(Number(item.score)) ? Number(item.score) : undefined,
    page: item.page,
    chunkId: item.chunkId || `${index + 1}`
  }));
}

function jwtExpiresSoon(token, skewSeconds = 120) {
  const claims = decodeJwtPayload(token);
  const exp = Number(claims?.exp || 0);
  if (!Number.isFinite(exp) || exp <= 0) return false;
  return exp <= Math.floor(Date.now() / 1000) + skewSeconds;
}

function decodeJwtPayload(token) {
  try {
    const parts = String(token || "").split(".");
    if (parts.length < 2) return null;
    const padded = parts[1] + "=".repeat((4 - (parts[1].length % 4)) % 4);
    return JSON.parse(Buffer.from(padded, "base64url").toString("utf8"));
  } catch {
    return null;
  }
}

function codexBackendHeaders(accessToken) {
  const headers = {
    "user-agent": "codex_cli_rs/0.0.0 (Codmes)",
    originator: "codex_cli_rs"
  };
  const claims = decodeJwtPayload(accessToken);
  const accountId = claims?.["https://api.openai.com/auth"]?.chatgpt_account_id;
  if (typeof accountId === "string" && accountId.trim()) {
    headers["ChatGPT-Account-ID"] = accountId.trim();
  }
  return headers;
}

function trimTrailingSlash(value) {
  return String(value || "").replace(/\/+$/, "");
}

export function classifyError(error) {
  const msg = String(error?.message || "").toLowerCase();
  const status = error?.status;

  if (status === 429 || msg.includes("rate limit") || msg.includes("too many requests")) {
    return "rate_limit";
  }
  if (
    status === 401 ||
    status === 403 ||
    msg.includes("api key") ||
    msg.includes("unauthorized") ||
    msg.includes("credential") ||
    msg.includes("auth") ||
    error?.setupRequired
  ) {
    return "auth_error";
  }
  if (
    msg.includes("fetch failed") ||
    msg.includes("enotfound") ||
    msg.includes("econnrefused") ||
    msg.includes("network") ||
    status === 502 ||
    status === 504
  ) {
    return "network_error";
  }
  if (status === 404 || msg.includes("model not found") || msg.includes("unknown model") || msg.includes("model unavailable")) {
    return "model_unavailable";
  }
  if (status === 503 || msg.includes("provider unavailable") || msg.includes("unknown provider")) {
    return "provider_unavailable";
  }
  if (status >= 500) {
    return "provider_unavailable";
  }
  return "unknown_error";
}

export function isDangerousMcpTool(tool) {
  const name = String(tool.name).toLowerCase();
  const desc = String(tool.description || "").toLowerCase();
  const dangerousKeywords = [
    "write", "delete", "remove", "destroy", "bash", "shell", "run", "execute",
    "git", "push", "patch", "modify", "install", "download", "fetch", "http",
    "curl", "wget", "rm", "kill", "stop"
  ];
  return dangerousKeywords.some((kw) => name.includes(kw) || desc.includes(kw));
}
