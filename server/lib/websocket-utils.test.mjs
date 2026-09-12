import test from "node:test";
import assert from "node:assert/strict";
import { acceptWebSocket, createFrameDecoder, encodeWebSocketFrame } from "./websocket-utils.mjs";


test("encodes server text frames", () => {
  const frame = encodeWebSocketFrame({ ok: true });
  assert.equal(frame[0], 0x81);
  assert.equal(frame.subarray(2).toString("utf8"), "{\"ok\":true}");
});

test("decodes masked client text frames", () => {
  const messages = [];
  const decode = createFrameDecoder((text) => messages.push(text));
  decode(maskedTextFrame(JSON.stringify({ command: "connect" })));
  assert.deepEqual(messages, ['{"command":"connect"}']);
});

test("WebSocket handshake echoes the authenticated Codmes subprotocol", () => {
  let response = "";
  acceptWebSocket({
    headers: {
      "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
      "sec-websocket-protocol": "codmes.bearer.local-token"
    }
  }, { write(value) { response += value; } });
  assert.match(response, /101 Switching Protocols/);
  assert.match(response, /Sec-WebSocket-Protocol: codmes\.bearer\.local-token/);
});

function maskedTextFrame(text) {
  const payload = Buffer.from(text, "utf8");
  const mask = Buffer.from([1, 2, 3, 4]);
  const header = [0x81, 0x80 | payload.length, ...mask];
  const masked = Buffer.from(payload);
  for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i % 4];
  return Buffer.concat([Buffer.from(header), masked]);
}
