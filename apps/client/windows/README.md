# Windows client scaffold

This WPF/.NET project connects to a Codmes Workspace server, identifies as
`windows + desktop`, filters runtime views by the shared compatibility contract,
and renders declarative Surfaces. It also includes live WebSocket Chat,
editable Notes/Code file browsers, and pending-approval review with patch
diffs, approve/reject actions, and optional post-patch checks.

Run `dotnet run --project apps/client/windows/Codmes.Windows.csproj` on Windows.
No Apple SwiftUI code is embedded or reused. The PDF renderer uses
server-rendered pages with a native WPF overlay for pen strokes, rectangles,
text objects, page navigation, and synchronized annotation saving.

Text edits autosave after 600 ms; completed PDF gestures save locally immediately.
Snapshots and per-edit operation IDs/timestamps are durable, profile/server scoped,
and contain no credentials. The common `merge-modified-v2` protocol preserves
independent words and PDF object properties; overlapping changes use local edit
order rather than arrival order. An unsaved editor draft pins its original merge
base. There is no separate history/recovery browser. Text uses native Undo/Redo
(80 steps); PDF annotation undo is session-only, capped at 80 steps / 8 MiB.
Remote replacements clear undo, while a local undo autosaves as a new edit.
Identical reads/saves reuse content-hash objects. Journal commits protect current
and pending payloads before removing unreferenced older objects. The manifest-first
file browser supports per-device local/server/sync policies and canonical IDs;
cached text can be edited offline. PDF page rendering still requires the server,
and independent whole-PDF registration/replacement is not yet supported.
Byte-array reads pause above 64 MiB. This is not a full offline PDF workspace.
Protocol limits are in `docs/server/api-contract.md`.

Local Release packages: `npm run client:build:windows` from the repository root.
Output is `apps/client/builds/windows/latest/`, with one previous successful build
in `previous/`. A cross-build on macOS does not verify Windows GUI behavior.

Google Desktop OAuth token exchange uses the distributor's matching
`CODMES_GOOGLE_DESKTOP_CLIENT_SECRET` at build time. Set it in the build
environment for official packages; each server operator and client user does
not configure it. A build missing the value reports a configuration error
before opening the browser. Never commit the downloaded OAuth JSON.
