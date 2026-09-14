# bwpkgscan

Pulls every published image for a given Bitwarden self-host release and
reports installed package versions in each one, for answering
customer-requested vulnerability scans (e.g. "is version X affected by
CVE-YYYY in `openssl`/`curl`?") without standing up a real deployment.

## What this does *not* do

- Doesn't run `docker-compose`, spin up MSSQL, or register an install ID.
  It only pulls images and inspects package metadata.
- Doesn't modify or touch an existing Bitwarden install.
- Doesn't judge CVE applicability. It reports installed versions; you
  cross-reference against the advisory.

## Requirements

- Docker, runnable without extra setup (`sudo`, or in the `docker` group).
- Network access to `ghcr.io` (and `docker.io` for `key-connector`, if
  added via `--extra-image`).

## Quick start

```bash
./bwpkgscan.sh 2026.8.1 curl openssl
```

## How matching works

`openssl` also finds `libssl3`/`libcrypto3` because the script checks each
distro's own origin/source metadata, not just the package name:

- **Debian/Ubuntu (dpkg):** the `Source` field (`libssl3t64`'s Source is
  `openssl`).
- **Alpine (apk):** the `{origin}` field (`libssl3`'s origin is `openssl`).

Matches are anchored to a word boundary (start of name, optional `lib`
prefix, end, hyphen, or a digit), so `cat` won't match inside
`certificates`, but `curl` still matches `libcurl`.

You can also paste an exact versioned name straight out of
`apk list --installed` or `dpkg -l` (e.g. `libcrypto3-3.5.7-r0`); the
version is stripped automatically before matching.

## Options

```
Usage: bwpkgscan.sh [options] <core-version> [package1 package2 ...]

  --webv <version>            Web image version (default: same as core version)
  --services svc1,svc2,...    Override the default (full) service list
  --include-mssql <tag>       Also scan ghcr.io/bitwarden/mssql:<tag>
  --extra-image name=repo:tag Scan an arbitrary additional image (repeatable)
  --csv <path>                Write results as CSV instead of a console table
  --force                     Overwrite an existing --csv file without asking
  --pkgs-file <path>          Read package names from a file (repeatable)
```

`--pkgs-file` names can be combined with ones on the command line. One or
more per line; blank lines and `#` comments are ignored:

```
# CVE-2026-1234
curl
openssl
libcrypto3-3.5.7-r0
```

Default scan set: `admin api attachments icons identity nginx
notifications web`, then `events lite mssqlmigratorutility scim setup
sso` (each flagged with a short note: one-shot utility, alternate deploy
mode, or opt-in enterprise add-on).

**Excluded by default:**
- `mssql`: versioned independently of the release. Use `--include-mssql <tag>`.
- `key-connector`: still on Docker Hub, not `ghcr.io`, and its tags don't
  match the release scheme. Add manually:
  `--extra-image key-connector=docker.io/bitwarden/key-connector:<tag>`

## Examples

```bash
./bwpkgscan.sh 2026.8.1 curl openssl
./bwpkgscan.sh --services admin,api,identity,web 2026.8.1 libssl3 curl
./bwpkgscan.sh --webv 2026.7.1 2026.8.1 openssl
./bwpkgscan.sh --include-mssql 2019-latest 2026.8.1 openssl
./bwpkgscan.sh --csv results.csv 2026.8.1 curl openssl vim
./bwpkgscan.sh --pkgs-file cve-2026-1234.txt 2026.8.1
```

## CSV output

`--csv <path>` swaps the console tables for a progress bar and writes:

```
service,image,os,package,version,origin,search_term,status,detail
```

`status` is `match`, `no_match`, `skip` (pull failed, see `detail`), or
`error` (in-container scan failed). Existing files prompt before being
overwritten unless `--force` is passed.

## Staying current

Bitwarden has changed registries (Docker Hub to `ghcr.io`) and versioning
(core/web/key-connector now tracked separately) before. If everything
starts `[skip]`ping, check
`https://github.com/bitwarden/self-host/blob/v<RELEASE>/version.json`
before assuming the script is broken.
