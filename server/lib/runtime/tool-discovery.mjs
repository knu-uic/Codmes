import { listInstalledPlugins } from "./plugin-registry.mjs";

export const TOOL_DISCOVERY_DEFINITION = {
  type: "function",
  function: {
    name: "tool_discovery",
    description: "Discover tools and capabilities that are not currently available or enabled in the current surface/mode.",
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        reason: {
          type: "string",
          description: "The reason why you are searching for additional tools."
        },
        desiredCapability: {
          type: "string",
          description: "The description of the capability you need (e.g. 'read files', 'git operations', 'search notes')."
        }
      },
      required: ["reason", "desiredCapability"]
    }
  }
};

export const TOOL_REGISTRY = [
  {
    name: "workspace_search",
    description: "Search workspace text and file contents.",
    group: "notes_search",
    surfaces: ["notes"]
  },
  {
    name: "codmes_search",
    description: "Search indexed notes, documents, PDFs, code, and conversation text through Codmes built-in search.",
    group: "notes_search",
    surfaces: ["notes"]
  },
  {
    name: "read_note_file",
    description: "Read the content of notes or document files.",
    group: "notes_read",
    surfaces: ["notes"]
  },
  {
    name: "read_file_metadata",
    description: "Get metadata for note files.",
    group: "notes_read",
    surfaces: ["notes"]
  },
  {
    name: "search_project",
    description: "Search source files and directories in code projects.",
    group: "code_tools",
    surfaces: ["code"]
  },
  {
    name: "read_project_file",
    description: "Read code project source files.",
    group: "code_tools",
    surfaces: ["code"]
  },
  {
    name: "propose_patch",
    description: "Propose modifications or edits to project code files.",
    group: "code_tools",
    surfaces: ["code"]
  },
  {
    name: "apply_patch",
    description: "Apply a proposed patch to project files.",
    group: "code_tools",
    surfaces: ["code"],
    requiresApproval: true
  },
  {
    name: "inspect_git",
    description: "Inspect the current git repository status.",
    group: "git_tools",
    surfaces: ["code"]
  },
  {
    name: "get_git_diff",
    description: "View git diff for the current changes or commits.",
    group: "git_tools",
    surfaces: ["code"]
  },
  {
    name: "run_git_command",
    description: "Run safe or arbitrary git commands.",
    group: "git_tools",
    surfaces: ["code"],
    requiresApproval: true
  },
  {
    name: "run_checks",
    description: "Run automated tests, builds, and linting checks.",
    group: "checks_tools",
    surfaces: ["code"],
    requiresApproval: true
  }
];

export async function executeToolDiscovery(workspaceRoot, surface, args = {}, options = {}) {
  const desiredCapability = String(args.desiredCapability || "").toLowerCase();
  const disabledTools = new Set((options.disabledTools || []).map(String));
  const pluginTools = (await listInstalledPlugins(workspaceRoot)).flatMap((plugin) =>
    (plugin.tools || []).map((tool) => ({
      name: tool.name,
      description: tool.description,
      group: tool.group || `plugin:${plugin.id}`,
      surfaces: tool.surfaces || [plugin.surface.id],
      requiresApproval: tool.requiresApproval === true,
      provider: tool.provider.type,
      pluginId: plugin.id
    }))
  );
  const availableTools = [...TOOL_REGISTRY, ...pluginTools];
  const queryWords = desiredCapability
    .split(/[^a-zA-Z0-9가-힣_/-]+/)
    .map((word) => word.trim())
    .filter((word) => word.length >= 2);
  
  // Find matching tool groups based on desiredCapability keywords or description match
  const matchedTools = availableTools.filter(tool => {
    if (queryWords.length === 0) return false;
    return queryWords.some(word => {
      const inName = tool.name.toLowerCase().includes(word);
      const inDesc = tool.description.toLowerCase().includes(word);
      const inGroup = tool.group.toLowerCase().includes(word);
      return inName || inDesc || inGroup;
    });
  });

  // Group matched tools
  const groupsMap = new Map();
  for (const tool of matchedTools) {
    if (!groupsMap.has(tool.group)) {
      groupsMap.set(tool.group, {
        group: tool.group,
        tools: [],
        requiresUserEnabled: false,
        requiresApproval: false
      });
    }
    const g = groupsMap.get(tool.group);
    g.tools.push({
      name: tool.name,
      description: tool.description,
      disabledByUser: disabledTools.has(tool.name),
      requiresApproval: Boolean(tool.requiresApproval),
      provider: tool.provider || "native",
      pluginId: tool.pluginId || null
    });
    if (tool.requiresApproval) {
      g.requiresApproval = true;
    }
  }

  const availableToolGroups = Array.from(groupsMap.values());
  const blockedTools = matchedTools
    .filter((tool) => disabledTools.has(tool.name) || tool.requiresApproval)
    .map((tool) => ({
      name: tool.name,
      reason: disabledTools.has(tool.name)
        ? "disabled_by_surface_mode"
        : "requires_approval_or_dangerous"
    }));

  const recommendTools = matchedTools
    .filter(t => !t.requiresApproval && !disabledTools.has(t.name)) // Recommend safe enabled tools first
    .map(t => t.name)
    .slice(0, 3);

  return {
    taskId: args.taskId || null,
    expandedToolsForThisTurn: recommendTools,
    blockedTools,
    reason: `Found tools matching your request for '${desiredCapability}'`,
    availableToolGroups,
    recommendation: {
      enableForThisTurn: recommendTools,
      reason: `Found tools matching your request for '${desiredCapability}'`
    }
  };
}
