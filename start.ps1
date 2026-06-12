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
    # Open as floating app window (no browser chrome, always-on-top)
    $edgeProc = Start-Process msedge.exe -ArgumentList @(
        "--app=http://localhost:3333",
        "--window-size=380,720",
        "--window-position=1540,0"
    ) -PassThru

    Start-Sleep 2

    # Set always-on-top via Win32 API
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class FloatWin {
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
}
'@ -ErrorAction SilentlyContinue

    try {
        $hwnd = $edgeProc.MainWindowHandle
        if ($hwnd -ne [IntPtr]::Zero) {
            [FloatWin]::SetWindowPos($hwnd, [FloatWin]::HWND_TOPMOST, 0, 0, 0, 0,
                [FloatWin]::SWP_NOMOVE -bor [FloatWin]::SWP_NOSIZE) | Out-Null
            Write-Host "  Dashboard: floating window OK" -ForegroundColor Green
        }
    } catch {}
}

Write-Host ""
Write-Host "Claude Dashboard running at http://localhost:3333" -ForegroundColor Green
Write-Host "Run .\stop.ps1 to shut down."
