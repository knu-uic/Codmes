import fs from "node:fs/promises";
import path from "node:path";
import { fileKind, resolveWorkspacePath } from "../path-utils.mjs";
import { readFileMetadata } from "../file-index.mjs";
import { searchWorkspace } from "../search-service.mjs";
import { extractAndCacheDocument, isDocumentIngestFile } from "../document-ingest.mjs";

const MAX_READ_CHARS = 60000;
const MAX_TREE_ENTRIES = 200;

export const WORKSPACE_TOOL_DEFINITIONS = [
  {
    type: "function",
    function: {
      name: "workspace_search",
      description: "Search text files in Codmes. Use this when the user asks about notes, code, or documents that are not already in context.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          query: {
            type: "string",
            description: "Text to search for."
          },
          scopePath: {
            type: "string",
            description: "Optional workspace-relative folder/file path to limit search."
          },
          maxResults: {
            type: "integer",
            minimum: 1,
            maximum: 20,
            description: "Maximum search results to return."
          }
        },
        required: ["query"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "codmes_search",
      description: "Search indexed notes, documents, PDFs, code, and conversation text through Codmes built-in search. Use this for broad workspace/RAG questions.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          query: { type: "string", description: "Text to search for." },
          scopePath: { type: "string", description: "Optional workspace-relative folder/file path to limit search." },
          maxResults: { type: "integer", minimum: 1, maximum: 20 }
        },
        required: ["query"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "workspace_read_file",
      description: "Read a text/markdown/code file by workspace-relative path.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          path: {
            type: "string",
            description: "Workspace-relative file path."
          },
          maxChars: {
            type: "integer",
            minimum: 1000,
            maximum: 100000,
            description: "Maximum characters to return."
          }
        },
        required: ["path"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "read_note_file",
      description: "Read a note, markdown, document text, or small workspace file by workspace-relative path.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          path: { type: "string", description: "Workspace-relative file path." },
          maxChars: { type: "integer", minimum: 1000, maximum: 100000 }
        },
        required: ["path"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "read_file_metadata",
      description: "Read server-side metadata for a workspace file, including kind, size, hash, and PDF metadata when available.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          path: { type: "string", description: "Workspace-relative file path." }
        },
        required: ["path"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "workspace_list_tree",
      description: "List files and folders under a workspace-relative path.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          path: {
            type: "string",
            description: "Workspace-relative folder path. Empty means workspace root."
          },
          depth: {
            type: "integer",
            minimum: 1,
            maximum: 4,
            description: "How many directory levels to list."
          },
          maxEntries: {
            type: "integer",
            minimum: 1,
            maximum: 200,
            description: "Maximum entries to return."
          }
        }
      }
    }
  },
  {
    type: "function",
    function: {
      name: "search_project",
      description: "Search source files in a Code project using the native CodeAgentRuntime project search flow.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          query: { type: "string", description: "Search query or instruction." },
          scopePath: { type: "string", description: "Code workspace path. Defaults to Code." },
          maxResults: { type: "integer", minimum: 1, maximum: 20 }
        },
        required: ["query"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "read_project_file",
      description: "Read a source file under the Code workspace root.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          path: { type: "string", description: "Code workspace-relative file path." },
          maxChars: { type: "integer", minimum: 1000, maximum: 100000 }
        },
        required: ["path"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "inspect_git",
      description: "Inspect git status and diff summary for a Code project.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          scopePath: { type: "string", description: "Code workspace path. Defaults to Code." }
        }
      }
    }
  },
  {
    type: "function",
    function: {
      name: "get_git_diff",
      description: "Read current git diff for a Code project or a stored task diff reference.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          scopePath: { type: "string", description: "Code workspace path. Defaults to Code." },
          taskId: { type: "string", description: "Optional code task id whose stored diffRef should be read." }
        }
      }
    }
  },
  {
    type: "function",
    function: {
      name: "propose_patch",
      description: "Create a CodeAgentRuntime patch proposal for an existing code task. The proposal creates an approval item instead of directly mutating files.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          taskId: { type: "string" },
          summary: { type: "string" },
          changes: {
            type: "array",
            items: {
              type: "object",
              additionalProperties: true
            }
          }
        },
        required: ["changes"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "apply_patch",
      description: "Apply an approved CodeAgentRuntime patch proposal.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          taskId: { type: "string" },
          proposalId: { type: "string" },
          runChecksAfterApply: { type: "boolean" }
        },
        required: ["proposalId"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "run_checks",
      description: "Run approved checks for an existing code task.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          taskId: { type: "string" },
          commands: { type: "array", items: { type: "string" } }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "run_git_command",
      description: "Run an approved git command for an existing code task.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          taskId: { type: "string" },
          command: { type: "string" },
          gitPushApproved: { type: "boolean" },
          dangerApproved: { type: "boolean" }
        },
        required: ["command"]
      }
    }
  }
];

export async function executeWorkspaceTool(workspaceRoot, toolName, rawArgs = {}, options = {}) {
  const args = typeof rawArgs === "string" ? parseToolArgs(rawArgs) : rawArgs;
  if (toolName === "workspace_search" || toolName === "codmes_search") {
    return await searchWorkspace(workspaceRoot, {
      workspaceId: options.workspaceId || null,
      query: args.query,
      scopePath: args.scopePath || "",
      maxResults: clampNumber(args.maxResults, 1, 20, 8)
    });
  }
  if (toolName === "workspace_read_file" || toolName === "read_note_file") {
    return await readWorkspaceFile(workspaceRoot, args);
  }
  if (toolName === "read_file_metadata") {
    return await readFileMetadata(workspaceRoot, args.path || "");
  }
  if (toolName === "workspace_list_tree") {
    return await listWorkspaceTree(workspaceRoot, args);
  }
  if (isCodeSurfaceTool(toolName)) {
    return await executeCodeSurfaceTool(workspaceRoot, toolName, args, options);
  }
  throw Object.assign(new Error(`Unknown workspace tool: ${toolName}`), { status: 400 });
}

export function workspaceToolNames() {
  return WORKSPACE_TOOL_DEFINITIONS.map((tool) => tool.function.name);
}

async function readWorkspaceFile(workspaceRoot, args) {
  const resolved = resolveWorkspacePath(workspaceRoot, args.path || "");
  if (!resolved.relativePath) {
    throw Object.assign(new Error("workspace_read_file requires a file path."), { status: 400 });
  }
  const stat = await fs.stat(resolved.absolutePath);
  if (stat.isDirectory()) {
    throw Object.assign(new Error("workspace_read_file cannot read a folder."), { status: 400 });
  }
  const maxChars = clampNumber(args.maxChars, 1000, 100000, MAX_READ_CHARS);
  if (isDocumentIngestFile(resolved.relativePath)) {
    const document = await extractAndCacheDocument(
      workspaceRoot,
      resolved.absolutePath,
      resolved.relativePath,
      stat
    );
    const content = String(document.markdown || document.text || "");
    const relatedImages = [];
    const seen = new Set();
    for (const block of document.blocks || []) {
      for (const image of block.metadata?.related_images || block.related_images || []) {
        const key = String(image?.asset_id || image?.url || "");
        if (!key || seen.has(key)) continue;
        relatedImages.push(image);
        seen.add(key);
      }
    }
    return {
      path: resolved.relativePath,
      kind: fileKind(resolved.relativePath),
      size: stat.size,
      modifiedAt: stat.mtime.toISOString(),
      truncated: content.length > maxChars,
      content: truncateMiddle(content, maxChars),
      related_images: relatedImages
    };
  }
  const content = await fs.readFile(resolved.absolutePath, "utf8");
  return {
    path: resolved.relativePath,
    kind: fileKind(resolved.relativePath),
    size: stat.size,
    modifiedAt: stat.mtime.toISOString(),
    truncated: content.length > maxChars,
    content: truncateMiddle(content, maxChars)
  };
}

async function listWorkspaceTree(workspaceRoot, args) {
  const resolved = resolveWorkspacePath(workspaceRoot, args.path || "");
  const stat = await fs.stat(resolved.absolutePath);
  const maxEntries = clampNumber(args.maxEntries, 1, 200, MAX_TREE_ENTRIES);
  const depth = clampNumber(args.depth, 1, 4, 2);
  const entries = [];

  if (!stat.isDirectory()) {
    return {
      path: resolved.relativePath,
      entries: [{
        path: resolved.relativePath,
        name: path.basename(resolved.relativePath),
        kind: fileKind(resolved.relativePath),
        size: stat.size,
        modifiedAt: stat.mtime.toISOString()
      }]
    };
  }

  async function visit(directory, currentDepth) {
    if (entries.length >= maxEntries || currentDepth > depth) return;
    const dirEntries = await fs.readdir(directory, { withFileTypes: true });
    dirEntries.sort((a, b) => Number(b.isDirectory()) - Number(a.isDirectory()) || a.name.localeCompare(b.name));
    for (const entry of dirEntries) {
      if (entries.length >= maxEntries) return;
      if (entry.name === ".DS_Store" || entry.name === ".codmes" || entry.name === ".hermes-workspace") continue;
      const absolutePath = path.join(directory, entry.name);
      const rel = path.relative(workspaceRoot, absolutePath).replace(/\\/g, "/");
      const itemStat = await fs.stat(absolutePath);
      const kind = fileKind(rel, entry.isDirectory());
      entries.push({
        path: rel,
        name: entry.name,
        kind,
        size: itemStat.size,
        modifiedAt: itemStat.mtime.toISOString()
      });
      if (entry.isDirectory()) await visit(absolutePath, currentDepth + 1);
    }
  }

  await visit(resolved.absolutePath, 1);
  return {
    path: resolved.relativePath,
    depth,
    maxEntries,
    entryCount: entries.length,
    entries
  };
}

function parseToolArgs(value) {
  try {
    return JSON.parse(value || "{}");
  } catch {
    return {};
  }
}

function clampNumber(value, min, max, fallback) {
  const number = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(max, Math.max(min, number));
}

function truncateMiddle(value, maxChars) {
  const text = String(value || "");
  if (text.length <= maxChars) return text;
  const head = Math.ceil(maxChars * 0.7);
  const tail = Math.max(0, maxChars - head);
  return `${text.slice(0, head)}\n\n... [truncated] ...\n\n${text.slice(text.length - tail)}`;
}

function isCodeSurfaceTool(name) {
  return [
    "search_project",
    "read_project_file",
    "inspect_git",
    "get_git_diff",
    "propose_patch",
    "apply_patch",
    "run_checks",
    "run_git_command"
  ].includes(name);
}

async function executeCodeSurfaceTool(workspaceRoot, toolName, args, options = {}) {
  const codeRuntime = options.codeRuntime;
  if (!codeRuntime) {
    throw Object.assign(new Error(`Code surface tool '${toolName}' requires CodeAgentRuntime.`), { status: 501 });
  }
  if (toolName === "search_project") {
    const scope = codeRuntime.resolveCodeScope(args.scopePath || "Code");
    return await codeRuntime.searchProject(scope, args.query || args.instruction || "", {
      maxSearchResults: args.maxResults
    });
  }
  if (toolName === "read_project_file") {
    const file = await readWorkspaceFile(workspaceRoot, {
      path: args.path,
      maxChars: args.maxChars
    });
    const scopePath = normalizeScopePath(options.currentCodeScopePath || args.scopePath || "Code");
    if (!isPathInsideScope(file.path, scopePath)) {
      throw Object.assign(new Error(`read_project_file can only read files under the current code scope '${scopePath}'.`), { status: 400 });
    }
    return file;
  }
  if (toolName === "inspect_git") {
    const scope = codeRuntime.resolveCodeScope(args.scopePath || "Code");
    const git = await codeRuntime.inspectGit(scope.absolutePath);
    const { diff, ...summary } = git;
    return summary;
  }
  if (toolName === "get_git_diff") {
    const taskId = args.taskId || options.currentCodeTaskId;
    if (taskId && codeRuntime.state) {
      const task = await codeRuntime.state.readTask(taskId);
      const diffRef = task?.git?.diffRef || task?.patchProposals?.at?.(-1)?.diffRef || "";
      if (diffRef) {
        const diff = await readWorkspaceFile(workspaceRoot, { path: diffRef, maxChars: args.maxChars || 60000 });
        return { taskId, diffRef, diff: diff.content, truncated: diff.truncated };
      }
    }
    const scope = codeRuntime.resolveCodeScope(args.scopePath || "Code");
    const git = await codeRuntime.inspectGit(scope.absolutePath);
    return { scopePath: scope.relativePath, isRepository: git.isRepository, diff: truncateMiddle(git.diff || "", args.maxChars || 60000) };
  }
  if (toolName === "propose_patch") {
    return await codeRuntime.proposePatch(requireCurrentCodeTaskId(args, options), args);
  }
  if (toolName === "apply_patch") {
    return await codeRuntime.applyPatch(requireCurrentCodeTaskId(args, options), { ...args, approved: options.approved === true });
  }
  if (toolName === "run_checks") {
    return await codeRuntime.runChecks(requireCurrentCodeTaskId(args, options), { ...args, approved: options.approved === true });
  }
  if (toolName === "run_git_command") {
    return await codeRuntime.runGitCommand(requireCurrentCodeTaskId(args, options), { ...args, approved: options.approved === true });
  }
  throw Object.assign(new Error(`Unknown code surface tool: ${toolName}`), { status: 400 });
}

function requireCurrentCodeTaskId(args, options = {}) {
  const taskId = args.taskId || options.currentCodeTaskId;
  if (!taskId) {
    throw Object.assign(new Error("This code tool requires a current code task id."), { status: 400 });
  }
  return taskId;
}

function normalizeScopePath(scopePath) {
  const value = String(scopePath || "Code").replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
  return value || "Code";
}

function isPathInsideScope(filePath, scopePath) {
  const file = normalizeScopePath(filePath);
  const scope = normalizeScopePath(scopePath);
  return file === scope || file.startsWith(`${scope}/`);
}
