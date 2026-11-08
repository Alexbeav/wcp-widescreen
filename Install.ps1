[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GameDirectory,
    [switch]$Uninstall
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
$game = (Resolve-Path -LiteralPath $GameDirectory -ErrorAction Stop).Path
$exe = Join-Path $game 'prophecy.exe'
$renderer = Join-Path $game 'gl_00007.dll'
$originalRenderer = Join-Path $game 'gl_00007_original.dll'
$backup = Join-Path $game 'wcpwide-backup'
$recordPath = Join-Path $backup 'install.json'

function Get-Hash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing file: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Assert-Hash([string]$Path, [string]$Expected) {
    if ((Get-Hash $Path) -ne $Expected) { throw "Unsupported or changed file: $Path" }
}
function Replace-Bytes([string]$Path, [byte[]]$Bytes) {
    $temporary = Join-Path $game ('wcpwide-' + [guid]::NewGuid().ToString('N') + '.new')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        [IO.File]::Replace($temporary, $Path, [NullString]::Value)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

# The process check covers both the selected installation and other running Prophecy copies.
if (Get-Process -Name prophecy -ErrorAction SilentlyContinue) { throw 'Close Prophecy before changing its files.' }

if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { throw 'No installation record exists for this folder.' }
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    Assert-Hash (Join-Path $backup 'prophecy.exe') $record.exe_before_sha256
    Assert-Hash (Join-Path $backup 'gl_00007.dll') $manifest.renderer_original_sha256
    # Accept either end of a partly completed restore, but preserve unrelated modifications.
    $exeHash = Get-Hash $exe
    $rendererHash = Get-Hash $renderer
    if ($exeHash -notin @($manifest.exe_60fps_sha256, $record.exe_before_sha256)) { throw 'The executable changed after installation.' }
    if ($rendererHash -notin @($record.proxy_sha256, $manifest.renderer_original_sha256)) { throw 'The renderer changed after installation.' }
    Replace-Bytes $renderer ([IO.File]::ReadAllBytes((Join-Path $backup 'gl_00007.dll')))
    Replace-Bytes $exe ([IO.File]::ReadAllBytes((Join-Path $backup 'prophecy.exe')))
    Assert-Hash $renderer $manifest.renderer_original_sha256
    Assert-Hash $exe $record.exe_before_sha256
    $record.status = 'removed'
    $record | ConvertTo-Json | Set-Content -LiteralPath $recordPath -Encoding utf8
    Write-Output 'Widescreen removed. The executable returned to its state before installation. Backups remain in wcpwide-backup.'
    return
}

$candidate = Join-Path $PSScriptRoot 'gl_00007.dll'
Assert-Hash $candidate $manifest.proxy_sha256
$exeHash = Get-Hash $exe
$rendererHash = Get-Hash $renderer
if ($exeHash -notin @($manifest.exe_original_sha256, $manifest.exe_60fps_sha256)) { throw 'This executable is not supported by release 0.1.' }
if ($rendererHash -eq $manifest.proxy_sha256) {
    Assert-Hash $originalRenderer $manifest.renderer_original_sha256
    if ($exeHash -ne $manifest.exe_60fps_sha256) { throw 'The existing proxy requires the supported 60 FPS executable.' }
    if (-not (Test-Path -LiteralPath $recordPath)) {
        if (Test-Path -LiteralPath $backup) { throw 'The backup folder exists without an installation record.' }
        New-Item -ItemType Directory -Path $backup | Out-Null
        Copy-Item -LiteralPath $exe -Destination (Join-Path $backup 'prophecy.exe')
        Copy-Item -LiteralPath $originalRenderer -Destination (Join-Path $backup 'gl_00007.dll')
        Assert-Hash (Join-Path $backup 'prophecy.exe') $exeHash
        Assert-Hash (Join-Path $backup 'gl_00007.dll') $manifest.renderer_original_sha256
        [pscustomobject]@{version=$manifest.version;status='installed';exe_before_sha256=$exeHash;proxy_sha256=$manifest.proxy_sha256} |
            ConvertTo-Json | Set-Content -LiteralPath $recordPath -Encoding utf8
    }
    Write-Output 'Release 0.1 is already installed.'
    return
}
Assert-Hash $renderer $manifest.renderer_original_sha256
if (Test-Path -LiteralPath $originalRenderer) { Assert-Hash $originalRenderer $manifest.renderer_original_sha256 }
if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $recordPath)) { throw 'The backup folder exists without an installation record.' }
$bytes = [IO.File]::ReadAllBytes($exe)
$signature = ($bytes[$manifest.recognition_offset..($manifest.recognition_offset + 6)] | ForEach-Object { $_.ToString('X2') }) -join ''
if ($signature -ne $manifest.recognition_hex) { throw 'The frame-rate patch signature does not match.' }
[Array]::Copy([BitConverter]::GetBytes([single]60), 0, $bytes, [int]$manifest.fps_offset, 4)
$patchedHash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')
if ($patchedHash -ne $manifest.exe_60fps_sha256) { throw 'The proposed 60 FPS executable does not match the supported build.' }

if (Test-Path -LiteralPath $recordPath) {
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    Assert-Hash (Join-Path $backup 'prophecy.exe') $record.exe_before_sha256
    Assert-Hash (Join-Path $backup 'gl_00007.dll') $manifest.renderer_original_sha256
    if ($record.status -eq 'removed' -and $exeHash -ne $record.exe_before_sha256) { throw 'The executable differs from the saved state before installation.' }
} else {
    New-Item -ItemType Directory -Path $backup | Out-Null
    Copy-Item -LiteralPath $exe -Destination (Join-Path $backup 'prophecy.exe')
    Copy-Item -LiteralPath $renderer -Destination (Join-Path $backup 'gl_00007.dll')
    Assert-Hash (Join-Path $backup 'prophecy.exe') $exeHash
    Assert-Hash (Join-Path $backup 'gl_00007.dll') $manifest.renderer_original_sha256
    $record = [pscustomobject]@{version=$manifest.version;status='prepared';exe_before_sha256=$exeHash;proxy_sha256=$manifest.proxy_sha256}
}
$record.status = 'prepared'
$record.proxy_sha256 = $manifest.proxy_sha256
$record | ConvertTo-Json | Set-Content -LiteralPath $recordPath -Encoding utf8
if (-not (Test-Path -LiteralPath $originalRenderer)) { Copy-Item -LiteralPath $renderer -Destination $originalRenderer }
Assert-Hash $originalRenderer $manifest.renderer_original_sha256
try {
    Replace-Bytes $exe $bytes
    Assert-Hash $exe $manifest.exe_60fps_sha256
    Replace-Bytes $renderer ([IO.File]::ReadAllBytes($candidate))
    Assert-Hash $renderer $manifest.proxy_sha256
    $record.status = 'installed'
    $record | ConvertTo-Json | Set-Content -LiteralPath $recordPath -Encoding utf8
} catch {
    Replace-Bytes $renderer ([IO.File]::ReadAllBytes((Join-Path $backup 'gl_00007.dll')))
    Replace-Bytes $exe ([IO.File]::ReadAllBytes((Join-Path $backup 'prophecy.exe')))
    throw
}
Write-Output 'Widescreen and 60 FPS installed. Launch Enhanced Prophecy as usual.'
