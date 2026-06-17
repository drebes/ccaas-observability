# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

locals {
  # Parse GCS URIs into bucket, path_pattern, and config
  parsed_paths = {
    for uri, cfg in var.gcs_path_configs : uri => {
      bucket                  = split("/", replace(uri, "gs://", ""))[0]
      path_pattern            = replace(uri, "gs://${split("/", replace(uri, "gs://", ""))[0]}", "")
      ccaas_project_id        = cfg.ccaas_project_id
      ccaas_resource_location = cfg.ccaas_resource_location
      ccaas_resource_id       = cfg.ccaas_resource_id
    }
  }

  # Unique buckets that we need to monitor
  unique_buckets = distinct([for uri, parsed in local.parsed_paths : parsed.bucket])

  # Unique target projects where we write logs
  unique_target_projects = distinct([for uri, parsed in local.parsed_paths : parsed.ccaas_project_id])
}

# Lookup GCS buckets to fetch their location dynamically
data "google_storage_bucket" "monitored_buckets" {
  for_each = toset(local.unique_buckets)
  name     = each.value
}


# Enable required services for storage project scope (conditional)
resource "google_project_service" "services" {
  for_each = var.enable_apis ? toset([
    "run.googleapis.com",
    "eventarc.googleapis.com",
    "logging.googleapis.com",
    "storage.googleapis.com",
    "pubsub.googleapis.com"
  ]) : []
  project            = var.storage_project_id
  service            = each.key
  disable_on_destroy = false
}


# Runtime Service Account for Cloud Run
resource "google_service_account" "metadata_logger_sa" {
  project      = var.storage_project_id
  account_id   = "metadata-logger-run-sa"
  display_name = "Metadata Logger Cloud Run Runtime SA"
}

# Grant GCS Read Access to Cloud Run SA for each bucket
resource "google_storage_bucket_iam_member" "gcs_object_viewer" {
  for_each = toset(local.unique_buckets)
  bucket   = each.value
  role     = "roles/storage.objectViewer"
  member   = "serviceAccount:${google_service_account.metadata_logger_sa.email}"
}

# Grant Log Writer permission to the destination Logging Projects
resource "google_project_iam_member" "logging_log_writer" {
  for_each = var.grant_project_iam_roles ? toset(local.unique_target_projects) : []
  project  = each.value
  role     = "roles/logging.logWriter"
  member   = "serviceAccount:${google_service_account.metadata_logger_sa.email}"
}

# Eventarc Trigger Service Account
resource "google_service_account" "eventarc_trigger_sa" {
  project      = var.storage_project_id
  account_id   = "metadata-logger-trigger-sa"
  display_name = "Metadata Logger Eventarc Trigger SA"
}

# Grant Event Receiver role to Eventarc SA
resource "google_project_iam_member" "eventarc_receiver" {
  count   = var.grant_project_iam_roles ? 1 : 0
  project = var.storage_project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.eventarc_trigger_sa.email}"
}

# Grant GCS service agent Pub/Sub Publisher role (required by direct Eventarc GCS triggers)
data "google_storage_project_service_account" "gcs_account" {
  project = var.storage_project_id
}

resource "google_project_iam_member" "gcs_pubsub_publisher" {
  count   = var.grant_project_iam_roles ? 1 : 0
  project = var.storage_project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"
}

# Cloud Run service instance
resource "google_cloud_run_v2_service" "metadata_logger" {
  name     = "metadata-logger"
  project  = var.storage_project_id
  location = var.region
  deletion_protection = false

  template {
    service_account = google_service_account.metadata_logger_sa.email

    containers {
      image = var.image_url

      env {
        name  = "CUSTOM_LOG_NAME"
        value = var.custom_log_name
      }

      env {
        name = "PATH_CONFIGS"
        value = jsonencode([
          for uri, parsed in local.parsed_paths : {
            bucket                  = parsed.bucket
            path_pattern            = parsed.path_pattern
            ccaas_project_id        = parsed.ccaas_project_id
            ccaas_resource_location = parsed.ccaas_resource_location
            ccaas_resource_id       = parsed.ccaas_resource_id
          }
        ])
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }

    scaling {
      max_instance_count = 50
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    google_project_service.services
  ]
}

# Grant Invoker access to Eventarc trigger Service Account on Cloud Run
resource "google_cloud_run_v2_service_iam_member" "eventarc_invoker" {
  project  = var.storage_project_id
  location = var.region
  name     = google_cloud_run_v2_service.metadata_logger.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.eventarc_trigger_sa.email}"
}

# Eventarc triggers mapping one-to-one to target buckets
resource "google_eventarc_trigger" "gcs_trigger" {
  for_each = toset(local.unique_buckets)

  name     = "md-log-tr-${substr(replace(each.value, ".", "-"), 0, 40)}-${substr(md5(each.value), 0, 4)}"
  location = lower(data.google_storage_bucket.monitored_buckets[each.value].location)
  project  = var.storage_project_id

  event_data_content_type = "application/json"

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }

  matching_criteria {
    attribute = "bucket"
    value     = each.value
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.metadata_logger.name
      region  = var.region
      path    = "/"
    }
  }

  service_account = google_service_account.eventarc_trigger_sa.email

  depends_on = [
    google_project_service.services,
    google_project_iam_member.gcs_pubsub_publisher,
    google_cloud_run_v2_service_iam_member.eventarc_invoker
  ]
}
