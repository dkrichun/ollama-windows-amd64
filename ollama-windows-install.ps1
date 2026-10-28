#Requires -Version 5.1
<#
.SYNOPSIS
    Развёртывание и обновление Ollama как службы Windows.

.DESCRIPTION
    Читает ollama-windows-install.ini. Позволяет выбрать любую версию, включая
    уже установленную (в этом случае выполняется переустановка с пересозданием
    службы). Перед установкой/переустановкой делает резервную копию в папку
    Backup. Скачанные архивы сохраняются в подпапки Downloads\ollama_@version@
    и Downloads\nssm_@version@.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force,
    [switch]$ForceDownload,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$forceDL = [bool]$ForceDownload

# ─── 0. Путь к INI и самоповышение прав ───
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDir 'ollama-windows-install.ini'
}
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запрос прав администратора (UAC)...' -ForegroundColor Yellow
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConfigPath `"$ConfigPath`""
    if ($Force)         { $argLine += ' -Force'         }
    if ($ForceDownload) { $argLine += ' -ForceDownload' }
    if ($NoPause)       { $argLine += ' -NoPause'       }
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
$ModelsDir        = Get-Cfg     'paths'     'ModelsDir'            'D:\AI\Models'
$NssmDir          = Get-Cfg     'paths'     'NssmDir'              'C:\Program Files\NSSM'
$LogsDir          = Get-Cfg     'paths'     'LogsDir'              ''
$DownloadsDir     = Get-Cfg     'paths'     'DownloadsDir'         ''
$BackupDir        = Get-Cfg     'paths'     'BackupDir'            ''
$OllamaHome       = Get-Cfg     'ollama'    'OllamaHome'           $OllamaDir
$ServiceName      = Get-Cfg     'service'   'ServiceName'          'Ollama'
$StartType        = Get-Cfg     'service'   'StartType'            'SERVICE_DELAYED_AUTO_START'
$StartTimeoutSec  = Get-CfgInt  'service'   'StartTimeoutSeconds'  60
$AppRestartDelay  = Get-CfgInt  'service'   'AppRestartDelay'      10000
$AddToPath        = Get-CfgBool 'service'   'AddToPath'            $true
$HostOnly         = Get-Cfg     'network'   'Host'                 '0.0.0.0'
$Port             = Get-CfgInt  'network'   'Port'                 11434
$FirewallEnabled  = Get-CfgBool 'network'   'FirewallEnabled'      $true
$FirewallSubnet   = Get-Cfg     'network'   'FirewallSubnet'       '192.168.117.0/24'
$Origins          = Get-Cfg     'network'   'Origins'              ''
$OllamaVersion    = Get-Cfg     'downloads' 'OllamaVersion'        'ask'
$NssmUrl          = Get-Cfg     'downloads' 'NssmUrl'              'https://github.com/dkxce/NSSM/releases/download/v2.25/NSSM_v2.25.zip'
$OllamaUrlFallback = Get-Cfg    'downloads' 'OllamaUrl'            'https://github.com/ollama/ollama/releases/download/v0.40.10/ollama-windows-amd64.zip'
$KeepDownloads    = Get-CfgBool 'downloads' 'KeepDownloads'        $true
$DownloadModels   = Get-CfgBool 'models'    'DownloadModels'       $true
$InteractiveModels = Get-CfgBool 'models'   'Interactive'          $true
$ModelsSpec       = Get-Cfg     'models'    'Models'               ''

# ─── Параметры производительности ───
$KeepAlive       = Get-Cfg     'performance' 'KeepAlive'          '10m'
$FlashAttention  = Get-CfgBool 'performance' 'FlashAttention'     $true
$KvCacheType     = Get-Cfg     'performance' 'KvCacheType'        'q8_0'
$NumParallel     = Get-CfgInt  'performance' 'NumParallel'        1
$MaxLoadedModels = Get-CfgInt  'performance' 'MaxLoadedModels'    1
$DebugMode       = Get-CfgBool 'performance' 'Debug'              $false

if ([string]::IsNullOrWhiteSpace($LogsDir))    { $LogsDir    = Join-Path $OllamaDir 'logs' }
if ([string]::IsNullOrWhiteSpace($OllamaHome)) { $OllamaHome = $OllamaDir }

if ([string]::IsNullOrWhiteSpace($DownloadsDir)) {
    $DownloadsDir = Join-Path $scriptDir 'Downloads'
} elseif (-not [IO.Path]::IsPathRooted($DownloadsDir)) {
    $DownloadsDir = Join-Path $scriptDir $DownloadsDir
}
$DownloadsDir = [IO.Path]::GetFullPath($DownloadsDir)

if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    $BackupDir = Join-Path $scriptDir 'Backup'
} elseif (-not [IO.Path]::IsPathRooted($BackupDir)) {
    $BackupDir = Join-Path $scriptDir $BackupDir
}
$BackupDir = [IO.Path]::GetFullPath($BackupDir)

$OllamaHost  = "${HostOnly}:${Port}"
$NewProfile  = Join-Path $OllamaHome '.ollama'
$OldProfile  = 'C:\Windows\System32\config\systemprofile\.ollama'

$preselectedModels = @()
if (-not [string]::IsNullOrWhiteSpace($ModelsSpec)) {
    $preselectedModels = $ModelsSpec -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
}

$faValue = if ($FlashAttention) { '1' } else { '0' }
if ($KvCacheType -ne 'f16' -and -not $FlashAttention) {
    Write-Warning "KvCacheType=$KvCacheType требует FlashAttention=1. Принудительно включаем Flash Attention."
    $faValue = '1'
}
if ($KvCacheType -notin @('f16','q8_0','q4_0')) {
    Write-Warning "Неизвестный KvCacheType='$KvCacheType'. Допустимые: f16, q8_0, q4_0."
}

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
if (-not [string]::IsNullOrWhiteSpace($Origins)) { $envPairs += "OLLAMA_ORIGINS=$Origins" }
if ($DebugMode) { $envPairs += "OLLAMA_DEBUG=1" }

# Env для диагностического запуска
$testEnv = @{
    'USERPROFILE'            = $OllamaHome
    'HOME'                   = $OllamaHome
    'OLLAMA_HOST'            = $OllamaHost
    'OLLAMA_MODELS'          = $ModelsDir
    'OLLAMA_KEEP_ALIVE'      = $KeepAlive
    'OLLAMA_FLASH_ATTENTION' = $faValue
    'OLLAMA_KV_CACHE_TYPE'   = $KvCacheType
    'OLLAMA_NUM_PARALLEL'    = "$NumParallel"
    'OLLAMA_MAX_LOADED_MODELS' = "$MaxLoadedModels"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

function Stop-OllamaProcesses {
    Write-Host "  → Завершение процессов Ollama..."
    $processesToKill = @("OllamaTM", "ollama app", "ollama", "ollama_llama_server")
    foreach ($procName in $processesToKill) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "    Убит процесс: $($_.Name) (PID: $($_.Id))"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
}

function Set-OllamaAcl {
    param([string]$OllamaDir, [string]$OllamaHome, [string]$ModelsDir, [string]$NewProfile)
    foreach ($dir in @($OllamaDir, $OllamaHome)) {
        if ((Test-Path $dir) -and $dir) {
            icacls $dir /grant '*S-1-5-18:(OI)(CI)F' /T 2>&1 | Out-Null
            icacls $dir /grant '*S-1-5-32-544:(OI)(CI)F' /T 2>&1 | Out-Null
        }
    }
    if ($ModelsDir -and (Test-Path $ModelsDir)) {
        icacls $ModelsDir /grant '*S-1-5-18:(OI)(CI)F' /T 2>&1 | Out-Null
        icacls $ModelsDir /grant '*S-1-5-32-544:(OI)(CI)F' /T 2>&1 | Out-Null
    }
    if ($NewProfile -and (Test-Path $NewProfile)) {
        icacls $NewProfile /grant '*S-1-5-18:(OI)(CI)F' /T 2>&1 | Out-Null
        icacls $NewProfile /grant '*S-1-5-32-544:(OI)(CI)F' /T 2>&1 | Out-Null
    }
}

function Get-FileNameFromUrl {
    param([string]$Url, [string]$Fallback = 'download.bin')
    try {
        $uri  = [Uri]$Url
        $name = [IO.Path]::GetFileName($uri.AbsolutePath)
        if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
    } catch { }
    return $Fallback
}

function Get-CachedFile {
    param([string]$Url, [string]$FileName, [string]$SubDir = '', [switch]$ForceRedownload)
    $targetDir = if ([string]::IsNullOrWhiteSpace($SubDir)) { $DownloadsDir } else { Join-Path $DownloadsDir $SubDir }
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    $cachePath = Join-Path $targetDir $FileName
    $urlStamp  = "$cachePath.url"

    if ($KeepDownloads -and -not $ForceRedownload) {
        if ((Test-Path -LiteralPath $cachePath) -and (Test-Path -LiteralPath $urlStamp)) {
            $cachedUrl = ''
            try { $cachedUrl = (Get-Content -LiteralPath $urlStamp -Raw -ErrorAction Stop).Trim() } catch { }
            if ($cachedUrl -eq $Url) {
                $sizeMb = [math]::Round((Get-Item -LiteralPath $cachePath).Length / 1MB, 1)
                Write-Host "  ✓ Кэш: $cachePath ($sizeMb MB)"
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

function Add-ToMachinePath {
    param([string]$Dir)
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($null -eq $current) { $current = '' }
    $parts = $current -split ';' | Where-Object { $_ -ne '' }
    $normalized = $parts | ForEach-Object { $_.TrimEnd('\') }
    if ($normalized -contains $Dir.TrimEnd('\')) { return }
    $new = if ($current.TrimEnd(';') -eq '') { $Dir } else { $current.TrimEnd(';') + ';' + $Dir }
    [Environment]::SetEnvironmentVariable('Path', $new, 'Machine')
    Write-Host "  ✓ Добавлено в PATH: $Dir"
}

# ─── GitHub Releases ───
function Get-OllamaReleases {
    param([switch]$ForceRefresh)
    $cacheFile = Join-Path $DownloadsDir '.ollama_releases_cache.json'
    $cacheTtl  = 12 * 60 * 60

    if (-not $ForceRefresh -and (Test-Path -LiteralPath $cacheFile)) {
        $age = (Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime
        if ($age.TotalSeconds -lt $cacheTtl) {
            try { return (Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json) } catch { }
        }
    }

    $headers = @{ 'User-Agent' = 'PowerShell-Ollama-Deploy-Script'; 'Accept' = 'application/vnd.github+json' }
    try {
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/ollama/ollama/releases?per_page=30' -Headers $headers -ErrorAction Stop
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
    param($Releases, [string]$CurrentVersion)
    if (-not $Releases) { return $null }

    $stable = @($Releases | Where-Object { -not (Test-IsPrerelease $_) })
    if ($stable.Count -eq 0) {
        Write-Warning '  Нет доступных версий для установки.'
        return $null
    }

    $list = $stable[0..([math]::Min(14, $stable.Count-1))]
    Write-Host ''
    Write-Host 'Доступные версии Ollama:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $list.Count; $i++) {
        $date = ([datetime]$list[$i].published_at).ToString('yyyy-MM-dd')
        $mark = if ($CurrentVersion -and $list[$i].tag_name -eq $CurrentVersion) {
            ' <-- текущая (переустановка)'
        } else { '' }
        Write-Host ('  [{0}] {1,-16} {2}  {3}' -f ($i+1), $list[$i].tag_name, $date, $mark) -ForegroundColor $(if ($mark) { 'Yellow' } else { 'White' })
    }
    Write-Host ''

    while ($true) {
        Write-Host 'Введите номер версии (Enter — последняя, s — отмена):' -ForegroundColor Cyan
        $ans = (Read-Host 'Выбор').Trim()

        if ([string]::IsNullOrWhiteSpace($ans)) { return $list[0] }
        if ($ans -match '^[scысSCЫС]$') { return 'CANCEL' }

        $n = 0
        if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) {
            return $list[$n-1]
        }
        Write-Warning "  Некорректный ввод: '$ans'. Введите число от 1 до $($list.Count), 's' для отмены или Enter."
    }
}

function Resolve-OllamaVersion {
    param([string]$RequestedVersion, [string]$CurrentVersion, [switch]$ForceRefresh)
    
    if ($RequestedVersion -match '^v?\d+\.\d+\.\d+$') {
        if (-not $RequestedVersion.StartsWith('v')) { return "v$RequestedVersion" }
        return $RequestedVersion
    }
    
    $releases = Get-OllamaReleases -ForceRefresh:$ForceRefresh
    if (-not $releases) { return $null }

    if ($RequestedVersion -eq 'ask' -and -not $Force) {
        $sel = Select-OllamaVersionInteractive -Releases $releases -CurrentVersion $CurrentVersion
        if ($sel -is [string] -and $sel -eq 'CANCEL') { return 'CANCEL' }
        if ($null -eq $sel) { return $null }
        if ($sel.tag_name) { return $sel.tag_name }
        return $null
    }

    $latest = @($releases | Where-Object { -not (Test-IsPrerelease $_) }) | Select-Object -First 1
    if ($latest) { return $latest.tag_name }
    return $null
}

function Test-ModelInstalled {
    param([string]$Exe, [string]$Model)
    try {
        $list = & $Exe list 2>&1 | Out-String
        $pattern = '(?m)^' + [regex]::Escape($Model) + '\s'
        return ($list -match $pattern)
    } catch { return $false }
}

function Invoke-PullModel {
    param([string]$Exe, [string]$Model, [string]$ApiHost)
    if (Test-ModelInstalled -Exe $Exe -Model $Model) {
        Write-Host "  ✓ $Model уже установлена — пропускаем" -ForegroundColor Green
        return $true
    }
    
    Write-Host "  → Загрузка $Model через API..." -ForegroundColor Cyan
    $useCurl = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)
    $hasError = $false
    
    if ($useCurl) {
        $jsonBody = "{`"name`": `"$Model`"}"
        $curlArgs = @("-N", "-s", "-X", "POST", "http://$ApiHost/api/pull", "-H", "Content-Type: application/json", "-d", $jsonBody)
        $lastStatus = ""
        
        & curl.exe @curlArgs 2>&1 | ForEach-Object {
            $line = $_.Trim()
            if ($line -eq '') { return }
            try {
                $obj = $line | ConvertFrom-Json
                if ($null -ne $obj.error) {
                    Write-Warning "`n    Ошибка API: $($obj.error)"
                    $hasError = $true
                    return
                }
                
                $status = $obj.status
                if ($status -eq 'downloading' -or $status -eq 'pulling') {
                    $completed = if ($null -ne $obj.completed) { [long]$obj.completed } else { 0 }
                    $total = if ($null -ne $obj.total) { [long]$obj.total } else { 0 }
                    if ($total -gt 0) {
                        $percent = [math]::Round(($completed / $total) * 100, 1)
                        $cMB = [math]::Round($completed / 1MB, 1)
                        $tMB = [math]::Round($total / 1MB, 1)
                        $digest = if ($obj.digest) { $obj.digest.Substring(0, 12) } else { "" }
                        Write-Progress -Activity "Загрузка $Model" -Status "$status $digest ($cMB MB / $tMB MB)" -PercentComplete $percent
                    }
                } elseif ($status -ne $lastStatus) {
                    Write-Progress -Activity "Загрузка $Model" -Completed
                    if ($status -eq 'success') { Write-Host "  ✓ $Model успешно загружена" -ForegroundColor Green }
                    else { Write-Host "    $status" }
                    $lastStatus = $status
                }
            } catch { Write-Host "    $line" }
        }
        Write-Host "" 
        if ($hasError) { return $false }
    } else {
        $prevHost = $env:OLLAMA_HOST
        $prevModels = $env:OLLAMA_MODELS
        try {
            $env:OLLAMA_HOST   = $ApiHost
            $env:OLLAMA_MODELS = $ModelsDir
            & $Exe pull $Model 2>&1 | ForEach-Object {
                $line = $_ -replace "`r", ""
                $line = $line -replace '\x1B\[[0-9;?]*[a-zA-Z]', ''
                $line = $line -replace '[\x00-\x1F\x7F]', ''
                if ($line.Trim() -ne '') { Write-Host "    $line" }
            }
        } finally {
            $env:OLLAMA_HOST   = $prevHost
            $env:OLLAMA_MODELS = $prevModels
        }
    }
    return (Test-ModelInstalled -Exe $Exe -Model $Model)
}

function Select-ModelsInteractive {
    param([string[]]$Preselected)
    $menu = @(
        [pscustomobject]@{ Name='llama3.1:8b';      Desc='Общий чат · Q4_K_M ≈ 4.9 ГБ' }
        [pscustomobject]@{ Name='qwen2.5:7b';       Desc='Баланс качества · Q4_K_M ≈ 4.7 ГБ' }
        [pscustomobject]@{ Name='qwen2.5-coder:7b'; Desc='Кодинг · Q4_K_M ≈ 4.7 ГБ' }
        [pscustomobject]@{ Name='deepseek-r1:8b';   Desc='Reasoning · Q4_K_M ≈ 4.9 ГБ' }
        [pscustomobject]@{ Name='gemma2:2b';        Desc='Лёгкая, много контекста · ≈ 1.6 ГБ' }
        [pscustomobject]@{ Name='qwen2.5:3b';       Desc='Быстрая · ≈ 2 ГБ' }
    )

    Write-Host ''
    Write-Host 'Рекомендованные модели для RTX 4060 8 ГБ:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $menu.Count; $i++) {
        $mark = if ($Preselected -contains $menu[$i].Name) { '*' } else { ' ' }
        Write-Host ('  [{0}] {1} {2,-22} — {3}' -f ($i+1), $mark, $menu[$i].Name, $menu[$i].Desc)
    }
    Write-Host ''
    Write-Host "  * — предвыбрано из INI ([models] Models)." -ForegroundColor DarkGray
    Write-Host 'Введите номера через запятую (например, "1,3"),' -ForegroundColor Cyan
    Write-Host "  'a' — все, 'n' — пропустить, Enter — оставить предвыбранные:" -ForegroundColor Cyan

    $ans = Read-Host 'Выбор'
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Preselected }
    if ($ans -eq 'n') { return @() }
    if ($ans -eq 'a') { return $menu | ForEach-Object { $_.Name } }

    $selected = @()
    foreach ($part in ($ans -split ',')) {
        $p = $part.Trim()
        $n = 0
        if ([int]::TryParse($p, [ref]$n) -and $n -ge 1 -and $n -le $menu.Count) {
            $name = $menu[$n-1].Name
            if ($selected -notcontains $name) { $selected += $name }
        } else {
            Write-Warning "  Пропущено: '$p' (не число или вне диапазона 1..$($menu.Count))"
        }
    }
    return $selected
}

function Test-OllamaServeDirect {
    param([string]$OllamaExe, [hashtable]$EnvVars)
    Write-Host "  → Диагностика: пробуем запустить ollama.exe serve напрямую (5 сек)..."

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $OllamaExe
    $psi.Arguments = "serve"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    foreach ($k in $EnvVars.Keys) { $psi.EnvironmentVariables[$k] = $EnvVars[$k] }

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        Start-Sleep -Seconds 5

        $exited = $proc.HasExited
        if (-not $exited) {
            Write-Host "    ✓ Процесс РАБОТАЕТ (значит ollama.exe рабочий, проблема в конфиге NSSM)"
            try { $proc.Kill() } catch {}
            $proc.WaitForExit(3000) | Out-Null
        } else {
            Write-Host "    ✗ Процесс УПАЛ с кодом $($proc.ExitCode)" -ForegroundColor Red
        }

        $stderr = ''
        $stdout = ''
        try { $stderr = $proc.StandardError.ReadToEnd() } catch {}
        try { $stdout = $proc.StandardOutput.ReadToEnd() } catch {}

        if ($stderr -and $stderr.Trim()) {
            Write-Host "    STDERR:" -ForegroundColor Yellow
            $stderr -split "`n" | Select-Object -First 25 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        }
        if ($stdout -and $stdout.Trim()) {
            Write-Host "    STDOUT (первые 15 строк):" -ForegroundColor Yellow
            $stdout -split "`n" | Select-Object -First 15 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        }
        return ($exited -eq $false)
    } catch {
        Write-Host "    Не удалось запустить тест: $_" -ForegroundColor Red
        return $false
    }
}

function Start-OllamaService {
    param([string]$NssmExe, [string]$ServiceName, [int]$TimeoutSec, [int]$MaxAttempts = 3)

    $started = $false
    $lastStatus = ''
    
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "  → Попытка запуска $attempt из $MaxAttempts..."
        
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc) { throw "Служба $ServiceName не найдена после установки" }
        
        if ($svc.Status -eq 'Running') {
            $started = $true
            break
        }
        
        $nssmOut = & $NssmExe start $ServiceName 2>&1
        if ($nssmOut) { Write-Host "    NSSM: $nssmOut" -ForegroundColor DarkGray }
        
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastStatus = ''
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            $svc.Refresh()
            $status = $svc.Status
            
            if ($status -ne $lastStatus) {
                Write-Host "    Статус: $status"
                $lastStatus = $status
            }
            
            if ($status -eq 'Running') { $started = $true; break }
            
            if ($status -eq 'Stopped' -and $sw.Elapsed.TotalSeconds -gt 3) {
                Write-Warning "  ⚠ Служба упала через $([int]$sw.Elapsed.TotalSeconds) сек после запуска"
                break
            }
            
            Start-Sleep -Milliseconds 500
        }
        
        if ($started) { break }
        
        if ($attempt -lt $MaxAttempts) {
            Write-Host "  → Пауза 5 сек перед повтором..."
            Start-Sleep -Seconds 5
        }
    }
    
    if ($started) {
        Write-Host "  ✓ Статус: Running" -ForegroundColor Green
        return $true
    }

    Write-Host ""
    Write-Warning "Служба не запустилась за $MaxAttempts × $TimeoutSec сек."

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "  Текущий статус : $($svc.Status)" -ForegroundColor Yellow
    }
    try {
        $svcInfo = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
        if ($svcInfo -and $null -ne $svcInfo.ExitCode) {
            Write-Host "  ExitCode       : $($svcInfo.ExitCode)" -ForegroundColor Yellow
        }
    } catch {}

    $logCandidates = @(
        (Join-Path $LogsDir 'ollama.err.log'),
        (Join-Path $LogsDir 'ollama.out.log'),
        (Join-Path $OllamaDir 'logs\ollama.err.log'),
        (Join-Path $OllamaDir 'logs\ollama.out.log')
    ) | Select-Object -Unique

    foreach ($logFile in $logCandidates) {
        if (Test-Path $logFile) {
            $lines = @(Get-Content $logFile -Tail 15 -ErrorAction SilentlyContinue)
            if ($lines.Count -gt 0) {
                Write-Host "`n  Файл $logFile (последние строки):" -ForegroundColor Yellow
                $lines | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            }
        }
    }

    Write-Host "`n  nssm dump $ServiceName :" -ForegroundColor Yellow
    try {
        & $NssmExe dump $ServiceName 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    } catch {}

    return $false
}

try {
    $ollamaExe = Join-Path $OllamaDir 'ollama.exe'
    $currentVersion = $null
    
    if (Test-Path $ollamaExe) {
        $verOut = (& $ollamaExe --version 2>&1) -join ' '
        if ($verOut -match '(\d+\.\d+\.\d+)') {
            $currentVersion = "v$($matches[1])"
            Write-Host "`n  ℹ Обнаружена установленная версия: $currentVersion" -ForegroundColor Green
        }
    }

    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Step "Остановка существующей службы $ServiceName"
        & sc.exe stop $ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    }
    Stop-OllamaProcesses

    Write-Step "Проверка порта $Port"
    $busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($busy) {
        $pids = ($busy.OwningProcess | Sort-Object -Unique) -join ', '
        Write-Warning "Порт $Port уже занят PID: $pids"
        if (-not $Force) {
            $ans = Read-Host 'Продолжить? [y/N]'
            if ($ans -ne 'y') { throw 'Отменено пользователем' }
        }
    } else {
        Write-Host '  ✓ Свободен'
    }

    Write-Step 'Создание каталогов'
    $dirsToCreate = @($OllamaDir, $ModelsDir, $LogsDir, $NssmDir, $OllamaHome, $NewProfile, $DownloadsDir, $BackupDir)
    foreach ($d in ($dirsToCreate | Select-Object -Unique)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Write-Host "  ✓ $d"
    }

    Write-Step 'Права доступа'
    Set-OllamaAcl -OllamaDir $OllamaDir -OllamaHome $OllamaHome -ModelsDir $ModelsDir -NewProfile $NewProfile
    Write-Host "  ✓ Права Full Control выданы (SYSTEM + Administrators)"

    Write-Step "Установка NSSM в $NssmDir"
    $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\win64\\' } |
        Select-Object -First 1 -ExpandProperty FullName

    if (-not $nssmExe -or $forceDL) {
        $nssmZipName = Get-FileNameFromUrl -Url $NssmUrl -Fallback 'NSSM.zip'
        $nssmVer = if ($NssmUrl -match '/download/([^/]+)/') { $matches[1] -replace '^v', '' } else { 'unknown' }
        $nssmSubDir = "nssm_$nssmVer"
        $nssmZip     = Get-CachedFile -Url $NssmUrl -FileName $nssmZipName -SubDir $nssmSubDir -ForceRedownload:$forceDL
        Expand-Archive -Path $nssmZip -DestinationPath $NssmDir -Force
        if (-not $KeepDownloads) { Remove-Item -LiteralPath $nssmZip -Force -ErrorAction SilentlyContinue }
        $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse | Where-Object { $_.FullName -match '\\win64\\' } | Select-Object -First 1 -ExpandProperty FullName
        if (-not $nssmExe) { $nssmExe = Get-ChildItem -Path $NssmDir -Filter nssm.exe -Recurse | Select-Object -First 1 -ExpandProperty FullName }
        if (-not $nssmExe) { throw "nssm.exe не найден после распаковки в $NssmDir" }
    }
    Write-Host "  ✓ $nssmExe"

    Write-Step "Выбор версии Ollama"
    $targetVersion = $null
    if ($currentVersion -and -not $forceDL) {
        Write-Host "  Текущая версия: $currentVersion" -ForegroundColor Cyan
        $resolvedVersion = Resolve-OllamaVersion -RequestedVersion $OllamaVersion -CurrentVersion $currentVersion -ForceRefresh:$forceDL
        if ($resolvedVersion -is [string] -and $resolvedVersion -eq 'CANCEL') {
            Write-Host "`n  Установка отменена пользователем." -ForegroundColor Yellow
            if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
            exit 0
        }
        if (-not $resolvedVersion) {
            if ($Force) { throw "Не удалось определить версию." }
            $resolvedVersion = $currentVersion
        }
        $targetVersion = $resolvedVersion
    } else {
        $targetVersion = Resolve-OllamaVersion -RequestedVersion $OllamaVersion -CurrentVersion $currentVersion -ForceRefresh:$forceDL
        if ($targetVersion -is [string] -and $targetVersion -eq 'CANCEL') {
            Write-Host "`n  Установка отменена пользователем." -ForegroundColor Yellow
            if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
            exit 0
        }
        if (-not $targetVersion) {
            Write-Warning '  ⚠ Не удалось определить версию. Используем резервный URL из INI.'
            $targetVersion = ($OllamaUrlFallback -split '/')[-3]
        }
    }

    $isReinstall = $false
    $isUpgrade   = $false
    if ($currentVersion -and $targetVersion) {
        if ($currentVersion -eq $targetVersion) {
            $isReinstall = $true
            Write-Host "`n  ℹ Та же версия: $targetVersion (переустановка)" -ForegroundColor Yellow
            if (-not $Force) {
                $ans = Read-Host "Переустановить текущую версию $currentVersion? [Y/n]"
                if ($ans -eq 'n' -or $ans -eq 'N') { Write-Host "  Отменено." -ForegroundColor Yellow; if (-not $NoPause) { Read-Host 'Enter' | Out-Null }; exit 0 }
            }
        } else {
            $isUpgrade = $true
            Write-Host "`n  → Обновление/даунгрейд: $currentVersion → $targetVersion" -ForegroundColor Cyan
        }
    } elseif ($targetVersion) {
        Write-Host "`n  → Первичная установка: $targetVersion" -ForegroundColor Cyan
    }

    $downloadUrl = "https://github.com/ollama/ollama/releases/download/$targetVersion/ollama-windows-amd64.zip"
    $needsBackup = ($currentVersion -and (Test-Path $OllamaDir))
    $backupPath = $null

    if ($needsBackup) {
        Write-Step "Создание резервной копии"
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupName = "Ollama_$timestamp"
        $backupPath = Join-Path $BackupDir $backupName

        Write-Host "  → Перемещение $OllamaDir в $backupPath"
        try {
            Rename-Item -Path $OllamaDir -NewName $backupName -ErrorAction Stop
            Move-Item -Path (Join-Path (Split-Path $OllamaDir -Parent) $backupName) -Destination $backupPath -Force
            Write-Host "  ✓ Бэкап: $backupPath" -ForegroundColor Green
        } catch {
            throw "Не удалось создать бэкап: $_"
        }
    }

    Write-Step "Подготовка каталогов после бэкапа"
    New-Item -ItemType Directory -Force -Path $OllamaDir | Out-Null
    New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
    New-Item -ItemType Directory -Force -Path $NewProfile | Out-Null
    Write-Host "  ✓ $OllamaDir"
    Write-Host "  ✓ $LogsDir"
    Write-Host "  ✓ $NewProfile"

    if ($needsBackup) {
        $backupProfile = Join-Path $backupPath '.ollama'
        if (Test-Path $backupProfile) {
            Write-Host "  → Восстановление профиля .ollama из бэкапа"
            Copy-Item -Path "$backupProfile\*" -Destination $NewProfile -Recurse -Force -ErrorAction SilentlyContinue
        }
        $backupLogs = Join-Path $backupPath 'logs'
        if (Test-Path $backupLogs) {
            Get-ChildItem $backupLogs -File | ForEach-Object {
                Copy-Item $_.FullName -Destination $LogsDir -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Set-OllamaAcl -OllamaDir $OllamaDir -OllamaHome $OllamaHome -ModelsDir $ModelsDir -NewProfile $NewProfile
    Write-Host "  ✓ Права Full Control повторно применены (SYSTEM + Administrators)"

    Write-Step "Установка Ollama в $OllamaDir"
    if ($needsBackup -or -not (Test-Path $ollamaExe) -or $forceDL) {
        Write-Host "  → Целевая версия: $targetVersion" -ForegroundColor Green
        $ollamaSubDir = 'ollama_' + ($targetVersion -replace '^v', '')
        $ollamaZip     = Get-CachedFile -Url $downloadUrl -FileName 'ollama-windows-amd64.zip' -SubDir $ollamaSubDir -ForceRedownload:$forceDL
        Expand-Archive -Path $ollamaZip -DestinationPath $OllamaDir -Force
        if (-not $KeepDownloads) { Remove-Item -LiteralPath $ollamaZip -Force -ErrorAction SilentlyContinue }
    } else {
        Write-Host "  ℹ Установка не требуется (используется текущая)"
    }

    $verRaw = (& $ollamaExe --version 2>&1) -join ' '
    if ($LASTEXITCODE -ne 0) { throw "ollama.exe --version завершился с кодом $LASTEXITCODE." }
    $verDisplay = $verRaw
    if ($verRaw -match 'client version is ([\d\.]+)') { $verDisplay = "v$($matches[1])" }
    elseif ($verRaw -match 'version is ([\d\.]+)') { $verDisplay = "v$($matches[1])" }
    Write-Host "  ✓ $verDisplay"

    Write-Step 'Переменные окружения (Machine)'
    [Environment]::SetEnvironmentVariable('OLLAMA_HOST',   $OllamaHost, 'Machine')
    [Environment]::SetEnvironmentVariable('OLLAMA_MODELS', $ModelsDir,  'Machine')
    
    if ($AddToPath) {
        Write-Step "Переменная PATH (Machine)"
        Add-ToMachinePath -Dir $OllamaDir
    }

    if ($FirewallEnabled -and -not [string]::IsNullOrWhiteSpace($FirewallSubnet)) {
        Write-Step "Правило брандмауэра ($FirewallSubnet)"
        $ruleName = "Ollama API ($FirewallSubnet)"
        Get-NetFirewallRule -DisplayName "Ollama API*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress $FirewallSubnet -Action Allow -Profile Any | Out-Null
        Write-Host "  ✓ $ruleName"
    }

    if ((Test-Path $OldProfile) -and -not (Test-Path (Join-Path $NewProfile 'id_ed25519'))) {
        Write-Step "Миграция профиля из $OldProfile"
        Copy-Item -Path "$OldProfile\*" -Destination $NewProfile -Recurse -Force -ErrorAction SilentlyContinue
        Set-OllamaAcl -OllamaDir $OllamaDir -OllamaHome $OllamaHome -ModelsDir $ModelsDir -NewProfile $NewProfile
        Write-Host "  ✓ Скопировано в $NewProfile"
    }

    Write-Step "Регистрация службы $ServiceName"
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Host '  → Остановка старой службы'
        & $nssmExe stop $ServiceName 2>&1 | Out-Null
        
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ((Get-Service $ServiceName -ErrorAction SilentlyContinue).Status -ne 'Stopped' -and $sw.Elapsed.TotalSeconds -lt 15) {
            Start-Sleep -Milliseconds 500
        }
        
        Write-Host '  → Удаление старой службы'
        & $nssmExe remove $ServiceName confirm 2>&1 | Out-Null
        
        $sw.Restart()
        while ((Get-Service $ServiceName -ErrorAction SilentlyContinue) -and $sw.Elapsed.TotalSeconds -lt 15) {
            Start-Sleep -Milliseconds 500
        }
        
        if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
            Write-Warning "  NSSM не удалил службу, принудительно через sc.exe"
            & sc.exe delete $ServiceName 2>&1 | Out-Null
            Start-Sleep -Seconds 2
        }
        
        if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
            throw "Не удалось удалить старую службу $ServiceName"
        }
    }

    & $nssmExe install $ServiceName $ollamaExe serve 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Ошибка NSSM при установке службы (код $LASTEXITCODE)."
    }
    & $nssmExe set $ServiceName AppDirectory $OllamaDir 2>&1 | Out-Null
    & $nssmExe set $ServiceName Start $StartType 2>&1 | Out-Null
    & $nssmExe set $ServiceName Description "Ollama is the most popular way to build with open models. Access the latest open models with complete privacy locally or in the cloud. Your prompts are never stored or trained on." 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppEnvironmentExtra @envPairs 2>&1 | Out-Null

    & $nssmExe set $ServiceName AppStdout (Join-Path $LogsDir 'ollama.out.log') 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppStderr (Join-Path $LogsDir 'ollama.err.log') 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateFiles 1 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateOnline 1 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRotateBytes 10485760 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppExit Default Restart 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppRestartDelay $AppRestartDelay 2>&1 | Out-Null
    & $nssmExe set $ServiceName AppThrottle 1500 2>&1 | Out-Null

    Write-Host '  ✓ Служба сконфигурирована'

    Write-Step 'Запуск службы'
    $ok = Start-OllamaService -NssmExe $nssmExe -ServiceName $ServiceName -TimeoutSec $StartTimeoutSec -MaxAttempts 3
    if (-not $ok) {
        Write-Host "`n=== ДОПОЛНИТЕЛЬНАЯ ДИАГНОСТИКА ===" -ForegroundColor Yellow
        Test-OllamaServeDirect -OllamaExe $ollamaExe -EnvVars $testEnv | Out-Null
        throw "Служба $ServiceName не запустилась. Смотрите диагностику выше."
    }

    Write-Step 'Проверка API (локально)'
    $maxAttempts = 15
    $apiOk = $false
    for ($i = 1; $i -le $maxAttempts; $i++) {
        Start-Sleep -Seconds 2
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/tags" -TimeoutSec 5 | Out-Null
            $apiOk = $true
            Write-Host "  ✓ Попытка ${i}: API отвечает"
            break
        } catch {
            Write-Host "  … Попытка ${i}/${maxAttempts}: $($_.Exception.Message)"
        }
    }
    if (-not $apiOk) {
        Write-Warning "API не ответил за $($maxAttempts * 2) секунд."
    }

    $pulledModels = @()
    if ($DownloadModels) {
        Write-Step 'Скачивание моделей'
        if (-not $apiOk) {
            Write-Warning '  API не отвечает — скачивание моделей пропущено.'
        } else {
            $toPull = @()
            if ($InteractiveModels -and -not $Force) {
                $toPull = Select-ModelsInteractive -Preselected $preselectedModels
            } else {
                $toPull = $preselectedModels
                if ($toPull.Count -eq 0) {
                    Write-Host '  ℹ Модели не заданы — пропускаем.'
                } else {
                    Write-Host "  → Неинтерактивный режим: $($toPull -join ', ')"
                }
            }

            if ($toPull.Count -gt 0) {
                Write-Host ''
                foreach ($m in $toPull) {
                    if (Invoke-PullModel -Exe $ollamaExe -Model $m -ApiHost "127.0.0.1:$Port") {
                        $pulledModels += $m
                    }
                }
            }
        }
    }

    $actionLabel = if ($isReinstall) { 'переустановка' } elseif ($isUpgrade) { 'обновление/даунгрейд' } else { 'первичная установка' }
    Write-Host "`n=============================" -ForegroundColor Green
    Write-Host " Развёртывание завершено ($actionLabel)" -ForegroundColor Green
    Write-Host '=============================' -ForegroundColor Green
    Write-Host " Служба      : $ServiceName"
    Write-Host " Версия      : $(if($currentVersion){$currentVersion} else {'не была установлена'}) -> $(if($targetVersion){$targetVersion} else {'N/A'})"
    Write-Host " Бинарник    : $ollamaExe"
    Write-Host " Модели      : $ModelsDir"
    Write-Host " Профиль     : $NewProfile"
    Write-Host " Логи        : $LogsDir"
    if ($targetVersion) {
        Write-Host " Архивы      : $DownloadsDir\ollama_$($targetVersion -replace '^v','')"
    }
    if ($backupPath) {
        Write-Host " Бэкап       : $backupPath"
    } else {
        Write-Host " Бэкапы      : $BackupDir (не требуется)"
    }
    Write-Host " API локально: http://127.0.0.1:$Port"
    Write-Host " Performance : KeepAlive=$KeepAlive, FA=$faValue, KvCache=$KvCacheType"
    
    if ($FirewallEnabled -and -not [string]::IsNullOrWhiteSpace($FirewallSubnet)) {
        $localIps = @()
        try {
            $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)' -and $_.PrefixOrigin -ne 'WellKnown' }
            foreach ($ip in $ips) {
                $networkIp = $FirewallSubnet -replace '/.*$'
                $prefixLen = [int]($FirewallSubnet -replace '^.*/', '')
                $ipBytes = ([System.Net.IPAddress]::Parse($ip.IPAddress)).GetAddressBytes()
                $netBytes = ([System.Net.IPAddress]::Parse($networkIp)).GetAddressBytes()
                $ipNum = [uint32]$ipBytes[0] -shl 24 -bor [uint32]$ipBytes[1] -shl 16 -bor [uint32]$ipBytes[2] -shl 8 -bor [uint32]$ipBytes[3]
                $netNum = [uint32]$netBytes[0] -shl 24 -bor [uint32]$netBytes[1] -shl 16 -bor [uint32]$netBytes[2] -shl 8 -bor [uint32]$netBytes[3]
                $mask = if ($prefixLen -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $prefixLen)) }
                if (($ipNum -band $mask) -eq ($netNum -band $mask)) { $localIps += $ip.IPAddress }
            }
        } catch {}
        if ($localIps.Count -gt 0) {
            foreach ($ip in $localIps) { Write-Host " API по сети : http://${ip}:$Port ($FirewallSubnet)" }
        } else {
            Write-Host " API по сети : http://<IP-сервера>:$Port ($FirewallSubnet)"
        }
    }
    
    if ($AddToPath) { Write-Host " PATH        : $OllamaDir добавлен (нужна новая консоль)" }
    if ($pulledModels.Count -gt 0) { Write-Host " Загружено   : $($pulledModels -join ', ')" }
    Write-Host " Проверка    : ollama list"
}
catch {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
    exit 1
}

if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
