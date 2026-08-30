# Client compatibility

Plugin compatibility is a two-dimensional Surface/UI capability declaration:

| Device | platform | formFactor |
| --- | --- | --- |
| iPhone | `ios` | `phone` |
| iPad | `ios` | `tablet` |
| Android phone | `android` | `phone` |
| Android tablet | `android` | `tablet` |
| Mac | `macos` | `desktop` |
| Windows PC | `windows` | `desktop` |

The Workspace installs a plugin independently of the connected client. A client
uses both values to decide whether to expose that plugin's views. LLM execution,
tools, MCP servers, storage, credentials, and update state remain server-owned
and are not filtered by client compatibility.

The shared wire shape is documented in
`client/shared/client-protocol.schema.json`. `ipados` is accepted only as a
legacy input and normalizes to `ios + tablet`. When an old record has no
`formFactors`, its old platform names derive `macos -> desktop`, `ios -> phone`,
and `ipados -> tablet`.

The Apple app contains the production SwiftUI renderers. The Android and Windows
directories are executable native clients that implement platform detection,
authentication, runtime discovery, compatibility filtering, declarative
collection/dashboard rendering, live Chat, and editable Notes/Code browsing.
Their approval inbox renders patch diffs and supports approve/reject actions
with optional checks. Advanced PDF annotation remains a platform-specific
renderer extension; the server protocol and declarative Surface contract do not
depend on it.

Client CI runs the Apple package tests, Android compatibility tests/lint/APK
build, and Windows compatibility tests/self-contained win-x64 publish. This
keeps compatibility declarations tied to executable client artifacts.
