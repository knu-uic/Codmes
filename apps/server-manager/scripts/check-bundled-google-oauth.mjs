import process from "node:process";

const platforms = ["desktop", "macos", "ios", "android", "web"];
const required = (process.argv.find((arg) => arg.startsWith("--require=")) || "")
  .slice("--require=".length).split(",").filter(Boolean);
const printAppleScheme = process.argv.find((arg) => arg.startsWith("--print-apple-scheme="))
  ?.slice("--print-apple-scheme=".length);
const values = Object.fromEntries(platforms.map((platform) => [
  platform,
  String(process.env[`CODMES_BUNDLED_GOOGLE_${platform.toUpperCase()}_CLIENT_ID`] || "").trim()
]));

for (const platform of required) {
  if (!platforms.includes(platform)) throw new Error(`Unknown Google OAuth platform: ${platform}`);
  if (!values[platform]) throw new Error(`Official release is missing the ${platform} Google OAuth client ID.`);
}
if (required.includes("desktop") && !String(process.env.CODMES_BUNDLED_GOOGLE_DESKTOP_CLIENT_SECRET || "").trim()) {
  throw new Error("Official release is missing the matching Desktop OAuth client secret.");
}
for (const [platform, id] of Object.entries(values)) {
  if (id && !/^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$/.test(id)) {
    throw new Error(`Invalid ${platform} Google OAuth client ID.`);
  }
}

if (printAppleScheme) {
  if (!["macos", "ios"].includes(printAppleScheme) || !values[printAppleScheme]) {
    throw new Error(`Missing Apple Google OAuth client ID for ${printAppleScheme}.`);
  }
  const suffix = ".apps.googleusercontent.com";
  process.stdout.write(`com.googleusercontent.apps.${values[printAppleScheme].slice(0, -suffix.length)}\n`);
} else {
  process.stdout.write(required.length ? "Official Google OAuth IDs are configured.\n" : "Google OAuth ID format check passed.\n");
}
