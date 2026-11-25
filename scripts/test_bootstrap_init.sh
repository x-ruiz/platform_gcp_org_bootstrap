#!/usr/bin/env bash
set -euo pipefail

# Offline mocked test suite for scripts/bootstrap_init.sh.
# Uses temporary stub `gcloud`, `gh`, and `tofu` binaries on PATH with zero network or GCP calls.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/bootstrap_init.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

STUB_BIN="${TMP_ROOT}/bin"
mkdir -p "${STUB_BIN}"
GCLOUD_LOG="${TMP_ROOT}/gcloud_calls.log"
TOFU_LOG="${TMP_ROOT}/tofu_calls.log"
export GCLOUD_LOG TOFU_LOG

cat > "${STUB_BIN}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TOFU_LOG}"
for arg in "$@"; do
  if [[ "$arg" == -out=* ]]; then
    touch "${arg#-out=}"
  fi
done
exit 0
EOF
chmod +x "${STUB_BIN}/tofu"

cat > "${STUB_BIN}/gcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GCLOUD_LOG}"
case "$*" in
  "config get-value account")
    echo "admin@example.com"
    ;;
  "organizations list --format=value(ID)")
    echo "846182627456"
    ;;
  "billing accounts list --filter=open=true --format=value(ACCOUNT_ID)")
    echo "billingAccounts/01ABCD-23EFGH-45IJKL"
    ;;
  "organizations add-iam-policy-binding "*)
    exit 0
    ;;
  "billing accounts get-iam-policy "*)
    if [[ "${STUB_BILLING_FAIL:-false}" == "true" ]]; then
      echo "ERROR: PERMISSION_DENIED" >&2
      exit 1
    fi
    cat <<'JSON'
{"bindings":[{"members":["user:admin@example.com"],"role":"roles/billing.admin"}]}
JSON
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${STUB_BIN}/gcloud"

cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "auth token" ]]; then
  echo "gho_stub_test_token"
  exit 0
fi
exit 0
EOF
chmod +x "${STUB_BIN}/gh"

export PATH="${STUB_BIN}:${PATH}"
unset GITHUB_TOKEN || true
export BOOTSTRAP_BILLING_RETRIES=1
export BOOTSTRAP_BILLING_DELAY_SECONDS=0
export BOOTSTRAP_IAM_WAIT_SECONDS=0

pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "${msg} (expected to contain: ${needle})"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "${msg} (unexpected substring: ${needle})"
  fi
}

# --- Test 1: Happy path auto-discovery, base Org IAM (incl. orgpolicy), tfvars, and tofu init/plan/apply ---
: > "${GCLOUD_LOG}"
: > "${TOFU_LOG}"
TFVARS_1="${TMP_ROOT}/happy.tfvars"
BOOTSTRAP_TFVARS_PATH="${TFVARS_1}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --auto-approve \
  --skip-adc-check \
  --github-owner "x-ruiz" \
  --seed-project-id "org-seed-test-001" >/dev/null

[[ -f "${TFVARS_1}" ]] || fail "Test 1: terraform.tfvars was not created"
tfvars_content="$(cat "${TFVARS_1}")"
assert_contains "$tfvars_content" 'org_id             = "846182627456"' "Test 1: org_id auto-discovered"
assert_contains "$tfvars_content" 'billing_account_id = "01ABCD-23EFGH-45IJKL"' "Test 1: billing_account_id auto-discovered"
assert_contains "$tfvars_content" 'github_owner       = "x-ruiz"' "Test 1: github_owner written"
assert_contains "$tfvars_content" 'seed_project_id    = "org-seed-test-001"' "Test 1: seed_project_id written"
assert_contains "$tfvars_content" 'folders      = {}' "Test 1: folders map scaffolded"
assert_contains "$tfvars_content" 'org_policies = {}' "Test 1: org_policies map scaffolded"
assert_not_contains "$tfvars_content" 'dev_project_id' "Test 1: platform dev_project_id must not appear in org bootstrap tfvars"
assert_not_contains "$tfvars_content" 'budget_alert_email' "Test 1: platform budget_alert_email must not appear in org bootstrap tfvars"

gcloud_calls="$(cat "${GCLOUD_LOG}")"
assert_contains "$gcloud_calls" "organizations add-iam-policy-binding 846182627456 --member=user:admin@example.com --role=roles/resourcemanager.folderAdmin" "Test 1: folderAdmin bound"
assert_contains "$gcloud_calls" "organizations add-iam-policy-binding 846182627456 --member=user:admin@example.com --role=roles/resourcemanager.projectCreator" "Test 1: projectCreator bound"
assert_contains "$gcloud_calls" "organizations add-iam-policy-binding 846182627456 --member=user:admin@example.com --role=roles/billing.admin" "Test 1: billing.admin bound"
assert_contains "$gcloud_calls" "organizations add-iam-policy-binding 846182627456 --member=user:admin@example.com --role=roles/orgpolicy.policyAdmin" "Test 1: orgpolicy.policyAdmin bound"
assert_contains "$gcloud_calls" "billing accounts get-iam-policy 01ABCD-23EFGH-45IJKL" "Test 1: billing IAM verified"

tofu_calls="$(cat "${TOFU_LOG}")"
assert_contains "$tofu_calls" "init -input=false" "Test 1: tofu init executed"
assert_contains "$tofu_calls" "plan -input=false -var-file=${TFVARS_1}" "Test 1: tofu plan executed with tfvars"
assert_contains "$tofu_calls" "apply -input=false" "Test 1: tofu apply executed"
pass "Test 1: Auto-discovery, base Org IAM (+ orgpolicy.policyAdmin), decoupled tfvars, and tofu init/plan/apply"

# --- Test 2: --skip-apply runs init + plan only ---
: > "${TOFU_LOG}"
BOOTSTRAP_TFVARS_PATH="${TFVARS_1}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --skip-apply \
  --skip-adc-check >/dev/null
tofu_calls="$(cat "${TOFU_LOG}")"
assert_contains "$tofu_calls" "init -input=false" "Test 2: tofu init executed"
assert_contains "$tofu_calls" "plan -input=false" "Test 2: tofu plan executed"
if grep -q "apply -input=false" "${TOFU_LOG}"; then
  fail "Test 2: --skip-apply must not invoke tofu apply"
fi
pass "Test 2: --skip-apply runs tofu init + plan and skips apply"

# --- Test 3: Invalid org_id or unsafe --non-interactive fails fast (exit 2) ---
: > "${GCLOUD_LOG}"
: > "${TOFU_LOG}"
TFVARS_BAD="${TMP_ROOT}/bad.tfvars"
set +e
BOOTSTRAP_TFVARS_PATH="${TFVARS_BAD}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --auto-approve \
  --skip-adc-check \
  --org-id "not-numeric" \
  --github-owner "x-ruiz" \
  --seed-project-id "org-seed-test-001" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "Test 3: expected exit code 2 for invalid org_id, got ${rc}"
[[ ! -f "${TFVARS_BAD}" ]] || fail "Test 3: terraform.tfvars should not be written on validation failure"
if grep -q "add-iam-policy-binding" "${GCLOUD_LOG}" || [[ -s "${TOFU_LOG}" ]]; then
  fail "Test 3: should not mutate GCP or call tofu when validation fails"
fi

set +e
BOOTSTRAP_TFVARS_PATH="${TFVARS_BAD}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --skip-adc-check \
  --github-owner "x-ruiz" \
  --seed-project-id "org-seed-test-001" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "Test 3: expected exit code 2 when --non-interactive lacks --auto-approve/--skip-apply, got ${rc}"
pass "Test 3: Invalid org_id and unsafe --non-interactive exit 2 with zero mutations"

# --- Test 4: Missing billing admin permission exits 1 without writing tfvars or calling tofu ---
: > "${TOFU_LOG}"
TFVARS_NOBILL="${TMP_ROOT}/nobill.tfvars"
set +e
STUB_BILLING_FAIL="true" BOOTSTRAP_TFVARS_PATH="${TFVARS_NOBILL}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --auto-approve \
  --skip-adc-check \
  --github-owner "x-ruiz" \
  --seed-project-id "org-seed-test-001" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "Test 4: expected exit code 1 when billing IAM check fails, got ${rc}"
[[ ! -f "${TFVARS_NOBILL}" ]] || fail "Test 4: terraform.tfvars should not be written when billing IAM fails"
[[ ! -s "${TOFU_LOG}" ]] || fail "Test 4: tofu must not run when billing IAM fails"
pass "Test 4: Missing billing.admin fails clearly with exit 1 before tfvars or tofu"

# --- Test 5: Dry-run performs zero GCP mutations, zero tofu calls, and writes no file ---
: > "${GCLOUD_LOG}"
: > "${TOFU_LOG}"
TFVARS_DRY="${TMP_ROOT}/dry.tfvars"
dry_out="$(BOOTSTRAP_TFVARS_PATH="${TFVARS_DRY}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --skip-adc-check \
  --dry-run \
  --github-owner "x-ruiz" \
  --seed-project-id "org-seed-dry-001")"
[[ ! -f "${TFVARS_DRY}" ]] || fail "Test 5: --dry-run must not write terraform.tfvars"
if grep -q "add-iam-policy-binding" "${GCLOUD_LOG}" || [[ -s "${TOFU_LOG}" ]]; then
  fail "Test 5: --dry-run must not call add-iam-policy-binding or tofu"
fi
assert_contains "$dry_out" 'seed_project_id    = "org-seed-dry-001"' "Test 5: --dry-run prints rendered tfvars"
assert_contains "$dry_out" "Would run: tofu -chdir=" "Test 5: --dry-run prints planned tofu commands"
pass "Test 5: Dry-run performs zero GCP mutations, zero tofu calls, and writes no files"

# --- Test 6: Re-running preserves existing multi-folder / org-policy terraform.tfvars untouched ---
: > "${GCLOUD_LOG}"
: > "${TOFU_LOG}"
cat > "${TFVARS_1}" <<'EOF'
org_id             = "111222333444"
billing_account_id = "99AAAA-88BBBB-77CCCC"
github_owner       = "custom-org"
bootstrap_name     = "custom-org-bootstrap"
seed_project_id    = "org-seed-custom-009"
seed_project_name  = "Custom Seed"
region             = "us-east1"
cost_center        = "platform-core"

folders = {
  data-platform = {
    display_name = "data-platform"
  }
}

org_policies = {
  "iam.disableServiceAccountKeyCreation" = {
    rules = [{ enforce = true }]
  }
}
EOF

BOOTSTRAP_TFVARS_PATH="${TFVARS_1}" bash "${BOOTSTRAP_SCRIPT}" \
  --non-interactive \
  --skip-apply \
  --skip-adc-check >/dev/null

tfvars_rerun="$(cat "${TFVARS_1}")"
assert_contains "$tfvars_rerun" 'data-platform = {' "Test 6: existing folders map preserved untouched"
assert_contains "$tfvars_rerun" '"iam.disableServiceAccountKeyCreation" = {' "Test 6: existing org_policies map preserved untouched"
assert_contains "$tfvars_rerun" 'org_id             = "111222333444"' "Test 6: existing org_id preserved"
pass "Test 6: Re-run preserves existing multi-folder and org-policy terraform.tfvars untouched"

printf '\nAll bootstrap_init.sh tests passed!\n'
