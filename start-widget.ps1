$ErrorActionPreference = 'SilentlyContinue'

# Hook entry point. The host pipes a JSON event payload on stdin; drain it so the
# caller is never blocked, then make sure exactly one widget process is alive.
$payload = ''
if ([Console]::IsInputRedirected) { $payload = [Console]::In.ReadToEnd() }

# Only the desktop client gets a floating window; the terminal TUI would find it
# intrusive. Anything else (or an unknown client) is treated as the desktop.
$client = ''
$m = [regex]::Match($payload, '"client_type"\s*:\s*"([^"]+)"')
if ($m.Success) { $client = $m.Groups[1].Value }
if ($client -eq 'kimi_code_cli') { exit 0 }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $here 'widget.pid'
$widget = Join-Path $here 'usage-widget.ps1'

# Single-instance guard. The pid file alone is not enough: if it goes missing or
# stale (a half-finished restart, a manual cleanup, a crash) the guard would
# happily spawn a second widget, and two instances each showing their own ball
# looks like a rendering bug. So scan the process table as well.
function Test-WidgetRunning {
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"
    foreach ($p in $procs) {
        if ($p.CommandLine -like "*$widget*") { return $true }
    }
    return $false
}

if (-not (Test-WidgetRunning)) {
    $p = Start-Process -FilePath 'powershell.exe' `
                       -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $widget) `
                       -WindowStyle Hidden -PassThru
    if ($p) { Set-Content -LiteralPath $pidFile -Value $p.Id -Encoding ascii }
} else {
    # keep the pid file pointing at whatever is actually running
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"
    foreach ($p in $procs) {
        if ($p.CommandLine -like "*$widget*") {
            Set-Content -LiteralPath $pidFile -Value $p.ProcessId -Encoding ascii
        }
    }
}

exit 0
