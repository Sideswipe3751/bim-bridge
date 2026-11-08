[CmdletBinding()]
param(
    [ValidateSet('mcp-servers', 'cordis-patch')]
    [string]$Style = 'mcp-servers',
    [string]$ServerName = 'bim-bridge'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$launcher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Start-BimBridgeDshMcp.ps1'))
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "DeepSeek Harness BIM Bridge launcher is missing: $launcher"
}

# The launcher's own directory, i.e. the bundle directory the operator copied.
# Deriving it by walking up a fixed number of levels made the generated `cwd`
# depend on the copy depth: a bundle copied to a shallower or deeper location
# produced a `cwd` outside the bundle (or a directory that no longer exists),
# and the DeepSeek Harness stdio transport hands `cwd` straight to cross-spawn,
# where a missing directory fails the spawn with ENOENT. $PSScriptRoot exists by
# construction - this script is running from it.
$launcherRoot = [IO.Path]::GetFullPath($PSScriptRoot)

# DeepSeek Harness does not read an MCP server file of its own: MCP servers are
# registered as `@deepseek-ai/dsh-mcp-client` rows in a profile's composed
# Cordis configuration. Both styles below therefore describe the same single
# stdio server; `mcp-servers` matches the shape the other BIM Bridge adapters
# template, and `cordis-patch` is the row DeepSeek Harness actually loads.
function Get-ServerDefinition {
    [ordered]@{
        transport = 'stdio'
        command = 'powershell.exe'
        args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $launcher)
        cwd = $launcherRoot
        toolCallTimeoutMs = 60000
    }
}

switch ($Style) {
    'mcp-servers' {
        # Strict JSON: a single line so the output is machine-parseable and
        # diff-stable.
        $document = [ordered]@{
            mcpServers = [ordered]@{
                $ServerName = Get-ServerDefinition
            }
        }
        ($document | ConvertTo-Json -Depth 8 -Compress)
    }
    'cordis-patch' {
        $server = Get-ServerDefinition
        $argumentList = (@($server.args) | ForEach-Object { "'" + $_ + "'" }) -join ', '
        $lines = @(
            '- insert:'
            '    - id: mcp-bim-bridge'
            "      name: '@deepseek-ai/dsh-mcp-client'"
            '      config:'
            "        serverName: $ServerName"
            "        transport: $($server.transport)"
            "        command: $($server.command)"
            "        args: [$argumentList]"
            "        cwd: '$($server.cwd)'"
            "        toolCallTimeoutMs: $($server.toolCallTimeoutMs)"
            '        failOnStartupError: true'
        )
        ($lines -join [Environment]::NewLine)
    }
}
