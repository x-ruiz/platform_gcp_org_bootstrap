mock_provider "random" {
  mock_resource "random_id" {
    defaults = {
      hex = "a1b2"
    }
  }
}

mock_provider "github" {}

mock_provider "google" {
  mock_resource "google_folder" {
    defaults = {
      name      = "folders/123456789012"
      folder_id = "123456789012"
    }
  }

  mock_resource "google_iam_workload_identity_pool" {
    defaults = {
      name = "projects/111111111111/locations/global/workloadIdentityPools/github-actions-pool"
    }
  }

  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/org-seed-test-001/serviceAccounts/sa-tofu-mock@org-seed-test-001.iam.gserviceaccount.com"
      email = "sa-tofu-mock@org-seed-test-001.iam.gserviceaccount.com"
    }
  }

  mock_resource "google_kms_crypto_key" {
    defaults = {
      id = "projects/org-seed-test-001/locations/us-central1/keyRings/gcp-org-bootstrap-tofu-state/cryptoKeys/tofu-state-key"
    }
  }
}

variables {
  org_id             = "999888777666"
  billing_account_id = "01ABCD-23EFGH-45IJKL"
  github_owner       = "x-ruiz"
  seed_project_id    = "org-seed-test-001"
  state_kms_key_id   = "projects/org-seed-test-001/locations/us-central1/keyRings/gcp-org-bootstrap-tofu-state/cryptoKeys/tofu-state-key"

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
    ai-platform = {
      display_name = "ai-platform"
      ci = {
        github_repository = "x-ruiz/platform-ai-gcp"
        github_var_prefix = "AI_GCP"
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
    ai-experiments = {
      parent_folder_key = "ai-platform"
      display_name      = "experiments"
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
}

# Multi-folder creation, Seed hardening, WIF least privilege, Org Policies, and decoupled GitHub vars
run "multi_folder_hardening_and_org_policies" {
  command = plan

  assert {
    condition     = google_project.seed.project_id == "org-seed-test-001-a1b2" && google_project.seed.org_id == "999888777666" && google_project.seed.auto_create_network == false && google_project.seed.deletion_policy == "PREVENT"
    error_message = "Seed project must append 4-char hex suffix, sit under org_id when seed_folder_key is null, disable auto_create_network, and enforce deletion_policy = PREVENT."
  }

  assert {
    condition     = google_storage_bucket.state.uniform_bucket_level_access == true && google_storage_bucket.state.public_access_prevention == "enforced" && google_storage_bucket.state.force_destroy == false && google_storage_bucket.state.versioning[0].enabled == true
    error_message = "State bucket must enforce UBLA, PAP, versioning, and force_destroy = false."
  }

  assert {
    condition     = google_kms_crypto_key.state.rotation_period == "7776000s"
    error_message = "Cloud KMS state encryption key must configure 90-day automatic rotation."
  }

  assert {
    condition     = length(google_folder.folders) == 3 && google_folder.folders["unified-data-platform"].parent == "organizations/999888777666" && google_folder.folders["sandbox"].deletion_protection == false
    error_message = "All top-level folders must sit under org_id with configured deletion_protection."
  }

  assert {
    condition     = length(google_folder.subfolders) == 1 && google_folder.subfolders["ai-experiments"].display_name == "experiments"
    error_message = "Subfolders must be created under their parent top-level folder."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository in ['x-ruiz/platform-ai-gcp', 'x-ruiz/playground-cloud-engineering']"
    error_message = "WIF OIDC provider must restrict federation strictly to the sorted set of authorized repositories."
  }

  assert {
    condition     = length(google_service_account.folder_plan) == 2 && length(google_service_account.folder_apply) == 2 && google_service_account.folder_plan["unified-data-platform"].account_id == "sa-tofu-plan" && google_service_account.folder_plan["ai-platform"].account_id == "sa-ai-platform-plan"
    error_message = "Only CI-enabled folders should provision plan/apply SAs (sandbox has no CI SAs), honoring custom and derived account IDs."
  }

  assert {
    condition     = endswith(google_service_account_iam_member.folder_wif_apply["unified-data-platform"].member, "/attribute.repository_ref/x-ruiz/playground-cloud-engineering:refs/heads/main") && endswith(google_service_account_iam_member.folder_wif_apply["ai-platform"].member, "/attribute.repository_ref/x-ruiz/platform-ai-gcp:refs/heads/main")
    error_message = "Each folder's apply SA WIF binding must be restricted strictly to its repository and apply branch."
  }

  assert {
    condition     = google_storage_bucket_iam_member.folder_plan_state_viewer["ai-platform"].role == "roles/storage.objectViewer" && google_storage_bucket_iam_member.folder_plan_state_lock["ai-platform"].condition[0].expression == "resource.name.endsWith(\".tflock\")"
    error_message = "Folder plan SAs must have read-only GCS objectViewer plus .tflock-only conditional lock permission."
  }

  assert {
    condition     = length(github_actions_variable.folder_ci) == 14 && contains(keys(github_actions_variable.folder_ci), "unified-data-platform:UDP_GCP_PLATFORM_FOLDER_ID") && contains(keys(github_actions_variable.folder_ci), "ai-platform:AI_GCP_FOLDER_ID") && !contains(keys(github_actions_variable.folder_ci), "unified-data-platform:UDP_GCP_DEV_PROJECT_ID") && !contains(keys(github_actions_variable.folder_ci), "unified-data-platform:UDP_GCP_BUDGET_ALERT_EMAIL")
    error_message = "Org bootstrap must sync 7 org-owned vars per CI folder and never manage platform dev_project_id or budget_alert_email."
  }

  assert {
    condition     = length(google_org_policy_policy.org) == 2 && google_org_policy_policy.org["iam.disableServiceAccountKeyCreation"].spec[0].rules[0].enforce == "TRUE" && length(google_org_policy_policy.folder) == 1 && google_org_policy_policy.folder["ai-platform:gcp.resourceLocations"].spec[0].rules[0].values[0].allowed_values[0] == "in:us-locations"
    error_message = "Org-level and folder-level Organization Policies must render boolean and list constraints accurately."
  }
}

run "single_repo_wif_condition_backward_compatible" {
  command = plan

  variables {
    seed_folder_key   = "unified-data-platform"
    seed_project_name = "UDP Seed"
    kms_key_ring_name = "unified-data-platform-tofu-state"
    subfolders        = {}
    org_policies      = {}
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
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository == 'x-ruiz/playground-cloud-engineering'"
    error_message = "Single-repo configuration must keep exact equality attribute_condition for backward compatibility."
  }

  assert {
    condition     = google_project.seed.org_id == null && google_project.seed.folder_id == "123456789012" && google_kms_key_ring.state.name == "unified-data-platform-tofu-state"
    error_message = "seed_folder_key and kms_key_ring_name overrides must preserve existing live Seed project and KeyRing placement."
  }
}

run "zero_repos_wif_fails_closed" {
  command = plan

  variables {
    folders      = {}
    subfolders   = {}
    org_policies = {}
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "false"
    error_message = "WIF OIDC provider must fail closed when no repositories are authorized."
  }
}

run "reject_non_numeric_org_id" {
  command = plan

  variables {
    org_id = "org-invalid"
  }

  expect_failures = [var.org_id]
}

run "reject_invalid_folder_repo_format" {
  command = plan

  variables {
    subfolders = {}
    folders = {
      bad-repo = {
        display_name = "bad-repo"
        ci = {
          github_repository = "not-owner-slash-repo"
        }
      }
    }
  }

  expect_failures = [var.folders]
}
