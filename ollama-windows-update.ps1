#Requires -Version 5.1
<#
.SYNOPSIS
    Обновление Ollama до выбранной версии с резервным копированием.

.DESCRIPTION
    Читает ollama-windows-amd64.ini, запрашивает список стабильных релизов
    через GitHub API и предлагает интерактивное меню выбора версии
    (по умолчанию — самая свежая).

    Процесс обновления:
      1. Проверка наличия службы и прав администратора.
      2. Остановка службы Ollama.
      3. Создание резервной копии текущего каталога OllamaDir.
      4. Скачивание выбранной версии (с кэшированием, как в основном скрипте).
      5. Распаковка новой версии в OllamaDir.
      6. Восстановление профиля .ollama (если он был внутри OllamaDir).
      7. Запуск службы и проверка API (health-check).
      8. Отчёт об успехе или инструкция по откату.

.PARAMETER ConfigPath
    Путь к INI. По умолчанию — рядом со скриптом.

.PARAMETER Version
    Тег версии для обновления (например, v0.40.12 или 0.40.12).
    Если не указан — запрашивается список и показывается меню.

.PARAMETER Force
    Не задавать интерактивных вопросов (использовать версию из -Version
    или самую свежую, если -Version не указан).

.PARAMETER NoPause
    Не ждать Enter в конце (для Планировщика/CI).

.EXAMPLE
    .\ollama-windows-update.ps1
    # Покажет меню выбора, по умолчанию — последняя версия.

.EXAMPLE
    .\ollama-windows-update.ps1 -Version v0.40.12 -Force -NoPause
    # Без вопросов обновит до v0.40.12.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Version,
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
    if ($Version) { $argLine += " -Version `"$Version`"" }
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
$OllamaDir        = Get-Cfg     'paths'     'OllamaDir'            'D:\AI\Ollama'
$NssmDir          = Get-Cfg     'paths'     'NssmDir'              'C:\Program Files\NSSM'
$OllamaHome       = Get-Cfg     'ollama'    'OllamaHome'           $OllamaDir
$ServiceName      = Get-Cfg     'service'   'ServiceName'          'Ollama'
$StartTimeoutSec  = Get-CfgInt  'service'   'StartTimeoutSeconds'  60
$OllamaUrlFallback = Get-Cfg    'downloads' 'OllamaUrl'            'https://github.com/ollama/ollama/releases/download/v0.40.10/ollama-windows-amd64.zip'
$DownloadCacheDir = Get-Cfg     'downloads' 'DownloadCacheDir'     ''
$KeepDownloads    = Get-CfgBool 'downloads' 'KeepDownloads'        $true
$Port             = Get-CfgInt  'network'   'Port'                 11434

if ([string]::IsNullOrWhiteSpace($OllamaHome)) { $OllamaHome = $OllamaDir }

if ([string]::IsNullOrWhiteSpace($DownloadCacheDir)) {
    $DownloadCacheDir = $scriptDir
} elseif (-not [IO.Path]::IsPathRooted($DownloadCacheDir)) {
    $DownloadCacheDir = Join-Path $scriptDir $DownloadCacheDir
}
$DownloadCacheDir = [IO.Path]::GetFullPath($DownloadCacheDir)
$effectiveCacheDir = if ($KeepDownloads) { $DownloadCacheDir } else { $env:TEMP }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

function Find-Nssm {
    param([string]$Dir)
    $exe = Get-ChildItem -Path $Dir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\win64\\' } |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $exe) {
        $exe = Get-ChildItem -Path $Dir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }
    return $exe
}

function Get-OllamaReleases {
    param([switch]$ForceRefresh)
    $cacheFile = Join-Path $scriptDir '.ollama_releases_cache.json'
    $cacheTtl  = 12 * 60 * 60  # 12 часов

    if (-not $ForceRefresh -and (Test-Path -LiteralPath $cacheFile)) {
        $age = (Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime
        if ($age.TotalSeconds -lt $cacheTtl) {
            try {
                return (Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json)
            } catch { }
        }
    }

    $headers = @{ 'User-Agent' = 'PowerShell-Ollama-Update-Script'; 'Accept' = 'application/vnd.github+json' }
    $apiUrl  = 'https://api.github.com/repos/ollama/ollama/releases?per_page=30'
    try {
        Write-Host '  → Запрос списка релизов с GitHub...'
        $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop
        $releases | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cacheFile -Encoding UTF8
        return $releases
    } catch {
        Write-Warning "  ✗ Не удалось получить список релизов: $($_.Exception.Message)"
        if (Test-Path -LiteralPath $cacheFile) { return (Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json) }
        return $null
    }
}

function Test-IsPrerelease {
    param($Release)
    return ($Release.prerelease -or $Release.tag_name -match '-(rc|beta|alpha)')
}

function Select-OllamaVersionInteractive {
    param($Releases)
    if (-not $Releases) { return $null }

    $stable = @($Releases | Where-Object { -not (Test-IsPrerelease $_) })
    if ($stable.Count -eq 0) { return $null }

    $showCount = [math]::Min(15, $stable.Count)
    $list = $stable[0..($showCount-1)]

    Write-Host ''
    Write-Host 'Доступные стабильные версии Ollama (с GitHub):' -ForegroundColor Cyan
    for ($i = 0; $i -lt $list.Count; $i++) {
        $r     = $list[$i]
        $tag   = $r.tag_name
        $date  = ([datetime]$r.published_at).ToString('yyyy-MM-dd')
        $mark  = if ($i -eq 0) { '<-- latest' } else { '' }
        Write-Host ('  [{0}] {1,-16} {2}  {3}' -f ($i+1), $tag, $date, $mark)
    }
    Write-Host ''
    Write-Host 'Введите номер версии (Enter — последняя стабильная, s — отмена):' -ForegroundColor Cyan
    $ans = Read-Host 'Выбор'
    if ([string]::IsNullOrWhiteSpace($ans)) { return $list[0].tag_name }
    if ($ans -eq 's') { return $null }

    $n = 0
    if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) {
        return $list[$n-1].tag_name
    }
    Write-Warning '  Неверный номер, выбираем последнюю стабильную.'
    return $list[0].tag_name
}

function Get-CachedFile {
    param([string]$Url, [string]$FileName, [switch]$ForceRedownload)
    $cachePath = Join-Path $effectiveCacheDir $FileName
    $urlStamp  = "$cachePath.url"

    if ($KeepDownloads -and -not $ForceRedownload) {
        if ((Test-Path -LiteralPath $cachePath) -and (Test-Path -LiteralPath $urlStamp)) {
            $cachedUrl = ''
            try { $cachedUrl = (Get-Content -LiteralPath $urlStamp -Raw).Trim() } catch { }
            if ($cachedUrl -eq $Url) {
                Write-Host "  ✓ Кэш: $cachePath"
                return $cachePath
            }
        }
    }

    if (Test-Path -LiteralPath $cachePath) { Remove-Item -LiteralPath $cachePath -Force }
    if (Test-Path -LiteralPath $urlStamp)  { Remove-Item -LiteralPath $urlStamp  -Force }

    Write-Host "  → Скачивание: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $cachePath -UseBasicParsing
    if ($KeepDownloads) { Set-Content -LiteralPath $urlStamp -Value $Url -NoNewline }
    return $cachePath
}

# ─── Основной сценарий обновления ───
try {
    # 1. Проверка службы и текущей версии
    Write-Step "Проверка текущей установки"
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        throw "Служба $ServiceName не найдена. Сначала запустите ollama-windows-amd64.ps1."
    }
    if (-not (Test-Path $OllamaDir)) {
        throw "Каталог $OllamaDir не найден. Проверьте настройки в INI."
    }
    
    $currentExe = Join-Path $OllamaDir 'ollama.exe'
    if (Test-Path $currentExe) {
        $currentVer = (& $currentExe --version 2>&1) -join ' '
        Write-Host "  Текущая версия: $currentVer" -ForegroundColor Green
    } else {
        Write-Host "  ollama.exe не найден в $OllamaDir (установка повреждена?)" -ForegroundColor Yellow
    }

    # 2. Выбор версии
    $targetVersion = $Version
    if ([string]::IsNullOrWhiteSpace($targetVersion) -or ($targetVersion -eq 'ask')) {
        if ($Force) {
            $releases = Get-OllamaReleases
            if ($releases) {
                $targetVersion = (@($releases | Where-Object { -not (Test-IsPrerelease $_) }) | Select-Object -First 1).tag_name
            } else {
                Write-Warning "  GitHub API недоступен, используем резервный URL."
                $targetVersion = ($OllamaUrlFallback -split '/')[-3]
            }
        } else {
            $releases = Get-OllamaReleases
            if ($releases) {
                $targetVersion = Select-OllamaVersionInteractive -Releases $releases
                if (-not $targetVersion) { throw 'Обновление отменено пользователем.' }
            } else {
                Write-Warning "  GitHub API недоступен. Продолжить с версией из INI (OllamaUrl)?"
                if (-not (Read-Host 'Продолжить? [y/N]') -eq 'y') { throw 'Отменено.' }
                $targetVersion = ($OllamaUrlFallback -split '/')[-3]
            }
        }
    }

    # Нормализация версии
    if ($targetVersion -notmatch '^v') { $targetVersion = "v$targetVersion" }
    $downloadUrl = "https://github.com/ollama/ollama/releases/download/$targetVersion/ollama-windows-amd64.zip"
    
    Write-Host "`n  Планируется обновление до: $targetVersion" -ForegroundColor Cyan
    if (-not $Force) {
        $ans = Read-Host 'Начать обновление? [Y/n]'
        if ($ans -eq 'n' -or $ans -eq 'N') { throw 'Отменено пользователем.' }
    }

    # 3. Поиск NSSM и остановка службы
    Write-Step "Остановка службы $ServiceName"
    $nssmExe = Find-Nssm -Dir $NssmDir
    if ($svc.Status -eq 'Running') {
        if ($nssmExe) {
            & $nssmExe stop $ServiceName 2>&1 | Out-Null
        } else {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        }
        
        # Ждем остановки
        $timeout = 15
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ((Get-Service $ServiceName).Status -ne 'Stopped' -and $sw.Elapsed.TotalSeconds -lt $timeout) {
            Start-Sleep -Milliseconds 500
        }
        
        if ((Get-Service $ServiceName).Status -ne 'Stopped') {
            Write-Warning "  Служба не остановилась за $timeout секунд. Принудительная остановка..."
            Stop-Service -Name $ServiceName -Force
            Start-Sleep -Seconds 2
        }
        Write-Host "  ✓ Служба остановлена" -ForegroundColor Green
    } else {
        Write-Host "  ℹ Служба уже остановлена" -ForegroundColor DarkGray
    }

    # 4. Резервное копирование
    Write-Step "Создание резервной копии"
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupDir = Join-Path (Split-Path $OllamaDir -Parent) "$(Split-Path $OllamaDir -Leaf)_backup_$timestamp"
    
    Write-Host "  → Перемещение $OllamaDir в $backupDir"
    try {
        Rename-Item -Path $OllamaDir -NewName (Split-Path $backupDir -Leaf) -ErrorAction Stop
        Write-Host "  ✓ Резервная копия создана" -ForegroundColor Green
    } catch {
        throw "Не удалось создать резервную копию (файлы заняты?). Убедитесь, что служба остановлена. Ошибка: $_"
    }

    # 5. Скачивание и распаковка
    Write-Step "Установка новой версии"
    New-Item -ItemType Directory -Path $OllamaDir -Force | Out-Null
    
    $zipName = "ollama-$targetVersion.zip"
    $zipPath = Get-CachedFile -Url $downloadUrl -FileName $zipName -ForceRedownload
    
    Write-Host "  → Распаковка в $OllamaDir"
    Expand-Archive -Path $zipPath -DestinationPath $OllamaDir -Force

    # 6. Восстановление профиля (если он лежал внутри OllamaDir)
    $backupProfile = Join-Path $backupDir '.ollama'
    if (Test-Path $backupProfile) {
        Write-Host "  → Восстановление профиля .ollama из резервной копии"
        Copy-Item -Path $backupProfile -Destination $OllamaDir -Recurse -Force
    }

    # 7. Запуск службы
    Write-Step "Запуск службы $ServiceName"
    if ($nssmExe) {
        & $nssmExe start $ServiceName 2>&1 | Out-Null
    } else {
        Start-Service -Name $ServiceName
    }
    
    $svc = Get-Service -Name $ServiceName
    $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds($StartTimeoutSec))
    Write-Host "  ✓ Статус: $($svc.Status)" -ForegroundColor Green

    # 8. Health-check
    Write-Step "Проверка API"
    $maxAttempts = 10
    $apiOk = $false
    for ($i = 1; $i -le $maxAttempts; $i++) {
        Start-Sleep -Seconds 2
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/tags" -TimeoutSec 5 | Out-Null
            $apiOk = $true
            Write-Host "  ✓ Попытка ${i}: API отвечает" -ForegroundColor Green
            break
        } catch {
            Write-Host "  … Попытка ${i}/${maxAttempts}: ожидание..."
        }
    }

    if ($apiOk) {
        $newVer = (& (Join-Path $OllamaDir 'ollama.exe') --version 2>&1) -join ' '
        Write-Host "`n=============================" -ForegroundColor Green
        Write-Host ' Обновление успешно завершено' -ForegroundColor Green
        Write-Host '=============================' -ForegroundColor Green
        Write-Host " Новая версия: $newVer"
        Write-Host " Бэкап       : $backupDir"
    } else {
        Write-Warning "API не ответил после обновления!"
        Write-Warning "Проверьте лог: $(Join-Path $OllamaDir 'logs\ollama.err.log')"
        Write-Warning "Для отката переименуйте $backupDir обратно в $OllamaDir"
    }
}
catch {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    Write-Host "Если служба не работает, откатите вручную, переименовав папку бэкапа обратно." -ForegroundColor Yellow
    if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
    exit 1
}

if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
