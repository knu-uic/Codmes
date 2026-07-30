import fs from "node:fs/promises";
import path from "node:path";

export const DEFAULT_TOOL_MODES = {
  chat: {
    mode: "default",
    enabledTools: [
      "conversation_search",
      "memory_search",
      "tool_discovery",
      "conversation_read"
    ]
  },
  notes: {
    mode: "default",
    enabledTools: [
      "workspace_search",
      "codmes_search",
      "read_note_file",
      "read_file_metadata",
      "conversation_search",
      "memory_search",
      "tool_discovery",
      "conversation_read"
    ]
  },
  code: {
    mode: "default",
    enabledTools: [
      "search_project",
      "read_project_file",
      "inspect_git",
      "get_git_diff",
      "propose_patch",
      "apply_patch",
      "run_checks",
      "run_git_command",
      "conversation_search",
      "memory_search",
      "tool_discovery",
      "conversation_read"
    ],
    requiresApproval: [
      "apply_patch",
      "run_checks",
      "run_git_command"
    ]
  },
  planner: {
    mode: "default",
    enabledTools: [
      "planner_list",
      "planner_get",
      "planner_create",
      "planner_update",
      "planner_delete",
      "calendar_list",
      "calendar_get",
      "calendar_create",
      "calendar_update",
      "calendar_delete",
      "memo_list",
      "memo_get",
      "memo_create",
      "memo_update",
      "memo_delete",
      "conversation_search",
      "memory_search",
      "tool_discovery",
      "conversation_read"
    ],
    requiresApproval: [
      "planner_create",
      "planner_update",
      "planner_delete",
      "calendar_create",
      "calendar_update",
      "calendar_delete",
      "memo_create",
      "memo_update",
      "memo_delete"
    ]
  }
};

export const CORE_RECALL_TOOLS = [
  "tool_discovery",
  "conversation_search",
  "conversation_read",
  "memory_search"
];

// Safe defaults for code
export const SAFE_TOOL_MODES = {
  code: {
    mode: "safe",
    enabledTools: [
      "search_project",
      "read_project_file",
      "inspect_git",
      "get_git_diff",
      "propose_patch",
      "conversation_search",
      "memory_search",
      "tool_discovery",
      "conversation_read"
    ],
    requiresApproval: [
      "apply_patch",
      "run_checks",
      "run_git_command"
    ]
  }
};

export async function ensureToolModesDir(workspaceRoot) {
  const dir = path.join(workspaceRoot, ".codmes", "tool-modes");
  await fs.mkdir(dir, { recursive: true });
  return dir;
}

export async function loadToolModes(workspaceRoot) {
  const dir = await ensureToolModesDir(workspaceRoot);
  const overridesPath = path.join(dir, "user-overrides.json");
  
  let overrides = {};
  try {
    const data = await fs.readFile(overridesPath, "utf8");
    overrides = JSON.parse(data);
  } catch {}

  const merged = {};
  const surfaceIds = Array.from(new Set([
    ...Object.keys(DEFAULT_TOOL_MODES),
    ...Object.keys(overrides)
  ]));
  for (const surface of surfaceIds) {
    const defaultVal = DEFAULT_TOOL_MODES[surface] || {
      mode: "custom",
      enabledTools: [...CORE_RECALL_TOOLS],
      requiresApproval: []
    };
    const overrideVal = overrides[surface] || {};
    
    // Merge logic
    const mode = overrideVal.mode || defaultVal.mode;
    let enabledTools = [...defaultVal.enabledTools];
    let requiresApproval = [...(defaultVal.requiresApproval || [])];
    
    if (mode === "custom") {
      if (Array.isArray(overrideVal.enabledTools)) {
        enabledTools = [...overrideVal.enabledTools];
      }
      if (Array.isArray(overrideVal.disabledTools)) {
        const disabledSet = new Set(overrideVal.disabledTools);
        enabledTools = enabledTools.filter(t => !disabledSet.has(t));
      }
    } else if (mode === "safe" && SAFE_TOOL_MODES[surface]) {
      enabledTools = [...SAFE_TOOL_MODES[surface].enabledTools];
      requiresApproval = [...(SAFE_TOOL_MODES[surface].requiresApproval || [])];
    }
    
    if (overrideVal.requiresApproval) {
      requiresApproval = Array.from(new Set([...requiresApproval, ...overrideVal.requiresApproval]));
    }

    // Core recall tools are always available in each surface mode. The global
    // runtime disabledTools config is still allowed to block them later.
    for (const m of CORE_RECALL_TOOLS) {
      if (!enabledTools.includes(m)) {
        enabledTools.push(m);
      }
    }

    merged[surface] = {
      surface,
      mode,
      enabledTools,
      disabledTools: overrideVal.disabledTools || [],
      requiresApproval
    };
  }
  return merged;
}

export async function saveToolModeOverride(workspaceRoot, surface, config) {
  const dir = await ensureToolModesDir(workspaceRoot);
  const overridesPath = path.join(dir, "user-overrides.json");
  
  let overrides = {};
  try {
    const data = await fs.readFile(overridesPath, "utf8");
    overrides = JSON.parse(data);
  } catch {}
  
  overrides[surface] = config;
  await fs.writeFile(overridesPath, JSON.stringify(overrides, null, 2), "utf8");
  return overrides[surface];
}

export async function getEffectiveToolMode(workspaceRoot, surface) {
  const modes = await loadToolModes(workspaceRoot);
  return modes[surface] || {
    surface,
    mode: "default",
    enabledTools: DEFAULT_TOOL_MODES[surface]?.enabledTools || [...CORE_RECALL_TOOLS],
    requiresApproval: []
  };
}
