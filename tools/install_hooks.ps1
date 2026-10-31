<#
.SYNOPSIS
  Install repository git hooks (currently only pre-commit: run fast test group).

.DESCRIPTION
  .git/hooks is not version controlled, so hook sources live in tools/hooks/ and
  are installed by this script. Run once after clone / on a new machine.

  NOTE: this file is kept ASCII-only on purpose. Windows PowerShell 5.1 reads
  BOM-less scripts as ANSI, and non-ASCII comments can break parsing.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/install_hooks.ps1
#>
param(
	[switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'tools\hooks\pre-commit'
$target = Join-Path $root '.git\hooks\pre-commit'

if (-not (Test-Path $source)) { throw "Hook source not found: $source" }
if (-not (Test-Path (Join-Path $root '.git'))) { throw "Not a git repo (no .git): $root" }

if ((Test-Path $target) -and (-not $Force)) {
	$existing = Get-Content $target -Raw
	$incoming = Get-Content $source -Raw
	if ($existing -eq $incoming) {
		Write-Host "[hooks] pre-commit is up to date"
		exit 0
	}
	throw "A different pre-commit hook already exists. Re-run with -Force to overwrite: $target"
}

Copy-Item $source $target -Force

# Git for Windows runs hooks with its own sh; CRLF would break the shebang line.
$bytes = [IO.File]::ReadAllBytes($target)
$text = [Text.Encoding]::UTF8.GetString($bytes) -replace "`r`n", "`n"
[IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "[hooks] installed pre-commit -> $target"
Write-Host "[hooks] every commit will run tools/run_tests.ps1 -Group fast (~5s)"
Write-Host "[hooks] to skip once: git commit --no-verify"
