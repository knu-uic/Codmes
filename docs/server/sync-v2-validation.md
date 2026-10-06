# Codmes Sync v2 Validation on 1 October 2026

## Unified app layout (3 October 2026)

Client sources now live in `apps/client/{apple,android,windows,shared}` with generated
artifacts in `apps/client/builds/<platform>`. The old root client directory was moved,
not duplicated: all 51 previously tracked client files have corresponding new paths.
Existing untracked client work was retained. Each app owns its generated-output ignore
rules rather than excluding the whole `apps/` directory.

Server Manager keeps frontend sources in `src`, native sources in `src-tauri` and
source icon input in `src/assets`. Vite output, runtime staging, native targets and
local tools now live under its `builds/` directory. Installed bundle resource paths
remain `runtime/codmes` and `runtime/bin`; only developer workspace paths changed.
Relocated client build caches were moved recoverably to Trash. Stale Tauri and
autostart compilation caches were regenerated after their embedded old paths caused
a permission-file lookup failure; package bundles and user data were preserved.

Verification after relocation:

- Server + build-layout tests with managed PostgreSQL: 343 passed, 1 skipped.
- Apple: 72 passed; Windows: 17 passed; Android: 14 passed plus lint.
- Fresh macOS Release, signed iOS Simulator, Android debug and Windows win-x64 builds
  succeeded in the new client output directory.
- Server Manager frontend/layout tests: 12 passed; native Rust tests: 15 passed.
- Server Manager app and DMG were rebuilt under `builds/rust/release/bundle/`.
  Client macOS/iOS and Manager strict deep codesign verification succeeded. The
  newly packaged Node/server returned HTTP 200 from `/api/health` in a disposable
  isolated workspace; no installed profile credentials or data were used.
- Source/output Git exclusion checks and local Markdown links passed.
- Interactive Google login, device pen input and Windows GUI testing were not repeated
  for this layout-only change. Installed applications and account data were not reset.

## Build-output and documentation cleanup (3 October 2026)

Fresh local Release builds succeeded for macOS, signed arm64 iOS Simulator,
Android debug and self-contained Windows win-x64 under `apps/client/builds/`.
Build publication tests verify bounded latest/previous retention and refusal to
replace unowned directories, symlinks or paths outside the output root. They are
included in `npm run check`: 342 passed, 1 skipped with managed PostgreSQL enabled.
Apple tests: 72 passed. This cleanup did not repeat interactive login or pen tests.

The prior dated `local-releases/` directory (approximately 9.6 GiB) was moved to
macOS Trash, not permanently deleted. The immediately preceding Mac app is retained
in `apps/client/builds/macos/previous/`; one Server Manager rollback bundle is in
`apps/server-manager/builds/rust/release/bundle/previous/`. The latest Manager
DMG remains in `bundle/dmg/` and its SHA-256 matched the moved copy. Installed apps,
accounts, local journals and server data were not replaced or reset. Empty obsolete
nested staging directories were removed. Existing PDF input compatibility and
sync-base/database migrations remain necessary and were not treated as dead code.

## Selective-sync follow-up (3 October 2026)

The working tree now adds per-device local/server/sync policies, canonical file
identities, manifest-first navigation, sequential transfers and first-registration
confirmation. Apple compares the PDF original AND normalized annotations before
adopting an independently imported file. Initial PDF registration/explicit document
replacement uses one durable transaction for original and ink, with both revision
conditions, idempotent receipts and reader-before-recovery serialization.

Verification for this follow-up:

- `CODMES_TEST_MANAGED_POSTGRES=true npm run check`: 339 passed, 1 skipped.
- `swift test --package-path apps/client/apple`: 72 passed.
- `dotnet test apps/client/windows/tests/Codmes.Windows.Tests.csproj`: 17 passed.
- Android `:app:testDebugUnitTest`: 14 passed; debug APK build successful.
- macOS Release, signed iOS Simulator arm64 Release and Windows Release cross-build:
  successful. Existing iOS actor-isolation warnings remain; no build errors.
- Server Manager app/DMG build uses the previously installed portable PostgreSQL
  distribution; no system/database bootstrap or account reset was performed.
- Mac client/Server Manager strict deep codesign verification: successful.
- `git diff --check`: clean.

Added tests cover independent local IDs attaching identical content, ambiguous first
registration preserving both sides until a decision, concurrent first uploads in
separate Node processes, conditional overwrite/retry, ID-preserving moves with causal
bases, remote rename, local recreation identity, device-policy isolation and rejection
of a forged device identity through actual authenticated PostgreSQL-backed HTTP,
metadata visibility before disk-space failure, on-demand server-mode download and
clean eviction, mode retention after changed-payload download/restart,
local-mode no-download/no-upload, different PDF ink, atomic PDF/ink
registration/replacement, truncated requests and committed transaction restart recovery.
Swift/C#/Kotlin continue to run the real Node implementation in disposable HTTP
fixtures, not the user's installed profile data.

Remaining platform/provider boundaries are documented in `docs/features/notes.md`:
Android/Windows PDF rendering still requires the server; independent whole-PDF
replacement is intentionally not performed there without the complete bundle path.
Their byte-array readers pause files above 64 MiB rather than risking an allocation
failure. Declarative external plugins cache bounded read-only view snapshots, not
their upstream attachments or an offline structured edit log. Generic provider-level
folder/file synchronization, native PDF rendering and delta/paginated manifests are
not claimed as complete. The manifest currently scans the full tree and caches hashes
using file stat signatures on subsequent scans.

The older validation below describes the preceding autosave/undo release, not new
selective-sync UI or native pen testing. This follow-up does not claim Windows GUI,
Android emulator/hardware stylus, iPhone/iPad interactive editing or background/low-
storage device behavior was tested end-to-end.

The Mac client and Server Manager were installed with recoverable previous bundles.
Only one process per app was launched. Server Manager automatically moved from its startup screen to login; its
installed server sync module was compared byte-for-byte with the source. The iPhone
17 and iPad (A16) simulators were updated and launched without deleting their data.
Both active simulator journals received canonical server IDs for all four cached
notes, with zero pending operations; their guest journals remained empty. This
verifies installed-app metadata synchronization, not interactive editing/pen input.
At the time of this validation, Mac's existing Keychain approval was pending, so final interaction
with the new file-mode dropdown is not yet verified. No Keychain password or ACL
bypass was attempted. The later build-output cleanup uses
`apps/client/builds/<platform>/latest/` for clients and
`apps/server-manager/builds/rust/release/bundle/` for Server Manager; local
client scripts retain one `previous/` rather than date-named copies.

This change uses immutable synchronization bases and deterministic replay, not CRDT.
The follow-up removes the user-facing version/recovery browser in favor of bounded,
session-local Undo/Redo. Local storage keeps current and pending data; the server
shares compressed blocks rather than retaining a complete file copy per edit.
The normative wire contract and safety limits are in [api-contract.md](api-contract.md).
Existing account/profile changes in the working tree were preserved.
The Undo/Redo follow-up completed on 2 October 2026.

## Automated validation

- `CODMES_TEST_MANAGED_POSTGRES=true npm run check`: 322 passed, 1 skipped.
  The skipped standalone PostgreSQL migration test requires `CODMES_TEST_DATABASE_URL`;
  disposable managed PostgreSQL authentication/profile/HTTP integration tests did run.
- `swift test --package-path apps/client/apple`: 61 passed.
- `dotnet test apps/client/windows/tests/Codmes.Windows.Tests.csproj`: 15 passed.
- Android `:app:testDebugUnitTest`: 12 passed.
- macOS Release, iOS Simulator Release (arm64/x86_64), Windows Release cross-build,
  Android debug APK, and Server Manager app/DMG: successful.
- macOS client and Server Manager `codesign --verify --deep --strict`: successful.
- `git diff --check`: clean.

Swift `WorkspaceAPI`/`LocalWorkspace`, Kotlin `VersionedDocument`, and C#
`VersionedDocument` each call the actual Node merge implementation over localhost
HTTP in disposable fixtures. Fixtures use public dummy test tokens and isolated
temporary storage; they never read installed account credentials or user notes.
Production router tests additionally use real profile sessions, device approval,
managed PostgreSQL, and history/recovery authorization checks.

Covered cases include reversed arrivals, all permutations of three edits,
equal-clock deterministic ordering, separate words in one line, Korean/emoji/CRLF,
per-save offline snapshots and original bases, response loss and restart retries,
draft pinning, edits during an upload, deletion tombstones and restoration,
same PDF object's independent position/text/style changes, added strokes, entity
deletion, page IDs across reordering, duplicate page rejection, clock rollback,
future timestamps, unavailable bases, profile isolation, legacy API bypass,
interrupted committed projection recovery, and corrupt recovery blobs.

Additional cases cover identical-save/download deduplication, preserving every
pending intermediate edit across restart and cleanup, releasing acknowledged
objects, keeping an open PDF URL readable during replacement, sharing the PDF
original during annotation-only edits, grouped Undo/Redo and its count/byte limits,
old offline bases after projection metadata pruning, and passing the previous
10,000-operation limit. A randomized fixture with twenty edits/insertions into a
roughly 1 MiB binary used 1,437,451 bytes of shared base storage in the measured run,
instead of twenty whole copies. This is a fixture result, not a universal ratio.
PDF editor comparisons also ignore server timestamp/path normalization and empty
collection representation differences; actual changed annotation content clears
undo. Swift, Kotlin and C# verify the metadata-only case against actual server
acknowledgements, not just hand-written JSON fixtures.

## Installed app checks

The installed Mac client and Server Manager were updated with recoverable backups
at the time of validation. Superseded dated release folders are not active output
locations. Accounts and current data were not reset;
unreferenced old local payloads are deliberately removed by the new cleanup policy.
Current files, pending operations and open file URLs are protected. Only one
instance of each Mac app was launched. Updating this ad-hoc signed build can require
the user to approve existing macOS Keychain access again; no password/ACL bypass
was attempted.

A separate memo `Notes/되돌리기 검증 20261001.md` was created through the updated Mac UI.
Typing autosaved, Undo returned the original heading, and Redo restored the edit.
No history/recovery toolbar or sheet remains. Another edit after restarting the
updated Server Manager synchronized without a Save button. The installed server
had five original operations, one latest projection entry, a matching current
SHA-256 and a shared-block revision descriptor. The earlier test memo and its
subsequent user edits were not overwritten or removed.

The iPhone 17 and iPad (A16) simulators were updated with the final build and launched.
Their actual local workspace journals both downloaded the new Undo/Redo test memo
with all three expected lines, clean records and zero pending operations. Each
active account object directory held four current files rather than old versions.
Simulator internal-button automation
failed in Device Hub, so this is **not** a claim that interactive editing or pen
gestures were tested end-to-end on both simulator screens.

The final Mac build also displays the connected network icon correctly in Notes,
instead of a disconnected icon next to the successfully synchronized status.

Windows native GUI and Android hardware/emulator GUI/stylus interaction were not
run on this Mac. Their real C#/Kotlin journal and HTTP implementations were tested;
Windows was cross-built and Android was built. Physical phone/tablet battery,
background suspension, pen rendering and network-switch behavior remain outside
this verification scope.

## Intentional boundaries

PDF annotations are object/property merged; arbitrary PDF binary/page structural
changes are not a generic mergeable operation. Opaque legacy PencilKit bytes are
page-sized registers. Text refinement uses word/symbol boundaries, not character
CRDT. Binary originals use local-edit latest-wins. Undo is not a persistent server
archive. Long-offline merge bases, version aliases and tombstones remain internally;
unchanged blocks are shared/compressed. Total storage is not a fixed quota: distinct
changes and pending offline edits can still increase usage. Existing whole-file
server bases migrate lazily when read, not by a destructive startup purge.
Large ambiguous text merges, missing bases, structural
collisions and untracked external mutations are never resolved by discarding
local data. Full Android/Windows offline file navigation/PDF original rendering
is not part of the portable editing-journal implementation.
