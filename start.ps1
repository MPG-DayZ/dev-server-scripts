param (
    [Parameter(Position = 0)]
    [ValidateSet("all", "server", "client", "")]
    [string]$startType = "all",

    [string]$modPreset = "",

    [string]$serverPreset = "",

    [int]$autoCloseTime = -1,

    [string]$lang = "",

    [switch]$help
)

# Вывод справки
if ($help) {
    Write-Host ""
    Write-Host "=== Скрипт запуска DayZ сервера и клиента ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Описание:" -ForegroundColor Yellow
    Write-Host "  Скрипт запускает сервер и/или клиент DayZ с указанными параметрами." -ForegroundColor White
    Write-Host ""
    Write-Host "Параметры:" -ForegroundColor Yellow
    Write-Host "  -startType <all|server|client>  Что запускать (по умолчанию: all)" -ForegroundColor White
    Write-Host "  -modPreset <имя>                Имя пресета модов (по умолчанию: из конфига)" -ForegroundColor White
    Write-Host "  -serverPreset <имя>             Имя серверного пресета (по умолчанию: из конфига)" -ForegroundColor White
    Write-Host "  -autoCloseTime <секунды>        Время автозакрытия окна в секундах (0 = не закрывать)" -ForegroundColor White
    Write-Host "  -lang <ru|en|auto>              Язык интерфейса (по умолчанию: из конфига)" -ForegroundColor White
    Write-Host "  -help                           Показать эту справку" -ForegroundColor White
    Write-Host ""
    Write-Host "Доступные пресеты модов:" -ForegroundColor Yellow

    # Загружаем конфиг для получения списка пресетов
    . "$PSScriptRoot\scripts\config.ps1"

    if ($config -and $config.modsPresets) {
        foreach ($presetName in $config.modsPresets.PSObject.Properties.Name) {
            Write-Host "  - $presetName" -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "Доступные серверные пресеты:" -ForegroundColor Yellow
    if ($config -and $config.serverPresets) {
        foreach ($presetName in $config.serverPresets.PSObject.Properties.Name) {
            Write-Host "  - $presetName" -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "Примеры использования:" -ForegroundColor Yellow
    Write-Host "  .\start.ps1 -startType server" -ForegroundColor Gray
    Write-Host "  .\start.ps1 -modPreset myPreset1 -serverPreset release" -ForegroundColor Gray
    Write-Host "  .\start.ps1 -autoCloseTime 60 -lang ru" -ForegroundColor Gray
    Write-Host "  .\start.ps1 -help" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# Сохраняем параметры командной строки ДО загрузки конфига
$cmdModPreset = $modPreset
$cmdServerPreset = $serverPreset

# Удаляем типизированные (string) param-переменные, чтобы config.ps1 мог переиспользовать
# имена $modPreset / $serverPreset для хранения объектов пресетов без принуждения к ToString()
Remove-Variable -Name modPreset, serverPreset -Scope Script -ErrorAction SilentlyContinue

. "$PSScriptRoot\scripts\config.ps1"

# === Интерактивный выбор пресетов ===
$interactiveEnabled = $config.active.PSObject.Properties.Name -contains "interactive" `
    -and $config.active.interactive -eq $true
$noCliPresets = ($cmdModPreset -eq "") -and ($cmdServerPreset -eq "")

if ($interactiveEnabled -and $noCliPresets) {
    . "$PSScriptRoot\scripts\interactive.ps1"
    $picked = Invoke-InteractivePresetSelection `
        -Config $config `
        -DefaultModPreset $selectedModPreset `
        -DefaultServerPreset $selectedServerPreset

    if ($null -ne $picked) {
        $cmdModPreset    = $picked.ModPreset
        $cmdServerPreset = $picked.ServerPreset
        Save-InteractiveCache -ModPreset $picked.ModPreset -ServerPreset $picked.ServerPreset
    }
    else {
        exit 0
    }
}
# === /Интерактивный выбор пресетов ===

# Переопределение значений из параметров командной строки
if ($cmdModPreset -ne "") {
    $selectedModPreset = $cmdModPreset

    # Проверка наличия пресета
    if (-not $config.modsPresets.$selectedModPreset) {
        Write-ColorOutput "errors.preset_not_found" -ForegroundColor "Red" -Prefix "prefixes.error" -FormatArgs @("mod", $selectedModPreset)
        Pause
        exit 1
    }

    # Обновление модов из нового пресета
    $modPreset = $config.modsPresets.$selectedModPreset

    $clientMods = @()
    foreach ($mod in $modPreset.client) {
        $clientMods += (Resolve-ModPath $mod)
    }

    $serverMods = @()
    foreach ($mod in $modPreset.server) {
        $serverMods += (Resolve-ModPath $mod)
    }

    $mod = $clientMods -join ";"
    $serverMod = $serverMods -join ";"
}

# Переопределение пресета сервера из параметра командной строки
if ($cmdServerPreset -ne "") {
    $selectedServerPreset = $cmdServerPreset
}

# Проверка наличия пресета
if (-not $config.serverPresets.$selectedServerPreset) {
    Write-ColorOutput "errors.preset_not_found" -ForegroundColor "Red" -Prefix "prefixes.error" -FormatArgs @("server", $selectedServerPreset)
    Pause
    exit 1
}

# Извлечение всех зависимых переменных из пресета (ВСЕГДА, а не только при явном указании -serverPreset)
$serverPresetObj = $config.serverPresets.$selectedServerPreset

$gamePath = Format-Path $serverPresetObj.gamePath
$serverPath = Format-Path $serverPresetObj.serverPath
$profilePath = Format-Path $serverPresetObj.profilePath
$missionPath = Format-Path $serverPresetObj.missionPath
$serverPort = $serverPresetObj.serverPort
$serverConfig = $serverPresetObj.serverConfig
$isDiagMode = $serverPresetObj.isDiagMode
$isFilePatching = $serverPresetObj.isFilePatching
$isDisableBE = $serverPresetObj.isDisableBE
$isExperimental = $serverPresetObj.isExperimental
$cleanLogsMode = $serverPresetObj.cleanLogs
$steamWorkshopPath = Format-Path $serverPresetObj.workshop.steam
$localModsPath = Format-Path $serverPresetObj.workshop.local
$logViewerConfig = $serverPresetObj.logViewer
$logViewerEnabled = $logViewerConfig -and ($logViewerConfig.server -eq $true -or $logViewerConfig.client -eq $true)

# Флаги очистки логов
$shouldClearLogs = $cleanLogsMode -ne "none"
$clearLogsClient = $cleanLogsMode -eq "all" -or $cleanLogsMode -eq "client"
$clearLogsServer = $cleanLogsMode -eq "all" -or $cleanLogsMode -eq "server"

# Имена исполняемых файлов
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

# Путь к логам клиента
if ($isExperimental) {
    $clientLogsPath = "$env:LOCALAPPDATA\DayZ Exp"
}
else {
    $clientLogsPath = "$env:LOCALAPPDATA\DayZ"
}

if ($autoCloseTime -ge 0) {
    $script:autoCloseTime = $autoCloseTime
}

if ($lang -ne "") {
    Set-CurrentLanguage $lang
}

$host.UI.RawUI.WindowTitle = "$(Get-LocalizedString "window_title") v$ScriptVersion"

# Проверка на первый запуск
if ($script:isFirstRun) {
    Write-ColorOutput "info.press_any_key" -ForegroundColor "Yellow"
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 0
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

if($isDisableBE) {
    Write-ColorOutput "separator" -ForegroundColor "Cyan"
    Write-ColorOutput "info.disable_be" -ForegroundColor "Yellow"
}

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
    & "$PSScriptRoot\scripts\kill.ps1" -mode "all" -silent -serverPreset $selectedServerPreset
}
else {
    if ($startType -eq "server") {
        & "$PSScriptRoot\scripts\kill.ps1" -mode "server" -silent -serverPreset $selectedServerPreset
    }
    elseif ($startType -eq "client") {
        & "$PSScriptRoot\scripts\kill.ps1" -mode "client" -silent -serverPreset $selectedServerPreset
    }
}

# Очистка логов, если требуется
if ($shouldClearLogs) {
    Write-ColorOutput "info.clearing_logs" -ForegroundColor "Yellow" -Prefix "prefixes.logs"
    . "$PSScriptRoot\scripts\clearlogs.ps1"
}

# Запуск сервера
# Убиваем предыдущий процесс logviewer, если он запущен
taskkill /F /FI "WINDOWTITLE eq DayZ Log Viewer v*" 2>$null | Out-Null

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

    Start-Process -FilePath (Normalize-Path $serverExe) -ArgumentList (Normalize-Path $serverArgs)
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

    Start-Process -FilePath (Normalize-Path $clientExe) -ArgumentList (Normalize-Path $clientArgs)
    Pop-Location
}

Write-ColorOutput "info.launch_complete" -ForegroundColor "Green" -Prefix "prefixes.system"

# Запуск мониторинга логов отдельным процессом
$hasServerLogs = $logViewerConfig -and $logViewerConfig.server -and $logViewerConfig.serverLogs -and $logViewerConfig.serverLogs.Count -gt 0
$hasClientLogs = $logViewerConfig -and $logViewerConfig.client -and $logViewerConfig.clientLogs -and $logViewerConfig.clientLogs.Count -gt 0

if ($logViewerEnabled -and ($hasServerLogs -or $hasClientLogs)) {
    Start-Sleep -Seconds 5
    Write-ColorOutput "info.starting_log_viewer" -ForegroundColor "Cyan" -Prefix "prefixes.system"

    $serverLogsStr = if ($hasServerLogs) {
        ($logViewerConfig.serverLogs -join ",")
    } else { "" }

    $clientLogsStr = if ($hasClientLogs) {
        ($logViewerConfig.clientLogs -join ",")
    } else { "" }
    
    $filterStr = if ($logViewerConfig.filter -and $logViewerConfig.filter.Count -gt 0) {
        ($logViewerConfig.filter -join "|")
    } else { "" }

    $logViewerScript = Join-Path $PSScriptRoot "scripts\logviewer.ps1"
    $logViewerArgs = "-ProfilePath `"$profilePath`" -ServerLogs `"$serverLogsStr`" -ClientLogs `"$clientLogsStr`" -Filter `"$filterStr`" -Lang `"$script:currentLocale`" -AutoCloseTime $autoCloseTime -Version `"$ScriptVersion`" -ClientLogsPath `"$clientLogsPath`""

    Start-Process -FilePath "pwsh.exe" -ArgumentList "-NoLogo -ExecutionPolicy Bypass -File `"$logViewerScript`" $logViewerArgs" -WindowStyle Normal
}

if ($autoCloseTime -gt 0) {
    1..$autoCloseTime | ForEach-Object {
        $timeLeft = $autoCloseTime - $_ + 1
        $host.UI.RawUI.WindowTitle = "$(Get-LocalizedString "window_title_closing" -FormatArgs @($timeLeft)) v$ScriptVersion"
        Start-Sleep -Seconds 1
    }
}