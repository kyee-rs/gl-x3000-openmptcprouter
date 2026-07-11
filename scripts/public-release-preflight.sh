#!/usr/bin/env bash
# Fail-closed public-repository preflight. It prints filenames, never matching
# secret text. Run from anywhere inside the clean repository staging tree.

set -u

failures=0

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf '%s\n' 'ERROR: run this only inside the clean public Git repository.' >&2
  exit 2
}
cd "$repo_root" || exit 2

for command_name in file git rg; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'ERROR: required command is missing: %s\n' "$command_name" >&2
    exit 2
  fi
done

printf '%s\n' '== Tracked-file deny-list =='
forbidden_path_re='(^|/)(backups?|captures?|diagnostics?|private|local|artifacts?|build_dir|staging_dir|rootfs|sysupgrade-[^/]*)(/|$)|(^|/)(etc/(config|shadow|dropbear)|root/\.ssh)(/|$)'
forbidden_name_re='(^|/)(authorized_keys|known_hosts|id_(rsa|ed25519|ecdsa)(\..*)?|\.env(\..*)?)$'
forbidden_ext_re='\.(bin|img|itb|ubi|ubifs|squashfs|apk|ipk|deb|rpm|ko|raw|qcow2?|vmdk|pcapng?|tar|tgz|tbz2?|txz|gz|bz2|xz|zst|zip|7z|rar|key|pem|p12|pfx|jks|keystore|kdbx|ovpn|log)$'

while IFS= read -r -d '' path; do
  lower_path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower_path" =~ $forbidden_path_re ]] ||
     [[ "$lower_path" =~ $forbidden_name_re ]] ||
     [[ "$lower_path" =~ $forbidden_ext_re ]]; then
    printf 'BLOCKED tracked path: %s\n' "$path" >&2
    failures=1
  fi

  if [[ -f "$path" ]]; then
    size="$(wc -c < "$path" | tr -d '[:space:]')"
    if [[ "$size" =~ ^[0-9]+$ ]] && (( size > 1048576 )); then
      printf 'REVIEW tracked file over 1 MiB: %s\n' "$path" >&2
      failures=1
    fi

    mime_type="$(file -b --mime-type -- "$path")"
    case "$mime_type" in
      text/*|application/json|application/xml|application/x-empty|inode/x-empty) ;;
      *)
        printf 'BLOCKED non-text tracked file: %s (%s)\n' "$path" "$mime_type" >&2
        failures=1
        ;;
    esac
  fi
done < <(git ls-files -z)

special_entries="$(git ls-files -s | awk '$1 == "120000" || $1 == "160000" { print $1, $4 }')"
if [[ -n "$special_entries" ]]; then
  printf '%s\n' 'REVIEW tracked symlinks or submodules:' >&2
  printf '%s\n' "$special_entries" >&2
  failures=1
fi

printf '%s\n' '== Filename-only high-risk pattern scan =='
high_risk_patterns=(
  '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'
  '(?i)(password|passwd|passphrase|psk|pin(code)?|secret|token|api[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:]<>{}]{4,}'
  '(?i)[a-z][a-z0-9+.-]*://[^/@[:space:]]+:[^/@[:space:]]+@'
  '(?i)(sshpass|SSHPASS|expect[[:space:]].*password)'
  '(?i)option[[:space:]]+(password|key|pin|psk|token|secret)[[:space:]]+'
  '(?i)(private_key|preshared_key|wireguard_key)[[:space:]]*[:=]'
)

for pattern in "${high_risk_patterns[@]}"; do
  # The scanner source contains these detection expressions verbatim. It is the
  # only fallback-regex exclusion; gitleaks still scans it normally.
  matches="$(rg -l --no-ignore --hidden --glob '!.git/**' --glob '!**/public-release-preflight.sh' -e "$pattern" .)"
  rg_status=$?
  if (( rg_status > 1 )); then
    printf '%s\n' 'ERROR: high-risk content scan failed.' >&2
    failures=1
    continue
  fi
  if [[ -n "$matches" ]]; then
    printf '%s\n' 'BLOCKED files matching a high-risk pattern:' >&2
    printf '%s\n' "$matches" >&2
    failures=1
  fi
done

printf '%s\n' '== Filename-only identity and endpoint review =='
metadata_patterns=(
  '(?i)(imei|imsi|iccid|msisdn|eid|sim[_ -]?(pin|puk)|serial([ _-]?number)?)[[:space:]]*[:=]'
  '(?i)\b([0-9a-f]{2}:){5}[0-9a-f]{2}\b'
  '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'
  '(?i)\b(ssh|scp|sftp|rsync)[[:space:]]+[^[:space:]]+@'
)

for pattern in "${metadata_patterns[@]}"; do
  matches="$(rg -l --no-ignore --hidden --glob '!.git/**' --glob '!**/public-release-preflight.sh' -e "$pattern" .)"
  rg_status=$?
  if (( rg_status > 1 )); then
    printf '%s\n' 'ERROR: identity and endpoint scan failed.' >&2
    failures=1
    continue
  fi
  if [[ -n "$matches" ]]; then
    printf '%s\n' 'REVIEW files containing identity/endpoint candidates:' >&2
    printf '%s\n' "$matches" >&2
    failures=1
  fi
done

printf '%s\n' '== Gitleaks working-tree and history scan =='
if [[ "${GITLEAKS_PRECHECKED:-0}" == 1 ]]; then
  printf '%s\n' 'Gitleaks scan delegated to the preceding pinned CI action.'
elif ! command -v gitleaks >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: gitleaks is not installed; publication gate remains closed.' >&2
  failures=1
elif gitleaks dir --help >/dev/null 2>&1; then
  gitleaks dir --redact . || failures=1
  gitleaks git --redact . || failures=1
else
  gitleaks detect --source . --no-git --redact || failures=1
  gitleaks detect --source . --redact --log-opts="--all" || failures=1
fi

printf '%s\n' '== Remote URL credential check =='
while IFS= read -r remote; do
  [[ -n "$remote" ]] || continue
  remote_url="$(git remote get-url "$remote" 2>/dev/null || true)"
  if [[ "$remote_url" =~ ://[^/@[:space:]]+@ ]] ||
     [[ "$remote_url" =~ ://[^/@[:space:]]+:[^/@[:space:]]+@ ]] ||
     [[ "$remote_url" =~ (oauth2|x-access-token|access_token|private_token) ]]; then
    printf 'BLOCKED remote URL with embedded identity or credential: %s\n' "$remote" >&2
    failures=1
  fi
done < <(git remote)

printf '%s\n' '== Staged snapshot checks =='
if ! git diff --quiet --; then
  printf '%s\n' 'PUBLICATION BLOCKED: tracked files contain unstaged changes.' >&2
  failures=1
fi

untracked_paths="$(git ls-files --others --exclude-standard)"
if [[ -n "$untracked_paths" ]]; then
  printf '%s\n' 'PUBLICATION BLOCKED: untracked, non-ignored paths are present:' >&2
  printf '%s\n' "$untracked_paths" >&2
  failures=1
fi

# Patch payloads intentionally contain diff-context whitespace; validate their
# syntax separately with `make lint` instead of treating context as new source.
git diff --cached --check -- . ':(exclude)patches/**' || failures=1
git diff --cached --name-status

if (( failures != 0 )); then
  printf '%s\n' 'PUBLICATION BLOCKED: resolve every finding and rerun.' >&2
  exit 1
fi

printf '%s\n' 'Automated preflight passed. A second human review is still required.'
