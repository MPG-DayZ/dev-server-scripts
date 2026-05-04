param (
    [Parameter(Mandatory = $false)]
    [ValidateSet("server", "client", "all")]
    [string]$mode = "all",

    [string]$serverPreset = "",

    [string]$modPreset = "",

    [int]$autoCloseTime = -1,

    [string]$lang = "",

    [string]$configPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$silent = $false
)

$cmdServerPreset = $serverPreset
$cmdAutoCloseTime = $autoCloseTime
$cmdLang = $lang

$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir = Split-Path -Parent $scriptPath

$customConfigPath = ""
if ($configPath -ne "") {
    if (-not [System.IO.Path]::IsPathRooted($configPath)) {
        $configPath = Join-Path $scriptDir $configPath
    }
    $customConfigPath = $configPath
}

. (Join-Path $scriptDir "config.ps1")

if ($cmdServerPreset -ne "") {
    if (-not $config.serverPresets.$cmdServerPreset) {
        Write-ColorOutput "errors.preset_not_found" -ForegroundColor "Red" -Prefix "prefixes.error" -FormatArgs @("server", $cmdServerPreset)
        Pause
        exit 1
    }
    $selectedServerPreset = $cmdServerPreset
}

$serverPresetObj = $config.serverPresets.$selectedServerPreset
$isDiagMode = $serverPresetObj.isDiagMode
$isDisableBE = $serverPresetObj.isDisableBE

if ($cmdAutoCloseTime -ge 0) {
    $autoCloseTime = $cmdAutoCloseTime
}

if ($cmdLang -ne "") {
    Set-CurrentLanguage $cmdLang
}

$host.UI.RawUI.WindowTitle = "$(Get-LocalizedString "window_title") v$ScriptVersion"

function Stop-DayZServer {
    Write-ColorOutput "info.stopping_server" -ForegroundColor "Yellow" -Prefix "prefixes.server"
    if ($isDiagMode) {
        # В diag-режиме сервер и клиент используют один exe (DayZDiag_x64)
        # Убиваем все экземпляры — клиента тоже, т.к. различить по имени нельзя
        Stop-Process -Name "DayZDiag_x64" -Force -ErrorAction SilentlyContinue
    }
    elseif ($isDisableBE) {
        Stop-Process -Name "DayZServer_x64_NoBe" -Force -ErrorAction SilentlyContinue
    }
    else {
        Stop-Process -Name "DayZServer_x64" -Force -ErrorAction SilentlyContinue
    }
}

function Stop-DayZClient {
    Write-ColorOutput "info.stopping_client" -ForegroundColor "Yellow" -Prefix "prefixes.client"
    if ($isDiagMode) {
        # В diag-режиме клиент уже убит вместе с сервером в Stop-DayZServer
        return
    }
    else {
        Stop-Process -Name "DayZ_x64" -Force -ErrorAction SilentlyContinue
    }
}

switch ($mode) {
    "server" {
        Stop-DayZServer
    }
    "client" {
        Stop-DayZClient
    }
    "all" {
        Stop-DayZServer
        Stop-DayZClient
    }
}

taskkill /F /FI "WINDOWTITLE eq MPG Log Viewer v$ScriptVersion" 2>$null | Out-Null

if (!$silent) {
    Write-ColorOutput "info.launch_complete" -ForegroundColor "Green" -Prefix "prefixes.system"

    if ($autoCloseTime -gt 0) {
        1..$autoCloseTime | ForEach-Object {
            $timeLeft = $autoCloseTime - $_ + 1
            $host.UI.RawUI.WindowTitle = "$(Get-LocalizedString "window_title_closing" -FormatArgs @($timeLeft)) v$ScriptVersion"
            Start-Sleep -Seconds 1
        }
    }
}
