# Pointer and keys in the Bezzle test VM's desktop session, for trying the app without anyone at
# it: run through Windows/VM/desktop. Coordinates are the VM screen's pixels.
#   . C:\bezzle\input.ps1; Drag 500 360 560 420; Key 0x2E
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class BezzleInput {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
}
"@
# Real input, as a mouse moved there (SetCursorPos alone makes no pointer events for WinUI).
function MoveTo([int]$x, [int]$y) {
    $w = [BezzleInput]::GetSystemMetrics(0); $h = [BezzleInput]::GetSystemMetrics(1)
    [BezzleInput]::mouse_event(0x8001, [uint32]($x * 65535 / ($w - 1)), [uint32]($y * 65535 / ($h - 1)), 0, [UIntPtr]::Zero)
}
function Down { [BezzleInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) }
function Up { [BezzleInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) }
function Click([int]$x, [int]$y) { MoveTo $x $y; Start-Sleep -Milliseconds 80; Down; Start-Sleep -Milliseconds 60; Up }
function Drag([int]$x, [int]$y, [int]$tx, [int]$ty, [int]$steps = 12) {
    MoveTo $x $y; Start-Sleep -Milliseconds 100; Down
    for ($i = 1; $i -le $steps; $i++) {
        MoveTo ([int]($x + ($tx - $x) * $i / $steps)) ([int]($y + ($ty - $y) * $i / $steps))
        Start-Sleep -Milliseconds 40
    }
    Start-Sleep -Milliseconds 100; Up
}
function Key([byte]$vk, [byte]$modifier = 0) {
    if ($modifier) { [BezzleInput]::keybd_event($modifier, 0, 0, [UIntPtr]::Zero) }
    [BezzleInput]::keybd_event($vk, 0, 0, [UIntPtr]::Zero); [BezzleInput]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
    if ($modifier) { [BezzleInput]::keybd_event($modifier, 0, 2, [UIntPtr]::Zero) }
}
# The wheel turned where the pointer is: positive away from you (up), in notches of 120.
function Wheel([int]$amount) { [BezzleInput]::mouse_event(0x0800, 0, 0, [BitConverter]::ToUInt32([BitConverter]::GetBytes($amount), 0), [UIntPtr]::Zero) }
