# Fetches what Remove Background runs Bezzle's subject matte with (Host/SubjectMatte.swift,
# CBezzleHost/matte.cpp) into Windows\Packages\onnxruntime (git-ignored), for both architectures:
#
#   ONNX Runtime 1.24.4 with DirectML   Microsoft.ML.OnnxRuntime.DirectML, MIT licence
#   DirectML 1.15.4                     Microsoft.AI.DirectML, Microsoft's DirectML license terms
#                                       (the DLL may be brought along in apps; its headers are MIT)
#
# Each is pinned to its version and its SHA-256 (nuget.org's own SHA-512 of the same files was
# checked when they were pinned) and taken from nuget.org, where Microsoft publishes them; their
# DLLs carry Microsoft's signature, which is checked too. Run on Windows, in Windows\, before
# `swift build`: Package.swift builds Remove Background in when the headers are here, build.ps1
# puts the DLLs beside Bezzle.exe, and the installer takes them along.
#
#   .\onnx.ps1
#
# The subject matte itself, the model ONNX Runtime runs, is made on a Mac (Scripts/subject-matte/
# make-onnx.sh) and sent here by Windows/VM/send-matte.sh, to Packages\subject-matte\BiRefNet.onnx;
# this says whether it is there and the one measured (`$matte` below).

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$packages = Join-Path $PSScriptRoot 'Packages'
$out = Join-Path $packages 'onnxruntime'
New-Item -ItemType Directory -Force $out | Out-Null

$runtime = '1.24.4'
$directML = '1.15.4'
$downloads = @(
    @{ Id = 'microsoft.ml.onnxruntime.directml'; Version = $runtime
       Sha = '57e9f11b73437bef7a309496135d4c1f96b1a8e9ddba60013fa27bfc1d788681' },
    @{ Id = 'microsoft.ai.directml'; Version = $directML
       Sha = '4e7cb7ddce8cf837a7a75dc029209b520ca0101470fcdf275c1f49736a3615b9' }
)
# The subject matte measured on Windows (Scripts/subject-matte/README.md): BiRefNet_HR at 2,048
# pixels, its weights kept to 8 bits and its layers in full precision, as make-onnx.sh makes it
# (quantize_onnx.py on the full-precision export of 2026-11-08). Half precision lost whole regions
# on Arm processors; this keeps every photo measured and halves the download.
$matte = '98b3c58e3338454f07e01081fcbacc13c221b1c7d0e45976c6f407dadf0b89ac'

$unpacked = @{}
foreach ($d in $downloads) {
    $file = Join-Path $out "$($d.Id).$($d.Version).nupkg"
    if (-not (Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash -ne $d.Sha.ToUpper()) {
        Write-Host "Fetching $($d.Id) $($d.Version)"
        Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/$($d.Id)/$($d.Version)/$($d.Id).$($d.Version).nupkg" -OutFile "$file.part" -UseBasicParsing
        $hash = (Get-FileHash "$file.part" -Algorithm SHA256).Hash
        if ($hash -ne $d.Sha.ToUpper()) {
            Remove-Item "$file.part"
            throw "$($d.Id) $($d.Version) is not the package pinned here ($hash)"
        }
        Move-Item -Force "$file.part" $file
    }
    $folder = Join-Path $out "$($d.Id).$($d.Version)"
    if (-not (Test-Path "$folder\.unpacked")) {
        if (Test-Path $folder) { Remove-Item -Recurse -Force $folder }
        Copy-Item $file "$file.zip"
        Expand-Archive "$file.zip" $folder
        Remove-Item "$file.zip"
        Set-Content "$folder\.unpacked" $d.Sha
    }
    $unpacked[$d.Id] = $folder
}
$ort = $unpacked['microsoft.ml.onnxruntime.directml']
$dml = $unpacked['microsoft.ai.directml']

# What the host is compiled against: ONNX Runtime's C API and DirectML's header, which its
# DirectML provider's header includes.
New-Item -ItemType Directory -Force "$out\include" | Out-Null
Copy-Item "$ort\build\native\include\*.h" "$out\include" -Force
Copy-Item "$dml\include\DirectML.h", "$dml\include\DirectMLConfig.h" "$out\include" -Force

# What goes beside Bezzle.exe, per architecture: ONNX Runtime, the helper it loads, and DirectML.
foreach ($arch in @('arm64', 'x64')) {
    $to = Join-Path $out $arch
    New-Item -ItemType Directory -Force $to | Out-Null
    Copy-Item "$ort\runtimes\win-$arch\native\onnxruntime.dll", "$ort\runtimes\win-$arch\native\onnxruntime_providers_shared.dll" $to -Force
    Copy-Item "$dml\bin\$arch-win\DirectML.dll" $to -Force
    foreach ($dll in Get-ChildItem $to -Filter *.dll) {
        $signature = Get-AuthenticodeSignature $dll.FullName
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            throw "$arch\$($dll.Name) is not validly signed by Microsoft ($($signature.Status))"
        }
    }
}

# Their licences, which About Bezzle shows (Windows/Credits keeps the same files).
New-Item -ItemType Directory -Force "$out\licenses" | Out-Null
Copy-Item "$ort\LICENSE" "$out\licenses\onnxruntime.txt" -Force
Copy-Item "$ort\ThirdPartyNotices.txt" "$out\licenses\onnxruntime-notices.txt" -Force
Copy-Item "$dml\LICENSE.txt" "$out\licenses\directml.txt" -Force
Copy-Item "$dml\ThirdPartyNotices.txt" "$out\licenses\directml-notices.txt" -Force
Set-Content "$out\version.txt" "onnxruntime $runtime, directml $directML"

$model = Join-Path $packages 'subject-matte\BiRefNet.onnx'
if (-not (Test-Path $model)) {
    Write-Host "No subject matte at ${model}: make it on a Mac (Scripts/subject-matte/make-onnx.sh) and send it (Windows/VM/send-matte.sh)."
} elseif ((Get-FileHash $model -Algorithm SHA256).Hash -ne $matte.ToUpper()) {
    Write-Host "The subject matte at $model is not the one measured ($matte): measure it before shipping it."
} else {
    Write-Host "Subject matte ready at $model"
}
Write-Host "ONNX Runtime $runtime and DirectML $directML ready in $out"
