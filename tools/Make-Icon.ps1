# Builds PimaxGameManager.ico and assets\logo.png from the same logo shapes the app uses.
# Run from the repo folder:  powershell -STA -ExecutionPolicy Bypass -File .\tools\Make-Icon.ps1
Add-Type -AssemblyName PresentationCore, WindowsBase, PresentationFramework
$root = Split-Path $PSScriptRoot -Parent

$visor  = 'M8 20 C8 17 10 16 13 16 H51 C54 16 56 17 56 20 L58 34 C58.5 39 56 43 51 43 H40 C37 43 35.5 41.5 34.5 39.5 L33.6 37.8 C33 36.6 31 36.6 30.4 37.8 L29.5 39.5 C28.5 41.5 27 43 24 43 H13 C8 43 5.5 39 6 34 Z'
$lenses = 'M12.5 24 H27 C29 24 30.2 25.5 29.8 27.5 L28.9 32 C28.5 34 27.2 35 25.2 35 H14.5 C12 35 10.6 33.4 11 31 L11.6 26 C11.8 24.8 12 24 12.5 24 Z M51.5 24 H37 C35 24 33.8 25.5 34.2 27.5 L35.1 32 C35.5 34 36.8 35 38.8 35 H49.5 C52 35 53.4 33.4 53 31 L52.4 26 C52.2 24.8 52 24 51.5 24 Z'

function New-Grad([string[]]$colors, $start, $end) {
    $g = New-Object Windows.Media.LinearGradientBrush
    $g.StartPoint = $start; $g.EndPoint = $end
    for ($i = 0; $i -lt $colors.Count; $i++) {
        $g.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString($colors[$i])), ($i / ($colors.Count - 1))))
    }
    $g
}
$logoGrad = New-Grad @('#22D3EE', '#3B82F6', '#8B5CF6') '0,0' '1,1'
$lensGrad = New-Grad @('#1C2436', '#07090D') '0,0' '0,1'
$tileGrad = New-Grad @('#1C2130', '#0B0D12') '0,0' '0,1'

# Renders the logo on a dark rounded tile at the given pixel size
function Get-LogoBitmap([int]$size) {
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $s = $size / 64.0
    $dc.PushTransform((New-Object Windows.Media.ScaleTransform $s, $s))
    $pen = if ($size -ge 32) { New-Object Windows.Media.Pen ((New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#2E3647'))), 1.2) } else { $null }
    $dc.DrawRoundedRectangle($tileGrad, $pen, (New-Object Windows.Rect 1, 1, 62, 62), 14, 14)
    $dc.PushTransform((New-Object Windows.Media.TranslateTransform 0, 2.5))
    $dc.DrawGeometry($logoGrad, $null, [Windows.Media.Geometry]::Parse($visor))
    $dc.DrawGeometry($lensGrad, $null, [Windows.Media.Geometry]::Parse($lenses))
    if ($size -ge 32) {
        $hl = New-Object Windows.Media.Pen ((New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x70, 255, 255, 255))), 1.2)
        $hl.StartLineCap = 'Round'; $hl.EndLineCap = 'Round'
        $dc.DrawGeometry($null, $hl, [Windows.Media.Geometry]::Parse('M15 19 H49'))
        $gl = New-Object Windows.Media.Pen ((New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0xA0, 255, 255, 255))), 1.3)
        $gl.StartLineCap = 'Round'; $gl.EndLineCap = 'Round'
        $dc.DrawGeometry($null, $gl, [Windows.Media.Geometry]::Parse('M15.5 27.5 H20.5 M38.5 27.5 H43.5'))
    }
    $dc.Pop(); $dc.Pop(); $dc.Close()
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap $size, $size, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $rtb
}
function Get-Png($bmp) {
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $ms = New-Object IO.MemoryStream; $enc.Save($ms); $ms.ToArray()
}
# Classic 32-bit icon image (BITMAPINFOHEADER + bottom-up BGRA + AND mask); readable by every Windows API, unlike small PNG entries
function Get-Dib($bmp) {
    $z = $bmp.PixelWidth
    $conv = New-Object Windows.Media.Imaging.FormatConvertedBitmap $bmp, ([Windows.Media.PixelFormats]::Bgra32), $null, 0
    $px = New-Object byte[] ($z * $z * 4); $conv.CopyPixels($px, $z * 4, 0)
    $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ms
    $w.Write([uint32]40); $w.Write([int32]$z); $w.Write([int32]($z * 2)); $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]0); $w.Write([uint32]($z * $z * 4)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    for ($y = $z - 1; $y -ge 0; $y--) { $w.Write($px, $y * $z * 4, $z * 4) }
    $maskRow = [int]([Math]::Ceiling($z / 32.0) * 4)
    $w.Write((New-Object byte[] ($maskRow * $z)))
    $w.Flush(); $ms.ToArray()
}

# .ico: bitmap images up to 128 px, PNG for 256 px
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$pngs = foreach ($z in $sizes) { $b = Get-LogoBitmap $z; if ($z -ge 256) { ,(Get-Png $b) } else { ,(Get-Dib $b) } }
$ms = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter $ms
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $z = $sizes[$i]; $len = $pngs[$i].Length
    $bw.Write([byte]($z % 256)); $bw.Write([byte]($z % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($p in $pngs) { $bw.Write([byte[]]$p) }
$bw.Flush()
[IO.File]::WriteAllBytes((Join-Path $root 'PimaxGameManager.ico'), $ms.ToArray())

$assets = Join-Path $root 'assets'
if (-not (Test-Path $assets)) { New-Item -ItemType Directory $assets | Out-Null }
[IO.File]::WriteAllBytes((Join-Path $assets 'logo.png'), (Get-Png (Get-LogoBitmap 512)))
"Wrote PimaxGameManager.ico ($($sizes -join ', ') px) and assets\logo.png"
