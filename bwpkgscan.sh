#!/usr/bin/env bash
# Scans Bitwarden self-host images (versioned pull, or already-running
# containers with --local) and reports installed package versions, so a
# CVE question can be answered without standing up a real deployment.
#
# Registry: ghcr.io/bitwarden/<name>. Core and web version independently -
# see version.json in a release tag on github.com/bitwarden/self-host.
# Package matching uses apk's {origin} metadata, so e.g. "openssl" also
# finds libssl3/libcrypto3 with nothing to maintain as packages get renamed.
#
# Usage:
#   ./bwpkgscan.sh <core-version> <package1> [package2 ...]
#   ./bwpkgscan.sh --webv <ver> <core-version> <pkg1> [pkg2 ...]
#   ./bwpkgscan.sh --services api,identity,web <core-version> <pkg1> [pkg2 ...]
#   ./bwpkgscan.sh --local <pkg1> [pkg2 ...]
#   ./bwpkgscan.sh --local --services admin,api <pkg1> [pkg2 ...]
#
# --local scans whatever's already running instead of pulling a version.
# It picks up any running container under ghcr.io/bitwarden or
# bitwardenprod.azurecr.io (RC builds, e.g. .../web:rc), even ones with a
# service name this script doesn't otherwise know about. --services
# narrows that down to specific names.

set -euo pipefail

readonly IMAGE_REPO="ghcr.io/bitwarden"
# RC builds are sometimes published here under a fixed :rc tag instead.
# Only used by --local's discovery; there's no version-pull path for it.
readonly RC_IMAGE_REPO="bitwardenprod.azurecr.io"
# Standard services, then ones with a caveat (one-shot/alt-deploy/opt-in),
# both alphabetical - see service_note() below.
readonly SERVICES_STANDARD="admin api attachments icons identity nginx notifications web"
readonly SERVICES_WITH_NOTES="events lite mssqlmigratorutility scim setup sso"
SERVICES="${SERVICES_STANDARD} ${SERVICES_WITH_NOTES}"
WEBVER=""
CSV_FILE=""
FORCE=false
LOCAL_MODE=false
# True once --services is passed explicitly. --local only narrows to a
# named subset when this is set; otherwise it scans everything it finds.
SERVICES_OVERRIDDEN=false
declare -a EXTRA_IMAGES=()
declare -a PKGS_FILES=()
# Filled in by discover_local_containers(): label/container/image per
# running container found (see --local above).
declare -a LOCAL_LABELS=()
declare -a LOCAL_CONTAINERS=()
declare -a LOCAL_IMAGES=()

# Short caveat shown next to a service's header line when it's not a
# persistent always-on container in a standard install. Kept as a
# function + case for POSIX/bash-3.2 compatibility (macOS system bash).
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
Usage: $(basename "$0") [options] <core-version> [package ...]
       $(basename "$0") --local [options] [package ...]

<package> matches an installed name or apk {origin} (e.g. "openssl" also
finds libssl3/libcrypto3). Exact versioned names like libcrypto3-3.5.7-r0
work too - the version is stripped before matching. Can also come from
--pkgs-file (one or more per line, # comments and blank lines ignored).

Default scan set (every published image):
  ${SERVICES_STANDARD} ${SERVICES_WITH_NOTES}
Non-standard ones (one-shot, enterprise add-on, alt deploy) get a [note].

<core-version> is checked against real releases first (needs curl). Any
matched package on an older version than seen elsewhere is flagged at
the end under "Version check".

Options:
  --local                      Scan running containers instead of pulling a
                               version. Matches ${IMAGE_REPO}/* or
                               ${RC_IMAGE_REPO}/*, any service name.
                               --extra-image takes a container name here.
  --webv <version>             Web image version (default: auto-detected)
  --services svc1,svc2,...     Only scan these services
  --extra-image name=repo:tag  Scan an extra image (repeatable)
  --csv <path>                 Write results to CSV instead of console tables
  --force                      Overwrite an existing --csv file
  --pkgs-file <path>           Package names from a file (repeatable)

Examples:
  $(basename "$0") 2026.8.1 curl openssl
  $(basename "$0") --services admin,api,web 2026.8.1 libssl3 curl
  $(basename "$0") --csv results.csv 2026.8.1 curl openssl
  $(basename "$0") --local curl openssl
  $(basename "$0") --pkgs-file cve-2026-1234.txt 2026.8.1
EOF
}

# --- parse flags ---
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --local) LOCAL_MODE=true; shift ;;
    --webv) WEBVER="$2"; shift 2 ;;
    --services) SERVICES="${2//,/ }"; SERVICES_OVERRIDDEN=true; shift 2 ;;
    --extra-image) EXTRA_IMAGES+=("$2"); shift 2 ;;
    --csv) CSV_FILE="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --pkgs-file) PKGS_FILES+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown flag: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${LOCAL_MODE}" == true ]]; then
  # No <core-version> in local mode - everything left is a package term.
  # (Empty PKGS is fine here; the "no packages" check below catches it.)
  COREVER=""
  PKGS="$*"
else
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  COREVER="$1"; shift
  PKGS="$*"

  # Check v<core-version> is a real bitwarden/self-host release before
  # scanning anything, so a typo'd/unreleased version warns once up front
  # instead of every image failing to pull, one at a time, unexplained.
  VERSION_JSON_URL="https://raw.githubusercontent.com/bitwarden/self-host/v${COREVER}/version.json"
  HTTP_STATUS=""
  VERSION_JSON=""
  if command -v curl >/dev/null 2>&1; then
    # One request instead of two: -w captures the status code on stdout
    # while -o writes the body to a temp file, rather than fetching the
    # same URL twice (once for the status, once for the body).
    version_json_tmp="$(mktemp 2>/dev/null || echo "/tmp/bwpkgscan_verjson.$$")"
    HTTP_STATUS="$(curl -s --connect-timeout 5 --max-time 10 -o "${version_json_tmp}" -w '%{http_code}' "${VERSION_JSON_URL}" 2>/dev/null || true)"
    VERSION_JSON="$(cat "${version_json_tmp}" 2>/dev/null || true)"
    rm -f "${version_json_tmp}"
  elif command -v wget >/dev/null 2>&1; then
    VERSION_JSON="$(wget -qO- --timeout=10 "${VERSION_JSON_URL}" 2>/dev/null || true)"
  fi

  if [[ "${HTTP_STATUS}" == "404" ]]; then
    echo "==> Warning: v${COREVER} does not appear to be a real bitwarden/self-host release."
    echo "             Check https://github.com/bitwarden/self-host/releases for the actual"
    echo "             latest version before continuing. Every image below will likely fail"
    echo "             to pull if this version was never released."
    echo
  fi

  # Web can diverge from core by more than a point release (seen before:
  # core 2026.6.1 shipped with web 2026.6.3). Check this release's own
  # version.json unless --webv was already given.
  if [[ -z "${WEBVER}" ]]; then
    WEBVER_DETECTED=""
    if [[ -n "${VERSION_JSON}" ]]; then
      WEBVER_DETECTED="$(printf '%s' "${VERSION_JSON}" | tr -d '\n\r ' | grep -o '"webVersion":"[^"]*"' | sed -E 's/.*:"([^"]*)".*/\1/' || true)"
    fi

    if [[ -n "${WEBVER_DETECTED}" ]]; then
      WEBVER="${WEBVER_DETECTED}"
      if [[ "${WEBVER}" != "${COREVER}" ]]; then
        echo "==> Note: web version (${WEBVER}) differs from core (${COREVER}) per this release's version.json"
      fi
    else
      # No network/curl/wget, or the release doesn't exist - assume they
      # match rather than failing outright.
      WEBVER="${COREVER}"
    fi
  fi
fi

# Merge in --pkgs-file contents: drop comments/blank lines and stray \r,
# then fold into the same space-separated PKGS string.
for pkgs_file in "${PKGS_FILES[@]+"${PKGS_FILES[@]}"}"; do
  if [[ ! -r "${pkgs_file}" ]]; then
    echo "ERROR: cannot read package list file: ${pkgs_file}" >&2
    exit 1
  fi
  file_pkgs="$(tr -d '\r' < "${pkgs_file}" | grep -Ev '^[[:space:]]*(#|$)' | tr '\n' ' ' || true)"
  PKGS="${PKGS} ${file_pkgs}"
done

PKGS="$(printf '%s' "${PKGS}" | tr -s '[:space:]' ' ')"
PKGS="${PKGS# }"; PKGS="${PKGS% }"
if [[ -z "${PKGS}" ]]; then
  echo "ERROR: no packages to search for (pass them as arguments, or via --pkgs-file)" >&2
  exit 1
fi

# --csv swaps the per-package tables for a progress bar; the CSV gets the
# same data either way.
QUIET=false
if [[ -n "${CSV_FILE}" ]]; then
  QUIET=true
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not on PATH" >&2
  exit 1
fi

# Finds running containers under a known Bitwarden registry, filters to
# SERVICES only if the user asked for a subset via --services, then sorts
# by container name (docker ps order is arbitrary - usually newest-first).
discover_local_containers() {
  local name image svc want found prefix
  local -a all_labels=() all_containers=() all_images=()

  while IFS=$'\t' read -r name image; do
    [[ -z "${name}" ]] && continue
    prefix=""
    case "${image}" in
      "${IMAGE_REPO}/"*) prefix="${IMAGE_REPO}/" ;;
      "${RC_IMAGE_REPO}/"*) prefix="${RC_IMAGE_REPO}/" ;;
    esac
    if [[ -n "${prefix}" ]]; then
      svc="${image#"${prefix}"}"
      svc="${svc%%:*}"
      all_labels+=("${svc}")
      all_containers+=("${name}")
      all_images+=("${image}")
    fi
  done < <(docker ps --format '{{.Names}}\t{{.Image}}')

  if [[ "${SERVICES_OVERRIDDEN}" == true ]]; then
    for i in "${!all_labels[@]}"; do
      found=false
      for want in ${SERVICES}; do
        [[ "${want}" == "${all_labels[$i]}" ]] && { found=true; break; }
      done
      if [[ "${found}" == true ]]; then
        LOCAL_LABELS+=("${all_labels[$i]}")
        LOCAL_CONTAINERS+=("${all_containers[$i]}")
        LOCAL_IMAGES+=("${all_images[$i]}")
      fi
    done
  else
    LOCAL_LABELS=("${all_labels[@]+"${all_labels[@]}"}")
    LOCAL_CONTAINERS=("${all_containers[@]+"${all_containers[@]}"}")
    LOCAL_IMAGES=("${all_images[@]+"${all_images[@]}"}")
  fi

  if [[ ${#LOCAL_CONTAINERS[@]} -gt 0 ]]; then
    local container_name label_name image_ref
    local -a sorted_labels=() sorted_containers=() sorted_images=()
    while IFS=$'\t' read -r container_name label_name image_ref; do
      [[ -z "${container_name}" ]] && continue
      sorted_containers+=("${container_name}")
      sorted_labels+=("${label_name}")
      sorted_images+=("${image_ref}")
    done < <(
      for i in "${!LOCAL_CONTAINERS[@]}"; do
        printf '%s\t%s\t%s\n' "${LOCAL_CONTAINERS[$i]}" "${LOCAL_LABELS[$i]}" "${LOCAL_IMAGES[$i]}"
      done | sort
    )
    LOCAL_LABELS=("${sorted_labels[@]}")
    LOCAL_CONTAINERS=("${sorted_containers[@]}")
    LOCAL_IMAGES=("${sorted_images[@]}")
  fi
}

if [[ "${LOCAL_MODE}" == true ]]; then
  discover_local_containers
  if [[ ${#LOCAL_LABELS[@]} -eq 0 && ${#EXTRA_IMAGES[@]} -eq 0 ]]; then
    if [[ "${SERVICES_OVERRIDDEN}" == true ]]; then
      echo "ERROR: no running containers found matching ${IMAGE_REPO}/* or ${RC_IMAGE_REPO}/* for --services: ${SERVICES}" >&2
    else
      echo "ERROR: no running containers found matching ${IMAGE_REPO}/* or ${RC_IMAGE_REPO}/*" >&2
    fi
    echo "       Is the Bitwarden self-host stack up? Check with: docker ps" >&2
    exit 1
  fi
fi

# Disabled automatically when stdout isn't a terminal (redirected/piped) or
# NO_COLOR is set, so escape codes never leak into logs or the CSV.
BOLD="" DIM="" GREEN="" YELLOW="" RED="" RESET=""
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RED=$'\033[31m'
  RESET=$'\033[0m'
fi

# Pulls each image in the background, PREFETCH_CONCURRENCY at a time, then
# waits for that batch before the next. Silent: failures are ignored here
# and reported per-service by scan_image. Not used by --local.
PREFETCH_CONCURRENCY=4
prefetch_images() {
  local image batch_count=0
  for image in "$@"; do
    docker pull "${image}" >/dev/null 2>&1 &
    batch_count=$((batch_count + 1))
    if (( batch_count >= PREFETCH_CONCURRENCY )); then
      wait
      batch_count=0
    fi
  done
  wait
}

if [[ "${LOCAL_MODE}" != true ]]; then
  declare -a PREFETCH_IMAGES=()
  for svc in ${SERVICES}; do
    case "${svc}" in
      web) PREFETCH_IMAGES+=("${IMAGE_REPO}/web:${WEBVER}") ;;
      *) PREFETCH_IMAGES+=("${IMAGE_REPO}/${svc}:${COREVER}") ;;
    esac
  done
  for entry in "${EXTRA_IMAGES[@]+"${EXTRA_IMAGES[@]}"}"; do
    PREFETCH_IMAGES+=("${entry#*=}")
  done
  echo "==> Pre-pulling ${#PREFETCH_IMAGES[@]} image(s), ${PREFETCH_CONCURRENCY} at a time..."
  prefetch_images "${PREFETCH_IMAGES[@]}"
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

# Every matched package/version, across all scans, so we can flag versions
# that disagree with the majority at the end (e.g. one service on an
# older libssl3 than the rest). Cleaned up on exit either way.
VERSION_LOG="$(mktemp 2>/dev/null || echo "/tmp/bwpkgscan_versions.$$")"
trap 'rm -f "${VERSION_LOG}"' EXIT

# Progress bar bookkeeping (used only when QUIET=true)
TOTAL=0
if [[ "${LOCAL_MODE}" == true ]]; then
  TOTAL=${#LOCAL_LABELS[@]}
else
  for _ in ${SERVICES}; do TOTAL=$((TOTAL + 1)); done
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

# In-container scan logic, piped into a shell over stdin. Must stay POSIX
# sh - some images use dash/busybox, not bash.
read -r -d '' INNER_SCRIPT <<'INNER_EOF' || true
set -eu

if command -v apk >/dev/null 2>&1; then
  OS="alpine"
  if [ -r /etc/alpine-release ]; then
    OS="alpine $(cat /etc/alpine-release 2>/dev/null)"
  fi
  # Query once, not per term. extra = {origin}, the aport a package was
  # split from (libssl3's origin is "openssl"). apk's "name-version" is
  # split here into name/version/origin for the matcher below.
  ALL_PKGS=$(apk list --installed 2>/dev/null | awk '
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
      print name "\t" ver "\t" origin
    }')
else
  echo "ERROR: apk not found in this image (expected an Alpine base)" >&2
  exit 1
fi

echo "os: ${OS}"
printf 'OSNAME\t%s\n' "${OS}"

for term in ${PKGS}; do
  term_lc=$(printf '%s' "${term}" | tr 'A-Z' 'a-z')

  # A search term that's itself "name-version" (e.g. pasted straight out
  # of `apk list --installed`, like libcrypto3-3.5.7-r0) gets its version
  # trimmed before matching, at the first hyphen followed by a digit.
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

  # Anchored to a token boundary (start/hyphen, optional "lib" prefix,
  # end/hyphen/digit) so "cat" doesn't match "certificates" but "curl"
  # still matches "libcurl".
  matches=$(printf '%s\n' "${ALL_PKGS}" | awk -F'\t' -v t="${term_lc}" '
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
      name=$1; ver=$2; extra=$3
      namelc=tolower(name); extralc=tolower(extra)
      if (namelc ~ pat || (extra!="" && extralc ~ pat)) print name "\t" ver "\t" extra
    }')

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

# Prints "-- LABEL: target  (note)" - shared by both scan functions below.
print_scan_header() {
  local label="$1" target="$2" note
  note="$(service_note "${label}")"
  [[ -n "${note}" ]] && note="  (${note})"
  echo "-- ${BOLD}$(printf '%s' "${label}" | tr '[:lower:]' '[:upper:]')${RESET}: ${target}${note}"
}

# Records a skipped scan (pull failure or container not running) and
# advances the progress bar / blank line - shared by both scan functions.
scan_skip() {
  local label="$1" image="$2" msg="$3" detail="$4"
  if [[ "${QUIET}" != true ]]; then
    echo "  ${RED}skip:${RESET} ${msg}"
  fi
  csv_row "${label}" "${image}" "" "" "" "" "" "skip" "${detail}"
  if [[ "${QUIET}" == true ]]; then
    draw_progress "${label}" " [skip]"
  else
    echo
  fi
}

# Pipes INNER_SCRIPT into "$@" (a docker run/exec invocation), parses its
# OSNAME/CSVROW output into CSV rows + VERSION_LOG, and prints colored
# per-package lines. Sets SCAN_STATUS (not local - read by the caller).
# Shared by scan_image (pull+run) and scan_local_container (exec).
run_inner_scan() {
  local label="$1" image="$2"; shift 2
  local os="" line pkg ver origin term rowstatus
  set +e # a failing pipeline here (e.g. no shell in the image) must not abort the whole script
  printf '%s\n' "${INNER_SCRIPT}" | "$@" 2>/dev/null | while IFS= read -r line; do
    case "${line}" in
      OSNAME$'\t'*)
        os="${line#OSNAME$'\t'}"
        ;;
      CSVROW$'\t'*)
        IFS=$'\t' read -r pkg ver origin term rowstatus <<< "${line#CSVROW$'\t'}"
        csv_row "${label}" "${image}" "${os}" "${pkg}" "${ver}" "${origin}" "${term}" "${rowstatus}" ""
        if [[ "${rowstatus}" == "match" ]]; then
          printf '%s\t%s\t%s\n' "${label}" "${pkg}" "${ver}" >> "${VERSION_LOG}"
        fi
        ;;
      *)
        if [[ "${QUIET}" != true ]]; then
          case "${line}" in
            "os: "*) echo "  ${DIM}${line}${RESET}" ;;
            *": no match") echo "${YELLOW}${line}${RESET}" ;;
            "  "*) echo "${GREEN}${line}${RESET}" ;;
            *) echo "${line}" ;;
          esac
        fi
        ;;
    esac
    : # keep this iteration's exit status benign regardless of which branch ran
  done
  SCAN_STATUS="${PIPESTATUS[1]}"
  set -e
}

# Reports a failed in-container scan (if any) and advances the progress
# bar / blank line - shared tail for both scan functions.
scan_finish() {
  local label="$1" image="$2" status="$3" final_marker=""
  if [[ "${status}" -ne 0 ]]; then
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

scan_image() {
  local label="$1" image="$2"
  [[ "${QUIET}" != true ]] && print_scan_header "${label}" "${image}"

  local pull_err
  if ! pull_err=$(docker pull "${image}" 2>&1 >/dev/null); then
    scan_skip "${label}" "${image}" "${pull_err}" "${pull_err}"
    return
  fi

  run_inner_scan "${label}" "${image}" docker run --rm -i --entrypoint sh -e PKGS="${PKGS}" "${image}" -s
  scan_finish "${label}" "${image}" "${SCAN_STATUS}"
}

# --local counterpart to scan_image(): no docker pull (already running),
# exec into the live container instead of run against a freshly pulled one.
scan_local_container() {
  local label="$1" container="$2" image="$3"
  [[ "${QUIET}" != true ]] && print_scan_header "${label}" "${container} (${image})"

  if [[ "$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null || echo false)" != "true" ]]; then
    scan_skip "${label}" "${image}" "container '${container}' not found or not running" "container not running"
    return
  fi

  run_inner_scan "${label}" "${image}" docker exec -i -e PKGS="${PKGS}" "${container}" sh -s
  scan_finish "${label}" "${image}" "${SCAN_STATUS}"
}

if [[ "${LOCAL_MODE}" == true ]]; then
  echo "==> Local scan: ${#LOCAL_LABELS[@]} running container(s) detected under ${IMAGE_REPO}/* or ${RC_IMAGE_REPO}/*"
else
  echo "==> Core: ${COREVER}   Web: ${WEBVER}"
fi
echo "==> Services: ${SERVICES}"
echo "==> Packages: ${PKGS}"
echo

if [[ "${LOCAL_MODE}" == true ]]; then
  for i in "${!LOCAL_LABELS[@]}"; do
    scan_local_container "${LOCAL_LABELS[$i]}" "${LOCAL_CONTAINERS[$i]}" "${LOCAL_IMAGES[$i]}"
  done
else
  for svc in ${SERVICES}; do
    case "${svc}" in
      web) scan_image "web" "${IMAGE_REPO}/web:${WEBVER}" ;;
      *) scan_image "${svc}" "${IMAGE_REPO}/${svc}:${COREVER}" ;;
    esac
  done
fi

for entry in "${EXTRA_IMAGES[@]+"${EXTRA_IMAGES[@]}"}"; do
  name="${entry%%=*}"
  ref="${entry#*=}"
  if [[ "${LOCAL_MODE}" == true ]]; then
    # ref is a container name here, not an image tag; look up its image
    # just for display.
    extra_image="$(docker inspect -f '{{.Config.Image}}' "${ref}" 2>/dev/null || echo "${ref}")"
    scan_local_container "${name}" "${ref}" "${extra_image}"
  else
    scan_image "${name}" "${ref}"
  fi
done

if [[ "${QUIET}" == true ]]; then
  echo
fi

if [[ -s "${VERSION_LOG}" ]]; then
  outdated="$(awk -F'\t' '
    # Zero-pads digit runs to a fixed width so version strings compare
    # correctly as plain strings (e.g. "3.10.0" sorts after "3.5.7").
    # Avoids relying on `sort -V`, which macOS bsd sort lacks.
    function verskey(v,   i, n, c, t, prevt, buf, out) {
      n = length(v)
      out = ""; buf = ""; prevt = ""
      for (i = 1; i <= n; i++) {
        c = substr(v, i, 1)
        t = (c ~ /[0-9]/) ? "d" : "s"
        if (prevt != "" && t != prevt) {
          if (prevt == "d") out = out sprintf("%012d", buf)
          else out = out buf
          buf = ""
        }
        buf = buf c
        prevt = t
      }
      if (buf != "") {
        if (prevt == "d") out = out sprintf("%012d", buf)
        else out = out buf
      }
      return out
    }
    {
      svc=$1; pkg=$2; ver=$3
      key = verskey(ver)
      n++
      rowsvc[n]=svc; rowpkg[n]=pkg; rowver[n]=ver; rowkey[n]=key
      if (!(pkg in maxkey) || key > maxkey[pkg]) {
        maxkey[pkg] = key
        maxver[pkg] = ver
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        if (rowkey[i] < maxkey[rowpkg[i]]) {
          print rowsvc[i] "\t" rowpkg[i] "\t" rowver[i] "\t" maxver[rowpkg[i]]
        }
      }
    }' "${VERSION_LOG}")"

  if [[ -n "${outdated}" ]]; then
    echo "==> Version check: these are older than the newest version seen for that package"
    echo
    printf '%s\n' "${outdated}" | while IFS=$'\t' read -r svc pkg ver newest; do
      printf '  %-20s %-25s %s%s%s (newest seen: %s)\n' "${svc}" "${pkg}" "${RED}" "${ver}" "${RESET}" "${newest}"
    done
    echo
  fi
fi

echo "==> Done."
if [[ -n "${CSV_FILE}" ]]; then
  echo "==> CSV written to ${CSV_FILE}"
fi
