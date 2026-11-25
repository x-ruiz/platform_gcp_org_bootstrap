# GCP Organization Bootstrap (`platform_gcp_org_bootstrap`)

Generalized OpenTofu Organization-level landing zone foundation for Google Cloud. Manages the Organization Seed project, Cloud KMS-encrypted GCS remote state, an org-wide GitHub OIDC Workload Identity Federation (WIF) pool, declarative multi-tier GCP Folders (`var.folders` + `var.subfolders`), optional per-folder keyless CI/CD identities & GitHub Actions variables, and Organization/Folder-level GCP Organization Policies (`google_org_policy_policy`).

> **Scope Boundary:** This repository strictly owns **Org-level and Folder-level foundations**. Workload/environment projects (such as `udp-dev`, `uat`, `prod`), VPCs, and billing budgets live in downstream platform repositories (e.g., `platform_unified_data_gcp/infra/platform` & `infra/envs`).

## Key Capabilities

- **Multi-Folder & Subfolder Hierarchy (`folders.tf`):** Declare any number of top-level folders under `organizations/<org_id>` (`var.folders`) and second-level child folders (`var.subfolders`) with per-folder `deletion_protection`.
- **Declarative Organization & Folder Policies (`org_policies.tf`):** Manage boolean and list-based GCP Organization Policies (`google_org_policy_policy`) at Organization, top-level Folder, and Subfolder scopes (opt-in by default).
- **Hardened Org Seed & Client-Side Encrypted State (`main.tf`, `encryption.tf`):** Provisions a dedicated Seed GCP project (`auto_create_network = false`, `deletion_policy = "PREVENT"`), versioned GCS state bucket (UBLA + PAP enforced, lifecycle retention, `prevent_destroy = true`), and Cloud KMS KeyRing/CryptoKey (90-day rotation, `prevent_destroy = true`) driving OpenTofu native `gcp_kms` + `aes_gcm` state encryption.
- **Keyless Per-Folder GitOps WIF (`iam_wif.tf`, `github_actions.tf`):** Shares one org-wide WIF Pool & GitHub OIDC Provider restricted to the exact set of authorized repositories (failing closed when empty). Any folder opting into `ci = { ... }` receives isolated `plan` (read-only + conditional `.tflock`-only GCS lock) and `apply` (branch-gated to `refs/heads/<apply_branch>`) Service Accounts scoped strictly to that folder, plus 7 org-owned GitHub Actions repository variables.
- **Zero-Downtime Migration Compatibility (`migrations.tf`):** Includes OpenTofu `moved {}` blocks and `removed { destroy = false }` blocks to adopt an existing live `platform_unified_data_gcp/infra/bootstrap` GCS state without destroying the Seed project, Folder, GCS bucket, KMS key, or existing `UDP_GCP_DEV_PROJECT_ID` / `UDP_GCP_BUDGET_ALERT_EMAIL` GitHub variables.

## Architecture Overview

```mermaid
flowchart TB
    Org["GCP Organization (organizations/org_id)"]
    OrgPol["Org Policies (google_org_policy_policy.org)"]
    Seed["Seed Project (org-seed-xxxx)"]
    State["GCS State Bucket + Cloud KMS Key (gcp_kms + aes_gcm)"]
    WIF["Org WIF Pool + GitHub OIDC Provider (allowlisted repos)"]

    subgraph Folders["Declarative Folder Hierarchy (var.folders / var.subfolders)"]
        F1["Folder A (e.g., unified-data-platform)\n+ Optional Folder Org Policies"]
        F2["Folder B (e.g., ai-platform)\n+ Optional Subfolders & Org Policies"]
        F3["Plain Folder (e.g., sandbox)\n(ci = null)"]
    end

    subgraph CI["Optional Per-Folder Keyless CI/CD"]
        SA1["sa-tofu-plan (PR read-only)\nsa-tofu-apply (refs/heads/main)\n+ 7 GitHub Actions Vars"]
        SA2["sa-ai-platform-plan / apply\n+ 7 GitHub Actions Vars"]
    end

    Org --> OrgPol
    Org --> Seed
    Org --> F1
    Org --> F2
    Org --> F3
    Seed --> State
    Seed --> WIF
    WIF --> SA1
    WIF --> SA2
    SA1 -->|"Folder-scoped IAM"| F1
    SA2 -->|"Folder-scoped IAM"| F2
```

## Repository Layout

```text
platform_gcp_org_bootstrap/
├── .github/workflows/ci.yml   # Format, validate, TFLint, Trivy, script & OpenTofu mocked tests
├── scripts/
│   ├── bootstrap_init.sh      # Automated Org IAM preflight, ADC check, tfvars scaffold & tofu apply
│   └── test_bootstrap_init.sh # Offline mocked unit tests for bootstrap_init.sh
├── tests/
│   └── bootstrap.tftest.hcl   # Offline mocked OpenTofu unit tests (folders, WIF, policies, validations)
├── main.tf                    # Seed project, required APIs, hardened GCS state bucket, Cloud KMS
├── folders.tf                 # Top-level folders & second-level subfolders
├── org_policies.tf            # Org-level, folder-level & subfolder-level google_org_policy_policy
├── iam_wif.tf                 # Org WIF Pool/OIDC Provider + per-folder plan/apply SAs & IAM
├── github_actions.tf          # 7 org-owned GitHub Actions variables per CI-enabled folder
├── migrations.tf              # Zero-downtime moved/removed blocks for live single-platform adoption
├── backend.tf                 # GCS remote state backend (prefix = "bootstrap")
├── encryption.tf              # Enforced OpenTofu gcp_kms + aes_gcm state/plan encryption
├── variables.tf               # Typed inputs & regex validation contracts
├── outputs.tf                 # Seed, KMS, WIF, folder_ids, subfolder_ids & folder_ci_identities
├── versions.tf                # OpenTofu >= 1.8, google ~> 6.0, random ~> 3.6, github ~> 6.0
├── terraform.tfvars.example   # Annotated configuration template (gitignored real terraform.tfvars)
├── .tflint.hcl                # TFLint Google ruleset config
└── .trivyignore               # Documented Trivy IaC suppressions (empty)
```

## Prerequisites

```bash
brew install opentofu trivy terraform-linters/tap/tflint
gcloud auth login && gcloud auth application-default login
gh auth login
```

## Quick Start (Fresh GCP Organization)

### Phase 1: Automated Org IAM Preflight & Initial Apply

> **External / Personal Billing Account:** If your Billing Account lives outside your GCP Organization (e.g., under a personal `@gmail.com` account), grant your Org Admin identity `roles/billing.admin` directly on the Billing Account once from the billing owner's account before running `bootstrap_init.sh`.

For a brand-new GCP Org without an existing remote state bucket yet, temporarily comment out `backend.tf` and `encryption.tf` for the initial local apply, then run `scripts/bootstrap_init.sh`:

```bash
# Preview planned Org IAM bindings, terraform.tfvars, and tofu commands (zero mutations)
./scripts/bootstrap_init.sh --dry-run

# Run preflight (binds folderAdmin, projectCreator, billing.admin, orgpolicy.policyAdmin) and apply
./scripts/bootstrap_init.sh
```

> Re-running `scripts/bootstrap_init.sh` preserves any existing `terraform.tfvars` (including your `folders`, `subfolders`, and `org_policies` maps) unless `--overwrite-tfvars` is passed.

### Phase 2: Migrate Bootstrap State to Cloud KMS-Encrypted GCS

1. Restore `backend.tf` (`prefix = "bootstrap"`) and temporarily set `enforced = false` with an `unencrypted` fallback in `encryption.tf`.
2. Grant your Org Admin identity `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the created KMS key and migrate state:
   ```bash
   STATE_BUCKET="$(tofu output -raw state_bucket_name)"
   export TF_VAR_state_kms_key_id="$(tofu output -raw kms_key_id)"

   gcloud kms keys add-iam-policy-binding "${TF_VAR_state_kms_key_id}" \
     --member="user:$(gcloud config get-value account)" \
     --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"

   tofu init -migrate-state -backend-config="bucket=${STATE_BUCKET}"
   ```
3. Verify the remote object is encrypted ciphertext (`gcloud storage cat "gs://${STATE_BUCKET}/bootstrap/default.tfstate" | head -c 200`), restore `enforced = true` in `encryption.tf`, remove local `terraform.tfstate*`, and run `tofu plan` to confirm zero diff.

## Adopting Existing Live State (from `platform_unified_data_gcp`)

Moving `.tf` files into a standalone repository does **not** affect your existing GCS state (`prefix = "bootstrap"`). However, generalizing the module from single-folder resources to multi-folder `for_each` maps changed the **OpenTofu resource addresses** recorded in `bootstrap/default.tfstate`:

| Existing state address | New generalized address |
| :--- | :--- |
| `google_folder.platform` | `google_folder.folders["unified-data-platform"]` |
| `google_service_account.tofu_plan` / `tofu_apply` | `google_service_account.folder_plan["unified-data-platform"]` / `folder_apply[...]` |
| `google_folder_iam_member.plan_folder_roles["<role>"]` | `google_folder_iam_member.folder_plan_roles["unified-data-platform:<role>"]` |
| `github_actions_variable.udp_gcp["UDP_GCP_*"]` *(7 org vars)* | `github_actions_variable.folder_ci["unified-data-platform:UDP_GCP_*"]` |
| `github_actions_variable.udp_gcp["UDP_GCP_DEV_PROJECT_ID"]` & `UDP_GCP_BUDGET_ALERT_EMAIL` | Detached via `removed { lifecycle { destroy = false } }` |

Without [`migrations.tf`](./migrations.tf):
- OpenTofu would treat the renamed addresses as deletions + new creations—attempting to destroy the live folder (blocked by `deletion_protection = true`) and recreate the CI service accounts/IAM bindings.
- Removing `dev_project_id` and `budget_alert_email` from bootstrap would delete `UDP_GCP_DEV_PROJECT_ID` and `UDP_GCP_BUDGET_ALERT_EMAIL` in GitHub; `removed { destroy = false }` forgets them from bootstrap state without touching GitHub so downstream `platform_unified_data_gcp` workflows keep running uninterrupted.

To adopt your existing GCS `bootstrap` state in-place with **0 to destroy**:

1. Create a local gitignored `terraform.tfvars` modeled on `terraform.tfvars.example` with your existing `org_id`, `billing_account_id`, `seed_project_id`, and:
   ```hcl
   github_owner      = "x-ruiz"
   bootstrap_name    = "unified-data-platform"
   seed_folder_key   = "unified-data-platform"
   seed_project_name = "UDP Seed"
   kms_key_ring_name = "unified-data-platform-tofu-state"

   folders = {
     unified-data-platform = {
       display_name = "unified-data-platform"
       ci = {
         github_repository    = "x-ruiz/playground-cloud-engineering"
         plan_sa_account_id   = "sa-tofu-plan"
         apply_sa_account_id  = "sa-tofu-apply"
         github_var_prefix    = "UDP_GCP"
         folder_id_var_suffix = "PLATFORM_FOLDER_ID"
       }
     }
   }
   ```
2. Point OpenTofu at your existing GCS state bucket and KMS key:
   ```bash
   export TF_VAR_state_kms_key_id="<existing-kms-key-id>"
   export GITHUB_TOKEN="$(gh auth token)"
   tofu init -backend-config="bucket=<existing-state-bucket>"
   tofu plan
   ```
3. Confirm `tofu plan` reports **0 to destroy**, clean `moved` transitions into `folders["unified-data-platform"]`, and `removed` (forget-only) for `UDP_GCP_DEV_PROJECT_ID` and `UDP_GCP_BUDGET_ALERT_EMAIL`, then run `tofu apply`.
4. Once applied, your remote state is permanently rewritten to the new addresses and `migrations.tf` can be safely deleted in a follow-up commit (it is also a harmless no-op on fresh orgs).

## Adding Folders, Subfolders & Organization Policies

Add entries to `terraform.tfvars` and apply—no HCL code edits required:

```hcl
folders = {
  data-platform = {
    display_name = "data-platform"
    ci = {
      github_repository = "x-ruiz/platform-data-gcp"
      github_var_prefix = "DATA_GCP"
    }
    org_policies = {
      "gcp.resourceLocations" = {
        rules = [{ allowed_values = ["in:us-locations"] }]
      }
    }
  }

  sandbox = {
    display_name        = "sandbox"
    deletion_protection = false
  }
}

subfolders = {
  data-nonprod = {
    parent_folder_key = "data-platform"
    display_name      = "nonprod"
  }
}

org_policies = {
  "iam.disableServiceAccountKeyCreation" = {
    rules = [{ enforce = true }]
  }
  "storage.uniformBucketLevelAccess" = {
    rules = [{ enforce = true }]
  }
}
```

### Synced GitHub Actions Variables (Per CI-Enabled Folder)

When `ci.sync_github_vars = true` (default), OpenTofu manages these 7 org-owned variables on `ci.github_repository` using `ci.github_var_prefix`:

| Variable | Source |
| :--- | :--- |
| `<PREFIX>_WIF_PROVIDER` | Org-wide GitHub OIDC WIF provider path |
| `<PREFIX>_PLAN_SA` | Folder-scoped read-only plan SA email |
| `<PREFIX>_APPLY_SA` | Folder-scoped branch-gated apply SA email |
| `<PREFIX>_STATE_BUCKET` | Org Seed GCS state bucket name |
| `<PREFIX>_STATE_KMS_KEY_ID` | Cloud KMS CryptoKey ID for `gcp_kms` state encryption |
| `<PREFIX>_<FOLDER_ID_SUFFIX>` | Created folder ID (`folders/<id>`, default suffix `FOLDER_ID`) |
| `<PREFIX>_BILLING_ACCOUNT_ID` | GCP Billing Account ID |

## Quality & Offline Verification

All static checks, security scans, and mocked unit tests run locally with zero GCP credentials or cost:

```bash
tofu fmt -check -recursive -diff .
tofu init -backend=false -input=false
tofu validate
tflint --init --config="$(pwd)/.tflint.hcl"
tflint --recursive --config="$(pwd)/.tflint.hcl"
trivy config --severity HIGH,CRITICAL --exit-code 1 --skip-dirs '**/.terraform' --skip-dirs '**/.tofu' .
bash -n scripts/bootstrap_init.sh && bash scripts/test_bootstrap_init.sh
tofu test -verbose
```
