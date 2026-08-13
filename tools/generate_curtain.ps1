Add-Type -AssemblyName System.Drawing
$resourceDir = Join-Path $PSScriptRoot '..\App\Resources'

function New-Curtain([string]$path, [bool]$dark) {
    $width = 1284
    $height = 2778
    $bitmap = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $background = if ($dark) { [System.Drawing.Color]::FromArgb(255, 10, 10, 11) } else { [System.Drawing.Color]::FromArgb(255, 250, 249, 246) }
    $ink = if ($dark) { [System.Drawing.Color]::FromArgb(255, 245, 245, 247) } else { [System.Drawing.Color]::FromArgb(255, 24, 24, 27) }
    $detail = if ($dark) { [System.Drawing.Color]::FromArgb(255, 174, 174, 181) } else { [System.Drawing.Color]::FromArgb(255, 126, 126, 134) }
    $accent = [System.Drawing.Color]::FromArgb(255, 255, 111, 66)
    $graphics.Clear($background)

    $centerX = $width / 2
    $centerY = 1280
    $radius = 66
    $trackPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(38, $detail), 22)
    $trackPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $trackPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $accentPen = New-Object System.Drawing.Pen($accent, 22)
    $accentPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $accentPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $ring = New-Object System.Drawing.RectangleF(($centerX - $radius), ($centerY - $radius), ($radius * 2), ($radius * 2))
    $graphics.DrawArc($trackPen, $ring, 0, 360)
    $graphics.DrawArc($accentPen, $ring, -90, 245)

    $titleFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 53, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $detailFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 34, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $inkBrush = New-Object System.Drawing.SolidBrush($ink)
    $detailBrush = New-Object System.Drawing.SolidBrush($detail)
    $title = -join ([char[]](0x6B63, 0x5728, 0x5237, 0x65B0, 0x5B57, 0x4F53, 0x73AF, 0x5883))
    $detailLine1 = -join ([char[]](0x6B63, 0x5728, 0x5207, 0x6362, 0x8BED, 0x8A00, 0x5E76, 0x51C6, 0x5907, 0x91CD, 0x542F, 0x7528, 0x6237, 0x7A7A, 0x95F4))
    $detailLine2 = -join ([char[]](0x8BF7, 0x52FF, 0x64CD, 0x4F5C, 0x8BBE, 0x5907))
    $graphics.DrawString($title, $titleFont, $inkBrush, (New-Object System.Drawing.RectangleF(80, 1420, 1124, 100)), $format)
    $graphics.DrawString("$detailLine1`n$detailLine2", $detailFont, $detailBrush, (New-Object System.Drawing.RectangleF(80, 1530, 1124, 145)), $format)

    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $trackPen.Dispose()
    $accentPen.Dispose()
    $titleFont.Dispose()
    $detailFont.Dispose()
    $format.Dispose()
    $inkBrush.Dispose()
    $detailBrush.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
}

New-Curtain (Join-Path $resourceDir 'ProcessingCurtainLight.png') $false
New-Curtain (Join-Path $resourceDir 'ProcessingCurtainDark.png') $true
