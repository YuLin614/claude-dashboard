$scriptDir = $PSScriptRoot
$pidFile   = "$scriptDir\.agent-pid"

Write-Host "Stopping Claude Dashboard..." -ForegroundColor Cyan

docker compose -f "$scriptDir\docker-compose.yml" down

if (Test-Path $pidFile) {
    $agentPid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($agentPid) { Stop-Process -Id $agentPid -Force -ErrorAction SilentlyContinue }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

Write-Host "Stopped." -ForegroundColor Green
