# Makes Bezzle's installer for one architecture from the app that build.ps1 laid out:
#
#   .\make-installer.ps1 -Version 1.4.2 -Build 20261108.1200 [-Arch arm64|x64] [-App <laid out app>]
#       [-Feed <appcast url> -PublicKey <EdDSA public key>] [-Name 'Bezzle Test'] [-Out <folder>]
#       [-Cache <fetch.ps1's folder>] [-RuntimeDirs <folders>]
#
# It copies the app into a folder of its own and makes it whole there:
# - the Swift runtime and Foundation, and the C++ runtime they are built against, beside Bezzle.exe
#   (whatever Bezzle.exe and those need that Windows itself does not have), as an app installed per
#   person cannot put them into Windows;
# - Bezzle.exe without its debugging information (kept beside the installer as Bezzle-<v>-<arch>.pdb.exe,
#   which llvm-symbolizer reads a crash's place from), its icon, and its version where Windows
#   shows it (the file's Details) and where Bezzle reads it (About Bezzle);
# - with -Feed and -PublicKey, the updater: WinSparkle.dll beside it, and the feed and the key it
#   must find updates signed with in Bezzle.exe's resources, where WinSparkle reads them. A copy
#   without them never looks for updates (as the Mac's builds from Xcode never do);
# - the licences of what Bezzle is made with (Windows/Credits), which About Bezzle shows.
# Then Inno Setup makes the installer of it (Bezzle.iss), with the Windows App Runtime's installer.
# Prints the installer's path, size and SHA-256.

param(
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [string]$Build,
    [ValidateSet('arm64', 'x64')] [string]$Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),
    [string]$App,
    [string]$Feed,
    [string]$PublicKey,
    [string]$Name = 'Bezzle',
    [string]$Out = (Join-Path $PSScriptRoot '..\.build\installer'),
    [string]$Cache = (Join-Path $PSScriptRoot '..\Packages\installer'),
    [string[]]$RuntimeDirs
)

$ErrorActionPreference = 'Stop'
$windows = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $App) {
    $native = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    # build.ps1 lays the machine's own architecture out in .build\Bezzle, another in .build\<arch>\Bezzle.
    $App = if ($Arch -eq $native) { "$windows\.build\Bezzle" } else { "$windows\.build\$Arch\Bezzle" }
}
if (-not (Test-Path "$App\Bezzle.exe")) { throw "No Bezzle.exe in ${App}: lay the app out with build.ps1 first" }
if ($Version -notmatch '^\d+(\.\d+){0,2}$') { throw "A version reads like 1.4.2, not $Version" }
if ($Build -notmatch '^\d+(\.\d+)*$') { throw "A build reads like 20261108.1200, not $Build" }
if ([bool]$Feed -ne [bool]$PublicKey) { throw 'The updater needs both -Feed and -PublicKey' }
$tools = & "$PSScriptRoot\fetch.ps1" -Cache $Cache
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$stage = Join-Path $Out "$Arch\app"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null

# The app as build.ps1 laid it out, without the tools that come with a build.
Copy-Item "$App\*" $stage -Recurse -Exclude 'bezzle-render.exe', 'bezzle-share.exe', '*.pdb', '*.ilk', '*.exp', '*.lib'
# The licences as this commit has them (About Bezzle shows them); the fonts' own beside them too,
# in place of what the font folder was made with.
if (Test-Path "$stage\licenses") { Remove-Item -Recurse -Force "$stage\licenses" }
Copy-Item "$windows\Credits\licenses" "$stage\licenses" -Recurse
Get-ChildItem "$stage\fonts" -Filter '*-OFL.txt' | Remove-Item
Copy-Item "$windows\Credits\licenses\fonts\*-OFL.txt" "$stage\fonts"

# What Bezzle.exe needs beyond Windows, found the way Windows will look for it: beside it first.
$toolchain = Split-Path (Get-Command swiftc.exe).Source
$readobj = Join-Path $toolchain 'llvm-readobj.exe'
if (-not $RuntimeDirs) {
    # The Swift runtime of the toolchain in use, which carries the C++ runtime it is built against.
    # Another architecture's layout carries its runtimes itself (build.ps1 -Arch puts them there).
    $own = $Arch -eq $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' })
    $RuntimeDirs = if ($own) { @($env:PATH -split ';' | Where-Object { $_ -match '\\Swift\\Runtimes\\[^\\]+\\usr\\bin\\?$' } | Select-Object -First 1) } else { @() }
}
$system = "$env:SystemRoot\System32"
$cppRuntime = '^(vcruntime|msvcp|concrt|vccorlib|vcomp)\d'
$seen = @{}
$queue = [System.Collections.Generic.Queue[string]]::new()
Get-ChildItem $stage -Filter *.exe | ForEach-Object { $queue.Enqueue($_.FullName) }
Get-ChildItem $stage -Filter *.dll | ForEach-Object { $queue.Enqueue($_.FullName) }
while ($queue.Count -gt 0) {
    $file = $queue.Dequeue()
    foreach ($line in (& $readobj --coff-imports $file | Select-String '^\s*Name: (.+\.dll)$')) {
        $dll = $line.Matches[0].Groups[1].Value
        $key = $dll.ToLower()
        if ($seen[$key]) { continue }
        $seen[$key] = $true
        if (Test-Path (Join-Path $stage $dll)) { continue }
        # Windows' own: the API sets, and what System32 has that is not the C++ runtime (which a
        # fresh Windows may lack: it comes app-local from the Swift runtime).
        if ($key.StartsWith('api-ms-win-') -or $key.StartsWith('ext-ms-')) { continue }
        if ((Test-Path (Join-Path $system $dll)) -and $key -notmatch $cppRuntime) { continue }
        # The Windows App Runtime's, which its package brings (the bootstrapper finds it).
        if ($key -match '^microsoft\.(windowsappruntime|ui|windows)\.') { continue }
        $found = $RuntimeDirs | ForEach-Object { Join-Path $_ $dll } | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $found) { throw "$dll, which $(Split-Path -Leaf $file) needs, is in none of $($RuntimeDirs -join ', ')" }
        Copy-Item $found $stage
        $queue.Enqueue((Join-Path $stage $dll))
    }
}
# The Mac's pointers must be in it (build.ps1 compiles them before Swift links them in; a manifest
# SwiftPM read before Resources\Generated\Bezzle.res was there leaves them out).
if (-not (& $readobj --coff-resources "$stage\Bezzle.exe" | Select-String 'GROUP_CURSOR')) {
    throw 'Bezzle.exe has no pointers: run build.ps1 (it compiles Bezzle.rc) after touching Package.swift'
}

# Bezzle.exe without its debugging information, which takes most of its size; the whole one is
# kept beside the installer for reading crashes.
$symbols = Join-Path $Out "Bezzle-$Version-$Arch.pdb.exe"
Copy-Item "$stage\Bezzle.exe" $symbols -Force
& (Join-Path $toolchain 'llvm-strip.exe') --strip-debug "$stage\Bezzle.exe"
if ($LASTEXITCODE -ne 0) { throw 'llvm-strip failed' }

# Its icon, its version, and (for a copy that updates itself) the feed and the key, as resources.
$parts = ($Version.Split('.') + @('0', '0', '0'))[0..2] | ForEach-Object { [int]$_ }
$numeric = "$($parts[0]),$($parts[1]),$($parts[2]),0"
$icon = "$windows\Resources\Generated\Bezzle.ico"
if (-not (Test-Path $icon)) { throw "No $icon`: run Resources/make-icons.sh on the Mac (VM/sync.sh does)" }
$rcText = @"
#pragma code_page(65001)
1 ICON "$($icon -replace '\\', '\\')"
1 VERSIONINFO
FILEVERSION $numeric
PRODUCTVERSION $numeric
FILEFLAGSMASK 0x3F
FILEFLAGS 0x0
FILEOS 0x40004
FILETYPE 0x1
FILESUBTYPE 0x0
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904B0"
        BEGIN
            VALUE "CompanyName", "Erik Muffler"
            VALUE "FileDescription", "$Name"
            VALUE "FileVersion", "$Version"
            VALUE "InternalName", "Bezzle"
            VALUE "LegalCopyright", "$([char]0xA9) 2026 Erik Muffler"
            VALUE "OriginalFilename", "Bezzle.exe"
            VALUE "ProductName", "$Name"
            VALUE "ProductVersion", "$Version"
            VALUE "Build", "$Build"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
"@
if ($Feed) {
    if ($PublicKey -notmatch '^[A-Za-z0-9+/]{43}=$') { throw 'The public key is the 32 bytes of an Ed25519 key in Base64' }
    $rcText += "`nFeedURL APPCAST {`"$Feed`"}`nEdDSAPub EDDSA {`"$PublicKey`"}`n"
    $sparkleArch = if ($Arch -eq 'arm64') { 'ARM64' } else { 'x64' }
    Copy-Item "$($tools.WinSparkle)\$sparkleArch\Release\WinSparkle.dll" $stage
}
$work = Join-Path $Out "$Arch\work"
New-Item -ItemType Directory -Force $work | Out-Null
[IO.File]::WriteAllText("$work\stamp.rc", $rcText, [Text.UTF8Encoding]::new($false))
$rc = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter rc.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq ($(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' })) } |
    Sort-Object FullName | Select-Object -Last 1
if (-not $rc) { throw 'rc.exe not found (the Windows SDK)' }
& $rc.FullName /nologo /fo "$work\stamp.res" "$work\stamp.rc"
if ($LASTEXITCODE -ne 0) { throw 'rc failed' }

# Each resource of the compiled script written into Bezzle.exe (UpdateResource), as a resource
# editor would: no relinking, so the same build serves every version stamped onto it.
if (-not ('BezzleResources' -as [type])) { Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class BezzleResources {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool UpdateResource(IntPtr update, IntPtr type, IntPtr name, ushort language, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool EndUpdateResource(IntPtr update, bool discard);

    // A type or name in a .res file: 0xFFFF and a number, or a string ended by a 0.
    static IntPtr ReadId(BinaryReader r, System.Collections.Generic.List<IntPtr> strings) {
        ushort first = r.ReadUInt16();
        if (first == 0xFFFF) return (IntPtr)r.ReadUInt16();
        var text = new System.Text.StringBuilder();
        for (ushort c = first; c != 0; c = r.ReadUInt16()) text.Append((char)c);
        IntPtr p = Marshal.StringToHGlobalUni(text.ToString());
        strings.Add(p);
        return p;
    }

    public static int Apply(string exe, string res) {
        byte[] bytes = File.ReadAllBytes(res);
        var strings = new System.Collections.Generic.List<IntPtr>();
        IntPtr update = BeginUpdateResource(exe, false);
        if (update == IntPtr.Zero) throw new Exception("BeginUpdateResource " + Marshal.GetLastWin32Error());
        int count = 0;
        using (var r = new BinaryReader(new MemoryStream(bytes))) {
            while (r.BaseStream.Position + 32 <= bytes.Length) {
                long start = r.BaseStream.Position;
                uint dataSize = r.ReadUInt32(), headerSize = r.ReadUInt32();
                IntPtr type = ReadId(r, strings), name = ReadId(r, strings);
                // The header ends with DataVersion, MemoryFlags, LanguageId, Version, Characteristics.
                r.BaseStream.Position = start + headerSize - 10;
                ushort language = r.ReadUInt16();
                r.BaseStream.Position = start + headerSize;
                byte[] data = r.ReadBytes((int)dataSize);
                r.BaseStream.Position = (r.BaseStream.Position + 3) & ~3L;
                if (dataSize == 0) continue;
                if (!UpdateResource(update, type, name, language, data, dataSize)) throw new Exception("UpdateResource " + Marshal.GetLastWin32Error());
                count++;
            }
        }
        if (!EndUpdateResource(update, false)) throw new Exception("EndUpdateResource " + Marshal.GetLastWin32Error());
        foreach (IntPtr p in strings) Marshal.FreeHGlobal(p);
        return count;
    }
}
'@ }
$written = [BezzleResources]::Apply("$stage\Bezzle.exe", "$work\stamp.res")
Write-Host "Bezzle.exe: $written resources (icon, version $Version ($Build)$(if ($Feed) { ', feed and key' }))"

# The installer.
$output = Join-Path $Out 'setup'
New-Item -ItemType Directory -Force $output | Out-Null
$iscc = @(
    "/DName=$Name", "/DArch=$Arch", "/DVersion=$Version", "/DBuild=$Build", "/DSource=$stage",
    "/DRuntime=$($tools.Runtime[$Arch])", "/DIcon=$icon", "/DPictures=$(Split-Path $icon)", "/DOutput=$output", '/Q', "$PSScriptRoot\Bezzle.iss"
)
& $tools.ISCC @iscc
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup could not make the installer' }
$installer = Get-ChildItem $output -Filter "*-$Version-Setup-$Arch.exe" | Sort-Object LastWriteTime | Select-Object -Last 1
[pscustomobject]@{
    Installer = $installer.FullName
    Length    = $installer.Length
    SHA256    = (Get-FileHash $installer.FullName -Algorithm SHA256).Hash.ToLower()
    Symbols   = $symbols
}
