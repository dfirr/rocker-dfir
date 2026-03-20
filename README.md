# rocker-dfir

Rocker (`rocker/tidyverse`) based DFIR-ready R environment with CRAN/GitHub packages, plus a reticulate Python setup that can connect to Splunk via MSTICPy.

This repository now provisions RStudio Server system users at container startup. Each user gets a persistent home directory, their own `~/.ssh`, a personal `~/cases` directory, and a shared `~/shared_cases` directory that is the default landing location in RStudio.

The intended model is:

- Use host-aligned Linux users with `uid >= 1000`
- Keep each user's home, SSH keys, and private casework separate
- Keep course material and collaborative files under `shared_cases`

## Requirements

- Docker Engine with the `docker compose` plugin
- A host path for the per-user cases root (default: `~/cases`)
- A host path for the shared cases root (default: `~/shared_cases`)

## Setup

1. Create `.env` from the sample:
   - `cp .env.sample .env`

2. Create the runtime inputs:
   - `cp rstudio_users/users.conf.sample rstudio_users/users.conf`
   - `cp msticpy_config/msticpyconfig.yaml.sample msticpy_config/msticpyconfig.yaml`
   - Create `rstudio_home/` if you want to persist user homes inside the repository path
   - Create `${HOME}/cases/` or another directory referenced by `CASES_ROOT_DIR`
   - Create `${HOME}/shared_cases/` or another directory referenced by `SHARED_CASES_DIR`

3. Edit `rstudio_users/users.conf`:
   - Add one line per user in the form `username:uid:gid:password_hash[:shell]`
   - Use the same `uid` and `gid` as the host OS account when you want bind-mounted files to keep natural ownership on the host
   - Generate password hashes with `openssl passwd -6 'replace-with-a-password'`

Example:

```text
swat:1000:1000:$6$rounds=656000$replace$with_a_real_hash:/bin/bash
analyst:1001:1001:$6$rounds=656000$replace$with_a_real_hash:/bin/bash
```

Password hash example:

```bash
openssl passwd -6 'replace-with-a-password'
```

4. Edit `.env`:
   - Adjust bind paths if needed
   - Leave `RSTUDIO_BASE_UID` / `RSTUDIO_BASE_GID` below `1000` so host-aligned users can safely occupy `1000+`
   - Edit `r_packages.txt` / `gh_packages.txt` for package lists
   - If required, put corporate CA `.crt` files under `corp_ca/` and rebuild the image

5. Edit `msticpy_config/msticpyconfig.yaml`:
   - Set `host`, `port`, and authentication
   - Prefer `bearer_token` over `password` when possible

## Build and Run

The Compose file in this repository is `compose.yaml`.

```bash
cd /path/to/rocker-dfir
docker compose --env-file .env build
docker compose --env-file .env up -d
```

Access RStudio at `http://localhost:8787` and log in with one of the usernames defined in `rstudio_users/users.conf`.

If you add or remove users later, update `rstudio_users/users.conf` and recreate the container:

```bash
docker compose --env-file .env up -d --force-recreate
```

## Multi-User Layout

- `RSTUDIO_USERS_FILE` is mounted to `/etc/rstudio/users.conf` and processed at container startup.
- `RSTUDIO_BASE_UID` / `RSTUDIO_BASE_GID` move the image's built-in `rstudio` account out of the `1000+` range so host-aligned users can reuse their normal UID/GID values.
- `RSTUDIO_HOME_ROOT` is mounted to `/srv/rstudio-home`; each user home is created under `/srv/rstudio-home/<username>`.
- `CASES_ROOT_DIR` is mounted to `/srv/cases`; each user gets `~/cases -> /srv/cases/<username>`.
- `SHARED_CASES_DIR` is mounted to `/srv/shared-cases`; each user gets `~/shared_cases -> /srv/shared-cases`.
- `RSTUDIO_CONFIG_DIR` is copied into each user's `~/.config` on first startup without overwriting existing files.
- `MSTICPY_CONFIG_DIR` is copied into each user's `~/.msticpy` on first startup without overwriting existing files.

RStudio defaults `initial_working_directory`, `default_project_location`, and `default_open_project_location` to `~/shared_cases` so shared teaching material is visible immediately after login.
`shared_cases` is managed as a common group-writable directory with default ACLs, so all provisioned users can keep reading and writing files there even when different users create them.
To keep ownership stable on the host, the container creates users and primary groups with the exact UID/GID values declared in `users.conf`.
In practice, `~/cases` is for personal work and `~/shared_cases` is for shared teaching material or collaborative editing.

Ownership model on bind mounts:

- Files created in a user's home or personal `~/cases` keep that user's numeric `uid:gid`
- Files created in `~/shared_cases` keep the creator's UID and the shared group GID
- On the host, ownership is stored numerically, so matching host/container UID and GID values matters

## GitHub over SSH

SSH is enabled by installing `openssh-client` in the image. Secrets are not injected through Compose. Each user manages their own keys inside their persistent home directory.
Because home directories are bind-mounted, `~/.ssh` persists across container recreation.

Typical workflow after the first login:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C "your_email@example.com"
ssh -T git@github.com
```

The default GitHub CLI config sets `git_protocol: ssh`, so Git operations initiated through `gh` will prefer SSH.
If users want GitHub CLI API access, they should run `gh auth login` in their own session so that `~/.config/gh/hosts.yml` remains user-specific.

## Splunk Connection (MSTICPy)

`msticpy_config/msticpyconfig.yaml` is copied to each user's `~/.msticpy/msticpyconfig.yaml` the first time that user is provisioned. Users can then customize their own copy without affecting other accounts.

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

## Environment Variables (.env)

- `R_PACKAGES_FILE`: CRAN package list file (one per line)
- `GH_PACKAGES_FILE`: GitHub package list file (one per line)
- `RSTUDIO_USERS_FILE`: host path to the user definition file
- `RSTUDIO_BASE_UID`: internal UID reserved for the built-in `rstudio` account
- `RSTUDIO_BASE_GID`: internal GID reserved for the built-in `rstudio` account
- `RSTUDIO_HOME_ROOT`: host path used for persistent per-user home directories
- `CASES_ROOT_DIR`: host path used for per-user case directories
- `SHARED_CASES_DIR`: host path used for the shared cases directory
- `SHARED_CASES_GROUP_GID`: optional fixed GID for the shared writable group used by `shared_cases`
- `RSTUDIO_CONFIG_DIR`: host path copied into each user's `~/.config`
- `RSTUDIO_RSERVER_CONF`: host file mounted to `/etc/rstudio/rserver.conf`
- `MSTICPY_CONFIG_DIR`: host path copied into each user's `~/.msticpy`

## Validation Notes

The multi-user model has been validated with two provisioned users whose host-aligned IDs were `1000:1000` and `1001:1001`.

- Personal homes under `rstudio_home/` persisted with the expected numeric owners
- Personal case directories under `CASES_ROOT_DIR` persisted with the expected numeric owners
- Shared files under `SHARED_CASES_DIR` used the configured shared group GID and were editable from real user sessions inside the container

One caveat: `docker exec -u UID:GID ...` does not include supplementary groups, so it is not a faithful test of `shared_cases` access. Real RStudio logins do include the shared group membership.

## Notes

- GitHub packages require network access during build.
- `installGithub.r` comes from the Rocker base image (littler).
- If you change `r_packages.txt`, `gh_packages.txt`, or `corp_ca/*.crt`, rebuild the image.
