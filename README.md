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

- [compose.yaml](compose.yaml)
- [.env.sample](.env.sample)

Setup:

1. Create `.env` from the single-user sample:
   - `cp .env.sample .env`
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

- [compose.multi.yaml](compose.multi.yaml)
- [.env.multi.sample](.env.multi.sample)
- [rstudio_users/users.conf.sample](rstudio_users/users.conf.sample)
- [DESIGN.md](DESIGN.md)

Setup:

1. Create `.env` from the multi-user sample:
   - `cp .env.multi.sample .env`
2. Create the runtime inputs:
   - `cp rstudio_users/users.conf.sample rstudio_users/users.conf`
   - `cp msticpy_config/msticpyconfig.yaml.sample msticpy_config/msticpyconfig.yaml`
   - Create `rstudio_home/` if you want to persist homes inside the repository path
   - Create `${HOME}/shared_cases/` or another directory referenced by `SHARED_CASES_DIR`
   - Generate mounts for existing host accounts (requires Bash and jq on the host):

     ```bash
     sudo bash scripts/prepare-users.sh alice bob > compose.users.yaml
     ```

     This creates missing `~/cases` directories with mode `0700` and the host account's
     UID/GID, preserving ownership and permissions of existing directories. Account
     templates are printed to stderr; replace `<password_hash>` in `users.conf`.
3. Edit `rstudio_users/users.conf`:
   - Add one line per user in the form `username:uid:gid:password_hash[:shell]`
   - Register ordinary host accounts with UID and primary GID of at least 1000; `rstudio` is reserved
   - Use the same `uid` and `gid` as the host OS account when you want bind-mounted files to keep natural ownership on the host
   - Generate password hashes with `openssl passwd -6 'replace-with-a-password'`
4. Edit `.env`:
   - Leave `RSTUDIO_BASE_UID` / `RSTUDIO_BASE_GID` below `1000`
   - Set `SHARED_CASES_GROUP_GID` if you want a stable shared group ID on the host
5. Build and start:

```bash
docker compose -f compose.multi.yaml -f compose.users.yaml --env-file .env build
docker compose -f compose.multi.yaml -f compose.users.yaml --env-file .env up -d
```

Access RStudio at `http://localhost:8787` and log in with one of the usernames defined in `rstudio_users/users.conf`.

If you add or remove users later, update `rstudio_users/users.conf`, regenerate
`compose.users.yaml` for the complete current user list, and recreate the container.
Removed users cannot log in; their persistent homes and host cases are retained.

```bash
docker compose -f compose.multi.yaml -f compose.users.yaml --env-file .env up -d --force-recreate
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

Both modes use the same [Dockerfile](Dockerfile) and therefore share:

- R packages from [r_packages.txt](r_packages.txt)
- GitHub R packages from [gh_packages.txt](gh_packages.txt)
- Python packages from [pip_requirements.txt](pip_requirements.txt)
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
- Each host account's `~/cases` is mounted to `/srv/cases/<username>` using the generated override; each user gets `~/cases -> /srv/cases/<username>`
- `SHARED_CASES_DIR` is mounted to `/srv/shared-cases`; each user gets `~/shared_cases -> /srv/shared-cases`
- `RSTUDIO_CONFIG_DIR` is copied into each user's `~/.config` on first startup without overwriting existing files
- `MSTICPY_CONFIG_DIR` is copied into each user's `~/.msticpy` on first startup without overwriting existing files

RStudio defaults its working and project directories to `~/cases` in both modes.
Persistent container homes have mode `0700`. Host cases permissions are preserved.
Multi-user mode requires rootful Docker without UID/GID remapping, and its dedicated
`rserver.multi.conf` restricts logins to explicitly registered users.

`shared_cases` is managed as a common group-writable directory. Files created there keep the creator's UID and the shared group GID. On the host, ownership is stored numerically, so matching host/container UID and GID values matters.

In practice:

- `~/cases` is for personal work
- `~/shared_cases` is for shared material or collaborative editing

One caveat: `docker exec -u UID:GID ...` does not include supplementary groups, so it is not a faithful test of `shared_cases` access. Real RStudio logins do include the shared group membership.

## GitHub over SSH

SSH is enabled in the image by installing `openssh-client`.

- In single-user mode, the effective user is `rstudio`
- In multi-user mode, each user manages their own `~/.ssh`

In multi-user mode, persistent container homes keep `~/.ssh` across recreation.
In single-user mode, persist `/home/rstudio` separately if SSH keys must survive recreation.
GitHub access and SSH authentication are optional.

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

Single-user mode variables live in [.env.sample](.env.sample):

- `PASSWORD`
- `CASES_DIR`
- `RSTUDIO_CONFIG_DIR`
- `RSTUDIO_RSERVER_CONF`
- `MSTICPY_CONFIG_FILE`

Multi-user mode variables live in [.env.multi.sample](.env.multi.sample):

- `RSTUDIO_USERS_FILE`
- `RSTUDIO_BASE_UID`
- `RSTUDIO_BASE_GID`
- `RSTUDIO_HOME_ROOT`
- `SHARED_CASES_DIR`
- `SHARED_CASES_GROUP_GID`
- `RSTUDIO_CONFIG_DIR`
- `RSTUDIO_MULTI_RSERVER_CONF`
- `MSTICPY_CONFIG_DIR`

## Personal Packages (Multi-User)

The shared R/Python environments are writable only by the administrator through
image builds. R installs user packages into `~/R/library` by default:

```r
install.packages("package_name")
```

To use a personal Python environment, run in the RStudio terminal:

```bash
uv venv ~/.venvs/analysis --python /opt/r/bin/python
uv pip install --python ~/.venvs/analysis/bin/python package_name
```

Then select it in R before initializing Python:

```r
Sys.setenv(RETICULATE_PYTHON = path.expand("~/.venvs/analysis/bin/python"))
```

Existing `.Renviron` files are preserved; if needed, add both `R_LIBS_USER=~/R/library`
and `R_LIBS=~/R/library`
to your own configuration. OS dependencies require an administrator image update.

Both modes also use:

- `R_PACKAGES_FILE`
- `GH_PACKAGES_FILE`

## Notes

- GitHub packages require network access during build
- `installGithub.r` comes from the Rocker base image (littler)
- If you change `r_packages.txt`, `gh_packages.txt`, or `corp_ca/*.crt`, rebuild the image
- Multi-user access is intended for trusted organization members over the internal
  network. This repository serves HTTP; network access restrictions are managed externally.
