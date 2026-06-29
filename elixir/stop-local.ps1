[CmdletBinding()]
param(
  [int]$Port = 0
)

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

if ($Port -gt 0) {
  $pidFilesExpression = "printf '%s\n' /tmp/symphony-local-$Port.pid"
} else {
  $pidFilesExpression = "find /tmp -maxdepth 1 \( -name 'symphony-local.pid' -o -name 'symphony-local-*.pid' \) -print"
}

$bash = @"
set -euo pipefail
found=0

while IFS= read -r pid_file; do
  [ -n "`$pid_file" ] || continue
  [ -f "`$pid_file" ] || continue
  found=1

  pid="`$(cat "`$pid_file")"
  if kill -0 "`$pid" 2>/dev/null; then
    kill "`$pid" 2>/dev/null || true
    sleep 1
    if kill -0 "`$pid" 2>/dev/null; then
      echo "Symphony pid `$pid is still running."
      exit 1
    fi
    echo "Stopped Symphony pid `$pid from `$pid_file."
  else
    echo "Symphony pid `$pid from `$pid_file was not running."
  fi

  rm -f "`$pid_file"
done < <($pidFilesExpression)

if [ "`$found" -eq 0 ]; then
  echo "No Symphony pid file found."
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
"@

$tempScript = Join-Path ([IO.Path]::GetTempPath()) ("symphony-stop-local-{0}.sh" -f ([guid]::NewGuid()))
[IO.File]::WriteAllText($tempScript, $bash, [Text.UTF8Encoding]::new($false))
$tempScriptWsl = ConvertTo-WslPath $tempScript

try {
  wsl.exe -e bash $tempScriptWsl
} finally {
  Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
}
