#!/usr/bin/env bash
# Build the 22nd X AI backend image: upstream Onyx backend/ at the pinned tag plus
# product/deploy/backend-patch (new files in overlay/, then the numbered patches).
# Prints the image id on the last line.
#
# Usage: build-backend-image.sh [--source <git dir>] [--tag <image:tag>]... [--no-cache]
#   --source  Git directory that has the upstream tag (default: this repo).
#             When the tag is missing there, it is fetched from upstream.
#   --tag     Image name to apply; repeat for several. Default: onyx-backend:<tag>-axi
# Env: ONYX_RELEASE_TAG overrides the tag from product/deploy/release.env.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"
patch_dir="${here}/backend-patch"
overlay="${patch_dir}/overlay/backend"
upstream_url="https://github.com/onyx-dot-app/onyx"

source_dir="${repo_root}"
tags=()
no_cache=""
while (($# > 0)); do
  case "$1" in
    --source) source_dir="$2"; shift 2 ;;
    --tag) tags+=("$2"); shift 2 ;;
    --no-cache) no_cache="--no-cache"; shift ;;
    -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Tag and expected commit from release.env (no secrets in that file).
release_env="${repo_root}/product/deploy/release.env"
if [[ -z "${ONYX_RELEASE_TAG:-}" ]]; then
  ONYX_RELEASE_TAG="$(sed -n 's/^ONYX_RELEASE_TAG=//p' "${release_env}")"
fi
expected_commit="$(sed -n 's/^ONYX_RELEASE_COMMIT=//p' "${release_env}")"
if [[ ! "${ONYX_RELEASE_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ONYX_RELEASE_TAG is not a release tag: '${ONYX_RELEASE_TAG}'" >&2
  exit 2
fi
if ((${#tags[@]} == 0)); then
  tags=("onyx-backend:${ONYX_RELEASE_TAG}-axi")
fi

# The tag must exist in the source git directory; fetch it from upstream if not.
if ! git -C "${source_dir}" rev-parse -q --verify "refs/tags/${ONYX_RELEASE_TAG}^{commit}" >/dev/null; then
  echo "Fetching ${ONYX_RELEASE_TAG} from ${upstream_url}"
  git -C "${source_dir}" fetch --no-tags --depth=1 "${upstream_url}" \
    "refs/tags/${ONYX_RELEASE_TAG}:refs/tags/${ONYX_RELEASE_TAG}"
fi
commit="$(git -C "${source_dir}" rev-parse "refs/tags/${ONYX_RELEASE_TAG}^{commit}")"
if [[ -n "${expected_commit}" && "${commit}" != "${expected_commit}" ]]; then
  echo "Tag ${ONYX_RELEASE_TAG} is ${commit}, release.env expects ${expected_commit}" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/axi-backend-build.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

echo "Exporting backend/ from ${ONYX_RELEASE_TAG} (${commit})"
git -C "${source_dir}" archive "${ONYX_RELEASE_TAG}" backend | tar -x -C "${work}"

# The overlay only adds files. Upstream files change only through the reviewed patches.
while IFS= read -r -d '' file; do
  rel="${file#"${overlay}/"}"
  if [[ -e "${work}/backend/${rel}" ]]; then
    echo "Overlay file would replace an upstream file: backend/${rel}" >&2
    exit 1
  fi
  mkdir -p "$(dirname "${work}/backend/${rel}")"
  cp "${file}" "${work}/backend/${rel}"
  echo "overlay: backend/${rel}"
done < <(find "${overlay}" -type f ! -name '*.pyc' ! -path '*/__pycache__/*' -print0 | sort -z)

# Patches are relative to backend/ (patch -p1). Every hunk must apply exactly (no fuzz);
# a reject stops the build.
patches=()
while IFS= read -r -d '' p; do patches+=("${p}"); done \
  < <(find "${patch_dir}" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.patch' -print0 | sort -z)
if ((${#patches[@]} == 0)); then
  echo "No patches found in ${patch_dir}" >&2
  exit 1
fi
for p in "${patches[@]}"; do
  echo "patch: $(basename "${p}")"
  patch --directory="${work}/backend" -p1 --forward --batch --fuzz=0 --no-backup-if-mismatch \
    --reject-file=- <"${p}"
done

tag_args=()
for tag in "${tags[@]}"; do tag_args+=(--tag "${tag}"); done

iidfile="${work}/image-id"
DOCKER_BUILDKIT=1 docker build ${no_cache} \
  --file "${work}/backend/Dockerfile" \
  --target runtime \
  --label "org.opencontainers.image.source=${upstream_url}" \
  --label "org.opencontainers.image.version=${ONYX_RELEASE_TAG}-axi" \
  --label "org.opencontainers.image.revision=${commit}" \
  --build-arg "ONYX_VERSION=${ONYX_RELEASE_TAG}" \
  "${tag_args[@]}" \
  --iidfile "${iidfile}" \
  "${work}/backend"

echo "Image tags: ${tags[*]}"
printf '%s\n' "$(cat "${iidfile}")"
