param ([Parameter(Position = 0)]
    [ValidateSet("all", "server", "client", "")]
    [string]$startType = "all")

. "$PSScriptRoot\scripts\config.ps1"

$host.UI.RawUI.WindowTitle = Get-LocalizedString "window_title"

# Проверка на первый запуск
if ($script:isFirstRun) {
    Write-ColorOutput "info.press_any_key" -ForegroundColor "Yellow"
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 0
}

# Определение имен исполняемых файлов в зависимости от режима
$serverExeName = if ($isDiagMode) {
    "DayZDiag_x64.exe"
}
elseif ($isDisableBE) {
    "DayZServer_x64_NoBe.exe"
}
else {
    "DayZServer_x64.exe"
}
$clientExeName = if ($isDiagMode) {
    "DayZDiag_x64.exe"
}
elseif ($isDisableBE) {
    "DayZ_x64.exe"
}
else {
    "DayZ_BE.exe"
}

# Проверка наличия исполняемых файлов
$serverExe = if ($isDiagMode) {
    "$gamePath\$serverExeName"
}
else {
    "$serverPath\$serverExeName"
}
$clientExe = "$gamePath\$clientExeName"

if (($startType -eq "all" -or $startType -eq "server") -and -not (Test-Path $serverExe)) {
    Write-ColorOutput "errors.executable_not_found" -ForegroundColor "Red" -Prefix "prefixes.error" -FormatArgs @("server", $serverExe)
    Pause
    exit 1
}

if (($startType -eq "all" -or $startType -eq "client") -and -not (Test-Path $clientExe)) {
    Write-ColorOutput "errors.executable_not_found" -ForegroundColor "Red" -Prefix "prefixes.error" -FormatArgs @("client", $clientExe)
    Pause
    exit 1
}

if ($isDiagMode -and [string]::IsNullOrEmpty($missionPath)) {
    Write-ColorOutput "errors.mission_path_required" -ForegroundColor "Red" -Prefix "prefixes.error"
    Pause
    exit 1
}

if ($isDiagMode -and -not (Test-Path $missionPath)) {
    Write-ColorOutput "errors.mission_path_not_found" -ForegroundColor "Red" -Prefix "prefixes.error" -FormatArgs @($missionPath)
    Pause
    exit 1
}

# Вывод информации о конфиге
Write-ColorOutput "info.server_config" -ForegroundColor "Cyan"
Write-ColorOutput "separator" -ForegroundColor "Cyan"
Write-ConfigParam "info.server_preset" -Padding 16 $selectedServerPreset
Write-ConfigParam "info.mod_preset" -Padding 16 $selectedModPreset

if ($isExperimental) {
    Write-ConfigParam "info.build_type" (Get-LocalizedString "info.experimental") "Yellow"
}
if ($isDiagMode) {
    Write-ConfigParam "info.mode" (Get-LocalizedString "info.diagnostic") "Yellow"
    Write-ConfigParam "info.mission_path" $missionPath "Yellow"
}
Write-Host ""

# Остановка процессов
if (-not $startType -or $startType -eq "all") {
    & "$PSScriptRoot\scripts\kill.ps1" -mode "all" -silent
}
else {
    if ($startType -eq "server") {
        & "$PSScriptRoot\scripts\kill.ps1" -mode "server" -silent
    }
    elseif ($startType -eq "client") {
        & "$PSScriptRoot\scripts\kill.ps1" -mode "client" -silent
    }
}

# Очистка логов, если требуется
if ($shouldClearLogs) {
    Write-ColorOutput "info.clearing_logs" -ForegroundColor "Yellow" -Prefix "prefixes.logs"
    . "$PSScriptRoot\scripts\clearlogs.ps1"
}

# Запуск сервера
if ((Test-Path $serverPath) -and (($startType -eq "all" -or $startType -eq "server") -or -not $startType)) {
    if ($mod) {
        Write-ColorOutput "info.client_mods" -ForegroundColor "Cyan" -Prefix "prefixes.system"
        $clientMods | ForEach-Object {
            Write-ColorOutput "info.list_item" -ForegroundColor "White" -Prefix "prefixes.system" -FormatArgs @((Normalize-Path $_))
        }
        Write-Host ""
    }

    if ($serverMod) {
        Write-ColorOutput "info.server_mods" -ForegroundColor "Cyan" -Prefix "prefixes.system"
        $serverMods | ForEach-Object {
            Write-ColorOutput "info.list_item" -ForegroundColor "White" -Prefix "prefixes.system" -FormatArgs @((Normalize-Path $_))
        }
        Write-Host ""
    }

    Write-ColorOutput "info.starting_server" -ForegroundColor "Green" -Prefix "prefixes.system" -FormatArgs @($serverPort)

    $serverArgs = @(
        "-config=$serverConfig", "-profiles=$profilePath", "-port=$serverPort", "-dologs", "-adminlog", "-freezecheck", "-logToFile=1"
    )

    if ($isDiagMode) {
        $serverArgs += "-server"
        $serverArgs += "-mission=$missionPath"
        $serverArgs += "-newErrorsAreWarnings=1"
        $serverArgs += "-doScriptLogs=1"
    }

    if ($mod) {
        $serverArgs += """-mod=$mod"""
    }
    if ($serverMod) {
        $serverArgs += """-serverMod=$serverMod"""
    }
    if ($isFilePatching) {
        $serverArgs += "-filePatching"
    }

    #    Write-ColorOutput (Normalize-Path $serverExe)
    #    Write-ColorOutput (Normalize-Path $serverArgs)

    Start-Process -WorkingDirectory (Normalize-Path $serverPath) -FilePath (Normalize-Path $serverExe) -ArgumentList (Normalize-Path $serverArgs)
}

# Запуск клиента
if ((Test-Path $gamePath) -and (($startType -eq "all" -or $startType -eq "client") -or -not $startType)) {
    Write-ColorOutput "info.starting_client" -ForegroundColor "Green" -Prefix "prefixes.system" -FormatArgs @($serverPort)

    Push-Location $gamePath

    $clientArgs = @(
        "-connect=127.0.0.1", "-port=$serverPort", "-nosplash", "-noPause", "-noBenchmark", "-doLogs"
    )

    if ($isDiagMode) {
        $clientArgs += "-newErrorsAreWarnings=1"
    }

    if ($mod) {
        $clientArgs += """-mod=$mod"""
    }
    if ($isFilePatching) {
        $clientArgs += "-filePatching"
    }

    #    Write-ColorOutput (Normalize-Path $clientExe)
    #    Write-ColorOutput (Normalize-Path $clientArgs)

    Start-Process -WorkingDirectory (Normalize-Path $gamePath) -FilePath (Normalize-Path $clientExe) -ArgumentList (Normalize-Path $clientArgs)
    Pop-Location
}

Write-ColorOutput "info.launch_complete" -ForegroundColor "Green" -Prefix "prefixes.system"

if ($autoCloseTime -gt 0) {
    1..$autoCloseTime | ForEach-Object {
        $timeLeft = $autoCloseTime - $_ + 1
        $host.UI.RawUI.WindowTitle = Get-LocalizedString "window_title_closing" -FormatArgs @($timeLeft)
        Start-Sleep -Seconds 1
    }
}