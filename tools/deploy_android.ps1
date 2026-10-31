<#
.SYNOPSIS
  Build a debug APK, install it on the connected device, launch it, and stream logs.

.DESCRIPTION
  Replaces the manual "export in editor -> copy apk -> tap install -> watch logcat" loop.
  ASCII-only on purpose: Windows PowerShell 5.1 reads BOM-less scripts as ANSI and
  non-ASCII comments can break parsing.

  Prerequisites:
    * Godot export templates must be installed (Editor -> Editor -> Manage Export Templates).
      Without them the export step fails with "No export template found".
    * adb on PATH or at $env:ANDROID_HOME\platform-tools\adb.exe

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/deploy_android.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/deploy_android.ps1 -NoBuild -NoLog
#>
param(
	[switch]$NoBuild,
	[switch]$NoInstall,
	[switch]$NoLog
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$apk = Join-Path $root 'build\android\iso_rpg.apk'
$package = 'com.gbcmikeblue.isorpg'

function Resolve-Godot {
	if ($env:GODOT_BIN -and (Test-Path $env:GODOT_BIN)) { return $env:GODOT_BIN }
	$fallback = 'D:\godot_program\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe'
	if (Test-Path $fallback) { return $fallback }
	$cmd = Get-Command godotc -ErrorAction SilentlyContinue
	if ($cmd) { return $cmd.Source }
	throw 'Godot not found: set GODOT_BIN or put godotc on PATH'
}

function Resolve-Adb {
	$cmd = Get-Command adb -ErrorAction SilentlyContinue
	if ($cmd) { return $cmd.Source }
	if ($env:ANDROID_HOME) {
		$candidate = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
		if (Test-Path $candidate) { return $candidate }
	}
	throw 'adb not found: add platform-tools to PATH or set ANDROID_HOME'
}

if (-not $NoBuild) {
	$templates = Join-Path $env:APPDATA 'Godot\export_templates'
	$count = 0
	if (Test-Path $templates) {
		$count = (Get-ChildItem $templates -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
	}
	if ($count -eq 0) {
		throw "Export templates are missing ($templates is empty). Install them first: Editor -> Editor -> Manage Export Templates -> Download and Install."
	}

	New-Item -ItemType Directory -Force -Path (Split-Path -Parent $apk) | Out-Null
	$godot = Resolve-Godot
	Write-Host "[deploy] exporting debug APK -> $apk"
	& $godot --headless --path $root --export-debug 'Android' $apk
	if ($LASTEXITCODE -ne 0 -or -not (Test-Path $apk)) { throw 'Export failed (see log above)' }
	Write-Host ("[deploy] apk size = {0:N1} MB" -f ((Get-Item $apk).Length / 1MB))
}

if (-not $NoInstall) {
	$adb = Resolve-Adb
	$devices = & $adb devices | Select-String 'device$'
	if (-not $devices) { throw 'No device detected: check USB debugging and `adb devices`' }
	Write-Host '[deploy] installing'
	& $adb install -r $apk
	if ($LASTEXITCODE -ne 0) { throw 'adb install failed' }
	Write-Host "[deploy] launching $package"
	& $adb shell monkey -p $package -c android.intent.category.LAUNCHER 1 | Out-Null
}

if (-not $NoLog) {
	$adb = Resolve-Adb
	Write-Host '[deploy] streaming godot logs (Ctrl+C to stop)'
	& $adb logcat -s godot:V GodotEngine:V
}
