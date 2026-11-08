param(
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [Parameter(Mandatory=$true)][string]$FixtureDirectory,
    [Parameter(Mandatory=$true)][string]$PristineExe,
    [Parameter(Mandatory=$true)][string]$OriginalRenderer
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$package = (Resolve-Path -LiteralPath $PackageDirectory).Path
$manifest = Get-Content -LiteralPath (Join-Path $package 'manifest.json') -Raw | ConvertFrom-Json
if (Test-Path -LiteralPath $FixtureDirectory) { throw 'Choose a new, empty fixture directory outside the source checkout.' }
$checkout = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\') + '\'
$fixtures = [IO.Path]::GetFullPath($FixtureDirectory)
if ($fixtures.StartsWith($checkout, [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep private test inputs outside the source checkout.' }
New-Item -ItemType Directory -Path $fixtures | Out-Null
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function New-Fixture([string]$Name, [bool]$Fps60=$false) {
    $dir = Join-Path $fixtures $Name
    New-Item -ItemType Directory -Path $dir | Out-Null
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $PristineExe).Path)
    if ($Fps60) { [Array]::Copy([BitConverter]::GetBytes([single]60),0,$bytes,[int]$manifest.fps_offset,4) }
    [IO.File]::WriteAllBytes((Join-Path $dir 'prophecy.exe'),$bytes)
    Copy-Item -LiteralPath $OriginalRenderer -Destination (Join-Path $dir 'gl_00007.dll')
    return $dir
}
function Install([string]$Directory) { & (Join-Path $package 'Install.ps1') -GameDirectory $Directory }
function Uninstall([string]$Directory) { & (Join-Path $package 'Install.ps1') -GameDirectory $Directory -Uninstall }
Assert ((Hash $PristineExe) -eq $manifest.exe_original_sha256) 'The pristine executable differs.'
Assert ((Hash $OriginalRenderer) -eq $manifest.renderer_original_sha256) 'The original renderer differs.'
$stock = New-Fixture 'stock'
Install $stock
Assert ((Hash (Join-Path $stock 'prophecy.exe')) -eq $manifest.exe_60fps_sha256) 'The 60 FPS patch differs.'
Assert ((Hash (Join-Path $stock 'gl_00007.dll')) -eq $manifest.proxy_sha256) 'The proxy differs.'
Assert ((Hash (Join-Path $stock 'gl_00007_original.dll')) -eq $manifest.renderer_original_sha256) 'The original renderer was not preserved.'
$backupHash = Hash (Join-Path $stock 'wcpwide-backup\prophecy.exe')
Install $stock
Assert ((Hash (Join-Path $stock 'wcpwide-backup\prophecy.exe')) -eq $backupHash) 'A repeat install changed the backup.'
Uninstall $stock
Assert ((Hash (Join-Path $stock 'prophecy.exe')) -eq $manifest.exe_original_sha256) 'Uninstall did not restore the stock executable.'
Assert ((Hash (Join-Path $stock 'gl_00007.dll')) -eq $manifest.renderer_original_sha256) 'Uninstall did not restore the renderer.'
Install $stock
Uninstall $stock
Write-Output 'PASS: stock install, preserved original, repeat install, exact restore and reinstall.'

$fps60 = New-Fixture 'existing-60fps' $true
Install $fps60
Uninstall $fps60
Assert ((Hash (Join-Path $fps60 'prophecy.exe')) -eq $manifest.exe_60fps_sha256) 'Uninstall removed an existing 60 FPS patch.'
Write-Output 'PASS: an existing 60 FPS patch survives uninstall.'

$adopt = New-Fixture 'existing-proxy' $true
Copy-Item -LiteralPath (Join-Path $adopt 'gl_00007.dll') -Destination (Join-Path $adopt 'gl_00007_original.dll')
Copy-Item -LiteralPath (Join-Path $package 'gl_00007.dll') -Destination (Join-Path $adopt 'gl_00007.dll') -Force
Install $adopt
Uninstall $adopt
Assert ((Hash (Join-Path $adopt 'gl_00007.dll')) -eq $manifest.renderer_original_sha256) 'Existing-proxy adoption did not support removal.'
Write-Output 'PASS: an existing matching proxy receives working removal metadata.'

$unsupported = New-Fixture 'unsupported'
$badExe = Join-Path $unsupported 'prophecy.exe'
$bytes = [IO.File]::ReadAllBytes($badExe)
$bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 1
[IO.File]::WriteAllBytes($badExe,$bytes)
$beforeHash = Hash $badExe
$refused = $false
try { Install $unsupported } catch { $refused = $true }
Assert $refused 'An unsupported executable was accepted.'
Assert ((Hash $badExe) -eq $beforeHash) 'A refused install changed the executable.'
Assert ((Hash (Join-Path $unsupported 'gl_00007.dll')) -eq $manifest.renderer_original_sha256) 'A refused install changed the renderer.'
Assert (-not (Test-Path -LiteralPath (Join-Path $unsupported 'wcpwide-backup'))) 'A refused install wrote backups.'
Write-Output 'PASS: unsupported input is refused before any game file changes.'

$changed = New-Fixture 'changed-after-install'
Install $changed
$changedExe = Join-Path $changed 'prophecy.exe'
$bytes = [IO.File]::ReadAllBytes($changedExe)
$bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 1
[IO.File]::WriteAllBytes($changedExe,$bytes)
$changedHash = Hash $changedExe
$refused = $false
try { Uninstall $changed } catch { $refused = $true }
Assert $refused 'Removal overwrote a later modification.'
Assert ((Hash $changedExe) -eq $changedHash) 'A refused removal changed the executable.'
Assert ((Hash (Join-Path $changed 'gl_00007.dll')) -eq $manifest.proxy_sha256) 'A refused removal changed the renderer.'
Write-Output 'PASS: removal preserves later, unrecognized modifications.'
