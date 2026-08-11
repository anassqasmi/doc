variable "namespace" {
  description = "Existing namespace to deploy Airflow into."
  type        = string
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "airflow"
}

variable "hostname" {
  description = "Public hostname served by the Istio gateway."
  type        = string
}

variable "istio_gateway" {
  description = "Existing Istio Gateway, as namespace/name."
  type        = string
  default     = "istio-system/public-gateway"
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL (discovery document is derived from it)."
  type        = string
}

variable "oidc_secret_name" {
  description = "Existing secret holding the OIDC credentials (keys: client-id, client-secret)."
  type        = string
}

variable "oidc_callback_url" {
  description = "Redirect URI registered in the IdP."
  type        = string
  default     = null
}

variable "airflow_image" {
  description = "Airflow image used by every container in the pod."
  type        = string
  default     = "apache/airflow:3.2.2"
}

variable "public_url" {
  description = "Full public URL including path if any (e.g. https://host/airflow). Overrides hostname+url_path."
  type        = string
  default     = null
}

variable "url_path" {
  description = "Path prefix on the host (e.g. /airflow). Must match api.base_url. Empty = host root."
  type        = string
  default     = ""
}

locals {
  # "" or "/airflow"
  url_path = trimsuffix(var.url_path == "/" ? "" : var.url_path, "/")
  base_url = trimsuffix(
    coalesce(var.public_url, "https://${var.hostname}${local.url_path}"),
    "/",
  )
  # Prefer explicit url_path; else path taken from public_url.
  path = (
    local.url_path != ""
    ? local.url_path
    : try(trimsuffix(regex("https?://[^/]+(/.*)$", local.base_url), "/"), "")
  )
  callback_url = coalesce(var.oidc_callback_url, "${local.base_url}/auth/oauth-authorized/oidc")
  db_path      = "/opt/airflow/metadata/airflow.db"

  dest = {
    host = "${var.release_name}-api-server.${var.namespace}.svc.cluster.local"
    port = { number = 8080 }
  }

  # If path=/airflow: redirect / → /airflow/, route /airflow/** as-is (no strip).
  # Airflow 3 with base_url …/airflow serves static at /airflow/static/… — stripping breaks it.
  vs_http = yamldecode(local.path == "" ? yamlencode([{
    route = [{ destination = local.dest }]
    }]) : yamlencode([
    {
      match    = [{ uri = { exact = "/" } }]
      redirect = { uri = "${local.path}/" }
    },
    {
      match    = [{ uri = { exact = local.path } }]
      redirect = { uri = "${local.path}/" }
    },
    {
      match = [{ uri = { prefix = "${local.path}/" } }]
      route = [{ destination = local.dest }]
    },
  ]))

  sidecar = {
    image = var.airflow_image
    env = [
      { name = "AIRFLOW__DATABASE__SQL_ALCHEMY_CONN", valueFrom = { secretKeyRef = { name = kubernetes_secret_v1.metadata_connection.metadata[0].name, key = "connection" } } },
      { name = "AIRFLOW__CORE__FERNET_KEY", valueFrom = { secretKeyRef = { name = "${var.release_name}-fernet-key", key = "fernet-key" } } },
      { name = "AIRFLOW__API_AUTH__JWT_SECRET", valueFrom = { secretKeyRef = { name = "${var.release_name}-jwt-secret", key = "jwt-secret" } } },
    ]
    volumeMounts = [
      { name = "config", mountPath = "/opt/airflow/airflow.cfg", subPath = "airflow.cfg", readOnly = true },
      { name = "metadata-db", mountPath = dirname(local.db_path) },
    ]
  }
}

resource "kubernetes_secret_v1" "metadata_connection" {
  metadata {
    name      = "${var.release_name}-metadata-connection"
    namespace = var.namespace
  }
  data = {
    connection = "sqlite:///${local.db_path}"
  }
}

resource "helm_release" "airflow" {
  name      = var.release_name
  chart     = "${path.module}/chart"
  namespace = var.namespace
  timeout   = 900

  values = [yamlencode({
    executor   = "LocalExecutor"
    images     = { airflow = { repository = split(":", var.airflow_image)[0], tag = split(":", var.airflow_image)[1] } }
    postgresql = { enabled = false }
    redis      = { enabled = false }
    statsd     = { enabled = false }

    data = { metadataSecretName = kubernetes_secret_v1.metadata_connection.metadata[0].name }

    volumes      = [{ name = "metadata-db", emptyDir = {} }]
    volumeMounts = [{ name = "metadata-db", mountPath = dirname(local.db_path) }]

    # Airflow 3: [api] base_url (not webserver.base_url). Path here must match url_path.
    config = {
      api  = { base_url = local.base_url }
      core = { auth_manager = "airflow.providers.fab.auth_manager.fab_auth_manager.FabAuthManager" }
    }

    apiServer = {
      args              = ["bash", "-c", "exec airflow api-server --proxy-headers"]
      waitForMigrations = { enabled = false }
      extraInitContainers = [
        merge(local.sidecar, { name = "db-migrate", args = ["bash", "-c", "airflow db migrate"] }),
      ]
      extraContainers = [
        merge(local.sidecar, { name = "scheduler", args = ["bash", "-c", "exec airflow scheduler"] }),
        merge(local.sidecar, { name = "dag-processor", args = ["bash", "-c", "exec airflow dag-processor"] }),
      ]
      env = [
        { name = "FORWARDED_ALLOW_IPS", value = "*" },
        { name = "OIDC_ISSUER_URL", value = var.oidc_issuer_url },
        { name = "OIDC_CLIENT_ID", valueFrom = { secretKeyRef = { name = var.oidc_secret_name, key = "client-id" } } },
        { name = "OIDC_CLIENT_SECRET", valueFrom = { secretKeyRef = { name = var.oidc_secret_name, key = "client-secret" } } },
      ]
      apiServerConfig = file("${path.module}/webserver_config.py")
    }
  })]
}

resource "kubernetes_manifest" "virtual_service" {
  manifest = {
    apiVersion = "networking.istio.io/v1"
    kind       = "VirtualService"
    metadata = {
      name      = var.release_name
      namespace = var.namespace
    }
    spec = {
      hosts    = [var.hostname]
      gateways = [var.istio_gateway]
      http     = local.vs_http
    }
  }

  depends_on = [helm_release.airflow]
}

output "airflow_url" {
  value = local.base_url
}

output "oidc_callback_url" {
  value = local.callback_url
}
