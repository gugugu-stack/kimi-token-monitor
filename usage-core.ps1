$script:eventsDir = Join-Path $env:USERPROFILE '.kimi-code\server\events'
$script:files = @{}
$script:chunkBytes = 4194304

# Pair a line's envelope timestamp with a usage object that carries cache-read
# counters. The bounded [^\r\n] guard keeps every match inside one line.
$script:rxPair = [regex]'"timestamp":"([^"]+)"[^\r\n]{0,400000}?"usage":\{([^{}]*?"inputCacheRead"[^{}]*?)\}'

function Format-Tokens {
    param([int64]$n)
    # One decimal place in every unit, so the widest value is six characters
    # ("999.9M") and the value column stays narrow. The unit is stepped up a
    # little before its boundary (999.95) so a rounded "1000.0K" can never
    # appear. Fixed-point, not "N", which would insert a thousands separator.
    if ($n -ge 999950000) { return ('{0:F1}B' -f ($n / 1000000000.0)) }
    if ($n -ge 999950)    { return ('{0:F1}M' -f ($n / 1000000.0)) }
    if ($n -ge 1000)      { return ('{0:F1}K' -f ($n / 1000.0)) }
    return ('{0:F0}' -f $n)
}

function Read-Field {
    param([string]$Body, [string]$Name)
    $m = [regex]::Match($Body, '"' + $Name + '"\s*:\s*(\d+)')
    if ($m.Success) { return [int64]$m.Groups[1].Value }
    return [int64]0
}

function Get-LocalDateKey {
    param([string]$Iso)
    try {
        $dt = [datetime]::Parse($Iso, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return $dt.ToLocalTime().ToString('yyyy-MM-dd')
    } catch {
        return $null
    }
}

function Get-EventFiles {
    return @(Get-ChildItem -LiteralPath $script:eventsDir -Filter 'session_*.jsonl' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending)
}

function Get-NewestFile {
    $f = Get-EventFiles | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

# Which conversation to show. "Most recently written events file" is the only
# signal that turned out to be reliable: the events files change when a turn runs,
# so switching to an older conversation is not visible until something is said in
# it. A log-based attempt (the renderer logs every re-subscription) was tried and
# withdrawn — the renderer subscribes to more than just the visible conversation,
# so the newest subscription is not necessarily the open one, and it showed 0.
function Get-ActiveFile {
    return (Get-NewestFile)
}

function Update-Scan {
    param([int64]$BudgetBytes = 8388608)

    $list = Get-EventFiles
    $existing = @{}
    foreach ($fi in $list) { $existing[$fi.FullName] = $true }
    foreach ($k in @($script:files.Keys)) {
        if (-not $existing.ContainsKey($k)) { $script:files.Remove($k) }
    }

    $remain = $BudgetBytes
    foreach ($fi in $list) {
        if ($remain -le 0) { break }
        $path = $fi.FullName
        if (-not $script:files.ContainsKey($path)) {
            $script:files[$path] = @{ Offset = [int64]0; Buckets = @{}; Complete = $false }
        }
        $state = $script:files[$path]

        $len = $fi.Length
        if ($len -lt $state.Offset) { $state.Offset = [int64]0; $state.Buckets = @{} }
        if ($len -eq $state.Offset) { $state.Complete = $true; continue }

        $fs = $null
        try {
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $window = $script:chunkBytes
            while ($state.Offset -lt $len -and $remain -gt 0) {
                $count = [int][Math]::Min([int64]$window, $len - $state.Offset)
                [void]$fs.Seek($state.Offset, [System.IO.SeekOrigin]::Begin)
                $buf = New-Object byte[] $count
                $read = $fs.Read($buf, 0, $count)
                if ($read -le 0) { break }

                $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                $nl = $text.LastIndexOf("`n")
                if ($nl -lt 0) {
                    if (($state.Offset + $read) -ge $len) { break }
                    $window = [Math]::Min($window * 2, 67108864)
                    continue
                }

                $chunk = $text.Substring(0, $nl)
                $consumed = [int64]([System.Text.Encoding]::UTF8.GetByteCount($chunk) + 1)

                foreach ($m in $script:rxPair.Matches($chunk)) {
                    $body = $m.Groups[2].Value
                    if ($body.Length -eq 0 -or $body -notmatch '"inputCacheRead"') { continue }
                    $key = Get-LocalDateKey $m.Groups[1].Value
                    if (-not $key) { continue }
                    if (-not $state.Buckets.ContainsKey($key)) {
                        $state.Buckets[$key] = @{ Input = [int64]0; Output = [int64]0; Read = [int64]0; Create = [int64]0; Requests = [int64]0 }
                    }
                    $b = $state.Buckets[$key]
                    $b.Input  += Read-Field $body 'inputOther'
                    $b.Output += Read-Field $body 'output'
                    $b.Read   += Read-Field $body 'inputCacheRead'
                    $b.Create += Read-Field $body 'inputCacheCreation'
                    # One usage record is exactly one API request: each completed
                    # step carries its own stepId and no stepId repeats, so this
                    # is a count rather than an estimate.
                    $b.Requests = $b.Requests + 1
                }

                $state.Offset += $consumed
                $remain -= $consumed
                $window = $script:chunkBytes
            }
        } finally {
            if ($fs) { $fs.Dispose() }
        }
        $state.Complete = ($state.Offset -ge $len)
    }
}

function Get-RangeDates {
    param([string]$Mode)
    $today = (Get-Date).Date
    switch ($Mode) {
        '不限'    { return $null }
        '今天'    { return @($today.ToString('yyyy-MM-dd')) }
        '昨天'    { return @($today.AddDays(-1).ToString('yyyy-MM-dd')) }
        '近 3 天' { return @(0..2  | ForEach-Object { $today.AddDays(-$_).ToString('yyyy-MM-dd') }) }
        '近 7 天' { return @(0..6  | ForEach-Object { $today.AddDays(-$_).ToString('yyyy-MM-dd') }) }
        '近 30 天' { return @(0..29 | ForEach-Object { $today.AddDays(-$_).ToString('yyyy-MM-dd') }) }
        '本月' {
            $first = $today.AddDays(-($today.Day - 1))
            return @(0..($today.Day - 1) | ForEach-Object { $first.AddDays($_).ToString('yyyy-MM-dd') })
        }
        '上月' {
            $lastPrev = $today.AddDays(-($today.Day - 1)).AddDays(-1)
            $firstPrev = $lastPrev.AddDays(-($lastPrev.Day - 1))
            return @(0..($lastPrev.Day - 1) | ForEach-Object { $firstPrev.AddDays($_).ToString('yyyy-MM-dd') })
        }
        default { return $null }
    }
}

function Get-ScopeTotals {
    param([string]$Scope, $DateKeys)

    $total = @{ Input = [int64]0; Output = [int64]0; Read = [int64]0; Create = [int64]0; Requests = [int64]0 }

    if ($Scope -eq '当前会话') {
        $newest = Get-ActiveFile
        $paths = @()
        if ($newest) { $paths = @($newest) }
    } else {
        $paths = @(Get-EventFiles | ForEach-Object { $_.FullName })
    }

    $set = $null
    if ($DateKeys) {
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($d in $DateKeys) { [void]$set.Add($d) }
    }

    foreach ($p in $paths) {
        if (-not $script:files.ContainsKey($p)) { continue }
        $buckets = $script:files[$p].Buckets
        foreach ($k in $buckets.Keys) {
            if ($set -and -not $set.Contains($k)) { continue }
            $b = $buckets[$k]
            $total.Input  += $b.Input
            $total.Output += $b.Output
            $total.Read   += $b.Read
            $total.Create += $b.Create
            $total.Requests += $b.Requests
        }
    }
    return $total
}

function Test-ScanPending {
    param([string]$Scope)
    if ($Scope -eq '当前会话') {
        $newest = Get-ActiveFile
        if (-not $newest) { return $false }
        if (-not $script:files.ContainsKey($newest)) { return $true }
        return (-not $script:files[$newest].Complete)
    }
    foreach ($fi in (Get-EventFiles)) {
        $p = $fi.FullName
        if (-not $script:files.ContainsKey($p)) { return $true }
        if (-not $script:files[$p].Complete) { return $true }
    }
    return $false
}

function Get-HitRate {
    param($Totals)
    $denom = $Totals.Read + $Totals.Create + $Totals.Input
    if ($denom -le 0) { return -1.0 }
    return (100.0 * $Totals.Read / $denom)
}

# ---------- hit-rate colour policy ----------

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

$script:colRateNone = [System.Drawing.Color]::FromArgb(150, 150, 158)

function Convert-HslToColor {
    param([double]$H, [double]$S, [double]$L)
    $c = (1 - [Math]::Abs(2 * $L - 1)) * $S
    $hp = $H / 60.0
    $x = $c * (1 - [Math]::Abs(($hp % 2) - 1))
    if ($hp -lt 1)      { $r1 = $c; $g1 = $x; $b1 = 0 }
    elseif ($hp -lt 2)  { $r1 = $x; $g1 = $c; $b1 = 0 }
    elseif ($hp -lt 3)  { $r1 = 0; $g1 = $c; $b1 = $x }
    elseif ($hp -lt 4)  { $r1 = 0; $g1 = $x; $b1 = $c }
    elseif ($hp -lt 5)  { $r1 = $x; $g1 = 0; $b1 = $c }
    else                { $r1 = $c; $g1 = 0; $b1 = $x }
    $m = $L - $c / 2
    return [System.Drawing.Color]::FromArgb(
        [int][Math]::Round(($r1 + $m) * 255),
        [int][Math]::Round(($g1 + $m) * 255),
        [int][Math]::Round(($b1 + $m) * 255))
}

# Continuous green -> yellow -> red gradient across the band that actually
# matters. At or above 95% the cache is healthy; at or below 80% a long session
# has clearly lost its cache; the midpoint (yellow) lands near 87.5%. Outside
# the band the colour clamps, so the display never goes "more than red".
$script:RateGoodEdge = 95.0
$script:RateBadEdge  = 80.0

function Get-HitRateColor {
    param([double]$Rate)
    if ($Rate -lt 0) { return $script:colRateNone }
    $t = ($Rate - $script:RateBadEdge) / ($script:RateGoodEdge - $script:RateBadEdge)
    if ($t -lt 0) { $t = 0 }
    if ($t -gt 1) { $t = 1 }
    return (Convert-HslToColor (120.0 * $t) 0.70 0.55)
}
