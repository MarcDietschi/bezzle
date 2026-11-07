# Fetches the Swift bindings for WinUI 3 and the Windows App SDK into Windows\Packages (git-ignored),
# and the Windows App Runtime they need. Run on Windows, in Windows\, before `swift build`.
#
# The bindings are The Browser Company's, generated with swift-winrt for Windows App SDK
# 1.7.250909003 and archived as they were on 2025-10-16; pinned to those last commits here, and
# made static libraries. They carry the runtime's bootstrapper for one architecture only, so it is
# replaced with the one of the machine's own, from the same Windows App SDK release.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$sdk = '1.7.250909003'
$packages = Join-Path $PSScriptRoot 'Packages'
$pins = [ordered]@{
    'swift-cwinrt'            = 'eb46cdb66f770a1e006f9fcfebbf9e99a0fba811'
    'swift-windowsfoundation' = '1efad430c4920d80d063bfaa526dd011d8ee8379'
    'swift-uwp'               = 'd1a96986570189f8aa9ed089e9c4dab3c96e688c'
    'swift-windowsappsdk'     = '317527def617c5b7b3153380a85390bf7d3ec5b2'
    'swift-winui'             = '17c77ebaf8585039ab2f25d8aaf19f6e0aead93b'
}
New-Item -ItemType Directory -Force $packages | Out-Null

foreach ($name in $pins.Keys) {
    $dir = Join-Path $packages $name
    if (-not (Test-Path "$dir\.git")) { git clone --quiet "https://github.com/thebrowsercompany/$name.git" $dir }
    git -C $dir fetch --quiet origin $pins[$name]
    git -C $dir checkout --quiet --force $pins[$name]
    # As static libraries, linked into Bezzle.exe: as DLLs, the Swift runtime of 6.4 cannot resolve
    # their generic wrappers' superclasses across the DLLs ("failed to demangle superclass of
    # UnsealedWinRTClassWrapper … does not conform to protocol AbiBridge").
    $manifest = Join-Path $dir 'Package.swift'
    (Get-Content $manifest -Raw) -replace 'type: \.dynamic', 'type: .static' | Set-Content $manifest -NoNewline
}

# The Windows App SDK release the bindings were made for: its bootstrapper for this machine.
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$nupkg = Join-Path $packages "microsoft.windowsappsdk.$sdk.nupkg"
if (-not (Test-Path $nupkg)) {
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/microsoft.windowsappsdk/$sdk/microsoft.windowsappsdk.$sdk.nupkg" -OutFile $nupkg -UseBasicParsing
}
$sdkDir = Join-Path $packages "windowsappsdk-$sdk"
if (-not (Test-Path $sdkDir)) {
    Copy-Item $nupkg "$nupkg.zip"
    Expand-Archive "$nupkg.zip" $sdkDir
    Remove-Item "$nupkg.zip"
}
Copy-Item "$sdkDir\runtimes\win-$arch\native\Microsoft.WindowsAppRuntime.Bootstrap.dll" `
    "$packages\swift-windowsappsdk\Sources\CWinAppSDK\nuget\bin\Microsoft.WindowsAppRuntime.Bootstrap.dll" -Force

# The Windows App Runtime itself, which an unpackaged app finds through the bootstrapper.
$installed = Get-AppxPackage -Name "Microsoft.WindowsAppRuntime.1.7" -ErrorAction SilentlyContinue | Where-Object Architecture -eq $arch
if (-not $installed) {
    $installer = Join-Path $packages "windowsappruntimeinstall-$arch.exe"
    $major = ($sdk -split '\.')[0..1] -join '.'
    Invoke-WebRequest "https://aka.ms/windowsappsdk/$major/$sdk/windowsappruntimeinstall-$arch.exe" -OutFile $installer -UseBasicParsing
    $p = Start-Process $installer -ArgumentList '--quiet' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "The Windows App Runtime installer exited with $($p.ExitCode)" }
}
Write-Host "WinUI bindings ready in $packages"
