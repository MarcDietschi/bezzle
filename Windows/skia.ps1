# Builds Skia for Bezzle on Windows into Windows\Packages\skia (git-ignored): the Skia of the web
# core's CanvasKit 0.42.0, so designs draw and text measures as they do in the browser, with its
# paragraphs (skparagraph, skshaper, skunicode on ICU, HarfBuzz) and FreeType, as CanvasKit has
# them. Static libraries, in out\<arch>, against the DLL C runtime that Swift uses (/MD). Run on
# Windows in Windows\:
#
#   .\skia.ps1 [-Arch arm64|x64] [-Jobs 2] [-Fetch]     # -Fetch: only clone Skia and its dependencies
#
# The architecture is the machine's own unless named. x64 is made on an Arm machine too: the same
# clang-cl, told the x64 target (Skia tells it only arm64's), over Visual Studio's x64 libraries.
param(
    [ValidateSet('arm64', 'x64')] [string]$Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),
    [int]$Jobs = 0,
    [switch]$Fetch
)

$ErrorActionPreference = 'Stop'
$commit = 'e2def78fa232884d4aedcf3ad92d4a0dd673b898'   # canvaskit/0.42.0
$skia = Join-Path $PSScriptRoot 'Packages\skia'
$cpu = $Arch

if (-not (Test-Path "$skia\.git")) { git clone --quiet https://skia.googlesource.com/skia.git $skia }
# Fetched and checked out only when it is not that commit already, so that building another
# architecture beside a first leaves the checkout as it is.
if ((git -C $skia rev-parse HEAD) -ne $commit) {
    git -C $skia fetch --quiet origin $commit
    git -C $skia checkout --quiet --force $commit
}
Push-Location $skia
try {
    # Its last step, fetch-gn, fails on Windows on Arm: gn has no arm64 build there (404). The x64
    # one runs under emulation, so it is fetched here, at the revision fetch-gn names.
    $ErrorActionPreference = 'Continue'
    if (-not (Test-Path bin\gn.exe)) { python tools\git-sync-deps }
    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path bin\gn.exe)) {
        $rev = (Select-String bin\fetch-gn -Pattern "rev = '([0-9a-f]+)'").Matches[0].Groups[1].Value
        Invoke-WebRequest "https://chrome-infra-packages.appspot.com/dl/gn/gn/windows-amd64/+/git_revision:$rev" -OutFile bin\gn.zip -UseBasicParsing
        Expand-Archive bin\gn.zip bin -Force
        Remove-Item bin\gn.zip
        New-Item -ItemType Directory -Force third_party\gn | Out-Null
        Copy-Item bin\gn.exe third_party\gn\gn.exe
    }
    if (-not (Test-Path bin\gn.exe)) { throw 'no gn' }
    if ($Fetch) { return }

    # The build's settings, in args.gn, where gn reads them (PowerShell 5 mangles the quotes in
    # a --args=… argument). clang-cl targets the machine it runs on unless told: Skia's build
    # says arm64 itself, so x64 is said here (also right on an x64 machine).
    $flags = if ($cpu -eq 'x64') { '"/MD", "--target=x86_64-pc-windows-msvc"' } else { '"/MD"' }
    $settings = @(
        "target_cpu = `"$cpu`"", 'is_official_build = true', 'is_debug = false', 'is_component_build = false',
        'clang_win = "C:/Program Files/LLVM"',
        'skia_use_system_expat = false', 'skia_use_system_freetype2 = false', 'skia_use_system_harfbuzz = false',
        'skia_use_system_icu = false', 'skia_use_system_libjpeg_turbo = false', 'skia_use_system_libpng = false',
        'skia_use_system_libwebp = false', 'skia_use_system_zlib = false',
        'skia_use_freetype = true', 'skia_enable_fontmgr_custom_empty = true', 'skia_enable_fontmgr_win = false',
        'skia_use_icu = true', 'skia_use_harfbuzz = true',
        'skia_enable_skshaper = true', 'skia_enable_skparagraph = true', 'skia_enable_skunicode = true',
        'skia_enable_pdf = true', 'skia_use_dng_sdk = false', 'skia_use_gl = false',
        "extra_cflags = [ $flags ]"
    )
    New-Item -ItemType Directory -Force "out\$cpu" | Out-Null
    Set-Content "out\$cpu\args.gn" ($settings -join "`n") -Encoding Ascii
    & bin\gn gen "out\$cpu"
    if ($LASTEXITCODE -ne 0) { throw 'gn gen failed' }
    $parallel = if ($Jobs -gt 0) { @('-j', "$Jobs") } else { @() }
    ninja -C "out\$cpu" @parallel skia skparagraph skshaper skunicode_core skunicode_icu
    if ($LASTEXITCODE -ne 0) { throw 'ninja failed' }
} finally {
    Pop-Location
}
Write-Host "Skia for $cpu in $skia\out\$cpu"
