#!/usr/bin/env bash
set -euo pipefail

# Offline mocked test suite for scripts/onboard_folder.sh.
# Uses temporary directories and stub `tofu` / `gh` binaries with zero network or GCP calls.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONBOARD_SCRIPT="${SCRIPT_DIR}/onboard_folder.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

STUB_BIN="${TMP_ROOT}/bin"
mkdir -p "${STUB_BIN}"
TOFU_LOG="${TMP_ROOT}/tofu_calls.log"
GH_LOG="${TMP_ROOT}/gh_calls.log"
export TOFU_LOG GH_LOG

cat > "${STUB_BIN}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TOFU_LOG}"
exit 0
EOF
chmod +x "${STUB_BIN}/tofu"

cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_LOG}"
echo "https://github.com/x-ruiz/platform_gcp_org_bootstrap/pull/99"
exit 0
EOF
chmod +x "${STUB_BIN}/gh"

export PATH="${STUB_BIN}:${PATH}"

pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "${msg} (expected to contain: ${needle})"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "${msg} (unexpected substring: ${needle})"
  fi
}

FOLDERS_DIR="${TMP_ROOT}/folders"
mkdir -p "${FOLDERS_DIR}"

# --- Test 1: Onboard a CI-enabled folder ---
: > "${TOFU_LOG}"
ONBOARD_FOLDERS_DIR="${FOLDERS_DIR}" bash "${ONBOARD_SCRIPT}" \
  --non-interactive \
  --folder-key "ai-platform" \
  --display-name "AI Platform" \
  --github-repo "x-ruiz/platform-ai-gcp" \
  --var-prefix "AI_GCP" >/dev/null

[[ -f "${FOLDERS_DIR}/ai-platform.yaml" ]] || fail "Test 1: ai-platform.yaml not created"
yaml_1="$(cat "${FOLDERS_DIR}/ai-platform.yaml")"
assert_contains "$yaml_1" 'display_name: "AI Platform"' "Test 1: display_name written"
assert_contains "$yaml_1" 'deletion_protection: true' "Test 1: deletion_protection defaults true"
assert_contains "$yaml_1" 'github_repository: "x-ruiz/platform-ai-gcp"' "Test 1: github_repository written"
assert_contains "$yaml_1" 'github_var_prefix: "AI_GCP"' "Test 1: github_var_prefix written"
assert_contains "$(cat "${TOFU_LOG}")" "validate" "Test 1: tofu validate ran"
assert_contains "$(cat "${TOFU_LOG}")" "test" "Test 1: tofu test ran"
pass "Test 1: Onboards CI-enabled folder manifest and runs local OpenTofu checks"

# --- Test 2: Onboard a plain folder (--no-ci) ---
ONBOARD_FOLDERS_DIR="${FOLDERS_DIR}" bash "${ONBOARD_SCRIPT}" \
  --non-interactive \
  --skip-verify \
  --folder-key "sandbox" \
  --deletion-protection false \
  --no-ci >/dev/null

yaml_2="$(cat "${FOLDERS_DIR}/sandbox.yaml")"
assert_contains "$yaml_2" 'display_name: "sandbox"' "Test 2: display_name defaults to folder key"
assert_contains "$yaml_2" 'deletion_protection: false' "Test 2: deletion_protection honored"
assert_not_contains "$yaml_2" 'github_repository' "Test 2: plain folder omits ci block"
pass "Test 2: Onboards plain folder without CI bindings"

# --- Test 3: Rejects duplicate without --update; allows updating repo with --update ---
set +e
ONBOARD_FOLDERS_DIR="${FOLDERS_DIR}" bash "${ONBOARD_SCRIPT}" \
  --non-interactive \
  --skip-verify \
  --folder-key "ai-platform" \
  --github-repo "x-ruiz/new-ai-repo" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "Test 3: expected exit 2 on duplicate folder without --update, got ${rc}"

ONBOARD_FOLDERS_DIR="${FOLDERS_DIR}" bash "${ONBOARD_SCRIPT}" \
  --non-interactive \
  --skip-verify \
  --update \
  --folder-key "ai-platform" \
  --github-repo "x-ruiz/platform-ai-standalone" >/dev/null

yaml_updated="$(cat "${FOLDERS_DIR}/ai-platform.yaml")"
assert_contains "$yaml_updated" 'display_name: "AI Platform"' "Test 3: existing display_name preserved on --update"
assert_contains "$yaml_updated" 'github_var_prefix: "AI_GCP"' "Test 3: existing var prefix preserved on --update"
assert_contains "$yaml_updated" 'github_repository: "x-ruiz/platform-ai-standalone"' "Test 3: github_repository updated"
pass "Test 3: Blocks duplicate without --update and preserves metadata on --update"

# --- Test 4: Dry-run writes no file and calls no tofu ---
: > "${TOFU_LOG}"
dry_out="$(ONBOARD_FOLDERS_DIR="${FOLDERS_DIR}" bash "${ONBOARD_SCRIPT}" \
  --non-interactive \
  --dry-run \
  --open-pr \
  --folder-key "ml-platform" \
  --github-repo "x-ruiz/platform-ml-gcp")"
[[ ! -f "${FOLDERS_DIR}/ml-platform.yaml" ]] || fail "Test 4: --dry-run must not write file"
[[ ! -s "${TOFU_LOG}" ]] || fail "Test 4: --dry-run must not run tofu"
assert_contains "$dry_out" 'github_var_prefix: "ML_PLATFORM"' "Test 4: derived default var prefix printed"
assert_contains "$dry_out" "Would create branch 'feat/onboard-folder-ml-platform'" "Test 4: dry-run prints PR plan"
pass "Test 4: Dry-run performs zero file/git/tofu mutations"

# --- Test 5: Invalid inputs exit 2 with zero mutations ---
set +e
ONBOARD_FOLDERS_DIR="${FOLDERS_DIR}" bash "${ONBOARD_SCRIPT}" \
  --non-interactive \
  --skip-verify \
  --folder-key "BAD_KEY" \
  --github-repo "not-a-repo" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "Test 5: expected exit 2 on invalid folder key/repo, got ${rc}"
[[ ! -f "${FOLDERS_DIR}/BAD_KEY.yaml" ]] || fail "Test 5: must not write invalid manifest"
pass "Test 5: Invalid folder key and repo format fail fast with exit 2"

printf '\nAll onboard_folder.sh tests passed!\n'
