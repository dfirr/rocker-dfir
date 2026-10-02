#!/usr/bin/env bash
# Run in a disposable container with mounted /srv/cases/reviewalice and reviewbob.
set -euo pipefail
if [[ "${REVIEW_SINGLE_USER:-0}" == 1 ]]; then
  PASSWORD=test-password RUNROOTLESS=false bash /etc/cont-init.d/02_userconf
  bash /etc/cont-init.d/30-provision-users
  /usr/lib/rstudio-server/bin/rserver --server-daemonize=1 --www-address=127.0.0.1 \
    --auth-encrypt-password=0 --config-file=/review/rstudio_etc/rserver.conf
  /opt/r/bin/python /review/scripts/test-rstudio-login.py rstudio accepted
  runuser -u rstudio -- /opt/r/bin/python -c 'print("Single-user Python works")'
  echo 'Single-user checks passed'
  exit 0
fi
provision_script=/review/container/init/30-provision-users.sh
if [[ "${REVIEW_CHECK_IMAGE:-0}" == 1 ]]; then
  cp /review/rstudio_etc/rserver.multi.conf /etc/rstudio/rserver.conf
  USERID=999 GROUPID=999 PASSWORD=test-base RUNROOTLESS=false bash /etc/cont-init.d/02_userconf
  provision_script=/etc/cont-init.d/30-provision-users
fi
hash="$(openssl passwd -6 test-password)"
groupadd -g 21003 reviewprep
useradd -m -u 21003 -g 21003 -d '/tmp/review prep' reviewprep
bash /review/scripts/prepare-users.sh reviewprep > /tmp/compose.users.json
[[ "$(stat -c '%u:%g:%a' '/tmp/review prep/cases')" == 21003:21003:700 ]]
jq -e '.services["rstudio-server"].volumes[0] | .source == "/tmp/review prep/cases" and .target == "/srv/cases/reviewprep" and .bind.create_host_path == false' /tmp/compose.users.json
chmod 0750 '/tmp/review prep/cases'
bash /review/scripts/prepare-users.sh reviewprep > /tmp/compose.users.json
[[ "$(stat -c %a '/tmp/review prep/cases')" == 750 ]]
! bash /review/scripts/prepare-users.sh reviewprep nonexistent-review-account > /tmp/rejected.json
! bash /review/scripts/prepare-users.sh root > /tmp/rejected.json
mkdir -p /etc/rstudio/skel-config/gh /srv/shared-cases/existing
printf 'secret-token\n' > /etc/rstudio/skel-config/gh/hosts.yml
printf 'initial\n' > /etc/rstudio/skel-config/preferences
printf 'reviewalice:21001:21001:%s:/bin/bash\nreviewbob:21002:21002:%s:/bin/bash\n' "$hash" "$hash" > /etc/rstudio/users.conf
if [[ "${REVIEW_RECREATED:-0}" == 1 ]]; then
  sed -i '/^reviewbob:/d' /etc/rstudio/users.conf
fi
sed -i '1i# Registered users\n' /etc/rstudio/users.conf
before="$(stat -c '%u:%g:%a' /srv/cases/reviewalice)"
bash "$provision_script"
if [[ "${REVIEW_RECREATED:-0}" == 1 ]]; then
  [[ "$(cat /srv/rstudio-home/reviewalice/.config/preferences)" == customized ]]
  [[ -f /srv/rstudio-home/reviewalice/recreation-marker ]]
  ! getent passwd reviewbob >/dev/null
  [[ -d /srv/rstudio-home/reviewbob ]]
  if [[ "${REVIEW_CHECK_IMAGE:-0}" == 1 ]]; then
    /usr/lib/rstudio-server/bin/rserver --server-daemonize=1 --www-address=127.0.0.1 \
      --auth-encrypt-password=0 --config-file=/review/rstudio_etc/rserver.multi.conf
    /opt/r/bin/python /review/scripts/test-rstudio-login.py reviewalice accepted
    /opt/r/bin/python /review/scripts/test-rstudio-login.py reviewbob rejected
  fi
  echo 'Recreated container preserved homes and settings'
  exit 0
fi
[[ "$before" == "$(stat -c '%u:%g:%a' /srv/cases/reviewalice)" ]]
[[ "$(stat -c %a /srv/rstudio-home/reviewalice)" == 700 ]]
[[ ! -e /srv/rstudio-home/reviewalice/.config/gh/hosts.yml ]]
! runuser -u reviewbob -- test -r /srv/rstudio-home/reviewalice/.Renviron
runuser -u reviewalice -- bash -c 'umask 022; echo first > /srv/shared-cases/existing/file; mkdir /srv/shared-cases/existing/new; echo first > /srv/shared-cases/existing/new/file'
runuser -u reviewbob -- bash -c 'echo second >> /srv/shared-cases/existing/file; echo second >> /srv/shared-cases/existing/new/file'
runuser -u reviewalice -- bash -c 'echo customized > "$HOME/.config/preferences"'
bash "$provision_script"
[[ "$(cat /srv/rstudio-home/reviewalice/.config/preferences)" == customized ]]
! id -nG reviewalice | tr ' ' '\n' | grep -qx staff
if [[ "${REVIEW_CHECK_IMAGE:-0}" == 1 ]]; then
  ! runuser -u reviewalice -- test -w /opt/r
  runuser -u reviewalice -- Rscript -e 'print(.libPaths()); print(Sys.getenv(c("R_LIBS", "R_LIBS_USER", "R_LIBS_SITE"))); stopifnot(Sys.getenv("R_LIBS_USER") == file.path(Sys.getenv("HOME"), "R/library")); stopifnot(file.access(.libPaths()[1], 2) == 0); stopifnot(file.access("/usr/local/lib/R/site-library", 2) != 0)'
  runuser -u reviewalice -- uv venv /srv/rstudio-home/reviewalice/.venvs/analysis --python /opt/r/bin/python
  runuser -u reviewalice -- /srv/rstudio-home/reviewalice/.venvs/analysis/bin/python -c 'print("Personal Python environment works")'
fi
if [[ "${REVIEW_CHECK_WEB:-${REVIEW_CHECK_IMAGE:-0}}" == 1 ]]; then
  /usr/lib/rstudio-server/bin/rserver --server-daemonize=1 --www-address=127.0.0.1 \
    --auth-encrypt-password=0 --config-file=/review/rstudio_etc/rserver.multi.conf
  /opt/r/bin/python /review/scripts/test-rstudio-login.py reviewalice accepted
  /opt/r/bin/python /review/scripts/test-rstudio-login.py reviewbob accepted
fi
sed -i '/^reviewbob:/d' /etc/rstudio/users.conf
bash "$provision_script"
[[ "$(getent shadow reviewbob | cut -d: -f2)" == '!'* ]]
! getent group rstudio-login | cut -d: -f4 | grep -q reviewbob
[[ -d /srv/rstudio-home/reviewbob && -d /srv/cases/reviewbob ]]
if [[ "${REVIEW_CHECK_WEB:-${REVIEW_CHECK_IMAGE:-0}}" == 1 ]]; then
  /opt/r/bin/python /review/scripts/test-rstudio-login.py reviewbob rejected
fi
# Root must never follow user-owned links while preparing settings.
install -m 0600 /dev/null /tmp/review-protected-file
runuser -u reviewalice -- ln -sfn /tmp/review-protected-file /srv/rstudio-home/reviewalice/.ssh/known_hosts
runuser -u reviewalice -- mv /srv/rstudio-home/reviewalice/.Renviron /srv/rstudio-home/reviewalice/.Renviron.saved
runuser -u reviewalice -- ln -s /tmp/review-dangling-target /srv/rstudio-home/reviewalice/.Renviron
bash "$provision_script"
[[ "$(stat -c '%u:%g:%a' /tmp/review-protected-file)" == 0:0:600 ]]
[[ ! -e /tmp/review-dangling-target ]]
[[ -L /srv/rstudio-home/reviewalice/.ssh/known_hosts && -L /srv/rstudio-home/reviewalice/.Renviron ]]
runuser -u reviewalice -- unlink /srv/rstudio-home/reviewalice/.Renviron
runuser -u reviewalice -- mv /srv/rstudio-home/reviewalice/.Renviron.saved /srv/rstudio-home/reviewalice/.Renviron
runuser -u reviewalice -- touch /srv/rstudio-home/reviewalice/recreation-marker
echo 'Provisioning checks passed'
