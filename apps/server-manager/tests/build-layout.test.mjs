import assert from 'node:assert/strict';
import { readFileSync, existsSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { prepareNativeCheck } from '../scripts/prepare-native-check.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = file => readFileSync(path.join(root, file), 'utf8');

test('native checks prepare an empty generated resource root and preserve staged files', () => {
  const temporary = mkdtempSync(path.join(os.tmpdir(), 'codmes-native-check-'));
  try {
    prepareNativeCheck(temporary);
    const resources = path.join(temporary, 'builds', 'runtime');
    assert.deepEqual(readdirSync(resources), []);
    const staged = path.join(resources, 'staged-fixture');
    writeFileSync(staged, 'keep existing staged runtime');
    prepareNativeCheck(temporary);
    assert.equal(readFileSync(staged, 'utf8'), 'keep existing staged runtime');
    assert.match(JSON.parse(read('package.json')).scripts.check,
      /prepare-native-check\.mjs\s*&&\s*cargo test/);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});

test('frontend, native output and runtime staging live under the ignored build root', () => {
  const config = JSON.parse(read('src-tauri/tauri.conf.json'));
  assert.equal(config.build.frontendDist, '../builds/frontend');
  assert.deepEqual(config.bundle.resources, { '../builds/runtime/': 'runtime/' });
  assert.match(read('vite.config.ts'), /outDir: "builds\/frontend"/);
  assert.match(read('.cargo/config.toml'), /target-dir = "builds\/rust"/);
  assert.match(read('scripts/stage-runtime.mjs'), /path.join\(managerRoot, "builds", "runtime"\)/);
  assert.ok(read('.gitignore').split('\n').includes('builds/'));
});

test('app sources and icon input are kept separate from generated artifacts', () => {
  for (const file of ['src/main.ts', 'src/assets/icon.svg', 'src-tauri/src/lib.rs', 'src-tauri/Cargo.toml']) {
    assert.ok(existsSync(path.join(root, file)), `Missing source: ${file}`);
  }
  for (const obsolete of ['dist', 'runtime', '.tools', 'assets', 'src-tauri/target']) {
    assert.ok(!existsSync(path.join(root, obsolete)), `Duplicate old folder: ${obsolete}`);
  }
});

test('native OS differences stay behind the platform interface', () => {
  const nativeRoot = 'src-tauri/src';
  for (const file of ['lib.rs', 'manager.rs', 'google_oauth.rs']) {
    const source = read(`${nativeRoot}/${file}`);
    assert.doesNotMatch(source, /target_os\s*=|#\[cfg\((?:not\()?unix\)|std::os::/,
      `OS-specific implementation leaked into ${file}`);
    assert.match(source, /platform::/, `Missing platform interface use: ${file}`);
  }
  for (const file of ['mod.rs', 'macos.rs', 'linux.rs', 'windows.rs', 'unix.rs']) {
    assert.ok(existsSync(path.join(root, nativeRoot, 'platform', file)), `Missing adapter: ${file}`);
  }
  const platform = read(`${nativeRoot}/platform/mod.rs`);
  for (const os of ['macos', 'linux', 'windows']) {
    assert.match(platform, new RegExp(`#\\[cfg\\(target_os = "${os}"\\)\\]\\s+mod ${os};`));
  }
});
