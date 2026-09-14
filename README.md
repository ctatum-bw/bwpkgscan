# bitwarden-pkg-scan

Fast, repeatable OS-package auditing for [Bitwarden's official self-host
release](https://github.com/bitwarden/self-host) — for a given release
version, pull every published service image and report installed package
versions inside each one, without standing up a real deployment.

Useful for checking whether a given Bitwarden release still ships a
vulnerable version of `openssl`, `curl`, etc. across its whole image set,
before you actually upgrade a live install.

## What this does *not* do

- Does **not** run `docker-compose`, spin up MSSQL, or register an
  installation ID/key. It only pulls each image and inspects its package
  metadata — no real Bitwarden instance is ever running.
- Does **not** modify or touch an existing Bitwarden install on the host.

## Requirements

- Docker, with permission to run it (either via `sudo` or by being in the
  `docker` group: `sudo usermod -aG docker $USER`, then re-login).
- Outbound network access to `ghcr.io` (and `docker.io` if you add
  `key-connector` yourself via `--extra-image`).

## Quick start

```bash
./scan-bitwarden-stack.sh 2026.8.1 curl openssl
```

This pulls every image in that Bitwarden release and reports which
installed packages match `curl` or `openssl` in each one.

## How package matching works

Asking for `openssl` and expecting it to also find `libssl3`/`libcrypto3`
is a **naming** problem, not a fuzzy-search problem — those strings share
no common substring. Instead of a hand-maintained alias table, this script
queries each distro's own packaging metadata, which already records the
relationship:

- **Debian/Ubuntu (dpkg):** the `Source` field — e.g. `libssl3t64`'s
  `Source` is literally `openssl`.
- **Alpine (apk):** the `{origin}` field — e.g. `libssl3`'s origin is
  `openssl`.

A search term matches if it appears in either the package name or its
origin/source, anchored to a real word boundary (start of name, optional
`lib` prefix, end of name, hyphen, or a following digit). That boundary
check is what stops a short term like `cat` from false-matching inside
unrelated words like `certificates`, while still letting `curl` match
`libcurl`.

## Options

```
Usage: scan-bitwarden-stack.sh [options] <core-version> <package1> [package2 ...]

  --webv <version>            Web image version (default: same as core version)
  --services svc1,svc2,...    Override the default (full) service list
  --include-mssql <tag>       Also scan ghcr.io/bitwarden/mssql:<tag>
  --extra-image name=repo:tag Scan an arbitrary additional image (repeatable)
  --csv <path>                Write results as CSV instead of a console table
  --force                     Overwrite an existing --csv file without asking
```

Every image Bitwarden publishes for a release is scanned by default:
`admin api attachments icons identity notifications nginx sso events scim
mssqlmigratorutility setup lite web`. Ones that aren't persistent,
always-on containers in a standard install (one-shot utilities,
enterprise-only add-ons, the alternate all-in-one `lite` deployment) are
still scanned, but flagged with a short note so you know what you're
looking at.

**Excluded by default, on purpose:**
- `mssql` — versioned independently of the Bitwarden release (SQL Server
  tags, not release numbers). Add with `--include-mssql <tag>`.
- `key-connector` — never migrated to `ghcr.io` with everything else, and
  its Docker Hub tags don't line up with the release version scheme. Add
  manually if you need it:
  `--extra-image key-connector=docker.io/bitwarden/key-connector:<tag>`

## Examples

```bash
# Default: every published image, console output
./scan-bitwarden-stack.sh 2026.8.1 curl openssl

# Just a few services
./scan-bitwarden-stack.sh --services admin,api,identity,web 2026.8.1 libssl3 curl

# Web on a different version than core (they can diverge — check
# version.json in the release tag on github.com/bitwarden/self-host)
./scan-bitwarden-stack.sh --webv 2026.7.1 2026.8.1 openssl

# Include the SQL Server image too
./scan-bitwarden-stack.sh --include-mssql 2019-latest 2026.8.1 openssl

# Write structured results to a file instead of a console table
./scan-bitwarden-stack.sh --csv results.csv 2026.8.1 curl openssl vim
```

## CSV output

`--csv <path>` switches the console from full per-package tables to a
single-line progress bar, and writes structured rows to `<path>`:

```
service,image,os,package,version,origin,search_term,status,detail
```

`status` is one of `match`, `no_match`, `skip` (image failed to pull —
`detail` has the reason), or `error` (in-container scan failed). If
`<path>` already exists you'll be prompted before it's overwritten, unless
you pass `--force`.

## A note on staying current

Bitwarden has changed both its container registry (Docker Hub → `ghcr.io`)
and its versioning scheme (unified core/web/key-connector version numbers
→ tracked separately) at least once. If a service starts reporting
`[skip] could not pull ...` across the board, check
`https://github.com/bitwarden/self-host/blob/v<RELEASE>/version.json` and
the package list at `https://github.com/orgs/bitwarden/packages?repo_name=self-host`
before assuming the script is broken.
