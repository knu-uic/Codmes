import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  createRegistryRootKeyPair,
  signMarketplaceRegistry,
  signMarketplaceRegistryFile,
  verifyMarketplaceRegistrySignature
} from "./plugin-registry-signature.mjs";

test("Registry root signs exact bytes and rejects tampering", () => {
  const root = createRegistryRootKeyPair("com.codmes.marketplace");
  const registry = Buffer.from('{"schemaVersion":1,"plugins":[]}\n');
  const signature = signMarketplaceRegistry(registry, {
    signingKey: root.privateKey,
    rootId: root.identity.rootId
  });

  assert.deepEqual(
    verifyMarketplaceRegistrySignature(registry, signature, root.identity),
    {
      valid: true,
      rootId: root.identity.rootId,
      keyId: root.identity.keyId,
      registrySha256: signature.registrySha256
    }
  );
  assert.throws(
    () => verifyMarketplaceRegistrySignature(
      Buffer.from('{"schemaVersion":1,"plugins":[{}]}\n'),
      signature,
      root.identity
    ),
    /checksum/
  );
});

test("Registry signature file is written separately from the Registry", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-registry-signature-"));
  const registryPath = path.join(directory, "index.json");
  const signaturePath = path.join(directory, "index.sig.json");
  const root = createRegistryRootKeyPair("com.codmes.marketplace");
  await fs.writeFile(registryPath, '{"schemaVersion":1,"plugins":[]}\n');

  const result = await signMarketplaceRegistryFile(registryPath, signaturePath, {
    signingKey: root.privateKey,
    rootId: root.identity.rootId
  });
  const signature = JSON.parse(await fs.readFile(signaturePath, "utf8"));
  const registry = await fs.readFile(registryPath);

  assert.equal(result.keyId, root.identity.keyId);
  assert.equal(
    verifyMarketplaceRegistrySignature(registry, signature, root.identity).valid,
    true
  );
});
