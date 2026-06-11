param([switch]$NoBrowser)

$scriptDir = $PSScriptRoot

Write-Host "Starting Claude Dashboard..." -ForegroundColor Cyan

# Start Docker container
Write-Host "  Starting server (Docker)..."
docker compose -f "$scriptDir\docker-compose.yml" up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Docker failed. Is Docker Desktop running?" -ForegroundColor Red
    exit 1
}

# Start PS agent as background job (stop existing if running)
$existing = Get-Job -Name "claude-dashboard-agent" -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  Stopping previous agent..."
    Stop-Job $existing; Remove-Job $existing
}
Write-Host "  Starting host agent..."
Start-Job -Name "claude-dashboard-agent" `
    -FilePath "$scriptDir\host-agent\agent.ps1" `
    -ArgumentList $scriptDir | Out-Null

# Wait briefly for agent to start
Start-Sleep 2

# Verify
try {
    $health = Invoke-WebRequest "http://localhost:3334/health" -UseBasicParsing -TimeoutSec 3
    Write-Host "  Agent: OK" -ForegroundColor Green
} catch {
    Write-Host "  Agent: not responding (may still be starting)" -ForegroundColor Yellow
}

if (-not $NoBrowser) {
    Start-Process msedge "http://localhost:3333"
}

Write-Host ""
Write-Host "Claude Dashboard running at http://localhost:3333" -ForegroundColor Green
Write-Host "Run .\stop.ps1 to shut down."
