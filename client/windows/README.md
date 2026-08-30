# Windows client scaffold

This WPF/.NET project connects to a Codmes Workspace server, identifies as
`windows + desktop`, filters runtime views by the shared compatibility contract,
and renders declarative Surfaces. It also includes live WebSocket Chat,
editable Notes/Code file browsers, and pending-approval review with patch
diffs, approve/reject actions, and optional post-patch checks.

Run `dotnet run --project client/windows/Codmes.Windows.csproj` on Windows.
No Apple SwiftUI code is embedded or reused. PDF annotation remains an
independent Windows renderer extension over the same APIs.
