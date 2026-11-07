# What the Bezzle test VM needs to build Bezzle for Windows. Safe to run again: each step is
# skipped when it is done. From the Mac:
#
#   Windows/VM/win 'powershell -ExecutionPolicy Bypass -File C:\bezzle\provision.ps1'
#
# after copying this file to C:\bezzle (scp, see win). Everything comes from its own project's
# downloads; the VM is Windows on Arm, so the tools are their arm64 builds. Visual Studio's build
# tools are installed under their license, as Swift on Windows requires.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$swift = '6.4.2'
$dl = 'C:\bezzle\downloads'
$tools = 'C:\Tools'
New-Item -ItemType Directory -Force $dl, "$tools\bin" | Out-Null

function Fetch($url, $name) {
    $file = Join-Path $dl $name
    if (-not (Test-Path $file)) { Write-Host "  $url"; Invoke-WebRequest $url -OutFile "$file.part" -UseBasicParsing; Move-Item "$file.part" $file }
    $file
}
function Latest($repo, $pattern) {
    $asset = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").assets | Where-Object name -match $pattern | Select-Object -First 1
    if (-not $asset) { throw "No release of $repo matches $pattern" }
    $asset
}
function Run($file, $arguments) {
    $p = Start-Process $file -ArgumentList $arguments -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { throw "$file exited with $($p.ExitCode)" }
}
function AddToPath($dir) {
    $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($path -split ';') -notcontains $dir) { [Environment]::SetEnvironmentVariable('Path', "$path;$dir", 'Machine') }
}

# Visual Studio Build Tools 2022: MSVC for arm64 and x64, ATL, and the Windows 11 SDK.
$vs = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
if (-not (Test-Path "$vs\VC\Tools\MSVC")) {
    Write-Host 'Visual Studio Build Tools…'
    Run (Fetch 'https://aka.ms/vs/17/release/vs_BuildTools.exe' 'vs_BuildTools.exe') (@(
        '--quiet', '--wait', '--norestart', '--nocache',
        '--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
        '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '--add', 'Microsoft.VisualStudio.Component.VC.ATL.ARM64',
        '--add', 'Microsoft.VisualStudio.Component.VC.ATL',
        '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100'
    ) -join ' ')
}

# Swift, with the arm64 and x64 SDKs (the x64 build is made here too). It installs for the user
# whatever InstallPerMachine says: in %LOCALAPPDATA%\Programs\Swift.
if (-not (Test-Path "$env:LOCALAPPDATA\Programs\Swift\Toolchains\$swift+Asserts")) {
    Write-Host "Swift $swift…"
    $exe = Fetch "https://download.swift.org/swift-$swift-release/windows10-arm64/swift-$swift-RELEASE/swift-$swift-RELEASE-windows10-arm64.exe" "swift-$swift-arm64.exe"
    Run $exe '/quiet /norestart OptionsInstallIDE=0 OptionsInstallWindowsSDKAMD64=1 OptionsInstallWindowsSDKARM64=1'
}

# Swift 6.4.2's arm64 installer leaves out some of the runtime assemblies its own tools list in
# their manifests (FoundationXML, swiftRegexBuilder…): each lives as <name>\<name>.dll beside the
# tools, and swift-build fails to start ("side-by-side configuration is incorrect") without them.
# The same DLLs are in the runtime's folder.
$toolchain = "$env:LOCALAPPDATA\Programs\Swift\Toolchains\$swift+Asserts\usr\bin"
$runtime = "$env:LOCALAPPDATA\Programs\Swift\Runtimes\$swift\usr\bin"
$mt = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter mt.exe | Where-Object FullName -match '\\arm64\\' | Select-Object -First 1 -ExpandProperty FullName
$wanted = @{}
foreach ($exe in Get-ChildItem $toolchain -Filter *.exe) {
    $manifest = Join-Path $env:TEMP "$($exe.BaseName).manifest"
    & $mt -nologo "-inputresource:$($exe.FullName);#1" "-out:$manifest" 2>$null | Out-Null
    if (Test-Path $manifest) {
        foreach ($m in [regex]::Matches((Get-Content $manifest -Raw), 'dependentAssembly>\s*<assemblyIdentity type="win32" name="([^"]+)"')) { $wanted[$m.Groups[1].Value] = $true }
        Remove-Item $manifest
    }
}
foreach ($name in $wanted.Keys) {
    if (-not (Test-Path "$toolchain\$name\$name.dll") -and (Test-Path "$runtime\$name.dll")) {
        Write-Host "  adding the $name assembly to the toolchain"
        New-Item -ItemType Directory -Force "$toolchain\$name" | Out-Null
        Copy-Item "$runtime\$name.dll" "$toolchain\$name\"
    }
    # Some of its DLLs also lack the embedded manifest that names them (swiftRegexBuilder): then
    # the assembly is described by a manifest file beside the DLL, as Windows also accepts.
    $probe = Join-Path $env:TEMP "$name.dll.manifest"
    Remove-Item $probe -ErrorAction SilentlyContinue
    & $mt -nologo "-inputresource:$toolchain\$name\$name.dll;#1" "-out:$probe" 2>$null | Out-Null
    if (Test-Path $probe) { Remove-Item $probe } elseif (-not (Test-Path "$toolchain\$name\$name.manifest")) {
        Write-Host "  describing the $name assembly"
        Set-Content "$toolchain\$name\$name.manifest" -Encoding UTF8 @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity type="win32" name="$name" version="$swift.0" processorArchitecture="arm64"></assemblyIdentity>
  <file name="$name.dll"></file>
</assembly>
"@
    }
}

# Git.
if (-not (Test-Path 'C:\Program Files\Git\cmd\git.exe')) {
    Write-Host 'Git…'
    $a = Latest 'git-for-windows/git' '^Git-[0-9.]+-arm64\.exe$'
    Run (Fetch $a.browser_download_url $a.name) '/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES'
}

# CMake and Ninja (swift-winrt and Skia build with them).
if (-not (Test-Path 'C:\Program Files\CMake\bin\cmake.exe')) {
    Write-Host 'CMake…'
    $a = Latest 'Kitware/CMake' 'windows-arm64\.msi$'
    Run msiexec.exe "/i `"$(Fetch $a.browser_download_url $a.name)`" /quiet /norestart ADD_CMAKE_TO_PATH=System"
}
if (-not (Test-Path "$tools\bin\ninja.exe")) {
    Write-Host 'Ninja…'
    $a = Latest 'ninja-build/ninja' '^ninja-winarm64\.zip$'
    Expand-Archive (Fetch $a.browser_download_url $a.name) "$tools\bin" -Force
}

# NuGet (the Windows App SDK and swift-winrt come as NuGet packages), and Python from python.org's
# own NuGet package (Skia's build scripts need it).
if (-not (Test-Path "$tools\bin\nuget.exe")) {
    Write-Host 'NuGet…'
    Copy-Item (Fetch 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' 'nuget.exe') "$tools\bin\nuget.exe"
}
if (-not (Test-Path "$tools\python\tools\python.exe")) {
    Write-Host 'Python…'
    & "$tools\bin\nuget.exe" install pythonarm64 -OutputDirectory "$dl\python" -ExcludeVersion -NonInteractive | Out-Null
    Copy-Item "$dl\python\pythonarm64" "$tools\python" -Recurse
    Copy-Item "$tools\python\tools\python.exe" "$tools\python\tools\python3.exe"
}

# LLVM, whose clang-cl builds Skia (Skia's own advice on Windows).
if (-not (Test-Path 'C:\Program Files\LLVM\bin\clang-cl.exe')) {
    Write-Host 'LLVM…'
    $a = Latest 'llvm/llvm-project' '^LLVM-[0-9.]+-woa64\.msi$'
    Run msiexec.exe "/i `"$(Fetch $a.browser_download_url $a.name)`" /quiet /norestart"
}

# Scripts written here (winrt.ps1, build.ps1…) may run; downloaded ones still need a signature.
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

foreach ($dir in "$tools\bin", "$tools\python\tools", 'C:\Program Files\Git\cmd') { AddToPath $dir }
& 'C:\Program Files\Git\cmd\git.exe' config --system core.autocrlf false
Write-Host 'Done.'
