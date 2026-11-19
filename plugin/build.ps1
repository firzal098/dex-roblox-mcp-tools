$ErrorActionPreference = "Stop"

Set-Location $PSScriptRoot

$rojoExe = "$env:USERPROFILE\.rokit\bin\rojo.exe"
if (-not (Test-Path $rojoExe)) {
    $rojoExe = "rojo"
}

Write-Host "[MCPBridge] Building plugin to local plugins folder..." -ForegroundColor Cyan
& $rojoExe build -p mcp.rbxmx

$targetPath = Join-Path "$env:LOCALAPPDATA\Roblox\Plugins" "mcp.rbxmx"
if (Test-Path $targetPath) {
    Write-Host "[MCPBridge] Successfully built plugin to: $targetPath" -ForegroundColor Green
} else {
    Write-Host "[MCPBridge] Warning: Expected output at $targetPath not found." -ForegroundColor Yellow
}
