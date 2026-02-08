# rocker-dfir

Rocker (`rocker/tidyverse`) based DFIR-ready R environment with CRAN/GitHub packages, plus a reticulate Python setup that can connect to Splunk via MSTICPy.

## Requirements

- Docker + Docker Compose v2
- A host directory for cases (default: `~/cases`)

## Setup

1. Create required host paths (already created in this repo by default):
   - `rstudio_config/`
   - `rstudio_etc/rserver.conf`
   - `corp_ca/` (optional; use this only in SSL/TLS inspection or internal CA environments, and place `.crt` files here)
   - `msticpy_config/msticpyconfig.yaml` (copy from sample)
   - `~/cases/` (or another path set in `.env`)

2. Create `.env` from the sample:
   - `cp .env.sample .env`

3. Edit `.env`:
   - Set `PASSWORD` (required)
   - Edit `r_packages.txt` / `gh_packages.txt` for package lists
   - Copy `msticpy_config/msticpyconfig.yaml.sample` to `msticpy_config/msticpyconfig.yaml` and fill Splunk details
   - If required, put corporate CA `.crt` files under `corp_ca/`
   - Adjust bind paths if needed

## Build and Run

```bash
cd /path/to/rocker-dfir

docker compose --env-file .env build

docker compose --env-file .env up -d
```

Access RStudio at `http://localhost:8787` and log in as user `rstudio` with `PASSWORD`.

## Splunk Connection (MSTICPy)

1. Copy and edit the config:
   - `cp msticpy_config/msticpyconfig.yaml.sample msticpy_config/msticpyconfig.yaml`
   - Set `host`, `port`, and authentication
   - For security, prefer `bearer_token` over `password` when possible

2. Choose the `host` value:
   - Splunk Cloud: use the cloud host name.
   - Splunk Enterprise (on-prem/remote): use the server host name or IP.
   - Local Docker Splunk: use your host IP (Docker Desktop may support `host.docker.internal`, but Linux often does not).

   To get the host IP from inside the container (Linux):
   - Run:
```bash
docker exec -t rss bash -lc "/opt/r/bin/python - <<'PY'
import socket, struct
with open('/proc/net/route') as f:
    for line in f.readlines()[1:]:
        fields = line.strip().split()
        if fields[1] != '00000000':
            continue
        gw_hex = fields[2]
        gw = socket.inet_ntoa(struct.pack('<L', int(gw_hex, 16)))
        print(gw)
        break
PY"
```

3. Test the connection:
   - Run:
```bash
docker exec -t rss bash -lc "MSTICPYCONFIG=/home/rstudio/.msticpy/msticpyconfig.yaml /opt/r/bin/python - <<'PY'
from msticpy.data import QueryProvider
qp = QueryProvider('Splunk')
qp.connect()
print('connected')
PY"
```

## Environment Variables (.env)

- `PASSWORD` (required): RStudio password for user `rstudio`
- `R_PACKAGES_FILE`: CRAN package list file (one per line)
- `GH_PACKAGES_FILE`: GitHub package list file (one per line)
- `CASES_DIR`: host path mounted to `/home/rstudio/cases`
- `RSTUDIO_CONFIG_DIR`: host path mounted to `/home/rstudio/.config`
- `RSTUDIO_RSERVER_CONF`: host file mounted to `/etc/rstudio/rserver.conf`
- `CORP_CA_DIR`: host directory mounted to `/usr/local/share/ca-certificates/corp`
- `MSTICPY_CONFIG_FILE`: host file mounted to `/home/rstudio/.msticpy/msticpyconfig.yaml`

## Notes

- GitHub packages require network access during build.
- `installGithub.r` comes from the Rocker base image (littler).
- If you change `r_packages.txt` or `gh_packages.txt`, rebuild the image.
