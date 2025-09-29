#!/bin/bash
set -euo pipefail

# Migration Preflight Check Script
# This script performs comprehensive validation before migration
# It is SAFE and NON-DESTRUCTIVE - no data or configuration changes are made

NAMESPACE="mastodon"
FAILED_CHECKS=0
TOTAL_CHECKS=0

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_section() {
    echo ""
    echo "=========================================="
    echo "  $1"
    echo "=========================================="
}

log_info() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
    ((FAILED_CHECKS++))
}

check_result() {
    ((TOTAL_CHECKS++))
    if [ $1 -eq 0 ]; then
        log_info "$2"
        return 0
    else
        log_error "$2"
        return 1
    fi
}

log_section "Migration Preflight Check Started"
echo "Timestamp: $(date)"
echo "Namespace: $NAMESPACE"
echo ""

# ==========================================
# 1. KUBERNETES CLUSTER ACCESS
# ==========================================
log_section "1. Verifying Kubernetes Access"

if kubectl cluster-info &>/dev/null; then
    check_result 0 "Kubernetes cluster accessible"
else
    check_result 1 "Cannot access Kubernetes cluster"
    exit 1
fi

if kubectl auth can-i get pods -n "$NAMESPACE" &>/dev/null; then
    check_result 0 "Namespace '$NAMESPACE' accessible"
else
    check_result 1 "Cannot access namespace '$NAMESPACE'"
    exit 1
fi

# ==========================================
# 2. ZALANDO POSTGRESQL STATUS
# ==========================================
log_section "2. Checking Zalando PostgreSQL Status"

# Check Zalando operator
if kubectl get deployment postgres-operator -n postgres-operator &>/dev/null; then
    OPERATOR_READY=$(kubectl get deployment postgres-operator -n postgres-operator -o jsonpath='{.status.readyReplicas}')
    if [ "$OPERATOR_READY" -ge 1 ]; then
        check_result 0 "Zalando operator running (ready: $OPERATOR_READY)"
    else
        check_result 1 "Zalando operator not ready (ready: $OPERATOR_READY)"
    fi
else
    check_result 1 "Zalando operator not found"
fi

# Check Zalando PostgreSQL cluster
if kubectl get postgresql mastodon-postgresql -n "$NAMESPACE" &>/dev/null; then
    ZALANDO_STATUS=$(kubectl get postgresql mastodon-postgresql -n "$NAMESPACE" -o jsonpath='{.status.PostgresClusterStatus}')
    if [ "$ZALANDO_STATUS" = "Running" ]; then
        check_result 0 "Zalando PostgreSQL cluster status: $ZALANDO_STATUS"
    else
        check_result 1 "Zalando PostgreSQL cluster status: $ZALANDO_STATUS (expected: Running)"
    fi
else
    check_result 1 "Zalando PostgreSQL cluster not found"
fi

# Check Zalando pods
ZALANDO_PODS=$(kubectl get pods -n "$NAMESPACE" -l application=spilo,cluster-name=mastodon-postgresql --no-headers 2>/dev/null | wc -l)
ZALANDO_READY=$(kubectl get pods -n "$NAMESPACE" -l application=spilo,cluster-name=mastodon-postgresql -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | grep -o true | wc -l)

if [ "$ZALANDO_PODS" -ge 2 ] && [ "$ZALANDO_READY" -ge 2 ]; then
    check_result 0 "Zalando PostgreSQL pods: $ZALANDO_READY/$ZALANDO_PODS ready"
else
    check_result 1 "Zalando PostgreSQL pods: $ZALANDO_READY/$ZALANDO_PODS ready (expected: 2/2)"
fi

# Check Zalando pooler
ZALANDO_POOLER_PODS=$(kubectl get pods -n "$NAMESPACE" -l application=db-connection-pooler --no-headers 2>/dev/null | wc -l)
ZALANDO_POOLER_READY=$(kubectl get pods -n "$NAMESPACE" -l application=db-connection-pooler -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | grep -o true | wc -l)

if [ "$ZALANDO_POOLER_PODS" -ge 2 ] && [ "$ZALANDO_POOLER_READY" -ge 2 ]; then
    check_result 0 "Zalando pooler pods: $ZALANDO_POOLER_READY/$ZALANDO_POOLER_PODS ready"
else
    check_result 1 "Zalando pooler pods: $ZALANDO_POOLER_READY/$ZALANDO_POOLER_PODS ready"
fi

# Check Zalando services
for service in mastodon-postgresql-pooler mastodon-postgresql-repl; do
    if kubectl get svc "$service" -n "$NAMESPACE" &>/dev/null; then
        check_result 0 "Service '$service' exists"
    else
        check_result 1 "Service '$service' not found"
    fi
done

# ==========================================
# 3. CNPG (CloudNative-PG) STATUS
# ==========================================
log_section "3. Checking CloudNative-PG Status"

# Check CNPG operator
if kubectl get deployment cnpg-controller-manager -n cnpg-system &>/dev/null; then
    CNPG_OPERATOR_READY=$(kubectl get deployment cnpg-controller-manager -n cnpg-system -o jsonpath='{.status.readyReplicas}')
    if [ "$CNPG_OPERATOR_READY" -ge 1 ]; then
        check_result 0 "CNPG operator running (ready: $CNPG_OPERATOR_READY)"
    else
        check_result 1 "CNPG operator not ready (ready: $CNPG_OPERATOR_READY)"
    fi
else
    check_result 1 "CNPG operator not found"
fi

# Check CNPG cluster
if kubectl get cluster database -n "$NAMESPACE" &>/dev/null; then
    CNPG_INSTANCES=$(kubectl get cluster database -n "$NAMESPACE" -o jsonpath='{.status.instances}')
    CNPG_READY=$(kubectl get cluster database -n "$NAMESPACE" -o jsonpath='{.status.readyInstances}')
    if [ "$CNPG_READY" -ge 2 ]; then
        check_result 0 "CNPG cluster instances: $CNPG_READY/$CNPG_INSTANCES ready"
    else
        check_result 1 "CNPG cluster instances: $CNPG_READY/$CNPG_INSTANCES ready (expected: 2/2)"
    fi
else
    check_result 1 "CNPG cluster 'database' not found"
fi

# Check CNPG pods
CNPG_PODS=$(kubectl get pods -n "$NAMESPACE" -l cnpg.io/cluster=database --no-headers 2>/dev/null | wc -l)
CNPG_READY_PODS=$(kubectl get pods -n "$NAMESPACE" -l cnpg.io/cluster=database -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | grep -o true | wc -l)

if [ "$CNPG_PODS" -ge 2 ] && [ "$CNPG_READY_PODS" -ge 2 ]; then
    check_result 0 "CNPG pods: $CNPG_READY_PODS/$CNPG_PODS ready"
else
    check_result 1 "CNPG pods: $CNPG_READY_PODS/$CNPG_PODS ready (expected: 2/2)"
fi

# Check CNPG poolers
CNPG_POOLER_RW=$(kubectl get pods -n "$NAMESPACE" -l cnpg.io/poolerName=database-pooler-rw --no-headers 2>/dev/null | wc -l)
CNPG_POOLER_RO=$(kubectl get pods -n "$NAMESPACE" -l cnpg.io/poolerName=database-pooler-ro --no-headers 2>/dev/null | wc -l)

if [ "$CNPG_POOLER_RW" -ge 1 ]; then
    check_result 0 "CNPG read-write pooler pods: $CNPG_POOLER_RW"
else
    check_result 1 "CNPG read-write pooler pods: $CNPG_POOLER_RW (expected: >=1)"
fi

if [ "$CNPG_POOLER_RO" -ge 1 ]; then
    check_result 0 "CNPG read-only pooler pods: $CNPG_POOLER_RO"
else
    check_result 1 "CNPG read-only pooler pods: $CNPG_POOLER_RO (expected: >=1)"
fi

# Check CNPG services
for service in database-pooler-rw database-pooler-ro database-rw database-ro database-r; do
    if kubectl get svc "$service" -n "$NAMESPACE" &>/dev/null; then
        check_result 0 "Service '$service' exists"
    else
        check_result 1 "Service '$service' not found"
    fi
done

# ==========================================
# 4. SECRETS AND CERTIFICATES
# ==========================================
log_section "4. Checking Secrets and Certificates"

# Zalando secrets
for secret in mastodon-db-url mastodon-postgresql-ca mastodon-postgresql-server; do
    if kubectl get secret "$secret" -n "$NAMESPACE" &>/dev/null; then
        check_result 0 "Secret '$secret' exists"
    else
        check_result 1 "Secret '$secret' not found"
    fi
done

# CNPG secrets
for secret in database-app database-ca database-server database-replication; do
    if kubectl get secret "$secret" -n "$NAMESPACE" &>/dev/null; then
        check_result 0 "Secret '$secret' exists"
    else
        check_result 1 "Secret '$secret' not found"
    fi
done

# ==========================================
# 5. MASTODON APPLICATION STATUS
# ==========================================
log_section "5. Checking Mastodon Application Status"

DEPLOYMENTS=("mastodon-web" "mastodon-sidekiq-default" "mastodon-sidekiq-federation" "mastodon-sidekiq-background" "mastodon-streaming")

for deployment in "${DEPLOYMENTS[@]}"; do
    if kubectl get deployment "$deployment" -n "$NAMESPACE" &>/dev/null; then
        DESIRED=$(kubectl get deployment "$deployment" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
        READY=$(kubectl get deployment "$deployment" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}')
        READY=${READY:-0}

        if [ "$READY" -ge 1 ]; then
            check_result 0 "Deployment '$deployment': $READY/$DESIRED ready"
        else
            check_result 1 "Deployment '$deployment': $READY/$DESIRED ready (no healthy pods)"
        fi
    else
        check_result 1 "Deployment '$deployment' not found"
    fi
done

# Check StatefulSets
STATEFULSETS=("mastodon-redis-master" "elasticsearch-master")

for sts in "${STATEFULSETS[@]}"; do
    if kubectl get statefulset "$sts" -n "$NAMESPACE" &>/dev/null; then
        DESIRED=$(kubectl get statefulset "$sts" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
        READY=$(kubectl get statefulset "$sts" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}')
        READY=${READY:-0}

        if [ "$READY" -eq "$DESIRED" ]; then
            check_result 0 "StatefulSet '$sts': $READY/$DESIRED ready"
        else
            check_result 1 "StatefulSet '$sts': $READY/$DESIRED ready"
        fi
    else
        check_result 1 "StatefulSet '$sts' not found"
    fi
done

# ==========================================
# 6. DATABASE CONNECTIVITY
# ==========================================
log_section "6. Testing Database Connectivity"

# Test Zalando connectivity using a test pod
echo "Testing Zalando PostgreSQL connectivity..."
ZALANDO_TEST=$(kubectl run zalando-test-${RANDOM} \
    --namespace="$NAMESPACE" \
    --image=postgres:17.2 \
    --restart=Never \
    --rm -i --quiet \
    --overrides='
{
  "spec": {
    "containers": [{
      "name": "test",
      "image": "postgres:17.2",
      "command": ["pg_isready"],
      "args": ["-h", "mastodon-postgresql-pooler", "-p", "5432"],
      "env": [{
        "name": "PGSSLMODE",
        "value": "require"
      }]
    }]
  }
}' 2>&1 || true)

if echo "$ZALANDO_TEST" | grep -q "accepting connections"; then
    check_result 0 "Zalando PostgreSQL accepting connections"
else
    check_result 1 "Zalando PostgreSQL not accepting connections"
fi

# Test CNPG connectivity
echo "Testing CNPG read-write endpoint..."
CNPG_RW_TEST=$(kubectl run cnpg-rw-test-${RANDOM} \
    --namespace="$NAMESPACE" \
    --image=postgres:17.2 \
    --restart=Never \
    --rm -i --quiet \
    --overrides='
{
  "spec": {
    "containers": [{
      "name": "test",
      "image": "postgres:17.2",
      "command": ["pg_isready"],
      "args": ["-h", "database-pooler-rw", "-p", "5432"],
      "env": [{
        "name": "PGSSLMODE",
        "value": "require"
      }]
    }]
  }
}' 2>&1 || true)

if echo "$CNPG_RW_TEST" | grep -q "accepting connections"; then
    check_result 0 "CNPG read-write pooler accepting connections"
else
    check_result 1 "CNPG read-write pooler not accepting connections"
fi

echo "Testing CNPG read-only endpoint..."
CNPG_RO_TEST=$(kubectl run cnpg-ro-test-${RANDOM} \
    --namespace="$NAMESPACE" \
    --image=postgres:17.2 \
    --restart=Never \
    --rm -i --quiet \
    --overrides='
{
  "spec": {
    "containers": [{
      "name": "test",
      "image": "postgres:17.2",
      "command": ["pg_isready"],
      "args": ["-h", "database-pooler-ro", "-p", "5432"],
      "env": [{
        "name": "PGSSLMODE",
        "value": "require"
      }]
    }]
  }
}' 2>&1 || true)

if echo "$CNPG_RO_TEST" | grep -q "accepting connections"; then
    check_result 0 "CNPG read-only pooler accepting connections"
else
    check_result 1 "CNPG read-only pooler not accepting connections"
fi

# ==========================================
# 7. STORAGE AND RESOURCES
# ==========================================
log_section "7. Checking Storage and Resources"

# Check node resources
echo "Checking node resources..."
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
log_info "Cluster has $NODE_COUNT nodes"

# Check available storage
CNPG_PVC_COUNT=$(kubectl get pvc -n "$NAMESPACE" -l cnpg.io/cluster=database --no-headers 2>/dev/null | wc -l)
if [ "$CNPG_PVC_COUNT" -ge 2 ]; then
    check_result 0 "CNPG PVCs: $CNPG_PVC_COUNT (expected: >=2)"
else
    check_result 1 "CNPG PVCs: $CNPG_PVC_COUNT (expected: >=2)"
fi

# Check for sufficient disk space estimate
MIGRATION_SIZE_NEEDED="20Gi"
log_warn "Migration will need approximately $MIGRATION_SIZE_NEEDED temporary storage"
log_warn "Ensure nodes have sufficient disk space for backup file"

# ==========================================
# 8. MIGRATION JOB FILES
# ==========================================
log_section "8. Verifying Migration Job Files"

JOB_FILES=(
    "zalando-backup-job.yaml"
    "cnpg-prepare-job.yaml"
    "zalando-to-cnpg-migration.yaml"
    "cnpg-validation-job.yaml"
)

for job_file in "${JOB_FILES[@]}"; do
    if [ -f "$job_file" ]; then
        check_result 0 "Migration job file '$job_file' exists"
    else
        check_result 1 "Migration job file '$job_file' not found"
        log_error "  Expected location: $(pwd)/$job_file"
    fi
done

# ==========================================
# 9. BACKUP AND DISASTER RECOVERY
# ==========================================
log_section "9. Checking Backup Configuration"

# Check if Zalando has recent backups
if kubectl get postgresql mastodon-postgresql -n "$NAMESPACE" -o jsonpath='{.spec.enableLogicalBackup}' | grep -q "true"; then
    log_warn "Zalando logical backups enabled - ensure recent backup exists"
else
    log_warn "Zalando logical backups disabled"
fi

# Check CNPG backup configuration
if kubectl get cluster database -n "$NAMESPACE" -o jsonpath='{.spec.backup}' &>/dev/null; then
    check_result 0 "CNPG backup configuration exists"
else
    log_warn "CNPG backup configuration not found (optional but recommended)"
fi

# ==========================================
# 10. SAFETY CHECKS
# ==========================================
log_section "10. Final Safety Checks"

# Check for running jobs that might interfere
RUNNING_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o jsonpath='{.items[?(@.status.active>0)].metadata.name}' | wc -w)
if [ "$RUNNING_JOBS" -eq 0 ]; then
    check_result 0 "No active jobs running"
else
    ACTIVE_JOB_NAMES=$(kubectl get jobs -n "$NAMESPACE" -o jsonpath='{.items[?(@.status.active>0)].metadata.name}')
    check_result 1 "Active jobs running: $ACTIVE_JOB_NAMES"
    log_warn "  Consider waiting for these jobs to complete"
fi

# Check for recent pod restarts (instability indicator)
echo "Checking for recent pod restarts..."
RESTART_COUNT=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' | tr ' ' '\n' | awk '{s+=$1} END {print s}')
if [ "$RESTART_COUNT" -lt 10 ]; then
    check_result 0 "Total pod restarts: $RESTART_COUNT (acceptable)"
else
    log_warn "Total pod restarts: $RESTART_COUNT (high - investigate before migration)"
fi

# Check for pending pods
PENDING_PODS=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
if [ "$PENDING_PODS" -eq 0 ]; then
    check_result 0 "No pending pods"
else
    check_result 1 "Pending pods detected: $PENDING_PODS"
fi

# ==========================================
# SUMMARY
# ==========================================
log_section "Preflight Check Summary"

echo ""
echo "Total checks performed: $TOTAL_CHECKS"
echo "Failed checks: $FAILED_CHECKS"
echo ""

if [ "$FAILED_CHECKS" -eq 0 ]; then
    log_info "ALL CHECKS PASSED - System ready for migration"
    echo ""
    echo "Next steps:"
    echo "  1. Review the migration guide: MIGRATION_GUIDE.md"
    echo "  2. Schedule maintenance window"
    echo "  3. Run: kubectl apply -f zalando-backup-job.yaml"
    echo "  4. Run: kubectl create job zalando-backup-test --from=job/zalando-backup-job -n mastodon"
    echo ""
    exit 0
else
    log_error "MIGRATION NOT READY - $FAILED_CHECKS checks failed"
    echo ""
    echo "Please fix the failed checks before proceeding with migration."
    echo "Review the errors above and ensure all systems are healthy."
    echo ""
    exit 1
fi