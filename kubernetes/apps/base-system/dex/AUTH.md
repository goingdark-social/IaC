# Authentication and Authorization

This document describes the authentication and authorization flow for accessing ArgoCD and Grafana through Dex OIDC.

## Overview

Authentication is handled by Dex using Mastodon as the OAuth2 provider. Users authenticate with their Mastodon account, and their Mastodon role determines their access level in ArgoCD and Grafana.

## Architecture

```
User → Mastodon OAuth → Dex → Masto-Claims-Proxy → ArgoCD/Grafana
```

### Components

1. **Mastodon OAuth Provider**: Users authenticate using their Mastodon credentials
2. **Dex**: Acts as an OIDC provider, proxying authentication to Mastodon
3. **Masto-Claims-Proxy**: Extracts user roles from Mastodon and maps them to groups
4. **ArgoCD/Grafana**: Consume OIDC tokens from Dex and enforce RBAC based on groups

## Authentication Flow

1. User attempts to access ArgoCD or Grafana
2. Application redirects to Dex (`https://idp.goingdark.social`)
3. Dex redirects to Mastodon OAuth authorization endpoint
4. User authenticates with Mastodon and authorizes the application
5. Mastodon redirects back to Dex with an authorization code
6. Dex exchanges the code for an access token
7. Dex calls masto-claims-proxy with the Mastodon access token
8. Masto-claims-proxy calls Mastodon's `/api/v1/accounts/verify_credentials` endpoint
9. Masto-claims-proxy extracts the user's role and maps it to groups:
   - Mastodon role "Owner" → group "mastodon:Owner"
   - Mastodon role "Admin" → group "mastodon:Admin"
   - Mastodon role "Moderator" → group "mastodon:Moderator"
10. Dex includes the groups in the OIDC token
11. User is redirected back to ArgoCD/Grafana with the OIDC token
12. Application validates the token and checks group membership

## Role Mappings

### ArgoCD

ArgoCD uses RBAC policies to map groups to roles:

| Mastodon Role | Group           | ArgoCD Role   | Permissions                           |
|--------------|-----------------|---------------|---------------------------------------|
| Owner        | mastodon:Owner  | role:admin    | Full administrative access            |
| Admin        | mastodon:Admin  | role:admin    | Full administrative access            |
| Moderator    | mastodon:Moderator | role:readonly | Read-only access to all applications  |
| None         | (no group)      | (none)        | **Access denied**                     |

**Configuration**: `kubernetes/apps/argocd/values.yaml`

```yaml
configs:
  rbac:
    policy.csv: |
      g, mastodon:Owner, role:admin
      g, mastodon:Admin, role:admin
      g, mastodon:Moderator, role:readonly
    policy.default: ""  # Deny access by default
```

### Grafana

Grafana uses JMESPath expressions to map groups to roles:

| Mastodon Role | Group           | Grafana Role | Permissions                          |
|--------------|-----------------|--------------|--------------------------------------|
| Owner        | mastodon:Owner  | Admin        | Full administrative access           |
| Admin        | mastodon:Admin  | Admin        | Full administrative access           |
| Moderator    | mastodon:Moderator | Editor    | Create and edit dashboards           |
| None         | (no group)      | (none)       | **Access denied**                    |

**Configuration**: `kubernetes/apps/base-system/victoriametrics/helm-values.yaml`

```yaml
grafana:
  grafana.ini:
    auth.generic_oauth:
      role_attribute_path: >
        contains(groups, 'mastodon:Owner') && 'Admin' ||
        contains(groups, 'mastodon:Admin') && 'Admin' ||
        contains(groups, 'mastodon:Moderator') && 'Editor'
      role_attribute_strict: true  # Deny access if no role matches
```

## Access Denial

Users without a valid Mastodon role (Owner, Admin, or Moderator) will be **denied access** to both ArgoCD and Grafana:

- **ArgoCD**: The `policy.default: ""` configuration ensures users without a mapped group cannot log in
- **Grafana**: The `role_attribute_strict: true` setting combined with no fallback role ensures users without a mapped group cannot log in

## Dex Static Clients

Dex is configured with static clients for ArgoCD and Grafana:

**ArgoCD**:
- Client ID: `argocd`
- Redirect URIs:
  - `https://argocd.goingdark.social/auth/callback`
  - `http://localhost:8085/auth/callback` (for CLI)
- Requested scopes: `openid`, `profile`, `groups`

**Grafana**:
- Client ID: `grafana`
- Redirect URI: `https://monitoring.goingdark.social/login/generic_oauth`
- Requested scopes: `openid`, `profile`, `groups`

Client secrets are stored in Bitwarden and synced via External Secrets Operator.

## Troubleshooting

### User Cannot Log In

1. **Verify Mastodon role**: Check that the user has Owner, Admin, or Moderator role in Mastodon
   - Users without these roles will be denied access
2. **Check masto-claims-proxy logs**:
   ```bash
   kubectl logs -n dex -l app=masto-claims-proxy
   ```
   - Look for DEBUG messages showing the groups being returned
3. **Verify Dex configuration**:
   ```bash
   kubectl get configmap -n dex dex-config -o yaml
   ```
   - Ensure `groupsKey: groups` is set in the connector configuration
4. **Check ArgoCD/Grafana logs** for authentication errors

### Groups Not Being Passed

1. **Verify OIDC scopes**: Ensure the application requests the `groups` scope
2. **Check Dex token**: Decode the OIDC token to verify groups claim is present
3. **Verify masto-claims-proxy**: Ensure it's returning groups in the response

### Permission Denied After Login

1. **ArgoCD**: Check RBAC policy in `values.yaml` and verify group names match exactly
2. **Grafana**: Verify `role_attribute_path` expression in `helm-values.yaml`
3. **Check application logs** for RBAC evaluation messages

## Security Considerations

- **Client secrets** are stored in Bitwarden and never committed to the repository
- **TLS/HTTPS** is enforced for all authentication endpoints
- **Group-based access control** ensures users only get permissions based on their Mastodon role
- **No default access**: Users without a mapped role are explicitly denied access
- **Skip approval screen** is enabled for better UX, but can be disabled if required
- **Password database** is disabled in Dex (authentication only via Mastodon)

## Related Files

- Dex configuration: `kubernetes/apps/base-system/dex/helm-values.yaml`
- Masto-claims-proxy: `kubernetes/apps/base-system/dex/masto-claims-proxy.yaml`
- ArgoCD RBAC: `kubernetes/apps/argocd/values.yaml`
- Grafana OAuth: `kubernetes/apps/base-system/victoriametrics/helm-values.yaml`
- Dex secrets: `kubernetes/apps/base-system/dex/secrets.yaml` (ExternalSecret)
- ArgoCD OIDC secret: `kubernetes/apps/argocd/externalsecret-oidc.yaml`
- Grafana OIDC secret: `kubernetes/apps/base-system/victoriametrics/grafana-oidc-credentials.yaml`
