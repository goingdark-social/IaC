# AGENTS.md - Architectural Context & Maintainer Guidelines

> **SYSTEM PROMPT:** This file serves as the primary source of truth for AI Agents and Engineers working in this directory. It defines the architectural constraints, network patterns, and infrastructure rules for the Stalwart Mail Server deployment on Hetzner Cloud via Talos Linux. **Read this before making changes.**

---

## 1. High-Level Architecture: The "Split Ingress" Model

We utilize a **Hybrid Ingress Strategy** to optimize for cost, security, and protocol requirements. Unlike standard web deployments, mail servers have distinct L4 networking needs that conflict with standard L7 Ingress controllers.

### A. Web Traffic (HTTPS/443/80)
*   **Mechanism:** Cloudflare Tunnel (`cloudflared`) → Gateway API.
*   **Data Flow:** User `https://mail.peekoff.com` → Cloudflare Edge (WAF/DDoS) → `cloudflared` Replica (Inside Cluster) → Service (`ClusterIP` port 8080).
*   **Rationale:** Offloads TLS termination, hides the cluster's origin IP, provides free DDoS protection, and saves "listeners" on the Hetzner Load Balancer.
*   **Constraint:** **DO NOT** add port 443 or 80 to the Hetzner Load Balancer.

### B. Mail Traffic (TCP/SMTP/IMAP)
*   **Mechanism:** Hetzner Cloud Load Balancer (L4) via `hcloud-cloud-controller-manager` (HCCM).
*   **Data Flow:** User/Server → Hetzner LB (Public IP) → K8s Node (NodePort) → Pod.
*   **Rationale:** Mail protocols require a clean, dedicated Public IP with proper Reverse DNS (PTR) records. Cloudflare Tunnels are not suitable for raw SMTP/IMAP traffic.
*   **Component:** The K8s `Service` object triggers the HCCM to provision the physical infrastructure.

---

## 2. Infrastructure Constraints & The "5-Port Rule"

We utilize the **Hetzner LB11** instance type to maintain a low cost basis (~€6/mo).
*   **Hard Limit:** LB11 allows a maximum of **5 Services (Listeners)**.
*   **Consequence:** We cannot expose every supported mail port. We must strictly prioritize.

### Approved Port Configuration (Exactly 5)
1.  **25 (SMTP):** Essential for server-to-server delivery.
2.  **465 (SMTPS):** Client submission (Implicit TLS). *Preferred over 587.*
3.  **993 (IMAPS):** Client access (Implicit TLS). *Preferred over 143.*
4.  **587 (Submission):** Client submission (STARTTLS). Kept for legacy client compatibility.
5.  **4190 (ManageSieve):** For remote email filter management.

### Explicitly Excluded Ports
*   **110 (POP3) / 995 (POP3S):** Protocol deprecated for our use case.
*   **143 (IMAP):** Plaintext/STARTTLS IMAP is disabled in favor of 993 to save a listener slot.
*   **443 (HTTPS):** Handled via Cloudflare (See Section 1).

---

## 3. Infrastructure Management Boundaries

### OpenTofu (Terraform)
*   **Scope:** VPC, Subnets, Talos Control Plane, Worker Nodes, Firewalls, S3 Buckets.
*   **Deprecation Notice:** We have **REMOVED** `hcloud_floating_ip` resources. Do not re-add them.
*   **Constraint:** **Do NOT** create `hcloud_load_balancer` resources in OpenTofu for Kubernetes Services. The lifecycle of the LB must be managed by the cluster itself to ensure the configuration (Targets/Ports) stays in sync with the `Service` definition.

### Kubernetes Manifests (Flux/Kustomize)
*   **Scope:** `Service`, `StatefulSet`, `CiliumNetworkPolicy`, `ExternalSecrets`.
*   **Source of Truth:** `kubernetes/apps/platform/mail/base/resources/services/mail-lb.yaml` is the definitive source of truth for the Load Balancer configuration.

---

## 4. Configuration Reference: HCCM Annotations

The Hetzner Cloud Controller Manager (HCCM) relies on specific annotations on the `Service` object. Use these exact settings:

| Annotation | Value | Reason |
| :--- | :--- | :--- |
| `load-balancer.hetzner.cloud/location` | `"hel1"` | Must match the Node location for lowest latency. |
| `load-balancer.hetzner.cloud/type` | `"lb11"` | Enforces the cost tier. |
| `load-balancer.hetzner.cloud/algorithm-type` | `"least_connections"` | Vital for IMAP (long-lived connections). Prevents overloading one pod. |
| `load-balancer.hetzner.cloud/use-private-ip` | `"true"` | LB talks to Nodes via private VPC IP, reducing public traffic costs and attack surface. |
| `load-balancer.hetzner.cloud/disable-private-ingress` | `"true"` | **CRITICAL.** Required for Cilium/IPVS compatibility to prevent routing loops. |
| `load-balancer.hetzner.cloud/ipv4-rdns` | `"mail.peekoff.com"` | Automatically sets the PTR record on the Hetzner Public IP. |

**Additional Service Settings:**
*   `externalTrafficPolicy: Local`: Preserves the client's real source IP. Essential for RBL lookups and Spam filtering.

---

## 5. Network & Storage Specifics

### Cilium Configuration
*   We use `CiliumNetworkPolicy` (CRD) instead of standard `NetworkPolicy` for better identity awareness.
*   **Value Change:** `lbExternalClusterIP: true` is enabled in `cilium/values.yaml` to allow specific load balancer routing behaviors.
*   **Ingress Rules:**
    *   Allow `world` -> Ports 25, 465, 587, 993, 4190.
    *   Allow `ingress` (Gateway API Identity) -> Port 8080 (Web UI).

### Storage (StatefulSet)
*   **Pattern:** Use `volumeClaimTemplates` within the `StatefulSet` definition.
*   **Class:** `hcloud-volumes-encrypted-xfs`.
*   **Change Log:** We migrated away from standalone `PersistentVolumeClaim` files to ensure proper volume lifecycle management per replica.

### Object Storage (S3/R2)
*   **Endpoint Rule:** When configuring Cloudflare R2 for backups (CNPG/Barman), you **MUST** use the regional endpoint format:
    *   **Correct:** `https://<account_id>.eu.r2.cloudflarestorage.com`
    *   **Incorrect:** `https://<account_id>.r2.cloudflarestorage.com`
    *   *Reason:* The non-regional endpoint caused connection failures during backup verification.

---

## 6. Troubleshooting & Verification

### Scenario: "Pending" External IP on Service
1.  Check HCCM logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=hcloud-cloud-controller-manager`.
2.  Verify you haven't exceeded the 5-port limit on the Service.

### Scenario: Mail delivery fails (Spam/Bounce)
1.  Verify Reverse DNS: `dig -x <EXTERNAL-IP>`.
2.  Ensure the PTR record matches the `HELO` hostname configured in `config.toml`.
3.  Check `load-balancer.hetzner.cloud/ipv4-rdns` annotation.

### Scenario: Connection Timeouts
1.  Verify `load-balancer.hetzner.cloud/disable-private-ingress: "true"` is set. If missing, Cilium may drop packets due to routing loops on the private interface.
2.  Verify `externalTrafficPolicy: Local` is set and Pods are healthy on the target nodes.

### Scenario: Targets are Empty in Hetzner Console
1.  Check Pod Labels. The Service Selector must match the Pods perfectly.
2.  HCCM only adds nodes that are "Ready". Check `kubectl get nodes`.

---

## 7. Database Operations: CloudNativePG (CNPG)

### Restart Operations
When restarting CloudNativePG (CNPG) PostgreSQL clusters, **ONLY use native `kubectl cnpg` commands**. Do not use `kubectl rollout restart` or delete pods directly, as this can disrupt the cluster state and break replication.

**Correct Command:**
```bash
kubectl cnpg restart -n stalwart stalwart-postgresql
```

**Rationale:** The CNPG plugin handles graceful failover, ensures primary election, and maintains cluster health during restarts. Using standard kubectl commands bypasses these safety mechanisms.