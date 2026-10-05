#!/usr/bin/env bash
# Check product/deploy/backend-patch against an upstream Onyx tag before a version bump.
# Exports backend/ at the tag, dry-runs every patch, checks that the overlay adds files
# only, and checks that the upstream names the overlay uses still exist.
# Prints PASS or FAIL per item; exit status 1 when an item fails.
#
# Usage: check-upstream.sh <tag> [--source <git dir>]
#   --source  Git directory that has the tag (default: this repo).
#             When the tag is missing there, it is fetched from upstream.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../.." && pwd)"
overlay="${here}/overlay/backend"
upstream_url="https://github.com/onyx-dot-app/onyx"

tag=""
source_dir="${repo_root}"
while (($# > 0)); do
  case "$1" in
    --source) source_dir="$2"; shift 2 ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) tag="$1"; shift ;;
  esac
done
if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: check-upstream.sh <tag, for example v4.8.4> [--source <git dir>]" >&2
  exit 2
fi

if ! git -C "${source_dir}" rev-parse -q --verify "refs/tags/${tag}^{commit}" >/dev/null; then
  echo "Fetching ${tag} from ${upstream_url}"
  git -C "${source_dir}" fetch --no-tags --depth=1 "${upstream_url}" \
    "refs/tags/${tag}:refs/tags/${tag}"
fi
commit="$(git -C "${source_dir}" rev-parse "refs/tags/${tag}^{commit}")"

work="$(mktemp -d "${TMPDIR:-/tmp}/axi-backend-check.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
git -C "${source_dir}" archive "${tag}" backend | tar -x -C "${work}"
backend="${work}/backend"
echo "Checking backend-patch against ${tag} (${commit})"

failed=0
result() {
  # result <PASS|FAIL> <text>
  echo "$1 $2"
  [[ "$1" == PASS ]] || failed=1
}

# 1. Every patch applies exactly (no fuzz).
while IFS= read -r -d '' p; do
  name="$(basename "${p}")"
  if patch --directory="${backend}" -p1 --forward --batch --fuzz=0 --dry-run <"${p}" >/dev/null; then
    result PASS "patch applies: ${name}"
  else
    result FAIL "patch applies: ${name}"
  fi
done < <(find "${here}" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.patch' -print0 | sort -z)

# 2. The overlay adds files only.
while IFS= read -r -d '' file; do
  rel="${file#"${overlay}/"}"
  if [[ -e "${backend}/${rel}" ]]; then
    result FAIL "overlay file is new: backend/${rel} (upstream has it)"
  else
    result PASS "overlay file is new: backend/${rel}"
  fi
done < <(find "${overlay}" -type f ! -name '*.pyc' ! -path '*/__pycache__/*' -print0 | sort -z)

# 3. Upstream names that the overlay and the patches use. Format: file|fixed string.
needles=(
  "Dockerfile|COPY --chown=onyx:onyx ./onyx /app/onyx"
  "Dockerfile|AS runtime"
  "ee/onyx/server/tenants/provisioning.py|async def setup_tenant("
  "ee/onyx/server/tenants/provisioning.py|setup_onyx(db_session, tenant_id, cohere_enabled=cohere_enabled)"
  "onyx/db/llm.py|def fetch_default_llm_model("
  "onyx/db/llm.py|def fetch_existing_llm_provider_by_name_and_type("
  "onyx/db/llm.py|def update_default_provider("
  "onyx/db/llm.py|def upsert_llm_provider("
  "onyx/db/models.py|class LLMProvider(Base)"
  "onyx/db/models.py|class VoiceProvider(Base)"
  "onyx/db/models.py|class InternetSearchProvider(Base)"
  "onyx/db/models.py|class InternetContentProvider(Base)"
  "onyx/db/models.py|class CodeInterpreterServer(Base)"
  "onyx/db/models.py|server_enabled: Mapped[bool]"
  "onyx/db/models.py|class KVStore(Base)"
  "onyx/db/models.py|value: Mapped[JSON_ro]"
  "onyx/db/models.py|class EncryptedString(_EncryptedBase)"
  "onyx/db/models.py|def wrap_raw("
  "onyx/db/models.py|def _register_sensitive_value_set_events("
  "onyx/utils/sensitive.py|def get_value("
  "onyx/db/web_search.py|def fetch_web_search_providers("
  "onyx/db/web_search.py|def fetch_active_web_content_provider("
  "onyx/db/web_search.py|def upsert_web_search_provider("
  "onyx/db/web_search.py|api_key_changed: bool,"
  "onyx/db/web_search.py|activate: bool,"
  "onyx/tools/tool_implementations/web_search/providers.py|def build_search_provider_from_config("
  "shared_configs/enums.py|class WebSearchProviderType("
  "onyx/configs/app_configs.py|ENCRYPTION_KEY_SECRET = "
  "onyx/utils/variable_functionality.py|global_version = OnyxVersion()"
  "onyx/utils/variable_functionality.py|def is_ee_version("
  "onyx/db/persona.py|def get_default_assistant("
  "onyx/db/persona.py|def update_default_assistant_configuration("
  "onyx/db/persona.py|update_system_prompt: bool"
  "onyx/prompts/chat_prompts.py|DEFAULT_SYSTEM_PROMPT = "
  "onyx/server/manage/llm/models.py|class LLMProviderUpsertRequest("
  "onyx/server/manage/llm/models.py|class ModelConfigurationUpsertRequest("
  "onyx/server/manage/llm/models.py|custom_config_changed: bool"
  "onyx/server/manage/llm/provider_cache.py|def invalidate_provider_listing_cache("
  "onyx/server/manage/llm/api.py|def _validate_llm_provider_change("
  "onyx/db/engine/sql_engine.py|class SqlEngine"
  "onyx/db/engine/sql_engine.py|def get_session_with_tenant("
  "onyx/db/engine/tenant_utils.py|def get_all_tenant_ids("
  "onyx/utils/variable_functionality.py|def set_is_ee_based_on_env_variable("
  "onyx/utils/logger.py|def setup_logger("
  "shared_configs/contextvars.py|CURRENT_TENANT_ID_CONTEXTVAR"
)
for needle in "${needles[@]}"; do
  file="${needle%%|*}"
  text="${needle#*|}"
  if [[ -f "${backend}/${file}" ]] && grep -qF -- "${text}" "${backend}/${file}"; then
    result PASS "upstream has: ${file}: ${text}"
  else
    result FAIL "upstream has: ${file}: ${text}"
  fi
done

# 4. The patched tree compiles (patches applied for real in the temporary export).
if ((failed == 0)); then
  for p in "${here}"/[0-9][0-9][0-9][0-9]-*.patch; do
    patch --directory="${backend}" -p1 --forward --batch --fuzz=0 --quiet <"${p}"
  done
  cp -R "${overlay}/." "${backend}/"
  mapfile -t touched < <(
    {
      sed -n 's|^+++ b/\([^[:space:]]*\).*|\1|p' "${here}"/[0-9][0-9][0-9][0-9]-*.patch
      (cd "${overlay}" && find . -name '*.py' | sed 's|^\./||')
    } | sort -u
  )
  if (cd "${backend}" && python3 -m py_compile "${touched[@]}"); then
    result PASS "patched files compile: ${touched[*]}"
  else
    result FAIL "patched files compile"
  fi
fi

if ((failed)); then
  echo "RESULT: FAIL (${tag})"
  exit 1
fi
echo "RESULT: PASS (${tag})"
