export const DISTRIBUTION_CLI_VERSION = "1.0.0";
export const DISTRIBUTION_CLI_TAG = `codmes-distribution-cli-v${DISTRIBUTION_CLI_VERSION}`;

export function distributionCliInfo() {
  return {
    name: "Codmes Distribution CLI",
    version: DISTRIBUTION_CLI_VERSION,
    tag: DISTRIBUTION_CLI_TAG,
    manifestSchemaVersions: [1],
    registrySchemaVersions: [1],
    surfaceSchemaVersions: [1, 2],
    capabilities: [
      "plugin-pack",
      "publisher-prepare",
      "package-verify",
      "registry-validate",
      "registry-build",
      "registry-sign"
    ]
  };
}
