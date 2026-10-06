import { spawnSync } from 'node:child_process';
import { existsSync, lstatSync, readFileSync, realpathSync } from 'node:fs';
import { cp, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const platforms = new Set(['macos', 'ios-simulator', 'android', 'windows']);
const markerName = '.codmes-build.json';

export function outputDirectory(root, platform) {
  if (!platforms.has(platform)) throw new Error(`Unsupported platform: ${platform}`);
  return path.join(root, 'apps', 'client', 'builds', platform);
}

// Generated artifacts must never redirect cleanup into source folders or user data.
export function assertNoSymlinks(root, target) {
  const relative = path.relative(root, target);
  if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error('Output must be a child of the build root');
  }
  let current = root;
  for (const component of relative.split(path.sep)) {
    current = path.join(current, component);
    let stat;
    try { stat = lstatSync(current); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (stat?.isSymbolicLink()) {
      throw new Error(`Refusing symlink output: ${current}`);
    }
  }
}

async function assertManaged(directory, platform) {
  if (!existsSync(directory)) return;
  const marker = JSON.parse(await readFile(path.join(directory, markerName), 'utf8'));
  if (marker.owner !== 'codmes-client-build' || marker.platform !== platform) {
    throw new Error(`Refusing to replace unmanaged directory: ${directory}`);
  }
}

export async function publishBuild(root, platform, staged) {
  const base = outputDirectory(root, platform);
  assertNoSymlinks(root, base);
  assertNoSymlinks(base, staged);
  if (path.dirname(staged) !== base || !path.basename(staged).startsWith('.next-')) {
    throw new Error('Staged build must be a generated sibling of latest');
  }
  const latest = path.join(base, 'latest');
  const previous = path.join(base, 'previous');
  assertNoSymlinks(base, latest);
  assertNoSymlinks(base, previous);
  await assertManaged(staged, platform);
  await assertManaged(latest, platform);
  await assertManaged(previous, platform);
  // Only a verified, script-owned previous build is pruned, never source or latest.
  if (existsSync(previous)) await rm(previous, { recursive: true });
  const hadLatest = existsSync(latest);
  if (hadLatest) await rename(latest, previous);
  try {
    await rename(staged, latest);
  } catch (error) {
    if (hadLatest) await rename(previous, latest);
    throw error;
  }
  return latest;
}

function run(command, args, cwd = repository) {
  const result = spawnSync(command, args, { cwd, stdio: 'inherit', env: process.env });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status})`);
}

async function build(platform) {
  const base = outputDirectory(repository, platform);
  assertNoSymlinks(repository, base);
  await mkdir(base, { recursive: true });
  const lock = path.join(base, '.build-lock');
  await mkdir(lock).catch(() => { throw new Error(`Build already running or stale lock: ${lock}`); });
  let staged;
  try {
    staged = await mkdtemp(path.join(base, '.next-'));
    if (platform === 'macos' || platform === 'ios-simulator') {
      if (process.platform !== 'darwin') throw new Error('Apple builds require macOS and Xcode');
      const simulator = platform === 'ios-simulator';
      const cache = path.join(base, 'DerivedData');
      assertNoSymlinks(base, cache);
      const args = ['-project', 'apps/client/apple/Codmes.xcodeproj', '-scheme', simulator ? 'Codmes iOS' : 'Codmes',
        '-configuration', 'Release', '-destination', simulator ? 'generic/platform=iOS Simulator' : 'generic/platform=macOS',
        '-derivedDataPath', cache, 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES',
        'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'build'];
      run('xcodebuild', args);
      const appName = simulator ? 'Codmes iOS.app' : 'Codmes.app';
      const app = path.join(staged, appName);
      run('ditto', [path.join(cache, 'Build/Products', simulator ? 'Release-iphonesimulator' : 'Release', appName), app]);
      run('codesign', ['--verify', '--deep', '--strict', app]);
    } else if (platform === 'android') {
      run(process.platform === 'win32' ? 'gradlew.bat' : './gradlew', ['assembleDebug'], path.join(repository, 'apps/client/android'));
      await cp(path.join(repository, 'apps/client/android/app/build/outputs/apk/debug/app-debug.apk'), path.join(staged, 'Codmes-debug.apk'));
    } else {
      run('dotnet', ['publish', 'apps/client/windows/Codmes.Windows.csproj', '--configuration', 'Release',
        '--runtime', 'win-x64', '--self-contained', 'true', '-p:PublishSingleFile=true', '--output', staged]);
      if (!existsSync(path.join(staged, 'Codmes.Windows.exe'))) throw new Error('Windows executable missing');
    }
    const version = JSON.parse(readFileSync(path.join(repository, 'package.json'), 'utf8')).version;
    await writeFile(path.join(staged, markerName), JSON.stringify({ owner: 'codmes-client-build', platform, version,
      builtAt: new Date().toISOString(), signing: 'local-development' }, null, 2));
    const latest = await publishBuild(repository, platform, staged);
    staged = undefined;
    console.log(`Client build: ${latest}`);
  } finally {
    if (staged) await rm(staged, { recursive: true, force: true });
    await rm(lock, { recursive: true });
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const platform = process.argv[2];
  if (process.argv.length !== 3 || !platforms.has(platform)) {
    console.error('Usage: node scripts/build-client.mjs macos|ios-simulator|android|windows');
    process.exitCode = 1;
  } else {
    await build(platform).catch(error => { console.error(error.message); process.exitCode = 1; });
  }
}
