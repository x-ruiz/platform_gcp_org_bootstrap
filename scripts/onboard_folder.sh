#!/usr/bin/env bash
set -euo pipefail

# Onboard a new GCP Folder (or update an existing folder's downstream GitHub repository)
# by generating a Git-tracked folders/<folder-key>.yaml manifest, verifying OpenTofu,
# and optionally opening a GitHub PR via `gh pr create`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FOLDERS_DIR="${ONBOARD_FOLDERS_DIR:-${REPO_DIR}/folders}"

FOLDER_KEY=""
DISPLAY_NAME=""
DELETION_PROTECTION="true"
ENABLE_CI=""
GITHUB_REPO=""
APPLY_BRANCH="main"
GITHUB_VAR_PREFIX=""
FOLDER_ID_VAR_SUFFIX="FOLDER_ID"
PLAN_SA_ID=""
APPLY_SA_ID=""
GRANT_BILLING_ACCESS="true"
SYNC_GITHUB_VARS="true"

UPDATE_EXISTING="false"
OPEN_PR="false"
SKIP_VERIFY="false"
NON_INTERACTIVE="false"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage: onboard_folder.sh [OPTIONS]

Creates (or updates with --update) a declarative folders/<folder-key>.yaml manifest,
runs local OpenTofu validation/tests, and optionally creates a branch + PR via `gh`.

Options:
  --folder-key <slug>           Folder map key & filename (3-30 lowercase letters/digits/hyphens)
  --display-name <name>         GCP Folder display name (3-30 chars; defaults to --folder-key)
  --deletion-protection <bool>  true | false (default: true)
  --no-ci                       Create a plain GCP folder without GitHub Actions WIF / CI SAs
  --github-repo <owner/repo>    Downstream GitOps repository allowed to deploy into this folder
  --apply-branch <branch>       Branch allowed to impersonate the apply SA (default: main)
  --var-prefix <PREFIX>         GitHub Actions variable prefix (e.g., AI_GCP; default: derived from key)
  --folder-id-suffix <SUFFIX>   Suffix for folder ID var (default: FOLDER_ID)
  --plan-sa-id <id>             Optional custom plan SA account_id (6-30 lowercase chars)
  --apply-sa-id <id>            Optional custom apply SA account_id (6-30 lowercase chars)
  --grant-billing-access <bool> Grant apply SA billing.user/costsManager (default: true)
  --sync-github-vars <bool>     Manage 7 org-owned GitHub Actions vars (default: true)
  --update                      Allow updating an existing folders/<folder-key>.yaml manifest
  --open-pr                     Create a git branch, commit, push, and open a PR via `gh pr create`
  --skip-verify                 Skip local `tofu validate` and `tofu test` checks
  --non-interactive             Never prompt on stdin (all required values must be passed via flags)
  --dry-run                     Validate inputs and preview YAML + planned git/gh actions without writing
  -h, --help                    Show this help message and exit
EOF
}

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_err() { printf '[ERROR] %s\n' "$*" >&2; }
die_prereq() { log_err "$*"; exit 1; }
die_usage() { log_err "$*"; exit 2; }

require_arg_value() {
  local flag="$1"
  local remaining="$2"
  if [[ "$remaining" -lt 2 ]]; then
    die_usage "Missing value for ${flag}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --folder-key) require_arg_value "$1" "$#"; FOLDER_KEY="$2"; shift 2 ;;
      --display-name) require_arg_value "$1" "$#"; DISPLAY_NAME="$2"; shift 2 ;;
      --deletion-protection) require_arg_value "$1" "$#"; DELETION_PROTECTION="$2"; shift 2 ;;
      --no-ci) ENABLE_CI="false"; shift ;;
      --github-repo) require_arg_value "$1" "$#"; GITHUB_REPO="$2"; ENABLE_CI="true"; shift 2 ;;
      --apply-branch) require_arg_value "$1" "$#"; APPLY_BRANCH="$2"; shift 2 ;;
      --var-prefix) require_arg_value "$1" "$#"; GITHUB_VAR_PREFIX="$2"; shift 2 ;;
      --folder-id-suffix) require_arg_value "$1" "$#"; FOLDER_ID_VAR_SUFFIX="$2"; shift 2 ;;
      --plan-sa-id) require_arg_value "$1" "$#"; PLAN_SA_ID="$2"; shift 2 ;;
      --apply-sa-id) require_arg_value "$1" "$#"; APPLY_SA_ID="$2"; shift 2 ;;
      --grant-billing-access) require_arg_value "$1" "$#"; GRANT_BILLING_ACCESS="$2"; shift 2 ;;
      --sync-github-vars) require_arg_value "$1" "$#"; SYNC_GITHUB_VARS="$2"; shift 2 ;;
      --update) UPDATE_EXISTING="true"; shift ;;
      --open-pr) OPEN_PR="true"; shift ;;
      --skip-verify) SKIP_VERIFY="true"; shift ;;
      --non-interactive) NON_INTERACTIVE="true"; shift ;;
      --dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die_usage "Unknown argument: $1 (use --help for usage)" ;;
    esac
  done
}

prompt_value() {
  local label="$1"
  local default_val="$2"
  local result="$default_val"

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    printf '%s' "$result"
    return 0
  fi

  if [[ -n "$default_val" ]]; then
    printf '%s [%s]: ' "$label" "$default_val" >&2
  else
    printf '%s: ' "$label" >&2
  fi

  local input=""
  if IFS= read -r input; then
    if [[ -n "$input" ]]; then
      result="$input"
    fi
  fi
  printf '%s' "$result"
}

read_existing_yaml_field() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 0
  awk -v k="$key" '
    $0 ~ "^[[:space:]]*" k ":[[:space:]]*" {
      sub("^[[:space:]]*" k ":[[:space:]]*", "", $0)
      sub("[[:space:]]*(#.*)?$", "", $0)
      gsub("^\"|\"$", "", $0)
      print $0
      exit
    }
  ' "$file"
}

derive_var_prefix() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

validate_bool() {
  local name="$1"
  local val="$2"
  if [[ "$val" != "true" && "$val" != "false" ]]; then
    log_err "Invalid ${name} '${val}'. Must be 'true' or 'false'."
    return 1
  fi
  return 0
}

validate_inputs() {
  local valid="true"

  if [[ ! "$FOLDER_KEY" =~ ^[a-z][a-z0-9-]{1,28}[a-z0-9]$ ]]; then
    log_err "Invalid folder_key '${FOLDER_KEY}'. Must be 3-30 lowercase alphanumeric characters or hyphens."
    valid="false"
  fi

  if [[ "${#DISPLAY_NAME}" -lt 3 || "${#DISPLAY_NAME}" -gt 30 ]]; then
    log_err "Invalid display_name '${DISPLAY_NAME}'. Must be 3-30 characters."
    valid="false"
  fi

  validate_bool "deletion_protection" "$DELETION_PROTECTION" || valid="false"
  validate_bool "enable_ci" "$ENABLE_CI" || valid="false"

  local target_file="${FOLDERS_DIR}/${FOLDER_KEY}.yaml"
  if [[ -f "$target_file" && "$UPDATE_EXISTING" != "true" ]]; then
    log_err "Manifest ${target_file} already exists. Pass --update to modify an existing folder."
    valid="false"
  fi

  if [[ "$ENABLE_CI" == "true" ]]; then
    if [[ ! "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
      log_err "Invalid github_repository '${GITHUB_REPO}'. Must match owner/repo format."
      valid="false"
    fi
    if [[ -z "$APPLY_BRANCH" ]]; then
      log_err "apply_branch cannot be empty."
      valid="false"
    fi
    if [[ ! "$GITHUB_VAR_PREFIX" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      log_err "Invalid github_var_prefix '${GITHUB_VAR_PREFIX}'. Must be uppercase letters, digits, or underscores starting with a letter."
      valid="false"
    fi
    if [[ ! "$FOLDER_ID_VAR_SUFFIX" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      log_err "Invalid folder_id_var_suffix '${FOLDER_ID_VAR_SUFFIX}'."
      valid="false"
    fi
    if [[ -n "$PLAN_SA_ID" && ! "$PLAN_SA_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
      log_err "Invalid plan_sa_account_id '${PLAN_SA_ID}'. Must be 6-30 lowercase letters, digits, or hyphens."
      valid="false"
    fi
    if [[ -n "$APPLY_SA_ID" && ! "$APPLY_SA_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
      log_err "Invalid apply_sa_account_id '${APPLY_SA_ID}'. Must be 6-30 lowercase letters, digits, or hyphens."
      valid="false"
    fi
    validate_bool "grant_billing_access" "$GRANT_BILLING_ACCESS" || valid="false"
    validate_bool "sync_github_vars" "$SYNC_GITHUB_VARS" || valid="false"
  fi

  if [[ "$valid" != "true" ]]; then
    exit 2
  fi
}

render_folder_yaml() {
  cat <<EOF
# Managed via scripts/onboard_folder.sh or the local \`folder-onboarding\` Antigravity skill.
display_name: "${DISPLAY_NAME}"
deletion_protection: ${DELETION_PROTECTION}
EOF

  if [[ "$ENABLE_CI" == "true" ]]; then
    cat <<EOF

ci:
  github_repository: "${GITHUB_REPO}"
  apply_branch: "${APPLY_BRANCH}"
EOF
    if [[ -n "$PLAN_SA_ID" ]]; then
      printf '  plan_sa_account_id: "%s"\n' "$PLAN_SA_ID"
    fi
    if [[ -n "$APPLY_SA_ID" ]]; then
      printf '  apply_sa_account_id: "%s"\n' "$APPLY_SA_ID"
    fi
    cat <<EOF
  github_var_prefix: "${GITHUB_VAR_PREFIX}"
  folder_id_var_suffix: "${FOLDER_ID_VAR_SUFFIX}"
  grant_billing_access: ${GRANT_BILLING_ACCESS}
  sync_github_vars: ${SYNC_GITHUB_VARS}
EOF
  fi
}

run_local_verification() {
  if [[ "$SKIP_VERIFY" == "true" ]]; then
    log_info "Skipping local OpenTofu verification (--skip-verify)."
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] Would run: tofu -chdir=${REPO_DIR} init -backend=false -input=false && tofu -chdir=${REPO_DIR} validate && tofu -chdir=${REPO_DIR} test"
    return 0
  fi

  if ! command -v tofu >/dev/null 2>&1; then
    die_prereq "tofu (OpenTofu) not found on PATH. Install opentofu or pass --skip-verify."
  fi

  log_info "Verifying OpenTofu configuration and mocked unit tests..."
  tofu -chdir="${REPO_DIR}" init -backend=false -input=false >/dev/null
  tofu -chdir="${REPO_DIR}" validate
  tofu -chdir="${REPO_DIR}" test
}

create_onboarding_pr() {
  local target_file="$1"
  local rel_path="${target_file#"${REPO_DIR}/"}"
  local action_verb="onboard"
  local action_title="Onboards"
  local branch_prefix="feat/onboard-folder"
  if [[ "$UPDATE_EXISTING" == "true" ]]; then
    action_verb="update"
    action_title="Updates"
    branch_prefix="chore/update-folder"
  fi
  local branch_name="${branch_prefix}-${FOLDER_KEY}"
  local pr_title="${action_verb}(folders): ${action_verb} GCP folder ${FOLDER_KEY}"

  local pr_body=""
  if [[ "$ENABLE_CI" == "true" ]]; then
    pr_body=$(cat <<EOF
## Summary
- ${action_title} declarative folder manifest \`${rel_path}\` (\`display_name = "${DISPLAY_NAME}"\`, \`deletion_protection = ${DELETION_PROTECTION}\`).
- Authorizes downstream GitOps repository \`${GITHUB_REPO}\` in the org WIF OIDC provider (apply restricted strictly to \`refs/heads/${APPLY_BRANCH}\`).
- Provisions folder-scoped read-only \`plan\` and branch-gated \`apply\` Service Accounts and syncs the 7 org-owned \`${GITHUB_VAR_PREFIX}_*\` GitHub Actions variables (folder ID variable: \`${GITHUB_VAR_PREFIX}_${FOLDER_ID_VAR_SUFFIX}\`).

## Post-Merge Operator Step
After merging to \`main\`, run \`tofu plan && tofu apply\` locally as Org Admin (with \`GITHUB_TOKEN="\$(gh auth token)"\`) to apply the folder, WIF binding, and GitHub Actions variables.
EOF
)
  else
    pr_body=$(cat <<EOF
## Summary
- ${action_title} plain GCP folder manifest \`${rel_path}\` (\`display_name = "${DISPLAY_NAME}"\`, \`deletion_protection = ${DELETION_PROTECTION}\`, no CI/WIF bindings).

## Post-Merge Operator Step
After merging to \`main\`, run \`tofu plan && tofu apply\` locally as Org Admin to provision the folder.
EOF
)
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] Would create branch '${branch_name}', commit '${rel_path}', push to origin, and run 'gh pr create --title \"${pr_title}\"'"
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    die_prereq "gh CLI not found on PATH. Install GitHub CLI and run 'gh auth login' to use --open-pr."
  fi

  git -C "${REPO_DIR}" checkout -b "${branch_name}"
  git -C "${REPO_DIR}" add "${rel_path}"
  git -C "${REPO_DIR}" commit -m "${pr_title}"
  git -C "${REPO_DIR}" push -u origin "${branch_name}"
  gh pr create --title "${pr_title}" --body "${pr_body}" --head "${branch_name}"
}

main() {
  parse_args "$@"

  if [[ "$NON_INTERACTIVE" != "true" ]]; then
    log_info "Folder onboarding for platform_gcp_org_bootstrap (press Enter to accept defaults):"
    FOLDER_KEY="$(prompt_value "Folder key (lowercase slug, e.g. ai-platform)" "$FOLDER_KEY")"
  fi

  local target_file="${FOLDERS_DIR}/${FOLDER_KEY}.yaml"
  if [[ "$UPDATE_EXISTING" == "true" && -f "$target_file" ]]; then
    [[ -n "$DISPLAY_NAME" ]] || DISPLAY_NAME="$(read_existing_yaml_field "display_name" "$target_file")"
    [[ -n "$GITHUB_REPO" ]] || GITHUB_REPO="$(read_existing_yaml_field "github_repository" "$target_file")"
    [[ -n "$GITHUB_VAR_PREFIX" ]] || GITHUB_VAR_PREFIX="$(read_existing_yaml_field "github_var_prefix" "$target_file")"
    local existing_suffix
    existing_suffix="$(read_existing_yaml_field "folder_id_var_suffix" "$target_file")"
    if [[ "$FOLDER_ID_VAR_SUFFIX" == "FOLDER_ID" && -n "$existing_suffix" ]]; then
      FOLDER_ID_VAR_SUFFIX="$existing_suffix"
    fi
    [[ -n "$PLAN_SA_ID" ]] || PLAN_SA_ID="$(read_existing_yaml_field "plan_sa_account_id" "$target_file")"
    [[ -n "$APPLY_SA_ID" ]] || APPLY_SA_ID="$(read_existing_yaml_field "apply_sa_account_id" "$target_file")"
    if [[ -z "$ENABLE_CI" ]]; then
      if [[ -n "$GITHUB_REPO" ]]; then ENABLE_CI="true"; else ENABLE_CI="false"; fi
    fi
  fi

  [[ -n "$DISPLAY_NAME" ]] || DISPLAY_NAME="$FOLDER_KEY"
  if [[ -z "$ENABLE_CI" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      ENABLE_CI="false"
    else
      local ci_answer
      ci_answer="$(prompt_value "Bind a downstream GitHub repo via WIF CI/CD? (true/false)" "true")"
      ENABLE_CI="$ci_answer"
    fi
  fi

  if [[ "$NON_INTERACTIVE" != "true" ]]; then
    DISPLAY_NAME="$(prompt_value "GCP Folder display name" "$DISPLAY_NAME")"
    DELETION_PROTECTION="$(prompt_value "Enable deletion_protection (true/false)" "$DELETION_PROTECTION")"
    if [[ "$ENABLE_CI" == "true" ]]; then
      GITHUB_REPO="$(prompt_value "Downstream GitOps repository (owner/repo)" "$GITHUB_REPO")"
      APPLY_BRANCH="$(prompt_value "Branch allowed to run apply" "$APPLY_BRANCH")"
      local default_prefix="${GITHUB_VAR_PREFIX:-$(derive_var_prefix "$FOLDER_KEY")}"
      GITHUB_VAR_PREFIX="$(prompt_value "GitHub Actions variable prefix" "$default_prefix")"
      FOLDER_ID_VAR_SUFFIX="$(prompt_value "Folder ID variable suffix" "$FOLDER_ID_VAR_SUFFIX")"
    fi
  else
    if [[ "$ENABLE_CI" == "true" && -z "$GITHUB_VAR_PREFIX" ]]; then
      GITHUB_VAR_PREFIX="$(derive_var_prefix "$FOLDER_KEY")"
    fi
  fi

  validate_inputs

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] Would write ${target_file} with:"
    printf '\n'
    render_folder_yaml
    printf '\n'
  else
    mkdir -p "${FOLDERS_DIR}"
    local tmp_file
    tmp_file="$(mktemp "${target_file}.tmp.XXXXXX")"
    render_folder_yaml > "$tmp_file"
    mv "$tmp_file" "${target_file}"
    log_info "Wrote ${target_file}."
  fi

  run_local_verification

  if [[ "$OPEN_PR" == "true" ]]; then
    create_onboarding_pr "${target_file}"
  elif [[ "$DRY_RUN" != "true" ]]; then
    log_info "Next steps: review ${target_file}, commit on a branch and open a PR (or re-run with --open-pr), then run 'tofu plan && tofu apply' after merge."
  fi
}

main "$@"
