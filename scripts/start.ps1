# Starts the dashboard. It launches the proxy and the demo backends itself
# when you press "Launch demo", and stops them when you stop this script.
$root = Split-Path -Parent $PSScriptRoot
Push-Location "$root\dashboard"
Write-Host "Open http://localhost:3000 and press 'Launch demo'"
npm run dev
Pop-Location
