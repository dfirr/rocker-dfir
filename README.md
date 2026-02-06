# rocker-dfir

Rocker (`rocker/tidyverse`) based DFIR-ready R environment with optional CRAN and GitHub packages, plus a reticulate Python setup.

## Requirements

- Docker + Docker Compose v2
- A host directory for cases (default: `~/cases`)

## Setup

1. Create required host paths (already created in this repo by default):
   - `rstudio_config/`
   - `rstudio_etc/rserver.conf`
   - `~/cases/` (or another path set in `.env`)

2. Create `.env` from the sample:
   - `cp .env.sample .env`

3. Edit `.env`:
   - Set `PASSWORD` (required)
   - Edit `r_packages.txt` / `gh_packages.txt` for package lists
   - Adjust bind paths if needed

## Build and Run

```bash
cd /path/to/rocker-dfir

docker compose --env-file .env build

docker compose --env-file .env up -d
```

Access RStudio at `http://localhost:8787` and log in as user `rstudio` with `PASSWORD`.

## Environment Variables (.env)

- `PASSWORD` (required): RStudio password for user `rstudio`
- `R_PACKAGES_FILE`: CRAN package list file (one per line)
- `GH_PACKAGES_FILE`: GitHub package list file (one per line)
- `CASES_DIR`: host path mounted to `/home/rstudio/cases`
- `RSTUDIO_CONFIG_DIR`: host path mounted to `/home/rstudio/.config`
- `RSTUDIO_RSERVER_CONF`: host file mounted to `/etc/rstudio/rserver.conf`

## Notes

- GitHub packages require network access during build.
- `installGithub.r` comes from the Rocker base image (littler).
- If you change `R_PACKAGES` or `GH_PACKAGES`, rebuild the image.
