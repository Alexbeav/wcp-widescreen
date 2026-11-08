[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio Installer and the C++ x86 build tools are required.' }
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vs) { throw 'No installed Visual Studio C++ x86 toolchain was found.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars32.bat'
$out = Join-Path $PSScriptRoot 'out'
$package = Join-Path $out 'package'
$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $out,$package,$dist,(Join-Path $package 'docs') -Force | Out-Null
$source = Join-Path $PSScriptRoot 'src\wcpwide.cpp'
Push-Location -LiteralPath $out
try {
    $compile = 'call "{0}" >nul && cl /nologo /O2 /MT /EHsc /W4 /WX /LD "{1}" /Fe:gl_00007.dll && cl /nologo /O2 /MT /EHsc /W4 /WX /DWCPWIDE_SELFTEST "{1}" /Fe:selftest.exe' -f $vcvars,$source
    & $env:ComSpec /d /c $compile
    if ($LASTEXITCODE -ne 0) { throw 'The x86 build failed.' }
    & '.\selftest.exe'
    if ($LASTEXITCODE -ne 0) { throw 'The camera self-test failed.' }
} finally { Pop-Location }
Copy-Item -LiteralPath (Join-Path $out 'gl_00007.dll') -Destination (Join-Path $package 'gl_00007.dll') -Force
foreach ($file in @('Install.ps1','README.md','LICENSE')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $package -Force }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs\REPORT.md') -Destination (Join-Path $package 'docs\REPORT.md') -Force
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
$manifest.proxy_sha256 = (Get-FileHash -LiteralPath (Join-Path $package 'gl_00007.dll') -Algorithm SHA256).Hash
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $package 'manifest.json') -Encoding utf8
$zip = Join-Path $dist ("wcp-widescreen-v{0}-win32.zip" -f $manifest.version)
$files = @('gl_00007.dll','Install.ps1','manifest.json','README.md','LICENSE','docs') | ForEach-Object { Join-Path $package $_ }
Compress-Archive -LiteralPath $files -DestinationPath $zip -Force
('{0}  {1}' -f (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash,(Split-Path -Leaf $zip)) | Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Encoding ascii
Write-Output $zip
