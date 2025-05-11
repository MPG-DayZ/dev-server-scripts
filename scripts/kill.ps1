param ([Parameter(Mandatory = $false)]
    [ValidateSet("server", "client", "all")]
    [string]$mode = "all",

    [Parameter(Mandatory = $false)]
    [switch]$silent = $false)

$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir = Split-Path -Parent $scriptPath
. (Join-Path $scriptDir "config.ps1")

$host.UI.RawUI.WindowTitle = Get-LocalizedString "window_title"

# Функция для остановки сервера
function Stop-DayZServer {
    Write-ColorOutput "info.stopping_server" -ForegroundColor "Yellow" -Prefix "prefixes.server"
    if ($isDiagMode) {
        Stop-Process -Name "DayZDiag_x64" -Force -ErrorAction SilentlyContinue
    }
    elseif ($isDisableBE) {
        Stop-Process -Name "DayZServer_x64_NoBe" -Force -ErrorAction SilentlyContinue
    }
    else {
        Stop-Process -Name "DayZServer_x64" -Force -ErrorAction SilentlyContinue
    }
}

# Функция для остановки клиента
function Stop-DayZClient {
    Write-ColorOutput "info.stopping_client" -ForegroundColor "Yellow" -Prefix "prefixes.client"
    if ($isDiagMode) {
        Stop-Process -Name "DayZDiag_x64" -Force -ErrorAction SilentlyContinue
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

if (!$silent) {
    Write-ColorOutput "info.launch_complete" -ForegroundColor "Green" -Prefix "prefixes.system"

    if ($autoCloseTime -gt 0) {
        1..$autoCloseTime | ForEach-Object {
            $timeLeft = $autoCloseTime - $_ + 1
            $host.UI.RawUI.WindowTitle = Get-LocalizedString "window_title_closing" -FormatArgs @($timeLeft)
            Start-Sleep -Seconds 1
        }
    }
}