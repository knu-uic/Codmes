# Windows client scaffold

This WPF/.NET project connects to a Codmes Workspace server, identifies as
`windows + desktop`, filters runtime views by the shared compatibility contract,
and renders declarative Surfaces. It also includes live WebSocket Chat and
editable Notes/Code file browsers.

Run `dotnet run --project client/windows/Codmes.Windows.csproj` on Windows.
No Apple SwiftUI code is embedded or reused. Advanced PDF annotation and patch
review remain independent Windows renderer extensions over the same APIs.
