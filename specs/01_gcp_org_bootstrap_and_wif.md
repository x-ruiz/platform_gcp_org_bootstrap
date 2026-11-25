# Feature Spec: GCP Org Bootstrap, Multi-Folder Governance, KMS State & Keyless WIF

- **Status:** Approved *(Graduated from `playground-cloud-engineering/platform_unified_data_gcp`)*
- **Module / Component:** `platform_gcp_org_bootstrap/` root module + `scripts/bootstrap_init.sh` (OpenTofu `>= 1.8`, `hashicorp/google ~> 6.0`, `hashicorp/random ~> 3.6`, `integrations/github ~> 6.0`)
- **Archetype:** Infrastructure-as-Code & GitOps Contract (Organization Bootstrap & Landing Zone)
- **Tier:** Full Spec
- **Owner:** Xavier Ruiz

---

## 1. Goal & Context

### Problem Statement
Before any downstream platform or workload repository can deploy environments autonomously via GitOps, a GCP Organization requires a hardened, reusable Organization bootstrap layer. This repository establishes the Organization Seed project, client-side Cloud KMS-encrypted GCS remote state, declarative multi-tier GCP Folders (`var.folders` + `var.subfolders`), Organization- and Folder-level GCP Organization Policies (`google_org_policy_policy`), an org-wide keyless GitHub OIDC Workload Identity Federation (WIF) pool with isolated per-folder CI Service Accounts, and declarative org-owned GitHub Actions repository variables—automated via a safe local preflight script.

### Success Metrics
- Root module passes `tofu fmt -check -recursive`, `tofu validate`, `tflint --recursive`, `trivy config` (`HIGH,CRITICAL`), and offline `tofu test` (`mock_provider`) with zero findings.
- Live apply + two-phase Cloud KMS state migration (or zero-downtime `migrations.tf` state adoption) produces an encrypted GCS state object and zero diff on re-plan.
- `scripts/test_bootstrap_init.sh` verifies preflight auto-discovery, Org IAM bindings (including `roles/orgpolicy.policyAdmin`), validation, `--dry-run`, `--skip-apply`/`--auto-approve`, and preservation of existing multi-folder `terraform.tfvars` offline.
- Full verification coverage of `TC-001` through `TC-007`.

---

## 2. Scope & Explicit Non-Goals

### In Scope
- Automated preflight script `scripts/bootstrap_init.sh` (and offline mocked suite `scripts/test_bootstrap_init.sh`) for Org/Billing/GitHub auto-discovery, base Org IAM bindings (`folderAdmin`, `projectCreator`, `billing.admin`, `orgpolicy.policyAdmin`), Billing Account & ADC verification, initial `terraform.tfvars` scaffolding (preserving existing hand-edited maps), and `tofu init` / `plan` / `apply`.
- Standalone OpenTofu root module provisioning:
  - **Org Seed Project** (under `org_id` or optional `seed_folder_key`), linked to `billing_account_id`, with required bootstrap APIs (including `orgpolicy.googleapis.com`).
  - **Hardened GCS Remote State Bucket** (versioned, UBLA, PAP enforced, noncurrent lifecycle retention, `prevent_destroy`).
  - **Cloud KMS KeyRing & CryptoKey** (90-day rotation, `prevent_destroy`) driving enforced OpenTofu native `gcp_kms` + `aes_gcm` state/plan encryption.
  - **Multi-Folder & Subfolder Hierarchy** (`var.folders` under `organizations/<org_id>`, optional 2nd-level `var.subfolders`).
  - **Declarative Organization Policies** (`var.org_policies` at Org scope + per-folder/per-subfolder `org_policies`, opt-in by default).
  - **Org-Wide WIF Pool & GitHub OIDC Provider** (allowlisted to configured repositories; fails closed when empty) + optional per-folder dual CI Service Accounts (`plan` read-only; `apply` branch-gated to `refs/heads/<apply_branch>`) with strictly folder-scoped IAM.
  - **7 Org-Owned GitHub Actions Repository Variables** per CI-enabled folder (`WIF_PROVIDER`, `PLAN_SA`, `APPLY_SA`, `STATE_BUCKET`, `STATE_KMS_KEY_ID`, `<FOLDER_ID>`, `BILLING_ACCOUNT_ID`).
  - **Zero-Downtime Migration Bridge (`migrations.tf`):** `moved {}` and `removed { destroy = false }` blocks for adopting existing single-platform live state.

### Non-Goals (Do Not Implement)
- **No workload/environment projects or platform compositions:** Environment projects (`dev`/`uat`/`prod`), VPCs, budgets, and platform-specific GitHub vars (`*_DEV_PROJECT_ID`, `*_BUDGET_ALERT_EMAIL`) belong exclusively in downstream platform repositories.
- **No static credentials:** Zero `google_service_account_key` resources or long-lived GCP JSON secrets.
- **No data-layer workloads:** BigQuery, BigLake, Dataproc, Composer, and medallion buckets belong in downstream domain/platform repositories.

---

## 3. Functional Requirements

- `REQ-01`: **Toolchain & Version Pinning** — Declare `required_version` (`>= 1.8.0, < 2.0.0`), pin `hashicorp/google` (`~> 6.0`), `hashicorp/random` (`~> 3.6`), and `integrations/github` (`~> 6.0`), and commit `.terraform.lock.hcl`.
- `REQ-02`: **Org Seed Project & Multi-Folder Hierarchy** — Provision a Seed GCP project (`auto_create_network = false`, random `-xxxx` suffix, `deletion_policy = "PREVENT"`, mandatory labels, required bootstrap APIs including `orgpolicy.googleapis.com`) alongside declarative top-level `var.folders` and optional 2nd-level `var.subfolders` with configurable `deletion_protection`.
- `REQ-03`: **Hardened Remote State Bucket & Cloud KMS Encryption** — Provision a GCS bucket in the Seed project with versioning enabled, `uniform_bucket_level_access = true`, `public_access_prevention = "enforced"`, noncurrent retention (10 versions / 30 days), `force_destroy = false`, `prevent_destroy = true`, paired with a Cloud KMS KeyRing + 90-day-rotating CryptoKey (`prevent_destroy = true`) enforcing OpenTofu `gcp_kms` + `aes_gcm` state/plan encryption.
- `REQ-04`: **Declarative Organization & Folder Policies** — Support opt-in `google_org_policy_policy` management (boolean `enforce`, list `allow_all`/`deny_all`/`allowed_values`/`denied_values`, and conditional rules) at Organization, top-level Folder, and Subfolder scopes.
- `REQ-05`: **Keyless Org WIF & Per-Folder Dual CI Service Accounts** — Provision one org-wide WIF Pool & GitHub OIDC Provider whose `attribute_condition` restricts federation strictly to authorized repositories (failing closed as `"false"` when empty). For each folder opting into `ci = { ... }`, provision isolated read-only `plan` and branch-gated `apply` (`refs/heads/<apply_branch>`) Service Accounts with zero Organization-level roles.
- `REQ-06`: **Declarative Org-Owned GitHub Actions Variables** — For each CI-enabled folder with `sync_github_vars = true`, manage strictly the 7 org-owned repository variables (`<PREFIX>_WIF_PROVIDER`, `<PREFIX>_PLAN_SA`, `<PREFIX>_APPLY_SA`, `<PREFIX>_STATE_BUCKET`, `<PREFIX>_STATE_KMS_KEY_ID`, `<PREFIX>_<FOLDER_ID_SUFFIX>`, `<PREFIX>_BILLING_ACCOUNT_ID`) via `github_actions_variable`.
- `REQ-07`: **Automated Bootstrap Preflight Script** — `scripts/bootstrap_init.sh` shall verify `gcloud`/`tofu`, auto-discover Org/Billing/GitHub/admin metadata, validate inputs against `variables.tf` contracts, idempotently bind `folderAdmin`/`projectCreator`/`billing.admin`/`orgpolicy.policyAdmin` on the Org, verify Billing Account access & ADC alignment, preserve existing multi-folder `terraform.tfvars` unless `--overwrite-tfvars` is passed, and run `tofu init` → `plan` → `apply`.

---

## 4. Interface & Data Contract

### 4.1 Root Module Inputs & Outputs

| Direction | Name | Type | Default / Required | Validation & Contract |
| :--- | :--- | :--- | :--- | :--- |
| Input | `org_id` | `string` | Required | Numeric GCP Organization ID (`^[0-9]+$`). |
| Input | `billing_account_id` | `string` | Required | Format `^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$`. |
| Input | `github_owner` | `string` | Required | GitHub org or username owning CI repositories. |
| Input | `bootstrap_name` | `string` | `"gcp-org-bootstrap"` | Lowercase slug for labels and default KMS KeyRing name. |
| Input | `kms_key_ring_name` | `string` | `null` | Optional override when adopting an existing live KeyRing. |
| Input | `seed_project_id` | `string` | Required | Base prefix (4–25 chars); random `-xxxx` suffix appended. |
| Input | `seed_project_name` | `string` | `"Org Bootstrap Seed"` | Seed project display name (4–30 chars). |
| Input | `seed_folder_key` | `string` | `null` | Optional key in `var.folders` (defaults to Org root when `null`). |
| Input | `region` / `cost_center` | `string` | `"us-central1"` / `"platform-engineering"` | Primary region and mandatory `cost_center` label. |
| Input | `state_kms_key_id` | `string` | Required | Cloud KMS CryptoKey ID for OpenTofu `gcp_kms` encryption. |
| Input | `folders` / `subfolders` | `map(object)` | `{}` | Declarative top-level and 2nd-level folders, optional `ci` & `org_policies`. |
| Input | `org_policies` | `map(object)` | `{}` | Declarative Organization-level `google_org_policy_policy` rules. |
| Output | `seed_project_id` / `state_bucket_name` / `kms_key_id` / `wif_provider_name` | `string` | — | Core Seed, state, KMS, and WIF identifiers. |
| Output | `folder_ids` / `subfolder_ids` / `folder_ci_identities` | `map` | — | Created folder IDs (`folders/<id>`) and per-folder CI SA emails. |

### 4.2 IAM & WIF Principal Matrix (Per CI-Enabled Folder)

| Principal | WIF Condition | Scope | Assigned Roles | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| `folder_plan[k]` | `assertion.repository == ci.github_repository` | Target Folder `k` | `roles/viewer`, `roles/iam.securityReviewer` (configurable) | Read-only PR plan & drift detection. |
| `folder_plan[k]` | Same | Seed State Bucket & KMS | `roles/storage.objectViewer`, conditional `.tflock`-only `objectUser`, `cloudkms.cryptoKeyEncrypterDecrypter` | Read-only encrypted state init + `.tflock` handling. |
| `folder_apply[k]` | `assertion.repository_ref == <repo>:refs/heads/<apply_branch>` | Target Folder `k` | `projectCreator`, `projectDeleter`, `projectIamAdmin`, `compute.networkAdmin`, `serviceUsageAdmin`, `monitoring.notificationChannelEditor` (configurable) | Provision environment projects & core infra inside folder `k` only. |
| `folder_apply[k]` | Same | Billing, State Bucket & KMS | Optional `billing.user`/`billing.costsManager`, `storage.objectUser`, `cloudkms.cryptoKeyEncrypterDecrypter` | Link projects, manage budgets, and write encrypted state. |

---

## 5. Invariants, Edge Cases & Failure Modes

### Key Invariants
1. **Zero Org-Wide CI Blast Radius:** No folder CI Service Account holds Organization-level IAM roles; WIF fails closed (`"false"`) when no repositories are authorized.
2. **Zero Static Credentials:** No `google_service_account_key` resources or JSON keys anywhere in code or CI.
3. **Destruction Guardrails:** Seed project (`deletion_policy = "PREVENT"`), state bucket (`force_destroy = false`, `prevent_destroy = true`), KMS key (`prevent_destroy = true`), and folders (`deletion_protection = true` default) reject accidental destroys.
4. **Org vs. Platform Ownership Boundary:** Platform/environment variables (e.g., `*_DEV_PROJECT_ID`, `*_BUDGET_ALERT_EMAIL`) are never managed here.

### Failure Mode Matrix

| Failure Condition | Expected Error / Status | Notes |
| :--- | :--- | :--- |
| Invalid `org_id`, `billing_account_id`, `seed_project_id`, or `ci.github_repository` | OpenTofu validation error (or script exit `2`) | Fails fast before any GCP API call or file write. |
| Non-`apply_branch` attempts to impersonate `folder_apply[k]` | GCP STS `403 PERMISSION_DENIED` | Enforced server-side by WIF principal binding. |
| Missing `roles/billing.admin` on external Billing Account or mismatched ADC | `bootstrap_init.sh` exit `1` (or ADC refresh prompt) | Prints remediation before running `tofu apply`. |
| `tofu init` without KMS decrypt permission | OpenTofu `Failed to decrypt state` | Fail-closed (`enforced = true`); rejects plaintext state. |

---

## 6. Acceptance Criteria & Verification Matrix

| Case ID | Scenario | Expected Outcome |
| :--- | :--- | :--- |
| `TC-001` | Static hygiene & security scan | `tofu fmt -check`, `tofu validate`, `tflint --recursive`, and `trivy config` exit `0` with zero HIGH/CRITICAL findings. |
| `TC-002` | Multi-folder, subfolder, WIF & Org Policy invariants (Mocked) | `tofu test` verifies Seed hardening, bucket UBLA/PAP/versioning, 90-day KMS rotation, multi-folder + subfolder creation, allowlisted WIF condition, 7 org-owned GitHub vars per CI folder (zero platform dev/budget vars), and boolean/list Org & Folder Policies. |
| `TC-003` | Backward-compatible single-repo & fail-closed zero-repo WIF (Mocked) | Single-repo config keeps equality `attribute_condition` and honors `seed_folder_key`/`kms_key_ring_name`; zero-repo config sets `attribute_condition = "false"`. |
| `TC-004` | Input validation negative tests (Mocked) | Invalid `org_id` and malformed `ci.github_repository` fail plan via `expect_failures`. |
| `TC-005` | Live apply / KMS migration or `migrations.tf` state adoption | Encrypted GCS state verified; `migrations.tf` adopts legacy single-platform state with 0 destroyed and detaches legacy dev/budget GitHub vars without deleting them. |
| `TC-006` | Preflight script happy path & modes (Mocked) | `scripts/test_bootstrap_init.sh` verifies auto-discovery, Org IAM (+ `orgpolicy.policyAdmin`), decoupled `tfvars`, `--skip-apply`, `--auto-approve`, and exit `2` / `1` negative paths. |
| `TC-007` | Preflight dry-run & multi-folder `tfvars` preservation (Mocked) | `--dry-run` performs zero mutations; re-running against an existing `terraform.tfvars` preserves custom `folders` and `org_policies` maps untouched. |
