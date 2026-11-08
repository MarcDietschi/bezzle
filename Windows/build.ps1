# Builds Bezzle for Windows and lays out the app in .build\Bezzle: the executable, the bindings'
# DLLs and their resources. Run on Windows in Windows\ (after winrt.ps1):
#
#   .\build.ps1 [-Configuration debug|release] [-Arch arm64|x64] [-Jobs n] [-Product Bezzle] [-Runtime]
#               [-Run [-Open <design.bezzle>]]
#
# The architecture is the machine's own unless named. x64 is built on an Arm machine too (Swift
# cross-compiles, `swift build --arch x86_64`), into .build\x64 with the app in .build\x64\Bezzle,
# from the x64 builds of Skia (skia.ps1 -Arch x64) and AVIF (avif.ps1 -Arch x64). An x64 layout
# carries Swift's and Visual C++'s runtimes beside Bezzle.exe (runtime.ps1), since the Swift on an
# Arm machine's path is the Arm one; -Runtime does the same for an Arm build.

param(
    [ValidateSet('debug', 'release')] [string]$Configuration = 'debug',
    [ValidateSet('arm64', 'x64')] [string]$Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),
    [int]$Jobs = 0,
    [string]$Product,
    [switch]$Runtime,
    [switch]$Run,
    [string]$Open
)

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
    # Arm builds where it always has; x64 beside it, with Package.swift told to link x64's libraries.
    $triple = if ($Arch -eq 'x64') { 'x86_64' } else { 'aarch64' }
    $scratch = if ($Arch -eq 'x64') { '.build\x64' } else { '.build' }
    # A release build makes the app alone unless told otherwise: bezzle-share reaches into the core
    # with @testable, which only a debug build allows.
    if (-not $Product -and $Configuration -eq 'release') { $Product = 'Bezzle' }
    $options = "-c $Configuration"
    if ($Arch -eq 'x64') { $options += " --arch x86_64 --scratch-path $scratch" }
    if ($Jobs -gt 0) { $options += " -j $Jobs" }
    if ($Product) { $options += " --product $Product" }
    $env:BEZZLE_ARCH = $Arch
    # Through cmd: PowerShell 5 takes a compiler's warnings on stderr for errors.
    cmd /c "swift build $options 2>&1"
    if ($LASTEXITCODE -ne 0) { throw 'swift build failed' }
    $products = "$scratch\out\Products\$((Get-Culture).TextInfo.ToTitleCase($Configuration))-windows-$triple"
    $app = "$scratch\Bezzle"
    New-Item -ItemType Directory -Force $app | Out-Null
    Copy-Item "$products\*.exe", "$products\*.dll" $app -Force
    # The Windows App Runtime's bootstrapper, which Bezzle loads from beside itself: the bindings
    # carry the machine's own (winrt.ps1), the Windows App SDK release every architecture's.
    if ($Arch -eq 'x64') {
        Copy-Item 'Packages\windowsappsdk-1.7.250909003\runtimes\win-x64\native\Microsoft.WindowsAppRuntime.Bootstrap.dll' $app -Force
    } else {
        Copy-Item "$products\swift-windowsappsdk_CWinAppSDK.bundle\Microsoft.WindowsAppRuntime.Bootstrap.dll" $app -Force
    }
    # What the core needs beside it: ICU's data for Skia's text, and the open fonts that stand in
    # for the Mac's (Web/tools/openfonts.py makes them; git-ignored, so sync.sh brings them).
    # The Mac's words in other languages (Resources/make-strings.py makes them on the Mac).
    if (Test-Path 'Resources\Generated\strings.json') { Copy-Item 'Resources\Generated\strings.json' $app -Force }
    # The licences of what Bezzle is made with, which About Bezzle shows (Credits/licenses).
    New-Item -ItemType Directory -Force "$app\licenses" | Out-Null
    Copy-Item 'Credits\licenses\*' "$app\licenses" -Recurse -Force
    # The icon library, where Foundation looks for an executable's resources on Windows
    # (Bundle.main.resourceURL is Bezzle.resources beside it), as Icons.swift reads it from the Mac's bundle.
    New-Item -ItemType Directory -Force "$app\Bezzle.resources" | Out-Null
    Copy-Item 'Sources\BezzleCore\Shared\Model\Kits\Icons.deflate' "$app\Bezzle.resources" -Force
    Copy-Item 'Packages\skia\third_party\externals\icu\common\icudtl.dat' $app -Force
    Copy-Item 'Packages\skia\third_party\externals\icu\common\icudtl.dat' $products -Force
    if (Test-Path '..\Web\site\openfonts\manifest.json') {
        New-Item -ItemType Directory -Force "$app\fonts" | Out-Null
        Copy-Item '..\Web\site\openfonts\*' "$app\fonts" -Force
    }
    # Swift's and Visual C++'s runtimes, for x64 always, beside the tools in Products too (the
    # tests run bezzle-render from there).
    if ($Arch -eq 'x64' -or $Runtime) {
        & "$PSScriptRoot\runtime.ps1" -Arch $Arch -App $app
        & "$PSScriptRoot\runtime.ps1" -Arch $Arch -App $products
    }
    Write-Host "Bezzle in $(Resolve-Path $app)"
    if ($Run) {
        $arguments = if ($Open) { @("`"$Open`"") } else { @() }
        Start-Process (Resolve-Path "$app\Bezzle.exe") -WorkingDirectory (Resolve-Path $app) -ArgumentList $arguments
    }
} finally {
    Pop-Location
}
