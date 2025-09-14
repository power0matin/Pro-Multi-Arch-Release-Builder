#!/usr/bin/env bash
# shellcheck disable=SC2155,SC2039

# =========================================================
# Pro Release Builder (Go, multi-arch) — senior-grade
# - Dynamic artifact prefix from input zip name
# - Deterministic packaging (reproducible)
# - Parallel builds with job limiting
# - Auto-detect main path, clear errors otherwise
# - Generates RELEASE.md and release.manifest.json
# Usage:
#   ./build.sh input/project.zip
# Env knobs:
#   BUILD_PATH       : override auto-detection (e.g. ./cmd/app)
#   OUTPUT_NAME      : binary name inside archives (default=project name)
#   ARTIFACT_PREFIX  : file prefix for assets (default=project name)
#   NUM_JOBS         : parallelism (default=CPU cores)
#   CGO_ENABLED      : default 0 for portable cross-compile
#   LDFLAGS          : default "-s -w"
#   GOFLAGS          : extra go build flags (default "-buildvcs=false -trimpath")
# =========================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
readonly SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1577836800}" # 2020-01-01 UTC for reproducibility

log()   { printf '\033[1;34m[INFO]\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
err()   { printf '\033[1;31m[ERR ]\033[0m %s\n'  "$*" >&2; }
die()   { err "$*"; exit 1; }

need()  { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

_cleanup=()
cleanup_push() { _cleanup+=("$*"); }
on_exit() {
  local st=$?
  for cmd in "${_cleanup[@]}"; do eval "$cmd" || true; done
  if (( st != 0 )); then err "Failed (exit=$st)"; fi
}
trap on_exit EXIT

# -------------------- args & checks -----------------------
INPUT_ZIP="${1:-}"
[[ -n "$INPUT_ZIP" ]] || die "Usage: ./build.sh input/project.zip"
[[ -f "$INPUT_ZIP" ]] || die "Input zip not found: $INPUT_ZIP"

for t in unzip zip tar sha256sum go python3; do need "$t"; done

# GNU tar flags detection (for reproducibility)
TAR_SORT="--sort=name"
TAR_NUM="--numeric-owner"
if ! tar --version 2>/dev/null | grep -qi 'gnu'; then
  warn "Non-GNU tar detected; reproducibility may be reduced"
  TAR_SORT=""
  TAR_NUM=""
fi

# -------------------- names & dirs ------------------------
ZIP_BASENAME="$(basename -- "${INPUT_ZIP}")"
PROJECT_NAME="${ZIP_BASENAME%.zip}"              # e.g. project.zip -> project
readonly PROJECT_NAME
readonly PROJECT_DIR="./${PROJECT_NAME}"
readonly SRC_DIR="${PROJECT_DIR}/src"
readonly ASSETS_DIR="${PROJECT_DIR}/Assets"
readonly MANIFEST="${PROJECT_DIR}/release.manifest.json"

: "${ARTIFACT_PREFIX:=${PROJECT_NAME}}"
: "${OUTPUT_NAME:=${PROJECT_NAME}}"
: "${CGO_ENABLED:=0}"
: "${LDFLAGS:=-s -w}"
: "${GOFLAGS:=-buildvcs=false -trimpath}"
: "${NUM_JOBS:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

mkdir -p "${SRC_DIR}" "${ASSETS_DIR}"
cleanup_push "rm -rf \"${PROJECT_DIR}.tmp\""
log "Project: ${PROJECT_NAME}"
log "Extracting -> ${SRC_DIR}"
unzip -q "${INPUT_ZIP}" -d "${SRC_DIR}"

# -------------------- detect main -------------------------
to_posix_rel() { python3 - "$1" <<'PY'
import os,sys
p=sys.argv[1]
print("./"+os.path.normpath(p).replace("\\","/").lstrip("./"))
PY
}

if [[ -z "${BUILD_PATH:-}" ]]; then
  log "Auto-detecting main package..."
  pushd "${SRC_DIR}" >/dev/null
    # Prefer cmd/*, then unique main
    mapfile -t mains < <(go list -f '{{if eq .Name "main"}}{{.Dir}}{{end}}' ./... | sed "s#^$(pwd)##" | sed 's#^#.#')
    # Filter validity: must contain 'func main('
    valid=()
    for d in "${mains[@]}"; do
      [[ -d "$d" ]] || continue
      if grep -Rsl --include='*.go' -E 'package +main' "$d" >/dev/null 2>&1 \
         && grep -Rsl --include='*.go' -E 'func +main\(' "$d" >/dev/null 2>&1; then
        valid+=("$d")
      fi
    done
    choose=""
    for d in "${valid[@]}"; do
      if [[ "$d" == ./cmd/* ]]; then choose="$d"; break; fi
    done
    if [[ -z "$choose" && "${#valid[@]}" -eq 1 ]]; then
      choose="${valid[0]}"
    fi
    if [[ -z "$choose" ]]; then
      err "Could not uniquely detect main. Candidates: ${valid[*]:-<none>}"
      err "Set BUILD_PATH (e.g. export BUILD_PATH=./cmd/${PROJECT_NAME}) and re-run."
      exit 2
    fi
    BUILD_PATH="$(to_posix_rel "$choose")"
  popd >/dev/null
  log "Detected BUILD_PATH=${BUILD_PATH}"
else
  BUILD_PATH="$(to_posix_rel "$BUILD_PATH")"
  log "Using BUILD_PATH=${BUILD_PATH}"
fi

# ----------------- reproducible env -----------------------
export TZ=UTC
export SOURCE_DATE_EPOCH
export GZIP=-n

# --------------- source exports (deterministic) -----------
log "Exporting sources (${PROJECT_NAME}-source.tar.gz/.zip)"
# tar.gz
( cd "${SRC_DIR}" && \
  tar -czf "../${PROJECT_NAME}-source.tar.gz" ${TAR_SORT} ${TAR_NUM} \
      --owner=0 --group=0 --mtime="@${SOURCE_DATE_EPOCH}" . )
# zip (strip extra fields)
( cd "${SRC_DIR}" && \
  zip -qr -X "../${PROJECT_NAME}-source.zip" . )

# -------------------- targets -----------------------------
# Required artifacts (archive suffixes are enforced below):
linux_targets=(
  "386::386"
  "amd64::amd64"
  "arm64::arm64"
  "arm:5:armv5"
  "arm:6:armv6"
  "arm:7:armv7"
  "s390x::s390x"
)
windows_targets=("amd64")

# --------------- build helpers (parallel) -----------------
pids=()
running_jobs() { jobs -rp | wc -l | tr -d ' '; }
wait_slot() {
  while (( $(running_jobs) >= NUM_JOBS )); do
    if wait -n 2>/dev/null; then :; else wait || true; fi
  done
}
sha_file_for() {  # sidecar name WITHOUT archive extension (per requirement)
  local pkg="$1"
  case "$pkg" in
    *.tar.gz) echo "${pkg%.tar.gz}.sha256" ;;
    *.zip)    echo "${pkg%.zip}.sha256" ;;
    *)        echo "${pkg}.sha256" ;;
  esac
}

build_one() {
  local goos="$1" goarch="$2" goarm="$3" suffix="$4" ext="$5"  # ext: tar.gz or zip
  local outdir; outdir="$(mktemp -d)"
  trap 'rm -rf "$outdir"' RETURN

  local bin="${OUTPUT_NAME}"
  local exe=""
  [[ "$goos" == "windows" ]] && exe=".exe"

  log "Building ${goos}/${goarch}${goarm:+ GOARM=$goarm} -> ${bin}${exe}"
  ( cd "${SRC_DIR}${BUILD_PATH/#./}" && \
     env CGO_ENABLED="${CGO_ENABLED}" GOOS="${goos}" GOARCH="${goarch}" ${goarm:+GOARM="${goarm}"} \
     go build -ldflags "${LDFLAGS}" ${GOFLAGS} -o "${outdir}/${bin}${exe}" . )

  local pkg="${ARTIFACT_PREFIX}-${goos}-${suffix}.${ext}"
  if [[ "$ext" == "tar.gz" ]]; then
    ( cd "${outdir}" && \
      tar -czf "${pkg}" ${TAR_SORT} ${TAR_NUM} --owner=0 --group=0 --mtime="@${SOURCE_DATE_EPOCH}" "${bin}" )
  else
    ( cd "${outdir}" && \
      zip -q -X "${pkg}" "${bin}${exe}" )
  fi

  # Sidecar checksum (filename without archive extension)
  ( cd "${outdir}" && \
    sha256sum "${pkg}" | awk -v p="${pkg}" '
      function base(n) {
        sub(/\.tar\.gz$/,"",n); sub(/\.zip$/,"",n); return n
      }
      { print $1 > base(p) ".sha256" }
    ' )

  mv "${outdir}/${pkg}" "${ASSETS_DIR}/"
  mv "${outdir}/$(basename "$(sha_file_for "${pkg}")")" "${ASSETS_DIR}/"
}

# ------------------ build all (parallel) ------------------
log "Starting parallel builds (NUM_JOBS=${NUM_JOBS})"

# Linux
for t in "${linux_targets[@]}"; do
  IFS=':' read -r arch arm suffix <<<"$t"
  goarch="$arch"
  goarm=""
  [[ -n "$arm" ]] && goarm="$arm"
  wait_slot
  build_one "linux" "${goarch}" "${goarm}" "${suffix}" "tar.gz" &
done

# Windows
for arch in "${windows_targets[@]}"; do
  wait_slot
  build_one "windows" "${arch}" "" "amd64" "zip" &
done

wait || true
log "All builds finished."

# ----------------- release listing & manifest --------------
log "Generating RELEASE.md and manifest"
python3 tools/release_list.py "${ASSETS_DIR}" \
  --manifest "${MANIFEST}" \
  > "${PROJECT_DIR}/RELEASE.md"

cat <<EOF

========================================================
Release ready at: ${PROJECT_DIR}
- Assets: ${ASSETS_DIR}
- Listing: ${PROJECT_DIR}/RELEASE.md
- Manifest: ${MANIFEST}
Started: ${START_TS}  |  Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)
========================================================
EOF
