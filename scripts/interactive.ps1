# Модуль интерактивного выбора пресетов

$script:interactiveCachePath = Join-Path $PSScriptRoot "..\.cache\interactive.json"

function Load-InteractiveCache {
    if (-not (Test-Path $script:interactiveCachePath)) {
        return $null
    }

    try {
        $raw = Get-Content -Path $script:interactiveCachePath -Raw -Encoding UTF8
        $cache = $raw | ConvertFrom-Json
        return @{
            modPreset    = $cache.modPreset
            serverPreset = $cache.serverPreset
            updatedAt    = $cache.updatedAt
        }
    }
    catch {
        Write-Warning "Interactive cache read failed, ignoring: $_"
        return $null
    }
}

function Save-InteractiveCache {
    param (
        [Parameter(Mandatory)][string]$ModPreset,
        [Parameter(Mandatory)][string]$ServerPreset
    )

    $cacheDir = Split-Path $script:interactiveCachePath -Parent

    try {
        if (-not (Test-Path $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }

        $data = @{
            modPreset    = $ModPreset
            serverPreset = $ServerPreset
            updatedAt    = (Get-Date).ToUniversalTime().ToString("o")
        }

        $data | ConvertTo-Json | Set-Content -Path $script:interactiveCachePath -Encoding UTF8
    }
    catch {
        Write-Warning (Get-LocalizedString "errors.cache_write_failed" -FormatArgs @($_.Exception.Message))
    }
}

function Show-PresetMenu {
    param (
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Items,
        [Parameter(Mandatory)][int]$DefaultIndex
    )

    if ($Items.Count -eq 0) {
        return $null
    }

    # Если только один элемент — автоматический выбор
    if ($Items.Count -eq 1) {
        Write-Host ""
        Write-Host "$Title" -ForegroundColor Cyan
        Write-Host (Get-LocalizedString "interactive.selected" -FormatArgs @($Items[0])) -ForegroundColor Green
        return $Items[0]
    }

    $selectedIndex = [Math]::Min($DefaultIndex, $Items.Count - 1)
    $defaultMarker = Get-LocalizedString "interactive.default_marker"
    $hint = Get-LocalizedString "interactive.hint"

    # Сохраняем начальную позицию курсора
    $topRow = [Console]::CursorTop

    # Функция отрисовки меню
    function Draw-Menu {
        [Console]::SetCursorPosition(0, $topRow)

        Write-Host "$Title" -ForegroundColor Cyan
        Write-Host $hint -ForegroundColor DarkGray

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $marker = ""
            if ($i -eq $DefaultIndex) {
                $marker = $defaultMarker
            }

            if ($i -eq $selectedIndex) {
                Write-Host "  > " -ForegroundColor Cyan -NoNewline
                Write-Host "$($Items[$i])$marker" -ForegroundColor Cyan
            }
            else {
                Write-Host "    $($Items[$i])$marker" -ForegroundColor Gray
            }
        }
    }

    # Скрыть курсор
    $cursorVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    # Перехват Ctrl+C как обычного ввода
    $prevCtrlC = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true

    try {
        Draw-Menu

        while ($true) {
            $key = [Console]::ReadKey($true)

            switch ($key.Key) {
                'UpArrow' {
                    if ($selectedIndex -gt 0) { $selectedIndex-- }
                    Draw-Menu
                }
                'DownArrow' {
                    if ($selectedIndex -lt $Items.Count - 1) { $selectedIndex++ }
                    Draw-Menu
                }
                'Home' {
                    $selectedIndex = 0
                    Draw-Menu
                }
                'End' {
                    $selectedIndex = $Items.Count - 1
                    Draw-Menu
                }
                'PageUp' {
                    $selectedIndex = 0
                    Draw-Menu
                }
                'PageDown' {
                    $selectedIndex = $Items.Count - 1
                    Draw-Menu
                }
                'Enter' {
                    # Очистка меню и вывод результата
                    [Console]::SetCursorPosition(0, $topRow)
                    for ($i = 0; $i -le ($Items.Count + 1); $i++) {
                        Write-Host (" " * [Console]::WindowWidth)
                    }
                    [Console]::SetCursorPosition(0, $topRow)

                    Write-Host (Get-LocalizedString "interactive.selected" -FormatArgs @($Items[$selectedIndex])) -ForegroundColor Green
                    return $Items[$selectedIndex]
                }
                'Escape' {
                    # Очистка меню
                    [Console]::SetCursorPosition(0, $topRow)
                    for ($i = 0; $i -le ($Items.Count + 1); $i++) {
                        Write-Host (" " * [Console]::WindowWidth)
                    }
                    [Console]::SetCursorPosition(0, $topRow)

                    Write-Host (Get-LocalizedString "interactive.cancelled") -ForegroundColor Yellow
                    return $null
                }
                default {
                    # Ctrl+C — отмена, аналогично Escape
                    if ($key.Modifiers -band [ConsoleModifiers]::Control -and $key.Key -eq 'C') {
                        [Console]::SetCursorPosition(0, $topRow)
                        for ($i = 0; $i -le ($Items.Count + 1); $i++) {
                            Write-Host (" " * [Console]::WindowWidth)
                        }
                        [Console]::SetCursorPosition(0, $topRow)

                        Write-Host (Get-LocalizedString "interactive.cancelled") -ForegroundColor Yellow
                        return $null
                    }

                    # Быстрый выбор по цифре (1-9)
                    if ($Items.Count -le 9 -and $key.KeyChar -match '[1-9]') {
                        $num = [int]$key.KeyChar.ToString()
                        if ($num -le $Items.Count) {
                            $selectedIndex = $num - 1

                            [Console]::SetCursorPosition(0, $topRow)
                            for ($i = 0; $i -le ($Items.Count + 1); $i++) {
                                Write-Host (" " * [Console]::WindowWidth)
                            }
                            [Console]::SetCursorPosition(0, $topRow)

                            Write-Host (Get-LocalizedString "interactive.selected" -FormatArgs @($Items[$selectedIndex])) -ForegroundColor Green
                            return $Items[$selectedIndex]
                        }
                    }
                }
            }
        }
    }
    finally {
        [Console]::TreatControlCAsInput = $prevCtrlC
        [Console]::CursorVisible = $cursorVisible
    }
}

function Invoke-InteractivePresetSelection {
    param (
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DefaultModPreset,
        [Parameter(Mandatory)][string]$DefaultServerPreset
    )

    $modPresetNames = @($Config.modsPresets.PSObject.Properties.Name)
    $serverPresetNames = @($Config.serverPresets.PSObject.Properties.Name)

    # Проверка наличия пресетов
    if ($modPresetNames.Count -eq 0) {
        Write-ColorOutput "errors.no_presets" -ForegroundColor "Red" -Prefix "prefixes.error" -FormatArgs @("mod")
        exit 1
    }
    if ($serverPresetNames.Count -eq 0) {
        Write-ColorOutput "errors.no_presets" -ForegroundColor "Red" -Prefix "prefixes.error" -FormatArgs @("server")
        exit 1
    }

    # Загрузка кэша и определение дефолтных значений
    $cache = Load-InteractiveCache
    $resolvedModDefault = $DefaultModPreset
    $resolvedServerDefault = $DefaultServerPreset

    if ($null -ne $cache) {
        if ($modPresetNames -contains $cache.modPreset) {
            $resolvedModDefault = $cache.modPreset
        }
        if ($serverPresetNames -contains $cache.serverPreset) {
            $resolvedServerDefault = $cache.serverPreset
        }
    }

    # Определение начальных индексов
    $modDefaultIndex = [Math]::Max(0, [Array]::IndexOf($modPresetNames, $resolvedModDefault))
    $serverDefaultIndex = [Math]::Max(0, [Array]::IndexOf($serverPresetNames, $resolvedServerDefault))

    # Меню модов
    $modTitle = Get-LocalizedString "interactive.title_mod"
    $pickedMod = Show-PresetMenu -Title $modTitle -Items $modPresetNames -DefaultIndex $modDefaultIndex

    if ($null -eq $pickedMod) {
        return $null
    }

    # Меню серверов
    $serverTitle = Get-LocalizedString "interactive.title_server"
    $pickedServer = Show-PresetMenu -Title $serverTitle -Items $serverPresetNames -DefaultIndex $serverDefaultIndex

    if ($null -eq $pickedServer) {
        return $null
    }

    return @{
        ModPreset    = $pickedMod
        ServerPreset = $pickedServer
    }
}
