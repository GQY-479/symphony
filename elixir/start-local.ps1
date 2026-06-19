[CmdletBinding()]
param(
  [string]$Workflow,
  [int]$Port = 4000,
  [string]$LinearApiKeyFile,
  [switch]$Preflight,
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Workflow)) {
  $Workflow = Join-Path $PSScriptRoot "WORKFLOW.local.md"
}

if ([string]::IsNullOrWhiteSpace($LinearApiKeyFile)) {
  $LinearApiKeyFile = Join-Path $HOME ".linear_api_key"
}

$preflightOnly = $Preflight -or $CheckOnly

function Get-EnvValue {
  param([string]$Name)

  foreach ($scope in @("Process", "User", "Machine")) {
    $value = [Environment]::GetEnvironmentVariable($Name, $scope)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return @{ Value = $value; Source = "environment:$scope" }
    }
  }

  return @{ Value = $null; Source = "missing" }
}

function Get-FileValue {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  foreach ($line in [IO.File]::ReadLines($Path)) {
    $value = $line.Trim()
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
  }

  return $null
}

function ConvertTo-PlainText {
  param([System.Security.SecureString]$SecureString)

  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function ConvertTo-WslPath {
  param([string]$Path)

  $fullPath = [IO.Path]::GetFullPath($Path)
  if ($fullPath -match "^([A-Za-z]):\\(.*)$") {
    $drive = $Matches[1].ToLowerInvariant()
    $rest = $Matches[2] -replace "\\", "/"
    return "/mnt/$drive/$rest"
  }

  throw "Cannot convert path to WSL path: $Path"
}

function Resolve-LinearApiKey {
  param(
    [string]$KeyFile,
    [bool]$AllowPrompt
  )

  $envValue = Get-EnvValue "LINEAR_API_KEY"
  if (-not [string]::IsNullOrWhiteSpace($envValue.Value)) {
    return $envValue
  }

  $fileValue = Get-FileValue $KeyFile
  if (-not [string]::IsNullOrWhiteSpace($fileValue)) {
    return @{ Value = $fileValue; Source = "file:$KeyFile" }
  }

  if ($AllowPrompt) {
    $secureLinearApiKey = Read-Host "LINEAR_API_KEY" -AsSecureString
    $promptValue = ConvertTo-PlainText $secureLinearApiKey

    if (-not [string]::IsNullOrWhiteSpace($promptValue)) {
      return @{ Value = $promptValue; Source = "prompt" }
    }
  }

  return @{ Value = $null; Source = "missing" }
}

function Test-LocalPortAvailable {
  param([int]$Port)

  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
  try {
    $listener.Start()
    return @{ Ok = $true; Message = "available" }
  } catch {
    return @{ Ok = $false; Message = $_.Exception.Message }
  } finally {
    try {
      $listener.Stop()
    } catch {
    }
  }
}

function Invoke-WslBash {
  param([string]$Script)

  $tempScript = Join-Path ([IO.Path]::GetTempPath()) ("symphony-local-{0}.sh" -f ([guid]::NewGuid()))
  [IO.File]::WriteAllText($tempScript, $Script, [Text.UTF8Encoding]::new($false))
  $tempScriptWsl = ConvertTo-WslPath $tempScript

  try {
    return wsl.exe -e bash $tempScriptWsl
  } finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
  }
}

function Test-WslRuntime {
  param([string]$RepoRootWsl)

  $bash = @"
set -euo pipefail
cd '$RepoRootWsl/elixir'
if ! command -v bash >/dev/null 2>&1; then
  echo "bash missing"
  exit 2
fi

MISE_BIN=""
for candidate in mise "`$HOME/.local/bin/mise" "`$HOME/.mise/bin/mise"; do
  if command -v "`$candidate" >/dev/null 2>&1; then
    MISE_BIN="`$(command -v "`$candidate")"
    break
  fi
done

if [ -n "`$MISE_BIN" ]; then
  "`$MISE_BIN" exec -- mix --version >/dev/null
  echo "mise + mix"
else
  command -v mix >/dev/null
  mix --version >/dev/null
  echo "mix"
fi
"@

  $output = Invoke-WslBash $bash
  return (($output | Out-String).Trim())
}

if (-not (Test-Path -LiteralPath $Workflow -PathType Leaf)) {
  throw "Workflow file not found: $Workflow"
}

$workflowFullPath = [IO.Path]::GetFullPath($Workflow)
$repoRoot = Split-Path -Parent $PSScriptRoot
$repoRootWsl = ConvertTo-WslPath $repoRoot
$workflowWsl = ConvertTo-WslPath $workflowFullPath

$codexApiKeyInfo = Get-EnvValue "CODEX_API_KEY"
$codexApiKey = $codexApiKeyInfo.Value
if ([string]::IsNullOrWhiteSpace($codexApiKey)) {
  throw "CODEX_API_KEY is not set in Process, User, or Machine environment."
}

$linearApiKeyInfo = Resolve-LinearApiKey -KeyFile $LinearApiKeyFile -AllowPrompt:(-not $preflightOnly)
$linearApiKey = $linearApiKeyInfo.Value

if ([string]::IsNullOrWhiteSpace($linearApiKey)) {
  throw "LINEAR_API_KEY is required. Set it in the environment, pass -LinearApiKeyFile, or create $LinearApiKeyFile."
}

$runtime = $null

try {
  $wslKernel = (wsl.exe -e uname -srm | Out-String).Trim()
  $wslStatus = "available ($wslKernel)"
  $runtime = Test-WslRuntime -RepoRootWsl $repoRootWsl
} catch {
  throw "WSL or Elixir runtime preflight failed: $($_.Exception.Message)"
}

if ($preflightOnly) {
  $portCheck = Test-LocalPortAvailable -Port $Port
  Write-Host "Workflow: $workflowFullPath"
  Write-Host ("CODEX_API_KEY source: {0}" -f $codexApiKeyInfo.Source)
  Write-Host ("LINEAR_API_KEY source: {0}" -f $linearApiKeyInfo.Source)
  Write-Host ("WSL: {0}" -f $wslStatus)
  Write-Host ("Runtime: {0}" -f $runtime)
  Write-Host ("Port {0}: {1}" -f $Port, $portCheck.Message)
  if (-not $portCheck.Ok) {
    throw "Port $Port is already in use. Symphony was not started."
  }
  Write-Host "Preflight OK. Symphony was not started."
  Write-Host "Preflight passed; Symphony was not started."
  return
}

$stopBash = @"
set -euo pipefail
pid_file="/tmp/symphony-local-$Port.pid"
legacy_pid_file="/tmp/symphony-local.pid"

stop_pid_file() {
  local file="`$1"
  if [ -f "`$file" ]; then
    old_pid="`$(cat "`$file")"
    if kill -0 "`$old_pid" 2>/dev/null; then
      kill "`$old_pid" 2>/dev/null || true
      sleep 1
    fi
    rm -f "`$file"
  fi
}

stop_pid_file "`$pid_file"
if [ "$Port" = "4000" ]; then
  stop_pid_file "`$legacy_pid_file"
fi
"@

Invoke-WslBash $stopBash | Out-Null

$portCheck = Test-LocalPortAvailable -Port $Port
if (-not $portCheck.Ok) {
  throw "Port $Port is already in use. Symphony was not started: $($portCheck.Message)"
}

$previousWslEnv = $env:WSLENV
$env:CODEX_API_KEY = $codexApiKey
$env:LINEAR_API_KEY = $linearApiKey
$wslEnvNames = @("CODEX_API_KEY", "LINEAR_API_KEY")
if (-not [string]::IsNullOrWhiteSpace($previousWslEnv)) {
  $wslEnvNames += ($previousWslEnv -split ":")
}
$env:WSLENV = (($wslEnvNames |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
  ForEach-Object { $_.Trim(":") } |
  Where-Object { $_ -ne "" } |
  Select-Object -Unique) -join ":")

$bash = @"
set -euo pipefail
pid_file="/tmp/symphony-local-$Port.pid"
log_file="/tmp/symphony-local-$Port.log"

cd '$repoRootWsl/elixir'
MISE_BIN=""
for candidate in mise "`$HOME/.local/bin/mise" "`$HOME/.mise/bin/mise"; do
  if command -v "`$candidate" >/dev/null 2>&1; then
    MISE_BIN="`$(command -v "`$candidate")"
    break
  fi
done

if [ -n "`$MISE_BIN" ]; then
  "`$MISE_BIN" exec -- mix escript.build
  nohup "`$MISE_BIN" exec -- ./bin/symphony '$workflowWsl' --port $Port --i-understand-that-this-will-be-running-without-the-usual-guardrails > "`$log_file" 2>&1 &
else
  mix escript.build
  nohup ./bin/symphony '$workflowWsl' --port $Port --i-understand-that-this-will-be-running-without-the-usual-guardrails > "`$log_file" 2>&1 &
fi
echo `$! > "`$pid_file"
sleep 1
cat "`$pid_file"
"@

$startOutput = (Invoke-WslBash $bash | Out-String).Trim()
$pidText = (($startOutput -split "`r?`n") | Where-Object { $_ -match "^\d+$" } | Select-Object -Last 1)
if ([string]::IsNullOrWhiteSpace($pidText)) {
  throw "Symphony start did not return a pid. Output: $startOutput"
}
Write-Host "Symphony started on http://127.0.0.1:$Port/ (pid $pidText)"
Write-Host "Log: wsl.exe -e bash -lc 'tail -f /tmp/symphony-local-$Port.log'"
