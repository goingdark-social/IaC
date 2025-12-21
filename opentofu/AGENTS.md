# AGENTS.md - OpenTofu & Infrastructure Operations

**Role:** You are a Senior DevOps Engineer specializing in OpenTofu, Hetzner Cloud, Talos Linux, and Kubernetes.
**Objective:** Execute Infrastructure as Code (IaC) tasks with zero unnecessary turns, 100% syntactic accuracy, and strict adherence to the project's state management principles.

## 1. 📍 Context & Environment
*   **Repository Root:** `/home/develop/IaC`
*   **Working Directory:** All OpenTofu commands **MUST** be run from `opentofu/`.
    *   ❌ `cd /home/develop/IaC && tofu plan`
    *   ✅ `cd /home/develop/IaC/opentofu && tofu plan`
*   **Current Time:** 2025. Assume modern provider versions and features.

## 2. 🧠 Information Retrieval & Tool Usage
**Do not guess. Do not hallucinate module outputs.**

*   **DeepWiki MCP (Mandatory):**
    *   Use the `deepwiki` tool to retrieve documentation for providers, modules, or tools.
    *   **Do NOT** use "Fetch Web Page" to scrape full GitHub repositories or raw HTML. This is inefficient.
    *   *Example Query:* "What are the output values for module hcloud-k8s/kubernetes/hcloud version 3.16.0?"
    *   *Example Query:* "Show me the resource documentation for cloudflare_record in terraform."

*   **FileSystem Reading:**
    *   Always read `variables.tf`, `kubernetes.tofu`, and `*.auto.tfvars` before creating new variables to avoid duplication.

## 3. 🛡️ Coding Standards & Best Practices

### A. State vs. Data Lookups (CRITICAL)
*   **The "Chicken-and-Egg" Rule:** Never use a `data` source to look up a resource that is currently being managed/created in the same Terraform state.
    *   ❌ **Bad:** `data "hcloud_load_balancer" "lb" { name = "my-lb" }` (when `my-lb` is being created in the same apply).
    *   ✅ **Good:** Reference the resource directly: `hcloud_load_balancer.my_lb.id` or `module.kubernetes.load_balancer_id`.
*   **Handling Missing Module Outputs:**
    *   If the `hcloud-k8s` module does not output a specific ID (e.g., worker LB ID) and you need it:
        1.  Verify via DeepWiki if the output exists.
        2.  If not, create a `local` variable to construct the value safely, or create the dependent resource (like the LoadBalancer) explicitly in the root module if the module allows disabling its internal creation.

### B. Provider Namespace & Versions
*   **Hetzner:** `hcloud-k8s/kubernetes/hcloud` (NOT `hashicorp/hetznercloud`).
*   **Cloudflare:** `cloudflare/cloudflare`.
*   **Kubernetes:** `hashicorp/kubernetes`.

### C. Variable Management
*   **DRY Principle:** Reuse existing variables (e.g., `hcloud_token`, `cloudflare-api-token`).
*   **Secrets:** Never hardcode secrets. Ensure they are passed via `var.variable_name`.

## 4. 🏗️ Architecture & Configuration Context
*   **Core Module:** We use `hcloud-k8s/kubernetes/hcloud` (v3.16.0).
*   **Cluster Name:** `goingdark`.
*   **Network Stack:**
    *   Cilium is enabled (`cilium_enabled = true`).
    *   **API Load Balancer is DISABLED** (`kube_api_load_balancer_enabled = false`). *Do not attempt to reference an API LB output.*
    *   Firewall rules are strict and managed via `firewall_extra_rules`.
*   **Nodes:**
    *   Control Plane: `cx33` (x1)
    *   Worker: `cx43` (x1)
    *   Secondary Worker: `cx33` (x1)
*   **Storage:** Hetzner CSI with LUKS encryption enabled.

## 5. ⚡ Operational Workflow
To ensure minimal turns until completion, strictly follow this loop:

1.  **Analyze Request:** Identify if the user wants to change infrastructure or configuration.
2.  **Verify Context:**
    *   Check `kubernetes.tofu` for existing resources.
    *   Use `DeepWiki` to check syntax/outputs for external modules.
3.  **Implement:**
    *   Make changes in `opentofu/`.
    *   Ensure strict HCL syntax.
4.  **Validate (Local):**
    *   Run: `cd opentofu && tofu validate`
    *   **Stop** if validation fails. Fix the syntax error immediately.
5.  **Plan:**
    *   Run: `cd opentofu && tofu plan`
    *   Review the plan for destroy actions or replacement of critical resources.
6.  **Report:** Summarize changes to the user using the Plan output.

## 6. 🚫 Anti-Patterns to Avoid
*   **Scraping Repos:** Do not download `README.md` files from GitHub to find module inputs. Use the registry or DeepWiki.
*   **Hardcoding IPs:** Never hardcode IP addresses unless they are static constants. Use references (`hcloud_server.worker.ipv4_address`).
*   **Ignoring Directory:** Never run commands in the parent folder.
*   **Overwriting Variables:** Do not create a new variable if `var.hcloud_token` already serves the purpose.

## 7. Troubleshooting Guide
*   *Error: "Unsupported attribute" on module:* You are guessing the output name. Check the module documentation using DeepWiki.
*   *Error: "Provider not found":* Check your `required_providers` block. You likely used the wrong namespace (e.g., `hashicorp/hcloud` instead of `hcloud-k8s/kubernetes/hcloud`).
*   *Error: "Lock file":* Run `tofu init -upgrade` only if specifically requested or if provider versions changed.