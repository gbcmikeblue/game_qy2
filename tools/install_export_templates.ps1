<#
.SYNOPSIS
  Install Godot export templates from a .tpz file (offline) into the editor's template dir.

.DESCRIPTION
  The Godot editor expects templates at:
      %APPDATA%\Godot\export_templates\<version>\

  A .tpz is just a zip with a top-level "templates" folder. This script unpacks it,
  copies the contents to the right place, and verifies the files Android/Windows
  export actually needs.

  ASCII-only on purpose (PowerShell 5.1 reads BOM-less scripts as ANSI).

.EXAMPLE
  # after downloading Godot_v4.7.2-stable_export_templates.tpz by hand
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/install_export_templates.ps1 -Tpz D:\godot_program\Godot_v4.7.2-stable_export_templates.tpz

.EXAMPLE
  # let the script download it (slower networks: pass -Proxy http://127.0.0.1:7890)
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/install_export_templates.ps1 -Download -Proxy http://127.0.0.1:7890
#>
param(
	[string]$Tpz = '',
	[string]$Version = '4.7.2',
	[switch]$Download,
	[string]$Proxy = '',
	[string]$Keep = 'D:\godot_program'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$templateRoot = Join-Path $env:APPDATA "Godot\export_templates"
$target = Join-Path $templateRoot "$Version.stable"
$url = "https://github.com/godotengine/godot/releases/download/$Version-stable/Godot_v$Version-stable_export_templates.tpz"

function Test-Templates([string]$dir) {
	if (-not (Test-Path $dir)) { return @() }
	return @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
}

# ---------------- 1. 取得 tpz ----------------
if ($Download -or $Tpz -eq '') {
	if (-not (Test-Path $Keep)) { New-Item -ItemType Directory -Force -Path $Keep | Out-Null }
	$Tpz = Join-Path $Keep "Godot_v$Version-stable_export_templates.tpz"
	if (-not (Test-Path $Tpz)) {
		Write-Host "[templates] downloading $url"
		Write-Host "[templates] size is about 1.2 GB; if this is slow, cancel and download by hand, then rerun with -Tpz <file>"
		$curlArgs = @('-L', '--fail', '--retry', '3', '--ssl-no-revoke', '-o', $Tpz, $url)
		if ($Proxy -ne '') { $curlArgs = @('-x', $Proxy) + $curlArgs }
		& curl.exe @curlArgs
		if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Tpz)) { throw 'Download failed. Download the .tpz by hand and rerun with -Tpz <file>.' }
	}
}

if (-not (Test-Path $Tpz)) { throw "tpz not found: $Tpz" }
$sizeMb = [math]::Round((Get-Item $Tpz).Length / 1MB, 1)
Write-Host "[templates] source = $Tpz ($sizeMb MB)"

# ---------------- 2. 解压 ----------------
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("godot_tpl_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $staging | Out-Null
$zipCopy = Join-Path $staging 'templates.zip'
Copy-Item $Tpz $zipCopy -Force

Write-Host '[templates] extracting'
Expand-Archive -Path $zipCopy -DestinationPath $staging -Force

# tpz 里通常是 templates/ 一层；兼容直接平铺的情况。
$inner = Join-Path $staging 'templates'
if (-not (Test-Path $inner)) { $inner = $staging }

$files = @(Get-ChildItem $inner -File -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) { throw "No files found inside the tpz (looked in $inner)" }

# ---------------- 3. 安装 ----------------
New-Item -ItemType Directory -Force -Path $target | Out-Null
foreach ($file in $files) {
	Copy-Item $file.FullName (Join-Path $target $file.Name) -Force
}

$installed = Test-Templates $target
Write-Host "[templates] installed $($installed.Count) files -> $target"

# ---------------- 4. 校验 ----------------
$need = @('android_debug.apk', 'android_release.apk')
$missing = @()
foreach ($name in $need) {
	if ($installed -notcontains $name) { $missing += $name }
}
if ($missing.Count -gt 0) {
	Write-Warning ("Android export still missing: " + ($missing -join ', '))
} else {
	Write-Host '[templates] Android debug/release templates OK'
}

$hasWindows = @($installed | Where-Object { $_ -like 'windows_*' })
if ($hasWindows.Count -gt 0) {
	Write-Host ("[templates] Windows templates: " + ($hasWindows -join ', '))
} else {
	Write-Warning 'No windows_* template found; PC export will not work'
}

Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'Next: powershell -NoProfile -ExecutionPolicy Bypass -File tools/deploy_android.ps1'
