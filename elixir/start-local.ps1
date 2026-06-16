[CmdletBinding()]
param(
  [string]$Workflow,
  [int]$Port = 4000,
  [string]$LinearApiKeyFile,
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Workflow)) {
  $Workflow = Join-Path $PSScriptRoot "WORKFLOW.local.md"
}

if ([string]::IsNullOrWhiteSpace($LinearApiKeyFile)) {
  $LinearApiKeyFile = Join-Path $HOME ".linear_api_key"
}

function Get-EnvValue {
  param([string]$Name)

  foreach ($scope in @("Process", "User", "Machine")) {
    $value = [Environment]::GetEnvironmentVariable($Name, $scope)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
  }

  return $null
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
  if (-not [string]::IsNullOrWhiteSpace($envValue)) {
    return @{ Value = $envValue; Source = "environment" }
  }

  $fileValue = Get-FileValue $KeyFile
  if (-not [string]::IsNullOrWhiteSpace($fileValue)) {
    return @{ Value = $fileValue; Source = "file" }
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

if (-not (Test-Path -LiteralPath $Workflow)) {
  throw "Workflow file not found: $Workflow"
}

$codexApiKey = Get-EnvValue "CODEX_API_KEY"
if ([string]::IsNullOrWhiteSpace($codexApiKey)) {
  throw "CODEX_API_KEY is not set in Process, User, or Machine environment."
}

$linearApiKeyInfo = Resolve-LinearApiKey -KeyFile $LinearApiKeyFile -AllowPrompt:(-not $CheckOnly)
$linearApiKey = $linearApiKeyInfo.Value

if ([string]::IsNullOrWhiteSpace($linearApiKey)) {
  throw "LINEAR_API_KEY is required. Set it in the environment, pass -LinearApiKeyFile, or create $LinearApiKeyFile."
}

if ($CheckOnly) {
  Write-Host "Workflow: $Workflow"
  Write-Host "CODEX_API_KEY source: environment"
  Write-Host ("LINEAR_API_KEY source: {0}" -f $linearApiKeyInfo.Source)
  Write-Host "Preflight OK. Symphony was not started."
  return
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$repoRootWsl = ConvertTo-WslPath $repoRoot
$workflowWsl = ConvertTo-WslPath $Workflow
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
if [ -f /tmp/symphony-local.pid ]; then
  old_pid=`$(cat /tmp/symphony-local.pid)
  if kill -0 "`$old_pid" 2>/dev/null; then
    kill "`$old_pid" 2>/dev/null || true
    sleep 1
  fi
fi
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
  nohup "`$MISE_BIN" exec -- ./bin/symphony '$workflowWsl' --port $Port --i-understand-that-this-will-be-running-without-the-usual-guardrails > /tmp/symphony-local.log 2>&1 &
else
  mix escript.build
  nohup ./bin/symphony '$workflowWsl' --port $Port --i-understand-that-this-will-be-running-without-the-usual-guardrails > /tmp/symphony-local.log 2>&1 &
fi
echo `$! > /tmp/symphony-local.pid
sleep 1
cat /tmp/symphony-local.pid
"@

$tempScript = Join-Path ([IO.Path]::GetTempPath()) ("symphony-start-local-{0}.sh" -f ([guid]::NewGuid()))
[IO.File]::WriteAllText($tempScript, $bash, [Text.UTF8Encoding]::new($false))
$tempScriptWsl = ConvertTo-WslPath $tempScript

try {
  $pidText = (wsl.exe -e bash $tempScriptWsl).Trim()
} finally {
  Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
}
Write-Host "Symphony started on http://127.0.0.1:$Port/ (pid $pidText)"
Write-Host "Logs: wsl.exe -e bash -lc 'tail -f /tmp/symphony-local.log'"
