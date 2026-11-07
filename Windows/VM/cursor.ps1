# Draws the pointer Windows shows now into a PNG, on grey, since a screenshot of the VM leaves it
# out. In the VM at C:\bezzle\cursor.ps1, run through Windows/VM/desktop:
#   powershell -ExecutionPolicy Bypass -File C:\bezzle\cursor.ps1 -Out C:\bezzle\c.png
param([string]$Out = 'C:\bezzle\cursor.png')
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class BezzleCursor {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int cbSize, flags; public IntPtr hCursor; public POINT pt; }
    [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO info);
    [DllImport("user32.dll")] public static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr icon, int w, int h, int step, IntPtr brush, int flags);
    public static IntPtr Now() { var i = new CURSORINFO(); i.cbSize = Marshal.SizeOf(i); GetCursorInfo(ref i); return i.hCursor; }
}
"@
$h = [BezzleCursor]::Now()
$bmp = New-Object System.Drawing.Bitmap 48, 48
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(150, 150, 150))
$dc = $g.GetHdc()
[BezzleCursor]::DrawIconEx($dc, 8, 8, $h, 0, 0, 0, [IntPtr]::Zero, 3) | Out-Null
$g.ReleaseHdc($dc)
$bmp.Save($Out)
"cursor $h"
