---
name: folder-onboarding
description: >-
  Onboard a new GCP Folder (or update an existing folder's downstream GitHub repository
  after a playground project graduates) in `platform_gcp_org_bootstrap` by gathering
  required inputs, generating or updating `folders/<folder-key>.yaml`, running local
  OpenTofu/TFLint/Trivy verification, and automatically creating a branch and GitHub PR
  via `gh pr create`. Use whenever the user asks to onboard a new GCP folder, add a
  platform folder, bind a GitHub repo to a folder's WIF, or update a folder's repository.
---

# Folder Onboarding (`platform_gcp_org_bootstrap`)

Automates declarative GCP Folder onboarding (and downstream repository re-binding when a project graduates) through Git-tracked `folders/<folder-key>.yaml` manifests and PR review.

## Non-Negotiable Guardrails
1. **Never commit secrets or account IDs.** `folders/<folder-key>.yaml` lives in a public repository and must contain only non-sensitive folder/WIF metadata (`display_name`, `deletion_protection`, `ci.*`, `subfolders`, `org_policies`)—never `org_id`, `billing_account_id`, or `terraform.tfvars`.
2. **Never run `tofu apply` unprompted.** This skill prepares, verifies, and opens a GitHub PR; live Org Admin `tofu plan && tofu apply` happens only after PR review/merge or explicit operator confirmation.
3. **Verify before opening a PR.** Always run `tofu fmt -check`, `tofu validate`, `tflint`, `trivy config`, `scripts/test_onboard_folder.sh`, and `tofu test` locally before pushing.

---

## Workflow

### Phase 1: Inspect Existing Folders (Read-Only)
1. Check `git status -sb` (ensure working tree is clean on `main` or ask before branching) and list existing manifests in `folders/*.yaml`.
2. Summarize existing folder keys and bound `ci.github_repository` values so the user avoids naming or variable-prefix collisions.

### Phase 2: Gather Folder Inputs (1 Concise Round)
Ask the user for any missing details:
1. **Mode:** Onboard a **new** folder or **update** an existing folder (e.g., re-binding `ci.github_repository` after graduating a playground project)?
2. **Folder key & display name:** Lowercase slug (`3–30` chars, e.g., `ai-platform`) and GCP Folder `display_name` (plus `deletion_protection`: default `true`).
3. **Downstream GitOps CI/WIF binding (optional):**
   - Does a downstream GitHub repository deploy into this folder? (If no, create a plain folder with `--no-ci`.)
   - If yes: exact `owner/repo` (e.g., `x-ruiz/platform-ai-gcp`), `apply_branch` (default `main`), and `github_var_prefix` (e.g., `AI_GCP`).
4. **Optional extras:** Any second-level `subfolders` or folder-scoped `org_policies` to include in `folders/<folder-key>.yaml`?

### Phase 3: Generate Manifest & Verify Locally
1. Run `./scripts/onboard_folder.sh --non-interactive ...` (passing `--update` when modifying an existing folder, or `--no-ci` for plain folders) to write `folders/<folder-key>.yaml`.
2. If the user requested `subfolders` or folder-scoped `org_policies`, add them cleanly to `folders/<folder-key>.yaml`.
3. Run the full local verification suite:
   ```bash
   tofu fmt -check -recursive -diff .
   tofu init -backend=false -input=false && tofu validate
   tflint --recursive --config="$(pwd)/.tflint.hcl"
   trivy config --severity HIGH,CRITICAL --exit-code 1 --skip-dirs '**/.terraform' --skip-dirs '**/.tofu' .
   bash scripts/test_onboard_folder.sh
   tofu test -verbose
   ```
4. Fix any validation or test failures before proceeding.

### Phase 4: Commit, Push & Open PR
1. Create a branch (`feat/onboard-folder-<folder-key>` or `chore/update-folder-<folder-key>`), commit `folders/<folder-key>.yaml`, push to `origin`, and open a PR against `main` via `gh pr create` summarizing:
   - The GCP Folder (and any subfolders / Org Policies) being created or updated.
   - The downstream `ci.github_repository` allowlisted in WIF, the plan/apply Service Accounts, and the 7 `<PREFIX>_*` GitHub Actions variables synced.
2. Return the PR URL and remind the user of the post-merge Org Admin apply step:
   ```bash
   export TF_VAR_state_kms_key_id="<kms-key-id>"
   export GITHUB_TOKEN="$(gh auth token)"
   tofu plan && tofu apply
   ```
