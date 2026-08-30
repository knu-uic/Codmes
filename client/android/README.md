# Android client scaffold

This native Android project connects to a Codmes Workspace server, detects
`android + phone/tablet`, filters runtime views by the shared compatibility
contract, and renders declarative Surfaces. It also includes live WebSocket
Chat, editable Notes/Code file browsers, and pending-approval review with patch
diffs, approve/reject actions, and optional post-patch checks. Build it with Android Studio
(JDK 17, Android SDK 35) or `./gradlew assembleDebug`.

The emulator default server is `http://10.0.2.2:8787`. Physical devices should
use the Workspace server's LAN HTTPS address. The client deliberately consumes
the common Workspace/Surface protocol and does not embed Apple SwiftUI code.
PDF annotation remains an independent Android renderer extension that does not
require changes to plugin manifests.
