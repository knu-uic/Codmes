import { ChatBackend } from "./chat-backend.mjs";

export class RuntimeChatBackend extends ChatBackend {
  constructor(runtime) {
    super();
    this.runtime = runtime;
  }

  async connect() {
    await this.runtime.connect();
  }

  async createSession(params) {
    return await this.runtime.createSession(params);
  }

  async resumeSession(sessionId) {
    return await this.runtime.resumeSession(sessionId);
  }

  async submitPrompt(params) {
    if (params.wait) {
      const replyPromise = new Promise((resolve, reject) => {
        let answerText = "";
        let reasoningText = "";
        const onEvent = (envelope) => {
          const type = envelope.type || "";
          const text = envelope.text || envelope.payload?.text || (typeof envelope.payload === "string" ? envelope.payload : "");

          if (type === "message.delta" || type === "assistant.delta" || type === "assistant.message.delta") {
            answerText += text;
          } else if (
            type === "reasoning.delta" ||
            type === "thinking.delta" ||
            type === "assistant.reasoning.delta" ||
            type === "assistant.thinking.delta"
          ) {
            reasoningText += text;
          } else if (
            type === "message.done" ||
            type === "response.done" ||
            type === "turn.complete" ||
            type === "turn.completed" ||
            type === "message.completed"
          ) {
            cleanup();
            resolve({
              ok: true,
              sessionId: params.sessionId,
              reply: text || answerText,
              reasoning: reasoningText
            });
          }
        };

        const onClose = () => {
          cleanup();
          reject(new Error("Live runtime connection closed prematurely."));
        };

        const onError = (err) => {
          cleanup();
          reject(err);
        };

        const cleanup = () => {
          this.runtime.off("event", onEvent);
          this.runtime.off("close", onClose);
          this.runtime.off("error", onError);
        };

        this.runtime.on("event", onEvent);
        this.runtime.on("close", onClose);
        this.runtime.on("error", onError);

        this.runtime.submitPrompt(params).catch((err) => {
          cleanup();
          reject(err);
        });
      });

      return await replyPromise;
    }

    return await this.runtime.submitPrompt(params);
  }

  async respondToApproval(params) {
    return await this.runtime.respondToApproval(params);
  }

  async setAccessMode(sessionId, accessMode) {
    await this.runtime.setAccessMode(sessionId, accessMode);
  }

  async setReasoning(sessionId, reasoningEffort) {
    await this.runtime.setReasoning(sessionId, reasoningEffort);
  }

  close() {
    this.runtime.close();
  }
}

export class ChatRuntime {
  constructor({ runtime } = {}) {
    if (runtime) {
      this.backend = new RuntimeChatBackend(runtime);
    } else {
      this.backend = null;
    }
  }

  isAvailable() {
    return this.backend !== null;
  }

  async connect() {
    if (!this.backend) {
      throw Object.assign(
        new Error("Chat runtime is unavailable because no model execution backend is configured."),
        { status: 503 }
      );
    }
    await this.backend.connect();
  }

  async createSession(params) {
    if (!this.backend) {
      throw Object.assign(
        new Error("Chat runtime is unavailable because no model execution backend is configured."),
        { status: 503 }
      );
    }
    return await this.backend.createSession(params);
  }

  async resumeSession(sessionId) {
    if (!this.backend) {
      throw Object.assign(
        new Error("Chat runtime is unavailable because no model execution backend is configured."),
        { status: 503 }
      );
    }
    return await this.backend.resumeSession(sessionId);
  }

  async submitPrompt(params) {
    if (!this.backend) {
      throw Object.assign(
        new Error("Chat runtime is unavailable because no model execution backend is configured."),
        { status: 503 }
      );
    }
    return await this.backend.submitPrompt(params);
  }

  async respondToApproval(params) {
    if (!this.backend) {
      throw Object.assign(
        new Error("Chat runtime is unavailable because no model execution backend is configured."),
        { status: 503 }
      );
    }
    return await this.backend.respondToApproval(params);
  }

  async setAccessMode(sessionId, accessMode) {
    if (!this.backend) return;
    await this.backend.setAccessMode(sessionId, accessMode);
  }

  async setReasoning(sessionId, reasoningEffort) {
    if (!this.backend) return;
    await this.backend.setReasoning(sessionId, reasoningEffort);
  }

  close() {
    if (this.backend) this.backend.close();
  }
}
