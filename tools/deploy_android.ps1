<#
.SYNOPSIS
  Debug APK workflow: inspect / backup / build / install / launch / logs.

.DESCRIPTION
  Replaces the manual "export in editor -> copy apk -> tap install -> watch logcat" loop.

  ASCII-only on purpose: Windows PowerShell 5.1 reads BOM-less scripts as ANSI and
  non-ASCII comments can break parsing.

  Signature note (important when the app was installed from another machine):
  debug APKs are signed with %USERPROFILE%\.android\debug.keystore, which differs per
  machine. Installing over an app signed elsewhere fails with
  INSTALL_FAILED_UPDATE_INCOMPATIBLE. In that case either
    * reuse the other machine's debug.keystore, or
    * -BackupSaves, uninstall, install, -RestoreSaves (see below).

.EXAMPLE
  # what is currently installed (version + install time)
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/deploy_android.ps1 -CheckInstalled

.EXAMPLE
  # build + install + launch, no log streaming
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/deploy_android.ps1 -NoLog

.EXAMPLE
  # keep saves across a required uninstall
  .\tools\deploy_android.ps1 -BackupSaves
  .\tools\deploy_android.ps1 -ForceUninstall -NoLog
  .\tools\deploy_android.ps1 -RestoreSaves
#>
param(
	[switch]$NoBuild,
	[switch]$NoInstall,
	[switch]$NoLog,
	[switch]$CheckInstalled,
	[switch]$BackupSaves,
	[switch]$RestoreSaves,
	[switch]$ForceUninstall
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$apk = Join-Path $root 'build\android\iso_rpg.apk'
$package = 'com.gbcmikeblue.isorpg'
$savesDir = Join-Path $root 'build\saves'

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

function Get-Device([string]$adb) {
	$lines = & $adb devices | Select-String 'device$'
	if (-not $lines) { throw 'No device detected: check USB debugging and `adb devices`' }
	return $lines
}

$adb = $null
if ($CheckInstalled -or $BackupSaves -or $RestoreSaves -or $ForceUninstall -or -not $NoInstall) {
	$adb = Resolve-Adb
	Get-Device $adb | Out-Null
}

# ---------------- 1. 已安装版本 ----------------
if ($CheckInstalled) {
	Write-Host "[deploy] installed package info: $package"
	$dump = & $adb shell dumpsys package $package
	if (-not $dump) {
		Write-Host '[deploy] not installed on this device'
	} else {
		$dump | Select-String 'versionName|versionCode|firstInstallTime|lastUpdateTime' | ForEach-Object {
			Write-Host ('  ' + $_.Line.Trim())
		}
		$path = & $adb shell pm path $package
		Write-Host ('  apk: ' + ($path -join ', '))
	}
	if ($BackupSaves -or $RestoreSaves -or $ForceUninstall -or -not $NoInstall) { } else { exit 0 }
}

# ---------------- 2. 备份存档 ----------------
if ($BackupSaves) {
	New-Item -ItemType Directory -Force -Path $savesDir | Out-Null
	$tar = Join-Path $savesDir 'files.tar'
	Write-Host "[deploy] backing up app files -> $tar"
	# run-as 只对 debuggable 包有效；debug 导出即为 debuggable。
	& $adb exec-out run-as $package tar cf - files | Set-Content -Path $tar -Encoding Byte
	if (-not (Test-Path $tar) -or (Get-Item $tar).Length -eq 0) {
		throw 'Backup produced an empty file: run-as may be disabled by the vendor ROM'
	}
	Write-Host ("[deploy] saved {0:N1} KB" -f ((Get-Item $tar).Length / 1KB))
}

# ---------------- 3. 卸载（签名冲突时） ----------------
if ($ForceUninstall) {
	Write-Host "[deploy] uninstalling $package"
	& $adb uninstall $package | Out-Null
}

# ---------------- 4. 构建 ----------------
if (-not $NoBuild) {
	$templates = Join-Path $env:APPDATA 'Godot\export_templates'
	$count = 0
	if (Test-Path $templates) {
		$count = (Get-ChildItem $templates -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
	}
	if ($count -eq 0) {
		throw 'Export templates missing. Run tools/install_export_templates.ps1 first (or install them from the editor).'
	}

	New-Item -ItemType Directory -Force -Path (Split-Path -Parent $apk) | Out-Null
	$godot = Resolve-Godot
	Write-Host "[deploy] exporting debug APK -> $apk"
	& $godot --headless --path $root --export-debug 'Android' $apk
	if ($LASTEXITCODE -ne 0 -or -not (Test-Path $apk)) { throw 'Export failed (see log above)' }
	Write-Host ("[deploy] apk size = {0:N1} MB" -f ((Get-Item $apk).Length / 1MB))
}

# ---------------- 5. 安装 + 启动 ----------------
if (-not $NoInstall) {
	Write-Host '[deploy] installing'
	$output = & $adb install -r $apk 2>&1
	$output | ForEach-Object { Write-Host ('  ' + $_) }
	if ($LASTEXITCODE -ne 0) {
		if (($output -join ' ') -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
			throw @'
Signature mismatch: the installed app was built on another machine.
Choose one:
  a) copy that machine's %USERPROFILE%\.android\debug.keystore here (keeps saves), or
  b) -BackupSaves, then -ForceUninstall -NoBuild -NoLog, install again, then -RestoreSaves
'@
		}
		throw 'adb install failed'
	}
	Write-Host "[deploy] launching $package"
	& $adb shell monkey -p $package -c android.intent.category.LAUNCHER 1 | Out-Null
}

# ---------------- 6. 恢复存档 ----------------
if ($RestoreSaves) {
	$tar = Join-Path $savesDir 'files.tar'
	if (-not (Test-Path $tar)) { throw "No backup found: $tar" }
	$remote = '/data/local/tmp/iso_saves.tar'
	Write-Host '[deploy] restoring app files'
	& $adb push $tar $remote | Out-Null
	& $adb shell run-as $package tar xf $remote
	& $adb shell rm -f $remote
	Write-Host '[deploy] saves restored; restart the app to reload them'
}

# ---------------- 7. 日志 ----------------
if (-not $NoLog) {
	Write-Host '[deploy] streaming godot logs (Ctrl+C to stop)'
	& $adb logcat -s godot:V GodotEngine:V
}
