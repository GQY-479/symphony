$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$elixirRoot = Resolve-Path (Join-Path $scriptRoot "..")
$startScript = Join-Path $elixirRoot "start-local.ps1"
$workflow = Join-Path $elixirRoot "WORKFLOW.local.md"
$keyFile = Join-Path ([IO.Path]::GetTempPath()) ("symphony-linear-key-{0}.txt" -f ([guid]::NewGuid()))

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Match {
  param(
    [string]$Value,
    [string]$Pattern,
    [string]$Message
  )

  if ($Value -notmatch $Pattern) {
    throw "$Message`nExpected pattern: $Pattern`nActual:`n$Value"
  }
}

try {
  Set-Content -LiteralPath $keyFile -NoNewline -Value "lin_api_test_token"

  $previousCodexApiKey = [Environment]::GetEnvironmentVariable("CODEX_API_KEY", "Process")
  $previousLinearApiKey = [Environment]::GetEnvironmentVariable("LINEAR_API_KEY", "Process")
  [Environment]::SetEnvironmentVariable("CODEX_API_KEY", "codex_test_token", "Process")
  [Environment]::SetEnvironmentVariable("LINEAR_API_KEY", $null, "Process")

  $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $startScript `
    -Preflight `
    -Workflow $workflow `
    -LinearApiKeyFile $keyFile `
    -Port 49876 2>&1

  $exitCode = $LASTEXITCODE
  $text = ($output | Out-String)

  Assert-True ($exitCode -eq 0) "start-local.ps1 -Preflight should exit successfully."
  Assert-Match $text "Preflight OK" "Preflight output should report success."
  Assert-Match $text "Workflow:" "Preflight output should include workflow path."
  Assert-Match $text "LINEAR_API_KEY source:" "Preflight output should include Linear key source."
  Assert-Match $text "WSL:" "Preflight output should include WSL check."
  Assert-Match $text "Runtime:" "Preflight output should include runtime check."
  Assert-Match $text "Port 49876:" "Preflight output should include port check."
  Assert-True (-not ($text -match "lin_api_test_token|codex_test_token")) "Preflight must not print API key values."
} finally {
  if (Test-Path -LiteralPath $keyFile) {
    Remove-Item -LiteralPath $keyFile -Force
  }

  [Environment]::SetEnvironmentVariable("CODEX_API_KEY", $previousCodexApiKey, "Process")
  [Environment]::SetEnvironmentVariable("LINEAR_API_KEY", $previousLinearApiKey, "Process")
}
