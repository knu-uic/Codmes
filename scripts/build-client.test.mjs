import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, symlink, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { outputDirectory, publishBuild, assertNoSymlinks } from './build-client.mjs';

test('outputs are distinct from Server Manager sources', () => {
  assert.equal(outputDirectory('/repo', 'macos'), path.join('/repo', 'apps/client/builds/macos'));
  assert.throws(() => outputDirectory('/repo', '../server-manager'));
});

test('the unified client layout contains source projects and excludes only generated outputs', async () => {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  for (const project of ['apple/Codmes.xcodeproj/project.pbxproj', 'android/app/build.gradle.kts',
    'windows/Codmes.Windows.csproj', 'shared/client-protocol.schema.json']) {
    assert.ok(existsSync(path.join(root, 'apps/client', project)), `Missing source project: ${project}`);
  }
  assert.ok(!existsSync(path.join(root, 'client')), 'Duplicate root client directory');
  const ignore = (await readFile(path.join(root, 'apps/client/.gitignore'), 'utf8')).split('\n');
  assert.ok(ignore.includes('builds/'));
  assert.ok(!ignore.includes('apple/') && !ignore.includes('android/') && !ignore.includes('windows/'));
});

test('only latest and one previous verified build are retained', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'codmes-build-test-'));
  try {
    const base = outputDirectory(root, 'macos');
    await mkdir(base, { recursive: true });
    for (let version = 1; version <= 3; version++) {
      const staged = await mkdtemp(path.join(base, '.next-'));
      await writeFile(path.join(staged, '.codmes-build.json'), JSON.stringify({ owner: 'codmes-client-build', platform: 'macos' }));
      await writeFile(path.join(staged, 'version'), String(version));
      await publishBuild(root, 'macos', staged);
    }
    assert.equal(await readFile(path.join(base, 'latest/version'), 'utf8'), '3');
    assert.equal(await readFile(path.join(base, 'previous/version'), 'utf8'), '2');
  } finally { await rm(root, { recursive: true }); }
});

test('unmanaged prior directories and symlinks are never replaced', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'codmes-build-test-'));
  try {
    const base = outputDirectory(root, 'macos');
    await mkdir(path.join(base, 'latest'), { recursive: true });
    await writeFile(path.join(base, 'latest/user-data'), 'keep');
    const staged = await mkdtemp(path.join(base, '.next-'));
    await writeFile(path.join(staged, '.codmes-build.json'), JSON.stringify({ owner: 'codmes-client-build', platform: 'macos' }));
    await assert.rejects(publishBuild(root, 'macos', staged));
    assert.equal(await readFile(path.join(base, 'latest/user-data'), 'utf8'), 'keep');
    await symlink(path.join(base, 'latest'), path.join(base, 'previous'));
    assert.throws(() => assertNoSymlinks(base, path.join(base, 'previous')));
    assert.throws(() => assertNoSymlinks(root, path.dirname(root)));
    await symlink(path.join(base, 'missing'), path.join(base, 'dangling'));
    assert.throws(() => assertNoSymlinks(base, path.join(base, 'dangling')));
  } finally { await rm(root, { recursive: true }); }
});
