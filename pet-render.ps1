Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# Geometry. Windows clamps small top-level window widths, so the window stays at
# a fixed square and the ball is centred inside it; the margin around the ball is
# painted in the chroma-key colour and therefore never shows.
$script:PetWindow = 144
$script:PetBall   = 104
$script:PetBezel  = 1

$script:PetFont     = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$script:PetFontBold = New-Object System.Drawing.Font('Microsoft YaHei UI', 8, [System.Drawing.FontStyle]::Bold)

$script:PetText      = [System.Drawing.Color]::FromArgb(240, 240, 243)
$script:PetArrowUp   = [System.Drawing.Color]::FromArgb(120, 214, 255)
$script:PetArrowDown = [System.Drawing.Color]::FromArgb(255, 190, 96)

# Deliberately mid-tone, not pale: the numbers are near-white and need the ball
# dark enough behind them to stay legible.
$script:PetCore = [System.Drawing.Color]::FromArgb(255, 74, 136, 206)
$script:PetEdge = [System.Drawing.Color]::FromArgb(255, 18, 54, 122)

Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;

public class PetNoise {
    // Value noise on a wrapping lattice: every octave's lattice divides the
    // texture size, and indices wrap, so the tile repeats seamlessly. Smooth
    // interpolation keeps it low frequency instead of per-pixel sandpaper.
    public static Bitmap[] Make(int size, int maxAlpha, int seed) {
        int[] grids = { 6, 12, 24 };
        double[] amps = { 1.0, 0.5, 0.25 };
        var rnd = new Random(seed);

        var table = new double[grids.Length][,];
        for (int o = 0; o < grids.Length; o++) {
            int g = grids[o];
            table[o] = new double[g, g];
            for (int i = 0; i < g; i++)
                for (int j = 0; j < g; j++)
                    table[o][i, j] = rnd.NextDouble();
        }

        double ampSum = 0;
        foreach (var a in amps) ampSum += a;

        var n = new double[size, size];
        double min = double.MaxValue, max = double.MinValue;
        for (int y = 0; y < size; y++) {
            for (int x = 0; x < size; x++) {
                double v = 0;
                for (int o = 0; o < grids.Length; o++) {
                    int g = grids[o];
                    double fx = (double)x / size * g;
                    double fy = (double)y / size * g;
                    int ix = (int)Math.Floor(fx), iy = (int)Math.Floor(fy);
                    double tx = fx - ix, ty = fy - iy;
                    tx = tx * tx * (3 - 2 * tx);
                    ty = ty * ty * (3 - 2 * ty);
                    int x0 = ((ix % g) + g) % g, x1 = (x0 + 1) % g;
                    int y0 = ((iy % g) + g) % g, y1 = (y0 + 1) % g;
                    double top = table[o][y0, x0] + (table[o][y0, x1] - table[o][y0, x0]) * tx;
                    double bot = table[o][y1, x0] + (table[o][y1, x1] - table[o][y1, x0]) * tx;
                    v += (top + (bot - top) * ty) * amps[o];
                }
                v /= ampSum;
                n[y, x] = v;
                if (v < min) min = v;
                if (v > max) max = v;
            }
        }

        double span = max - min;
        if (span <= 0) span = 1;

        var light = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        var dark = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        var lr = new Rectangle(0, 0, size, size);
        var ld = light.LockBits(lr, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        var dd = dark.LockBits(lr, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        byte[] lb = new byte[ld.Stride * size];
        byte[] db = new byte[dd.Stride * size];

        for (int y = 0; y < size; y++) {
            for (int x = 0; x < size; x++) {
                double v = (n[y, x] - min) / span;      // 0..1
                int o = y * ld.Stride + x * 4;
                if (v > 0.5) {
                    lb[o] = 255; lb[o + 1] = 255; lb[o + 2] = 255;
                    lb[o + 3] = (byte)((v - 0.5) * 2.0 * maxAlpha);
                } else {
                    db[o] = 0; db[o + 1] = 0; db[o + 2] = 0;
                    db[o + 3] = (byte)((0.5 - v) * 2.0 * maxAlpha);
                }
            }
        }

        System.Runtime.InteropServices.Marshal.Copy(lb, 0, ld.Scan0, lb.Length);
        System.Runtime.InteropServices.Marshal.Copy(db, 0, dd.Scan0, db.Length);
        light.UnlockBits(ld);
        dark.UnlockBits(dd);
        return new Bitmap[] { light, dark };
    }
}
'@

$script:PetNoiseStrength = 16
$script:noisePair = [PetNoise]::Make(96, $script:PetNoiseStrength, 20261009)
$script:PetNoiseLight = $script:noisePair[0]
$script:PetNoiseDark  = $script:noisePair[1]

function Draw-CenteredSegments {
    param($Graphics, [double]$CenterX, [double]$Y, $Segments)
    $total = 0.0
    $widths = @()
    foreach ($s in $Segments) {
        $w = $Graphics.MeasureString($s.Text, $s.Font).Width
        $widths += $w
        $total += $w
    }
    $x = $CenterX - ($total / 2.0)
    for ($i = 0; $i -lt $Segments.Count; $i++) {
        $brush = New-Object System.Drawing.SolidBrush($Segments[$i].Color)
        $Graphics.DrawString($Segments[$i].Text, $Segments[$i].Font, $brush, [single]$x, [single]$Y)
        $brush.Dispose()
        $x += $widths[$i]
    }
}

function Draw-NoiseLayer {
    param($Graphics, $Ball, $Texture, [double]$Dx, [double]$Dy)
    $size = $Texture.Width
    $sx = [int]$Dx % $size; if ($sx -lt 0) { $sx += $size }
    $sy = [int]$Dy % $size; if ($sy -lt 0) { $sy += $size }
    for ($x = $Ball.X - $sx; $x -lt $Ball.Right; $x += $size) {
        for ($y = $Ball.Y - $sy; $y -lt $Ball.Bottom; $y += $size) {
            $Graphics.DrawImageUnscaled($Texture, [int]$x, [int]$y)
        }
    }
}

# Light and dark patches drift at different rates, so the pattern never looks
# like a static decal sliding past. Alpha is fine inside the ball: the chroma key
# only cares about pixels that end up exactly the key colour.
function Draw-PetNoise {
    param($Graphics, $Ball, [double]$Phase)

    $clip = New-Object System.Drawing.Drawing2D.GraphicsPath
    $clip.AddEllipse($Ball)
    $old = $Graphics.Clip
    $Graphics.SetClip($clip, [System.Drawing.Drawing2D.CombineMode]::Intersect)

    Draw-NoiseLayer -Graphics $Graphics -Ball $Ball -Texture $script:PetNoiseLight -Dx $Phase -Dy ($Phase * 0.30)
    Draw-NoiseLayer -Graphics $Graphics -Ball $Ball -Texture $script:PetNoiseDark  -Dx (-1 * $Phase * 0.62) -Dy ($Phase * 0.45)

    $Graphics.Clip = $old
    $clip.Dispose()
}

# The ball is drawn in two passes so the body can be translucent while the
# numbers stay fully opaque — the same split as the panel. Everything that
# belongs to the body (bezel, sphere, rim, drifting noise) goes on the lower
# layer; only the text goes on the upper one.
function Render-PetBall {
    param(
        [Parameter(Mandatory = $true)]$Graphics,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)]$BackgroundColor,
        [double]$Phase = 0,
        # Diameter override. The desktop ball leaves a wide margin so its numbers
        # have room; a tray icon is drawn at 16-24px and cannot afford one.
        [int]$Diameter = 0,
        # Colour override: the tray icon is allowed a brighter blue than the
        # desktop ball, whose numbers need the darker sphere behind them.
        $CoreColor = $null,
        $EdgeColor = $null
    )

    if ($Diameter -le 0) { $Diameter = $script:PetBall }
    if (-not $CoreColor) { $CoreColor = $script:PetCore }
    if (-not $EdgeColor) { $EdgeColor = $script:PetEdge }

    $Graphics.Clear($BackgroundColor)

    $cx = $Width / 2.0
    $cy = $Height / 2.0
    $r  = $Diameter / 2.0
    $ball = New-Object System.Drawing.RectangleF([single]($cx - $r), [single]($cy - $r), [single]$Diameter, [single]$Diameter)

    # thin light bezel, same family as the panel's hairline but a notch brighter:
    # the ball sits on an arbitrary desktop rather than on the panel's own dark
    # background, so it needs a little more lift to read at all.
    $bb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 96, 96, 112))
    $Graphics.FillEllipse($bb, $ball)
    $bb.Dispose()

    # sphere: bright core offset up-left, deep blue at the edge. No specular is
    # drawn on purpose; the lit look comes from the gradient's offset centre.
    $inner = [System.Drawing.RectangleF]::Inflate($ball, -$script:PetBezel, -$script:PetBezel)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddEllipse($inner)
    $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
    $pgb.CenterColor = $CoreColor
    $pgb.SurroundColors = @($EdgeColor)
    $pgb.CenterPoint = New-Object System.Drawing.PointF(
        [single]($inner.X + $inner.Width * 0.40),
        [single]($inner.Y + $inner.Height * 0.30))
    $Graphics.FillEllipse($pgb, $inner)
    $pgb.Dispose()
    $path.Dispose()

    # bottom rim light for a glass edge
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, 150, 205, 250), [single]1.5)
    $rim = [System.Drawing.RectangleF]::Inflate($inner, [single](-1.5), [single](-1.5))
    $Graphics.DrawArc($pen, $rim, 25, 130)
    $pen.Dispose()

    Draw-PetNoise -Graphics $Graphics -Ball $inner -Phase $Phase
}

function Render-PetOverlay {
    param(
        [Parameter(Mandatory = $true)]$Graphics,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][string]$InputText,
        [Parameter(Mandatory = $true)][string]$OutputText,
        [Parameter(Mandatory = $true)][string]$RateText,
        [Parameter(Mandatory = $true)]$RateColor,
        [Parameter(Mandatory = $true)]$BackgroundColor
    )

    $Graphics.Clear($BackgroundColor)

    $cx = $Width / 2.0
    $lineH = 16.0
    $startY = ($Height / 2.0) - ($lineH * 1.5) + 1

    Draw-CenteredSegments $Graphics $cx $startY @(
        @{ Text = '↑'; Color = $script:PetArrowUp; Font = $script:PetFontBold },
        @{ Text = (' ' + $InputText); Color = $script:PetText; Font = $script:PetFont })

    Draw-CenteredSegments $Graphics $cx ($startY + $lineH) @(
        @{ Text = '↓'; Color = $script:PetArrowDown; Font = $script:PetFontBold },
        @{ Text = (' ' + $OutputText); Color = $script:PetText; Font = $script:PetFont })

    Draw-CenteredSegments $Graphics $cx ($startY + $lineH * 2) @(
        @{ Text = '命中 '; Color = $script:PetText; Font = $script:PetFont },
        @{ Text = $RateText; Color = $RateColor; Font = $script:PetFontBold })
}

function Render-Pet {
    param(
        [Parameter(Mandatory = $true)]$Graphics,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][string]$InputText,
        [Parameter(Mandatory = $true)][string]$OutputText,
        [Parameter(Mandatory = $true)][string]$RateText,
        [Parameter(Mandatory = $true)]$RateColor,
        [Parameter(Mandatory = $true)]$BackgroundColor,
        [double]$Phase = 0
    )

    Render-PetBall -Graphics $Graphics -Width $Width -Height $Height -BackgroundColor $BackgroundColor -Phase $Phase
    Render-PetOverlay -Graphics $Graphics -Width $Width -Height $Height `
        -InputText $InputText -OutputText $OutputText -RateText $RateText `
        -RateColor $RateColor -BackgroundColor $BackgroundColor
}

# ---------- tray icon ----------

# The tray image is the same ball, but it fills far more of its square: the shell
# draws a notification-area icon at 16-24px, so a margin is simply wasted, and
# with no room for numbers the ball carries a K instead.
$script:IconCanvas = 144
$script:IconBall = 134
# Share of the sphere's diameter the letter spans. Deliberately short of the
# edge, so a ring of blue stays visible around the K.
$script:IconGlyph = 0.67
# Brighter than the desktop ball's blue: at tray size the sphere is only a few
# pixels across, where a mid-tone reads as murk, and the letter sits on it in
# near-white.
$script:IconCore = [System.Drawing.Color]::FromArgb(255, 92, 170, 240)
$script:IconEdge = [System.Drawing.Color]::FromArgb(255, 28, 82, 164)

function New-TrayImage {
    $big = New-Object System.Drawing.Bitmap($script:IconCanvas, $script:IconCanvas, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gb = [System.Drawing.Graphics]::FromImage($big)
    try {
        $gb.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        Render-PetBall -Graphics $gb -Width $script:IconCanvas -Height $script:IconCanvas `
            -BackgroundColor ([System.Drawing.Color]::Transparent) -Phase 0 -Diameter $script:IconBall `
            -CoreColor $script:IconCore -EdgeColor $script:IconEdge

        # The letter is measured, not guessed at: a glyph outline carries its own
        # ink box, so the font size can be solved for the height the K should
        # occupy and the shape centred on that box. Centring the *line* box
        # instead leaves it visibly low, and a guessed font size lands nowhere
        # near the target.
        $family = New-Object System.Drawing.FontFamily('Segoe UI')
        $probe = New-Object System.Drawing.Drawing2D.GraphicsPath
        $probe.AddString('K', $family, [System.Drawing.FontStyle]::Bold, [single]100,
                         (New-Object System.Drawing.PointF(0, 0)), [System.Drawing.StringFormat]::GenericDefault)
        $em = [single](100.0 * ($script:IconBall * $script:IconGlyph) / $probe.GetBounds().Height)
        $probe.Dispose()

        $glyph = New-Object System.Drawing.Drawing2D.GraphicsPath
        $glyph.AddString('K', $family, [System.Drawing.FontStyle]::Bold, $em,
                         (New-Object System.Drawing.PointF(0, 0)), [System.Drawing.StringFormat]::GenericDefault)
        $box = $glyph.GetBounds()
        $shift = New-Object System.Drawing.Drawing2D.Matrix
        $shift.Translate([single](($script:IconCanvas / 2.0) - ($box.X + $box.Width / 2.0)),
                         [single](($script:IconCanvas / 2.0) - ($box.Y + $box.Height / 2.0)))
        $glyph.Transform($shift)
        $brush = New-Object System.Drawing.SolidBrush($script:PetText)
        $gb.FillPath($brush, $glyph)
        $brush.Dispose()
        $shift.Dispose()
        $glyph.Dispose()
        $family.Dispose()
    } finally { $gb.Dispose() }

    $small = New-Object System.Drawing.Bitmap(32, 32, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gs = [System.Drawing.Graphics]::FromImage($small)
    try {
        $gs.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $gs.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $gs.DrawImage($big, (New-Object System.Drawing.Rectangle(0, 0, 32, 32)), 0, 0, $script:IconCanvas, $script:IconCanvas, [System.Drawing.GraphicsUnit]::Pixel)
    } finally { $gs.Dispose() }
    $big.Dispose()
    return $small
}
