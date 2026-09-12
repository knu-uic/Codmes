import crypto from "node:crypto";

export function acceptWebSocket(req, socket) {
  const key = req.headers["sec-websocket-key"];
  if (!key) throw new Error("Missing Sec-WebSocket-Key.");
  const accept = crypto
    .createHash("sha1")
    .update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    .digest("base64");
  const requestedProtocols = String(req.headers["sec-websocket-protocol"] || "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  const selectedProtocol = requestedProtocols.find((value) => value.startsWith("codmes.bearer.")) || "";
  socket.write([
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${accept}`,
    ...(selectedProtocol ? [`Sec-WebSocket-Protocol: ${selectedProtocol}`] : []),
    "",
    ""
  ].join("\r\n"));
}

export function encodeWebSocketFrame(value) {
  const payload = Buffer.from(typeof value === "string" ? value : JSON.stringify(value), "utf8");
  const header = [];
  header.push(0x81);
  if (payload.length < 126) {
    header.push(payload.length);
  } else if (payload.length < 65536) {
    header.push(126, (payload.length >> 8) & 0xff, payload.length & 0xff);
  } else {
    header.push(127, 0, 0, 0, 0, (payload.length >> 24) & 0xff, (payload.length >> 16) & 0xff, (payload.length >> 8) & 0xff, payload.length & 0xff);
  }
  return Buffer.concat([Buffer.from(header), payload]);
}

export function createFrameDecoder(onMessage, onClose) {
  let buffer = Buffer.alloc(0);
  return function decode(chunk) {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      if (buffer.length < 2) return;
      const first = buffer[0];
      const second = buffer[1];
      const opcode = first & 0x0f;
      const masked = Boolean(second & 0x80);
      let length = second & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffer.length < offset + 2) return;
        length = buffer.readUInt16BE(offset);
        offset += 2;
      } else if (length === 127) {
        if (buffer.length < offset + 8) return;
        const high = buffer.readUInt32BE(offset);
        const low = buffer.readUInt32BE(offset + 4);
        if (high !== 0) throw new Error("WebSocket frame is too large.");
        length = low;
        offset += 8;
      }
      let mask = null;
      if (masked) offset += 4;
      if (buffer.length < offset + length) return;
      if (masked) mask = buffer.subarray(offset - 4, offset);
      const payload = Buffer.from(buffer.subarray(offset, offset + length));
      buffer = buffer.subarray(offset + length);
      if (masked) {
        for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
      }
      if (opcode === 0x8) {
        onClose?.();
        return;
      }
      if (opcode === 0x1) onMessage(payload.toString("utf8"));
    }
  };
}
