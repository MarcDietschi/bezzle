# Builds AVIF reading and writing for Bezzle on Windows into Windows\Packages\avif (git-ignored):
# libavif with libaom for both directions, as static libraries against the DLL C runtime that Swift
# uses (/MD), with CMake, Ninja and the Swift toolchain's clang over the Visual Studio C++ headers
# and libraries. Each comes from its project's own
# release downloads at the version pinned here and is checked against the SHA-256 written beside
# it. Package.swift links them into CBezzleHost when they are there (Sources/CBezzleHost/avif.cpp
# then reads and writes AVIF); without them Bezzle on Windows neither reads nor writes it.
# Run on Windows in Windows\:
#
#   .\avif.ps1 [-Arch arm64|x64] [-Jobs 2]
#
# x64 is made on an Arm machine too (the tools cross-compile), and then needs NASM for libaom's x86
# code, which is fetched the same way. Licences: libavif and libaom are BSD-2-Clause, libaom also
# comes under the Alliance for Open Media Patent License 1.0; their texts are kept in
# Packages\avif\licenses.
#
# One line differs from the downloads, in libavif's reading: the Mac's Image I/O writes a picture
# over about a megapixel as a grid of 512-pixel cells, also when it is an odd number of pixels wide
# or high (a 2401 × 1601 artboard). MIAF wants a 4:2:0 grid's size even, and libavif refuses such a
# file; here it checks only that the cells are even, which is what makes putting them together
# safe (each cell's colour falls on whole samples), and reads it as Image I/O does.
#
# How the encoder was matched to the Mac's (sizes and PSNR at each quality, the alpha, colours,
# orientation, odd sizes): see the comments in Sources/CBezzleHost/avif.cpp.

param(
    [ValidateSet('arm64', 'x64')] [string]$Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),
    [int]$Jobs = 2
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$downloads = [ordered]@{
    'libaom-3.15.3' = @{
        Url = 'https://storage.googleapis.com/aom-releases/libaom-3.15.3.tar.gz'
        Sha256 = '12c01dc731ed7b5a999e28120b45bf58a002ba3435a4ba2cfbc1e084a27c9c04'
    }
    'libavif-1.4.2' = @{
        Url = 'https://github.com/AOMediaCodec/libavif/archive/refs/tags/v1.4.2.tar.gz'
        Sha256 = '2b645287340ba5a631d268b551dc2d72bd73ac33335962dd36dcdb6d8366921d'
    }
    'nasm-3.01' = @{
        Url = 'https://www.nasm.us/pub/nasm/releasebuilds/3.01/win64/nasm-3.01-win64.zip'
        Sha256 = 'e0ba5157007abc7b1a65118a96657a961ddf55f7e3f632ee035366dfce039ca4'
        Zip = $true
    }
}
$root = Join-Path $PSScriptRoot 'Packages\avif'
$fetched = Join-Path $root 'downloads'
$sources = Join-Path $root 'src'
$work = Join-Path $root "build\$Arch"
$out = Join-Path $root "out\$Arch"

# Fetches and unpacks one download into src\, afresh, after checking it is the one pinned.
function Unpack([string]$name) {
    $d = $downloads[$name]
    New-Item -ItemType Directory -Force $fetched, $sources | Out-Null
    $file = Join-Path $fetched ($d.Url -replace '.*/', '')
    if (-not (Test-Path $file)) { Invoke-WebRequest $d.Url -OutFile $file -UseBasicParsing }
    $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $d.Sha256) {
        Remove-Item $file
        throw "$name is not the file pinned: SHA-256 $hash, not $($d.Sha256)"
    }
    $dir = Join-Path $sources $name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    if ($d.Zip) {
        Expand-Archive $file $sources -Force
    } else {
        if ((Run 'tar.exe' @('-x', '-f', $file, '-C', $sources)) -ne 0) { throw "$name could not be unpacked" }
    }
    if (-not (Test-Path $dir)) { throw "$name did not unpack into $dir" }
    return $dir
}

# The Visual Studio C++ tools' environment for the architecture, as vcvarsall sets it, here.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
if (-not $vs) { $vs = & $vswhere -latest -products * -property installationPath }
if (-not $vs) { throw 'The Visual Studio C++ tools are not installed (VM/provision.ps1 installs them)' }
$hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$target = if ($hostArch -eq $Arch) { $Arch } else { "${hostArch}_$Arch" }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
foreach ($line in (cmd /c "`"$vcvars`" $target >nul && set")) {
    $k = $line.IndexOf('=')
    if ($k -gt 0) { [Environment]::SetEnvironmentVariable($line.Substring(0, $k), $line.Substring($k + 1), 'Process') }
}
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw "vcvarsall $target set up no compiler" }

$cmake = 'C:\Program Files\CMake\bin\cmake.exe'
if (-not (Test-Path $cmake)) { $cmake = (Get-Command cmake).Source }
$ninja = 'C:\Tools\bin\ninja.exe'
if (-not (Test-Path $ninja)) { $ninja = (Get-Command ninja).Source }
# libaom makes its CPU dispatch tables with Perl, which Git for Windows brings.
$perl = 'C:\Program Files\Git\usr\bin\perl.exe'
if (-not (Test-Path $perl)) { $perl = (Get-Command perl).Source }

# The compiler: the Swift toolchain's clang, with its GNU-style driver, against the Visual Studio
# headers and libraries set up above. Not MSVC's cl: libaom asks for its Arm extensions (dot
# product, i8mm) with -march flags, which cl ignores while its checks still pass, and libaom built
# so read lossy 4:4:4 and 10-bit AVIF files wrongly (colour streaks; the same files read right
# with clang, byte for byte as on the Mac).
$clang = (Get-Command clang.exe).Source
$llvm = Split-Path $clang
$triple = if ($Arch -eq 'x64') { 'x86_64-pc-windows-msvc' } else { 'aarch64-pc-windows-msvc' }
$common = @(
    '-G', 'Ninja', "-DCMAKE_MAKE_PROGRAM=$ninja", '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=OFF',
    "-DCMAKE_C_COMPILER=$clang", "-DCMAKE_CXX_COMPILER=$llvm\clang++.exe", "-DCMAKE_C_COMPILER_TARGET=$triple",
    "-DCMAKE_CXX_COMPILER_TARGET=$triple", "-DCMAKE_AR=$llvm\llvm-ar.exe", "-DCMAKE_RANLIB=$llvm\llvm-ranlib.exe",
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL', "-DCMAKE_INSTALL_PREFIX=$out"
)
if ($hostArch -ne $Arch) { $common += @('-DCMAKE_SYSTEM_NAME=Windows', "-DCMAKE_SYSTEM_PROCESSOR=$(if ($Arch -eq 'x64') { 'AMD64' } else { 'ARM64' })") }

# Runs a tool, what it says shown as it says it: PowerShell 5 would take what goes to stderr
# (CMake's warnings) for errors and stop.
function Run([string]$tool, [string[]]$arguments) {
    $ErrorActionPreference = 'Continue'
    & $tool @arguments 2>&1 | ForEach-Object { Write-Host "$_" }
    return $LASTEXITCODE
}

function Build([string]$name, [string]$source, [string[]]$options) {
    $dir = Join-Path $work $name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null
    if ((Run $cmake (@('-S', $source, '-B', $dir) + $common + $options)) -ne 0) { throw "cmake could not set up $name" }
    if ((Run $ninja @('-C', $dir, '-j', "$Jobs", 'install')) -ne 0) { throw "$name did not build" }
}

if (Test-Path $out) { Remove-Item $out -Recurse -Force }

# libaom: the AV1 encoder and decoder, nothing else (no tools, tests or examples).
$aom = Unpack 'libaom-3.15.3'
$aomOptions = @(
    "-DPERL_EXECUTABLE=$perl", '-DENABLE_DOCS=0', '-DENABLE_EXAMPLES=0', '-DENABLE_TESTDATA=0', '-DENABLE_TESTS=0',
    '-DENABLE_TOOLS=0', '-DENABLE_APPS=0', '-DCONFIG_AV1_ENCODER=1', '-DCONFIG_AV1_DECODER=1'
)
if ($Arch -eq 'x64') {
    $nasm = Unpack 'nasm-3.01'
    $aomOptions += @("-DCMAKE_ASM_NASM_COMPILER=$nasm\nasm.exe", '-DAOM_TARGET_CPU=x86_64')
} else {
    $aomOptions += '-DAOM_TARGET_CPU=arm64'
}
Build 'aom' $aom $aomOptions

# libavif, with libaom found in out\ and nothing else.
$avif = Unpack 'libavif-1.4.2'
$read = Join-Path $avif 'src\read.c'
$check = @'
        if (!avifAreGridDimensionsValid(tile->image->yuvFormat,
                                        grid->outputWidth,
                                        grid->outputHeight,
'@
$relaxed = @'
        if (!avifAreGridDimensionsValid(tile->image->yuvFormat,
                                        grid->outputWidth + (grid->outputWidth & 1),
                                        grid->outputHeight + (grid->outputHeight & 1),
'@
$text = [IO.File]::ReadAllText($read) -replace "`r`n", "`n"
$check = $check -replace "`r`n", "`n"
$relaxed = $relaxed -replace "`r`n", "`n"
$at = $text.IndexOf($check)
if ($at -lt 0 -or $text.IndexOf($check, $at + 1) -ge 0) { throw 'libavif read.c is not as expected: the grid check to relax is not there once' }
[IO.File]::WriteAllText($read, $text.Replace($check, $relaxed))
Build 'avif' $avif @(
    '-DAVIF_CODEC_AOM=SYSTEM', '-DAVIF_CODEC_AOM_DECODE=ON', '-DAVIF_CODEC_AOM_ENCODE=ON', "-DCMAKE_PREFIX_PATH=$out",
    '-DAVIF_LIBYUV=OFF', '-DAVIF_LIBSHARPYUV=OFF', '-DAVIF_LIBXML2=OFF', '-DAVIF_ZLIBPNG=OFF', '-DAVIF_JPEG=OFF',
    '-DAVIF_BUILD_APPS=OFF', '-DAVIF_BUILD_TESTS=OFF', '-DAVIF_BUILD_EXAMPLES=OFF'
)

foreach ($lib in 'aom.lib', 'avif.lib') {
    if (-not (Test-Path "$out\lib\$lib")) { throw "$lib is missing from $out\lib" }
}

# The licences, for whatever credits the libraries.
$licenses = Join-Path $root 'licenses'
New-Item -ItemType Directory -Force $licenses | Out-Null
Copy-Item "$aom\LICENSE" "$licenses\libaom-LICENSE.txt" -Force
Copy-Item "$aom\PATENTS" "$licenses\libaom-PATENTS.txt" -Force
Copy-Item "$avif\LICENSE" "$licenses\libavif-LICENSE.txt" -Force
$versions = ($downloads.Keys | Where-Object { $_ -ne 'nasm-3.01' -or $Arch -eq 'x64' } | ForEach-Object { "$_ $($downloads[$_].Sha256)" }) -join "`n"
Set-Content "$out\versions.txt" $versions -Encoding Ascii
Write-Host "libavif and libaom for $Arch in $out"
