param([string]$ScriptDir = $PSScriptRoot)

$ErrorActionPreference = "Stop"

# Load config
$configPath = Join-Path $ScriptDir "..\config.json"
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$port = $config.ports.agent

# Win32 API for window focus
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinUser {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
}
'@

function Send-Response {
    param($context, [int]$status, $body)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 5))
    $context.Response.StatusCode = $status
    $context.Response.ContentType = "application/json"
    $context.Response.Headers.Add("Access-Control-Allow-Origin", "*")
    $context.Response.ContentLength64 = $bytes.Length
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.OutputStream.Close()
}

function Get-Worktrees {
    param([string]$repoPath)
    try {
        $raw = & git -C $repoPath worktree list --porcelain 2>&1
        $worktrees = @()
        $cur = $null
        foreach ($line in $raw) {
            if ($line -match '^worktree (.+)$') {
                if ($cur) { $worktrees += $cur }
                $cur = @{ path = $Matches[1]; branch = ""; head = "" }
            } elseif ($line -match '^branch refs/heads/(.+)$') {
                if ($cur) { $cur.branch = $Matches[1] }
            } elseif ($line -match '^HEAD ([a-f0-9]+)$') {
                if ($cur) { $cur.head = $Matches[1].Substring(0, [Math]::Min(8, $Matches[1].Length)) }
            }
        }
        if ($cur) { $worktrees += $cur }
        return $worktrees
    } catch {
        return @()
    }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:${port}/")
$listener.Start()
Write-Host "Agent listening on http://localhost:${port}/"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $req  = $context.Request
        $path = $req.Url.AbsolutePath
        $method = $req.HttpMethod

        # Handle CORS preflight
        if ($method -eq "OPTIONS") {
            $context.Response.Headers.Add("Access-Control-Allow-Origin", "*")
            $context.Response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            $context.Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
            $context.Response.StatusCode = 204
            $context.Response.OutputStream.Close()
            continue
        }

        try {
            if ($path -eq "/focus" -and $method -eq "POST") {
                $body = [System.IO.StreamReader]::new($req.InputStream).ReadToEnd() | ConvertFrom-Json
                $hwnd = [IntPtr]$body.hwnd
                if ([WinUser]::IsWindow($hwnd)) {
                    [WinUser]::ShowWindow($hwnd, 9) | Out-Null  # SW_RESTORE
                    [WinUser]::SetForegroundWindow($hwnd) | Out-Null
                    Send-Response $context 200 @{ ok = $true }
                } else {
                    Send-Response $context 404 @{ ok = $false; error = "window handle invalid" }
                }
            }
            elseif ($path -eq "/launch" -and $method -eq "POST") {
                $body = [System.IO.StreamReader]::new($req.InputStream).ReadToEnd() | ConvertFrom-Json
                $launchPath = $body.path
                $label = $body.label
                # Escape single quotes to prevent command injection
                $safeLabel = "$label" -replace "'","''"
                $safePath  = "$launchPath" -replace "'","''"
                if (-not (Test-Path $launchPath)) {
                    Send-Response $context 400 @{ ok = $false; error = "path not found" }
                } else {
                    Start-Process powershell.exe -ArgumentList @(
                        "-NoExit",
                        "-Command",
                        "Set-Location '$safePath'; Write-Host 'Starting Claude - $safeLabel'; claude"
                    )
                    Send-Response $context 200 @{ ok = $true; path = $launchPath }
                }
            }
            elseif ($path -eq "/worktrees" -and $method -eq "GET") {
                $repoParam = $req.QueryString["repo"]
                if (-not $repoParam) {
                    # Return worktrees for all configured repos
                    $result = @{}
                    foreach ($repo in $config.repos) {
                        $result[$repo.name] = Get-Worktrees $repo.path
                    }
                    Send-Response $context 200 $result
                } else {
                    # Only allow paths that are in the configured repos list
                    $allowed = $config.repos | Where-Object { $_.path -eq $repoParam }
                    if (-not $allowed) {
                        Send-Response $context 403 @{ error = "repo path not in allowlist" }
                    } else {
                        Send-Response $context 200 (Get-Worktrees $repoParam)
                    }
                }
            }
            elseif ($path -eq "/health" -and $method -eq "GET") {
                Send-Response $context 200 @{ ok = $true; port = $port }
            }
            else {
                Send-Response $context 404 @{ error = "not found" }
            }
        } catch {
            try { Send-Response $context 500 @{ error = $_.Exception.Message } } catch {}
        }
    }
} finally {
    $listener.Stop()
}
