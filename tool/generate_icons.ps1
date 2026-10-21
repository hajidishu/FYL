# Regenerate the native icons from the geometry in assets/brand/mark.svg.
# Uses only .NET drawing APIs; no external image tools are required.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$macIconRoot = Join-Path $projectRoot 'macos\Runner\Assets.xcassets\AppIcon.appiconset'
$pngs = @{}
foreach ($size in @(16, 32, 48, 64, 128, 256, 512, 1024)) {
    $bitmap = [Drawing.Bitmap]::new($size, $size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.ScaleTransform(($size / 64.0), ($size / 64.0))
    $shape = [Drawing.Drawing2D.GraphicsPath]::new()
    $shape.AddArc(0, 0, 28, 28, 180, 90)
    $shape.AddArc(36, 0, 28, 28, 270, 90)
    $shape.AddArc(36, 36, 28, 28, 0, 90)
    $shape.AddArc(0, 36, 28, 28, 90, 90)
    $shape.CloseFigure()
    $brush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#192b23'))
    $graphics.FillPath($brush, $shape)
    $points = [Drawing.PointF[]]@([Drawing.PointF]::new(32,13), [Drawing.PointF]::new(49,22.5),
        [Drawing.PointF]::new(49,41.5), [Drawing.PointF]::new(32,51), [Drawing.PointF]::new(15,41.5), [Drawing.PointF]::new(15,22.5))
    $brush.Color = [Drawing.ColorTranslator]::FromHtml('#284b3a')
    $graphics.FillPolygon($brush, $points)
    $pen = [Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml('#a3e5c4'), 2.6)
    $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
    $graphics.DrawPolygon($pen, $points)
    $graphics.DrawLines($pen, [Drawing.PointF[]]@([Drawing.PointF]::new(15,22.5), [Drawing.PointF]::new(32,32), [Drawing.PointF]::new(49,22.5)))
    $graphics.DrawLine($pen, 32, 32, 32, 51)
    $stream = [IO.MemoryStream]::new()
    $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
    $pngs[$size] = $stream.ToArray()
    if ($size -ne 48) { [IO.File]::WriteAllBytes((Join-Path $macIconRoot "app_icon_$size.png"), $pngs[$size]) }
    if ($size -eq 256) { [IO.File]::WriteAllBytes((Join-Path $projectRoot 'assets\brand\icon.png'), $pngs[$size]) }
    $stream.Dispose(); $pen.Dispose(); $brush.Dispose(); $shape.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
}
$sizes = @(16, 32, 48, 64, 128, 256)
$iconStream = [IO.MemoryStream]::new()
$writer = [IO.BinaryWriter]::new($iconStream)
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
foreach ($size in $sizes) {
    $dimension = if ($size -eq 256) { 0 } else { $size }
    $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
    $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$pngs[$size].Length); $writer.Write([uint32]$offset)
    $offset += $pngs[$size].Length
}
foreach ($size in $sizes) { $writer.Write([byte[]]$pngs[$size]) }
$writer.Flush()
[IO.File]::WriteAllBytes((Join-Path $projectRoot 'windows\runner\resources\app_icon.ico'), $iconStream.ToArray())
$writer.Dispose(); $iconStream.Dispose()
