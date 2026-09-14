#!/usr/bin/env bash
# Pulls each image in an official Bitwarden self-host release from ghcr.io
# and reports installed package versions inside each one. Single file: the
# in-container scan logic is embedded below and piped in over stdin.
#
# Registry: ghcr.io/bitwarden/<name> (not Docker Hub). Core and web version
# independently. See version.json in a given release tag on
# github.com/bitwarden/self-host if they diverge.
#
# Package matching uses each distro's own origin/source metadata (dpkg's
# ${Source} field, apk's {origin} field), so e.g. "openssl" also matches
# libssl3/libcrypto3 with nothing to maintain as packages get renamed.
#
# This does not perform a real install (no compose, no DB, no license
# key). It only pulls the images and inspects package metadata.
#
# Usage:
#   ./bwpkgscan.sh <core-version> <package1> [package2 ...]
#   ./bwpkgscan.sh --webv <ver> <core-version> <pkg1> [pkg2 ...]
#   ./bwpkgscan.sh --services api,identity,web <core-version> <pkg1> [pkg2 ...]
#   ./bwpkgscan.sh --include-mssql <tag> <core-version> <pkg1> [pkg2 ...]

set -euo pipefail

readonly IMAGE_REPO="ghcr.io/bitwarden"
# Two groups, each sorted alphabetically: ordinary persistent services
# first, then anything with a caveat (one-shot utility, alternate deploy
# mode, or opt-in enterprise add-on) at the bottom, from service_note()
# below.
readonly SERVICES_STANDARD="admin api attachments icons identity nginx notifications web"
readonly SERVICES_WITH_NOTES="events lite mssqlmigratorutility scim setup sso"
SERVICES="${SERVICES_STANDARD} ${SERVICES_WITH_NOTES}"
WEBVER=""
MSSQL_TAG=""
CSV_FILE=""
FORCE=false
declare -a EXTRA_IMAGES=()

# Caveats appended to a service's header line when it's not a persistent,
# always-on container in a standard install (one-shot utility, alternate
# deployment mode, or an optional enterprise add-on). Kept short since
# they're shown inline.
#
# A function + case statement, kept POSIX/bash-3.2 compatible so it also
# works with macOS's default system bash.
service_note() {
  case "$1" in
    sso) echo "enterprise, opt-in" ;;
    events) echo "enterprise, opt-in" ;;
    scim) echo "enterprise, opt-in" ;;
    mssqlmigratorutility) echo "one-shot migration helper" ;;
    setup) echo "one-shot config generator" ;;
    lite) echo "alt all-in-one deploy, not run with full stack" ;;
    *) echo "" ;;
  esac
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <core-version> <package1> [package2 ...]

Each <packageN> is a search term matched against installed package names
and their distro origin/source metadata, so "openssl" also finds
libssl3/libcrypto3. You can also pass a package's exact name as reported
by the distro, version included (e.g. libcrypto3-3.5.7-r0 or
curl-8.5.0-2ubuntu10.8) - the version part is trimmed off automatically
before matching, so pasting one straight out of \`apk list --installed\`
or \`dpkg -l\` output works as-is.

Every published Bitwarden self-host image is scanned by default:
  ${SERVICES_STANDARD} ${SERVICES_WITH_NOTES}
Images that aren't persistent containers in a standard install (one-shot
utilities, enterprise-only add-ons, the alternate "lite" deployment) get a
[note] in the output rather than being silently skipped.

mssql is versioned independently of the app release (SQL Server tags, not
Bitwarden release numbers), so it stays opt-in via --include-mssql.

key-connector is intentionally not scanned: it's not published under
ghcr.io/bitwarden alongside everything else, and its Docker Hub tags don't
line up with the release version scheme. Add it yourself if needed:
  --extra-image key-connector=docker.io/bitwarden/key-connector:<tag>

Options:
  --webv <version>            Web image version (default: same as core version)
  --services svc1,svc2,...    Override the default (full) service list
  --include-mssql <tag>       Also scan ghcr.io/bitwarden/mssql:<tag>
  --extra-image name=repo:tag Scan an arbitrary additional image (repeatable)
  --csv <path>                Also write results as CSV to <path>
  --force                     Overwrite an existing --csv file without asking

Examples:
  $(basename "$0") 2026.8.1 curl openssl
  $(basename "$0") --services admin,api,identity,web 2026.8.1 libssl3 curl
  $(basename "$0") --include-mssql 2019-latest 2026.8.1 openssl
  $(basename "$0") --csv results.csv 2026.8.1 curl openssl
EOF
}

# --- parse flags ---
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --webv) WEBVER="$2"; shift 2 ;;
    --services) SERVICES="${2//,/ }"; shift 2 ;;
    --include-mssql) MSSQL_TAG="$2"; shift 2 ;;
    --extra-image) EXTRA_IMAGES+=("$2"); shift 2 ;;
    --csv) CSV_FILE="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown flag: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

COREVER="$1"; shift
PKGS="$*"
WEBVER="${WEBVER:-$COREVER}"

# --csv suppresses the per-package tables (noisy alongside a progress bar)
# and shows a single-line progress bar instead. All the same data still
# lands in the CSV either way.
QUIET=false
if [[ -n "${CSV_FILE}" ]]; then
  QUIET=true
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not on PATH" >&2
  exit 1
fi

# Console styling: bold for the service name, dim for secondary info,
# green/yellow to distinguish matches from no-matches at a glance, red for
# problems. Disabled automatically when stdout isn't a terminal (redirected
# to a file, piped, etc.) or NO_COLOR is set, so it never leaks escape
# codes into logs or the CSV.
BOLD="" DIM="" GREEN="" YELLOW="" RED="" RESET=""
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RED=$'\033[31m'
  RESET=$'\033[0m'
fi

if [[ -n "${CSV_FILE}" && -e "${CSV_FILE}" && "${FORCE}" != true ]]; then
  reply=""
  if exec 3</dev/tty 2>/dev/null; then
    read -r -p "CSV file '${CSV_FILE}' already exists. Overwrite? [y/N] " reply <&3
    exec 3<&-
  else
    echo "ERROR: ${CSV_FILE} already exists and no terminal is available to confirm overwrite." >&2
    echo "       Re-run with --force to overwrite it, or choose a different --csv path." >&2
    exit 1
  fi
  case "${reply}" in
    y|Y|yes|YES|Yes) : ;;
    *)
      echo "Aborted: not overwriting ${CSV_FILE}." >&2
      exit 1
      ;;
  esac
fi

if [[ -n "${CSV_FILE}" ]]; then
  echo "service,image,os,package,version,origin,search_term,status,detail" > "${CSV_FILE}"
fi

# Progress bar bookkeeping (used only when QUIET=true)
TOTAL=0
for _ in ${SERVICES}; do TOTAL=$((TOTAL + 1)); done
if [[ -n "${MSSQL_TAG}" ]]; then
  TOTAL=$((TOTAL + 1))
fi
TOTAL=$((TOTAL + ${#EXTRA_IMAGES[@]}))
COMPLETED=0

draw_progress() {
  local label="$1" marker="$2" width=30
  COMPLETED=$((COMPLETED + 1))
  local filled=$(( COMPLETED * width / TOTAL )) empty i bar=""
  if (( filled > width )); then
    filled=${width}
  fi
  empty=$(( width - filled ))
  for ((i = 0; i < filled; i++)); do bar+="#"; done
  for ((i = 0; i < empty; i++)); do bar+="-"; done
  local label_padded
  printf -v label_padded '%-28s' "${label}"
  printf '\r[%s] %3d%% (%d/%d) %s%s%s%s' \
    "${bar}" "$(( COMPLETED * 100 / TOTAL ))" "${COMPLETED}" "${TOTAL}" "${BOLD}" "${label_padded}" "${RESET}" "${marker}"
}

# In-container scan logic, piped into each image's own /bin/sh via stdin.
# Must stay POSIX sh (some images use dash/busybox, not bash).
read -r -d '' INNER_SCRIPT <<'INNER_EOF' || true
set -eu

if command -v dpkg-query >/dev/null 2>&1; then
  OS="debian"
elif command -v apk >/dev/null 2>&1; then
  OS="alpine"
else
  echo "ERROR: no dpkg or apk found in this image" >&2
  exit 1
fi

echo "os: ${OS}"
printf 'OSNAME\t%s\n' "${OS}"

for term in ${PKGS}; do
  term_lc=$(printf '%s' "${term}" | tr 'A-Z' 'a-z')

  # If the search term itself looks like a full "name-version" string
  # (e.g. copied straight out of `apk list --installed` or `dpkg -l`,
  # such as libcrypto3-3.5.7-r0), strip the version part before matching.
  # Splits at the *first* hyphen immediately followed by a digit, since
  # that's the package-name/version boundary even when the version itself
  # has multiple hyphenated segments (Debian's "8.5.0-2ubuntu10.8" style).
  # Matching always happens against the bare package name/origin, and the
  # actual installed version is reported regardless of what was searched
  # for, so trimming here just makes pasting an exact name work as-is.
  term_lc=$(printf '%s' "${term_lc}" | awk '
    {
      s = $0
      n = length(s); splitpos = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "-") {
          nx = substr(s, i + 1, 1)
          if (nx ~ /[0-9]/) { splitpos = i; break }
        }
      }
      if (splitpos > 0) print substr(s, 1, splitpos - 1)
      else print s
    }')

  case "${OS}" in
    debian)
      # ${Source}: set when a package was built from a differently-named
      # source package (e.g. libssl3t64's Source is "openssl"). Match is
      # anchored to a token boundary (start/hyphen, optional "lib" prefix,
      # end/hyphen/digit) so short terms like "cat" don't hit mid-word
      # (e.g. "certificates") while "curl" still matches "libcurl".
      matches=$(dpkg-query -W -f='${Package}\t${Source}\t${Version}\n' 2>/dev/null | awk -F'\t' -v t="${term_lc}" '
        function reesc(s,   i,c,out) {
          out = ""
          for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (index(".^$*+?()[]{}|\\", c) > 0) out = out "\\" c
            else out = out c
          }
          return out
        }
        BEGIN { pat = "(^|-)(lib)?" reesc(t) "($|-|[0-9])" }
        {
          name=$1; source=$2; ver=$3
          gsub(/ *\(.*/, "", source)
          namelc=tolower(name); sourcelc=tolower(source)
          if (namelc ~ pat || (source!="" && sourcelc ~ pat)) print name "\t" ver "\t" source
        }')
      ;;
    alpine)
      # {origin}: the aport a package was split from (e.g. libssl3's
      # origin is "openssl"). Same token-boundary matching as above.
      matches=$(apk list --installed 2>/dev/null | awk -v t="${term_lc}" '
        function reesc(s,   i,c,out) {
          out = ""
          for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (index(".^$*+?()[]{}|\\", c) > 0) out = out "\\" c
            else out = out c
          }
          return out
        }
        BEGIN { pat = "(^|-)(lib)?" reesc(t) "($|-|[0-9])" }
        {
          nv=$1
          start=index($0,"{"); endp=index($0,"}")
          origin=""
          if (start>0 && endp>start) origin=substr($0,start+1,endp-start-1)
          n=length(nv); splitpos=0
          for (i=n; i>=1; i--) {
            c=substr(nv,i,1)
            if (c=="-") { nx=substr(nv,i+1,1); if (nx ~ /[0-9]/) { splitpos=i; break } }
          }
          if (splitpos>0) { name=substr(nv,1,splitpos-1); ver=substr(nv,splitpos+1) } else { name=nv; ver="" }
          namelc=tolower(name); originlc=tolower(origin)
          if (namelc ~ pat || (origin!="" && originlc ~ pat)) print name "\t" ver "\t" origin
        }')
      ;;
  esac

  if [ -z "${matches}" ]; then
    printf '  %s: no match\n' "${term}"
    printf 'CSVROW\t-\t-\t-\t%s\tno_match\n' "${term}"
  else
    summary=""
    old_ifs="${IFS}"
    IFS="
"
    for line in ${matches}; do
      IFS="$(printf '\t')"
      set -- ${line}
      IFS="${old_ifs}"
      name="$1"; ver="$2"; origin="${3:--}"
      printf 'CSVROW\t%s\t%s\t%s\t%s\tmatch\n' "${name}" "${ver}" "${origin}" "${term}"
      [ -n "${summary}" ] && summary="${summary}, "
      summary="${summary}${name}@${ver}"
    done
    IFS="${old_ifs}"
    printf '  %s: %s\n' "${term}" "${summary}"
  fi
done
INNER_EOF

csv_escape() {
  local s="${1//\"/\"\"}"
  printf '"%s"' "${s}"
}

csv_row() {
  # args: service image os package version origin search_term status detail
  if [[ -z "${CSV_FILE}" ]]; then
    return
  fi
  local out="" f
  for f in "$@"; do
    out+="$(csv_escape "${f}"),"
  done
  echo "${out%,}" >> "${CSV_FILE}"
}

scan_image() {
  local label="$1" image="$2" final_marker=""

  if [[ "${QUIET}" != true ]]; then
    local note=""
    local this_note
    this_note="$(service_note "${label}")"
    if [[ -n "${this_note}" ]]; then
      note="  (${this_note})"
    fi
    local label_upper
    label_upper="$(printf '%s' "${label}" | tr '[:lower:]' '[:upper:]')"
    echo "-- ${BOLD}${label_upper}${RESET}: ${image}${note}"
  fi

  local pull_err
  if ! pull_err=$(docker pull "${image}" 2>&1 >/dev/null); then
    if [[ "${QUIET}" != true ]]; then
      echo "  ${RED}skip:${RESET} ${pull_err}"
    fi
    csv_row "${label}" "${image}" "" "" "" "" "" "skip" "${pull_err}"
    if [[ "${QUIET}" == true ]]; then
      draw_progress "${label}" " [skip]"
    else
      echo
    fi
    return
  fi

  local os="" line pkg ver origin term rowstatus
  printf '%s\n' "${INNER_SCRIPT}" | docker run --rm -i \
        --entrypoint sh \
        -e PKGS="${PKGS}" \
        "${image}" \
        -s 2>/dev/null | while IFS= read -r line; do
    case "${line}" in
      OSNAME$'\t'*)
        os="${line#OSNAME$'\t'}"
        ;;
      CSVROW$'\t'*)
        IFS=$'\t' read -r pkg ver origin term rowstatus <<< "${line#CSVROW$'\t'}"
        csv_row "${label}" "${image}" "${os}" "${pkg}" "${ver}" "${origin}" "${term}" "${rowstatus}" ""
        ;;
      *)
        if [[ "${QUIET}" != true ]]; then
          case "${line}" in
            "os: "*)
              echo "  ${DIM}${line}${RESET}"
              ;;
            *": no match")
              echo "${YELLOW}${line}${RESET}"
              ;;
            "  "*)
              echo "${GREEN}${line}${RESET}"
              ;;
            *)
              echo "${line}"
              ;;
          esac
        fi
        ;;
    esac
    : # keep this iteration's exit status benign regardless of which branch ran
  done
  local docker_status="${PIPESTATUS[1]}"

  if [[ "${docker_status}" -ne 0 ]]; then
    final_marker=" [warn]"
    if [[ "${QUIET}" != true ]]; then
      echo "  ${RED}warn:${RESET} scan failed (no shell, or unsupported base)"
    fi
    csv_row "${label}" "${image}" "" "" "" "" "" "error" "scan failed inside container"
  fi

  if [[ "${QUIET}" == true ]]; then
    draw_progress "${label}" "${final_marker}"
  else
    echo
  fi
}

echo "==> Core: ${COREVER}   Web: ${WEBVER}"
echo "==> Services: ${SERVICES}"
echo "==> Packages: ${PKGS}"
echo

for svc in ${SERVICES}; do
  case "${svc}" in
    web) scan_image "web" "${IMAGE_REPO}/web:${WEBVER}" ;;
    *) scan_image "${svc}" "${IMAGE_REPO}/${svc}:${COREVER}" ;;
  esac
done

if [[ -n "${MSSQL_TAG}" ]]; then
  scan_image "mssql" "${IMAGE_REPO}/mssql:${MSSQL_TAG}"
fi

for entry in "${EXTRA_IMAGES[@]+"${EXTRA_IMAGES[@]}"}"; do
  name="${entry%%=*}"
  ref="${entry#*=}"
  scan_image "${name}" "${ref}"
done

if [[ "${QUIET}" == true ]]; then
  echo
fi
echo "==> Done."
if [[ -n "${CSV_FILE}" ]]; then
  echo "==> CSV written to ${CSV_FILE}"
fi
