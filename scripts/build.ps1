# Builds everything the dashboard needs: the proxy, the demo backend, the dashboard deps.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

Push-Location "$root\crystal-proxy"
New-Item -ItemType Directory -Force bin | Out-Null
crystal build --release src/main.cr -o bin/crystal-proxy
Pop-Location

Push-Location "$root\demo-backend"
dotnet build -c Release -o out
Pop-Location

Push-Location "$root\dashboard"
npm install
Pop-Location

Write-Host "`nBuilt. Start the lab with:  ./scripts/start.ps1"
