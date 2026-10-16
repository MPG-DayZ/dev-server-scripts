#requires -Version 5.1
<#
.SYNOPSIS
    Патчер DayZServer_x64.exe — создаёт NoBe-версию с отключённым BattlEye.

.DESCRIPTION
    Создаёт копию exe с именем *_NoBe.exe, в которой:
      - инициализация BattlEye всегда возвращает успех (BE dll не грузится)
      - проверка VAC-бана пропускается (jz -> jmp)
      - заголовок консоли помечается как патченный
    Оригинальный файл никогда не изменяется. Только для локальной разработки модов.

    Поиск функций семантический (порт unmerged C++ PR #12 из JonathanEke/DayZ-Server-Battleye-Remover):
      - поиск строки "BattlEye\BEServer_x64.dll" в образе
      - скан исполняемых секций на RIP-relative lea-ссылки на неё
      - определение границ функции через .pdata (x64 exception directory)
    Сигнатуры байтов — fallback. Якоря — строковые литералы, а не прологи компилятора,
    поэтому патчер обычно переживает обновления игры без изменений.

    Порт standalone-патчера DayZServer-BERemover.ps1 (сессия sess_918d24c9).

.PARAMETER SourceExePath
    Путь к оригинальному DayZServer_x64.exe.

.PARAMETER OutputPath
    Путь результата. По умолчанию — соседний *_NoBe.exe.

.PARAMETER Check
    Только анализ, ничего не записывать.

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\nobe.ps1 -SourceExePath "E:/DayZServer/DayZServer_x64.exe" -Check
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceExePath,

    [string]$OutputPath = "",

    [switch]$Check,

    [string]$lang = "",

    [string]$configPath = ""
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$customConfigPath = ""
if ($configPath -ne "") {
    if (-not [System.IO.Path]::IsPathRooted($configPath)) {
        $configPath = Join-Path $scriptDir $configPath
    }
    $customConfigPath = $configPath
}

. (Join-Path $scriptDir "config.ps1")

if ($lang -ne "") {
    Set-CurrentLanguage $lang
}

# ------------------------------------------------------------------ helpers

# Локализованное сообщение с префиксом [NOBE]
function Write-NoBe([string]$Msg, [string]$ForegroundColor = "White", [array]$FormatArgs = @()) {
    Write-ColorOutput $Msg -ForegroundColor $ForegroundColor -Prefix "prefixes.nobe" -FormatArgs $FormatArgs
}

# Техническая диагностика (смещения, количество вхождений) — для отчётов о багах,
# локализации не подлежит
function Write-Diag([string]$Msg) {
    Write-Host "  $Msg" -ForegroundColor DarkGray
}

function Read-U16([byte[]]$B, [int]$O) { [BitConverter]::ToUInt16($B, $O) }
function Read-U32([byte[]]$B, [int]$O) { [BitConverter]::ToUInt32($B, $O) }
function Read-I32([byte[]]$B, [int]$O) { [BitConverter]::ToInt32($B, $O) }

function Read-AsciiZ([byte[]]$B, [int]$O) {
    $end = $O
    while ($B[$end] -ne 0) { $end++ }
    [Text.Encoding]::ASCII.GetString($B, $O, $end - $O)
}

function ConvertTo-Hex([string]$Ascii) {
    [BitConverter]::ToString([Text.Encoding]::ASCII.GetBytes($Ascii)).Replace('-', '')
}

function ConvertTo-Pattern([string]$Sig) {
    ($Sig -split '\s+' | ForEach-Object {
        if ($_ -match '^\?+$') { '..' } else { $_.ToUpperInvariant() }
    }) -join ''
}

# Все поиск байтовых паттернов идут через предпостроенную hex-строку файла:
# один regex-движок, wildcards и литеральные строки используют один путь
function Find-HexOffsets([string]$Hex, [string]$Pattern) {
    $out = New-Object System.Collections.Generic.List[object]
    $rx = New-Object System.Text.RegularExpressions.Regex($Pattern)
    foreach ($m in $rx.Matches($Hex)) {
        if (($m.Index -band 1) -eq 0) { $out.Add([int]($m.Index / 2)) }  # skip mid-byte hits
    }
    return ,$out
}

# ------------------------------------------------------------------ PE

function Read-PEImage([byte[]]$B) {
    if ((Read-U16 $B 0) -ne 0x5A4D) { throw 'Not an MZ executable' }
    $peOff = [int](Read-U32 $B 0x3C)
    if ((Read-U32 $B $peOff) -ne 0x00004550) { throw 'PE signature not found' }
    $coff = $peOff + 4
    $machine = Read-U16 $B $coff
    if ($machine -ne 0x8664) { throw ('Only x64 PE supported (machine=0x{0:X4})' -f $machine) }
    $numSections = Read-U16 $B ($coff + 2)
    $sizeOpt = Read-U16 $B ($coff + 16)
    $opt = $coff + 20
    if ((Read-U16 $B $opt) -ne 0x020B) { throw 'Not PE32+ (x64 optional header expected)' }

    $sizeOfHeaders = Read-U32 $B ($opt + 60)
    $numDirs = Read-U32 $B ($opt + 108)
    $impRva = 0; $impSize = 0; $excRva = 0; $excSize = 0
    if ($numDirs -ge 2) { $impRva = Read-U32 $B ($opt + 120); $impSize = Read-U32 $B ($opt + 124) }
    if ($numDirs -ge 5) { $excRva = Read-U32 $B ($opt + 144); $excSize = Read-U32 $B ($opt + 148) }

    $sections = @()
    $secOff = $opt + $sizeOpt
    for ($i = 0; $i -lt $numSections; $i++) {
        $o = $secOff + $i * 40
        $sections += [pscustomobject]@{
            Name    = [Text.Encoding]::ASCII.GetString($B, $o, 8).TrimEnd([char]0)
            Va      = [int](Read-U32 $B ($o + 12))
            VSize   = [int](Read-U32 $B ($o + 8))
            RawPtr  = [int](Read-U32 $B ($o + 20))
            RawSize = [int](Read-U32 $B ($o + 16))
            Exec    = ((Read-U32 $B ($o + 36)) -band 0x20000000) -ne 0
        }
    }

    [pscustomobject]@{
        SizeOfHeaders = $sizeOfHeaders
        Sections      = $sections
        ImpRva        = $impRva
        ImpSize       = $impSize
        ExcRva        = $excRva
        ExcSize       = $excSize
    }
}

function Get-FileOffset([int]$Rva) {
    if ($Rva -lt $script:Pe.SizeOfHeaders) { return $Rva }
    foreach ($s in $script:Pe.Sections) {
        $size = [Math]::Max($s.VSize, $s.RawSize)
        if ($Rva -ge $s.Va -and $Rva -lt ($s.Va + $size)) {
            $delta = $Rva - $s.Va
            if ($delta -ge $s.RawSize) { return -1 }   # lives in virtual padding, no file bytes
            return $s.RawPtr + $delta
        }
    }
    return -1
}

function Get-RvaFromOffset([int]$Off) {
    if ($Off -lt $script:Pe.SizeOfHeaders) { return $Off }
    foreach ($s in $script:Pe.Sections) {
        if ($Off -ge $s.RawPtr -and $Off -lt ($s.RawPtr + $s.RawSize)) {
            return $s.Va + ($Off - $s.RawPtr)
        }
    }
    return -1
}

# name -> IAT slot RVA (FirstThunk entry), which `call [rip+disp]` resolves to
function Get-ImportTable {
    $map = @{}
    if ($script:Pe.ImpRva -eq 0) { return $map }
    $desc = Get-FileOffset $script:Pe.ImpRva
    if ($desc -lt 0) { return $map }
    while ($true) {
        $oft = Read-U32 $script:Bytes $desc
        $nameRva = Read-U32 $script:Bytes ($desc + 12)
        $ft = Read-U32 $script:Bytes ($desc + 16)
        if ($oft -eq 0 -and $ft -eq 0 -and $nameRva -eq 0) { break }
        $lookup = $oft; if ($lookup -eq 0) { $lookup = $ft }
        $tOff = Get-FileOffset $lookup
        $slot = $ft
        if ($tOff -ge 0) {
            while ($true) {
                $thunk = [BitConverter]::ToUInt64($script:Bytes, $tOff)
                if ($thunk -eq 0) { break }
                if (($thunk -band 0x8000000000000000) -eq 0) {
                    $nOff = Get-FileOffset ([int]($thunk -band 0xFFFFFFFF))
                    if ($nOff -ge 0) { $map[(Read-AsciiZ $script:Bytes ($nOff + 2))] = $slot }
                }
                $tOff += 8; $slot += 8
            }
        }
        $desc += 20
    }
    return $map
}

# .pdata: sorted array of RUNTIME_FUNCTION {u32 Begin, u32 End, u32 Unwind}
# DayZ 1.30 ships a bogus table (begin > end), so validity is checked before use
function Test-PdataValid {
    $count = [int]($script:Pe.ExcSize / 12)
    if ($count -lt 64) { return $false }
    $off = Get-FileOffset $script:Pe.ExcRva
    if ($off -lt 0) { return $false }
    $bad = 0
    for ($i = 0; $i -lt $count; $i++) {
        if ((Read-U32 $script:Bytes ($off + $i * 12)) -ge (Read-U32 $script:Bytes ($off + $i * 12 + 4))) { $bad++ }
    }
    return ($bad * 10 -lt $count)
}

function Find-FunctionByRva([int]$Rva) {
    if (-not $script:PdataOk) { return $null }
    $count = [int]($script:Pe.ExcSize / 12)
    if ($count -le 0) { return $null }
    $off = Get-FileOffset $script:Pe.ExcRva
    if ($off -lt 0) { return $null }
    for ($i = 0; $i -lt $count; $i++) {
        $begin = Read-U32 $script:Bytes ($off + $i * 12)
        if ($begin -gt $Rva) { break }                       # entries are sorted
        $end = Read-U32 $script:Bytes ($off + $i * 12 + 4)
        if ($Rva -lt $end) { return @{ Begin = $begin; End = $end } }
    }
    return $null
}

# Fallback when .pdata is unusable: MSVC separates functions with int3 (CC CC)
# padding, so the nearest CC-run backwards marks the function start
function Find-FunctionBoundsByCC([int]$Off) {
    $limit = [Math]::Max(1, $Off - 0x8000)
    $i = $Off - 1
    while ($i -gt $limit) {
        if ($script:Bytes[$i] -eq 0xCC -and $script:Bytes[$i - 1] -eq 0xCC) { break }
        $i--
    }
    if ($i -le $limit) { return $null }
    $begin = $i
    while ($script:Bytes[$begin] -eq 0xCC) { $begin++ }
    $end = $Off
    $flimit = [Math]::Min($script:Bytes.Length - 2, $Off + 0x20000)
    while ($end -lt $flimit) {
        if ($script:Bytes[$end] -eq 0xCC -and $script:Bytes[$end + 1] -eq 0xCC) { break }
        $end++
    }
    return @{ BeginOff = $begin; EndOff = $end }
}

function Test-Prologue([int]$Off) {
    $b = $script:Bytes[$Off]
    if ($b -eq 0xB0 -and $script:Bytes[$Off + 1] -eq 0x01 -and $script:Bytes[$Off + 2] -eq 0xC3) { return $true }  # already-patched marker
    return (($b -band 0xF0) -eq 0x40) -or ($b -ge 0x50 -and $b -le 0x57)
}

# enclosing function of a file offset; .pdata first, CC-boundary scan as fallback
function Get-EnclosingFunction([int]$Off) {
    $rva = Get-RvaFromOffset $Off
    if ($rva -ge 0) {
        $fn = Find-FunctionByRva $rva
        if ($fn) {
            $b = Get-FileOffset $fn.Begin
            $e = Get-FileOffset $fn.End
            if ($b -ge 0 -and $e -gt $b) { return @{ BeginOff = $b; EndOff = $e; How = 'pdata' } }
        }
    }
    $fn = Find-FunctionBoundsByCC $Off
    if ($fn -and (Test-Prologue $fn.BeginOff)) { return @{ BeginOff = $fn.BeginOff; EndOff = $fn.EndOff; How = 'cc-scan' } }
    return $null
}

# RIP-relative `lea reg, [rip+disp]`: REX(4?) 8D modrm(mod=00,rm=101) disp32
function Get-LeaXrefs([int[]]$NeedleRvas) {
    $want = @{}
    foreach ($r in $NeedleRvas) { $want[$r] = $true }
    $hits = New-Object System.Collections.Generic.List[object]
    $rx = New-Object System.Text.RegularExpressions.Regex('4[0-9A-F]8D[0-7]5[0-9A-F]{8}')
    $lastSec = $null
    foreach ($m in $rx.Matches($script:Hex)) {
        if (($m.Index -band 1) -ne 0) { continue }
        $off = [int]($m.Index / 2)
        if ($lastSec -and $off -ge $lastSec.RawPtr -and $off -lt ($lastSec.RawPtr + $lastSec.RawSize)) {
            $rva = $lastSec.Va + ($off - $lastSec.RawPtr)
        }
        else {
            $rva = Get-RvaFromOffset $off
            if ($rva -lt 0) { continue }
            foreach ($s in $script:Pe.Sections) {
                if ($rva -ge $s.Va -and $rva -lt ($s.Va + [Math]::Max($s.VSize, $s.RawSize))) { $lastSec = $s; break }
            }
        }
        $disp = Read-I32 $script:Bytes ($off + 3)
        $target = $rva + 7 + $disp
        if ($want.ContainsKey($target)) {
            $hits.Add([pscustomobject]@{ Off = $off; InsnRva = $rva; Target = $target })
        }
    }
    return ,$hits
}

# ------------------------------------------------------------------ patch targets

$script:InitSigs = @(
    '40 53 55 56 57 41 54 48 81 EC ?? ?? ?? ?? 45 33 E4 48 8B D9 44 89'
    '48 89 5C 24 ?? 48 89 6C 24 ?? 56 57 41 56 48 81 EC ?? ?? ?? ?? 45 33 F6 48 8B D9 44 89'
    '40 53 55 56 57 41 54 48 81 EC ?? ?? ?? ?? 45 33'   # short 2026-04 variant, last resort
)
$script:VacSigs = @(
    '74 44 0F B7 C8 E8 ?? ?? ?? ?? 8B 13 44 0F B7 C0 44 89 4C 24 ?? 48'
    '74 5C B8 ?? ?? ?? ?? 66 3B C3 75 09 E8 ?? ?? ?? ?? 84 C0 74 49 0F B7'
)

function Find-BattlEyeInit {
    # strings that mark the BE loading code, broadest last
    $needles = @('BattlEye\BEServer_x64.dll', 'BEServer_x64.dll')
    foreach ($needle in $needles) {
        $offs = Find-HexOffsets $script:Hex (ConvertTo-Hex $needle)
        Write-Diag ("string '{0}': {1} occurrence(s)" -f $needle, $offs.Count)
        if ($offs.Count -eq 0) { continue }
        $rvas = @($offs | ForEach-Object { Get-RvaFromOffset $_ } | Where-Object { $_ -ge 0 })
        $refs = Get-LeaXrefs $rvas
        Write-Diag ("lea xrefs: {0}" -f $refs.Count)
        foreach ($ref in $refs) {
            # BE loader calls through a resolved pointer (call [reg]), not the IAT,
            # so the strongest check available is: the xref sits inside a function
            # with a sane prologue, not too far from the reference
            $fn = Get-EnclosingFunction $ref.Off
            if (-not $fn) { continue }
            $dist = $ref.Off - $fn.BeginOff
            if ($dist -lt 0 -or $dist -gt 0x4000) { continue }
            return @{
                Off    = $fn.BeginOff
                Begin  = (Get-RvaFromOffset $fn.BeginOff)
                Method = "string-xref/$($fn.How), +$dist bytes"
            }
        }
        Write-Diag 'xrefs did not resolve to a usable function'
    }
    foreach ($sig in $script:InitSigs) {
        $offs = Find-HexOffsets $script:Hex (ConvertTo-Pattern $sig)
        if ($offs.Count -gt 0) {
            return @{ Off = [int]$offs[0]; Begin = (Get-RvaFromOffset [int]$offs[0]); Method = 'signature fallback' }
        }
    }
    return $null
}

function Find-VacCheck {
    $needle = 'Cannot start authentication of player dpid %d, reason %s'
    $offs = Find-HexOffsets $script:Hex (ConvertTo-Hex $needle)
    Write-Diag ("string '{0}': {1} occurrence(s)" -f $needle, $offs.Count)
    if ($offs.Count -gt 0) {
        $rvas = @($offs | ForEach-Object { Get-RvaFromOffset $_ } | Where-Object { $_ -ge 0 })
        $refs = Get-LeaXrefs $rvas
        Write-Diag ("lea xrefs: {0}" -f $refs.Count)
        foreach ($ref in $refs) {
            $fn = Get-EnclosingFunction $ref.Off
            if (-not $fn) { continue }
            for ($o = $fn.BeginOff; $o + 2 -le $fn.EndOff; $o++) {
                if ($script:Bytes[$o] -eq 0x74 -and $script:Bytes[$o + 1] -eq 0x44) {
                    return @{ Off = $o; Method = "string-xref/$($fn.How)" }
                }
            }
        }
        Write-Diag 'no `74 44` jz inside referencing functions'
    }
    foreach ($sig in $script:VacSigs) {
        $offs = Find-HexOffsets $script:Hex (ConvertTo-Pattern $sig)
        if ($offs.Count -gt 0) { return @{ Off = [int]$offs[0]; Method = 'signature fallback' } }
    }
    return $null
}

# cosmetic marker in console title; replacement is same length, in place
$titleCandidates = @(
    @{ Find = 'Console version (64bit)'; Repl = 'Patched [BE-off] server' }
    @{ Find = 'Console version';         Repl = 'Patched (no BE)' }
)

# ------------------------------------------------------------------ main

if (-not (Test-Path -LiteralPath $SourceExePath)) {
    Write-ColorOutput "errors.executable_not_found" -ForegroundColor "Red" -Prefix "prefixes.error" -FormatArgs @("server", $SourceExePath)
    exit 1
}

$ExePath = (Resolve-Path -LiteralPath $SourceExePath).Path
$script:Bytes = [IO.File]::ReadAllBytes($ExePath)

try { $script:Pe = Read-PEImage $script:Bytes }
catch {
    Write-ColorOutput "errors.nobe_pe_failed" -ForegroundColor "Red" -Prefix "prefixes.error" -FormatArgs @($_)
    exit 1
}

Write-NoBe "nobe.analyzing" "White" @($script:Bytes.Length)

$script:Hex = ([BitConverter]::ToString($script:Bytes)).Replace('-', '')
$script:Imports = Get-ImportTable
$script:PdataOk = Test-PdataValid
Write-Diag ("PE32+ x64, {0} sections; named imports: {1}; .pdata: {2}" -f `
    $script:Pe.Sections.Count, $script:Imports.Count, $(if ($script:PdataOk) { 'valid' } else { 'invalid, using CC-boundary scan' }))

# результат: соседний *_NoBe.exe; повторный запуск на готовом _NoBe-файле
# не добавляет ещё один суффикс
if (-not $OutputPath) {
    $inName = [IO.Path]::GetFileName($ExePath)
    $inBase = [IO.Path]::GetFileNameWithoutExtension($inName) -replace '_NoBe$', ''
    $inExt  = [IO.Path]::GetExtension($inName)
    $OutputPath = Join-Path ([IO.Path]::GetDirectoryName($ExePath)) ($inBase + '_NoBe' + $inExt)
}

Write-NoBe "nobe.locating_be" "Cyan"
$init = Find-BattlEyeInit
if (-not $init) {
    Write-ColorOutput "errors.nobe_init_not_found" -ForegroundColor "Red" -Prefix "prefixes.error"
    exit 1
}
Write-Diag ("BE init found @ file 0x{0:X} (rva 0x{1:X}), {2}" -f $init.Off, $init.Begin, $init.Method)

if ($script:Bytes[$init.Off] -eq 0xB0 -and $script:Bytes[$init.Off + 1] -eq 0x01 -and $script:Bytes[$init.Off + 2] -eq 0xC3) {
    if ([IO.Path]::GetFullPath($OutputPath) -ieq [IO.Path]::GetFullPath($ExePath)) {
        Write-NoBe "nobe.already_patched" "Green"
    }
    else {
        Copy-Item -LiteralPath $ExePath -Destination $OutputPath -Force
        Write-NoBe "nobe.copied_patched" "Green" @($OutputPath)
    }
    exit 0
}

Write-NoBe "nobe.locating_vac" "Cyan"
$vac = Find-VacCheck
if (-not $vac) {
    Write-ColorOutput "errors.nobe_vac_not_found" -ForegroundColor "Red" -Prefix "prefixes.error"
    exit 1
}
Write-Diag ("VAC check found @ file 0x{0:X}, {1}" -f $vac.Off, $vac.Method)

if ($Check) {
    Write-NoBe "nobe.check_only" "Yellow"
    exit 0
}

if ($script:Bytes[$vac.Off] -ne 0x74) {
    Write-ColorOutput "errors.nobe_vac_byte" -ForegroundColor "Red" -Prefix "prefixes.error" -FormatArgs @($script:Bytes[$vac.Off])
    exit 1
}

# BattlEye init -> mov al,1; ret  (always report success, BE dll never loads)
$script:Bytes[$init.Off]     = 0xB0
$script:Bytes[$init.Off + 1] = 0x01
$script:Bytes[$init.Off + 2] = 0xC3
# VAC check: jz -> jmp (ban branch never taken)
$script:Bytes[$vac.Off] = 0xEB

$titleCount = 0
foreach ($t in $titleCandidates) {
    $offs = Find-HexOffsets $script:Hex (ConvertTo-Hex $t.Find)
    if ($offs.Count -eq 0) { continue }
    $repl = [Text.Encoding]::ASCII.GetBytes($t.Repl)
    foreach ($o in $offs) {
        for ($i = 0; $i -lt $repl.Length; $i++) { $script:Bytes[$o + $i] = $repl[$i] }
        $titleCount++
    }
    break
}
Write-Diag ("console title marked in {0} place(s)" -f $titleCount)

try {
    [IO.File]::WriteAllBytes($OutputPath, $script:Bytes)
}
catch {
    Write-ColorOutput "errors.nobe_write_failed" -ForegroundColor "Red" -Prefix "prefixes.error" -FormatArgs @($OutputPath, $_)
    exit 1
}
Write-NoBe "nobe.created" "Green" @($OutputPath)
exit 0
