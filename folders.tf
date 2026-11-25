locals {
  yaml_folder_files = var.load_folders_from_yaml ? fileset("${path.module}/folders", "*.yaml") : toset([])

  yaml_folders_raw = {
    for f in local.yaml_folder_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/folders/${f}"))
  }

  yaml_folders = {
    for k, raw in local.yaml_folders_raw : k => {
      display_name        = raw.display_name
      deletion_protection = try(raw.deletion_protection, true)
      ci = try(raw.ci, null) == null ? null : {
        github_repository    = raw.ci.github_repository
        apply_branch         = try(raw.ci.apply_branch, "main")
        plan_sa_account_id   = try(raw.ci.plan_sa_account_id, null)
        apply_sa_account_id  = try(raw.ci.apply_sa_account_id, null)
        plan_folder_roles    = try(raw.ci.plan_folder_roles, null) == null ? null : toset(raw.ci.plan_folder_roles)
        apply_folder_roles   = try(raw.ci.apply_folder_roles, null) == null ? null : toset(raw.ci.apply_folder_roles)
        apply_billing_roles  = try(raw.ci.apply_billing_roles, null) == null ? null : toset(raw.ci.apply_billing_roles)
        grant_billing_access = try(raw.ci.grant_billing_access, true)
        sync_github_vars     = try(raw.ci.sync_github_vars, true)
        github_var_prefix    = try(raw.ci.github_var_prefix, null)
        folder_id_var_suffix = try(raw.ci.folder_id_var_suffix, "FOLDER_ID")
      }
      org_policies = {
        for constraint, pol in try(raw.org_policies, {}) : constraint => {
          inherit_from_parent = try(pol.inherit_from_parent, false)
          reset               = try(pol.reset, false)
          rules = [
            for r in try(pol.rules, []) : {
              enforce        = try(r.enforce, null)
              allow_all      = try(r.allow_all, null)
              deny_all       = try(r.deny_all, null)
              allowed_values = try(r.allowed_values, [])
              denied_values  = try(r.denied_values, [])
              condition = try(r.condition, null) == null ? null : {
                description = try(r.condition.description, null)
                expression  = r.condition.expression
                location    = try(r.condition.location, null)
                title       = r.condition.title
              }
            }
          ]
        }
      }
    }
  }

  yaml_subfolders = merge([
    for parent_key, raw in local.yaml_folders_raw : {
      for sf_key, sf in try(raw.subfolders, {}) : sf_key => {
        parent_folder_key   = parent_key
        display_name        = sf.display_name
        deletion_protection = try(sf.deletion_protection, true)
        org_policies = {
          for constraint, pol in try(sf.org_policies, {}) : constraint => {
            inherit_from_parent = try(pol.inherit_from_parent, false)
            reset               = try(pol.reset, false)
            rules = [
              for r in try(pol.rules, []) : {
                enforce        = try(r.enforce, null)
                allow_all      = try(r.allow_all, null)
                deny_all       = try(r.deny_all, null)
                allowed_values = try(r.allowed_values, [])
                denied_values  = try(r.denied_values, [])
                condition = try(r.condition, null) == null ? null : {
                  description = try(r.condition.description, null)
                  expression  = r.condition.expression
                  location    = try(r.condition.location, null)
                  title       = r.condition.title
                }
              }
            ]
          }
        }
      }
    }
  ]...)

  # Declarative folders/*.yaml files merged with optional terraform.tfvars overrides.
  effective_folders    = merge(local.yaml_folders, var.folders)
  effective_subfolders = merge(local.yaml_subfolders, var.subfolders)
}

resource "google_folder" "folders" {
  for_each = local.effective_folders

  display_name        = each.value.display_name
  parent              = "organizations/${var.org_id}"
  deletion_protection = each.value.deletion_protection

  lifecycle {
    precondition {
      condition     = can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", each.key)) && length(each.value.display_name) >= 3 && length(each.value.display_name) <= 30
      error_message = "Each folder key must be 3-30 lowercase alphanumeric/hyphen chars and display_name must be 3-30 characters."
    }

    precondition {
      condition     = each.value.ci == null ? true : can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", each.value.ci.github_repository))
      error_message = "When folder ci is configured, ci.github_repository must be in owner/repo format."
    }
  }
}

resource "google_folder" "subfolders" {
  for_each = local.effective_subfolders

  display_name        = each.value.display_name
  parent              = google_folder.folders[each.value.parent_folder_key].name
  deletion_protection = each.value.deletion_protection

  lifecycle {
    precondition {
      condition     = contains(keys(local.effective_folders), each.value.parent_folder_key)
      error_message = "Each subfolder's parent_folder_key must match a key defined in folders/*.yaml or var.folders."
    }
  }
}
