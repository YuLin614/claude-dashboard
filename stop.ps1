$scriptDir = $PSScriptRoot

Write-Host "Stopping Claude Dashboard..." -ForegroundColor Cyan

docker compose -f "$scriptDir\docker-compose.yml" down

$job = Get-Job -Name "claude-dashboard-agent" -ErrorAction SilentlyContinue
if ($job) { Stop-Job $job; Remove-Job $job }

Write-Host "Stopped." -ForegroundColor Green
