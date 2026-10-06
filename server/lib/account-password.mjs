import crypto from "node:crypto";
import { promisify } from "node:util";

const scrypt = promisify(crypto.scrypt);
const parameters = { N: 32768, r: 8, p: 3, maxmem: 64 * 1024 * 1024 };
// Bound expensive KDF concurrency; reject rather than queue unbounded requests.
let running = 0;
function error(message, status = 400) { return Object.assign(new Error(message), { status }); }
export function normalizeAccountId(value) {
  const id = String(value || "").normalize("NFKC").trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9._-]{2,63}$/.test(id)) throw error("ID는 영문·숫자·점·밑줄·하이픈으로 3~64자여야 합니다.");
  return id;
}
export function validateAccountPassword(value) {
  if (typeof value !== "string" || [...value].length < 15 || value.length > 128) throw error("비밀번호는 15~128자로 입력하세요. 여러 단어를 조합해도 됩니다.");
  if (/^(.)\1+$/.test(value) || ["123456789012345", "passwordpassword", "abcdefghijklmnop"].includes(value.toLowerCase())) throw error("쉽게 추측할 수 없는 비밀번호를 사용하세요.");
  return value;
}
async function derive(value, salt) {
  if (running >= 4) throw error("로그인 요청이 많습니다. 잠시 후 다시 시도하세요.", 429);
  running++;
  try { return await scrypt(value, salt, 32, parameters); } finally { running--; }
}
export async function hashAccountPassword(value) {
  validateAccountPassword(value);
  const salt = crypto.randomBytes(16).toString("hex");
  const key = await derive(value, salt);
  return `scrypt-v1$${salt}$${key.toString("hex")}`;
}
export async function verifyAccountPassword(value, encoded) {
  const validInput = typeof value === "string" && value.length <= 128;
  const parts = /^scrypt-v1\$([a-f0-9]{32})\$([a-f0-9]{64})$/.exec(String(encoded || ""));
  const actual = await derive(validInput ? value : "invalid-password", parts?.[1] || "00000000000000000000000000000000");
  const expected = Buffer.from(parts?.[2] || "0".repeat(64), "hex");
  return Boolean(validInput && parts && crypto.timingSafeEqual(actual, expected));
}
