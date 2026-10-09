$ErrorActionPreference = 'Stop'

# Removes the SessionStart hook this widget installed. The folder itself is left
# alone — delete it by hand once you are happy that nothing is running.

$kimiHome = if ($env:KIMI_CODE_HOME) { $env:KIMI_CODE_HOME } else { Join-Path $env:USERPROFILE '.kimi-code' }
$configPath = Join-Path $kimiHome 'config.toml'

Write-Host ''
Write-Host '  Kimi Code 用量悬浮窗 — 卸载' -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Host '  [错误] 没找到 config.toml，无需卸载。' -ForegroundColor Red
    exit 1
}

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

if ($removed -eq 0) {
    Write-Host '  配置里没有本插件的钩子，无需改动。'
    exit 0
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$configPath.bak-kimi-token-monitor-$stamp"
Copy-Item -LiteralPath $configPath -Destination $backup -Force

while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }
[System.IO.File]::WriteAllLines($configPath, $out.ToArray(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ("  [完成] 已移除 " + $removed + " 条钩子") -ForegroundColor Green
Write-Host ('  配置备份: ' + $backup)
Write-Host '  重启 Kimi Code 后生效。若不再需要，可直接删掉 kimi-token-monitor 文件夹。'
Write-Host ''
