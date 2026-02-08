#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="/usr/local/share/ca-certificates/corp"
if [ -d "${CERT_DIR}" ] && find "${CERT_DIR}" -type f -name '*.crt' -print -quit | grep -q .; then
  update-ca-certificates
fi

exec "$@"
