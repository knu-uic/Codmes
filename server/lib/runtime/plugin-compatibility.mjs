export const SUPPORTED_CLIENT_PLATFORMS = Object.freeze([
  "macos",
  "ios",
  "android",
  "windows"
]);

export const SUPPORTED_CLIENT_FORM_FACTORS = Object.freeze([
  "phone",
  "tablet",
  "desktop"
]);

const PLATFORM_SET = new Set(SUPPORTED_CLIENT_PLATFORMS);
const FORM_FACTOR_SET = new Set(SUPPORTED_CLIENT_FORM_FACTORS);

export function normalizeClientCompatibility({
  platforms,
  formFactors,
  subject = "Plugin",
  requirePlatforms = true
} = {}) {
  const declaredPlatforms = normalizeStringArray(platforms);
  const declaredFormFactors = normalizeStringArray(formFactors);
  const hadLegacyIPadOS = declaredPlatforms.includes("ipados");
  const normalizedPlatforms = declaredPlatforms
    .map((platform) => platform === "ipados" ? "ios" : platform)
    .filter((platform, index, values) => values.indexOf(platform) === index);

  if (requirePlatforms && normalizedPlatforms.length === 0) {
    throw new Error(`${subject} must declare at least one platform.`);
  }
  const unsupportedPlatforms = normalizedPlatforms.filter(
    (platform) => !PLATFORM_SET.has(platform)
  );
  if (unsupportedPlatforms.length) {
    throw new Error(`${subject} declares unsupported platforms: ${unsupportedPlatforms.join(", ")}.`);
  }

  const normalizedFormFactors = declaredFormFactors.length
    ? [...declaredFormFactors]
    : deriveLegacyFormFactors(declaredPlatforms);
  if (hadLegacyIPadOS && !normalizedFormFactors.includes("tablet")) {
    normalizedFormFactors.push("tablet");
  }
  if (requirePlatforms && normalizedFormFactors.length === 0) {
    throw new Error(`${subject} must declare at least one formFactor.`);
  }
  const unsupportedFormFactors = normalizedFormFactors.filter(
    (formFactor) => !FORM_FACTOR_SET.has(formFactor)
  );
  if (unsupportedFormFactors.length) {
    throw new Error(
      `${subject} declares unsupported formFactors: ${unsupportedFormFactors.join(", ")}.`
    );
  }

  return {
    platforms: normalizedPlatforms,
    formFactors: [...new Set(normalizedFormFactors)],
    migratedFromIPadOS: hadLegacyIPadOS
  };
}

export function supportsClient(compatibility, client) {
  const normalized = normalizeClientCompatibility({
    ...compatibility,
    subject: "Compatibility",
    requirePlatforms: false
  });
  if (normalized.platforms.length === 0 && normalized.formFactors.length === 0) return true;
  return normalized.platforms.includes(String(client?.platform || "").toLowerCase())
    && normalized.formFactors.includes(String(client?.formFactor || "").toLowerCase());
}

function deriveLegacyFormFactors(platforms) {
  const derived = [];
  for (const platform of platforms) {
    if (platform === "macos" && !derived.includes("desktop")) derived.push("desktop");
    if (platform === "ios" && !derived.includes("phone")) derived.push("phone");
    if (platform === "ipados" && !derived.includes("tablet")) derived.push("tablet");
  }
  return derived;
}

function normalizeStringArray(value) {
  return Array.isArray(value)
    ? [...new Set(value.map(String).map((item) => item.trim().toLowerCase()).filter(Boolean))]
    : [];
}
