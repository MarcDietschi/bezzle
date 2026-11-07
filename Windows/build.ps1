# Builds Bezzle for Windows and lays out the app in .build\Bezzle: the executable, the bindings'
# DLLs and their resources. Run on Windows in Windows\ (after winrt.ps1):
#
#   .\build.ps1 [-Configuration debug|release] [-Run [-Open <design.bezzle>]]

param([ValidateSet('debug', 'release')] [string]$Configuration = 'debug', [switch]$Run, [string]$Open)

$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    # The Mac's pointers (Resources/make-cursors.sh draws them on the Mac) into a resource file
    # that is linked into Bezzle.exe, where the canvas asks for them by number.
    if (Test-Path 'Resources\Generated\Bezzle.rc') {
        $rc = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter rc.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -eq ($(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' })) } |
            Sort-Object FullName | Select-Object -Last 1
        if (-not $rc) { throw 'rc.exe not found (the Windows SDK)' }
        Push-Location 'Resources\Generated'
        & $rc.FullName /nologo /fo Bezzle.res Bezzle.rc
        $failed = $LASTEXITCODE -ne 0
        Pop-Location
        if ($failed) { throw 'rc failed' }
    }
    # Through cmd: PowerShell 5 takes a compiler's warnings on stderr for errors.
    cmd /c "swift build -c $Configuration 2>&1"
    if ($LASTEXITCODE -ne 0) { throw 'swift build failed' }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
    $products = ".build\out\Products\$((Get-Culture).TextInfo.ToTitleCase($Configuration))-windows-$arch"
    $app = '.build\Bezzle'
    New-Item -ItemType Directory -Force $app | Out-Null
    Copy-Item "$products\*.exe", "$products\*.dll" $app -Force
    # The Windows App Runtime's bootstrapper, which Bezzle loads from beside itself.
    Copy-Item "$products\swift-windowsappsdk_CWinAppSDK.bundle\Microsoft.WindowsAppRuntime.Bootstrap.dll" $app -Force
    # What the core needs beside it: ICU's data for Skia's text, and the open fonts that stand in
    # for the Mac's (Web/tools/openfonts.py makes them; git-ignored, so sync.sh brings them).
    # The Mac's words in other languages (Resources/make-strings.py makes them on the Mac).
    if (Test-Path 'Resources\Generated\strings.json') { Copy-Item 'Resources\Generated\strings.json' $app -Force }
    Copy-Item 'Packages\skia\third_party\externals\icu\common\icudtl.dat' $app -Force
    Copy-Item 'Packages\skia\third_party\externals\icu\common\icudtl.dat' $products -Force
    if (Test-Path '..\Web\site\openfonts\manifest.json') {
        New-Item -ItemType Directory -Force "$app\fonts" | Out-Null
        Copy-Item '..\Web\site\openfonts\*' "$app\fonts" -Force
    }
    Write-Host "Bezzle in $(Resolve-Path $app)"
    if ($Run) {
        $arguments = if ($Open) { @("`"$Open`"") } else { @() }
        Start-Process (Resolve-Path "$app\Bezzle.exe") -WorkingDirectory (Resolve-Path $app) -ArgumentList $arguments
    }
} finally {
    Pop-Location
}
