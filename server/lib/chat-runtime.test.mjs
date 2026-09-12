process.env.NODE_ENV = "test";
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { ChatRuntime } from "./chat-runtime.mjs";

test("ChatRuntime wait mode keeps post-processed completion text", async () => {
  class Runtime extends EventEmitter {
    async submitPrompt(params) {
      this.emit("event", { type: "message.delta", sessionId: params.sessionId, text: "[그림:d123]" });
      const reply = "![그림](http://127.0.0.1:8787/api/document-assets/study--12345678/figure.png)";
      this.emit("event", { type: "turn.complete", sessionId: params.sessionId, text: reply });
      return { ok: true, sessionId: params.sessionId, reply };
    }
  }

  const runtime = new Runtime();
  const chat = new ChatRuntime({ runtime });
  const result = await chat.submitPrompt({ sessionId: "session-1", message: "show it", wait: true });

  assert.equal(result.reply, "![그림](http://127.0.0.1:8787/api/document-assets/study--12345678/figure.png)");
});
