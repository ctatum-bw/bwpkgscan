# bwpkgscan

Reports installed package versions inside Bitwarden self-host images, for answering
customer vulnerability questions (e.g. "is version X affected by CVE-YYYY in
`openssl`/`curl`?") without standing up a real deployment.

It can scan either:

- **A published release**: pulls every image for a given version and inspects each one.
- **A running instance** (`--local`): inspects the Bitwarden containers already running
  on this machine, no version needed.

## What it does not do

- Doesn't run `docker-compose`, start MSSQL, or register an install ID.
- Doesn't modify an existing Bitwarden install. `--local` only runs a read-only
  package query inside each container.
- Doesn't judge CVE applicability. It reports installed versions; you compare them
  against the advisory.

## Requirements

- Docker, runnable without extra setup (`sudo`, or membership in the `docker` group).
- Network access to `ghcr.io` (release mode only).
- `curl` or `wget` (optional): used to validate the release version and detect the web
  version. Without them the script still runs and assumes web matches core.
- Works with macOS's default bash 3.2.

## Quick start

```bash
# Scan a published release
./bwpkgscan.sh 2026.8.1 curl openssl

# Scan what's running locally (no version)
./bwpkgscan.sh --local curl openssl
```

## Usage

```
bwpkgscan.sh [options] <core-version> [package ...]
bwpkgscan.sh --local [options] [package ...]
```

Options go before the version and package names.

| Option | Description |
| --- | --- |
| `--local` | Scan running containers instead of pulling a version. |
| `--webv <version>` | Web image version. Default: auto-detected from the release's `version.json`. |
| `--services svc1,svc2,...` | Only scan these services. |
| `--extra-image name=repo:tag` | Scan an additional image (repeatable). With `--local`, give `name=container_name` instead. |
| `--csv <path>` | Write results to CSV instead of console tables. |
| `--force` | Overwrite an existing `--csv` file without prompting. |
| `--pkgs-file <path>` | Read package names from a file (repeatable). |

### Examples

```bash
./bwpkgscan.sh 2026.8.1 curl openssl
./bwpkgscan.sh --services admin,api,web 2026.8.1 libssl3 curl
./bwpkgscan.sh --webv 2026.7.1 2026.8.1 openssl
./bwpkgscan.sh --csv results.csv 2026.8.1 curl openssl vim
./bwpkgscan.sh --pkgs-file cve-2026-1234.txt 2026.8.1
./bwpkgscan.sh --local --services admin,api libssl3 curl
```

## Package matching

All Bitwarden self-host images are Alpine-based. Search terms are matched against
each installed package's name **and** its apk `{origin}` metadata, so `openssl` also
finds `libssl3` and `libcrypto3` (their origin is `openssl`). Nothing needs updating
when packages get renamed.

- Matches are anchored to a word boundary, so `cat` won't match inside `certificates`,
  but `curl` still matches `libcurl`.
- You can paste an exact versioned name straight from `apk list --installed`
  (e.g. `libcrypto3-3.5.7-r0`). The version is stripped before matching.
- With `--pkgs-file`, put one or more names per line. Blank lines and `#` comments are
  ignored.

  ```
  # CVE-2026-1234
  curl
  openssl
  libcrypto3-3.5.7-r0
  ```

## Release mode

1. **Version check.** If `curl` is available, the script confirms
   `<core-version>` is a real `bitwarden/self-host` release and warns up front if it
   isn't, instead of every image failing to pull one at a time. The check times out
   after 10 seconds so an unreachable network can't stall the run.
2. **Web version.** Core and web are versioned independently. The script reads the
   release's `version.json` to find the right web version and prints a note when it
   differs from core. Use `--webv` to set it yourself.
3. **Pre-pull.** Images are pulled in parallel, 4 at a time, so the downloads overlap.
   Failures are reported per service in the next step.

4. **Scan.** Each image is inspected in turn and results are printed per service.

Default service set (each is scanned unless you pass `--services`):

```
admin api attachments icons identity nginx notifications web
events lite mssqlmigratorutility scim setup sso
```

The last six aren't persistent containers in a standard install, so they're labeled
in the output: `events`, `scim` and `sso` are opt-in enterprise add-ons,
`mssqlmigratorutility` and `setup` are one-shot utilities, and `lite` is the alternate
all-in-one deployment.

## Local mode (`--local`)

Scans whatever is already running, with no version argument and no pulling.

- Detects **any** running container whose image is under `ghcr.io/bitwarden/` or
  `bitwardenprod.azurecr.io/` (release candidates, e.g. `.../web:rc`), regardless of
  service name. Services the script doesn't know about are still picked up.
- Containers are scanned in alphabetical order by container name.
- `--services` narrows the scan to specific service names.
- `--extra-image name=container_name` adds another running container by name.
- Exits with an error if no matching containers are found.

## Output

After all scans, any matched package running an older version than the newest one seen
for that package elsewhere in the scan is listed under **Version check** in red,
for example one service still on an older `libssl3` than the rest.

Colors turn off automatically when output is piped or redirected, or when `NO_COLOR`
is set.

### CSV

`--csv <path>` replaces the console tables with a progress bar and writes:

```
service,image,os,package,version,origin,search_term,status,detail
```

`status` is one of:

| Status | Meaning |
| --- | --- |
| `match` | Package found. |
| `no_match` | Search term matched nothing in that image. |
| `skip` | Pull failed or container not running (see `detail`). |
| `error` | The scan failed inside the container (e.g. no shell). |

An existing file prompts before being overwritten unless `--force` is passed.

## Troubleshooting

- **Everything is `[skip]`ping.** Bitwarden has changed registries (Docker Hub to
  `ghcr.io`) and versioning before. Check
  `https://github.com/bitwarden/self-host/blob/v<RELEASE>/version.json` and
  `https://github.com/bitwarden/self-host/releases` before assuming the script is
  broken. A release link that doesn't exist can silently fall back to the top of the
  releases page, so it can look real when it isn't.
- **Warning that the version isn't a real release.** The version was never published
  (or has a typo). Check the releases page for the actual latest version.
- **Slow before the "Pre-pulling" message appears.** That's the version check reaching out to
  `raw.githubusercontent.com`. It gives up after 10 seconds and continues.
- **`no running containers found` in `--local` mode.** The stack isn't up, or its
  images aren't under the registries above. Check with `docker ps`.
- **`scan failed (no shell, or unsupported base)`.** The container has no `sh`, or
  isn't Alpine-based. The script warns on that service and continues with the rest.
