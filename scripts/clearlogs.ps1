# Функция для проверки, запущен ли процесс
function Test-ProcessRunning {
    param ([string]$ProcessName, [int]$RetryCount = 3, [int]$RetryDelay = 1)

    for ($i = 0; $i -lt $RetryCount; $i++) {
        $process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            return $false
        }
        Start-Sleep -Seconds $RetryDelay
    }
    return $true
}

# Очистка логов сервера
if ($clearLogsServer) {
    $serverProcessName = if ($isDiagMode) { "DayZDiag_x64" }
        elseif ($isDisableBE) { "DayZServer_x64_NoBe" }
        else { "DayZServer_x64" }

    if (Test-ProcessRunning $serverProcessName -RetryCount 2 -RetryDelay 1) {
        Write-ColorOutput "logs.server_running" -ForegroundColor "Yellow" -Prefix "prefixes.logs"
    }
    else {
        Write-ColorOutput "logs.cleaning_server" -ForegroundColor "White" -Prefix "prefixes.logs"

        # Очистка логов в папке сервера
        $serverLogs = Get-ChildItem -Path $serverPath -Include "*.log","*.mdmp","*.RPT","*.ADM" -Recurse -ErrorAction SilentlyContinue
        if ($serverLogs) {
            Write-ColorOutput "logs.found_server" -ForegroundColor "White" -Prefix "prefixes.logs" -FormatArgs @($serverLogs.Count)
            foreach ($log in $serverLogs) {
                Write-ColorOutput "logs.deleting" -ForegroundColor "White" -Prefix "prefixes.logs" -FormatArgs @($log.FullName)
                Remove-Item -LiteralPath $log.FullName -Force -ErrorAction SilentlyContinue
            }
            Write-ColorOutput "logs.server_cleaned" -ForegroundColor "White" -Prefix "prefixes.logs"
        }

        # Очистка логов в папке профилей
        $profileLogs = Get-ChildItem -Path $profilePath -Include "*.log","*.mdmp","*.RPT","*.ADM" -Recurse -ErrorAction SilentlyContinue
        if ($profileLogs) {
            foreach ($log in $profileLogs) {
                Write-ColorOutput "logs.deleting" -ForegroundColor "White" -Prefix "prefixes.logs" -FormatArgs @($log.FullName)
                Remove-Item -LiteralPath $log.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Write-ColorOutput "logs.profile_not_found" -ForegroundColor "White" -Prefix "prefixes.logs"
        }
    }
}

# Очистка логов клиента
if ($clearLogsClient) {
    $clientProcessName = if ($isDiagMode) { "DayZDiag_x64" } else { "DayZ_x64" }

    if (Test-ProcessRunning $clientProcessName -RetryCount 2 -RetryDelay 1) {
        Write-ColorOutput "logs.client_running" -ForegroundColor "Yellow" -Prefix "prefixes.logs"
    }
    else {
        Write-ColorOutput "logs.cleaning_client" -ForegroundColor "White" -Prefix "prefixes.logs" -FormatArgs @($clientLogsPath)

        $clientLogs = Get-ChildItem -Path $clientLogsPath -Include "*.log","*.mdmp","*.RPT" -Recurse -ErrorAction SilentlyContinue
        if ($clientLogs) {
            Write-ColorOutput "logs.found_client" -ForegroundColor "White" -Prefix "prefixes.logs" -FormatArgs @($clientLogs.Count)
            foreach ($log in $clientLogs) {
                Write-ColorOutput "logs.deleting" -ForegroundColor "White" -Prefix "prefixes.logs" -FormatArgs @($log.FullName)
                Remove-Item -LiteralPath $log.FullName -Force -ErrorAction SilentlyContinue
            }
            Write-ColorOutput "logs.client_cleaned" -ForegroundColor "White" -Prefix "prefixes.logs"
        }
    }
}

Write-ColorOutput "logs.complete" -ForegroundColor "White" -Prefix "prefixes.logs"

