$ErrorActionPreference = 'Stop'

# Installs the usage widget into this machine's Kimi Code config: it only writes
# the SessionStart hook, so the folder can be copied anywhere and this script is
# what makes it take effect. Re-running it is safe — an existing hook written by
# a previous install (any path) is replaced, not duplicated.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$needed = @('start-widget.ps1', 'usage-widget.ps1', 'usage-core.ps1', 'pet-render.ps1', 'hotkey.ps1')

Write-Host ''
Write-Host '  Kimi Code 用量悬浮窗 — 安装' -ForegroundColor Cyan
Write-Host ('  目录: ' + $here)
Write-Host ''

$missing = @()
foreach ($f in $needed) {
    if (-not (Test-Path -LiteralPath (Join-Path $here $f))) { $missing += $f }
}
if ($missing.Count -gt 0) {
    Write-Host ('  [错误] 缺少文件: ' + ($missing -join ', ')) -ForegroundColor Red
    Write-Host '  请把整个 kimi-token-monitor 文件夹一起拷过来，不要只拷其中几个文件。'
    exit 1
}

$kimiHome = if ($env:KIMI_CODE_HOME) { $env:KIMI_CODE_HOME } else { Join-Path $env:USERPROFILE '.kimi-code' }
$configPath = Join-Path $kimiHome 'config.toml'
Write-Host ('  Kimi Code 配置: ' + $configPath)

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Host '  [错误] 没找到 config.toml。' -ForegroundColor Red
    Write-Host '  请先启动一次 Kimi Code 让它生成配置，然后再运行本安装。'
    exit 1
}

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launcher = Join-Path $here 'start-widget.ps1'

# Forward slashes: that is the form this hook has actually been verified with.
$psF = $ps -replace '\\', '/'
$launcherF = $launcher -replace '\\', '/'

# The host spawns the command line directly, so absolute paths are required. The
# plain form is the one that has been verified; quoting is used only when a path
# actually contains a space.
if (($psF -match ' ') -or ($launcherF -match ' ')) {
    $line = "command = `"'$psF`" -NoProfile -ExecutionPolicy Bypass -File `"$launcherF`"`""
    Write-Host '  [注意] 路径含空格，已改用带引号的写法（该写法未在含空格路径上实测）。' -ForegroundColor Yellow
} else {
    $line = 'command = "' + $psF + ' -NoProfile -ExecutionPolicy Bypass -File ' + $launcherF + '"'
}

# Read the config as lines and drop any [[hooks]] block that mentions this widget.
$lines = [System.IO.File]::ReadAllLines($configPath)
$out = New-Object System.Collections.Generic.List[string]
$removed = 0
$i = 0
while ($i -lt $lines.Count) {
    if ($lines[$i].Trim() -eq '[[hooks]]') {
        $j = $i + 1
        while ($j -lt $lines.Count -and -not $lines[$j].TrimStart().StartsWith('[')) { $j++ }
        $block = $lines[$i..($j - 1)]
        # Recognised by the script it launches, never by the folder name: the
        # folder can be renamed or cloned anywhere, while the hook always runs
        # start-widget.ps1 from wherever the folder happens to sit.
        if (($block -join "`n") -like '*start-widget.ps1*') {
            $removed++
            $i = $j
            continue
        }
        foreach ($b in $block) { $out.Add($b) }
        $i = $j
        continue
    }
    $out.Add($lines[$i])
    $i++
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$configPath.bak-kimi-token-monitor-$stamp"
Copy-Item -LiteralPath $configPath -Destination $backup -Force

while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }
$out.Add('')
$out.Add('[[hooks]]')
$out.Add('event = "SessionStart"')
$out.Add($line)
$out.Add('timeout = 15')

[System.IO.File]::WriteAllLines($configPath, $out.ToArray(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ("  [完成] 已写入 SessionStart 钩子（替换了 " + $removed + " 条旧配置）") -ForegroundColor Green
Write-Host ('  配置备份: ' + $backup)
Write-Host ''
Write-Host '  下一步：重启 Kimi Code（钩子在会话启动时才加载，/reload 不生效）。'
Write-Host '  重启后小球或面板会自动出现。'
Write-Host ''
