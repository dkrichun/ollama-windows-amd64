#Requires -Version 5.1
<#
.SYNOPSIS
    Удаление службы Ollama, созданной скриптом ollama-windows-amd64.ps1.

.DESCRIPTION
    Читает ollama-windows-amd64.ini и последовательно:
      1. Останавливает и удаляет службу Windows.
      2. Удаляет правило брандмауэра.
      3. Убирает OllamaDir из Machine PATH (если AddToPath=true).
      4. Сбрасывает Machine-переменные OLLAMA_HOST / OLLAMA_MODELS.
      5. По флагам -PurgeProfile / -PurgeModels удаляет каталоги профиля
         (.ollama) и моделей.
      6. По флагу -PurgeOllama удаляет каталог с бинарниками.
      7. По флагу -PurgeLogs удаляет каталог логов.
    NSSM и сам INI по умолчанию НЕ удаляются.

.PARAMETER ConfigPath
    Путь к INI. По умолчанию — рядом со скриптом.

.PARAMETER PurgeProfile
    Удалить каталог <OllamaHome>\.ollama (с ключом id_ed25519!).

.PARAMETER PurgeModels
    Удалить каталог моделей <ModelsDir>.

.PARAMETER PurgeOllama
    Удалить каталог с бинарниками <OllamaDir>.

.PARAMETER PurgeLogs
    Удалить каталог логов <LogsDir>.

.PARAMETER Force
    Не задавать интерактивных подтверждений.

.PARAMETER NoPause
    Не ждать Enter в конце.

.EXAMPLE
    .\ollama-windows-uninstall.ps1

.EXAMPLE
    .\ollama-windows-uninstall.ps1 -PurgeProfile -PurgeModels -PurgeOllama -PurgeLogs -Force -NoPause
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$PurgeProfile,
    [switch]$PurgeModels,
    [switch]$PurgeOllama,
    [switch]$PurgeLogs,
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
    if ($PurgeProfile) { $argLine += ' -PurgeProfile' }
    if ($PurgeModels)  { $argLine += ' -PurgeModels'  }
    if ($PurgeOllama)  { $argLine += ' -PurgeOllama'  }
    if ($PurgeLogs)    { $argLine += ' -PurgeLogs'    }
    if ($Force)        { $argLine += ' -Force'        }
    if ($NoPause)      { $argLine += ' -NoPause'      }
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

$OllamaDir   = Get-Cfg     'paths'   'OllamaDir'        'D:\AI\Ollama'
$ModelsDir   = Get-Cfg     'paths'   'ModelsDir'        'D:\AI\Models'
$NssmDir     = Get-Cfg     'paths'   'NssmDir'          'C:\Program Files\NSSM'
$LogsDir     = Get-Cfg     'paths'   'LogsDir'          ''
$OllamaHome  = Get-Cfg     'ollama'  'OllamaHome'       $OllamaDir
$ServiceName = Get-Cfg     'service' 'ServiceName'      'Ollama'
$AddToPath   = Get-CfgBool 'service' 'AddToPath'        $true
$Port        = [int](Get-Cfg 'network' 'Port'           '11434')
$FwEnabled   = Get-CfgBool 'network' 'FirewallEnabled'  $true
$FwSubnet    = Get-Cfg     'network' 'FirewallSubnet'   ''

if ([string]::IsNullOrWhiteSpace($LogsDir))    { $LogsDir    = Join-Path $OllamaDir 'logs' }
if ([string]::IsNullOrWhiteSpace($OllamaHome)) { $OllamaHome = $OllamaDir }

function Write-Step([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Confirm-Action([string]$Prompt) {
    if ($Force) { Write-Host "  (Force) $Prompt → да"; return $true }
    $ans = Read-Host "$Prompt [y/N]"
    return ($ans -eq 'y')
}

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

function Remove-FromMachinePath {
    param([string]$Dir)
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($null -eq $current -or $current.Trim() -eq '') {
        Write-Host '  ℹ PATH не задан'
        return
    }
    $parts = $current -split ';' | Where-Object { $_ -ne '' }
    $target = $Dir.TrimEnd('\')
    $kept = $parts | Where-Object { $_.TrimEnd('\') -ne $target }
    if ($kept.Count -eq $parts.Count) {
        Write-Host "  ℹ $Dir в PATH не найден"
        return
    }
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'Machine')
    Write-Host "  ✓ $Dir удалён из PATH"
    Write-Host '  ℹ Изменения вступят в силу в новых консолях.'
}

try {
    # ─── 2. Служба ───
    Write-Step "Служба $ServiceName"
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        $nssmExe = Find-Nssm -Dir $NssmDir
        if (-not $nssmExe) {
            Write-Warning "  nssm.exe не найден в $NssmDir — удаляю через sc.exe"
            & sc.exe stop $ServiceName | Out-Null
            Start-Sleep -Seconds 2
            & sc.exe delete $ServiceName | Out-Null
        } else {
            Write-Host '  → stop'
            & $nssmExe stop $ServiceName 2>&1 | Out-Null
            Start-Sleep -Seconds 1
            Write-Host '  → remove'
            & $nssmExe remove $ServiceName confirm 2>&1 | Out-Null
            Start-Sleep -Seconds 1
        }
        if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
            Write-Warning "  Служба $ServiceName всё ещё присутствует"
        } else {
            Write-Host '  ✓ Служба удалена'
        }
    } else {
        Write-Host '  ℹ Службы нет — пропускаем'
    }

    # ─── 3. Брандмауэр ───
    Write-Step 'Правило брандмауэра'
    $rules = Get-NetFirewallRule -DisplayName "Ollama API*" -ErrorAction SilentlyContinue
    if ($rules) {
        $rules | Remove-NetFirewallRule
        Write-Host "  ✓ Удалено правил: $($rules.Count)"
    } else {
        Write-Host '  ℹ Правил не найдено'
    }

    # ─── 3b. PATH ───
    if ($AddToPath) {
        Write-Step 'Переменная PATH (Machine)'
        Remove-FromMachinePath -Dir $OllamaDir
    } else {
        Write-Host "`n  ℹ AddToPath=false — PATH не трогаем" -ForegroundColor DarkGray
    }

    # ─── 4. Machine-переменные ───
    Write-Step 'Переменные окружения (Machine)'
    foreach ($name in @('OLLAMA_HOST','OLLAMA_MODELS')) {
        $cur = [Environment]::GetEnvironmentVariable($name, 'Machine')
        if ($null -ne $cur) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Machine')
            Write-Host "  ✓ Удалена $name (было: $cur)"
        } else {
            Write-Host "  ℹ $name не задана"
        }
    }

    # ─── 5. Каталог профиля ───
    $profileDir = Join-Path $OllamaHome '.ollama'
    Write-Step "Профиль: $profileDir"
    if (Test-Path $profileDir) {
        if ($PurgeProfile) {
            if (Confirm-Action "Удалить $profileDir (включая id_ed25519)?") {
                Remove-Item -LiteralPath $profileDir -Recurse -Force
                Write-Host '  ✓ Удалён'
            } else {
                Write-Host '  ℹ Сохранён'
            }
        } else {
            Write-Host '  ℹ Сохранён (укажите -PurgeProfile чтобы удалить)'
        }
    } else {
        Write-Host '  ℹ Отсутствует'
    }

    # ─── 6. Каталог моделей ───
    Write-Step "Модели: $ModelsDir"
    if (Test-Path $ModelsDir) {
        if ($PurgeModels) {
            if (Confirm-Action "Удалить $ModelsDir? Это может быть много гигабайт.") {
                Remove-Item -LiteralPath $ModelsDir -Recurse -Force
                Write-Host '  ✓ Удалён'
            } else {
                Write-Host '  ℹ Сохранён'
            }
        } else {
            Write-Host '  ℹ Сохранён (укажите -PurgeModels чтобы удалить)'
        }
    } else {
        Write-Host '  ℹ Отсутствует'
    }

    # ─── 7. Каталог с бинарниками ───
    Write-Step "Бинарники: $OllamaDir"
    if (Test-Path $OllamaDir) {
        $hasProfileInside = ($OllamaDir.TrimEnd('\') -ieq $OllamaHome.TrimEnd('\')) -and (Test-Path $profileDir)
        if ($PurgeOllama) {
            if ($hasProfileInside -and -not $PurgeProfile) {
                Write-Warning "  ⚠ В $OllamaDir лежит .ollama, а -PurgeProfile не задан — пропускаем удаление"
            } elseif (Confirm-Action "Удалить $OllamaDir?") {
                Remove-Item -LiteralPath $OllamaDir -Recurse -Force
                Write-Host '  ✓ Удалён'
            } else {
                Write-Host '  ℹ Сохранён'
            }
        } else {
            Write-Host '  ℹ Сохранён (укажите -PurgeOllama чтобы удалить)'
        }
    } else {
        Write-Host '  ℹ Отсутствует'
    }

    # ─── 8. Логи ───
    Write-Step "Логи: $LogsDir"
    if (Test-Path $LogsDir) {
        if ($PurgeLogs) {
            if (Confirm-Action "Удалить $LogsDir?") {
                Remove-Item -LiteralPath $LogsDir -Recurse -Force
                Write-Host '  ✓ Удалён'
            } else {
                Write-Host '  ℹ Сохранён'
            }
        } else {
            Write-Host '  ℹ Сохранён (укажите -PurgeLogs чтобы удалить)'
        }
    } else {
        Write-Host '  ℹ Отсутствует'
    }

    # ─── Итог ───
    $pProfile = if ($PurgeProfile) { 'удалён' } else { 'сохранён' }
    $pModels  = if ($PurgeModels)  { 'удалён' } else { 'сохранён' }
    $pOllama  = if ($PurgeOllama)  { 'удалён' } else { 'сохранён' }
    $pLogs    = if ($PurgeLogs)    { 'удалён' } else { 'сохранён' }

    Write-Host "`n=============================" -ForegroundColor Green
    Write-Host ' Удаление завершено'         -ForegroundColor Green
    Write-Host '=============================' -ForegroundColor Green
    Write-Host ' Сохранено:'
    Write-Host "   NSSM         : $NssmDir  (не трогаем)"
    Write-Host "   INI          : $ConfigPath"
    Write-Host "   Профиль      : $profileDir  ($pProfile)"
    Write-Host "   Модели       : $ModelsDir   ($pModels)"
    Write-Host "   Бинарники    : $OllamaDir   ($pOllama)"
    Write-Host "   Логи         : $LogsDir     ($pLogs)"
}
catch {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
    exit 1
}

if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' | Out-Null }
