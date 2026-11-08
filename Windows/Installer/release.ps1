# The Windows half of Scripts/release-windows.sh, run in the build VM in the folder the Mac copied
# the release's commit into (C:\src\bezzle-release by default): builds Bezzle in release for each
# architecture, lays it out (build.ps1) and makes its installer (make-installer.ps1), with the
# updater, the feed and the key Bezzle's updates are signed with. Prints each installer, one line
# of JSON each, last.
#
#   .\release.ps1 -Version 1.4.2 -Build 20261108.1200 -Archs arm64,x64 -Feed <url> -PublicKey <key>
#       [-Cache <fetch.ps1's folder>] [-Jobs 2]

param(
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [string]$Build,
    [string[]]$Archs = @('x64', 'arm64'),
    [Parameter(Mandatory)] [string]$Feed,
    [Parameter(Mandatory)] [string]$PublicKey,
    [string]$Cache = 'C:\bezzle\release-cache',
    [int]$Jobs = 2
)

$ErrorActionPreference = 'Stop'
$windows = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $windows
# The packages every Bezzle build shares (Skia, the WinUI bindings, libavif…), never changed here.
if (-not (Test-Path "$windows\Packages")) {
    cmd /c mklink /J "$windows\Packages" 'C:\src\Bezzle\Windows\Packages' | Out-Null
}
$native = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$made = @()
foreach ($arch in $Archs) {
    Write-Host "Building Bezzle $Version ($Build) for $arch…"
    $started = Get-Date
    if ($arch -eq $native) {
        # Through cmd: PowerShell 5 takes a compiler's warnings on stderr for errors.
        $log = cmd /c "swift build -c release -j $Jobs --product Bezzle 2>&1"
        if ($LASTEXITCODE -ne 0) { $log | Select-String 'error' | Select-Object -Last 20; throw "Bezzle did not build for $arch" }
        .\build.ps1 release | Out-Null
    } else {
        # Another architecture is built across (build.ps1 -Arch), into .build\Bezzle-<arch>.
        .\build.ps1 release -Arch $arch | Out-Null
    }
    Write-Host "  built in $([int]((Get-Date) - $started).TotalMinutes) min"
    $result = & "$PSScriptRoot\make-installer.ps1" -Arch $arch -Version $Version -Build $Build -Feed $Feed -PublicKey $PublicKey -Cache $Cache | Select-Object -Last 1
    $made += $result
}
foreach ($m in $made) { $m | ConvertTo-Json -Compress }
