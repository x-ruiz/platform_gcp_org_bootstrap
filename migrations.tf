# Zero-downtime state migration blocks from single-platform playground bootstrap
# (`platform_unified_data_gcp/infra/bootstrap`) to multi-folder `platform_gcp_org_bootstrap`.
#
# Safe on fresh/greenfield applies (no-op when old addresses do not exist in state).
# Once applied against your existing GCS `bootstrap` state, these blocks may be removed in a follow-up PR.

moved {
  from = google_folder.platform
  to   = google_folder.folders["unified-data-platform"]
}

moved {
  from = google_service_account.tofu_plan
  to   = google_service_account.folder_plan["unified-data-platform"]
}

moved {
  from = google_service_account.tofu_apply
  to   = google_service_account.folder_apply["unified-data-platform"]
}

moved {
  from = google_service_account_iam_member.wif_plan
  to   = google_service_account_iam_member.folder_wif_plan["unified-data-platform"]
}

moved {
  from = google_service_account_iam_member.wif_apply
  to   = google_service_account_iam_member.folder_wif_apply["unified-data-platform"]
}

moved {
  from = google_folder_iam_member.plan_folder_roles["roles/viewer"]
  to   = google_folder_iam_member.folder_plan_roles["unified-data-platform:roles/viewer"]
}

moved {
  from = google_folder_iam_member.plan_folder_roles["roles/iam.securityReviewer"]
  to   = google_folder_iam_member.folder_plan_roles["unified-data-platform:roles/iam.securityReviewer"]
}

moved {
  from = google_folder_iam_member.apply_folder_roles["roles/resourcemanager.projectCreator"]
  to   = google_folder_iam_member.folder_apply_roles["unified-data-platform:roles/resourcemanager.projectCreator"]
}

moved {
  from = google_folder_iam_member.apply_folder_roles["roles/resourcemanager.projectDeleter"]
  to   = google_folder_iam_member.folder_apply_roles["unified-data-platform:roles/resourcemanager.projectDeleter"]
}

moved {
  from = google_folder_iam_member.apply_folder_roles["roles/resourcemanager.projectIamAdmin"]
  to   = google_folder_iam_member.folder_apply_roles["unified-data-platform:roles/resourcemanager.projectIamAdmin"]
}

moved {
  from = google_folder_iam_member.apply_folder_roles["roles/compute.networkAdmin"]
  to   = google_folder_iam_member.folder_apply_roles["unified-data-platform:roles/compute.networkAdmin"]
}

moved {
  from = google_folder_iam_member.apply_folder_roles["roles/serviceusage.serviceUsageAdmin"]
  to   = google_folder_iam_member.folder_apply_roles["unified-data-platform:roles/serviceusage.serviceUsageAdmin"]
}

moved {
  from = google_folder_iam_member.apply_folder_roles["roles/monitoring.notificationChannelEditor"]
  to   = google_folder_iam_member.folder_apply_roles["unified-data-platform:roles/monitoring.notificationChannelEditor"]
}

moved {
  from = google_storage_bucket_iam_member.plan_state_viewer
  to   = google_storage_bucket_iam_member.folder_plan_state_viewer["unified-data-platform"]
}

moved {
  from = google_storage_bucket_iam_member.plan_state_lock
  to   = google_storage_bucket_iam_member.folder_plan_state_lock["unified-data-platform"]
}

moved {
  from = google_kms_crypto_key_iam_member.plan_kms_decrypter
  to   = google_kms_crypto_key_iam_member.folder_plan_kms["unified-data-platform"]
}

moved {
  from = google_billing_account_iam_member.apply_billing_roles["roles/billing.user"]
  to   = google_billing_account_iam_member.folder_apply_billing_roles["unified-data-platform:roles/billing.user"]
}

moved {
  from = google_billing_account_iam_member.apply_billing_roles["roles/billing.costsManager"]
  to   = google_billing_account_iam_member.folder_apply_billing_roles["unified-data-platform:roles/billing.costsManager"]
}

moved {
  from = google_storage_bucket_iam_member.apply_state_user
  to   = google_storage_bucket_iam_member.folder_apply_state_user["unified-data-platform"]
}

moved {
  from = google_kms_crypto_key_iam_member.apply_kms_encrypter_decrypter
  to   = google_kms_crypto_key_iam_member.folder_apply_kms["unified-data-platform"]
}

moved {
  from = github_actions_variable.udp_gcp["UDP_GCP_WIF_PROVIDER"]
  to   = github_actions_variable.folder_ci["unified-data-platform:UDP_GCP_WIF_PROVIDER"]
}

moved {
  from = github_actions_variable.udp_gcp["UDP_GCP_PLAN_SA"]
  to   = github_actions_variable.folder_ci["unified-data-platform:UDP_GCP_PLAN_SA"]
}

moved {
  from = github_actions_variable.udp_gcp["UDP_GCP_APPLY_SA"]
  to   = github_actions_variable.folder_ci["unified-data-platform:UDP_GCP_APPLY_SA"]
}

moved {
  from = github_actions_variable.udp_gcp["UDP_GCP_STATE_BUCKET"]
  to   = github_actions_variable.folder_ci["unified-data-platform:UDP_GCP_STATE_BUCKET"]
}

moved {
  from = github_actions_variable.udp_gcp["UDP_GCP_STATE_KMS_KEY_ID"]
  to   = github_actions_variable.folder_ci["unified-data-platform:UDP_GCP_STATE_KMS_KEY_ID"]
}

moved {
  from = github_actions_variable.udp_gcp["UDP_GCP_PLATFORM_FOLDER_ID"]
  to   = github_actions_variable.folder_ci["unified-data-platform:UDP_GCP_PLATFORM_FOLDER_ID"]
}

moved {
  from = github_actions_variable.udp_gcp["UDP_GCP_BILLING_ACCOUNT_ID"]
  to   = github_actions_variable.folder_ci["unified-data-platform:UDP_GCP_BILLING_ACCOUNT_ID"]
}

# Detach any remaining legacy platform-specific variables (UDP_GCP_DEV_PROJECT_ID,
# UDP_GCP_BUDGET_ALERT_EMAIL) from Org bootstrap state without deleting them in GitHub,
# after the 7 org-owned variables above have moved to github_actions_variable.folder_ci.
removed {
  from = github_actions_variable.udp_gcp

  lifecycle {
    destroy = false
  }
}
