import fs from "node:fs/promises";
import path from "node:path";
import { runtimeConfigDir } from "./config-store.mjs";
import { parseConfigYaml, stringifyConfigYaml } from "./yaml-utils.mjs";
import { appendAuditEvent } from "./audit-log.mjs";

export async function readSecurityConfig(workspaceRoot) {
  const dir = runtimeConfigDir(workspaceRoot);
  const filePath = path.join(dir, "config.yaml");
  const isTest = process.env.NODE_ENV === "test";
  try {
    const content = await fs.readFile(filePath, "utf8");
    const parsed = parseConfigYaml(content);
    const sec = parsed.security || {};
    return {
      approvalMode: sec.approval_mode || (isTest ? "auto" : "suggest"),
      allowShell: sec.allow_shell !== false,
      allowedCommands: sec.allowed_commands || [],
      deniedCommands: sec.denied_commands || [],
      requireApproval: sec.require_approval || []
    };
  } catch {
    return {
      approvalMode: isTest ? "auto" : "suggest",
      allowShell: true,
      allowedCommands: [],
      deniedCommands: [],
      requireApproval: []
    };
  }
}

export async function writeSecurityConfig(workspaceRoot, securityConfig) {
  const dir = runtimeConfigDir(workspaceRoot);
  await fs.mkdir(dir, { recursive: true });
  const filePath = path.join(dir, "config.yaml");
  let content = "";
  try {
    content = await fs.readFile(filePath, "utf8");
  } catch {}

  const parsed = parseConfigYaml(content);
  parsed.security = {
    approval_mode: securityConfig.approvalMode,
    allow_shell: securityConfig.allowShell,
    allowed_commands: securityConfig.allowedCommands,
    denied_commands: securityConfig.deniedCommands,
    require_approval: securityConfig.requireApproval
  };

  const updatedContent = stringifyConfigYaml(content, parsed);
  await fs.writeFile(filePath, updatedContent, "utf8");
}

export async function checkAction(workspaceRoot, action) {
  const config = await readSecurityConfig(workspaceRoot);
  const decision = await evaluateSecurityAction(workspaceRoot, action, config);
  await auditSecurityDecision(workspaceRoot, action, decision);
  return decision;
}

async function evaluateSecurityAction(workspaceRoot, action, config) {
  // 1. Path Traversal & Workspace Boundaries
  if (action.path) {
    const absolutePath = path.resolve(workspaceRoot, action.path);
    const relative = path.relative(workspaceRoot, absolutePath);
    const isOutside = relative.startsWith("..") || path.isAbsolute(relative);
    if (isOutside) {
      return {
        status: "deny",
        reason: `Access denied: path '${action.path}' is outside the workspace root.`
      };
    }
  }

  // 2. Denied Commands Check (substring search for safety)
  if (action.command) {
    const cmdLower = action.command.toLowerCase();
    for (const denied of config.deniedCommands || []) {
      if (cmdLower.includes(denied.toLowerCase())) {
        return {
          status: "deny",
          reason: `Command blocked: command matches denied pattern '${denied}'.`
        };
      }
    }
  }

  // 3. Allowed Commands Check (prefix/exact match)
  if (action.command) {
    const cmdLower = action.command.toLowerCase().trim();
    const isAllowed = (config.allowedCommands || []).some((allowed) => {
      const allowedLower = allowed.toLowerCase().trim();
      return cmdLower === allowedLower || cmdLower.startsWith(allowedLower + " ");
    });
    if (isAllowed) {
      return { status: "allow", reason: "Command is explicitly allowed by security policy." };
    }
  }

  // 4. Shell Execution Block
  if (action.type === "shell.run") {
    if (config.allowShell === false) {
      return {
        status: "deny",
        reason: "Shell command execution is disabled by security policy."
      };
    }
  }

  // 5. Dangerous Shell Syntax Check
  if (action.type === "shell.run" && action.command) {
    const dangerousSyntax = detectDangerousShellSyntax(action.command);
    if (dangerousSyntax) {
      return {
        status: "approve",
        reason: `Shell command uses risky syntax: ${dangerousSyntax}.`
      };
    }
  }

  // 6. Require Approval Check
  let requireApproval = false;
  if (config.requireApproval.includes(action.type)) {
    requireApproval = true;
  } else if (action.type === "git.command" && action.command) {
    const cmd = action.command.toLowerCase();
    if (cmd.includes("push") && config.requireApproval.includes("git.push")) {
      requireApproval = true;
    } else if (cmd.includes("commit") && config.requireApproval.includes("git.commit")) {
      requireApproval = true;
    }
  }

  if (requireApproval) {
    return {
      status: "approve",
      reason: `Approval required for action category '${action.type}'`
    };
  }

  // 7. Approval Mode Evaluator
  switch (config.approvalMode) {
    case "auto":
      return { status: "allow", reason: "Approval mode is set to auto." };
    case "manual":
      return { status: "approve", reason: "Policy requires manual approval for all actions." };
    case "off":
      return { status: "deny", reason: "All write and execution actions are blocked (approval_mode is off)." };
    case "suggest":
    default:
      // Suggest mode: require approval for modifications/runs, allow reads
      if (
        action.type === "file.write" ||
        action.type === "file.delete" ||
        action.type === "git.command" ||
        action.type === "shell.run" ||
        (action.type === "mcp.tool.call" && action.dangerous === true)
      ) {
        return {
          status: "approve",
          reason: `Action '${action.type}' requires confirmation in suggest mode.`
        };
      }
      return { status: "allow" };
  }
}

function detectDangerousShellSyntax(command) {
  const text = String(command || "");
  const compact = text.replace(/\s+/g, " ").trim().toLowerCase();
  const checks = [
    ["curl | sh", /\bcurl\b[\s\S]*\|[\s\S]*(\bsh\b|\bbash\b)/i],
    ["wget | sh", /\bwget\b[\s\S]*\|[\s\S]*(\bsh\b|\bbash\b)/i],
    ["rm -rf", /\brm\s+(-[a-z]*r[a-z]*f|-{1,2}recursive\b[\s\S]*-{1,2}force\b)/i],
    ["sudo", /\bsudo\b/i],
    ["subshell", /\$\([^)]*\)/],
    ["backtick", /`[^`]*`/],
    ["and/or chain", /&&|\|\|/],
    ["semicolon chain", /;/],
    ["pipe", /\|/],
    ["redirection", /(^|[^<])>{1,2}([^>]|$)|</],
    ["chmod + execute", /\bchmod\s+\+x\b[\s\S]*(&&|;|\|\|)/i]
  ];
  for (const [label, pattern] of checks) {
    if (pattern.test(text) || pattern.test(compact)) return label;
  }
  return "";
}

async function auditSecurityDecision(workspaceRoot, action, decision) {
  if (!shouldAuditAction(action, decision)) return;
  try {
    await appendAuditEvent(workspaceRoot, {
      actionType: action.type || "unknown",
      status: decision.status === "approve" ? "approval_required" : decision.status,
      reason: decision.reason || "",
      sessionId: action.sessionId || "",
      taskId: action.taskId || "",
      command: action.command || "",
      path: action.path || "",
      serverName: action.serverName || "",
      toolName: action.toolName || ""
    });
  } catch {
    // Audit logging must not make the policy evaluator fail closed by accident.
  }
}

function shouldAuditAction(action, decision) {
  if (decision.status === "deny" || decision.status === "approve") return true;
  return [
    "file.write",
    "file.delete",
    "file.move",
    "git.command",
    "shell.run",
    "mcp.tool.call",
    "code.patch.apply"
  ].includes(action.type);
}
