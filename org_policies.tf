locals {
  folder_org_policies = merge([
    for folder_key, folder in var.folders : {
      for constraint, policy in folder.org_policies :
      "${folder_key}:${constraint}" => {
        folder_key = folder_key
        constraint = constraint
        policy     = policy
      }
    }
  ]...)

  subfolder_org_policies = merge([
    for subfolder_key, subfolder in var.subfolders : {
      for constraint, policy in subfolder.org_policies :
      "${subfolder_key}:${constraint}" => {
        subfolder_key = subfolder_key
        constraint    = constraint
        policy        = policy
      }
    }
  ]...)
}

resource "google_org_policy_policy" "org" {
  for_each = var.org_policies

  name   = "organizations/${var.org_id}/policies/${each.key}"
  parent = "organizations/${var.org_id}"

  spec {
    inherit_from_parent = each.value.inherit_from_parent
    reset               = each.value.reset

    dynamic "rules" {
      for_each = each.value.rules
      content {
        enforce   = rules.value.enforce != null ? (rules.value.enforce ? "TRUE" : "FALSE") : null
        allow_all = rules.value.allow_all != null ? (rules.value.allow_all ? "TRUE" : "FALSE") : null
        deny_all  = rules.value.deny_all != null ? (rules.value.deny_all ? "TRUE" : "FALSE") : null

        dynamic "values" {
          for_each = (length(rules.value.allowed_values) > 0 || length(rules.value.denied_values) > 0) ? [1] : []
          content {
            allowed_values = length(rules.value.allowed_values) > 0 ? rules.value.allowed_values : null
            denied_values  = length(rules.value.denied_values) > 0 ? rules.value.denied_values : null
          }
        }

        dynamic "condition" {
          for_each = rules.value.condition != null ? [rules.value.condition] : []
          content {
            description = condition.value.description
            expression  = condition.value.expression
            location    = condition.value.location
            title       = condition.value.title
          }
        }
      }
    }
  }

  depends_on = [google_project_service.seed_apis]
}

resource "google_org_policy_policy" "folder" {
  for_each = local.folder_org_policies

  name   = "${google_folder.folders[each.value.folder_key].name}/policies/${each.value.constraint}"
  parent = google_folder.folders[each.value.folder_key].name

  spec {
    inherit_from_parent = each.value.policy.inherit_from_parent
    reset               = each.value.policy.reset

    dynamic "rules" {
      for_each = each.value.policy.rules
      content {
        enforce   = rules.value.enforce != null ? (rules.value.enforce ? "TRUE" : "FALSE") : null
        allow_all = rules.value.allow_all != null ? (rules.value.allow_all ? "TRUE" : "FALSE") : null
        deny_all  = rules.value.deny_all != null ? (rules.value.deny_all ? "TRUE" : "FALSE") : null

        dynamic "values" {
          for_each = (length(rules.value.allowed_values) > 0 || length(rules.value.denied_values) > 0) ? [1] : []
          content {
            allowed_values = length(rules.value.allowed_values) > 0 ? rules.value.allowed_values : null
            denied_values  = length(rules.value.denied_values) > 0 ? rules.value.denied_values : null
          }
        }

        dynamic "condition" {
          for_each = rules.value.condition != null ? [rules.value.condition] : []
          content {
            description = condition.value.description
            expression  = condition.value.expression
            location    = condition.value.location
            title       = condition.value.title
          }
        }
      }
    }
  }

  depends_on = [google_project_service.seed_apis]
}

resource "google_org_policy_policy" "subfolder" {
  for_each = local.subfolder_org_policies

  name   = "${google_folder.subfolders[each.value.subfolder_key].name}/policies/${each.value.constraint}"
  parent = google_folder.subfolders[each.value.subfolder_key].name

  spec {
    inherit_from_parent = each.value.policy.inherit_from_parent
    reset               = each.value.policy.reset

    dynamic "rules" {
      for_each = each.value.policy.rules
      content {
        enforce   = rules.value.enforce != null ? (rules.value.enforce ? "TRUE" : "FALSE") : null
        allow_all = rules.value.allow_all != null ? (rules.value.allow_all ? "TRUE" : "FALSE") : null
        deny_all  = rules.value.deny_all != null ? (rules.value.deny_all ? "TRUE" : "FALSE") : null

        dynamic "values" {
          for_each = (length(rules.value.allowed_values) > 0 || length(rules.value.denied_values) > 0) ? [1] : []
          content {
            allowed_values = length(rules.value.allowed_values) > 0 ? rules.value.allowed_values : null
            denied_values  = length(rules.value.denied_values) > 0 ? rules.value.denied_values : null
          }
        }

        dynamic "condition" {
          for_each = rules.value.condition != null ? [rules.value.condition] : []
          content {
            description = condition.value.description
            expression  = condition.value.expression
            location    = condition.value.location
            title       = condition.value.title
          }
        }
      }
    }
  }

  depends_on = [google_project_service.seed_apis]
}
