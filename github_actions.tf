locals {
  # Only Org/Bootstrap-owned variables are synced here.
  # Platform/environment-specific variables (e.g., dev project IDs, budget alert emails)
  # belong in each downstream platform repository (e.g., infra/platform & infra/envs).
  folder_github_variables = merge([
    for folder_key, cfg in local.ci_folders : cfg.sync_github_vars ? {
      for suffix, val in {
        WIF_PROVIDER               = google_iam_workload_identity_pool_provider.github.name
        PLAN_SA                    = google_service_account.folder_plan[folder_key].email
        APPLY_SA                   = google_service_account.folder_apply[folder_key].email
        STATE_BUCKET               = google_storage_bucket.state.name
        STATE_KMS_KEY_ID           = google_kms_crypto_key.state.id
        (cfg.folder_id_var_suffix) = google_folder.folders[folder_key].name
        BILLING_ACCOUNT_ID         = var.billing_account_id
        } : "${folder_key}:${cfg.github_var_prefix}_${suffix}" => {
        owner         = split("/", cfg.github_repository)[0]
        repository    = split("/", cfg.github_repository)[1]
        variable_name = "${cfg.github_var_prefix}_${suffix}"
        value         = val
      }
    } : {}
  ]...)
}

resource "github_actions_variable" "folder_ci" {
  for_each = local.folder_github_variables

  repository    = each.value.repository
  variable_name = each.value.variable_name
  value         = each.value.value

  lifecycle {
    precondition {
      condition     = each.value.owner == var.github_owner
      error_message = "ci.github_repository owner must match var.github_owner when sync_github_vars is true."
    }
  }
}
