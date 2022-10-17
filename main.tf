module "rerun" {
  source = "git::https://github.com/GlueOps/terraform-toggle-rerun-for-tfc-operator.git?ref=v0.1.0"
}

variable "VAULT_ADDR" {
  type        = string
  description = "The url of the vault server Example: https://vault.us-production.glueops.rocks"
}

terraform {
  required_providers {
    vaultoperator = {
      source  = "rickardgranberg/vaultoperator"
      version = "0.1.6"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "3.8.2"
    }
    tfe = {
      source = "hashicorp/tfe"
      version = "0.37.0"
    }
  }
}

provider "vaultoperator" {
  vault_addr = var.VAULT_ADDR
}

resource "vaultoperator_init" "default" {
  recovery_shares    = 5
  recovery_threshold = 3
}

provider "vault" {
  token   = vaultoperator_init.default.root_token
  address = var.VAULT_ADDR
}


resource "vault_policy" "super_admin" {
  name = "super_admin"

  policy = <<EOT
        path "*" {
        capabilities = ["create", "read", "update", "delete", "list", "sudo"]
        }
EOT
}

resource "vault_policy" "admin" {
  name = "admin"

  policy = <<EOF
    # Read system health check
    path "sys/health"
    {
      capabilities = ["read", "sudo"]
    }

    # Create and manage ACL policies broadly across Vault

    # List existing policies
    path "sys/policies/acl"
    {
      capabilities = ["list"]
    }

    # Create and manage ACL policies
    path "sys/policies/acl/*"
    {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }

    # Enable and manage authentication methods broadly across Vault

    # Manage auth methods broadly across Vault
    path "auth/*"
    {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }

    # Create, update, and delete auth methods
    path "sys/auth/*"
    {
      capabilities = ["create", "update", "delete", "sudo"]
    }

    # List auth methods
    path "sys/auth"
    {
      capabilities = ["read"]
    }

    # Enable and manage the key/value secrets engine at `secret/` path

    # List, create, update, and delete key/value secrets
    path "secret/*"
    {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }

    # Manage secrets engines
    path "sys/mounts/*"
    {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }

    # List existing secrets engines.
    path "sys/mounts"
    {
      capabilities = ["read"]
    }

    # Disable misleading cubbyhole, the path with broad access
    path "/cubbyhole/*" {
      capabilities = ["deny"]
    }
    EOF

}

resource "vault_policy" "developers" {
  name = "developers"

  policy = <<EOF
    path "secret/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    path "/cubbyhole/*" {
      capabilities = ["deny"]
    }
EOF
}

resource "vault_github_auth_backend" "glueops" {
  organization = "GlueOps"
  path         = "glueops/github"
}

resource "vault_github_auth_backend" "client" {
  organization = "antoniostacos"
  path         = "github"

  tune {
    allowed_response_headers     = []
    audit_non_hmac_request_keys  = []
    audit_non_hmac_response_keys = []
    default_lease_ttl            = "768h"
    listing_visibility           = "unauth"
    max_lease_ttl                = "768h"
    passthrough_request_headers  = []
    token_type                   = "default-service"
  }
}

resource "vault_github_team" "vault_super_admins" {
  backend  = vault_github_auth_backend.glueops.id
  team     = "vault_super_admins"
  policies = [vault_policy.super_admin.name]
}


resource "vault_github_team" "developers" {
  backend  = vault_github_auth_backend.client.id
  team     = "developers"
  policies = [vault_policy.developers.name]
}


resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}



resource "vault_kubernetes_auth_backend_config" "config" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = "https://kubernetes.default.svc.cluster.local:443"
}

locals {
  envs = ["development", "staging", "production"]
}

resource "vault_kubernetes_auth_backend_role" "env_roles" {
  for_each = toset(local.envs)

  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "${each.key}-vault-role"
  bound_service_account_names      = ["*"]
  bound_service_account_namespaces = [each.key]
  token_ttl                        = 3600
  token_policies                   = ["${each.key}-secrets-reader"]
}


resource "vault_policy" "read_all_env_specific_secrets" {
  for_each = toset(local.envs)

  name = "${each.key}-secrets-reader"

  policy = <<EOF
    path "secret/${each.key}/*" {
    capabilities = ["read"]
  }
EOF
}

resource "vault_mount" "secrets_kvv2" {
  for_each    = toset(local.envs)
  path        = "secret/${each.key}"
  type        = "kv-v2"
  description = "KV Version 2 secrets mount"
}
 
