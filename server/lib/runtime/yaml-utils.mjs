export function parseConfigYaml(content) {
  const lines = content.split(/\r?\n/);
  const result = {
    model: null,
    custom_providers: [],
    disabled_tools: [],
    mcp_servers: [],
    security: null
  };

  let inModel = false;
  let inCustomProviders = false;
  let inDisabledTools = false;
  let inMcpServers = false;
  let inSecurity = false;
  let inAllowedCommands = false;
  let inDeniedCommands = false;
  let inRequireApproval = false;
  let inMcpEnv = false;
  let inMcpSurfaces = false;
  let currentCustomProvider = null;
  let currentMcpServer = null;

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const indent = line.search(/\S/);

    if (indent === 0) {
      inModel = trimmed.startsWith("model:");
      inCustomProviders = trimmed.startsWith("custom_providers:");
      inDisabledTools = trimmed.startsWith("disabled_tools:");
      inMcpServers = trimmed.startsWith("mcp_servers:");
      inSecurity = trimmed.startsWith("security:");
      inAllowedCommands = false;
      inDeniedCommands = false;
      inRequireApproval = false;
      inMcpEnv = false;
      if (currentCustomProvider) {
        result.custom_providers.push(currentCustomProvider);
        currentCustomProvider = null;
      }
      if (currentMcpServer) {
        result.mcp_servers.push(currentMcpServer);
        currentMcpServer = null;
      }
      continue;
    }

    if (inModel && indent > 0) {
      if (!result.model) result.model = { fallback_chain: [] };
      if (trimmed.startsWith("-")) {
        const v = stripQuotes(trimmed.slice(1).trim());
        if (!result.model.fallback_chain) result.model.fallback_chain = [];
        result.model.fallback_chain.push(v);
      } else {
        const colonIdx = trimmed.indexOf(":");
        if (colonIdx !== -1) {
          const k = trimmed.slice(0, colonIdx).trim();
          const v = stripQuotes(trimmed.slice(colonIdx + 1).trim());
          if (k !== "fallback_chain") {
            result.model[k] = v;
          }
        }
      }
    }

    if (inDisabledTools && indent > 0) {
      if (trimmed.startsWith("-")) {
        result.disabled_tools.push(stripQuotes(trimmed.slice(1).trim()));
      }
    }

    if (inCustomProviders && indent > 0) {
      if (trimmed.startsWith("-")) {
        if (currentCustomProvider) {
          result.custom_providers.push(currentCustomProvider);
        }
        currentCustomProvider = {};
        const rest = trimmed.slice(1).trim();
        const colonIdx = rest.indexOf(":");
        if (colonIdx !== -1) {
          const k = rest.slice(0, colonIdx).trim();
          const v = stripQuotes(rest.slice(colonIdx + 1).trim());
          currentCustomProvider[k] = v;
        }
      } else if (currentCustomProvider) {
        const colonIdx = trimmed.indexOf(":");
        if (colonIdx !== -1) {
          const k = trimmed.slice(0, colonIdx).trim();
          const v = stripQuotes(trimmed.slice(colonIdx + 1).trim());
          currentCustomProvider[k] = v;
        }
      }
    }

    if (inMcpServers && indent > 0) {
      if (trimmed.startsWith("-") && (trimmed.includes(":") || !currentMcpServer)) {
        if (currentMcpServer) {
          result.mcp_servers.push(currentMcpServer);
        }
        currentMcpServer = { args: [], env: {} };
        inMcpEnv = false;
        inMcpSurfaces = false;
        const rest = trimmed.slice(1).trim();
        const colonIdx = rest.indexOf(":");
        if (colonIdx !== -1) {
          const k = rest.slice(0, colonIdx).trim();
          const v = stripQuotes(rest.slice(colonIdx + 1).trim());
          if (k !== "args") {
            currentMcpServer[k] = v;
          }
        }
      } else if (currentMcpServer) {
        if (trimmed.startsWith("env:")) {
          currentMcpServer.env = currentMcpServer.env || {};
          inMcpEnv = true;
          inMcpSurfaces = false;
        } else if (trimmed.startsWith("args:")) {
          currentMcpServer.args = currentMcpServer.args || [];
          inMcpEnv = false;
          inMcpSurfaces = false;
        } else if (trimmed.startsWith("surfaces:")) {
          currentMcpServer.surfaces = currentMcpServer.surfaces || [];
          inMcpEnv = false;
          inMcpSurfaces = true;
        } else if (trimmed.startsWith("-")) {
          if (inMcpSurfaces) currentMcpServer.surfaces.push(stripQuotes(trimmed.slice(1).trim()));
          else currentMcpServer.args.push(stripQuotes(trimmed.slice(1).trim()));
        } else {
          const colonIdx = trimmed.indexOf(":");
          if (colonIdx !== -1) {
            const k = trimmed.slice(0, colonIdx).trim();
            const v = stripQuotes(trimmed.slice(colonIdx + 1).trim());
            if (inMcpEnv) {
              currentMcpServer.env = currentMcpServer.env || {};
              currentMcpServer.env[k] = v;
            } else if (k === "scope_path") {
              currentMcpServer.scopePath = v;
            } else if (k === "enabled") {
              currentMcpServer[k] = parseBooleanString(v, true);
            } else if (k !== "args") {
              inMcpSurfaces = false;
              currentMcpServer[k] = v;
            }
          }
        }
      }
    }

    if (inSecurity && indent > 0) {
      if (!result.security) {
        result.security = {
          approval_mode: "suggest",
          allow_shell: true,
          allowed_commands: [],
          denied_commands: [],
          require_approval: []
        };
      }
      if (trimmed.startsWith("allowed_commands:")) {
        inAllowedCommands = true;
        inDeniedCommands = false;
        inRequireApproval = false;
      } else if (trimmed.startsWith("denied_commands:")) {
        inAllowedCommands = false;
        inDeniedCommands = true;
        inRequireApproval = false;
      } else if (trimmed.startsWith("require_approval:")) {
        inAllowedCommands = false;
        inDeniedCommands = false;
        inRequireApproval = true;
      } else if (trimmed.startsWith("approval_mode:")) {
        const colonIdx = trimmed.indexOf(":");
        result.security.approval_mode = stripQuotes(trimmed.slice(colonIdx + 1).trim());
      } else if (trimmed.startsWith("allow_shell:")) {
        const colonIdx = trimmed.indexOf(":");
        const v = trimmed.slice(colonIdx + 1).trim();
        result.security.allow_shell = v !== "false";
      } else if (trimmed.startsWith("-")) {
        const v = stripQuotes(trimmed.slice(1).trim());
        if (inAllowedCommands) {
          result.security.allowed_commands.push(v);
        } else if (inDeniedCommands) {
          result.security.denied_commands.push(v);
        } else if (inRequireApproval) {
          result.security.require_approval.push(v);
        }
      }
    }
  }

  if (currentCustomProvider) result.custom_providers.push(currentCustomProvider);
  if (currentMcpServer) result.mcp_servers.push(currentMcpServer);

  return result;
}

export function stringifyConfigYaml(content, { model, custom_providers, disabled_tools, mcp_servers, security }) {
  const lines = content.split(/\r?\n/);
  const resultLines = [];
  let skipUntilUnindented = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    const indent = line.search(/\S/);

    if (indent === 0 && trimmed) {
      skipUntilUnindented = false;
      if (
        trimmed.startsWith("model:") ||
        trimmed.startsWith("custom_providers:") ||
        trimmed.startsWith("disabled_tools:") ||
        trimmed.startsWith("mcp_servers:") ||
        trimmed.startsWith("security:")
      ) {
        skipUntilUnindented = true;
        continue;
      }
    }

    if (skipUntilUnindented && indent > 0) {
      continue;
    }

    resultLines.push(line);
  }

  while (resultLines.length > 0 && resultLines[resultLines.length - 1].trim() === "") {
    resultLines.pop();
  }

  if (model) {
    resultLines.push("model:");
    resultLines.push(`  default: ${model.default || ""}`);
    resultLines.push(`  provider: ${model.provider || ""}`);
    if (model.base_url) {
      resultLines.push(`  base_url: ${model.base_url}`);
    }
    if (model.api_mode) {
      resultLines.push(`  api_mode: ${model.api_mode}`);
    }
    if (model.fallback_chain && model.fallback_chain.length > 0) {
      resultLines.push("  fallback_chain:");
      for (const fc of model.fallback_chain) {
        resultLines.push(`    - ${fc}`);
      }
    }
  }

  if (custom_providers && custom_providers.length > 0) {
    resultLines.push("custom_providers:");
    for (const cp of custom_providers) {
      resultLines.push(`  - name: ${cp.name}`);
      if (cp.base_url) resultLines.push(`    base_url: ${cp.base_url}`);
      if (cp.model) resultLines.push(`    model: ${cp.model}`);
      if (cp.api_mode) resultLines.push(`    api_mode: ${cp.api_mode}`);
      if (cp.key_env) resultLines.push(`    key_env: ${cp.key_env}`);
    }
  }

  if (disabled_tools && disabled_tools.length > 0) {
    resultLines.push("disabled_tools:");
    for (const dt of disabled_tools) {
      resultLines.push(`  - ${dt}`);
    }
  }

  if (mcp_servers && mcp_servers.length > 0) {
    resultLines.push("mcp_servers:");
    for (const mcp of mcp_servers) {
      resultLines.push(`  - name: ${mcp.name}`);
      if (mcp.transport && mcp.transport !== "stdio") resultLines.push(`    transport: ${mcp.transport}`);
      if (mcp.command) resultLines.push(`    command: ${mcp.command}`);
      if (mcp.url) resultLines.push(`    url: ${mcp.url}`);
      if (mcp.credential_id) resultLines.push(`    credential_id: ${mcp.credential_id}`);
      if (mcp.enabled !== undefined) resultLines.push(`    enabled: ${mcp.enabled}`);
      if (mcp.scopePath || mcp.scope_path) resultLines.push(`    scope_path: ${mcp.scopePath || mcp.scope_path}`);
      if (mcp.env && Object.keys(mcp.env).length > 0) {
        resultLines.push("    env:");
        for (const [key, value] of Object.entries(mcp.env)) {
          if (key && value !== undefined && value !== null && String(value).trim()) {
            resultLines.push(`      ${key}: "${escapeYamlString(String(value))}"`);
          }
        }
      }
      if (mcp.args && mcp.args.length > 0) {
        resultLines.push("    args:");
        for (const arg of mcp.args) {
          resultLines.push(`      - ${arg}`);
        }
      }
      if (mcp.surfaces && mcp.surfaces.length > 0) {
        resultLines.push("    surfaces:");
        for (const surface of mcp.surfaces) resultLines.push(`      - ${surface}`);
      }
    }
  }

  if (security) {
    resultLines.push("security:");
    resultLines.push(`  approval_mode: ${security.approval_mode || "suggest"}`);
    resultLines.push(`  allow_shell: ${security.allow_shell !== false}`);
    if (security.allowed_commands && security.allowed_commands.length > 0) {
      resultLines.push("  allowed_commands:");
      for (const cmd of security.allowed_commands) {
        resultLines.push(`    - ${cmd}`);
      }
    }
    if (security.denied_commands && security.denied_commands.length > 0) {
      resultLines.push("  denied_commands:");
      for (const cmd of security.denied_commands) {
        resultLines.push(`    - ${cmd}`);
      }
    }
    if (security.require_approval && security.require_approval.length > 0) {
      resultLines.push("  require_approval:");
      for (const req of security.require_approval) {
        resultLines.push(`    - ${req}`);
      }
    }
  }

  resultLines.push("");

  return resultLines.join("\n");
}

function escapeYamlString(value) {
  return String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function parseBooleanString(value, fallback = false) {
  const normalized = String(value || "").trim().toLowerCase();
  if (["true", "1", "yes", "on"].includes(normalized)) return true;
  if (["false", "0", "no", "off"].includes(normalized)) return false;
  return fallback;
}

function stripQuotes(str) {
  if ((str.startsWith('"') && str.endsWith('"')) || (str.startsWith("'") && str.endsWith("'"))) {
    return str.slice(1, -1);
  }
  return str;
}
