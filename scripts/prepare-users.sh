#!/usr/bin/env bash
set -euo pipefail

# Usage: sudo bash scripts/prepare-users.sh alice bob > compose.users.yaml
# Account hashes are entered separately in rstudio_users/users.conf.
[[ "$EUID" -eq 0 && "$#" -gt 0 ]] || {
  echo 'Usage: sudo bash scripts/prepare-users.sh USER... > compose.users.yaml' >&2
  exit 1
}
command -v jq >/dev/null
declare -a names=() uids=() gids=() homes=()
declare -A seen=()
for username in "$@"; do
  [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ && "$username" != rstudio && -z "${seen[$username]:-}" ]] || exit 1
  entry="$(getent passwd "$username")" || { echo "Unknown account: $username" >&2; exit 1; }
  IFS=: read -r name _ uid gid _ account_home _ <<< "$entry"
  [[ "$uid" -ge 1000 && "$gid" -ge 1000 && "$account_home" == /* && "$account_home" != / && -d "$account_home" ]] || exit 1
  [[ ! -L "$account_home/cases" ]] || { echo "Symlink cases directory rejected: $name" >&2; exit 1; }
  if [[ -e "$account_home/cases" && ! -d "$account_home/cases" ]]; then
    echo "Not a directory: $account_home/cases" >&2; exit 1
  fi
  seen[$username]=1
  names+=("$name"); uids+=("$uid"); gids+=("$gid"); homes+=("$account_home")
done
volumes='[]'
for i in "${!names[@]}"; do
  cases="${homes[$i]}/cases"
  if [[ ! -d "$cases" ]]; then
    runuser -u "${names[$i]}" -- bash --noprofile --norc -c \
      'umask 077; mkdir -- "$1"' -- "$cases"
  fi
  printf '%s:%s:%s:<password_hash>:/bin/bash\n' "${names[$i]}" "${uids[$i]}" "${gids[$i]}" >&2
  volumes="$(jq --arg source "$cases" --arg target "/srv/cases/${names[$i]}" \
    '. + [{type:"bind",source:$source,target:$target,bind:{create_host_path:false}}]' <<< "$volumes")"
done
# JSON is valid YAML; jq safely escapes paths.
jq -n --argjson volumes "$volumes" '{services:{"rstudio-server":{volumes:$volumes}}}'
