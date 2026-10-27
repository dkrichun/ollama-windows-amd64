#Requires -Version 5.1
<#
.SYNOPSIS
    Развёртывание Ollama как службы Windows с сетевым доступом.

.DESCRIPTION
    Читает ollama-windows-amd64.ini, скачивает NSSM и Ollama, распаковывает,
    настраивает Machine-переменные (OLLAMA_HOST/OLLAMA_MODELS), явно задаёт
    USERPROFILE/HOME для службы, читает секцию [performance] и передаёт все
    параметры через AppEnvironmentExtra, настраивает брандмауэр, ротацию логов
    NSSM и политику восстановления, регистрирует службу, запускает и проверяет
    API с повторами.

.PARAMETER ConfigPath
    Путь к INI. По умолчанию — рядом со скриптом.

.PARAMETER Force
    Не задавать интерактивных вопросов.

.PARAMETER NoPause
    Не ждать Enter в конце (для Планировщика/CI).

.EXAMPLE
    .\ollama-windows-amd64.ps1

.EXAMPLE
    .\ollama-windows-amd64.ps1 -Force -NoPause
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

# ─── 0. Путь к INI и самоповышение прав ───
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDir 'ollama-windows-amd64.ini'
}
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запрос прав администратора (UAC)...' -ForegroundColor Yellow
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConfigPath `"$ConfigPath`""
    if ($Force)   { $argLine += ' -Force'   }
    if ($NoPause) { $argLine += ' -NoPause' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine
    exit
}

# ─── 1. Парсер INI ───
function Read-IniFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Не найден INI: $Path" }
    $data = @{}
    $section = ''
    foreach ($raw in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $raw.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line[0] -eq ';' -or $line[0] -eq '#') { continue }
        if ($line -match '^\[(.+?)\]$') {
            $section = $matches[1].Trim()
            if (-not $data.ContainsKey($section)) { $data[$section] = @{} }
            continue
        }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()
        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
            ($val.StartsWith("'") -and $val.EndsWith("'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        if (-not $data.ContainsKey($section)) { $data[$section] = @{} }
        $data[$section][$key] = $val
    }
    return $data
}

$cfg = Read-IniFile -Path $ConfigPath

function Get-Cfg {
    param([string]$Section, [string]$Key, [string]$Default = '')
    if ($cfg.ContainsKey($Section) -and $cfg[$Section].ContainsKey($Key)) {
        $v = $cfg[$Section][$Key]
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return $Default
}
function Get-CfgBool {
    param([string]$Section, [string]$Key, [bool]$Default = $false)
    $v = Get-Cfg $Section $Key ''
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return ($v -match '^(true|1|yes|y|on)$')
}
function Get-CfgInt {
    param([string]$Section, [string]$Key, [int]$Default = 0)
    $v = Get-Cfg $Section $Key ''
    $n = 0
    if ([int]::TryParse($v, [ref]$n)) { return $n }
    return $Default
}

# ─── 2. Конфигурация ───
$OllamaDir       = Get-Cfg     'paths'     'OllamaDir'            'D:\AI\Ollama'
$ModelsDir       = Get-Cfg     'paths'     'ModelsDir'            'D:\AI\Models'
$NssmDir         = Get-Cfg     'paths'     'NssmDir'              'C:\Program Files\NSSM'
$LogsDir         = Get-Cfg     'paths'     'LogsDir'              ''
$OllamaHome      = Get-Cfg     'ollama'    'OllamaHome'           $OllamaDir
$ServiceName     = Get-Cfg     'service'   'ServiceName'          'Ollama'
$StartType       = Get-Cfg     'service'   'StartType'            'SERVICE_DELAYED_AUTO_START'
$StartTimeoutSec = Get-CfgInt  'service'   'StartTimeoutSeconds'  45
$AppRestartDelay = Get-CfgInt  'service'   'AppRestartDelay'      10000
$HostOnly        = Get-Cfg     'network'   'Host'                 '0.0.0.0'
$Port            = Get-CfgInt  'network'   'Port'                 11434
$FirewallEnabled = Get-CfgBool 'network'   'FirewallEnabled'      $true
$FirewallSubnet  = Get-Cfg     'network'   'FirewallSubnet'       ''
$Origins         = Get-Cfg     'network'   'Origins'              ''
$NssmUrl         = Get-Cfg     'downloads' 'NssmUrl'              'https://github.com/dkxce/NSSM/releases/download/v2.25/NSSM_v2.25.zip'
$OllamaUrl       = Get-Cfg     'downloads' 'OllamaUrl'            'https://github.com/ollama/ollama/releases/download/v0.40.1/ollama-windows-amd64.zip'

# ─── Параметры производительности ───
$KeepAlive       = Get-Cfg     'performance' 'KeepAlive'          '10m'
$FlashAttention  = Get-CfgBool 'performance' 'FlashAttention'     $true
$KvCacheType     = Get-Cfg     'performance' 'KvCacheType'        'q8_0'
$NumParallel     = Get-CfgInt  'performance' 'NumParallel'        1
$MaxLoadedModels = Get-CfgInt  'performance' 'MaxLoadedModels'    1
$DebugMode       = Get-CfgBool 'performance' 'Debug'              $false

if ([string]::IsNullOrWhiteSpace($LogsDir))    { $LogsDir    = Join-Path $OllamaDir 'logs' }
if ([string]::IsNullOrWhiteSpace($OllamaHome)) { $OllamaHome = $OllamaDir }
$OllamaHost  = "${HostOnly}:${Port}"
$NewProfile  = Join-Path $OllamaHome '.ollama'
$OldProfile  = 'C:\Windows\System32\config\systemprofile\.ollama'

# Валидация FlashAttention ↔ KvCacheType
$faValue = if ($FlashAttention) { '1' } else { '0' }
if ($KvCacheType -ne 'f16' -and -not $FlashAttention) {
    Write-Warning "KvCacheType=$KvCacheType требует FlashAttention=1. Принудительно включаем Flash Attention."
    $faValue = '1'
}
if ($KvCacheType -notin @('f16','q8_0','q4_0')) {
    Write-Warning "Неизвестный KvCacheType='$KvCacheType'. Допустимые: f16, q8_0, q4_0. Оставляем как есть."
}

# Формируем блок переменных для AppEnvironmentExtra (все в одном вызове!)
$envPairs = @(
    "USERPROFILE=$OllamaHome",
    "HOME=$OllamaHome",
    "OLLAMA_HOST=$OllamaHost",
    "OLLAMA_MODELS=$ModelsDir",
    "OLLAMA_KEEP_ALIVE=$KeepAlive",
    "OLLAMA_FLASH_ATTENTION=$faValue",
    "OLLAMA_KV_CACHE_TYPE=$KvCacheType",
    "OLLAMA_NUM_PARALLEL=$NumParallel",
    "OLLAMA_MAX_LOADED_MODELS=$MaxLoadedModels"
)
if (-not [string]::IsNullOrWhiteSpace($Origins)) {
    $envPairs += "OLLAMA_ORIGINS=$Origins"
}
if ($DebugMode) {
    $envPairs += "OLLAMA_DEBUG=1"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Download-File([string]$Url, [string]$Dest) {
    Write-Host "  → $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
}

try {
    # ─── 3. Остановка существующей службы (до проверки порта) ───
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Step "Остановка существующей службы $ServiceName"
        & sc.exe stop $ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    }

    # ─── 4. Проверка порта ───
    Write-Step "Проверка порта $Port"
    $busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($busy) {
        $pids = ($busy.OwningProcess | Sort-Object -Unique) -join ', '
        Write-Warning "Порт $Port уже занят PID: $pids"
        if (-not $Force) {
            $ans = Read-Host 'Продолжить? [y/N]'
            if ($ans -ne 'y') { throw 'Отменено пользователем' }
        } else {
            Write-Host '  (Force — продолжаем)'
        }
    } else {
        Write-Host '  ✓ Свободен'
    }

    # ─── 5. Каталоги ───
    Write-Step 'Создание каталогов'
    foreach ($d in @($OllamaDir, $ModelsDir, $LogsDir, $NssmDir, $OllamaHome, $NewProfile)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Write-Host "  ✓ $d"
    }

    # ─── 6. ACL: LocalSystem должен писать в профиль и модели ───
    Write-Step 'Права доступа для LocalSystem'
    icacls $OllamaHome /grant 'SYSTEM:(OI)(CI)F' | Out-Null
    icacls $ModelsDir  /grant 'SYSTEM:(OI)(CI)F' | Out-Null
    icacls $NewProfile /grant 'SYSTEM:(OI)(CI)F' /T | Out-Null
    Write-Host "  ✓ SYSTEM: Full Control на $OllamaHome, $ModelsDir, $NewProfile"

    # ─── 7. NSSM ───
    Write-Step "Установка NSSM в $NssmDir"
    $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\win64\\' } |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $nssmExe) {
        $nssmZip = Join-Path $env:TEMP 'NSSM.zip'
        Download-File $NssmUrl $nssmZip
        Expand-Archive -Path $nssmZip -DestinationPath $NssmDir -Force
        Remove-Item $nssmZip -Force -ErrorAction SilentlyContinue
        $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse |
            Where-Object { $_.FullName -match '\\win64\\' } |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $nssmExe) {
            $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse |
                Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $nssmExe) { throw "nssm.exe не найден после распаковки в $NssmDir" }
    }
    Write-Host "  ✓ $nssmExe"

    # ─── 8. Ollama ───
    Write-Step "Установка Ollama в $OllamaDir"
    $ollamaExe = Join-Path $OllamaDir 'ollama.exe'
    if (-not (Test-Path $ollamaExe)) {
        $ollamaZip = Join-Path $env:TEMP 'ollama-windows-amd64.zip'
        Download-File $OllamaUrl $ollamaZip
        Expand-Archive -Path $ollamaZip -DestinationPath $OllamaDir -Force
        Remove-Item $ollamaZip -Force -ErrorAction SilentlyContinue
    }
    $ver = (& $ollamaExe --version 2>&1) -join ' '
    if ($LASTEXITCODE -ne 0) {
        throw "ollama.exe --version завершился с кодом $LASTEXITCODE. Проверьте зависимости (VC++ Runtime) и целостность архива."
    }
    Write-Host "  ✓ $ver"

    # ─── 9. Machine-переменные (для ручных запусков из консоли) ───
    Write-Step 'Переменные окружения (Machine)'
    [Environment]::SetEnvironmentVariable('OLLAMA_HOST',   $OllamaHost, 'Machine')
    [Environment]::SetEnvironmentVariable('OLLAMA_MODELS', $ModelsDir,  'Machine')
    Write-Host "  ✓ OLLAMA_HOST=$OllamaHost"
    Write-Host "  ✓ OLLAMA_MODELS=$ModelsDir"
    Write-Host "  ℹ Для применения к службе параметры ниже передаются через AppEnvironmentExtra."

    # ─── 10. Брандмауэр ───
    if ($FirewallEnabled -and -not [string]::IsNullOrWhiteSpace($FirewallSubnet)) {
        Write-Step "Правило брандмауэра ($FirewallSubnet)"
        $ruleName = "Ollama API ($FirewallSubnet)"
        Get-NetFirewallRule -DisplayName "Ollama API*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $ruleName `
            -Direction Inbound -Protocol TCP -LocalPort $Port `
            -RemoteAddress $FirewallSubnet -Action Allow -Profile Any | Out-Null
        Write-Host "  ✓ $ruleName"
    } else {
        Write-Host "`n  ⚠ Правило брандмауэра не создано" -ForegroundColor Yellow
    }

    # ─── 11. Миграция старого профиля ───
    if ((Test-Path $OldProfile) -and -not (Test-Path (Join-Path $NewProfile 'id_ed25519'))) {
        Write-Step "Миграция профиля из $OldProfile"
        Copy-Item -Path "$OldProfile\*" -Destination $NewProfile -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  ✓ Скопировано в $NewProfile"
        Write-Host "  ⚠ Старую папку не удаляем — проверьте и удалите вручную"
    } else {
        Write-Host "`n  ℹ Миграция профиля не требуется"
    }

    # ─── 12. Регистрация службы ───
    Write-Step "Регистрация службы $ServiceName"
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Host '  → Удаление существующей службы'
        & $nssmExe stop   $ServiceName         2>&1 | Out-Null
        Start-Sleep -Seconds 1
        & $nssmExe remove $ServiceName confirm 2>&1 | Out-Null
        Start-Sleep -Seconds 1
    }
    & $nssmExe install $ServiceName $ollamaExe serve                           2>&1 | Out-Null
    & $nssmExe set $ServiceName AppDirectory $OllamaDir                        2>&1 | Out-Null
    & $nssmExe set $ServiceName Start $StartType                               2>&1 | Out-Null

    # Единый вызов AppEnvironmentExtra со всеми переменными, включая performance
    & $nssmExe set $ServiceName AppEnvironmentExtra @envPairs 2>&1 | Out-Null

    # Логи и ротация
    & $nssmExe set $ServiceName AppStdout (Join-Path $LogsDir 'ollama.out.log') 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStderr (Join-Path $LogsDir 'ollama.err.log') 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateFiles 1                               2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateOnline 1                              2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateBytes 10485760                         2>&1 | Out-Null  # 10 MB

    # Политика перезапуска при падении
    & $nssmExe set $ServiceName AppExit Default Restart                        2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRestartDelay $AppRestartDelay               2>&1 | Out-Null
    & $nssmExe set $ServiceName AppThrottle 1500                              2>&1 | Out-Null

    Write-Host '  ✓ Служба сконфигурирована (включая performance и ротацию логов)'

    # ─── 13. Запуск ───
    Write-Step 'Запуск службы'
    & $nssmExe start $ServiceName 2>&1 | Out-Null
    $svc = Get-Service -Name $ServiceName
    $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds($StartTimeoutSec))
    Write-Host "  ✓ Статус: $($svc.Status)"

    # ─── 14. Проверка API (с повторами) ───
    Write-Step 'Проверка API (локально)'
    $maxAttempts = 15
    $ok = $false
    for ($i = 1; $i -le $maxAttempts; $i++) {
        Start-Sleep -Seconds 2
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/tags" -TimeoutSec 5 | Out-Null
            $ok = $true
            Write-Host "  ✓ Попытка ${i}: API отвечает"
            break
        } catch {
            Write-Host "  … Попытка ${i}/${maxAttempts}: $($_.Exception.Message)"
        }
    }
    if (-not $ok) {
        Write-Warning "API не ответил за $($maxAttempts * 2) секунд."
        Write-Warning "Проверьте: $(Join-Path $LogsDir 'ollama.err.log')"
        if (-not $Force) {
            $ans = Read-Host 'Продолжить завершение? [y/N]'
            if ($ans -ne 'y') { throw 'Прервано пользователем' }
        }
    }

    # ─── Итог ───
    Write-Host "`n=============================" -ForegroundColor Green
    Write-Host ' Развёртывание завершено'     -ForegroundColor Green
    Write-Host '=============================' -ForegroundColor Green
    Write-Host " Служба      : $ServiceName"
    Write-Host " Бинарник    : $ollamaExe"
    Write-Host " Модели      : $ModelsDir"
    Write-Host " Профиль     : $NewProfile"
    Write-Host " Логи        : $LogsDir"
    Write-Host " API локально: http://127.0.0.1:$Port"
    Write-Host " Performance : KeepAlive=$KeepAlive, FlashAttention=$faValue, KvCache=$KvCacheType, Parallel=$NumParallel, MaxModels=$MaxLoadedModels"
    if ($FirewallEnabled -and -not [string]::IsNullOrWhiteSpace($FirewallSubnet)) {
        Write-Host " API по сети : http://<IP-сервера>:$Port ($FirewallSubnet)"
    }
}
catch {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
    exit 1
}

if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }