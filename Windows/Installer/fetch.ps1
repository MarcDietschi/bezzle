# Fetches what the installer is made with, each pinned to a version and its SHA-256 and taken only
# from where its makers publish it, into a cache folder (Windows\Packages\installer by default,
# git-ignored):
#
#   Inno Setup 6.7.3        the installer's compiler (jrsoftware.org links its downloads to GitHub)
#   WinSparkle 0.9.4        the updater, MIT, by Vaclav Slavik (GitHub releases)
#   Windows App Runtime     1.7.250909003, the release Bezzle's WinUI bindings are made for, per
#                           architecture (Microsoft's download center, as aka.ms/windowsappsdk sends)
#
#   .\fetch.ps1 [-Cache <folder>]
#
# Inno Setup is unpacked there without being installed (its own installer's /PORTABLE=1), so
# nothing on the machine changes. Prints the folders it made, which make-installer.ps1 reads.

param([string]$Cache = (Join-Path $PSScriptRoot '..\Packages\installer'))

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force $Cache | Out-Null
$Cache = (Resolve-Path $Cache).Path

$inno = '6.7.3'
$winSparkle = '0.9.4'
$runtime = '1.7.250909003'
$downloads = @(
    @{ File = "innosetup-$inno.exe"; Url = "https://github.com/jrsoftware/issrc/releases/download/is-$($inno -replace '\.', '_')/innosetup-$inno.exe"
       Sha = '9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732' },
    @{ File = "WinSparkle-$winSparkle.zip"; Url = "https://github.com/vslavik/winsparkle/releases/download/v$winSparkle/WinSparkle-$winSparkle.zip"
       Sha = '6037df37fc263bd1650a1c4949681a9d40ffe991d01f35892a406cb5d103c976' },
    @{ File = "WindowsAppRuntimeInstall-$runtime-arm64.exe"; Url = 'https://download.microsoft.com/download/be2d34e3-9fa0-4b17-9340-7533f927f747/WindowsAppRuntimeInstall-arm64.exe'
       Sha = 'bdcf82fa00773b0656379a36f7ebe44ef4072bd088103109bad0d1ad843bf880' },
    @{ File = "WindowsAppRuntimeInstall-$runtime-x64.exe"; Url = 'https://download.microsoft.com/download/a03bdcf6-0fae-46af-8cbb-aea631168b0c/WindowsAppRuntimeInstall-x64.exe'
       Sha = 'a3780c756357cd519b481080de88bdacd661b5a2d5c1c828d25b90913abbd1b9' }
)
foreach ($d in $downloads) {
    $path = Join-Path $Cache $d.File
    if (-not (Test-Path $path) -or (Get-FileHash $path -Algorithm SHA256).Hash -ne $d.Sha.ToUpper()) {
        Write-Host "Fetching $($d.File)"
        Invoke-WebRequest $d.Url -OutFile "$path.part" -UseBasicParsing
        $hash = (Get-FileHash "$path.part" -Algorithm SHA256).Hash
        if ($hash -ne $d.Sha.ToUpper()) {
            Remove-Item "$path.part"
            throw "$($d.File) is not the download pinned here ($hash)"
        }
        Move-Item -Force "$path.part" $path
    }
}
# The executables carry their makers' signatures too: Microsoft's, and Inno Setup's publisher's.
foreach ($exe in @("innosetup-$inno.exe", "WindowsAppRuntimeInstall-$runtime-arm64.exe", "WindowsAppRuntimeInstall-$runtime-x64.exe")) {
    $signature = Get-AuthenticodeSignature (Join-Path $Cache $exe)
    if ($signature.Status -ne 'Valid') { throw "$exe is not validly signed ($($signature.Status))" }
}

$innoDir = Join-Path $Cache "innosetup-$inno"
if (-not (Test-Path "$innoDir\ISCC.exe")) {
    $p = Start-Process (Join-Path $Cache "innosetup-$inno.exe") -Wait -PassThru -ArgumentList `
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', '/PORTABLE=1', "/DIR=`"$innoDir`""
    if ($p.ExitCode -ne 0 -or -not (Test-Path "$innoDir\ISCC.exe")) { throw "Inno Setup could not be unpacked ($($p.ExitCode))" }
}
$sparkleDir = Join-Path $Cache "WinSparkle-$winSparkle"
if (-not (Test-Path "$sparkleDir\ARM64\Release\WinSparkle.dll")) {
    Expand-Archive (Join-Path $Cache "WinSparkle-$winSparkle.zip") "$Cache\winsparkle.part" -Force
    Move-Item "$Cache\winsparkle.part\WinSparkle-$winSparkle" $sparkleDir
    Remove-Item -Recurse -Force "$Cache\winsparkle.part"
}
[pscustomobject]@{
    ISCC       = "$innoDir\ISCC.exe"
    WinSparkle = $sparkleDir
    Runtime    = @{ arm64 = Join-Path $Cache "WindowsAppRuntimeInstall-$runtime-arm64.exe"; x64 = Join-Path $Cache "WindowsAppRuntimeInstall-$runtime-x64.exe" }
}
