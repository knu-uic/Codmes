import { listRuntimeModels } from "./runtime/config-store.mjs";
import { discoverOllamaModels } from "./runtime/provider-model-discovery.mjs";

export class ModelRuntime {
  constructor({ workspaceRoot, discoverOllama = discoverOllamaModels } = {}) {
    this.workspaceRoot = workspaceRoot;
    this.discoverOllama = discoverOllama;
  }

  async listModels() {
    const models = this.workspaceRoot ? await listRuntimeModels(this.workspaceRoot) : [];
    const active = models.find((model) => model.isActive);

    if (this.workspaceRoot) {
      try {
        const discovered = await this.discoverOllama(this.workspaceRoot);
        const seen = new Set(models.map((model) => model.id));
        for (const modelName of discovered.models) {
          const id = `ollama-local:${modelName}`;
          if (seen.has(id)) continue;
          seen.add(id);
          models.push({
            id,
            name: modelName,
            model: modelName,
            provider: "ollama-local",
            source: discovered.source,
            isActive: active?.provider === "ollama-local" && active?.model === modelName
          });
        }
      } catch {
        // A stopped local runtime must not make the general model registry unavailable.
      }
    }

    return {
      runtime: "model-runtime",
      source: "codmes",
      providers: [],
      models
    };
  }
}
