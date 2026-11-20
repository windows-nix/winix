# Incrementally deliver a built windows-nix folder over SSH or same-host WSL.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: windows-deploy [OPTIONS] <folder> [-- <apply arguments>]

Deliver a built windows-nix folder and optionally apply it.

Options:
  -t, --transport auto|ssh|wsl  Transport (default: WINDOWS_TRANSPORT or auto)
  -H, --host DESTINATION        OpenSSH destination (or WINDOWS_HOST)
  -d, --dir PATH                Windows target folder
                                (default: WINDOWS_DIR or C:\ProgramData\machine-config)
  -m, --mode merge|enforce      merge preserves unmanaged files; enforce prunes them
                                (default: WINDOWS_MODE or merge)
      --apply                   Apply after a successful transfer
  -h, --help                    Show this help

auto selects SSH when a host is set, then WSL when running inside WSL.
Apply arguments belong after --, for example: --apply -- -DryRun -Platform vm.
The legacy "<folder> --apply -DryRun" form is also accepted.

merge/enforce owns only the delivered folder. Neither mode undoes Windows
settings or uninstalls software removed from the Nix configuration. Logs,
markers, locks, and deployment staging directories are always preserved.
EOF
}

fail() {
  echo "windows-deploy: $*" >&2
  exit 2
}

src=''
apply=0
transport=${WINDOWS_TRANSPORT:-auto}
host=${WINDOWS_HOST:-}
dir=${WINDOWS_DIR:-'C:\ProgramData\machine-config'}
mode=${WINDOWS_MODE:-merge}
apply_args=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -t|--transport)
      [ "$#" -ge 2 ] || fail "$1 needs a value"
      transport=$2
      shift 2
      ;;
    -H|--host)
      [ "$#" -ge 2 ] || fail "$1 needs a value"
      host=$2
      shift 2
      ;;
    -d|--dir)
      [ "$#" -ge 2 ] || fail "$1 needs a value"
      dir=$2
      shift 2
      ;;
    -m|--mode)
      [ "$#" -ge 2 ] || fail "$1 needs a value"
      mode=$2
      shift 2
      ;;
    --apply)
      apply=1
      shift
      ;;
    --)
      shift
      apply_args+=("$@")
      break
      ;;
    -*)
      if [ "$apply" = 1 ] && [ -n "$src" ] && [[ "$1" != --* ]]; then
        apply_args+=("$@")
        break
      fi
      fail "unknown option $1 (apply arguments go after --)"
      ;;
    *)
      if [ -z "$src" ]; then
        src=$1
        shift
      else
        apply_args+=("$1")
        shift
      fi
      ;;
  esac
done

[ -n "$src" ] || fail "a built configuration folder is required; try --help"
[ -d "$src" ] || fail "source is not a directory: $src"
case "$transport" in auto|ssh|wsl) ;; *) fail "invalid transport '$transport'" ;; esac
case "$mode" in merge|enforce) ;; *) fail "invalid mode '$mode'" ;; esac
case "$dir" in
  *[$'\r\n\"%']*) fail "WINDOWS_DIR contains an unsupported character" ;;
  *"'"*) fail "WINDOWS_DIR may not contain a single quote" ;;
esac
[[ "$dir" =~ ^[A-Za-z]:\\[^\\] ]] || fail "WINDOWS_DIR must be a non-root absolute path like C:\\ProgramData\\machine-config"

if [ "$transport" = auto ]; then
  if [ -n "$host" ]; then
    transport=ssh
  elif [ -n "${WSL_INTEROP:-}${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    transport=wsl
  else
    fail "cannot auto-select a transport; set --host for SSH or use --transport wsl inside WSL"
  fi
fi
if [ "$transport" = ssh ]; then
  [ -n "$host" ] || fail "SSH transport needs --host or WINDOWS_HOST"
else
  [ -n "${WSL_INTEROP:-}${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null || \
    fail "WSL transport is only available inside WSL"
  command -v powershell.exe >/dev/null 2>&1 || fail "powershell.exe is not on PATH; enable WSL interoperability"
  command -v tar.exe >/dev/null 2>&1 || fail "tar.exe is not on PATH; check the Windows System32 PATH"
fi

for rel in apply.ps1 apply.cmd common.ps1 startup.ps1 items.json machine.json startup.json config.dsc.yaml config.win11.dsc.yaml; do
  [ -f "$src/$rel" ] || fail "source is not a complete build.folder: missing $rel"
done

encode_utf8() {
  printf '%s' "$1" | base64 -w0
}

dir_b64=$(encode_utf8 "$dir")
ps_dir="\$d=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$dir_b64'))"

windows_command() {
  if [ "$transport" = ssh ]; then
    ssh -o BatchMode=yes "$host" "$@"
  else
    "$@"
  fi
}

ps() {
  local enc
  enc=$(printf '%s' "\$ErrorActionPreference='Stop'; \$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8"$'\n'"$1" | iconv -t UTF-16LE | base64 -w0)
  windows_command powershell.exe -NoProfile -NonInteractive -EncodedCommand "$enc" | tr -d '\r'
}

ps_array() {
  local arg b64 first=1
  printf '@('
  for arg in "$@"; do
    b64=$(encode_utf8 "$arg")
    if [ "$first" = 0 ]; then printf ','; fi
    printf "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s'))" "$b64"
    first=0
  done
  printf ')'
}

remote_tar() {
  if [ "$transport" = ssh ]; then
    ssh -o BatchMode=yes "$host" "tar -xf - -C \"$1\""
  else
    tar.exe -xf - -C "$1"
  fi
}

remote=$(ps "$ps_dir; if (Test-Path -LiteralPath \$d) { Get-ChildItem -LiteralPath \$d -Recurse -File | Where-Object { \$_.FullName -notlike (Join-Path \$d 'logs\\*') -and \$_.FullName -notlike (Join-Path \$d '.deploy-*\\*') -and \$_.FullName -ne (Join-Path \$d 'virtio-staged') -and \$_.FullName -ne (Join-Path \$d 'debloat-applied') -and \$_.FullName -ne (Join-Path \$d '.apply.lock') } | ForEach-Object { '{0} {1}' -f (Get-FileHash -LiteralPath \$_.FullName -Algorithm SHA256).Hash.ToLower(), \$_.FullName.Substring(\$d.TrimEnd('\\').Length + 1).Replace('\\','/') } }")

tmp=$(mktemp -d)
stage="$dir\\.deploy-incoming-$$"
stage_created=0
cleanup() {
  rm -rf "$tmp"
  if [ "$stage_created" = 1 ]; then
    ps "$ps_dir; \$s='$stage'; if (Test-Path -LiteralPath \$s) { Remove-Item -LiteralPath \$s -Recurse -Force }" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

mapfile -d '' -t files < <(find "$src" -type f -printf '%P\0' | sort -z)
declare -A expected=()
: > "$tmp/send"
for rel in "${files[@]}"; do
  case "$rel" in *[$'\r\n']*) fail "source filenames may not contain newlines" ;; esac
  expected["$rel"]=1
done

sent=0
for rel in "${files[@]}"; do
  sum=$(sha256sum -- "$src/$rel")
  sum=${sum%% *}
  if ! grep -qxF "$sum $rel" <<<"$remote"; then
    printf '%s\n' "$rel" >> "$tmp/send"
    sent=$((sent + 1))
  fi
done
echo "windows-deploy: transport=$transport mode=$mode; $sent of ${#files[@]} files differ" >&2

if [ "$sent" -gt 0 ]; then
  stage_b64=$(encode_utf8 "$stage")
  ps "$ps_dir; \$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$stage_b64')); if (Test-Path -LiteralPath \$s) { Remove-Item -LiteralPath \$s -Recurse -Force }; New-Item -ItemType Directory -Path \$s -Force | Out-Null" >/dev/null
  stage_created=1
  (cd "$src" && tar -chf - -T "$tmp/send") | remote_tar "$stage"
  ps "$ps_dir; \$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$stage_b64')); Get-ChildItem -LiteralPath \$s -Recurse -File | ForEach-Object { \$rel=\$_.FullName.Substring(\$s.Length + 1); \$dest=Join-Path \$d \$rel; New-Item -ItemType Directory -Path (Split-Path -Parent \$dest) -Force | Out-Null; Copy-Item -LiteralPath \$_.FullName -Destination \$dest -Force; \$_.IsReadOnly=\$false; (Get-Item -LiteralPath \$dest).IsReadOnly=\$false }; Remove-Item -LiteralPath \$s -Recurse -Force" >/dev/null
  stage_created=0
fi

if [ "$mode" = enforce ]; then
  : > "$tmp/stale"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rel=${line#* }
    if [ -z "${expected["$rel"]+x}" ]; then
      printf '%s\n' "$rel" >> "$tmp/stale"
    fi
  done <<< "$remote"
  stale_count=$(wc -l < "$tmp/stale")
  if [ "$stale_count" -gt 0 ]; then
    mapfile -t stale < "$tmp/stale"
    stale_expr=$(ps_array "${stale[@]}")
    ps "$ps_dir; \$stale=$stale_expr; foreach (\$rel in \$stale) { \$p=Join-Path \$d \$rel; if (Test-Path -LiteralPath \$p -PathType Leaf) { \$item=Get-Item -LiteralPath \$p; \$item.IsReadOnly=\$false; Remove-Item -LiteralPath \$p -Force } }; Get-ChildItem -LiteralPath \$d -Recurse -Directory | Sort-Object { \$_.FullName.Length } -Descending | Where-Object { \$_.FullName -notlike (Join-Path \$d 'logs*') -and \$_.FullName -notlike (Join-Path \$d '.deploy-*') } | ForEach-Object { if (@(Get-ChildItem -LiteralPath \$_.FullName -Force).Count -eq 0) { Remove-Item -LiteralPath \$_.FullName -Force } }" >/dev/null
  fi
  echo "windows-deploy: enforce pruned ${stale_count:-0} unmanaged payload files" >&2
fi

if [ "$apply" = 1 ]; then
  args_expr=$(ps_array "${apply_args[@]}")
  ps "$ps_dir; \$a=$args_expr; & (Join-Path \$d 'apply.cmd') @a; exit \$LASTEXITCODE"
fi
