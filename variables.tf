variable "org_id" {
  description = "Numeric GCP Organization ID under which top-level folders, Org Policies, and the Seed project are managed."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.org_id))
    error_message = "org_id must be a numeric GCP Organization ID (digits only)."
  }
}

variable "billing_account_id" {
  description = "GCP Billing Account ID in XXXXXX-XXXXXX-XXXXXX format."
  type        = string

  validation {
    condition     = can(regex("^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$", var.billing_account_id))
    error_message = "billing_account_id must match the format XXXXXX-XXXXXX-XXXXXX."
  }
}

variable "github_owner" {
  description = "GitHub organization or username owning repositories authorized via WIF and synced by integrations/github."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.github_owner))
    error_message = "github_owner must be a valid GitHub organization or username."
  }
}

variable "bootstrap_name" {
  description = "Lowercase slug used for Org bootstrap labels and default Cloud KMS KeyRing naming."
  type        = string
  default     = "gcp-org-bootstrap"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,28}[a-z0-9]$", var.bootstrap_name))
    error_message = "bootstrap_name must be 4-30 lowercase alphanumeric characters or hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "kms_key_ring_name" {
  description = "Optional explicit Cloud KMS KeyRing name override (defaults to <bootstrap_name>-tofu-state). Set when adopting an existing live KeyRing."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_ring_name == null ? true : can(regex("^[a-zA-Z0-9_-]{1,63}$", var.kms_key_ring_name))
    error_message = "kms_key_ring_name must be 1-63 alphanumeric, underscore, or hyphen characters."
  }
}

variable "seed_project_id" {
  description = "Base GCP Project ID prefix for the Org bootstrap Seed project (a random 4-char hex suffix -xxxx is appended automatically)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}[a-z0-9]$", var.seed_project_id))
    error_message = "seed_project_id must be 4-25 lowercase letters, digits, or hyphens (leaving room for the -xxxx random suffix within GCP's 30-char limit)."
  }
}

variable "seed_project_name" {
  description = "Human-readable display name for the Org bootstrap Seed GCP project (4-30 characters)."
  type        = string
  default     = "Org Bootstrap Seed"

  validation {
    condition     = length(var.seed_project_name) >= 4 && length(var.seed_project_name) <= 30
    error_message = "seed_project_name must be between 4 and 30 characters."
  }
}

variable "seed_folder_key" {
  description = "Optional key in var.folders under which the Seed project resides. When null, the Seed project sits directly under organizations/<org_id>."
  type        = string
  default     = null
}

variable "region" {
  description = "Primary GCP region for the Seed remote state bucket and Cloud KMS KeyRing."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region identifier (e.g., us-central1)."
  }
}

variable "cost_center" {
  description = "Cost center label applied to all Org bootstrap Seed resources."
  type        = string
  default     = "platform-engineering"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{1,61}[a-z0-9]$", var.cost_center))
    error_message = "cost_center must be a valid lowercase GCP label value."
  }
}

variable "state_kms_key_id" {
  description = "Cloud KMS CryptoKey ID used by OpenTofu gcp_kms client-side state encryption."
  type        = string
}

variable "additional_wif_repositories" {
  description = "Optional extra GitHub repositories (owner/repo) allowed to exchange OIDC tokens via the org WIF provider."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.additional_wif_repositories : can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", r))])
    error_message = "Every entry in additional_wif_repositories must match owner/repo format."
  }
}

variable "folders" {
  description = "Top-level GCP folders under organizations/<org_id>, each with optional keyless GitHub Actions WIF CI/CD and folder-scoped Organization Policies."
  type = map(object({
    display_name        = string
    deletion_protection = optional(bool, true)
    ci = optional(object({
      github_repository    = string
      apply_branch         = optional(string, "main")
      plan_sa_account_id   = optional(string)
      apply_sa_account_id  = optional(string)
      plan_folder_roles    = optional(set(string))
      apply_folder_roles   = optional(set(string))
      apply_billing_roles  = optional(set(string))
      grant_billing_access = optional(bool, true)
      sync_github_vars     = optional(bool, true)
      github_var_prefix    = optional(string)
      folder_id_var_suffix = optional(string, "FOLDER_ID")
    }))
    org_policies = optional(map(object({
      inherit_from_parent = optional(bool, false)
      reset               = optional(bool, false)
      rules = optional(list(object({
        enforce        = optional(bool)
        allow_all      = optional(bool)
        deny_all       = optional(bool)
        allowed_values = optional(list(string), [])
        denied_values  = optional(list(string), [])
        condition = optional(object({
          description = optional(string)
          expression  = string
          location    = optional(string)
          title       = string
        }))
      })), [])
    })), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, f in var.folders :
      can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", k)) &&
      length(f.display_name) >= 3 && length(f.display_name) <= 30
    ])
    error_message = "Each folder key must be 3-30 lowercase alphanumeric/hyphen chars and display_name must be 3-30 characters."
  }

  validation {
    condition = alltrue([
      for f in values(var.folders) :
      f.ci == null ? true : can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", f.ci.github_repository))
    ])
    error_message = "When folder ci is configured, ci.github_repository must be in owner/repo format."
  }

  validation {
    condition = alltrue([
      for f in values(var.folders) :
      f.ci == null ? true : (
        (f.ci.plan_sa_account_id == null ? true : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", f.ci.plan_sa_account_id))) &&
        (f.ci.apply_sa_account_id == null ? true : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", f.ci.apply_sa_account_id)))
      )
    ])
    error_message = "Custom plan_sa_account_id and apply_sa_account_id must be 6-30 lowercase letters, digits, or hyphens."
  }

  validation {
    condition = alltrue([
      for f in values(var.folders) :
      f.ci == null ? true : (
        f.ci.github_var_prefix == null ? true : can(regex("^[A-Z][A-Z0-9_]*$", f.ci.github_var_prefix))
      )
    ])
    error_message = "ci.github_var_prefix must be uppercase letters, digits, or underscores starting with a letter."
  }
}

variable "subfolders" {
  description = "Optional second-level child folders nested under keys in var.folders, with optional folder-scoped Organization Policies."
  type = map(object({
    parent_folder_key   = string
    display_name        = string
    deletion_protection = optional(bool, true)
    org_policies = optional(map(object({
      inherit_from_parent = optional(bool, false)
      reset               = optional(bool, false)
      rules = optional(list(object({
        enforce        = optional(bool)
        allow_all      = optional(bool)
        deny_all       = optional(bool)
        allowed_values = optional(list(string), [])
        denied_values  = optional(list(string), [])
        condition = optional(object({
          description = optional(string)
          expression  = string
          location    = optional(string)
          title       = string
        }))
      })), [])
    })), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, sf in var.subfolders :
      can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", k)) &&
      length(sf.display_name) >= 3 && length(sf.display_name) <= 30
    ])
    error_message = "Each subfolder key must be 3-30 lowercase alphanumeric/hyphen chars and display_name must be 3-30 characters."
  }
}

variable "org_policies" {
  description = "Declarative Organization-level GCP Organization Policies keyed by constraint name (e.g., iam.disableServiceAccountKeyCreation)."
  type = map(object({
    inherit_from_parent = optional(bool, false)
    reset               = optional(bool, false)
    rules = optional(list(object({
      enforce        = optional(bool)
      allow_all      = optional(bool)
      deny_all       = optional(bool)
      allowed_values = optional(list(string), [])
      denied_values  = optional(list(string), [])
      condition = optional(object({
        description = optional(string)
        expression  = string
        location    = optional(string)
        title       = string
      }))
    })), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.org_policies) : can(regex("^[a-zA-Z0-9]+\\.[a-zA-Z0-9._-]+$", k))])
    error_message = "Each org_policies key must be a valid GCP constraint name (e.g., iam.disableServiceAccountKeyCreation or gcp.resourceLocations)."
  }
}
