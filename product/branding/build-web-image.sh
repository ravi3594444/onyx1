#!/usr/bin/env bash
# Build the 22nd X AI web image: upstream Onyx web/ at the pinned tag plus
# product/branding/web-overlay. Prints the image id on the last line.
#
# Usage: build-web-image.sh [--source <git dir>] [--tag <image:tag>]... [--no-cache]
#   --source  Git directory that has the upstream tag (default: this repo).
#             When the tag is missing there, it is fetched from upstream.
#   --tag     Image name to apply; repeat for several. Default: onyx-web-server:<tag>-axi
# Env: ONYX_RELEASE_TAG overrides the tag from product/deploy/release.env.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"
overlay="${here}/web-overlay/web"
upstream_url="https://github.com/onyx-dot-app/onyx"

source_dir="${repo_root}"
tags=()
no_cache=""
# --cloud builds the multi-tenant variant: NEXT_PUBLIC_CLOUD_ENABLED is a Next.js build-time
# value, so the single-tenant and the multi-tenant stacks need two images.
cloud=""
while (($# > 0)); do
  case "$1" in
    --source) source_dir="$2"; shift 2 ;;
    --tag) tags+=("$2"); shift 2 ;;
    --no-cache) no_cache="--no-cache"; shift ;;
    --cloud) cloud=1; shift ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
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
variant="axi${cloud:+-cloud}"
if ((${#tags[@]} == 0)); then
  tags=("onyx-web-server:${ONYX_RELEASE_TAG}-${variant}")
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

work="$(mktemp -d "${TMPDIR:-/tmp}/axi-web-build.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

echo "Exporting web/ from ${ONYX_RELEASE_TAG} (${commit})"
git -C "${source_dir}" archive "${ONYX_RELEASE_TAG}" web | tar -x -C "${work}"

# Overlay files replace upstream files at the same path. New files are allowed
# only where the README lists them.
new_files=(src/lib/branding.ts src/components/branding/BrandMark.tsx public/axi-logo.png)
while IFS= read -r -d '' file; do
  rel="${file#"${overlay}/"}"
  if [[ ! -e "${work}/web/${rel}" ]]; then
    found=""
    for allowed in "${new_files[@]}"; do [[ "${rel}" == "${allowed}" ]] && found=1; done
    if [[ -z "${found}" ]]; then
      echo "Overlay file has no upstream counterpart: web/${rel}" >&2
      exit 1
    fi
  fi
  mkdir -p "$(dirname "${work}/web/${rel}")"
  cp "${file}" "${work}/web/${rel}"
  echo "overlay: web/${rel}"
done < <(find "${overlay}" -type f -print0 | sort -z)

# Same build args as the upstream release workflow for the public image
# (.github/workflows/deployment.yml), without the Docker Hardened Image bases.
build_args=(
  --build-arg "ONYX_VERSION=${ONYX_RELEASE_TAG}"
  --build-arg "NODE_OPTIONS=--max-old-space-size=8192"
)
if [[ -n "${cloud}" ]]; then
  build_args+=(--build-arg "NEXT_PUBLIC_CLOUD_ENABLED=true")
fi
tag_args=()
for tag in "${tags[@]}"; do tag_args+=(--tag "${tag}"); done

iidfile="${work}/image-id"
DOCKER_BUILDKIT=1 docker build ${no_cache} \
  --file "${work}/web/Dockerfile" \
  --label "org.opencontainers.image.source=${upstream_url}" \
  --label "org.opencontainers.image.version=${ONYX_RELEASE_TAG}-${variant}" \
  --label "org.opencontainers.image.revision=${commit}" \
  "${build_args[@]}" "${tag_args[@]}" \
  --iidfile "${iidfile}" \
  "${work}/web"

echo "Image tags: ${tags[*]}"
printf '%s\n' "$(cat "${iidfile}")"
