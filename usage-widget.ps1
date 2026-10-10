param()

$ErrorActionPreference = 'Stop'

# Single instance. Two widgets each drawing their own ball and panel looks like a
# rendering bug, and the launcher's process scan can misjudge when a WMI query
# fails, so the claim is made here with a session-local mutex — the OS guarantees
# only one holder, and the claim is released automatically when the process dies.
$script:instanceMutex = New-Object System.Threading.Mutex($false, 'Local\KimiUsageWidget')
if (-not $script:instanceMutex.WaitOne(0)) { exit 0 }

# DPI awareness, claimed before any window exists.
#
# Without it the process draws at 96 DPI and Windows stretches the finished
# window by the monitor's scale factor (150% here), so every glyph arrives on
# screen as a resampled bitmap and looks soft next to natively drawn UI. With
# it the surface is physical and text is hinted against the real pixel grid.
# Point-sized fonts then scale themselves; the hand-tuned pixel geometry below
# goes through Px() so the layout keeps its proportions either way.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Dpi {
    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("shcore.dll")] private static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] private static extern uint GetDpiForSystem();
    // Returns which call worked, 0 if none did.
    public static int Apply() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return 1; } catch { }  // PER_MONITOR_AWARE_V2
        try { if (SetProcessDpiAwareness(2) == 0) return 2; } catch { }                 // PER_MONITOR_DPI_AWARE
        try { if (SetProcessDPIAware()) return 3; } catch { }                           // SYSTEM_DPI_AWARE
        return 0;
    }
    public static int SystemDpi() { try { return (int)GetDpiForSystem(); } catch { return 96; } }
}
'@

$script:DpiMode = [Dpi]::Apply()
# If awareness could not be claimed the process stays virtualised, and then the
# coordinates really are 96 DPI — scale 1 keeps that case exactly as it was.
$script:UiScale = if ($script:DpiMode -gt 0) { [Dpi]::SystemDpi() / 96.0 } else { 1.0 }

# Every literal pixel size in this file is written in 96 DPI units and handed to
# this function, which is what keeps the two cases identical in appearance.
function Px {
    param([double]$Value)
    return [int][Math]::Round($Value * $script:UiScale)
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Numbers and Latin text use the same face the desktop client uses for them
# (Schibsted Grotesk), so the widget matches the client rather than merely
# resembling it; Chinese stays on the family the client uses for Chinese.
# The pair is loaded privately — nothing is installed system-wide and the files
# live in this folder. Both are SIL OFL, see fonts/OFL.txt. If they are missing
# the widget falls back to the UI font for numbers and looks as it did before.
$script:numFamily = $null
$script:fontCollection = $null
try {
    $pfc = New-Object System.Drawing.Text.PrivateFontCollection
    foreach ($file in @('fonts\SchibstedGrotesk-Regular.ttf', 'fonts\SchibstedGrotesk-Bold.ttf')) {
        $path = Join-Path $PSScriptRoot $file
        if (Test-Path -LiteralPath $path) { $pfc.AddFontFile($path) }
    }
    if ($pfc.Families.Count -gt 0) {
        # Regular and Bold share one family name, which is what lets the two
        # files be addressed as one family with two styles.
        $script:numFamily = $pfc.Families[0]
        $script:fontCollection = $pfc
    }
} catch { $script:numFamily = $null }

. (Join-Path $PSScriptRoot 'usage-core.ps1')
. (Join-Path $PSScriptRoot 'pet-render.ps1')
. (Join-Path $PSScriptRoot 'hotkey.ps1')

# One family across every surface. Noto Sans SC is safe to swap in because its
# CJK glyphs are the same full width as Microsoft YaHei's, so the fixed-width
# label and value columns below keep their alignment.
$fontUI    = New-Object System.Drawing.Font('Noto Sans SC', 9)
$fontBold  = New-Object System.Drawing.Font('Noto Sans SC', 9, [System.Drawing.FontStyle]::Bold)
$fontHead  = New-Object System.Drawing.Font('Noto Sans SC', 10.5, [System.Drawing.FontStyle]::Bold)
$fontSmall = New-Object System.Drawing.Font('Noto Sans SC', 7.5)

# Every value the panel shows is digits and units, so it takes the client's Latin
# face too; the labels beside them stay Chinese. Falls back to the UI font when
# the private pair could not be loaded.
$fontNum     = if ($script:numFamily) { New-Object System.Drawing.Font($script:numFamily, 9) } else { $fontUI }
$fontNumBold = if ($script:numFamily) { New-Object System.Drawing.Font($script:numFamily, 9, [System.Drawing.FontStyle]::Bold) } else { $fontBold }

$colBg        = [System.Drawing.Color]::FromArgb(31, 31, 35)
$colCombo     = [System.Drawing.Color]::FromArgb(48, 48, 54)
$colSel       = [System.Drawing.Color]::FromArgb(70, 70, 80)
$colFg        = [System.Drawing.Color]::FromArgb(232, 232, 234)
$colDim       = [System.Drawing.Color]::FromArgb(150, 150, 158)
$colWarn      = [System.Drawing.Color]::FromArgb(220, 180, 80)
# Chroma-key for the pet: everything painted this colour never shows, so the
# ball floats on the desktop instead of sitting on a dark rectangle.
$colPetKey    = [System.Drawing.Color]::FromArgb(24, 24, 27)

$script:brushFg    = New-Object System.Drawing.SolidBrush($colFg)
$script:brushCombo = New-Object System.Drawing.SolidBrush($colCombo)
$script:brushSel   = New-Object System.Drawing.SolidBrush($colSel)

$script:PanelW = (Px 312)

# The cache-write row is part of the grid now rather than a row that appears and
# disappears, so the panel has one fixed size. The scan still runs here so the
# first paint has data to show instead of counting up from "统计中…".
Update-Scan -BudgetBytes 1073741824

function Get-PanelHeight {
    return (Px 158)
}
$script:PanelH = Get-PanelHeight

# ---------- persisted state ----------

# One shared position: the two modes inherit each other's location, so there is
# nothing to remember per mode. The default sits in the bottom-right corner.
$statePath = Join-Path $PSScriptRoot 'widget.state.json'
$script:diagPath = Join-Path $PSScriptRoot 'diag.log'

function Get-DefaultPosition {
    param([int]$W, [int]$H)
    $a = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $m = Px 16
    return (New-Object System.Drawing.Point(($a.Right - $W - $m), ($a.Bottom - $H - $m)))
}

# Keep the window fully on the monitor that contains the anchor point.
function Fit-ToMonitor {
    param([System.Drawing.Point]$Point, [int]$W, [int]$H)
    $screen = [System.Windows.Forms.Screen]::FromPoint($Point)
    $a = $screen.WorkingArea
    $x = [Math]::Max($a.Left, [Math]::Min($Point.X, $a.Right - $W))
    $y = [Math]::Max($a.Top, [Math]::Min($Point.Y, $a.Bottom - $H))
    return (New-Object System.Drawing.Point($x, $y))
}

# The two windows anchor to each other by their BOTTOM-RIGHT corner, not their
# top-left. They differ in size, so anchoring the corner that stays put when the
# window grows means a round trip returns to exactly where it started; anchoring
# the top-left would shift the smaller window by the size difference every time.
function Get-AnchoredLocation {
    param([System.Drawing.Point]$BottomRight, [int]$W, [int]$H)
    $p = New-Object System.Drawing.Point(($BottomRight.X - $W), ($BottomRight.Y - $H))
    return (Fit-ToMonitor $p $W $H)
}

$script:mode = 'panel'
$script:startPos = $null
$script:petAnchor = $null
$script:panelAnchor = $null

if (Test-Path -LiteralPath $statePath) {
    try {
        $st = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($st.mode -eq 'pet') { $script:mode = 'pet' }
        if ($null -ne $st.x -and $null -ne $st.y) {
            # Coordinates are physical now. A file written before that change has
            # no scale marker and holds 96 DPI values, so it is converted once
            # here — otherwise the widget would jump to the wrong corner.
            $from = if ($null -ne $st.scale) { [double]$st.scale } else { 1.0 }
            $k = $script:UiScale / $from
            $script:startPos = New-Object System.Drawing.Point(
                [int][Math]::Round($st.x * $k), [int][Math]::Round($st.y * $k))
        }
    } catch { }
}

if (-not $script:startPos) {
    if ($script:mode -eq 'pet') { $script:startPos = Get-DefaultPosition $script:PetWindow $script:PetWindow }
    else                        { $script:startPos = Get-DefaultPosition $script:PanelW $script:PanelH }
}
if ($script:mode -eq 'pet') { $script:startPos = Fit-ToMonitor $script:startPos $script:PetWindow $script:PetWindow }
else                        { $script:startPos = Fit-ToMonitor $script:startPos $script:PanelW $script:PanelH }

# Settings live in their own file: the position changes on every drag, while
# these are only written from the settings window.
$settingsPath = Join-Path $PSScriptRoot 'widget.settings.json'
$script:DefaultHotkeyMods = 3    # MOD_CONTROL | MOD_ALT
$script:DefaultHotkeyKey = 75    # VK_K
$script:hotkeyMods = $script:DefaultHotkeyMods
$script:hotkeyKey = $script:DefaultHotkeyKey

if (Test-Path -LiteralPath $settingsPath) {
    try {
        $sg = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        # A stored 0 means "no key" and is left alone rather than silently
        # replaced by the default.
        if ($null -ne $sg.hotkeyMods -and $null -ne $sg.hotkeyKey) {
            $script:hotkeyMods = [int]$sg.hotkeyMods
            $script:hotkeyKey = [int]$sg.hotkeyKey
        }
    } catch { }
}

function Save-Settings {
    $obj = [ordered]@{
        hotkeyMods = $script:hotkeyMods
        hotkeyKey  = $script:hotkeyKey
    }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
}

function Save-State {
    $active = if ($script:mode -eq 'pet') { $pet } else { $form }
    $obj = [ordered]@{
        mode = $script:mode
        x    = $active.Location.X
        y    = $active.Location.Y
        # Which DPI the coordinates were measured at, so a later run on a
        # differently scaled display can convert them instead of guessing.
        scale = $script:UiScale
    }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

# ---------- panel form ----------

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
# Positions are computed here in physical pixels; letting WinForms also rescale
# them by font metrics would apply the DPI factor a second time.
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.Location = $script:startPos
$form.Size = New-Object System.Drawing.Size($script:PanelW, $script:PanelH)
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = $colPetKey
$form.Text = 'Kimi Code 用量'

# The content layer's own background must be chroma-keyed away, otherwise its
# opaque fill would simply cover the translucent layer underneath and the whole
# point of stacking would be lost. Labels keep BackColor = Transparent, which
# renders this same key colour and therefore also disappears; only their glyphs,
# the drawn border, the icons and the ComboBoxes stay opaque.
$form.TransparencyKey = $colPetKey

# The panel is two stacked windows. Only the background layer carries Opacity, so
# the desktop shows through it; the content layer keeps its own alpha at 1 so the
# text, border, icons and drop-downs stay perfectly crisp. A single window cannot
# do this: Opacity is applied to the whole composited surface, which is exactly
# why the text went translucent before.
$script:PanelOpacity = 0.70

# Rounded panel via the Win11 DWM corner preference. The earlier SetWindowRgn
# approach rounded by clipping the window with a hard-edged region, and a region
# has no antialiasing: the stepped corner showed up as a jagged bright arc
# whenever something brighter sat behind the translucent panel. DWM rounds the
# composited window instead, with antialiasing. Verified on a throwaway window
# with the same style before switching — a tool window (ShowInTaskbar = false)
# does get rounded, and the rounding is visible in a window capture.
$script:PanelRadius = 8

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Dwm {
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int val, int size);
    // DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_ROUND = 2
    public static int SetRound(IntPtr h) { int v = 2; return DwmSetWindowAttribute(h, 33, ref v, 4); }
    public static int GetRound(IntPtr h) { int v = -1; try { DwmGetWindowAttribute(h, 33, out v, 4); } catch { } return v; }
}
'@


Add-Type @'
using System;
using System.Runtime.InteropServices;
public class ZOrder {
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetTopWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr h, int i, int v);
    // Walks the z order downwards looking for the first of the two handles.
    public static string WhichIsAbove(IntPtr a, IntPtr b) {
        IntPtr cur = GetTopWindow(IntPtr.Zero);
        for (int i = 0; i < 200 && cur != IntPtr.Zero; i++) {
            if (cur == a) return "first";
            if (cur == b) return "second";
            cur = GetWindow(cur, 2);
        }
        return "neither";
    }
    // Clicking a topmost window activates it and lifts it to the front of the
    // topmost band. The background layer must never do that, or it ends up
    // covering the text; WS_EX_NOACTIVATE also means the widget never steals
    // focus from whatever the user is typing in.
    public static void MakeNoActivate(IntPtr h) {
        SetWindowLong(h, -20, GetWindowLong(h, -20) | 0x08000000);
        SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, 0x1 | 0x2 | 0x4 | 0x20); // NOSIZE|NOMOVE|NOZORDER|FRAMECHANGED
    }
    public static bool IsNoActivate(IntPtr h) { return (GetWindowLong(h, -20) & 0x08000000) != 0; }
}
'@

[void]$form.Handle
[void][Dwm]::SetRound($form.Handle)

# Background layer: a plain rounded slab of the panel colour at 70% alpha. It has
# no chroma key, so it receives the mouse everywhere inside the rounded region —
# which is what makes dragging, icon hover and icon clicks work even though the
# content layer above is transparent in those places.
$bg = New-Object System.Windows.Forms.Form
$bg.FormBorderStyle = 'None'
$bg.StartPosition = 'Manual'
$bg.Location = $script:startPos
$bg.Size = New-Object System.Drawing.Size($script:PanelW, $script:PanelH)
$bg.TopMost = $true
$bg.ShowInTaskbar = $false
$bg.BackColor = $colBg
$bg.Text = 'Kimi Code 用量 (bg)'
$bg.Opacity = $script:PanelOpacity
[void]$bg.Handle
[void][Dwm]::SetRound($bg.Handle)
# Clicking must not raise this layer above the content layer it sits behind.
[ZOrder]::MakeNoActivate($bg.Handle)

function Set-PanelGeometry {
    param([System.Drawing.Point]$Location, [int]$PanelWidth, [int]$PanelHeight)
    $script:PanelH = $PanelHeight
    foreach ($win in @($bg, $form)) {
        $win.Size = New-Object System.Drawing.Size($PanelWidth, $PanelHeight)
        $win.Location = $Location
        [void][Dwm]::SetRound($win.Handle)
    }
}

# WS_EX_NOACTIVATE stops the background layer from becoming the foreground
# window, but it does NOT stop Windows from lifting it to the front of the
# topmost band when it is clicked — which puts the translucent slab over the
# text. Activation is what lifts it, so the layering is re-asserted whenever
# activation happens. One call: drop the background back under the content.
function Assert-PanelZOrder {
    if (-not $form.Visible) { return }
    [void][ZOrder]::SetWindowPos($bg.Handle, $form.Handle, 0, 0, 0, 0, 0x1 -bor 0x2 -bor 0x10)
}

function Show-PanelWindows {
    $bg.Show()
    $form.Show()
    # Re-apply after the windows are visible: DWM ignores the corner preference
    # on a window that has not been shown yet in some cases, and both layers must
    # round identically or the corners of the slab and the content would disagree.
    [void][Dwm]::SetRound($bg.Handle)
    [void][Dwm]::SetRound($form.Handle)
    Assert-PanelZOrder
}

function Hide-PanelWindows {
    $form.Hide()
    $bg.Hide()
}

# Header icons: a settings triangle, a minimise dash and a multiply sign. The
# icons are drawn rather than typed: a dash and a multiplication sign carry very
# different weights at the same font size, which is what made the two buttons
# look mismatched. Drawing gives each the same 9px span and stroke.
$script:iconCfg   = New-Object System.Drawing.Rectangle((Px 242), (Px 8), (Px 18), (Px 18))
$script:iconMin   = New-Object System.Drawing.Rectangle((Px 264), (Px 8), (Px 18), (Px 18))
$script:iconClose = New-Object System.Drawing.Rectangle((Px 286), (Px 8), (Px 18), (Px 18))
$script:hoverIcon = ''
$script:panelDragged = $false

# Hover feedback is repainted one icon at a time rather than by invalidating the
# whole panel: a full invalidation of a chroma-keyed window shows the transparent
# erase for a frame, which is the blink the ball used to suffer from.
function Invalidate-PanelIcons {
    foreach ($r in @($script:iconCfg, $script:iconMin, $script:iconClose)) { $form.Invalidate($r) }
}

$form.Add_Paint({
    $g = $_.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    # No decorative outline is drawn. Three rounds of feedback landed on the same
    # spot: a 1px light stroke around a translucent panel is more conspicuous than
    # it looks in isolation — the arc along the hard-clipped corner worst of all —
    # so the panel is left with just its own edge. If a rim is ever wanted back,
    # the cheap version is a single colour one step brighter than $colBg.

    foreach ($pair in @(
            @{ R = $script:iconCfg;   K = 'cfg' },
            @{ R = $script:iconMin;   K = 'min' },
            @{ R = $script:iconClose; K = 'close' })) {
        $col = if ($script:hoverIcon -eq $pair.K) { $colFg } else { $colDim }
        # Glyph geometry is derived from the box rather than written in pixels,
        # so it looks the same at any DPI: a stroke spans half the box and the
        # pen is 1.6/18 of it.
        $box = $pair.R.Width
        $cx = $pair.R.X + $box / 2.0
        $cy = $pair.R.Y + $box / 2.0
        $span = $box / 4.0
        if ($pair.K -eq 'cfg') {
            # A filled triangle, matching the ▼ the settings entry is described
            # by. A gear would be mush at this size.
            $tb = New-Object System.Drawing.SolidBrush($col)
            $g.FillPolygon($tb, [System.Drawing.PointF[]]@(
                    (New-Object System.Drawing.PointF([single]($cx - $span), [single]($cy - $box * 0.139))),
                    (New-Object System.Drawing.PointF([single]($cx + $span), [single]($cy - $box * 0.139))),
                    (New-Object System.Drawing.PointF([single]$cx, [single]($cy + $box * 0.194)))))
            $tb.Dispose()
            continue
        }
        $ip = New-Object System.Drawing.Pen($col, [single]($box / 11.25))
        if ($pair.K -eq 'min') {
            $g.DrawLine($ip, $cx - $span, $cy, $cx + $span, $cy)
        } else {
            $g.DrawLine($ip, $cx - $span, $cy - $span, $cx + $span, $cy + $span)
            $g.DrawLine($ip, $cx + $span, $cy - $span, $cx - $span, $cy + $span)
        }
        $ip.Dispose()
    }
})

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, $Font, $Color, [string]$Align = 'MiddleLeft', $Parent = $null)
    if (-not $Parent) { $Parent = $form }
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point((Px $X), (Px $Y))
    $l.Size = New-Object System.Drawing.Size((Px $W), (Px $H))
    $l.Font = $Font
    $l.ForeColor = $Color
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.TextAlign = $Align
    $Parent.Controls.Add($l)
    return $l
}

$lblHead = New-Label 'Kimi Code 用量' 12 10 226 20 $fontHead $colFg

$drawComboItem = {
    param($sender, $e)
    if ($e.Index -lt 0) { return }
    $isSel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
    $brush = if ($isSel) { $script:brushSel } else { $script:brushCombo }
    $e.Graphics.FillRectangle($brush, $e.Bounds)
    $e.Graphics.DrawString([string]$sender.Items[$e.Index], $sender.Font, $script:brushFg, [single]($e.Bounds.X + (Px 6)), [single]($e.Bounds.Y + (Px 3)))
}

function New-Combo {
    param([int]$X, [int]$Y, [int]$W, [string[]]$Items, [int]$SelectedIndex)
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cb.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $cb.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
    $cb.BackColor = $colCombo
    $cb.ForeColor = $colFg
    $cb.Font = $fontUI
    $cb.ItemHeight = (Px 20)
    $cb.Location = New-Object System.Drawing.Point((Px $X), (Px $Y))
    $cb.Size = New-Object System.Drawing.Size((Px $W), (Px 22))
    [void]$cb.Items.AddRange([object[]]$Items)
    $cb.SelectedIndex = $SelectedIndex
    $cb.Add_DrawItem($drawComboItem)
    $form.Controls.Add($cb)
    return $cb
}

$cbTime  = New-Combo 12 34 148 @('不限', '今天', '昨天', '近 3 天', '近 7 天', '近 30 天', '本月', '上月') 1
$cbScope = New-Combo 166 34 134 @('当前会话', '全部会话') 0

$lblSub = New-Label '正在统计…' 12 60 288 16 $fontSmall $colDim

# Three rows of two metrics: 输入 | 输出, 缓存读取 | 平均每次, 请求次数 | 缓存命中率.
# Values are right aligned, so the numbers in a column line up, and each box can
# be sized to its own content — the panel is then exactly two label columns plus
# two value columns with nothing spare.
$colName1X = 12;  $colName1W = 91
$colVal1X  = 106; $colVal1W = 56
$colName2X = 172; $colName2W = 67
$colVal2X  = 243; $colVal2W = 56

$rowY = 82
$lblInName  = New-Label '输入（非缓存）' $colName1X $rowY $colName1W 20 $fontUI $colDim 'MiddleRight'
$lblInVal   = New-Label '—' $colVal1X $rowY $colVal1W 20 $fontUI $colFg 'MiddleRight'
$lblOutName = New-Label '输出' $colName2X $rowY $colName2W 20 $fontUI $colDim 'MiddleRight'
$lblOutVal  = New-Label '—' $colVal2X $rowY $colVal2W 20 $fontUI $colFg 'MiddleRight'
$rowY += 22
$lblRdName  = New-Label '缓存读取' $colName1X $rowY $colName1W 20 $fontUI $colDim 'MiddleRight'
$lblRdVal   = New-Label '—' $colVal1X $rowY $colVal1W 20 $fontUI $colFg 'MiddleRight'
$lblAvgName = New-Label '平均每次' $colName2X $rowY $colName2W 20 $fontUI $colDim 'MiddleRight'
$lblAvgVal  = New-Label '—' $colVal2X $rowY $colVal2W 20 $fontUI $colFg 'MiddleRight'
$rowY += 22
$lblReqName  = New-Label '请求次数' $colName1X $rowY $colName1W 22 $fontUI $colDim 'MiddleRight'
$lblReqVal   = New-Label '—' $colVal1X $rowY $colVal1W 22 $fontUI $colFg 'MiddleRight'
$lblRateName = New-Label '缓存命中率' $colName2X $rowY $colName2W 22 $fontBold $colFg 'MiddleRight'
$lblRateVal  = New-Label '—' $colVal2X $rowY $colVal2W 22 $fontBold $colFg 'MiddleRight'

# Numbers take the client's Latin face, and therefore have to be drawn by GDI+:
# the native label renderer goes through GDI, which cannot see a privately
# loaded family at all and would quietly substitute a system font.
foreach ($lbl in @($lblInVal, $lblOutVal, $lblRdVal, $lblAvgVal, $lblReqVal)) {
    $lbl.Font = $fontNum
    $lbl.UseCompatibleTextRendering = $true
}
$lblRateVal.Font = $fontNumBold
$lblRateVal.UseCompatibleTextRendering = $true

# ---------- pet form ----------

# A plain Form repaints by erasing the background first; on a chroma-key window
# that erase means "become fully transparent for a moment", which is what made
# the ball blink once per refresh. Painting everything into an off-screen buffer
# and blitting it in one go removes the in-between state.
Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition @'
public class PetSurface : System.Windows.Forms.Form {
    public PetSurface() {
        this.SetStyle(System.Windows.Forms.ControlStyles.UserPaint
                    | System.Windows.Forms.ControlStyles.AllPaintingInWmPaint
                    | System.Windows.Forms.ControlStyles.OptimizedDoubleBuffer
                    | System.Windows.Forms.ControlStyles.Opaque, true);
        this.UpdateStyles();
    }
}
'@

# The ball is two stacked windows for the same reason the panel is: the body has
# to be translucent while the numbers stay fully opaque. $petBody carries the
# alpha; $pet sits above it with no alpha at all, drawing only the text over a
# chroma-keyed background.
$petBody = New-Object PetSurface
$petBody.FormBorderStyle = 'None'
$petBody.StartPosition = 'Manual'
$petBody.Location = $script:startPos
$petBody.Size = New-Object System.Drawing.Size($script:PetWindow, $script:PetWindow)
$petBody.TopMost = $true
$petBody.ShowInTaskbar = $false
$petBody.BackColor = $colPetKey
$petBody.TransparencyKey = $colPetKey
$petBody.Opacity = 0.70
$petBody.Text = 'Kimi Code 用量 (body)'
[void]$petBody.Handle
[ZOrder]::MakeNoActivate($petBody.Handle)

$pet = New-Object PetSurface
$pet.FormBorderStyle = 'None'
$pet.StartPosition = 'Manual'
$pet.Location = $script:startPos
$pet.Size = New-Object System.Drawing.Size($script:PetWindow, $script:PetWindow)
$pet.TopMost = $true
$pet.ShowInTaskbar = $false
$pet.BackColor = $colPetKey
$pet.TransparencyKey = $colPetKey
$pet.Text = 'Kimi Code 用量'
# A floating widget should not take focus away from whatever the user is typing
# in; clicking it must not make it the active window either.
[void]$pet.Handle
[ZOrder]::MakeNoActivate($pet.Handle)

$script:view = @{ Input = [int64]0; Output = [int64]0; Rate = -1.0; RateText = '—'; Key = '' }

# Noise drifts with wall-clock time rather than a frame counter, so the flow
# keeps its speed regardless of how often the animation timer actually fires.
$script:petEpoch = Get-Date

function Assert-PetZOrder {
    if (-not $pet.Visible) { return }
    [void][ZOrder]::SetWindowPos($petBody.Handle, $pet.Handle, 0, 0, 0, 0, 0x1 -bor 0x2 -bor 0x10)
}

function Set-PetLocation {
    param([System.Drawing.Point]$Location)
    $petBody.Location = $Location
    $pet.Location = $Location
}

function Show-PetWindows {
    $petBody.Show()
    $pet.Show()
    Assert-PetZOrder
}

function Hide-PetWindows {
    $pet.Hide()
    $petBody.Hide()
}

function Get-PetPhase {
    return (((Get-Date) - $script:petEpoch).TotalMilliseconds * 0.012 * $script:UiScale)
}

$petBody.Add_Paint({
    try {
        $g = $_.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        Render-PetBall -Graphics $g -Width $petBody.ClientSize.Width -Height $petBody.ClientSize.Height `
            -BackgroundColor $colPetKey `
            -Phase (Get-PetPhase)
    } catch {
        if (-not $script:paintErrLogged) {
            $script:paintErrLogged = $true
            Add-Content -LiteralPath $script:diagPath -Value ("BALL paint: " + $_.Exception.ToString())
        }
    }
})

$pet.Add_Paint({
    try {
        $g = $_.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        Render-PetOverlay -Graphics $g -Width $pet.ClientSize.Width -Height $pet.ClientSize.Height `
            -InputText (Format-Tokens $script:view.Input) `
            -OutputText (Format-Tokens $script:view.Output) `
            -RateText $script:view.RateText `
            -RateColor (Get-HitRateColor ([double]$script:view.Rate)) `
            -BackgroundColor $colPetKey
    } catch {
        if (-not $script:paintErrLogged) {
            $script:paintErrLogged = $true
            Add-Content -LiteralPath $script:diagPath -Value ("OVERLAY paint: " + $_.Exception.ToString())
        }
    }
})

# ---------- dragging ----------

$script:dragOffset = $null

function Add-PanelDragging {
    param($ctrl)
    $ctrl.Add_MouseDown({
        Assert-PanelZOrder
        $script:dragOffset = [System.Windows.Forms.Cursor]::Position - $form.Location
        $script:panelDragged = $false
    })
    $ctrl.Add_MouseMove({
        if ($script:dragOffset) {
            $down = ([System.Windows.Forms.Control]::MouseButtons -band [System.Windows.Forms.MouseButtons]::Left) -ne 0
            if ($down) {
                $target = [System.Windows.Forms.Cursor]::Position - $script:dragOffset
                if ([Math]::Abs($target.X - $form.Location.X) -gt 3 -or [Math]::Abs($target.Y - $form.Location.Y) -gt 3) {
                    $script:panelDragged = $true
                }
                # Both layers must move together, or the text slides off its
                # background.
                if ($script:panelDragged) { Set-PanelGeometry $target $script:PanelW $script:PanelH }
            }
        }
    })
    $ctrl.Add_MouseUp({ $script:dragOffset = $null; if ($form.Visible) { Save-State } })
}

# Icon hover and activation are attached to both layers, keyed purely by
# script-scope state plus the event's own coordinates: a scriptblock handed to an
# event cannot close over a function's locals, since that scope is gone by the
# time it fires.
function Add-PanelIcons {
    param($ctrl)
    $ctrl.Add_MouseMove({
        $p = New-Object System.Drawing.Point($_.X, $_.Y)
        $hover = ''
        if ($script:iconCfg.Contains($p)) { $hover = 'cfg' }
        elseif ($script:iconMin.Contains($p)) { $hover = 'min' }
        elseif ($script:iconClose.Contains($p)) { $hover = 'close' }
        if ($hover -ne $script:hoverIcon) {
            $script:hoverIcon = $hover
            $form.Cursor = if ($hover) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
            Invalidate-PanelIcons
        }
    })
    $ctrl.Add_MouseLeave({
        if ($script:hoverIcon -ne '') {
            $script:hoverIcon = ''
            Invalidate-PanelIcons
        }
    })
    $ctrl.Add_MouseUp({
        Assert-PanelZOrder
        if ($script:panelDragged) { return }
        $p = New-Object System.Drawing.Point($_.X, $_.Y)
        # Guarded and logged: an exception thrown here is swallowed by the message
        # loop, which turns a broken handler into "the button does nothing".
        try {
            if ($script:iconCfg.Contains($p)) { Show-SettingsWindow }
            elseif ($script:iconMin.Contains($p)) { Switch-ToPet }
            # The × no longer ends the process: it parks the widget in the tray, so
            # an accidental click is recoverable. Quitting is the tray menu's job.
            elseif ($script:iconClose.Contains($p)) { Hide-ToTray }
        } catch {
            Add-Content -LiteralPath $script:diagPath -Value ("ICON click: " + $_.Exception.ToString())
        }
    })
}

Add-PanelDragging $bg
Add-PanelDragging $form
Add-PanelIcons $bg
Add-PanelIcons $form

# Activation is what lifts a window to the front of the topmost band, so it is
# also where the layering has to be put back.
$bg.Add_Activated({ Assert-PanelZOrder })
$form.Add_Activated({ Assert-PanelZOrder })

# Labels on the content layer sit on chroma-keyed pixels, so the mouse never
# reaches them; dragging is handled by the two layers themselves.

$script:petDown = $null
$script:petDragged = $false
$script:petLastClick = -1
$script:petClock = [System.Diagnostics.Stopwatch]::StartNew()

function Add-PetMouse {
    param($ctrl)
    $ctrl.Add_MouseDown({
        Assert-PetZOrder
        $script:petDown = [System.Windows.Forms.Cursor]::Position - $pet.Location
        $script:petDragged = $false
    })
    $ctrl.Add_MouseMove({
        if ($script:petDown) {
            $target = [System.Windows.Forms.Cursor]::Position - $script:petDown
            if ([Math]::Abs($target.X - $pet.Location.X) -gt 3 -or [Math]::Abs($target.Y - $pet.Location.Y) -gt 3) {
                $script:petDragged = $true
            }
            if ($script:petDragged) { Set-PetLocation $target }
        }
    })
    $ctrl.Add_MouseUp({
        Assert-PetZOrder
        $script:petDown = $null
        if ($script:petDragged) {
            Set-PetLocation (Fit-ToMonitor $pet.Location $script:PetWindow $script:PetWindow)
            Save-State
            $script:petLastClick = -1
            return
        }

        # Restore on double click only. A single click does nothing, so a stray click
        # while nudging the ball around cannot drop the panel open.
    #
    # Timed here rather than with the DoubleClick event: WM_LBUTTONDBLCLK is
    # produced by the mouse driver, so a synthesised click pair could never
    # exercise that path, whereas this one is testable.
    # Environment.TickCount64 does not exist on .NET Framework: it evaluates to
    # $null, and $null - 0 is 0, which would make every single click look like a
    # double click. A Stopwatch is monotonic and has no wraparound concern.
    $now = $script:petClock.ElapsedMilliseconds
    if ($script:petLastClick -ge 0 -and
        ($now - $script:petLastClick) -le [System.Windows.Forms.SystemInformation]::DoubleClickTime) {
        $script:petLastClick = -1
        Switch-ToPanel
    } else {
        $script:petLastClick = $now
    }
    })
}

# Both ball layers accept the mouse: the body layer covers the sphere, while
# clicks that land exactly on a glyph reach the text layer.
Add-PetMouse $petBody
Add-PetMouse $pet
$petBody.Add_Activated({ Assert-PetZOrder })
$pet.Add_Activated({ Assert-PetZOrder })

# ---------- mode switching ----------

# The two modes inherit each other's position, so the ball appears where the
# panel was rather than jumping to a separately remembered spot. The result is
# fitted to the monitor so the larger panel can never land off-screen.
function Switch-ToPet {
    $script:mode = 'pet'
    $moved = -not ($script:panelAnchor -and
                   $form.Location.X -eq $script:panelAnchor.X -and
                   $form.Location.Y -eq $script:panelAnchor.Y)
    Hide-PanelWindows

    if ($moved) {
        # The panel was repositioned since it opened, so the ball follows it and
        # keeps the shared bottom-right corner.
        $br = New-Object System.Drawing.Point(($form.Location.X + $script:PanelW), ($form.Location.Y + $script:PanelH))
        Set-PetLocation (Get-AnchoredLocation $br $script:PetWindow $script:PetWindow)
    } elseif ($script:petAnchor) {
        # Untouched panel: go back to exactly where the ball was. Deriving the
        # spot from the corner instead would drift whenever the panel had to be
        # nudged on-screen (a ball near the top-left corner cannot be preserved
        # by corner alignment alone).
        Set-PetLocation (Fit-ToMonitor $script:petAnchor $script:PetWindow $script:PetWindow)
    }

    Show-PetWindows
    Save-State
}

function Switch-ToPanel {
    $script:mode = 'panel'
    $script:petAnchor = New-Object System.Drawing.Point($pet.Location.X, $pet.Location.Y)
    Hide-PetWindows
    $br = New-Object System.Drawing.Point(($pet.Location.X + $script:PetWindow), ($pet.Location.Y + $script:PetWindow))
    $loc = Get-AnchoredLocation $br $script:PanelW $script:PanelH
    Set-PanelGeometry $loc $script:PanelW $script:PanelH
    $script:panelAnchor = New-Object System.Drawing.Point($loc.X, $loc.Y)
    Show-PanelWindows
    Save-State
}

# ---------- live data ----------

function Format-DaySpan {
    param($DateKeys)
    if (-not $DateKeys) { return '全部时间' }
    $sorted = @($DateKeys | Sort-Object)
    if ($sorted.Count -eq 1) { return $sorted[0].Substring(5) }
    return ($sorted[0].Substring(5) + ' ~ ' + $sorted[-1].Substring(5))
}

$updateDisplay = {
    $scope = [string]$cbScope.SelectedItem
    if (-not $scope) { return }
    $dates = Get-RangeDates ([string]$cbTime.SelectedItem)
    $tot = Get-ScopeTotals $scope $dates
    $rate = Get-HitRate $tot

    $script:view.Input = $tot.Input
    $script:view.Output = $tot.Output
    $script:view.Rate = $rate
    $script:view.RateText = if ($rate -ge 0) { ('{0:N1}%' -f $rate) } else { '—' }

    $lblInVal.Text  = Format-Tokens $tot.Input
    $lblOutVal.Text = Format-Tokens $tot.Output
    $lblRdVal.Text  = Format-Tokens $tot.Read
    $lblReqVal.Text = ('{0:N0}' -f $tot.Requests)
    # Average tokens per request: everything the model was fed or wrote, divided
    # by the number of requests that produced it.
    $perReq = if ($tot.Requests -gt 0) {
        [int64](($tot.Input + $tot.Read + $tot.Create + $tot.Output) / $tot.Requests)
    } else { [int64]0 }
    $lblAvgVal.Text = Format-Tokens $perReq

    if ($rate -ge 0) { $lblRateVal.Text = ('{0:N1}%' -f $rate) } else { $lblRateVal.Text = '—' }
    $lblRateVal.ForeColor = Get-HitRateColor ([double]$rate)

    if ($scope -eq '当前会话') {
        $newest = Get-ActiveFile
        $name = '(无会话)'
        if ($newest) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($newest)
            if ($name -like 'session_*') { $name = $name.Substring(8, [Math]::Min(8, $name.Length - 8)) }
            $name = "会话 $name"
        }
    } else {
        $name = '全部会话'
    }

    $pending = ''
    if (Test-ScanPending $scope) { $pending = ' · 统计中…' }
    $lblSub.Text = "$name · $(Format-DaySpan $dates)$pending"
    $lblSub.ForeColor = if ($pending) { $colWarn } else { $colDim }

    if ($pet.Visible) {
        # Only the text layer needs repainting when the numbers change; the body
        # layer animates on its own timer.
        $key = "$($script:view.Input)|$($script:view.Output)|$($script:view.RateText)"
        if ($key -ne $script:view.Key) {
            $script:view.Key = $key
            $pet.Invalidate()
        }
    }
}

$cbTime.Add_SelectedIndexChanged({ & $updateDisplay })
$cbScope.Add_SelectedIndexChanged({ & $updateDisplay })

# No drop-down opacity juggling is needed any more: the lists belong to the
# content layer, which never carried the translucent alpha.

# The initial full scan already ran before the layout was built, so there is
# nothing to catch up on here.
& $updateDisplay

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    Update-Scan -BudgetBytes 8388608
    & $updateDisplay
    Test-ClientWatchdog
})
$timer.Start()

# Separate, faster timer for the drifting noise. Only the body layer animates —
# the text layer is repainted when the numbers change. The forms are double
# buffered with the background erase suppressed, so a repaint never shows a
# half-drawn frame.
$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 75
$animTimer.Add_Tick({
    if ($petBody.Visible) { $petBody.Invalidate() }
})
$animTimer.Start()

# ---------- tray, hotkey and settings ----------

# × now parks the widget in the notification area instead of ending it, so there
# has to be a visible way back, a keyboard way back, and somewhere to change the
# keyboard way back. That is this whole section.

$script:trayIcon = $null
$script:trayHicon = [IntPtr]::Zero
$script:miHotkey = $null
$script:trayHidden = $false

function Write-Diag {
    param([string]$Line)
    try { Add-Content -LiteralPath $script:diagPath -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $Line) } catch { }
}

# ---------- park and wake ----------

function Invoke-ShowPanel {
    if ($form.Visible) { Assert-PanelZOrder; return }
    if ($script:mode -eq 'panel') {
        # Parked from the panel, so it goes back exactly where it was. Letting
        # Switch-ToPanel derive the spot from the ball's corner would move it.
        Show-PanelWindows
    } else {
        Switch-ToPanel
    }
    $script:trayHidden = $false
    Write-Diag 'panel shown'
}

function Invoke-ShowPet {
    if ($pet.Visible) { Assert-PetZOrder; return }
    if ($script:mode -eq 'pet') { Show-PetWindows } else { Switch-ToPet }
    $script:trayHidden = $false
    Write-Diag 'pet shown'
}

function Hide-ToTray {
    Hide-PanelWindows
    Hide-PetWindows
    # A dialog left open would be stranded with nothing on screen to explain it.
    if ($script:stg -and $script:stg.Visible) { Hide-SettingsWindow }
    $script:trayHidden = $true
    Save-State
    Write-Diag 'parked to tray'
}

# ---------- global hotkey ----------

$script:hk = New-Object HotKeyHost
$script:hk.Pressed = [Action]{
    # One key, two states: whatever is on screen — ball or panel — goes back to
    # the tray, and the ball is what comes back, since the panel is something the
    # user opens deliberately by double-clicking it. The callback arrives on the
    # UI thread, which is where forms live.
    if ($form.Visible -or $pet.Visible) { Hide-ToTray } else { Invoke-ShowPet }
}

function Register-CurrentHotkey {
    if ($script:hotkeyKey -le 0) { return $false }
    return $script:hk.Register([uint32]$script:hotkeyMods, [uint32]$script:hotkeyKey)
}

function Update-HotkeyLabel {
    if ($script:miHotkey) {
        $script:miHotkey.Text = '唤出 / 收起：' + (Format-Hotkey $script:hotkeyMods $script:hotkeyKey)
    }
}

# Another program can already hold the combination, in which case registration
# fails and the previous binding is restored rather than leaving the widget with
# no hotkey at all.
function Set-Hotkey {
    param([int]$Mods, [int]$Key)
    if ($Key -le 0) { return $false }
    $script:hk.Unregister()
    if ($script:hk.Register([uint32]$Mods, [uint32]$Key)) {
        $script:hotkeyMods = $Mods
        $script:hotkeyKey = $Key
        Save-Settings
        Update-HotkeyLabel
        return $true
    }
    [void](Register-CurrentHotkey)
    return $false
}

# ---------- tray icon ----------

function Initialize-Tray {
    # The bitmap is kept referenced for the life of the process: the icon is made
    # from its HICON, and disposing the source out from under it is asking for
    # trouble for no gain.
    $script:trayBmp = New-TrayImage
    $script:trayHicon = $script:trayBmp.GetHicon()
    $script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:trayIcon.Icon = [System.Drawing.Icon]::FromHandle($script:trayHicon)
    $script:trayIcon.Text = 'Kimi Code 用量 — 双击显示面板'

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $item = $menu.Items.Add('显示统计面板')
    $item.Add_Click({ Invoke-ShowPanel })
    $item = $menu.Items.Add('显示小球')
    $item.Add_Click({ Invoke-ShowPet })
    $item = $menu.Items.Add('全部收起到托盘')
    $item.Add_Click({ Hide-ToTray })
    [void]$menu.Items.Add('-')
    $script:miHotkey = $menu.Items.Add('唤出 / 收起：' + (Format-Hotkey $script:hotkeyMods $script:hotkeyKey))
    $script:miHotkey.Enabled = $false
    $item = $menu.Items.Add('设置…')
    $item.Add_Click({ Show-SettingsWindow })
    [void]$menu.Items.Add('-')
    $item = $menu.Items.Add('退出')
    $item.Add_Click({ $form.Close() })
    $script:trayIcon.ContextMenuStrip = $menu

    $script:trayIcon.Add_MouseDoubleClick({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-ShowPanel }
    })
    $script:trayIcon.Visible = $true
}

# Windows 11 files a newly seen tray icon into the overflow flyout, where it is
# effectively invisible — which defeats a button whose entire job is to be
# reachable. Explorer records the choice per icon under NotifyIconSettings,
# keyed by a hash and identified by this exact tooltip, so promoting it here is
# the same edit dragging it onto the taskbar makes. An icon already known to the
# machine is left exactly as the user arranged it.
function Enable-TrayIconPromotion {
    try {
        $root = 'HKCU:\Control Panel\NotifyIconSettings'
        if (-not (Test-Path -LiteralPath $root)) { return }
        foreach ($key in Get-ChildItem -LiteralPath $root) {
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if ($props.InitialTooltip -ne $script:trayIcon.Text) { continue }
            if ($props.IsPromoted -eq 1) { return }
            Set-ItemProperty -Path $key.PSPath -Name IsPromoted -Value 1 -Type DWord
            Write-Diag 'tray icon promoted out of the overflow'
            return
        }
    } catch { }
}

# ---------- settings window ----------

function New-FlatButton {
    param([string]$Text, [int]$X, [int]$W)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point((Px $X), (Px 118))
    $b.Size = New-Object System.Drawing.Size((Px $W), (Px 28))
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderColor = $colSel
    $b.FlatAppearance.MouseOverBackColor = $colSel
    $b.FlatAppearance.MouseDownBackColor = $colSel
    $b.BackColor = $colCombo
    $b.ForeColor = $colFg
    $b.Font = $fontUI
    return $b
}

$script:stg = $null
$script:stgTb = $null
$script:stgHover = ''
$script:stgDrag = $null
$script:stgPendingMods = 0
$script:stgPendingKey = 0

function Build-SettingsWindow {
    $w = New-Object System.Windows.Forms.Form
    $w.FormBorderStyle = 'None'
    $w.StartPosition = 'Manual'
    $w.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $w.Size = New-Object System.Drawing.Size((Px 300), (Px 160))
    # Solid, unlike the panel: this is a window the user reads and types into,
    # and the panel's translucent stack costs a second window and a z-order it
    # has to defend.
    $w.BackColor = $colBg
    $w.ForeColor = $colFg
    $w.TopMost = $true
    $w.ShowInTaskbar = $false
    # Owned by the panel. Both windows are topmost, and clicking a topmost window
    # lifts it to the front of that band — so the panel kept climbing over this
    # one and swallowing the clicks meant for its buttons. An owned window is
    # held above its owner by Windows itself, whatever the clicks do.
    $w.Owner = $form
    $w.Text = 'Kimi Code 用量 · 设置'
    [void]$w.Handle
    [void][Dwm]::SetRound($w.Handle)

    $script:stgClose = New-Object System.Drawing.Rectangle((Px 266), (Px 8), (Px 18), (Px 18))
    $w.Add_Paint({
        $g = $_.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $col = if ($script:stgHover -eq 'close') { $colFg } else { $colDim }
        $box = $script:stgClose.Width
        $span = $box / 4.0
        $p = New-Object System.Drawing.Pen($col, [single]($box / 11.25))
        $cx = $script:stgClose.X + $box / 2.0
        $cy = $script:stgClose.Y + $box / 2.0
        $g.DrawLine($p, $cx - $span, $cy - $span, $cx + $span, $cy + $span)
        $g.DrawLine($p, $cx + $span, $cy - $span, $cx - $span, $cy + $span)
        $p.Dispose()
    })
    $w.Add_MouseDown({ $script:stgDrag = [System.Windows.Forms.Cursor]::Position - $script:stg.Location })
    $w.Add_MouseMove({
        $p = New-Object System.Drawing.Point($_.X, $_.Y)
        $h = if ($script:stgClose.Contains($p)) { 'close' } else { '' }
        if ($h -ne $script:stgHover) { $script:stgHover = $h; $script:stg.Invalidate($script:stgClose) }
        if ($script:stgDrag) {
            $down = ([System.Windows.Forms.Control]::MouseButtons -band [System.Windows.Forms.MouseButtons]::Left) -ne 0
            if ($down) { $script:stg.Location = [System.Windows.Forms.Cursor]::Position - $script:stgDrag }
        }
    })
    $w.Add_MouseUp({
        $script:stgDrag = $null
        if ($script:stgClose.Contains((New-Object System.Drawing.Point($_.X, $_.Y)))) { Hide-SettingsWindow }
    })

    [void](New-Label '设置' 12 10 150 20 $fontHead $colFg 'MiddleLeft' $w)
    [void](New-Label '唤出快捷键' 12 44 96 22 $fontUI $colDim 'MiddleRight' $w)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point((Px 116), (Px 43))
    $tb.Size = New-Object System.Drawing.Size((Px 172), (Px 24))
    $tb.Font = $fontUI
    $tb.BackColor = $colCombo
    $tb.ForeColor = $colFg
    $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $tb.ReadOnly = $true
    $w.Controls.Add($tb)
    $script:stgTb = $tb

    # Broken by hand: left to itself the sentence wraps in the middle of a word
    # ("至少一 / 个。").
    $hint = New-Label "点进输入框后按下组合键`n需含 Ctrl / Alt / Shift 中至少一个" 12 74 276 36 $fontSmall $colDim 'TopLeft' $w
    $hint.AutoSize = $false

    # Modifier chords arrive as a KeyDown for the real key; the modifier keys on
    # their own are ignored so the box does not fill up with "Ctrl + ".
    $tb.Add_KeyDown({
        $k = [int]$_.KeyCode
        $_.SuppressKeyPress = $true
        if ($k -eq 16 -or $k -eq 17 -or $k -eq 18 -or $k -eq 91 -or $k -eq 92) { return }
        $mods = 0
        if ($_.Control) { $mods = $mods -bor 2 }
        if ($_.Alt) { $mods = $mods -bor 1 }
        if ($_.Shift) { $mods = $mods -bor 4 }
        if ($mods -eq 0) {
            $script:stgPendingMods = 0
            $script:stgPendingKey = 0
            $script:stgTb.ForeColor = $colWarn
            $script:stgTb.Text = '需要 Ctrl / Alt / Shift'
            return
        }
        $script:stgPendingMods = $mods
        $script:stgPendingKey = $k
        $script:stgTb.ForeColor = $colFg
        $script:stgTb.Text = Format-Hotkey $mods $k
    })

    $bDef = New-FlatButton '恢复默认' 12 88
    $bCan = New-FlatButton '取消' 116 76
    $bOk = New-FlatButton '保存' 204 84
    $bDef.Add_Click({
        $script:stgPendingMods = $script:DefaultHotkeyMods
        $script:stgPendingKey = $script:DefaultHotkeyKey
        $script:stgTb.ForeColor = $colFg
        $script:stgTb.Text = Format-Hotkey $script:DefaultHotkeyMods $script:DefaultHotkeyKey
    })
    $bCan.Add_Click({ Hide-SettingsWindow })
    $bOk.Add_Click({
        if ($script:stgPendingKey -le 0) {
            [void][System.Windows.Forms.MessageBox]::Show($script:stg, '先按下一个组合键再保存。', '设置')
            return
        }
        if (Set-Hotkey $script:stgPendingMods $script:stgPendingKey) {
            $script:stg.Hide()
            Write-Diag ('hotkey set: ' + (Format-Hotkey $script:hotkeyMods $script:hotkeyKey))
        } else {
            [void][System.Windows.Forms.MessageBox]::Show($script:stg, '这个组合键被别的程序占用了，换一个试试。', '设置')
        }
    })
    foreach ($b in @($bDef, $bCan, $bOk)) { $w.Controls.Add($b) }

    return $w
}

function Hide-SettingsWindow {
    if (-not $script:stg) { return }
    $script:stg.Hide()
    # Closing without saving must not leave the widget with no hotkey: the chord
    # was released so it could be recorded.
    [void](Register-CurrentHotkey)
    Write-Diag 'settings closed'
}

function Show-SettingsWindow {
    if (-not $script:stg) { $script:stg = Build-SettingsWindow }
    $script:stgPendingMods = $script:hotkeyMods
    $script:stgPendingKey = $script:hotkeyKey
    $script:stgTb.ForeColor = $colFg
    $script:stgTb.Text = Format-Hotkey $script:hotkeyMods $script:hotkeyKey
    # The chord has to be free while the window is open, or the OS eats the very
    # keystroke the user is trying to record.
    $script:hk.Unregister()
    $script:stg.Location = (Fit-ToMonitor (New-Object System.Drawing.Point(($form.Location.X + (Px 8)), ($form.Location.Y + (Px 8)))) $script:stg.Width $script:stg.Height)
    $script:stg.Show()
    [void][ZOrder]::SetWindowPos($script:stg.Handle, [IntPtr]::Zero, 0, 0, 0, 0, 0x1 -bor 0x2 -bor 0x40)
    $script:stg.Activate()
    $script:stgTb.Focus()
    # A focused read-only box renders a selection highlight, which reads as if
    # the value were selected for editing.
    $script:stgTb.SelectionStart = $script:stgTb.Text.Length
    $script:stgTb.SelectionLength = 0
    Write-Diag 'settings opened'
}

# ---------- lifecycle ----------

# The widget belongs to the desktop client: the SessionStart hook starts it, and
# it should not outlive the client either. The process name is only trusted
# because the client is provably running when the hook fires — a build whose
# executable is named differently must not make the widget exit straight away.
$script:watchClient = $false
$script:clientGoneAt = $null

function Test-ClientAlive {
    return ($null -ne (Get-Process -Name 'Kimi Code' -ErrorAction SilentlyContinue))
}

if (Test-ClientAlive) { $script:watchClient = $true }

function Test-ClientWatchdog {
    if (-not $script:watchClient) { return }
    if (Test-ClientAlive) { $script:clientGoneAt = $null; return }
    if (-not $script:clientGoneAt) { $script:clientGoneAt = Get-Date; return }
    # A restart, including an auto-update, takes seconds; a whole minute of
    # absence means the client really is gone.
    if (((Get-Date) - $script:clientGoneAt).TotalSeconds -gt 60) {
        Write-Diag 'client gone, exiting'
        $form.Close()
    }
}

# ---------- start the extras ----------

Initialize-Tray
if (-not (Register-CurrentHotkey)) {
    # Stored chord may have been taken since it was recorded; fall back rather
    # than come up without any hotkey.
    if ($script:hotkeyMods -ne $script:DefaultHotkeyMods -or $script:hotkeyKey -ne $script:DefaultHotkeyKey) {
        if ($script:hk.Register([uint32]$script:DefaultHotkeyMods, [uint32]$script:DefaultHotkeyKey)) {
            $script:hotkeyMods = $script:DefaultHotkeyMods
            $script:hotkeyKey = $script:DefaultHotkeyKey
            Save-Settings
            Update-HotkeyLabel
        }
    }
}
Write-Diag ('start: mode=' + $script:mode + ' hotkey=' + (Format-Hotkey $script:hotkeyMods $script:hotkeyKey) + ' watchdog=' + $script:watchClient)

# Explorer writes the overflow entry a moment after the icon appears, so the
# promotion is attempted after the icon has had time to be registered.
$trayTimer = New-Object System.Windows.Forms.Timer
$trayTimer.Interval = 4000
$trayTimer.Add_Tick({
    $trayTimer.Stop()
    $trayTimer.Dispose()
    Enable-TrayIconPromotion
})
$trayTimer.Start()

# ---------- run ----------

$script:closing = $false
$onClosed = {
    if ($script:closing) { return }
    $script:closing = $true
    Save-State
    if ($pet.Visible) { $pet.Hide() }
    if ($petBody.Visible) { $petBody.Hide() }
    if ($bg.Visible) { $bg.Hide() }
    try { $script:hk.Unregister() } catch { }
    if ($script:trayIcon) { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() }
    if ($script:stg -and $script:stg.Visible) { $script:stg.Hide() }
    Write-Diag 'exit'
    [System.Windows.Forms.Application]::ExitThread()
}
$form.Add_FormClosed($onClosed)
$bg.Add_FormClosed($onClosed)
$pet.Add_FormClosed($onClosed)
$petBody.Add_FormClosed($onClosed)

if ($script:mode -eq 'pet') { Show-PetWindows } else { Show-PanelWindows }
[System.Windows.Forms.Application]::Run()

$timer.Stop()
if (-not $form.IsDisposed) { $form.Dispose() }
if (-not $bg.IsDisposed) { $bg.Dispose() }
if (-not $pet.IsDisposed) { $pet.Dispose() }
if (-not $petBody.IsDisposed) { $petBody.Dispose() }
