<#
.SYNOPSIS
    Draws the bear face. Dot-sourced by Hibearnate.ps1 (tray icons) and by
    Install.ps1 (the shortcut icon), so there is one copy of the drawing.

.DESCRIPTION
    Needs only System.Drawing, so Install.ps1 can use it without compiling
    the C# helper. Defines functions and nothing else: dot-sourcing it has
    no side effect.
#>

Add-Type -AssemblyName System.Drawing

# A bear face. The coordinates are for 32 px; other sizes scale the drawing.
# Awake = open eyes, otherwise closed (sleeping). Auto adds a white badge,
# so the mode never depends on color alone.
function New-BearBitmap([System.Drawing.Color]$Fur, [bool]$Awake, [bool]$Auto, [int]$Size = 32) {
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.ScaleTransform($Size / 32.0, $Size / 32.0)
    $dark = [System.Drawing.Color]::FromArgb(40, 30, 25)
    # Not $fur: PowerShell names ignore case, so that is the typed $Fur parameter.
    $furBrush = New-Object System.Drawing.SolidBrush $Fur
    $ink = New-Object System.Drawing.SolidBrush $dark

    $g.FillEllipse($furBrush, 2, 2, 11, 11)    # ears
    $g.FillEllipse($furBrush, 19, 2, 11, 11)
    $g.FillEllipse($furBrush, 3, 5, 26, 25)    # head
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(245, 236, 222))), 10, 16, 12, 10)  # snout
    $g.FillEllipse($ink, 14, 17, 4, 3)    # nose
    if ($Awake) {
        $g.FillEllipse($ink, 9, 11, 4, 4)
        $g.FillEllipse($ink, 19, 11, 4, 4)
    } else {
        # Sleeping eyes: the lower half of an ellipse, like a closed lid.
        $pen = New-Object System.Drawing.Pen $dark, 2
        $g.DrawArc($pen, 8, 9, 6, 5, 0, 180)
        $g.DrawArc($pen, 18, 9, 6, 5, 0, 180)
    }
    if ($Auto) {
        $g.FillEllipse([System.Drawing.Brushes]::White, 21, 21, 10, 10)
        $g.DrawEllipse((New-Object System.Drawing.Pen $dark, 1.5), 21, 21, 10, 10)
    }
    $g.Dispose()
    $bmp
}

# Writes the sleeping green bear (the Away icon) as a .ico file with PNG
# images at the sizes Explorer and the Start menu ask for. Icon.Save is not
# used: on an icon made from GetHicon it drops the alpha channel.
# Writes to a .tmp file first, so a failure never leaves half an icon.
function Save-BearIco([string]$Path) {
    $sizes = 16, 24, 32, 48, 64, 256
    $images = foreach ($size in $sizes) {
        $bmp = New-BearBitmap ([System.Drawing.Color]::SeaGreen) $false $false $size
        $png = New-Object System.IO.MemoryStream
        $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        , $png.ToArray()  # the comma keeps the byte array as one item
    }

    $out = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $out
    $w.Write([uint16]0)               # reserved
    $w.Write([uint16]1)               # type: icon
    $w.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count   # header, then one 16-byte entry per image
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }  # 0 means 256
        $w.Write([byte]$dim)          # width
        $w.Write([byte]$dim)          # height
        $w.Write([byte]0)             # palette colors
        $w.Write([byte]0)             # reserved
        $w.Write([uint16]1)           # planes
        $w.Write([uint16]32)          # bits per pixel
        $w.Write([uint32]$images[$i].Length)
        $w.Write([uint32]$offset)
        $offset += $images[$i].Length
    }
    foreach ($png in $images) { $w.Write($png) }
    $w.Flush()

    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllBytes($tmp, $out.ToArray())
    $w.Dispose()
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
