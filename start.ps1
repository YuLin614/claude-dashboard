param([switch]$NoBrowser)

$scriptDir = $PSScriptRoot
$pidFile   = "$scriptDir\.agent-pid"

Write-Host "Starting Claude Dashboard..." -ForegroundColor Cyan

# Start Docker container
Write-Host "  Starting server (Docker)..."
docker compose -f "$scriptDir\docker-compose.yml" up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Docker failed. Is Docker Desktop running?" -ForegroundColor Red
    exit 1
}

# Kill previous agent if PID file exists
if (Test-Path $pidFile) {
    $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($oldPid) { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

# Start agent as a hidden background process (survives across PS sessions)
Write-Host "  Starting host agent..."
$proc = Start-Process powershell.exe -ArgumentList @(
    "-ExecutionPolicy", "Bypass",
    "-WindowStyle", "Hidden",
    "-File", "$scriptDir\host-agent\agent.ps1"
) -PassThru -WindowStyle Hidden
$proc.Id | Set-Content $pidFile

Start-Sleep 2

try {
    Invoke-WebRequest "http://localhost:3334/health" -UseBasicParsing -TimeoutSec 3 | Out-Null
    Write-Host "  Agent: OK" -ForegroundColor Green
} catch {
    Write-Host "  Agent: not responding (may still be starting)" -ForegroundColor Yellow
}

if (-not $NoBrowser) {
    # Launch PyWebView app window (native, always-on-top)
    Start-Process pythonw.exe -ArgumentList "$scriptDir\app.py" -WorkingDirectory $scriptDir
    Write-Host "  Dashboard window: launching..." -ForegroundColor Green
}

Write-Host ""
Write-Host "Claude Dashboard running at http://localhost:3333" -ForegroundColor Green
Write-Host "Run .\stop.ps1 to shut down."
