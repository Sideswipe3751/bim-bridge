# BIM Bridge for Copilot Cowork

From the repository root on Windows, build the shared Revit connector with
`& .\eng\Build-RevitAdapters.ps1 -Version 2024 -Configuration Release`.
Use a disposable test document in a development Revit session loaded with that
build. The installed alpha.1 connector predates the units snapshot. Follow the
repository's read-only Host status and instance discovery workflow before
querying Revit. Select one instance explicitly and compute SHA-256 over the UTF-8
bytes of its exact connector document ID. Keep the original ID local because it
can contain the document path.

In PowerShell, inject a random URL-safe loopback bearer secret from your secret
store as `BIM_BRIDGE_COWORK_LOOPBACK_TOKEN`, then run:

```powershell
py -3 .\adapters\cowork\streamable_http.py --instance-id $instanceId --document-sha256 $documentHash --port 8765
```

POST JSON-RPC to `http://127.0.0.1:8765/mcp` with the bearer secret,
`Content-Type: application/json`, and `Accept: application/json, text/event-stream`.
Send `initialize`, `notifications/initialized`, `tools/list`, and
`tools/call` for `get_revit_test_document_units` with empty arguments.
Use the negotiated version in `MCP-Protocol-Version` after initialization.
The connector reports length, area, volume, and angle as Autodesk unit type IDs.
The HTTP process logs only the outcome of tool calls.

The adapter embeds the checkout Runtime and calls its existing document-info
operation directly. This avoids a general-purpose stdio tool proxy and permits
the Cowork surface to expose just the configured read. The Runtime still owns
instance selection, connector authentication, and capability policy.

## Package and upload

### Configure the local OAuth gateway

In Microsoft Entra, create or select a single-tenant resource app and expose
the delegated scope `api://<resource-app-id>/Mcp.Read`. Set the resource app
manifest's `api.requestedAccessTokenVersion` to `2`. Create or select a separate
OAuth client app, configure the Web redirect URI
`https://teams.microsoft.com/api/platform/v1.0/oAuthRedirect`, and grant it the
resource app's delegated permission. Complete tenant consent if prompted.
Use the test user's Entra object ID for the principal.

```powershell
py -3 -m venv .venv-cowork
& .\.venv-cowork\Scripts\python.exe -m pip install -r .\adapters\cowork\requirements-oauth.txt
& .\.venv-cowork\Scripts\python.exe .\adapters\cowork\oauth_gateway.py --tenant $tenantId --audience $resourceAppId --client $oauthClientId --principal $testUserObjectId
```

Inject the same `BIM_BRIDGE_COWORK_LOOPBACK_TOKEN` from your secret store into
both local processes. The gateway listens on `127.0.0.1:8766` and forwards
authenticated MCP requests to `127.0.0.1:8765`. It accepts only delegated
v2 access tokens for the configured test principal.

For a temporary test, start `cloudflared.exe tunnel --url http://127.0.0.1:8766`
after verifying the gateway locally. Keep that process running. Use its
`https://…trycloudflare.com/mcp` endpoint when configuring the OAuth
registration and packaging the ZIP. A new temporary hostname requires
updating the OAuth registration's Base URL and rebuilding the ZIP.

In the Teams Developer Portal, open **Tools → OAuth client registration → New
OAuth client registration**. Set Base URL to the public MCP URL, choose
**Any Teams app** and **My organization**, enter the Entra OAuth client ID
and secret in the portal, and leave PKCE enabled. Set authorization and token
endpoints to the tenant-specific `/oauth2/v2.0/authorize` and
`/oauth2/v2.0/token` endpoints on `login.microsoftonline.com`. Use the token
endpoint for refresh, with scope `api://<resource-app-id>/Mcp.Read offline_access`.
After saving, use the **OAuth client registration ID** as `--oauth-reference`.

[Microsoft OAuth registration instructions](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/plugin-authentication-oauth)

Use an organization-approved HTTPS OAuth gateway and tunnel. The gateway must
validate the incoming OAuth token and its issuer, audience and authorized
principal or scope before forwarding, replace the authorization header with the
loopback bearer secret, and set Host to the loopback listener. Preserve MCP
headers and JSON-RPC bodies. Point the tunnel at this gateway and forward only
its MCP route to port 8765. The Revit connector port stays local.

### Cloudflare Tunnel on Windows

Use a named tunnel in the organization-managed Cloudflare account. The
published route should match the approved hostname and `^/mcp$` and use
`http://127.0.0.1:8766` as its origin, assuming the OAuth gateway uses port
8766. The gateway forwards authorized MCP requests to
`http://127.0.0.1:8765/mcp`. Configure it to set the upstream Host to
`127.0.0.1:8765` and inject the loopback bearer from its secret store.
The Cloudflare tunnel credential connects `cloudflared` to Cloudflare.
Cowork uses the OAuth registration for client authentication.

For a locally managed tunnel, copy
`cloudflared.example.yml` to a local configuration file and fill in the
approved hostname, tunnel UUID and credential file location. Validate
the route before starting the tunnel:

```powershell
cloudflared tunnel --config $tunnelConfig ingress validate
cloudflared tunnel --config $tunnelConfig ingress rule "https://$mcpHost/mcp"
cloudflared tunnel --config $tunnelConfig ingress rule "https://$mcpHost/"
cloudflared tunnel --config $tunnelConfig run
```

The second rule check should select the catch-all 404. For a remotely managed
tunnel, configure the same hostname, path and origin in **Networking →
Tunnels → Published application routes**, then use the organization's
Windows connector enrollment procedure. Keep tunnel credentials out of the
repository and ZIP. Before uploading the package, verify that unauthenticated
requests receive an auth challenge or denial and that an authenticated MCP
call traverses the gateway and reaches the adapter. Confirm with IT whether
the hostname has an additional Cloudflare Access policy, since Cowork must be
able to complete the configured OAuth flow from its cloud service.

[Cloudflare Tunnel configuration](https://developers.cloudflare.com/tunnel/configuration/)

Register the OAuth client through Microsoft's supported workflow and supply
the Microsoft Enterprise Token Store registration reference, public MCP URL,
and developer privacy and terms URLs.

```powershell
py -3 .\adapters\cowork\package_plugin.py --mcp-url $mcpUrl --oauth-reference $oauthReference --privacy-url $privacyUrl --terms-url $termsUrl --output .\BimBridge-Cowork.zip
```

The ZIP contains a v1.28 manifest, two icons, and the single-tool description.
In Cowork select **Customize → Add → Upload a skill or plugin**, select the ZIP,
and choose **Only you**. Complete the OAuth sign-in when prompted. In a new
task, ask Cowork to call `get_revit_test_document_units` and report its result.
Verify the result against the selected Revit test document and the gateway's
redacted invocation evidence. Client handshake traffic alone is insufficient
to demonstrate that Cowork invoked the tool.

[Microsoft Cowork plugin development](https://learn.microsoft.com/en-us/copilot/cowork/cowork-plugin-development)
