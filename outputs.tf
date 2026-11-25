output "seed_project_id" {
  description = "Created Org bootstrap Seed GCP Project ID."
  value       = google_project.seed.project_id
}

output "state_bucket_name" {
  description = "GCS bucket name for OpenTofu remote state."
  value       = google_storage_bucket.state.name
}

output "kms_key_id" {
  description = "Fully qualified Cloud KMS CryptoKey ID for OpenTofu gcp_kms state encryption."
  value       = google_kms_crypto_key.state.id
}

output "wif_provider_name" {
  description = "Full org-wide GitHub OIDC WIF provider resource path for google-github-actions/auth."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "folder_ids" {
  description = "Map of top-level folder key to GCP folder resource name (folders/<id>)."
  value       = { for k, f in google_folder.folders : k => f.name }
}

output "subfolder_ids" {
  description = "Map of second-level subfolder key to GCP folder resource name (folders/<id>)."
  value       = { for k, f in google_folder.subfolders : k => f.name }
}

output "folder_ci_identities" {
  description = "Map of CI-enabled folder key to its GitHub repository, plan SA email, and apply SA email."
  value = {
    for k, cfg in local.ci_folders : k => {
      github_repository           = cfg.github_repository
      plan_service_account_email  = google_service_account.folder_plan[k].email
      apply_service_account_email = google_service_account.folder_apply[k].email
    }
  }
}
