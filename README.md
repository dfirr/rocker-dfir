# rocker-dfir

Rocker (`rocker/tidyverse`) based DFIR-ready R environment with CRAN/GitHub packages, plus a reticulate Python setup that can connect to Splunk via MSTICPy.

This repository supports two runtime modes with one shared image:

- `single-user`: simplest path for personal use
- `multi-user`: host-aligned Linux users with separate homes and a shared working area

## Requirements

- Docker Engine with the `docker compose` plugin
- Network access for image build steps and GitHub package installation

## Modes

### Single-User

Use this when one person will use the container.

Files:

- [compose.yaml](/home/swat/docker/2602rockerdfir/compose.yaml)
- [.env.single.sample](/home/swat/docker/2602rockerdfir/.env.single.sample)

Setup:

1. Create `.env` from the single-user sample:
   - `cp .env.single.sample .env`
2. Create `msticpy_config/msticpyconfig.yaml` from the sample:
   - `cp msticpy_config/msticpyconfig.yaml.sample msticpy_config/msticpyconfig.yaml`
3. Edit `.env`:
   - Set `PASSWORD` to a non-empty value
   - Adjust `CASES_DIR`, `RSTUDIO_CONFIG_DIR`, and other bind paths if needed
4. Build and start:

```bash
docker compose --env-file .env build
docker compose --env-file .env up -d
```

Access RStudio at `http://localhost:8787` and log in as user `rstudio` with `PASSWORD`.

### Multi-User

Use this when several Linux users should log in separately and keep host-aligned ownership on bind-mounted files.

Files:

- [compose.multi.yaml](/home/swat/docker/2602rockerdfir/compose.multi.yaml)
- [.env.sample](/home/swat/docker/2602rockerdfir/.env.sample)
- [rstudio_users/users.conf.sample](/home/swat/docker/2602rockerdfir/rstudio_users/users.conf.sample)

Setup:

1. Create `.env` from the multi-user sample:
   - `cp .env.sample .env`
2. Create the runtime inputs:
   - `cp rstudio_users/users.conf.sample rstudio_users/users.conf`
   - `cp msticpy_config/msticpyconfig.yaml.sample msticpy_config/msticpyconfig.yaml`
   - Create `rstudio_home/` if you want to persist homes inside the repository path
   - Create `${HOME}/cases/` or another directory referenced by `CASES_ROOT_DIR`
   - Create `${HOME}/shared_cases/` or another directory referenced by `SHARED_CASES_DIR`
3. Edit `rstudio_users/users.conf`:
   - Add one line per user in the form `username:uid:gid:password_hash[:shell]`
   - Use the same `uid` and `gid` as the host OS account when you want bind-mounted files to keep natural ownership on the host
   - Generate password hashes with `openssl passwd -6 'replace-with-a-password'`
4. Edit `.env`:
   - Leave `RSTUDIO_BASE_UID` / `RSTUDIO_BASE_GID` below `1000`
   - Set `SHARED_CASES_GROUP_GID` if you want a stable shared group ID on the host
5. Build and start:

```bash
docker compose -f compose.multi.yaml --env-file .env build
docker compose -f compose.multi.yaml --env-file .env up -d
```

Access RStudio at `http://localhost:8787` and log in with one of the usernames defined in `rstudio_users/users.conf`.

If you add or remove users later, update `rstudio_users/users.conf` and recreate the container:

```bash
docker compose -f compose.multi.yaml --env-file .env up -d --force-recreate
```

Example `users.conf`:

```text
swat:1000:1000:$6$rounds=656000$replace$with_a_real_hash:/bin/bash
analyst:1001:1001:$6$rounds=656000$replace$with_a_real_hash:/bin/bash
```

Password hash example:

```bash
openssl passwd -6 'replace-with-a-password'
```

## Shared Image

Both modes use the same [Dockerfile](/home/swat/docker/2602rockerdfir/Dockerfile) and therefore share:

- R packages from [r_packages.txt](/home/swat/docker/2602rockerdfir/r_packages.txt)
- GitHub R packages from [gh_packages.txt](/home/swat/docker/2602rockerdfir/gh_packages.txt)
- Python packages from [pip_requirements.txt](/home/swat/docker/2602rockerdfir/pip_requirements.txt)
- Japanese fonts and RStudio configuration assets
- Corporate CA support through `corp_ca/`
- Git, GitHub CLI, and `openssh-client`

## Single-User Layout

- `/home/rstudio` is the main home directory
- `CASES_DIR` is mounted to `/home/rstudio/cases`
- `RSTUDIO_CONFIG_DIR` is mounted to `/home/rstudio/.config`
- `MSTICPY_CONFIG_FILE` is mounted to `/home/rstudio/.msticpy/msticpyconfig.yaml`

This mode has the lowest setup overhead and is the default mode for this repository.

## Multi-User Layout

- `RSTUDIO_USERS_FILE` is mounted to `/etc/rstudio/users.conf` and processed at container startup
- `RSTUDIO_BASE_UID` / `RSTUDIO_BASE_GID` move the built-in `rstudio` account out of the `1000+` range
- `RSTUDIO_HOME_ROOT` is mounted to `/srv/rstudio-home`; each user home is created under `/srv/rstudio-home/<username>`
- `CASES_ROOT_DIR` is mounted to `/srv/cases`; each user gets `~/cases -> /srv/cases/<username>`
- `SHARED_CASES_DIR` is mounted to `/srv/shared-cases`; each user gets `~/shared_cases -> /srv/shared-cases`
- `RSTUDIO_CONFIG_DIR` is copied into each user's `~/.config` on first startup without overwriting existing files
- `MSTICPY_CONFIG_DIR` is copied into each user's `~/.msticpy` on first startup without overwriting existing files

RStudio defaults `initial_working_directory`, `default_project_location`, and `default_open_project_location` to `~/shared_cases` so shared teaching material is visible immediately after login.

`shared_cases` is managed as a common group-writable directory. Files created there keep the creator's UID and the shared group GID. On the host, ownership is stored numerically, so matching host/container UID and GID values matters.

In practice:

- `~/cases` is for personal work
- `~/shared_cases` is for shared material or collaborative editing

One caveat: `docker exec -u UID:GID ...` does not include supplementary groups, so it is not a faithful test of `shared_cases` access. Real RStudio logins do include the shared group membership.

## GitHub over SSH

SSH is enabled in the image by installing `openssh-client`.

- In single-user mode, the effective user is `rstudio`
- In multi-user mode, each user manages their own `~/.ssh`

Because home directories are bind-mounted or persisted, `~/.ssh` survives container recreation.

Typical workflow after first login:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C "your_email@example.com"
ssh -T git@github.com
```

The default GitHub CLI config sets `git_protocol: ssh`, so Git operations initiated through `gh` prefer SSH. If users want GitHub CLI API access, they should run `gh auth login` in their own session so that `~/.config/gh/hosts.yml` remains user-specific.

## Splunk Connection (MSTICPy)

Single-user mode:

- `msticpy_config/msticpyconfig.yaml` is mounted directly to `/home/rstudio/.msticpy/msticpyconfig.yaml`

Multi-user mode:

- `msticpy_config/` is copied into each user's `~/.msticpy` on first provisioning
- `msticpyconfig.yaml.sample` becomes `msticpyconfig.yaml` on first run if the user does not already have one

To choose the `host` value:

- Splunk Cloud: use the cloud host name
- Splunk Enterprise (on-prem/remote): use the server host name or IP
- Local Docker Splunk: use your host IP; `host.docker.internal` may work on Docker Desktop but often does not on Linux

To get the host IP from inside the container on Linux:

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

## Config Files

Single-user mode variables live in [.env.single.sample](/home/swat/docker/2602rockerdfir/.env.single.sample):

- `PASSWORD`
- `CASES_DIR`
- `RSTUDIO_CONFIG_DIR`
- `RSTUDIO_RSERVER_CONF`
- `MSTICPY_CONFIG_FILE`

Multi-user mode variables live in [.env.sample](/home/swat/docker/2602rockerdfir/.env.sample):

- `RSTUDIO_USERS_FILE`
- `RSTUDIO_BASE_UID`
- `RSTUDIO_BASE_GID`
- `RSTUDIO_HOME_ROOT`
- `CASES_ROOT_DIR`
- `SHARED_CASES_DIR`
- `SHARED_CASES_GROUP_GID`
- `RSTUDIO_CONFIG_DIR`
- `RSTUDIO_RSERVER_CONF`
- `MSTICPY_CONFIG_DIR`

Both modes also use:

- `R_PACKAGES_FILE`
- `GH_PACKAGES_FILE`

## Notes

- GitHub packages require network access during build
- `installGithub.r` comes from the Rocker base image (littler)
- If you change `r_packages.txt`, `gh_packages.txt`, or `corp_ca/*.crt`, rebuild the image
