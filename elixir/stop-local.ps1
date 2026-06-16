$ErrorActionPreference = "Stop"

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

$bash = @'
set -euo pipefail
if [ ! -f /tmp/symphony-local.pid ]; then
  echo "No Symphony pid file found."
  exit 0
fi

pid="$(cat /tmp/symphony-local.pid)"
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    echo "Symphony pid $pid is still running."
    exit 1
  fi
  echo "Stopped Symphony pid $pid."
else
  echo "Symphony pid $pid was not running."
fi

pkill -TERM -f "/home/gqy47/.npm-global/bin/mimo run" 2>/dev/null || true
pkill -TERM -f "/home/gqy47/.npm-global/bin/mimo acp" 2>/dev/null || true
pkill -TERM -f "[.]mimocode run" 2>/dev/null || true
pkill -TERM -f "[.]mimocode acp" 2>/dev/null || true
sleep 1
pkill -KILL -f "/home/gqy47/.npm-global/bin/mimo run" 2>/dev/null || true
pkill -KILL -f "/home/gqy47/.npm-global/bin/mimo acp" 2>/dev/null || true
pkill -KILL -f "[.]mimocode run" 2>/dev/null || true
pkill -KILL -f "[.]mimocode acp" 2>/dev/null || true
'@

$tempScript = Join-Path ([IO.Path]::GetTempPath()) ("symphony-stop-local-{0}.sh" -f ([guid]::NewGuid()))
[IO.File]::WriteAllText($tempScript, $bash, [Text.UTF8Encoding]::new($false))
$tempScriptWsl = ConvertTo-WslPath $tempScript

try {
  wsl.exe -e bash $tempScriptWsl
} finally {
  Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
}
