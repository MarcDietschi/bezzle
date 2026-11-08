# Puts beside Bezzle.exe what it needs to run on a PC without Swift: the Swift runtime and the
# Visual C++ runtime, each DLL only when something laid out there asks for it (followed import by
# import). build.ps1 runs it for every x64 build (an Arm machine's Swift has only its own runtime
# on the path) and, with -Runtime, for Arm too. Run on Windows in Windows\:
#
#   .\runtime.ps1 -Arch arm64|x64 -App <folder with Bezzle.exe>
#
# The Swift runtime comes from the merge module Swift's installer leaves for apps to ship
# (Redistributables\<version>\rtl.shared.<arch>.msm, for every architecture it was installed
# with), unpacked once into Packages\swift-runtime\<version>\<arch>. The Visual C++ runtime comes
# from Visual Studio's redistributable files (VC\Redist\MSVC\<version>\<arch>\Microsoft.VC143.CRT),
# which Microsoft lets an app carry beside itself.
param(
    [Parameter(Mandatory)] [ValidateSet('arm64', 'x64')] [string]$Arch,
    [Parameter(Mandatory)] [string]$App
)

$ErrorActionPreference = 'Stop'
$sdk = $env:SDKROOT
if (-not $sdk -or $sdk -notmatch '\\Platforms\\([^\\]+)\\') { throw 'SDKROOT does not name a Swift platform (Swift is not installed)' }
$version = $Matches[1]
$swift = Join-Path $env:LOCALAPPDATA 'Programs\Swift'
$readobj = Join-Path $swift "Toolchains\$version+Asserts\usr\bin\llvm-readobj.exe"
if (-not (Test-Path $readobj)) { $readobj = (Get-Command llvm-readobj.exe).Source }

# What a merge module holds is a cabinet in one of its streams, its files named by the File
# table's keys: read both through Windows Installer's own msi.dll.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class BezzleMergeModule {
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiOpenDatabaseW(string path, IntPtr persist, out IntPtr db);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiDatabaseOpenViewW(IntPtr db, string query, out IntPtr view);
    [DllImport("msi.dll")] static extern uint MsiViewExecute(IntPtr view, IntPtr record);
    [DllImport("msi.dll")] static extern uint MsiViewFetch(IntPtr view, out IntPtr record);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiRecordGetStringW(IntPtr record, uint field, StringBuilder value, ref uint size);
    [DllImport("msi.dll")] static extern uint MsiRecordReadStream(IntPtr record, uint field, byte[] buffer, ref uint size);
    [DllImport("msi.dll")] static extern uint MsiCloseHandle(IntPtr handle);
    static IntPtr View(IntPtr db, string query) {
        IntPtr view;
        uint e = MsiDatabaseOpenViewW(db, query, out view);
        if (e != 0 || (e = MsiViewExecute(view, IntPtr.Zero)) != 0) throw new Exception("Windows Installer error " + e + " on " + query);
        return view;
    }
    static string Text(IntPtr record, uint field) {
        uint size = 0;
        var text = new StringBuilder(1);
        MsiRecordGetStringW(record, field, text, ref size);
        size++;
        text = new StringBuilder((int)size);
        MsiRecordGetStringW(record, field, text, ref size);
        return text.ToString();
    }
    // The file names by key, and the cabinet written to `cabinet`.
    public static Dictionary<string, string> Unpack(string module, string cabinet) {
        IntPtr db;
        uint e = MsiOpenDatabaseW(module, IntPtr.Zero, out db);
        if (e != 0) throw new Exception("Windows Installer cannot open " + module + " (" + e + ")");
        var names = new Dictionary<string, string>();
        IntPtr view = View(db, "SELECT `File`, `FileName` FROM `File`"), record;
        while (MsiViewFetch(view, out record) == 0) {
            string name = Text(record, 2);
            names[Text(record, 1)] = name.Substring(name.IndexOf('|') + 1);   // "short|long"
            MsiCloseHandle(record);
        }
        MsiCloseHandle(view);
        view = View(db, "SELECT `Data` FROM `_Streams` WHERE `Name` = 'MergeModule.CABinet'");
        if (MsiViewFetch(view, out record) != 0) throw new Exception(module + " holds no cabinet");
        using (var output = File.Create(cabinet)) {
            var buffer = new byte[1 << 20];
            while (true) {
                uint n = (uint)buffer.Length;
                if ((e = MsiRecordReadStream(record, 1, buffer, ref n)) != 0) throw new Exception("Windows Installer error " + e + " reading the cabinet");
                if (n == 0) break;
                output.Write(buffer, 0, (int)n);
            }
        }
        MsiCloseHandle(record);
        MsiCloseHandle(view);
        MsiCloseHandle(db);
        return names;
    }
}
'@

# Swift's runtime for the architecture, unpacked once.
$installerArch = if ($Arch -eq 'x64') { 'amd64' } else { 'arm64' }
$runtime = Join-Path $PSScriptRoot "Packages\swift-runtime\$version\$Arch"
if (-not (Test-Path "$runtime\swiftCore.dll")) {
    $module = Join-Path $swift "Redistributables\$version\rtl.shared.$installerArch.msm"
    if (-not (Test-Path $module)) { throw "$module is missing: install Swift $version with its $Arch SDK (VM/provision.ps1)" }
    $work = "$runtime.unpacking"
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Force "$work\cabinet" | Out-Null
    $names = [BezzleMergeModule]::Unpack($module, "$work\rtl.cab")
    expand.exe "$work\rtl.cab" -F:* "$work\cabinet" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "expand could not unpack $module" }
    New-Item -ItemType Directory -Force $runtime | Out-Null
    foreach ($key in $names.Keys) {
        Move-Item (Join-Path "$work\cabinet" $key) (Join-Path $runtime $names[$key]) -Force
    }
    Remove-Item $work -Recurse -Force
}

# Visual C++'s runtime for the architecture: the newest redistributable Visual Studio has.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -property installationPath
$crt = Get-ChildItem "$vs\VC\Redist\MSVC\*\$Arch\Microsoft.VC*.CRT" -Directory -ErrorAction SilentlyContinue |
    Sort-Object FullName | Select-Object -Last 1
if (-not $crt) { throw "Visual Studio has no $Arch C++ runtime to redistribute" }

# Every DLL that what is laid out imports (or loads late), found in either runtime, copied beside
# it; what Windows itself has (and the Windows App Runtime, a package of its own) is left out.
$from = @($runtime, $crt.FullName)
$queue = [Collections.Generic.Queue[string]]::new()
Get-ChildItem $App -File | Where-Object { $_.Extension -in '.exe', '.dll' } | ForEach-Object { $queue.Enqueue($_.FullName) }
$seen = @{}
$copied = @()
while ($queue.Count -gt 0) {
    $file = $queue.Dequeue()
    $imports = & $readobj --coff-imports $file | Select-String '^\s*Name: (.+\.dll)\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
    foreach ($name in $imports) {
        $key = $name.ToLowerInvariant()
        if ($seen[$key]) { continue }
        $seen[$key] = $true
        foreach ($dir in $from) {
            $candidate = Get-ChildItem $dir -File | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
            if ($candidate) {
                Copy-Item $candidate.FullName $App -Force
                $copied += $candidate.Name
                $queue.Enqueue((Join-Path $App $candidate.Name))
                break
            }
        }
    }
}
Write-Host "Swift $version and $($crt.Parent.Parent.Name) C++ runtimes ($Arch) beside it: $(($copied | Sort-Object) -join ', ')"
