locals {
  default_plan_folder_roles = toset([
    "roles/viewer",
    "roles/iam.securityReviewer",
  ])

  default_apply_folder_roles = toset([
    "roles/resourcemanager.projectCreator",
    "roles/resourcemanager.projectDeleter",
    "roles/resourcemanager.projectIamAdmin",
    "roles/compute.networkAdmin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/monitoring.notificationChannelEditor",
  ])

  default_apply_billing_roles = toset([
    "roles/billing.user",
    "roles/billing.costsManager",
  ])

  ci_folders = {
    for k, f in local.effective_folders : k => {
      display_name         = f.display_name
      github_repository    = f.ci.github_repository
      apply_branch         = f.ci.apply_branch
      plan_sa_account_id   = coalesce(f.ci.plan_sa_account_id, "sa-${trim(substr(k, 0, 21), "-")}-plan")
      apply_sa_account_id  = coalesce(f.ci.apply_sa_account_id, "sa-${trim(substr(k, 0, 20), "-")}-apply")
      plan_folder_roles    = coalesce(f.ci.plan_folder_roles, local.default_plan_folder_roles)
      apply_folder_roles   = coalesce(f.ci.apply_folder_roles, local.default_apply_folder_roles)
      apply_billing_roles  = coalesce(f.ci.apply_billing_roles, local.default_apply_billing_roles)
      grant_billing_access = f.ci.grant_billing_access
      sync_github_vars     = f.ci.sync_github_vars
      github_var_prefix    = coalesce(f.ci.github_var_prefix, upper(replace(k, "-", "_")))
      folder_id_var_suffix = f.ci.folder_id_var_suffix
    }
    if f.ci != null
  }

  authorized_repositories = sort(distinct(concat(
    [for cfg in values(local.ci_folders) : cfg.github_repository],
    tolist(var.additional_wif_repositories),
  )))

  wif_attribute_condition = (
    length(local.authorized_repositories) == 0
    ? "false"
    : length(local.authorized_repositories) == 1
    ? "assertion.repository == '${local.authorized_repositories[0]}'"
    : "assertion.repository in [${join(", ", [for r in local.authorized_repositories : "'${r}'"])}]"
  )

  folder_plan_role_bindings = merge([
    for folder_key, cfg in local.ci_folders : {
      for role in cfg.plan_folder_roles :
      "${folder_key}:${role}" => {
        folder_key = folder_key
        role       = role
      }
    }
  ]...)

  folder_apply_role_bindings = merge([
    for folder_key, cfg in local.ci_folders : {
      for role in cfg.apply_folder_roles :
      "${folder_key}:${role}" => {
        folder_key = folder_key
        role       = role
      }
    }
  ]...)

  folder_apply_billing_bindings = merge([
    for folder_key, cfg in local.ci_folders : {
      for role in(cfg.grant_billing_access ? cfg.apply_billing_roles : toset([])) :
      "${folder_key}:${role}" => {
        folder_key = folder_key
        role       = role
      }
    }
  ]...)
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = google_project.seed.project_id
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions Pool"
  description               = "Org-wide Workload Identity Pool for keyless GitHub Actions OpenTofu GitOps."

  depends_on = [google_project_service.seed_apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = google_project.seed.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC Provider"
  description                        = "OIDC provider restricted strictly to authorized repositories."

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"           = "assertion.sub"
    "attribute.actor"          = "assertion.actor"
    "attribute.repository"     = "assertion.repository"
    "attribute.ref"            = "assertion.ref"
    "attribute.repository_ref" = "assertion.repository + ':' + assertion.ref"
  }

  attribute_condition = local.wif_attribute_condition
}

# --- Per-Folder Dual CI Service Accounts (Plan Read-Only & Branch-Gated Apply) ---

resource "google_service_account" "folder_plan" {
  for_each = local.ci_folders

  project      = google_project.seed.project_id
  account_id   = each.value.plan_sa_account_id
  display_name = "OpenTofu Plan (${each.value.display_name})"
  description  = "Read-only CI service account for GitHub Actions PR plans scoped to folder ${each.value.display_name}."

  depends_on = [google_project_service.seed_apis]
}

resource "google_service_account" "folder_apply" {
  for_each = local.ci_folders

  project      = google_project.seed.project_id
  account_id   = each.value.apply_sa_account_id
  display_name = "OpenTofu Apply (${each.value.display_name})"
  description  = "Provisioning CI service account restricted strictly to refs/heads/${each.value.apply_branch} for folder ${each.value.display_name}."

  depends_on = [google_project_service.seed_apis]
}

# WIF binding: PRs/branches in each folder's repository can impersonate its plan SA.
resource "google_service_account_iam_member" "folder_wif_plan" {
  for_each = local.ci_folders

  service_account_id = google_service_account.folder_plan[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${each.value.github_repository}"
}

# WIF binding: ONLY refs/heads/<apply_branch> in each folder's repository can impersonate its apply SA.
resource "google_service_account_iam_member" "folder_wif_apply" {
  for_each = local.ci_folders

  service_account_id = google_service_account.folder_apply[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_ref/${each.value.github_repository}:refs/heads/${each.value.apply_branch}"
}

# --- Read-Only Plan SA IAM (Folder, State Bucket, KMS Key) ---

resource "google_folder_iam_member" "folder_plan_roles" {
  for_each = local.folder_plan_role_bindings

  folder = google_folder.folders[each.value.folder_key].name
  role   = each.value.role
  member = "serviceAccount:${google_service_account.folder_plan[each.value.folder_key].email}"
}

resource "google_storage_bucket_iam_member" "folder_plan_state_viewer" {
  for_each = local.ci_folders

  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.folder_plan[each.key].email}"
}

# Allow plan SAs to create/release .tflock lock objects during `tofu init` while
# strictly blocking any write/delete on .tfstate objects.
resource "google_storage_bucket_iam_member" "folder_plan_state_lock" {
  for_each = local.ci_folders

  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.folder_plan[each.key].email}"

  condition {
    title       = "AllowTflockOnly"
    description = "Permit lockfile creation/deletion (*.tflock) without granting write access to *.tfstate."
    expression  = "resource.name.endsWith(\".tflock\")"
  }
}

# OpenTofu's gcp_kms key_provider wraps a fresh data key during init even on read-only plan.
# Plan SAs remain strictly read-only via roles/storage.objectViewer (GCS) and roles/viewer (Folder).
resource "google_kms_crypto_key_iam_member" "folder_plan_kms" {
  for_each = local.ci_folders

  crypto_key_id = google_kms_crypto_key.state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.folder_plan[each.key].email}"
}

# --- Branch-Gated Apply SA IAM (Folder, Billing Account, State Bucket, KMS Key) ---

resource "google_folder_iam_member" "folder_apply_roles" {
  for_each = local.folder_apply_role_bindings

  folder = google_folder.folders[each.value.folder_key].name
  role   = each.value.role
  member = "serviceAccount:${google_service_account.folder_apply[each.value.folder_key].email}"
}

resource "google_billing_account_iam_member" "folder_apply_billing_roles" {
  for_each = local.folder_apply_billing_bindings

  billing_account_id = var.billing_account_id
  role               = each.value.role
  member             = "serviceAccount:${google_service_account.folder_apply[each.value.folder_key].email}"
}

resource "google_storage_bucket_iam_member" "folder_apply_state_user" {
  for_each = local.ci_folders

  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.folder_apply[each.key].email}"
}

resource "google_kms_crypto_key_iam_member" "folder_apply_kms" {
  for_each = local.ci_folders

  crypto_key_id = google_kms_crypto_key.state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.folder_apply[each.key].email}"
}
