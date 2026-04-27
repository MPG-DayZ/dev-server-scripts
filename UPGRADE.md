# Инструкция по ручному обновлению конфигов

Этот файл описывает изменения, которые необходимо внести вручную в конфигурационные файлы после `git pull`, если
у вас уже была установленная версия с существующим `config.json`.

---

## Добавление секции `logViewer` в каждый пресет сервера

В каждый объект внутри `serverPresets` необходимо добавить новую секцию `logViewer`.

### Минимальный вариант (логи отключены)

```json
"logViewer": {
    "server": false,
    "client": false,
    "serverLogs": [],
    "clientLogs": [],
    "filter": []
}
```

### Стандартный вариант (все логи включены)

```json
"logViewer": {
    "server": true,
    "client": true,
    "serverLogs": [
        "p_rpt",
        "p_adm",
        "p_script",
        "p_console"
    ],
    "clientLogs": [
        "p_all"
    ],
    "filter": []
}
```

### Расширенный вариант (с кастомными логами и фильтром)

```json
"logViewer": {
    "server": true,
    "client": true,
    "serverLogs": [
        "p_rpt",
        "p_adm",
        "p_script",
        "p_console",
        "MyMod/Logs/myModLog.log"
    ],
    "clientLogs": [
        "p_all",
        "error.log"
    ],
    "filter": [
        "myMod",
        "error"
    ]
}
```

---

## Описание полей `logViewer`

| Поле         | Тип           | Значение по умолчанию | Описание                                                    |
|--------------|:-------------:|:---------------------:|-------------------------------------------------------------|
| `server`     | `bool`        | `true`                | Включить мониторинг серверных логов                         |
| `client`     | `bool`        | `true`                | Включить мониторинг клиентских логов                        |
| `serverLogs` | `array`       | `["p_rpt", "p_adm", "p_script", "p_console"]` | Список серверных логов: файлы, wildcard-паттерны или пресеты |
| `clientLogs` | `array`       | `["p_all"]`           | Список клиентских логов: файлы, wildcard-паттерны или пресеты |
| `filter`     | `array`       | `[]`                  | Regex-фильтры: показываются только строки, совпадающие хотя бы с одним паттерном |

> [!NOTE]
> Если `logViewer` отсутствует или `server`/`client` равны `false`, logviewer не запускается автоматически.

---

## Доступные пресеты логов

Можно использовать в `serverLogs` и `clientLogs`:

| Пресет      | Соответствующие файлы                                                   |
|-------------|-------------------------------------------------------------------------|
| `p_rpt`     | `*.RPT`                                                                 |
| `p_adm`     | `*.ADM`                                                                 |
| `p_script`  | `script_*.log`                                                          |
| `p_console` | `serverconsole.log`                                                     |
| `p_all`     | `*.RPT`, `*.ADM`, `script_*.log`, `serverconsole.log`                   |

---

## Пример: как выглядит обновлённый пресет в config.json

До (старая версия):

```json
"serverPresets": {
    "release": {
        "cleanLogs": "all",
        "isExperimental": false,
        "isDiagMode": false,
        "isFilePatching": false,
        "isDisableBE": false,
        "serverPath": "C:/DayZServer",
        "gamePath": "E:/SteamLibrary/steamapps/common/DayZ",
        "serverConfig": "ServerDev.cfg",
        "missionPath": "",
        "serverPort": 2300,
        "profilePath": "C:/DayZServer/profiles",
        "workshop": {
            "steam": "E:/SteamLibrary/steamapps/common/DayZ/!Workshop",
            "local": "C:/PDrive"
        }
    }
}
```

После (с добавленной секцией `logViewer`):

```json
"serverPresets": {
    "release": {
        "cleanLogs": "all",
        "isExperimental": false,
        "isDiagMode": false,
        "isFilePatching": false,
        "isDisableBE": false,
        "serverPath": "C:/DayZServer",
        "gamePath": "E:/SteamLibrary/steamapps/common/DayZ",
        "serverConfig": "ServerDev.cfg",
        "missionPath": "",
        "serverPort": 2300,
        "profilePath": "C:/DayZServer/profiles",
        "workshop": {
            "steam": "E:/SteamLibrary/steamapps/common/DayZ/!Workshop",
            "local": "C:/PDrive"
        },
        "logViewer": {
            "server": true,
            "client": true,
            "serverLogs": [
                "p_rpt",
                "p_adm",
                "p_script",
                "p_console"
            ],
            "clientLogs": [
                "p_all"
            ],
            "filter": []
        }
    }
}
```

> [!IMPORTANT]
> Секцию `logViewer` нужно добавить в **каждый** пресет в `serverPresets`, который вы используете.
> Если секция отсутствует — logviewer просто не запустится, ошибок не будет.
