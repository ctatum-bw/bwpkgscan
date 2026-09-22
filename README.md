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
- Network access to `ghcr.io`.

## Quick start

```bash
./bwpkgscan.sh 2026.8.1 curl openssl
```

## How matching works

All Bitwarden self-host images are Alpine-based. `openssl` also finds
`libssl3`/`libcrypto3` because the script checks apk's own `{origin}`
metadata, not just the package name (`libssl3`'s origin is `openssl`).

Matches are anchored to a word boundary (start of name, optional `lib`
prefix, end, hyphen, or a digit), so `cat` won't match inside
`certificates`, but `curl` still matches `libcurl`.

You can also paste an exact versioned name straight out of
`apk list --installed` (e.g. `libcrypto3-3.5.7-r0`); the version is
stripped automatically before matching.

For Alpine images, the `os:` line in the output also shows the Alpine
version (e.g. `os: alpine 3.20.3`), read from `/etc/alpine-release`.

## Options

```
Usage: bwpkgscan.sh [options] <core-version> [package1 package2 ...]

  --webv <version>            Web image version (default: auto-detected from
                               this release's version.json)
  --services svc1,svc2,...    Override the default (full) service list
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
mode, or opt-in enterprise add-on). Web's version is auto-detected rather
than assumed to match core; use `--webv` to skip that lookup and set it
directly.

## Examples

```bash
./bwpkgscan.sh 2026.8.1 curl openssl
./bwpkgscan.sh --services admin,api,identity,web 2026.8.1 libssl3 curl
./bwpkgscan.sh --webv 2026.7.1 2026.8.1 openssl
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
(core and web now tracked separately) before. If everything starts
`[skip]`ping, check
`https://github.com/bitwarden/self-host/blob/v<RELEASE>/version.json`
before assuming the script is broken.

Two things worth knowing:

- The script now checks whether `<core-version>` is a real release before
  scanning anything (requires `curl`). If it isn't, you'll see a warning
  up front instead of every image failing to pull one by one. You can
  still double-check yourself at
  `https://github.com/bitwarden/self-host/releases`; a link to a release
  that doesn't exist (e.g. an anchor like `#release-vX.Y.Z`) silently
  falls back to the top of the page instead of erroring, so it can look
  real when it isn't.
- Web version is auto-detected from the release's own `version.json`,
  since it often diverges from core by more than a point release (past
  examples: core `2026.6.1` shipped with web `2026.6.3`; core `2026.4.1`
  with web `2026.4.2`). The script prints a note when they differ. Pass
  `--webv` yourself to skip this lookup.
