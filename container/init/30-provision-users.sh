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

log() {
  echo "[provision-users] $*"
}

copy_tree_no_clobber() {
  local src="$1"
  local dst="$2"
  local username="$3"

  if [[ ! -d "$src" ]]; then
    return 0
  fi

  # Read administrator defaults as root, but extract only as the target user.
  # Exclude credentials before streaming them into the home.
  tar -C "$src" --exclude='./gh/hosts.yml' -cf - . |
    runuser -u "$username" -- tar --skip-old-files \
      --no-same-owner --no-same-permissions -xf - -C "$dst"
}

initialize_home() {
  set -euo pipefail
  umask 077
  local home_dir="$1" case_dir="$2" shared_dir="$3"
  mkdir -p "$home_dir/R/library" "$home_dir/.config" "$home_dir/.msticpy" "$home_dir/.ssh"
  if [[ ! -e "$home_dir/.Renviron" && ! -L "$home_dir/.Renviron" ]]; then
    printf 'R_LIBS_USER=%s/R/library\nR_LIBS=%s/R/library\n' "$home_dir" "$home_dir" > "$home_dir/.Renviron"
  fi
  # Preserve existing known_hosts, including links, without touching their targets.
  if [[ ! -e "$home_dir/.ssh/known_hosts" && ! -L "$home_dir/.ssh/known_hosts" ]]; then
    touch "$home_dir/.ssh/known_hosts"
  fi
  ln -sfnT "$case_dir" "$home_dir/cases"
  ln -sfnT "$shared_dir" "$home_dir/shared_cases"
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

  primary_group="$(ensure_group "$username" "$gid_value")"

  if id "$username" >/dev/null 2>&1; then
    log "Updating existing user ${username}"
    usermod -d "$home_dir" -s "$shell_path" -g "$primary_group" "$username"
    if [[ "$(id -u "$username")" != "$uid_value" ]]; then
      usermod -u "$uid_value" "$username"
    fi
  else
    log "Creating user ${username}"
    useradd -M -d "$home_dir" -s "$shell_path" -u "$uid_value" -g "$primary_group" "$username"
  fi

  if [[ -n "$password_hash" ]]; then
    usermod -p "$password_hash" "$username"
  fi

  if id -nG "$username" | tr ' ' '\n' | grep -qx staff; then
    gpasswd -d "$username" staff
  fi

  user_group="$(id -gn "$username")"

  [[ ! -L "$home_dir" ]] || { log "Refusing symlink home: ${username}"; exit 1; }
  install -d -m 0700 -o "$username" -g "$user_group" "$home_dir"
  mountpoint -q "$case_dir" || { log "Missing cases bind mount for ${username}"; exit 1; }
  runuser -u "$username" -- bash --noprofile --norc -c \
    "$(declare -f initialize_home); initialize_home \"\$@\"" -- "$home_dir" "$case_dir" "$SHARED_CASES_ROOT"
  copy_tree_no_clobber "$SKEL_CONFIG_DIR" "$home_dir/.config" "$username"
  copy_tree_no_clobber "$SKEL_MSTICPY_DIR" "$home_dir/.msticpy" "$username"
  runuser -u "$username" -- bash --noprofile --norc -c '
    set -euo pipefail
    umask 077
    if [[ -f "$HOME/.msticpy/msticpyconfig.yaml.sample" && ! -e "$HOME/.msticpy/msticpyconfig.yaml" && ! -L "$HOME/.msticpy/msticpyconfig.yaml" ]]; then
      cp -n "$HOME/.msticpy/msticpyconfig.yaml.sample" "$HOME/.msticpy/msticpyconfig.yaml"
    fi'
}

main() {
  local line username uid_value gid_value password_hash shell_path shared_group_name
  local -a provisioned_users=() entries=()
  local -A seen_names=() seen_uids=()

  install -d -m 0755 -o root -g root "$HOME_ROOT" "$CASES_ROOT"

  if [[ ! -f "$USERS_FILE" ]]; then
    if [[ "${RSTUDIO_MULTI_USER:-false}" == true ]]; then
      log "Multi-user mode requires ${USERS_FILE}"; exit 1
    fi
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
      log "Invalid entry; expected username:uid:gid:password_hash[:shell]"; exit 1
    fi

    if [[ -z "${shell_path:-}" ]]; then
      shell_path="/bin/bash"
    fi

    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || [[ "$username" == rstudio ]] ||
       [[ ! "$uid_value" =~ ^[1-9][0-9]*$ ]] || (( uid_value < 1000 )) ||
       [[ ! "$gid_value" =~ ^[1-9][0-9]*$ ]] || (( gid_value < 1000 )) ||
       [[ -n "${seen_names[$username]:-}" || -n "${seen_uids[$uid_value]:-}" ]] ||
       [[ ! -x "$shell_path" ]]; then
      log "Invalid or duplicate account: ${username}"; exit 1
    fi
    seen_names[$username]=1
    seen_uids[$uid_value]=1
    if getent passwd "$username" >/dev/null && [[ "$(id -u "$username")" -lt 1000 ]]; then
      log "Refusing to modify system account ${username}"; exit 1
    fi
    if id "$username" >/dev/null 2>&1 && [[ "$(id -u "$username")" != "$uid_value" ]]; then
      log "UID changes require separate administrator migration: ${username}"; exit 1
    fi
    local uid_owner
    uid_owner="$(getent passwd "$uid_value" | cut -d: -f1 || true)"
    if [[ -n "$uid_owner" && "$uid_owner" != "$username" ]]; then
      log "UID already belongs to ${uid_owner}"; exit 1
    fi
    mountpoint -q "$CASES_ROOT/$username" || { log "Missing cases bind mount for ${username}"; exit 1; }
    entries+=("$username:$uid_value:$gid_value:$password_hash:$shell_path")
    provisioned_users+=("$username")
  done <"$USERS_FILE"

  # Restrict RStudio authentication to explicitly registered accounts.
  getent group rstudio-login >/dev/null || groupadd --system rstudio-login
  gpasswd -M '' rstudio-login
  usermod -L rstudio
  while IFS=: read -r username _ uid_value _ _ home_dir _; do
    if [[ "$home_dir" == "$HOME_ROOT/"* && -z "${seen_names[$username]:-}" ]]; then
      usermod -L -e 1970-01-02 "$username"
    fi
  done < /etc/passwd
  for line in "${entries[@]}"; do
    IFS=':' read -r username uid_value gid_value password_hash shell_path <<< "$line"
    ensure_user "$username" "$uid_value" "$gid_value" "$password_hash" "${shell_path:-/bin/bash}"
    usermod -e '' -a -G rstudio-login "$username"
  done

  shared_group_name="$(ensure_shared_group)"

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

  find "$SHARED_CASES_ROOT" -type d -exec setfacl -m \
    "g:${shared_group_name}:rwx,d:u::rwx,d:g::rwx,d:g:${shared_group_name}:rwx,d:m::rwx,d:o::rx" {} +
}

main "$@"
