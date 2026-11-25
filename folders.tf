resource "google_folder" "folders" {
  for_each = var.folders

  display_name        = each.value.display_name
  parent              = "organizations/${var.org_id}"
  deletion_protection = each.value.deletion_protection
}

resource "google_folder" "subfolders" {
  for_each = var.subfolders

  display_name        = each.value.display_name
  parent              = google_folder.folders[each.value.parent_folder_key].name
  deletion_protection = each.value.deletion_protection

  lifecycle {
    precondition {
      condition     = contains(keys(var.folders), each.value.parent_folder_key)
      error_message = "Each subfolder's parent_folder_key must match a key defined in var.folders."
    }
  }
}
