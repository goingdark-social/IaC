# IaC Repository - Hetzner Cloud Kubernetes Infrastructure

Always reference these instructions first and fallback to search or bash commands only when you encounter unexpected information that does not match the info here.

## Working Effectively

### Bootstrap Dependencies
Install required tools in this exact order:
- **OpenTofu**: `wget https://github.com/opentofu/opentofu/releases/download/v1.8.8/tofu_1.8.8_linux_amd64.zip && unzip tofu_1.8.8_linux_amd64.zip && sudo mv tofu /usr/local/bin/ && rm tofu_1.8.8_linux_amd64.zip`
- **Terraform** (alternative): `wget https://releases.hashicorp.com/terraform/1.10.3/terraform_1.10.3_linux_amd64.zip && unzip terraform_1.10.3_linux_amd64.zip && sudo mv terraform /usr/local/bin/ && rm terraform_1.10.3_linux_amd64.zip`
- **Talosctl**: `wget https://github.com/siderolabs/talos/releases/download/v1.10.5/talosctl-linux-amd64 -O talosctl && chmod +x talosctl && sudo mv talosctl /usr/local/bin/`
- **kubectl**: Already available at `/usr/bin/kubectl`
- **kustomize**: Already available at `/usr/local/bin/kustomize`
- **helm**: Already available at `/usr/local/bin/helm`

### Infrastructure Validation and Deployment
- **Format and validate OpenTofu/Terraform configuration**:
  - `cd opentofu && tofu fmt -write=true -diff` -- takes <1 second
  - `cd opentofu && tofu validate` -- takes <1 second (requires init first)
  - **NEVER CANCEL**: `tofu init -upgrade` -- takes 2-5 minutes depending on network. Set timeout to 10+ minutes.
  - **NEVER CANCEL**: `tofu plan` -- takes 1-3 minutes with network access. Set timeout to 10+ minutes.
  - **NEVER CANCEL**: `tofu apply` -- takes 15-45 minutes for full cluster deployment. Set timeout to 60+ minutes.

### Kubernetes Manifest Validation
- **Basic YAML syntax validation**: `find . -name "*.yaml" -o -name "*.yml" | xargs -I {} python3 -c "import yaml; yaml.safe_load(open('{}', 'r')); print('Valid YAML: {}')"` -- takes <1 second
- **Kustomize validation** (offline components): 
  - `cd kubernetes/apps/default && kustomize build .` -- takes <1 second
  - `cd kubernetes/apps/base-system && kustomize build .` -- takes <1 second
- **Kustomize with Helm** (requires network):
  - **NEVER CANCEL**: `cd kubernetes/apps/argocd && kustomize build --enable-helm .` -- takes 2-10 minutes to download charts. Set timeout to 15+ minutes.
  - Network access required for helm chart repositories
- **Full kubernetes validation**: `cd kubernetes && kubectl kustomize --enable-helm .` -- requires network access and can take 5-15 minutes for all helm charts

### Manual Testing Scenarios
**CRITICAL**: After making infrastructure changes, always validate through these scenarios:

#### Infrastructure Deployment Test
1. **Prerequisites**: Must have Hetzner Cloud API token and all required environment variables
2. **Deploy cluster**: `cd opentofu && tofu init && tofu plan && tofu apply`
3. **Validate cluster access**: 
   - `export TALOSCONFIG=talosconfig`
   - `export KUBECONFIG=kubeconfig`
   - `talosctl get member` -- should show cluster nodes
   - `kubectl get nodes -o wide` -- should show nodes in Ready state
   - `kubectl get pods -A` -- should show all system pods running

#### GitOps Application Deployment Test
1. **Validate ArgoCD deployment**: `kubectl get pods -n argocd`
2. **Check ApplicationSets**: `kubectl get applicationsets -n argocd`
3. **Verify app synchronization**: `kubectl get applications -n argocd`

#### Network and Security Validation
1. **Check firewall rules**: Verify API access from configured source IPs
2. **Test Talos API**: `talosctl version --endpoints <node-ip>`
3. **Test Kubernetes API**: `kubectl version --short`

## Repository Structure and Navigation

### Key Directories
- **`opentofu/`**: Contains OpenTofu infrastructure configuration
  - `kubernetes.tofu`: Main cluster configuration using hcloud-k8s module
  - `.terraform.lock.hcl`: Provider version locks
- **`kubernetes/`**: GitOps manifests and ArgoCD configuration
  - `application-set.yaml`: ArgoCD ApplicationSet for infrastructure apps
  - `project.yaml`: ArgoCD project definition
  - `apps/`: Application manifests organized by namespace
    - `argocd/`: ArgoCD deployment with Helm charts
    - `base-system/`: Core system components (cert-manager, cilium, etc.)
    - `database/`: Database services (PostgreSQL)
    - `observability/`: Monitoring and observability stack
    - `default/`: Default namespace resources

### Important Files to Check After Changes
- **After modifying `opentofu/kubernetes.tofu`**: Always run `tofu fmt` and `tofu validate`
- **After modifying Kubernetes manifests**: Always run kustomize build to validate syntax
- **After adding new Helm charts**: Check chart version compatibility and test with `--enable-helm`
- **After modifying ArgoCD configs**: Validate ApplicationSet syntax and project permissions

## Common Commands Reference

### OpenTofu Operations
```bash
cd opentofu
tofu fmt -write=true -diff              # Format and show changes
tofu validate                           # Validate configuration
tofu init -upgrade                      # Initialize/update providers
tofu plan                              # Show planned changes
tofu apply                             # Apply infrastructure changes
tofu destroy                           # Destroy infrastructure (set cluster_delete_protection = false first)
```

### Kubernetes Operations
```bash
cd kubernetes
kustomize build apps/default/           # Build specific app manifests
kubectl kustomize --enable-helm .       # Build all manifests with Helm
kubectl apply --dry-run=client -f <file> # Validate individual manifest
kubectl diff -k .                       # Show differences (requires cluster)
```

### Cluster Management
```bash
export TALOSCONFIG=opentofu/talosconfig
export KUBECONFIG=opentofu/kubeconfig
talosctl get member                     # List cluster members
talosctl health                         # Check cluster health
kubectl get nodes -o wide               # List nodes with details
kubectl get pods -A                     # List all pods
```

## Build and Test Timing Expectations

### Fast Operations (<1 second)
- `tofu fmt` and `tofu validate` (after init)
- `kustomize build` for simple manifests
- YAML syntax validation
- `talosctl` and `kubectl` informational commands

### Medium Operations (1-15 minutes)
- `tofu init` -- 2-5 minutes (NEVER CANCEL, set timeout 10+ minutes)
- `tofu plan` -- 1-3 minutes (NEVER CANCEL, set timeout 10+ minutes)  
- Kustomize with Helm charts -- 2-10 minutes (NEVER CANCEL, set timeout 15+ minutes)
- Full kubernetes manifest validation -- 5-15 minutes (NEVER CANCEL, set timeout 20+ minutes)

### Long Operations (15+ minutes)
- **NEVER CANCEL**: `tofu apply` for full cluster -- 15-45 minutes (set timeout 60+ minutes)
- **NEVER CANCEL**: `tofu destroy` for cluster teardown -- 10-30 minutes (set timeout 45+ minutes)
- **NEVER CANCEL**: Initial ArgoCD synchronization -- 10-20 minutes (set timeout 30+ minutes)

## Network Dependencies and Limitations

### Commands That Require Internet Access
- `tofu init` -- downloads providers from registry.opentofu.org
- `tofu plan/apply` -- accesses Hetzner Cloud API
- `kustomize build --enable-helm` -- downloads Helm charts
- Cluster deployment -- requires Hetzner Cloud connectivity

### Commands That Work Offline
- `tofu fmt` and `tofu validate` (after init)
- Basic `kustomize build` without Helm charts
- YAML syntax validation
- Most `kubectl` operations against existing cluster

### Firewall and API Access Notes
- Talos and Kubernetes APIs are protected by Hetzner Cloud Firewall
- Default configuration allows access from current machine's IPv4/IPv6
- Manual firewall configuration may be required for CI/CD systems
- API tokens must be provided via environment variables or .tfvars files

## Validation Checklist

Before committing changes, always run:
- [ ] `cd opentofu && tofu fmt -write=true -diff`
- [ ] `cd opentofu && tofu validate` (requires prior init)
- [ ] `find . -name "*.yaml" -o -name "*.yml" | head -10 | xargs -I {} python3 -c "import yaml; yaml.safe_load(open('{}', 'r'))"`
- [ ] `cd kubernetes/apps/default && kustomize build .`
- [ ] Test at least one helm-based kustomize build if network available
- [ ] If infrastructure changes: Deploy and validate cluster access
- [ ] If GitOps changes: Verify ArgoCD can sync applications

## Troubleshooting Common Issues

### "Module not installed" Error
- Run `tofu init -upgrade` in the opentofu directory
- Check network connectivity to registry.opentofu.org

### "Helm chart repository cannot be reached"
- Verify internet connectivity
- Check if helm repositories are accessible
- For CI environments, consider chart vendoring

### "Provider plugins not installed"
- Delete `.terraform` directory and re-run `tofu init`
- Verify provider version constraints in `.terraform.lock.hcl`

### Cluster Access Issues
- Verify kubeconfig and talosconfig files exist in opentofu directory
- Check firewall rules allow API access from your IP
- Confirm cluster is fully deployed and nodes are ready

This IaC repository deploys production-ready Kubernetes infrastructure on Hetzner Cloud using Talos Linux, with GitOps-based application management through ArgoCD.