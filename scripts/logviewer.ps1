param (
    [Parameter(Mandatory = $true)]
    [string]$ProfilePath,

    [Parameter(Mandatory = $false)]
    [string]$ServerLogs = "",

    [Parameter(Mandatory = $false)]
    [string]$ClientLogs = "",

    [Parameter(Mandatory = $false)]
    [string]$LogPreset = "",

    [Parameter(Mandatory = $false)]
    [string]$Filter = "",

    [string]$lang = "",

    [int]$autoCloseTime = -1
)

# Обработка ошибок на уровне скрипта
$ErrorActionPreference = "Continue"
trap {
    $msg = $script:Loc.logviewer.fatal_error -f $_
    Write-Host "[logviewer] $msg" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host "`n$($script:Loc.logviewer.press_any_key)" -ForegroundColor Yellow
    if ($autoCloseTime -lt 0) {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } elseif ($autoCloseTime -gt 0) {
        Start-Sleep -Seconds $autoCloseTime
    }
    exit 1
}

# Извлечение версии из config.ps1
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configContent = Get-Content (Join-Path $scriptDir "config.ps1") -Raw
$ScriptVersion = "unknown"
foreach ($line in ($configContent -split "`n")) {
    if ($line.Trim() -match '^\$ScriptVersion\s*=\s*["''](.+?)["'']') {
        $ScriptVersion = $Matches[1]
        break
    }
}

$host.UI.RawUI.WindowTitle = "DayZ Log Viewer v$ScriptVersion"

# Загрузка локализации
$localesPath = Join-Path $scriptDir "locales.json"
$locales = Get-Content $localesPath -Raw -Encoding UTF8 | ConvertFrom-Json

# Определение языка
$effectiveLang = if ($lang -ne "") { $lang } else { [System.Globalization.CultureInfo]::CurrentCulture.TwoLetterISOLanguageName }
if ($locales.PSObject.Properties.Name -contains $effectiveLang) {
    $script:Loc = $locales.$effectiveLang
} else {
    $script:Loc = $locales.en
}

function Get-T {
    param([string]$Key)
    $obj = $script:Loc
    foreach ($part in $Key.Split('.')) {
        if ($obj.PSObject.Properties.Name -contains $part) {
            $obj = $obj.$part
        } else {
            return $Key
        }
    }
    return $obj
}

function Format-T {
    param([string]$Key, [object[]]$Values)
    $template = Get-T $Key
    if ($Values -and $Values.Count -gt 0) {
        return ($template -f $Values)
    }
    return $template
}

# Определение пути к клиентским логам
$gamePath = $env:LOCALAPPDATA
$dayzExe = Get-Process -Name "DayZ_x64" -ErrorAction SilentlyContinue
if ($dayzExe) {
    $clientLogsPath = Join-Path $gamePath "DayZ Exp"
} else {
    $clientLogsPath = Join-Path $gamePath "DayZ"
}

# Пресеты логов
$LogPresets = @{
    "p_rpt"     = "*.RPT"
    "p_adm"     = "*.ADM"
    "p_script"  = "script_*.log"
    "p_console" = "serverconsole.log"
    "p_all"     = "*.RPT,*.ADM,script_*.log,serverconsole.log"
}

# Префиксы для пресетов
$PresetPrefixes = @{
    "p_rpt"     = "RPT"
    "p_adm"     = "ADM"
    "p_script"  = "SCRIPT"
    "p_console" = "CONSOLE"
}

# Структуры данных
$script:filePrefixMap = @{}  # fullPath -> prefix (RPT, ADM, SCRIPT, CONSOLE)
$script:fileTypeMap = @{}    # fullPath -> "server" | "client"
$script:rawFiles = @()

function Get-PrefixForFile {
    param([string]$FilePath)
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $extension = [System.IO.Path]::GetExtension($fileName).ToUpperInvariant()

    if ($extension -eq '.RPT') { return 'RPT' }
    if ($extension -eq '.ADM') { return 'ADM' }
    if ($fileName -like 'script_*.log') { return 'SCRIPT' }
    if ($fileName -eq 'serverconsole.log') { return 'CONSOLE' }

    return [System.IO.Path]::GetFileNameWithoutExtension($fileName)
}

function Add-Files {
    param(
        [string[]]$Files,
        [string]$SearchPath,
        [string]$FileType
    )
    
    foreach ($f in $Files) {
        if ([string]::IsNullOrEmpty($f)) { continue }
        
        if ($f -match '[*?]') {
            $found = Get-ChildItem -Path $SearchPath -Filter $f -File -ErrorAction SilentlyContinue
            if ($found) {
                foreach ($match in $found) {
                    $fullPath = $match.FullName
                    if (-not $script:filePrefixMap.ContainsKey($fullPath)) {
                        $script:filePrefixMap[$fullPath] = Get-PrefixForFile $fullPath
                        $script:fileTypeMap[$fullPath] = $FileType
                        $script:rawFiles += $fullPath
                    }
                }
            }
        } else {
            $fullPath = Join-Path $SearchPath $f
            if (-not $script:filePrefixMap.ContainsKey($fullPath)) {
                $script:filePrefixMap[$fullPath] = Get-PrefixForFile $fullPath
                $script:fileTypeMap[$fullPath] = $FileType
                $script:rawFiles += $fullPath
            }
        }
    }
}

# Функция раскрытия пресетов в списке файлов
function Expand-PresetsInList {
    param(
        [string]$FileList,
        [string]$SearchPath,
        [string]$FileType
    )
    
    if ([string]::IsNullOrEmpty($FileList)) { return }
    
    $items = $FileList -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $expandedFiles = @()
    
    foreach ($item in $items) {
        if ($LogPresets.ContainsKey($item)) {
            # Раскрываем пресет
            $pattern = $LogPresets[$item]
            $patterns = $pattern -split "," | ForEach-Object { $_.Trim() }
            foreach ($pat in $patterns) {
                $found = Get-ChildItem -Path $SearchPath -Filter $pat -File -ErrorAction SilentlyContinue
                if ($found) {
                    foreach ($match in $found) {
                        $fullPath = $match.FullName
                        if (-not $script:filePrefixMap.ContainsKey($fullPath)) {
                            $script:filePrefixMap[$fullPath] = Get-PrefixForFile $fullPath
                            $script:fileTypeMap[$fullPath] = $FileType
                            $script:rawFiles += $fullPath
                        }
                    }
                }
            }
        } else {
            # Обычный файл или wildcard
            $expandedFiles += $item
        }
    }
    
    # Обрабатываем оставшиеся файлы (не пресеты)
    if ($expandedFiles.Count -gt 0) {
        Add-Files -Files $expandedFiles -SearchPath $SearchPath -FileType $FileType
    }
}

# Обработка пресетов для обоих типов логов (через параметр -LogPreset)
if (-not [string]::IsNullOrEmpty($LogPreset)) {
    if ($LogPresets.ContainsKey($LogPreset)) {
        $pattern = $LogPresets[$LogPreset]
        $patterns = $pattern -split "," | ForEach-Object { $_.Trim() }
        
        foreach ($pat in $patterns) {
            # Серверные логи
            if (-not [string]::IsNullOrEmpty($ServerLogs)) {
                $found = Get-ChildItem -Path $ProfilePath -Filter $pat -File -ErrorAction SilentlyContinue
                if ($found) {
                    foreach ($match in $found) {
                        $fullPath = $match.FullName
                        if (-not $script:filePrefixMap.ContainsKey($fullPath)) {
                            $script:filePrefixMap[$fullPath] = Get-PrefixForFile $fullPath
                            $script:fileTypeMap[$fullPath] = "server"
                            $script:rawFiles += $fullPath
                        }
                    }
                }
            }
            
            # Клиентские логи
            if (-not [string]::IsNullOrEmpty($ClientLogs)) {
                $found = Get-ChildItem -Path $clientLogsPath -Filter $pat -File -ErrorAction SilentlyContinue
                if ($found) {
                    foreach ($match in $found) {
                        $fullPath = $match.FullName
                        if (-not $script:filePrefixMap.ContainsKey($fullPath)) {
                            $script:filePrefixMap[$fullPath] = Get-PrefixForFile $fullPath
                            $script:fileTypeMap[$fullPath] = "client"
                            $script:rawFiles += $fullPath
                        }
                    }
                }
            }
        }
    }
}

# Обработка списков файлов с раскрытием пресетов внутри
Expand-PresetsInList -FileList $ServerLogs -SearchPath $ProfilePath -FileType "server"
Expand-PresetsInList -FileList $ClientLogs -SearchPath $clientLogsPath -FileType "client"

$logFilesArray = $script:rawFiles
$useFilter = -not [string]::IsNullOrEmpty($Filter)
$filterPattern = if ($useFilter) { $Filter } else { $null }
$pendingFiles = @()
$wildcardPatterns = @()

# Вычисление максимальной ширины префикса
$maxPrefixLength = 0
foreach ($prefix in $script:filePrefixMap.Values) {
    if ($prefix.Length -gt $maxPrefixLength) {
        $maxPrefixLength = $prefix.Length
    }
}

function Get-LogPrefix {
    param([string]$FilePath)
    if ($script:filePrefixMap.ContainsKey($FilePath)) {
        $prefix = $script:filePrefixMap[$FilePath]
        return $prefix.PadRight($maxPrefixLength)
    }
    return $FilePath.PadRight($maxPrefixLength)
}

function Get-PrefixColor {
    param([string]$FilePath)
    if ($script:fileTypeMap[$FilePath] -eq "server") {
        return "DarkCyan"
    } else {
        return "DarkMagenta"
    }
}

function Get-LogTypePrefix {
    param([string]$FilePath)
    if ($script:fileTypeMap[$FilePath] -eq "server") {
        return "S"
    } else {
        return "C"
    }
}

Write-Host "[logviewer] $(Format-T 'logviewer.profile' (,$ProfilePath))" -ForegroundColor Cyan
if (-not [string]::IsNullOrEmpty($ClientLogs)) {
    Write-Host "[logviewer] $(Format-T 'logviewer.client_profile' (,$clientLogsPath))" -ForegroundColor Cyan
}
Write-Host "[logviewer] $(Get-T 'logviewer.files')" -ForegroundColor Cyan
foreach ($f in $logFilesArray) {
    $typeStr = if ($script:fileTypeMap[$f] -eq "server") { "[S]" } else { "[C]" }
    Write-Host "            $typeStr $f" -ForegroundColor Cyan
}
if ($useFilter) {
    Write-Host "[logviewer] $(Format-T 'logviewer.filter' (,$Filter))" -ForegroundColor Cyan
}

function Get-ColorForLine {
    param([string]$Line)

    if ($Line -match "ERROR|Script ERROR") { return "Red" }
    if ($Line -match "WARNING|Script WARNING") { return "Yellow" }
    if ($Line -match "INFO|Script INFO") { return "Green" }
    return "White"
}

# Хранилище состояний файлов: путь -> { Reader, LastPosition, LogName }
$fileStates = @{}

# Инициализация начальных файлов
foreach ($logFile in $logFilesArray) {
    $fullPath = $logFile
    $logName = $script:filePrefixMap[$logFile]

    if (-not (Test-Path $fullPath)) {
        Write-Host "[logviewer] $(Format-T 'logviewer.file_not_found' (,$fullPath))" -ForegroundColor DarkYellow
        $pendingFiles += $fullPath
        continue
    }

    $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $fileStates[$fullPath] = @{
        Reader = New-Object System.IO.StreamReader($stream)
        LastPosition = 0
        LogName = $logName
    }

    Write-Host "[logviewer] $(Format-T 'logviewer.started_monitor' (,$logName))" -ForegroundColor Green
}

if ($fileStates.Count -eq 0 -and $wildcardPatterns.Count -eq 0) {
    Write-Host "[logviewer] $(Get-T 'logviewer.no_files')" -ForegroundColor Red
    Write-Host "`n$(Get-T 'logviewer.press_any_key')" -ForegroundColor Yellow
    if ($autoCloseTime -lt 0) {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } elseif ($autoCloseTime -gt 0) {
        Start-Sleep -Seconds $autoCloseTime
    }
    exit 1
}

if ($fileStates.Count -eq 0) {
    Write-Host "[logviewer] $(Format-T 'logviewer.waiting_files' (,($wildcardPatterns -join ', ')))" -ForegroundColor DarkYellow
}

Write-Host "`n[logviewer] $(Format-T 'logviewer.monitoring' (,$fileStates.Count))" -ForegroundColor Cyan
Write-Host "-----------------------------------------------------------`n" -ForegroundColor DarkGray

# Отслеживаем все уже добавленные файлы
$trackedFiles = @{}
foreach ($key in $fileStates.Keys) {
    $trackedFiles[$key] = $true
}

$wildcardCheckCounter = 0

try {
    while ($true) {
        # Проверяем появление новых файлов по wildcard-паттернам и pending-файлам
        if ($wildcardPatterns.Count -gt 0 -or $pendingFiles.Count -gt 0) {
            $wildcardCheckCounter++
            if ($wildcardCheckCounter -ge 25) {
                $wildcardCheckCounter = 0

                # Проверяем wildcard-паттерны
                foreach ($pattern in $wildcardPatterns) {
                    $found = Get-ChildItem -Path $ProfilePath -Filter $pattern -File -ErrorAction SilentlyContinue
                    if ($found) {
                        foreach ($match in $found) {
                            $newFilePath = $match.FullName
                            if (-not $trackedFiles.ContainsKey($newFilePath)) {
                                $trackedFiles[$newFilePath] = $true
                                $newLogName = Get-PrefixForFile $newFilePath

                                $stream = [System.IO.File]::Open($newFilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                                $fileStates[$newFilePath] = @{
                                    Reader = New-Object System.IO.StreamReader($stream)
                                    LastPosition = 0
                                    LogName = $newLogName
                                }
                                Write-Host "`n[logviewer] $(Format-T 'logviewer.new_file_detected' (,$newLogName))" -ForegroundColor Green
                            }
                        }
                    }
                }

                # Проверяем pending-файлы (обычные файлы, не найденные при старте)
                $stillPending = @()
                foreach ($pendingPath in $pendingFiles) {
                    if (-not $trackedFiles.ContainsKey($pendingPath) -and (Test-Path $pendingPath)) {
                        $trackedFiles[$pendingPath] = $true
                        $pendingLogName = $script:filePrefixMap[$pendingPath]

                        $stream = [System.IO.File]::Open($pendingPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                        $fileStates[$pendingPath] = @{
                            Reader = New-Object System.IO.StreamReader($stream)
                            LastPosition = 0
                            LogName = $pendingLogName
                        }
                        Write-Host "`n[logviewer] $(Format-T 'logviewer.file_appeared' (,$pendingLogName))" -ForegroundColor Green
                    } else {
                        $stillPending += $pendingPath
                    }
                }
                $pendingFiles = $stillPending
            }
        }

        # Последовательный опрос всех файлов
        $filesToRemove = @()
        foreach ($filePath in $fileStates.Keys) {
            $state = $fileStates[$filePath]

            try {
                if (-not (Test-Path $filePath)) {
                    continue
                }

                $file = Get-Item $filePath
                $currentLength = $file.Length

                # Если файл стал меньше (ротация), сбрасываем
                if ($currentLength -lt $state.LastPosition) {
                    try { $state.Reader.Close() } catch {}
                    $stream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $state.Reader = New-Object System.IO.StreamReader($stream)
                    $state.LastPosition = 0
                }

                # Если есть новые данные
                if ($currentLength -gt $state.LastPosition) {
                    $state.Reader.BaseStream.Seek($state.LastPosition, [System.IO.SeekOrigin]::Begin) | Out-Null

                    while ($null -ne ($line = $state.Reader.ReadLine())) {
                        $shouldOutput = $true
                        if ($useFilter -and $line -notmatch $filterPattern) {
                            $shouldOutput = $false
                        }

                        if ($shouldOutput) {
                            $color = Get-ColorForLine $line
                            $prefixColor = Get-PrefixColor $filePath
                            $typePrefix = Get-LogTypePrefix $filePath
                            $prefix = Get-LogPrefix $filePath
                            Write-Host "[$typePrefix" -ForegroundColor $prefixColor -NoNewline
                            Write-Host "][$prefix] " -ForegroundColor $prefixColor -NoNewline
                            Write-Host $line -ForegroundColor $color
                        }
                    }

                    $state.LastPosition = $state.Reader.BaseStream.Position
                }
            }
            catch {
                # При ошибке пересоздаём reader
                try { $state.Reader.Close() } catch {}
                if (Test-Path $filePath) {
                    $stream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $state.Reader = New-Object System.IO.StreamReader($stream)
                    $state.LastPosition = 0
                } else {
                    $filesToRemove += $filePath
                }
            }
        }

        # Удаляем несуществующие файлы из отслеживания
        foreach ($removePath in $filesToRemove) {
            $fileStates.Remove($removePath)
        }

        Start-Sleep -Milliseconds 200
    }
}
finally {
    Write-Host "`n[logviewer] $(Get-T 'logviewer.stopping')" -ForegroundColor Yellow

    # Закрываем все reader'ы
    foreach ($state in $fileStates.Values) {
        try {
            if ($state.Reader) {
                $state.Reader.Close()
                $state.Reader.Dispose()
            }
        }
        catch { }
    }

    Write-Host "[logviewer] $(Get-T 'logviewer.done')" -ForegroundColor Yellow
    Write-Host "`n$(Get-T 'logviewer.press_any_key')" -ForegroundColor Yellow
    if ($autoCloseTime -lt 0) {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } elseif ($autoCloseTime -gt 0) {
        Start-Sleep -Seconds $autoCloseTime
    }
}
