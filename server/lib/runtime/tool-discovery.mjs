import { listRuntimeToolProviders } from "./plugin-runtime.mjs";

export const TOOL_DISCOVERY_DEFINITION = {
  type: "function",
  function: {
    name: "tool_discovery",
    description: "Explore the hierarchical Codmes tool catalog. On a named Surface route, its exact current route path may be selected directly. Otherwise start without path and select one returned group at a time. Tools are enabled only after selecting a leaf group.",
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        reason: { type: "string", description: "Why external data or another capability is needed." },
        desiredCapability: { type: "string", description: "The user's concrete goal, such as 'read cumulative grades' or 'search PDF notes'." },
        path: { type: "string", description: "A group path returned by an earlier discovery call, for example 'knu' or 'knu.portal'. Omit to list top-level groups." }
      },
      required: ["reason", "desiredCapability"]
    }
  }
};

const GROUP_DESCRIPTIONS = {
  notes: "Search, read, and work with notes, documents, PDFs, and workspace files.",
  "notes.search": "Search indexed notes, documents, and PDFs.",
  "notes.read": "Read note files and document metadata.",
  code: "Inspect, edit, test, and manage source code.",
  "code.edit": "Search, read, and edit source code files.",
  "code.git": "Inspect Git state and run Git operations.",
  "code.checks": "Run builds, tests, and verification checks.",
  planner: "Work with schedules, tasks, calendars, and memos.",
  "planner.tasks": "Read and manage Planner tasks.",
  "planner.calendar": "Read and manage Planner calendar events.",
  "planner.memos": "Read and manage Planner memos.",
};

export const TOOL_REGISTRY = [
  tool("workspace_search", "Search workspace text and file contents.", "notes.search", ["notes"]),
  tool("codmes_search", "Search indexed notes, documents, PDFs, code, and conversation text through Codmes built-in search.", "notes.search", ["notes"]),
  tool("read_note_file", "Read the content of notes or document files.", "notes.read", ["notes"]),
  tool("read_file_metadata", "Get metadata for note files.", "notes.read", ["notes"]),
  tool("search_project", "Search source files and directories in code projects.", "code.edit", ["code"]),
  tool("read_project_file", "Read code project source files.", "code.edit", ["code"]),
  tool("propose_patch", "Propose modifications or edits to project code files.", "code.edit", ["code"]),
  tool("apply_patch", "Apply a proposed patch to project files.", "code.edit", ["code"], true),
  tool("inspect_git", "Inspect the current Git repository status.", "code.git", ["code"]),
  tool("get_git_diff", "View Git diffs for current changes or commits.", "code.git", ["code"]),
  tool("run_git_command", "Run safe or arbitrary Git commands.", "code.git", ["code"], true),
  tool("run_checks", "Run automated tests, builds, and linting checks.", "code.checks", ["code"], true)
];

export async function executeToolDiscovery(workspaceRoot, surface, args = {}, options = {}) {
  const desiredCapability = String(args.desiredCapability || "").trim().toLowerCase();
  const selectedPath = normalizePath(args.path);
  const allowedPaths = Array.isArray(options.allowedPaths)
    ? new Set(options.allowedPaths.map(normalizePath))
    : null;
  const disabledTools = new Set((options.disabledTools || []).map(String));
  const availableTools = await discoveryTools(workspaceRoot, options.runtimeTools);
  const catalog = buildCatalog(availableTools);
  const groupDescriptions = collectGroupDescriptions(availableTools);

  if (selectedPath && allowedPaths && !allowedPaths.has(selectedPath)) {
    const revealedParent = [...allowedPaths]
      .filter((path) => !path || selectedPath.startsWith(`${path}.`))
      .sort((left, right) => right.split(".").length - left.split(".").length)[0] || "";
    const revealedChildren = directChildren(catalog, revealedParent)
      .map((path) => groupSummary(path, groupDescriptions));
    const nextSuggestedPath = revealedChildren.find((item) =>
      selectedPath === item.path || selectedPath.startsWith(`${item.path}.`)
    )?.path || null;
    return {
      ...discoveryResult({ args, surface, path: revealedParent, children: revealedChildren, tools: [], expanded: [], blocked: [], leaf: false }),
      requestedPathDeferred: selectedPath,
      nextSuggestedPath,
      reason: `Requested group '${selectedPath}' is deeper than the revealed catalog. Returned the next safe level only.`
    };
  }
  const children = directChildren(catalog, selectedPath)
    .map((path) => groupSummary(path, groupDescriptions));

  if (!selectedPath || children.length) {
    const routeGroup = normalizePath(options.route) === "settings" ? "account" : normalizePath(options.route);
    const preferredPath = !selectedPath
      ? normalizePath(surface)
      : selectedPath === normalizePath(surface) && routeGroup
        ? `${selectedPath}.${routeGroup}`
        : "";
    const nextSuggestedPath = children.some((item) => item.path === preferredPath) ? preferredPath : null;
    return {
      ...discoveryResult({ args, surface, path: selectedPath, children, tools: [], expanded: [], blocked: [], leaf: false }),
      nextSuggestedPath
    };
  }

  const toolsInLeaf = availableTools.filter((item) => canonicalGroupPath(item) === selectedPath);
  const matched = rankTools(toolsInLeaf, desiredCapability).slice(0, 8);
  const blocked = matched
    .filter((item) => disabledTools.has(item.name))
    .map((item) => ({
      name: item.name,
      reason: "disabled_by_surface_mode"
    }));
  const blockedNames = new Set(blocked.map((item) => item.name));
  const expanded = matched.filter((item) => !blockedNames.has(item.name)).map((item) => item.name);

  return discoveryResult({
    args,
    surface,
    path: selectedPath,
    children: [],
    tools: matched.map((item) => ({
      name: item.name,
      description: item.description,
      disabledByUser: disabledTools.has(item.name),
      requiresApproval: Boolean(item.requiresApproval),
      provider: item.provider || "native",
      pluginId: item.pluginId || null
    })),
    expanded,
    blocked,
    leaf: true
  });
}

export async function toolCatalogPromptLines(workspaceRoot, { surface = "chat", route = "" } = {}) {
  const lines = [
    "Tool schemas are hidden behind a hierarchical catalog. On the displayed Current Surface route, you may select that exact route path directly. For other capabilities, start tool_discovery without path and choose one returned group at a time."
  ];
  const normalizedSurface = normalizePath(surface);
  const normalizedRoute = normalizePath(route);
  if (normalizedSurface && normalizedSurface !== "chat") {
    lines.push(`Current Surface: ${normalizedSurface}${normalizedRoute ? ` > ${normalizedRoute}` : ""}.`);
  }
  lines.push(
    "For factual work, external services, user-specific data, or current state without fresh evidence, call tool_discovery before answering.",
    "Outside the displayed Current Surface route, explore one returned group path at a time. Never skip a level or repeat the same level. When nextSuggestedPath fits the request, use it. A leaf discovery enables only its relevant tools for this turn."
  );
  return lines;
}

async function discoveryTools(workspaceRoot, runtimeTools = []) {
  const providers = await listRuntimeToolProviders(workspaceRoot);
  const pluginTools = providers.flatMap((plugin) =>
    (plugin.tools || []).map((item) => ({
      name: item.name,
      description: item.description,
      group: item.group || `plugin.${plugin.id}`,
      surfaces: item.surfaces || plugin.views.map((view) => view.id),
      requiresApproval: item.requiresApproval === true,
      provider: item.provider.type,
      pluginId: plugin.id,
      groupDescriptions: item.groupDescriptions || {}
    }))
  );
  const discovered = new Map([...TOOL_REGISTRY, ...pluginTools].map((item) => [item.name, item]));
  for (const item of Array.isArray(runtimeTools) ? runtimeTools : []) {
    if (!item?.name || item?.provider?.type !== "mcp") continue;
    discovered.set(item.name, {
      ...item,
      provider: "mcp",
      groupDescriptions: item.groupDescriptions || {}
    });
  }
  return [...discovered.values()];
}

function buildCatalog(tools) {
  const paths = new Set();
  for (const item of tools) {
    const parts = canonicalGroupPath(item).split(".").filter(Boolean);
    for (let index = 1; index <= parts.length; index += 1) paths.add(parts.slice(0, index).join("."));
  }
  return paths;
}

function directChildren(catalog, parent) {
  const depth = parent ? parent.split(".").length + 1 : 1;
  const prefix = parent ? `${parent}.` : "";
  return [...catalog]
    .filter((path) => path.startsWith(prefix) && path.split(".").length === depth)
    .sort();
}

function collectGroupDescriptions(tools) {
  const descriptions = { ...GROUP_DESCRIPTIONS };
  for (const item of tools) Object.assign(descriptions, item.groupDescriptions || {});
  return descriptions;
}

function groupSummary(path, descriptions) {
  return { path, description: descriptions[path] || `${path} tool group.` };
}

function rankTools(tools, query) {
  if (!query) return [...tools].sort((a, b) => a.name.localeCompare(b.name));
  const words = query.split(/[^a-zA-Z0-9가-힣_/-]+/).filter((word) => word.length >= 2);
  const scored = tools.map((item) => {
    const haystack = `${item.name} ${item.description} ${item.group}`.toLowerCase();
    const score = words.reduce((sum, word) => sum + (haystack.includes(word) ? 1 : 0), 0);
    return { item, score };
  });
  const positive = scored.filter(({ score }) => score > 0);
  return (positive.length ? positive : scored)
    .sort((left, right) => right.score - left.score || left.item.name.localeCompare(right.item.name))
    .map(({ item }) => item);
}

function discoveryResult({ args, surface, path, children, tools, expanded, blocked, leaf }) {
  const group = path || "root";
  return {
    taskId: args.taskId || null,
    surface,
    path,
    leaf,
    groups: children,
    tools,
    expandedToolsForThisTurn: expanded,
    blockedTools: blocked,
    reason: leaf ? `Selected leaf tool group '${group}' for '${args.desiredCapability || ""}'.` : `Choose one child group under '${group}'.`,
    availableToolGroups: children.map((item) => ({ group: item.path, description: item.description, tools: [] })),
    recommendation: {
      enableForThisTurn: expanded,
      reason: leaf ? `Enabled tools from '${group}'.` : `Select a child group under '${group}'.`
    }
  };
}

function canonicalGroupPath(item) {
  const raw = normalizePath(item.group);
  if (raw.includes(".")) return raw;
  const surface = normalizePath(item.surfaces?.[0]);
  if (surface && surface !== "chat") return `${surface}.${raw}`;
  return raw;
}

function normalizePath(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[:/]+/g, ".")
    .replace(/[^a-z0-9_.-]+/g, "-")
    .replace(/\.+/g, ".")
    .replace(/^\.|\.$/g, "");
}

function tool(name, description, group, surfaces, requiresApproval = false) {
  return { name, description, group, surfaces, requiresApproval };
}
