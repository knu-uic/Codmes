# Plan: Codmes Gate 3 - private KNU RAG remote MCP

## Gate and issue state

- Gate 1: approved by the user.
- GitHub issue: [#5](https://github.com/jeongu0569-ui/Codmes/issues/5)
- Synchronized base: `origin/main` at `24eacba59c37ebbc2dd2eab2fc601784d5b85cdc`.
- Focused branch: `codex/issue-5-remote-knu-mcp`.
- This planning turn changes no product code and runs no tests.

## Goal

Connect the Codmes server's OpenAI Codex runtime to the existing private KNU
RAG MCP endpoint:

```text
Codmes OpenAI Codex
  -> Codmes MCP tool execution and approval inbox
  -> local loopback HTTP
  -> http://127.0.0.1:8000/api/mcp/
```

The KNU endpoint is a bearer-protected, stateless Streamable HTTP FastMCP
server. It returns JSON responses and exposes exactly:

- `search_knu_notices`
- `get_knu_notice_detail`

Deployment decision: each Mac runs its own Codmes server and KNU MCP server.
Codmes connects only to that Mac's loopback KNU MCP endpoint; Tailscale is not
part of this request path.

## Approved configuration contract

Remote configuration contains no bearer value:

```yaml
mcp_servers:
  - name: knu-rag
    transport: streamable_http
    url: http://127.0.0.1:8000/api/mcp/
    credential_id: knu-rag
    surfaces:
      - chat
    enabled: true
```

Compatibility rules:

- Missing `transport` means the existing `stdio` transport.
- `stdio` requires `command` and accepts the existing `args`, `env`, and
  `scopePath` fields.
- `streamable_http` requires an absolute HTTPS `url`, or an HTTP URL limited to
  loopback (`localhost`, `127.0.0.1`, or `::1`), plus `credential_id` and at
  least one allowed surface. It rejects URL userinfo, query strings, and
  fragments.
- The endpoint's trailing slash is preserved.
- Remote bearer credentials are never accepted in `url`, `args`, or `env`.

## Credential boundary

Store the bearer only in the Codmes server-owned
`.codmes/config/auth.json`, under a dedicated `mcp_credentials` namespace keyed
by `credential_id`. The MCP config stores only the reference.

- Harden the config directory to mode `0700` and `auth.json` to `0600`.
- Write credentials atomically and preserve existing provider credentials.
- Add server-side CLI provisioning that reads a token from stdin or a named
  environment variable. Never accept the raw token as a command-line argument.
- MCP list/read API responses return only `credentialConfigured: true|false`.
- The Apple client can select transport, enter URL and credential id, and see
  configuration status; it cannot read or edit the bearer.
- The token accessor is invoked by the HTTP transport immediately before an
  authenticated request so credential rotation does not require putting the
  token in a long-lived MCP config object.

## Implementation steps

### 1. Official MCP client and transport adapter

Files:

- `package.json`
- `package-lock.json`
- `server/lib/runtime/mcp-client.mjs`
- new focused MCP client tests under `server/lib/runtime/`

Changes:

- Add production dependency `@modelcontextprotocol/sdk` pinned to `1.29.0`.
- Keep the existing stdio implementation behind a transport-neutral client
  interface.
- Add a Streamable HTTP implementation using the SDK `Client` and
  `StreamableHTTPClientTransport`.
- Supply `Authorization: Bearer ...` through a server-side token accessor.
- Preserve the existing `start`, `listTools`, `callTool`, `stop`, `status`, and
  `tools` behavior expected by the runtime.
- Apply finite initialize/list/call timeouts and redact credential-bearing
  headers from errors and logs.
- Use normal TLS certificate and hostname validation; do not add an insecure
  TLS option.

### 2. Configuration, API, and CLI

Files:

- `server/lib/runtime/config-store.mjs`
- `server/lib/runtime/config-store.test.mjs`
- `server/index.mjs`
- `server/server-api-auth.test.mjs`
- `bin/codmes.mjs`
- `server/lib/cli-compat.test.mjs`

Changes:

- Normalize MCP entries as a discriminated `stdio | streamable_http` shape.
- Add MCP credential read/write/remove/status helpers without exposing the
  value through existing provider credential APIs.
- Add transport-specific validation to MCP create/update routes.
- Add a server-side credential provisioning/status/removal CLI flow using
  stdin or `--from-env NAME`.
- Keep existing stdio CLI commands and API bodies backward compatible.
- Recreate or stop a cached MCP client when its connection identity changes.

### 3. Codex tool exposure and approval

Files:

- `server/lib/runtime/openai-compatible-runtime.mjs`
- `server/lib/runtime/openai-compatible-runtime.test.mjs`
- `server/lib/agent-engine.test.mjs`
- optionally `server/lib/runtime/tool-discovery.mjs` and its tests only if the
  selected UI flow needs discovery text for dynamic MCP tools

Changes:

- Create clients through the transport-neutral factory.
- Include discovered MCP tools in the model tool list only when the MCP
  server's `surfaces` contains the active surface; for this issue, `chat`.
- Keep public tool naming and original-name mapping unchanged.
- Keep the existing `checkAction({type: "mcp.tool.call"})`,
  `approval.required`, pending-state persistence, approval inbox
  approve/reject, and single-call resume path unchanged.
- Configure `security.require_approval` to include `mcp.tool.call` in the
  integration environment so approval is required even if the general mode is
  `auto`.
- Never add the bearer to model messages, tool definitions, tool arguments,
  pending state, approval records, events, audit logs, or tool results.

### 4. Apple settings contract

Files:

- `client/apple/Sources/Codmes/Models.swift`
- `client/apple/Sources/Codmes/WorkspaceAPI.swift`
- `client/apple/Sources/Codmes/WorkspaceStore.swift`
- `client/apple/Sources/Codmes/RootView.swift`

Changes:

- Decode and edit the transport-discriminated public MCP configuration.
- Show command/args/env fields only for stdio.
- Show URL, credential id, and `credentialConfigured` status for
  Streamable HTTP.
- Do not add a bearer field and do not put the MCP bearer in Apple Keychain;
  this credential belongs to the Codmes server, not a client device.
- Continue using the existing approval inbox for `mcp.tool.call`.

### 5. Documentation

Files:

- `docs/server/api-contract.md`
- `docs/server/architecture.md`
- `docs/features/chat.md`
- `README.md` only if operator setup needs a top-level pointer

Document the local loopback configuration shape, one-command server-side secret
provisioning, approval precondition, rotation/removal, and validation steps.

## Verification

### Focused automated tests

1. Runtime config round-trips both legacy stdio and remote HTTP shapes.
2. Invalid transport combinations and insecure/malformed URLs return 400.
3. MCP API list/read responses never contain the bearer.
4. Credential writes preserve provider credentials and enforce `0700/0600`
   permissions.
5. A local mock Streamable HTTP server verifies initialize, `tools/list`,
   `tools/call`, bearer header presence, 401, JSON-RPC errors, timeout/abort,
   stop, and cached-client replacement.
6. The Chat surface sends the two `mcp__knu_rag__...` function schemas through
   the Codex Responses request.
7. Before approval the mock remote tool receives zero calls; approval executes
   exactly one stored call; rejection executes zero calls.
8. Model requests, API responses, events, tasks, approvals, audit records, and
   logs contain neither the bearer nor an Authorization header value.
9. Apple macOS and iOS targets decode/render stdio and remote configurations.

### Repository checks

- Focused Node tests for config, MCP client, runtime, agent approval, API, and
  CLI.
- Full `npm run check`.
- macOS build with code signing disabled.
- iOS Simulator build with code signing disabled.
- Compare failures against the synchronized base before attributing them to
  this issue.

### Private integration check

Using the real endpoint and a server-side credential:

1. An unauthenticated initialize request returns 401.
2. Authenticated initialize and `tools/list` succeed and return exactly the two
   notice evidence tools.
3. A Codmes Chat prompt using OpenAI Codex creates an `mcp.tool.call` approval
   before the remote `search_knu_notices` request.
4. Rejecting causes no remote tool call.
5. Approving executes the stored call exactly once and returns the evidence to
   the model.
6. No raw bearer appears in Codmes or KNU application logs.

This is a private local integration check, not authorization to change KNU
server configuration or public traffic.

## Explicitly out of scope

- OAuth, JWKS, delegated user authorization, or personalized KNU identity.
- LMS or portal tools.
- Tailscale Funnel, Tailnet routing, or public internet exposure.
- KNU RAG source filtering or data-quality corrections.
- KNU MCP tool or response-contract changes.
- Unrelated Apple build output, including `client/apple/build/`.

## Handoff

Implementation may begin only after this planning turn reports the issue,
branch/base facts, and approved plan. The requested implementation worker is
GPT-5.6 Terra with medium reasoning.
