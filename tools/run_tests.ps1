<#
.SYNOPSIS
  阶段验收批量运行器：一次调用跑一组 suite，聚合耗时与失败摘要。

.DESCRIPTION
  解决三个问题：① 每次手敲完整的 godot 命令行；② 逐条命令往返、长命令被判定为「需要等待」；
  ③ 失败时只看到 FAIL 行、看不到上下文。

  fast 组 = 纯逻辑/布局断言（毫秒级），用于每次改动后的即时反馈；
  slow 组 = 依赖真实物理帧的 stage_a / stage_b（数十秒），提交前或 CI 跑。

.EXAMPLE
  .\tools\run_tests.ps1 -Group fast
  .\tools\run_tests.ps1 -Group all -Import
  .\tools\run_tests.ps1 -Suite stage_c_check,stage_b_check
#>
param(
	[ValidateSet('fast', 'slow', 'all')]
	[string]$Group = 'all',
	[string[]]$Suite = @(),
	[switch]$Import,
	[string]$Godot = '',
	[int]$TimeoutSec = 180,
	[switch]$Quiet
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root = Split-Path -Parent $PSScriptRoot
$project = $root

# ---------------- 引擎定位 ----------------
function Resolve-Godot {
	param([string]$Explicit)
	if ($Explicit -and (Test-Path $Explicit)) { return $Explicit }
	if ($env:GODOT_BIN -and (Test-Path $env:GODOT_BIN)) { return $env:GODOT_BIN }
	$cmd = Get-Command godotc -ErrorAction SilentlyContinue
	if ($cmd) { return $cmd.Source }
	$fallback = 'D:\godot_program\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe'
	if (Test-Path $fallback) { return $fallback }
	throw "找不到 Godot：请用 -Godot 指定，或设置环境变量 GODOT_BIN"
}

$godot = Resolve-Godot -Explicit $Godot

# ---------------- 分组表 ----------------
$suites = [ordered]@{
	'stage_c_check'            = 'fast'
	'mobile_layout_check'      = 'fast'
	'settings_readability_check' = 'fast'
	'i18n_settings_check'      = 'fast'
	'display_preset_check'     = 'fast'
	'touch_contract_check'     = 'fast'
	'stage_a_check'            = 'slow'
	'stage_b_check'            = 'slow'
}

if ($Suite.Count -gt 0) {
	$selected = @()
	foreach ($name in $Suite) {
		if (-not $suites.Contains($name)) { throw "未知 suite：$name" }
		$selected += $name
	}
} elseif ($Group -eq 'all') {
	$selected = @($suites.Keys)
} else {
	$selected = @($suites.Keys | Where-Object { $suites[$_] -eq $Group })
}

# ---------------- 可选：先导入资源 ----------------
if ($Import) {
	$sw = [System.Diagnostics.Stopwatch]::StartNew()
	& $godot --headless --path $project --import *> $null
	$sw.Stop()
	Write-Host ("[import] {0:N1}s exit={1}" -f $sw.Elapsed.TotalSeconds, $LASTEXITCODE)
	if ($LASTEXITCODE -ne 0) { throw "资源导入失败" }
}

# ---------------- 逐个运行 ----------------
$rows = @()
$totalFail = 0
$totalSeconds = 0.0

foreach ($name in $selected) {
	$outFile = Join-Path ([System.IO.Path]::GetTempPath()) "godot_$name.log"
	$errFile = "$outFile.err"
	$scene = "res://tests/$name.tscn"

	$sw = [System.Diagnostics.Stopwatch]::StartNew()
	$proc = Start-Process -FilePath $godot `
		-ArgumentList @('--headless', '--path', $project, $scene) `
		-NoNewWindow -PassThru `
		-RedirectStandardOutput $outFile -RedirectStandardError $errFile
	# fast 组都是毫秒级用例：20s 还没退出必然是脚本解析失败或死循环，别等 3 分钟。
	$limit = if ($suites[$name] -eq 'fast') { 20 } else { $TimeoutSec }
	$exited = $proc.WaitForExit($limit * 1000)
	if (-not $exited) {
		try { $proc.Kill() } catch {}
	}
	$sw.Stop()

	$text = ''
	if (Test-Path $outFile) { $text += (Get-Content $outFile -Raw -ErrorAction SilentlyContinue) }
	if (Test-Path $errFile) { $text += (Get-Content $errFile -Raw -ErrorAction SilentlyContinue) }

	$pass = ([regex]::Matches($text, '\[PASS\]')).Count
	$fails = [regex]::Matches($text, '\[FAIL\][^\r\n]*') | ForEach-Object { $_.Value }
	$failCount = @($fails).Count
	$seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
	$totalSeconds += $seconds

	# 退出码偶发为空（Start-Process 的对象缓存），统一以「结果行 + FAIL 计数」判定，
	# 解析失败（脚本没加载起来）单独标出来，否则只会看到一个沉默的 TIMEOUT。
	$code = -1
	if ($exited) { $proc.Refresh(); $code = $proc.ExitCode }
	$allPass = $text -match '结果：全部通过'
	# 硬编译失败一律红灯：依赖链编译不通过时，上层脚本会继续用旧字节码，
	# 断言可能「通过」但跑的是上一版逻辑（本轮就踩过：三元 Variant 推断报错 → 面板用了旧 ItemData）。
	$compileError = $text -match 'Compile Error|Failed to load script'
	# 单点 Parse Error 只在一条断言都没跑时才算失败（主场景里个别历史 BOM 是无害的）。
	$parseError = ($pass -eq 0) -and ($text -match 'Parse Error')

	$status = if (-not $exited) { 'TIMEOUT' }
		elseif ($compileError -or $parseError) { 'COMPILE' }
		elseif ($failCount -gt 0 -or -not $allPass) { 'FAIL' }
		else { 'PASS' }
	if ($status -ne 'PASS') { $totalFail++ }

	$rows += [pscustomobject]@{
		Suite   = $name
		Group   = $suites[$name]
		Status  = $status
		Seconds = $seconds
		Pass    = $pass
		Fail    = $failCount
		Exit    = $code
	}

	if (-not $Quiet -and $failCount -gt 0) {
		foreach ($line in ($fails | Select-Object -First 3)) { Write-Host "    $line" -ForegroundColor Red }
	}
	Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
}

# ---------------- 汇总 ----------------
$rows | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("total: {0} suites, {1:N1}s, pass={2}, fail={3}" -f `
		$rows.Count, $totalSeconds, ($rows | Measure-Object -Property Pass -Sum).Sum, $totalFail)

if ($totalFail -gt 0) { exit 1 }
exit 0
