#!/usr/bin/with-contenv bash
set -euo pipefail

USERS_FILE="${RSTUDIO_USERS_FILE_PATH:-/etc/rstudio/users.conf}"
SKEL_CONFIG_DIR="${RSTUDIO_SKEL_CONFIG_DIR:-/etc/rstudio/skel-config}"
SKEL_MSTICPY_DIR="${RSTUDIO_SKEL_MSTICPY_DIR:-/etc/rstudio/skel-msticpy}"
HOME_ROOT="${RSTUDIO_HOME_ROOT_PATH:-/srv/rstudio-home}"
CASES_ROOT="${CASES_ROOT_PATH:-/srv/cases}"
SHARED_CASES_ROOT="${SHARED_CASES_ROOT_PATH:-/srv/shared-cases}"
SHARED_CASES_GROUP="${SHARED_CASES_GROUP_NAME:-rstudio-shared}"
SHARED_CASES_GID="${SHARED_CASES_GROUP_GID:-}"
SHARED_CASES_GROUP_EFFECTIVE=""

log() {
  echo "[provision-users] $*"
}

copy_tree_no_clobber() {
  local src="$1"
  local dst="$2"

  if [[ ! -d "$src" ]]; then
    return 0
  fi

  mkdir -p "$dst"
  cp -a --no-clobber "$src"/. "$dst"/
}

chown_if_exists() {
  local owner="$1"
  shift

  for path in "$@"; do
    if [[ -e "$path" ]]; then
      chown -R "$owner" "$path"
    fi
  done
}

group_name_for_gid() {
  local gid_value="$1"
  local entry

  entry="$(getent group "$gid_value" || true)"
  if [[ -n "$entry" ]]; then
    echo "$entry" | cut -d: -f1
  fi
}

ensure_group() {
  local group_name="$1"
  local gid_value="$2"
  local existing_for_gid

  existing_for_gid="$(group_name_for_gid "$gid_value")"
  if [[ -n "$existing_for_gid" ]]; then
    echo "$existing_for_gid"
    return 0
  fi

  if getent group "$group_name" >/dev/null 2>&1; then
    groupmod -g "$gid_value" "$group_name"
  else
    groupadd -g "$gid_value" "$group_name"
  fi

  echo "$group_name"
}

ensure_shared_group() {
  local existing_for_gid

  if [[ -n "$SHARED_CASES_GID" ]]; then
    existing_for_gid="$(group_name_for_gid "$SHARED_CASES_GID")"
    if [[ -n "$existing_for_gid" ]]; then
      echo "$existing_for_gid"
      return 0
    fi

    if getent group "$SHARED_CASES_GROUP" >/dev/null 2>&1; then
      groupmod -g "$SHARED_CASES_GID" "$SHARED_CASES_GROUP"
    else
      groupadd -g "$SHARED_CASES_GID" "$SHARED_CASES_GROUP"
    fi
    echo "$SHARED_CASES_GROUP"
    return 0
  fi

  if ! getent group "$SHARED_CASES_GROUP" >/dev/null 2>&1; then
    groupadd "$SHARED_CASES_GROUP"
  fi
  echo "$SHARED_CASES_GROUP"
}

ensure_user() {
  local username="$1"
  local uid_value="$2"
  local gid_value="$3"
  local password_hash="$4"
  local shell_path="$5"
  local home_dir="${HOME_ROOT}/${username}"
  local case_dir="${CASES_ROOT}/${username}"
  local primary_group
  local user_group
  local had_gh_hosts=0

  primary_group="$(ensure_group "$username" "$gid_value")"

  if id "$username" >/dev/null 2>&1; then
    log "Updating existing user ${username}"
    usermod -d "$home_dir" -s "$shell_path" -g "$primary_group" "$username"
    if [[ "$(id -u "$username")" != "$uid_value" ]]; then
      usermod -u "$uid_value" "$username"
    fi
  else
    log "Creating user ${username}"
    useradd -m -d "$home_dir" -s "$shell_path" -u "$uid_value" -g "$primary_group" "$username"
  fi

  if [[ -n "$password_hash" ]]; then
    usermod -p "$password_hash" "$username"
  fi

  if getent group staff >/dev/null 2>&1; then
    usermod -a -G staff "$username"
  fi

  user_group="$(id -gn "$username")"

  install -d -m 0755 -o "$username" -g "$user_group" "$home_dir"
  install -d -m 0755 -o "$username" -g "$user_group" "$case_dir"

  if [[ -f "$home_dir/.config/gh/hosts.yml" ]]; then
    had_gh_hosts=1
  fi

  copy_tree_no_clobber "$SKEL_CONFIG_DIR" "$home_dir/.config"
  copy_tree_no_clobber "$SKEL_MSTICPY_DIR" "$home_dir/.msticpy"

  if [[ "$had_gh_hosts" -eq 0 ]] && [[ -f "$SKEL_CONFIG_DIR/gh/hosts.yml" ]]; then
    rm -f "$home_dir/.config/gh/hosts.yml"
  fi

  if [[ -f "$home_dir/.msticpy/msticpyconfig.yaml.sample" ]] && [[ ! -f "$home_dir/.msticpy/msticpyconfig.yaml" ]]; then
    cp -n "$home_dir/.msticpy/msticpyconfig.yaml.sample" "$home_dir/.msticpy/msticpyconfig.yaml"
  fi

  install -d -m 0700 -o "$username" -g "$user_group" "$home_dir/.ssh"
  touch "$home_dir/.ssh/known_hosts"
  chown "$username:$user_group" "$home_dir/.ssh/known_hosts"
  chmod 0600 "$home_dir/.ssh/known_hosts"

  ln -sfn "$case_dir" "$home_dir/cases"
  ln -sfn "$SHARED_CASES_ROOT" "$home_dir/shared_cases"

  chown_if_exists "$username:$user_group" "$home_dir/.config" "$home_dir/.msticpy" "$home_dir/.ssh" "$case_dir"
  chown -h "$username:$user_group" "$home_dir/cases"
  chown -h "$username:$user_group" "$home_dir/shared_cases"
}

main() {
  local line username uid_value gid_value password_hash shell_path shared_group_name
  local -a provisioned_users=()

  install -d -m 0755 "$HOME_ROOT" "$CASES_ROOT"

  if [[ ! -f "$USERS_FILE" ]]; then
    log "No users file found at ${USERS_FILE}; leaving built-in users unchanged"
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    if [[ -z "$line" ]] || [[ "$line" == \#* ]]; then
      continue
    fi

    IFS=':' read -r username uid_value gid_value password_hash shell_path <<<"$line"

    if [[ -z "$username" ]] || [[ -z "${uid_value:-}" ]] || [[ -z "${gid_value:-}" ]] || [[ -z "${password_hash:-}" ]]; then
      log "Skipping invalid entry; expected username:uid:gid:password_hash[:shell]"
      continue
    fi

    if [[ -z "${shell_path:-}" ]]; then
      shell_path="/bin/bash"
    fi

    ensure_user "$username" "$uid_value" "$gid_value" "$password_hash" "$shell_path"
    provisioned_users+=("$username")
  done <"$USERS_FILE"

  shared_group_name="$(ensure_shared_group)"
  SHARED_CASES_GROUP_EFFECTIVE="$shared_group_name"

  if [[ -n "$SHARED_CASES_GID" ]]; then
    groupmod -o -g "$SHARED_CASES_GID" "$shared_group_name"
  fi

  install -d -m 2775 -g "$shared_group_name" "$SHARED_CASES_ROOT"
  chmod 2775 "$SHARED_CASES_ROOT"
  for username in "${provisioned_users[@]}"; do
    usermod -a -G "$shared_group_name" "$username"
  done
  chgrp -R "$shared_group_name" "$SHARED_CASES_ROOT"
  find "$SHARED_CASES_ROOT" -type d -exec chmod 2775 {} +
  find "$SHARED_CASES_ROOT" -type f -exec chmod g+rw {} +

  if command -v setfacl >/dev/null 2>&1; then
    setfacl -b "$SHARED_CASES_ROOT"
    setfacl -m "g:${shared_group_name}:rwx" "$SHARED_CASES_ROOT"
    setfacl -d -m "g:${shared_group_name}:rwx" "$SHARED_CASES_ROOT"
    setfacl -d -m "o::rx" "$SHARED_CASES_ROOT"
  fi
}

main "$@"
