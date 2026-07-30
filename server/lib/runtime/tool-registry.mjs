const TOOL_NAME_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;
const PROVIDER_TOOL_PATTERN = /^[A-Za-z0-9_.-]{1,128}$/;
const PROVIDER_TYPES = new Set(["native", "plugin", "mcp"]);
const MAX_SCHEMA_BYTES = 64 * 1024;

export class ToolRegistry {
  constructor({ adapters = {} } = {}) {
    this.descriptors = new Map();
    this.adapters = new Map(Object.entries(adapters));
  }

  register(value) {
    const descriptor = normalizeToolDescriptor(value);
    if (this.descriptors.has(descriptor.name)) {
      throw new Error(`Tool '${descriptor.name}' is already registered.`);
    }
    this.descriptors.set(descriptor.name, descriptor);
    return descriptor;
  }

  registerOpenAITool(tool, metadata = {}) {
    return this.register(descriptorFromOpenAITool(tool, metadata));
  }

  get(name) {
    return this.descriptors.get(String(name || "")) || null;
  }

  list({ surface = null, provider = null } = {}) {
    return [...this.descriptors.values()].filter((descriptor) => {
      if (provider && descriptor.provider.type !== provider) return false;
      if (surface && descriptor.surfaces.length && !descriptor.surfaces.includes(surface)) return false;
      return true;
    });
  }

  openAITools(options = {}) {
    return this.list(options).map(openAIToolFromDescriptor);
  }

  async execute(name, args = {}, context = {}) {
    const descriptor = this.get(name);
    if (!descriptor) {
      throw Object.assign(new Error(`Tool '${name}' is not registered.`), { status: 404 });
    }
    const adapter = this.adapters.get(descriptor.provider.type);
    if (!adapter || typeof adapter.execute !== "function") {
      throw Object.assign(
        new Error(`Tool provider '${descriptor.provider.type}' is not available.`),
        { status: 501 }
      );
    }
    return await adapter.execute(descriptor, args, context);
  }
}

export function normalizeToolDescriptor(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Tool descriptor must be an object.");
  }
  const name = String(value.name || "").trim();
  const description = String(value.description || "").trim();
  if (!TOOL_NAME_PATTERN.test(name)) throw new Error("Tool name is invalid.");
  if (!description) throw new Error(`Tool '${name}' requires a description.`);
  const inputSchema = normalizeInputSchema(value.inputSchema || value.parameters);
  const provider = normalizeProvider(value.provider);
  const surfaces = normalizeStringArray(value.surfaces, "surface");
  return Object.freeze({
    name,
    description,
    inputSchema,
    provider,
    surfaces,
    group: String(value.group || provider.type).trim() || provider.type,
    requiresApproval: value.requiresApproval === true,
    readOnly: value.readOnly === true,
    pluginId: String(value.pluginId || "").trim() || null,
    storageNamespace: String(value.storageNamespace || "").trim() || null
  });
}

export function descriptorFromOpenAITool(tool, metadata = {}) {
  if (tool?.type !== "function" || !tool.function) {
    throw new Error("Only OpenAI function tools can be registered.");
  }
  return normalizeToolDescriptor({
    name: tool.function.name,
    description: tool.function.description,
    inputSchema: tool.function.parameters,
    provider: metadata.provider || { type: "native", id: "workspace", tool: tool.function.name },
    surfaces: metadata.surfaces || [],
    group: metadata.group,
    requiresApproval: metadata.requiresApproval,
    readOnly: metadata.readOnly,
    pluginId: metadata.pluginId
  });
}

export function openAIToolFromDescriptor(descriptor) {
  return {
    type: "function",
    function: {
      name: descriptor.name,
      description: descriptor.description,
      parameters: descriptor.inputSchema
    }
  };
}

export function normalizePluginToolDocument(value, {
  pluginId,
  surfaceId,
  mcpName,
  storageCollections = []
} = {}) {
  if (value == null) return [];
  const document = Array.isArray(value) ? { schemaVersion: 1, tools: value } : value;
  if (!document || typeof document !== "object" || Array.isArray(document)
      || Number(document.schemaVersion) !== 1 || !Array.isArray(document.tools)) {
    throw new Error("Plugin tools document schema is invalid.");
  }
  if (document.tools.length > 64) throw new Error("Plugin tools document contains too many tools.");
  const seen = new Set();
  return document.tools.map((raw) => {
    const provider = raw?.provider;
    if (!["mcp", "plugin"].includes(provider?.type)) throw new Error("Plugin tool provider is invalid.");
    const server = String(provider.server || mcpName || "").trim();
    if (provider.type === "mcp" && (!server || server !== mcpName)) throw new Error("Plugin tool MCP provider must reference its own MCP server.");
    const providerId = provider.type === "plugin" ? String(provider.id || pluginId) : server;
    if (provider.type === "plugin" && providerId !== pluginId) throw new Error("Plugin tool provider must reference its own plugin.");
    if (provider.type === "plugin") {
      const tool = String(provider.tool || "");
      const match = /^collection\.([a-z][a-z0-9_-]{0,63})\.(list|get|create|update|delete)$/.exec(tool);
      if (!match || !storageCollections.includes(match[1])) {
        throw new Error("Plugin tool must reference a declared collection.");
      }
    }
    const descriptor = normalizeToolDescriptor({
      ...raw,
      pluginId,
      surfaces: raw.surfaces || [surfaceId],
      provider: {
        type: provider.type,
        id: providerId,
        tool: provider.tool
      }
    });
    if (descriptor.surfaces.some((surface) => surface !== surfaceId)) {
      throw new Error("Plugin tools cannot request another plugin's Surface.");
    }
    if (seen.has(descriptor.name)) throw new Error("Plugin tool names must be unique.");
    seen.add(descriptor.name);
    return descriptor;
  });
}

function normalizeProvider(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Tool descriptor requires a provider.");
  }
  const type = String(value.type || "").trim().toLowerCase();
  const id = String(value.id || value.server || "").trim();
  const tool = String(value.tool || "").trim();
  if (!PROVIDER_TYPES.has(type)) throw new Error(`Unsupported tool provider '${type}'.`);
  if (!id) throw new Error(`Tool provider '${type}' requires an id.`);
  if (!tool || !PROVIDER_TOOL_PATTERN.test(tool)) {
    throw new Error(`Tool provider '${type}' requires a valid tool name.`);
  }
  return Object.freeze({ type, id, tool });
}

function normalizeInputSchema(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || value.type !== "object") {
    throw new Error("Tool inputSchema must be a JSON object schema.");
  }
  const serialized = JSON.stringify(value);
  if (Buffer.byteLength(serialized, "utf8") > MAX_SCHEMA_BYTES) {
    throw new Error("Tool inputSchema is too large.");
  }
  return Object.freeze(JSON.parse(serialized));
}

function normalizeStringArray(value, label) {
  if (value == null) return [];
  if (!Array.isArray(value)) throw new Error(`Tool ${label}s must be an array.`);
  const items = [...new Set(value.map(String).map((item) => item.trim()).filter(Boolean))];
  if (items.some((item) => !/^[a-z0-9][a-z0-9_-]*$/.test(item))) {
    throw new Error(`Tool ${label} is invalid.`);
  }
  return items;
}
