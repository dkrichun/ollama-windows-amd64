#Requires -Version 5.1
<#
.SYNOPSIS
    Удаление службы Ollama.

.DESCRIPTION
    Читает ollama-windows-install.ini. Останавливает и удаляет службу,
    чистит брандмауэр и переменные окружения. Каталоги (модели, профиль,
    логи, бэкапы, архивы) удаляются только по явным флагам.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$PurgeProfile,
    [switch]$PurgeModels,
    [switch]$PurgeOllama,
    [switch]$PurgeLogs,
    [switch]$PurgeDownloads,
    [switch]$PurgeBackup,
    [switch]$Force,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

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
    if ($PurgeProfile)   { $argLine += ' -PurgeProfile'   }
    if ($PurgeModels)    { $argLine += ' -PurgeModels'    }
    if ($PurgeOllama)    { $argLine += ' -PurgeOllama'    }
    if ($PurgeLogs)      { $argLine += ' -PurgeLogs'      }
    if ($PurgeDownloads) { $argLine += ' -PurgeDownloads' }
    if ($PurgeBackup)    { $argLine += ' -PurgeBackup'    }
    if ($Force)          { $argLine += ' -Force'          }
    if ($NoPause)        { $argLine += ' -NoPause'        }
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

$OllamaDir    = Get-Cfg     'paths'   'OllamaDir'        'D:\AI\Ollama'
$ModelsDir    = Get-Cfg     'paths'   'ModelsDir'        'D:\AI\Models'
$NssmDir      = Get-Cfg     'paths'   'NssmDir'          'C:\Program Files\NSSM'
$LogsDir      = Get-Cfg     'paths'   'LogsDir'          ''
$DownloadsDir = Get-Cfg     'paths'   'DownloadsDir'     ''
$BackupDir    = Get-Cfg     'paths'   'BackupDir'        ''
$OllamaHome   = Get-Cfg     'ollama'  'OllamaHome'       $OllamaDir
$ServiceName  = Get-Cfg     'service' 'ServiceName'      'Ollama'
$AddToPath    = Get-CfgBool 'service' 'AddToPath'        $true
$Port         = [int](Get-Cfg 'network' 'Port'           '11434')

if ([string]::IsNullOrWhiteSpace($LogsDir))    { $LogsDir    = Join-Path $OllamaDir 'logs' }
if ([string]::IsNullOrWhiteSpace($OllamaHome)) { $OllamaHome = $OllamaDir }
if ([string]::IsNullOrWhiteSpace($DownloadsDir)) { $DownloadsDir = Join-Path $scriptDir 'Downloads' }
if ([string]::IsNullOrWhiteSpace($BackupDir))    { $BackupDir = Join-Path $scriptDir 'Backup' }

function Write-Step([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Confirm-Action([string]$Prompt) {
    if ($Force) { Write-Host "  (Force) $Prompt → да"; return $true }
    $ans = Read-Host "$Prompt [y/N]"
    return ($ans -eq 'y')
}

function Find-Nssm {
    param([string]$Dir)
    $exe = Get-ChildItem -Path $Dir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\win64\\' } | Select-Object -First 1 -ExpandProperty FullName
    if (-not $exe) { $exe = Get-ChildItem -Path $Dir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    return $exe
}

function Remove-FromMachinePath {
    param([string]$Dir)
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($null -eq $current -or $current.Trim() -eq '') { return }
    $parts = $current -split ';' | Where-Object { $_ -ne '' }
    $target = $Dir.TrimEnd('\')
    $kept = $parts | Where-Object { $_.TrimEnd('\') -ne $target }
    if ($kept.Count -eq $parts.Count) { return }
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'Machine')
    Write-Host "  ✓ $Dir удалён из PATH"
}

try {
    Write-Step "Служба $ServiceName"
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        $nssmExe = Find-Nssm -Dir $NssmDir
        if ($nssmExe) { & $nssmExe stop $ServiceName 2>&1 | Out-Null } else { & sc.exe stop $ServiceName | Out-Null }
        
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ((Get-Service $ServiceName -ErrorAction SilentlyContinue).Status -ne 'Stopped' -and $sw.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 500 }
        if ((Get-Service $ServiceName -ErrorAction SilentlyContinue).Status -ne 'Stopped') {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }

        if ($nssmExe) { & $nssmExe remove $ServiceName confirm 2>&1 | Out-Null }
        if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { & sc.exe delete $ServiceName | Out-Null; Start-Sleep -Seconds 1 }
        Write-Host '  ✓ Служба удалена'
    } else {
        Write-Host '  ℹ Службы нет'
    }

    Write-Step 'Правило брандмауэра'
    $rules = Get-NetFirewallRule -DisplayName "Ollama API*" -ErrorAction SilentlyContinue
    if ($rules) {
        $rules | Remove-NetFirewallRule
        Write-Host "  ✓ Удалено правил: $($rules.Count)"
    } else {
        Write-Host '  ℹ Правил не найдено'
    }

    if ($AddToPath) {
        Write-Step 'Переменная PATH (Machine)'
        Remove-FromMachinePath -Dir $OllamaDir
    }

    Write-Step 'Переменные окружения (Machine)'
    foreach ($name in @('OLLAMA_HOST','OLLAMA_MODELS')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Machine')
        Write-Host "  ✓ Удалена $name"
    }

    $profileDir = Join-Path $OllamaHome '.ollama'
    Write-Step "Профиль: $profileDir"
    if (Test-Path $profileDir) {
        if ($PurgeProfile) { if (Confirm-Action "Удалить $profileDir?") { Remove-Item -LiteralPath $profileDir -Recurse -Force; Write-Host '  ✓ Удалён' } }
        else { Write-Host '  ℹ Сохранён (используйте -PurgeProfile)' }
    }

    Write-Step "Модели: $ModelsDir"
    if (Test-Path $ModelsDir) {
        if ($PurgeModels) { if (Confirm-Action "Удалить $ModelsDir?") { Remove-Item -LiteralPath $ModelsDir -Recurse -Force; Write-Host '  ✓ Удалён' } }
        else { Write-Host '  ℹ Сохранён (используйте -PurgeModels)' }
    }

    Write-Step "Бинарники: $OllamaDir"
    if (Test-Path $OllamaDir) {
        if ($PurgeOllama) { if (Confirm-Action "Удалить $OllamaDir?") { Remove-Item -LiteralPath $OllamaDir -Recurse -Force; Write-Host '  ✓ Удалён' } }
        else { Write-Host '  ℹ Сохранён (используйте -PurgeOllama)' }
    }

    Write-Step "Логи: $LogsDir"
    if (Test-Path $LogsDir) {
        if ($PurgeLogs) { if (Confirm-Action "Удалить $LogsDir?") { Remove-Item -LiteralPath $LogsDir -Recurse -Force; Write-Host '  ✓ Удалён' } }
        else { Write-Host '  ℹ Сохранён (используйте -PurgeLogs)' }
    }

    Write-Step "Архивы: $DownloadsDir"
    if (Test-Path $DownloadsDir) {
        if ($PurgeDownloads) { if (Confirm-Action "Удалить $DownloadsDir (включая подпапки версий)?") { Remove-Item -LiteralPath $DownloadsDir -Recurse -Force; Write-Host '  ✓ Удалён' } }
        else { Write-Host '  ℹ Сохранён (используйте -PurgeDownloads)' }
    }

    Write-Step "Бэкапы: $BackupDir"
    if (Test-Path $BackupDir) {
        if ($PurgeBackup) { if (Confirm-Action "Удалить $BackupDir?") { Remove-Item -LiteralPath $BackupDir -Recurse -Force; Write-Host '  ✓ Удалён' } }
        else { Write-Host '  ℹ Сохранён (используйте -PurgeBackup)' }
    }

    Write-Host "`n Удаление завершено." -ForegroundColor Green
}
catch {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
    exit 1
}
if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
