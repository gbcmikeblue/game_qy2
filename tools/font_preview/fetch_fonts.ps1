#Requires -Version 5.1
<#
.SYNOPSIS
    Download the candidate fonts used by tools/font_preview/font_specimen.tscn.

.DESCRIPTION
    Fonts are cached in the Godot user directory (NOT in the repo), so the
    preview works without polluting git:
        %APPDATA%\Godot\app_userdata\Iso RPG Stage A\fonts

    All candidates are SIL Open Font License 1.1 (commercial use allowed,
    redistribution allowed, must keep the license text when shipping).

    Run:
        powershell -ExecutionPolicy Bypass -File tools\font_preview\fetch_fonts.ps1
        powershell -ExecutionPolicy Bypass -File tools\font_preview\fetch_fonts.ps1 -Force

.PARAMETER OutDir
    Override the target directory.

.PARAMETER Force
    Re-download files that already exist.
#>
param(
    [string]$OutDir = (Join-Path $env:APPDATA "Godot\app_userdata\Iso RPG Stage A\fonts"),
    [switch]$Force
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Stem of the saved file is what font_specimen.gd matches for license/role.
$targets = @(
    @{
        File = "SmileySans-Oblique.ttf"
        Url  = "https://github.com/atelier-anchor/smiley-sans/releases/download/v2.0.1/smiley-sans-v2.0.1.zip"
        Zip  = $true
        Note = "Smiley Sans / display: titles, buttons"
    },
    @{
        File = "NotoSansSC-Regular.otf"
        Url  = "https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf"
        Zip  = $false
        Note = "Noto Sans SC / UI body, settings panel"
    },
    @{
        File = "LXGWWenKaiLite-Regular.ttf"
        Url  = "https://github.com/lxgw/LxgwWenKai-Lite/releases/download/v1.520/LXGWWenKaiLite-Regular.ttf"
        Zip  = $false
        Note = "LXGW WenKai / narrative, hints"
    },
    @{
        File = "NotoSerifSC-SemiBold.otf"
        Url  = "https://raw.githubusercontent.com/notofonts/noto-cjk/main/Serif/SubsetOTF/SC/NotoSerifSC-SemiBold.otf"
        Zip  = $false
        Note = "Noto Serif SC / display serif, atmosphere"
    },
    @{
        File = "NotoSansMonoCJKsc-Regular.otf"
        Url  = "https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/Mono/NotoSansMonoCJKsc-Regular.otf"
        Zip  = $false
        Note = "Noto Sans Mono CJK SC / debug info, digits"
    }
)

Write-Host "Target directory: $OutDir"
$failed = @()

foreach ($target in $targets) {
    $dest = Join-Path $OutDir $target.File
    if ((Test-Path $dest) -and -not $Force) {
        $size = [math]::Round((Get-Item $dest).Length / 1MB, 1)
        Write-Host ("[skip] {0,-28} {1,6} MB  ({2})" -f $target.File, $size, $target.Note)
        continue
    }

    $started = Get-Date
    try {
        if ($target.Zip) {
            $tmpZip = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName() + ".zip")
            Invoke-WebRequest -Uri $target.Url -OutFile $tmpZip -UseBasicParsing
            $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
            Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
            $ttf = Get-ChildItem -Path $tmpDir -Recurse -Filter "*.ttf" |
                Where-Object { $_.Name -eq $target.File } | Select-Object -First 1
            if ($null -eq $ttf) {
                $ttf = Get-ChildItem -Path $tmpDir -Recurse -Filter "*.ttf" | Select-Object -First 1
            }
            if ($null -eq $ttf) { throw "no ttf inside $($target.Url)" }
            Copy-Item $ttf.FullName $dest -Force
            Remove-Item $tmpZip, $tmpDir -Recurse -Force
        }
        else {
            Invoke-WebRequest -Uri $target.Url -OutFile $dest -UseBasicParsing
        }
        $size = [math]::Round((Get-Item $dest).Length / 1MB, 1)
        $seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        Write-Host ("[ok]   {0,-28} {1,6} MB  {2}s  ({3})" -f $target.File, $size, $seconds, $target.Note)
    }
    catch {
        $failed += $target.File
        Write-Host ("[fail] {0,-28} {1}" -f $target.File, $_.Exception.Message)
    }
}

Write-Host ""
Write-Host "License: all candidates are SIL OFL 1.1 - commercial use OK."
Write-Host "Shipping them requires bundling the OFL text (see fonts/OFL.txt as the template)."
if ($failed.Count -gt 0) {
    Write-Host ("Missing: " + ($failed -join ", "))
    exit 1
}
exit 0
