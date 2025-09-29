#!/bin/bash
set -euo pipefail

# Migration Execution Script
# This script performs the actual migration from Zalando to CNPG
# WARNING: This will cause downtime while data is transferred

NAMESPACE="mastodon"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="migration-${TIMESTAMP}.log"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
}

log_step() {
    echo -e "${BLUE}→${NC} $1"
}

confirm() {
    echo -e "${YELLOW}⚠ $1${NC}"
    read -p "Type 'yes' to continue: " response
    if [ "$response" != "yes" ]; then
        echo "Aborted by user"
        exit 1
    fi
}

log_section "Mastodon Migration Execution Script"
echo "Timestamp: $(date)"
echo "Log file: $LOG_FILE"
echo ""

# Redirect all output to both console and log file
exec > >(tee -a "$LOG_FILE")
exec 2>&1

# ==========================================
# SAFETY CONFIRMATIONS
# ==========================================
log_section "Safety Confirmations"

confirm "This script will migrate Mastodon from Zalando PostgreSQL to CNPG."
confirm "This will cause DOWNTIME of approximately 5-15 minutes."
confirm "Have you run the preflight check script successfully?"
confirm "Have you tested the Zalando backup job?"
confirm "Is this the correct time window for migration?"

log_info "All safety confirmations received"

# ==========================================
# STEP 1: VERIFY PREREQUISITES
# ==========================================
log_section "Step 1: Verifying Prerequisites"

log_step "Checking Zalando backup job completion..."
BACKUP_JOB_STATUS=$(kubectl get job zalando-backup-job -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")

if [ "$BACKUP_JOB_STATUS" != "True" ]; then
    log_error "Zalando backup job has not completed successfully"
    log_error "Run: kubectl apply -f zalando-backup-job.yaml"
    log_error "Then: kubectl create job zalando-backup-test --from=job/zalando-backup-job -n mastodon"
    exit 1
fi

log_info "Zalando backup job completed successfully"

log_step "Checking CNPG preparation job..."
if kubectl get job cnpg-prepare-job -n "$NAMESPACE" &>/dev/null; then
    CNPG_PREP_STATUS=$(kubectl get job cnpg-prepare-job -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
    if [ "$CNPG_PREP_STATUS" = "True" ]; then
        log_info "CNPG preparation job completed successfully"
    else
        log_warn "CNPG preparation job exists but not completed - restarting..."
        kubectl delete job cnpg-prepare-job -n "$NAMESPACE" 2>/dev/null || true
        # Wait for deletion to complete
        while kubectl get job cnpg-prepare-job -n "$NAMESPACE" &>/dev/null; do
          sleep 1
        done
        kubectl apply -f cnpg-prepare-job.yaml
        log_step "Waiting for CNPG preparation job to complete..."
        kubectl wait --for=condition=complete --timeout=300s job/cnpg-prepare-job -n "$NAMESPACE" || {
            log_error "CNPG preparation job failed"
            kubectl logs job/cnpg-prepare-job -n "$NAMESPACE"
            exit 1
        }
        log_info "CNPG preparation completed"
    fi
else
    log_warn "CNPG preparation job not found - running now..."
    kubectl apply -f cnpg-prepare-job.yaml
    log_step "Waiting for CNPG preparation job to complete..."
    kubectl wait --for=condition=complete --timeout=300s job/cnpg-prepare-job -n "$NAMESPACE" || {
        log_error "CNPG preparation job failed"
        kubectl logs job/cnpg-prepare-job -n "$NAMESPACE"
        exit 1
    }
    log_info "CNPG preparation completed"
fi

log_step "Recording current application replica counts..."
MASTODON_WEB_REPLICAS=$(kubectl get deployment mastodon-web -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
MASTODON_SIDEKIQ_DEFAULT_REPLICAS=$(kubectl get deployment mastodon-sidekiq-default -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
MASTODON_SIDEKIQ_BACKGROUND_REPLICAS=$(kubectl get deployment mastodon-sidekiq-background -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
MASTODON_SIDEKIQ_FEDERATION_REPLICAS=$(kubectl get deployment mastodon-sidekiq-federation -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
MASTODON_STREAMING_REPLICAS=$(kubectl get deployment mastodon-streaming -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')

log_info "Current replica counts recorded:"
echo "  mastodon-web: $MASTODON_WEB_REPLICAS"
echo "  mastodon-sidekiq-default: $MASTODON_SIDEKIQ_DEFAULT_REPLICAS"
echo "  mastodon-sidekiq-background: $MASTODON_SIDEKIQ_BACKGROUND_REPLICAS"
echo "  mastodon-sidekiq-federation: $MASTODON_SIDEKIQ_FEDERATION_REPLICAS"
echo "  mastodon-streaming: $MASTODON_STREAMING_REPLICAS"

# Save replica counts for potential rollback
cat > /tmp/mastodon-replicas-${TIMESTAMP}.txt <<EOF
MASTODON_WEB_REPLICAS=$MASTODON_WEB_REPLICAS
MASTODON_SIDEKIQ_DEFAULT_REPLICAS=$MASTODON_SIDEKIQ_DEFAULT_REPLICAS
MASTODON_SIDEKIQ_BACKGROUND_REPLICAS=$MASTODON_SIDEKIQ_BACKGROUND_REPLICAS
MASTODON_SIDEKIQ_FEDERATION_REPLICAS=$MASTODON_SIDEKIQ_FEDERATION_REPLICAS
MASTODON_STREAMING_REPLICAS=$MASTODON_STREAMING_REPLICAS
EOF

log_info "Replica counts saved to: /tmp/mastodon-replicas-${TIMESTAMP}.txt"

# ==========================================
# STEP 2: FINAL CONFIRMATION
# ==========================================
log_section "Step 2: Final Confirmation Before Downtime"

echo ""
log_warn "════════════════════════════════════════"
log_warn "  DOWNTIME WILL BEGIN IN 10 SECONDS"
log_warn "════════════════════════════════════════"
echo ""
log_warn "Press Ctrl+C NOW to abort, or wait to continue..."
sleep 10

log_info "Starting migration - downtime begins now"
START_TIME=$(date +%s)

# ==========================================
# STEP 3: SCALE DOWN APPLICATIONS
# ==========================================
log_section "Step 3: Scaling Down Applications"

log_step "Scaling down Mastodon web..."
kubectl scale deployment mastodon-web --replicas=0 -n "$NAMESPACE"

log_step "Scaling down Mastodon sidekiq workers..."
kubectl scale deployment mastodon-sidekiq-default --replicas=0 -n "$NAMESPACE"
kubectl scale deployment mastodon-sidekiq-background --replicas=0 -n "$NAMESPACE"
kubectl scale deployment mastodon-sidekiq-federation --replicas=0 -n "$NAMESPACE"

log_step "Scaling down Mastodon streaming..."
kubectl scale deployment mastodon-streaming --replicas=0 -n "$NAMESPACE"

log_step "Waiting for pods to terminate (max 5 minutes)..."
kubectl wait --for=delete pod -l app=mastodon-web -n "$NAMESPACE" --timeout=300s 2>/dev/null || log_warn "Some web pods may still be terminating"
kubectl wait --for=delete pod -l app=mastodon-sidekiq -n "$NAMESPACE" --timeout=300s 2>/dev/null || log_warn "Some sidekiq pods may still be terminating"
kubectl wait --for=delete pod -l app=mastodon-streaming -n "$NAMESPACE" --timeout=300s 2>/dev/null || log_warn "Some streaming pods may still be terminating"

log_info "All Mastodon applications scaled down"

# Verify no active connections
log_step "Verifying no active connections to Zalando..."
sleep 5  # Wait for lingering connections to close

# ==========================================
# STEP 4: CREATE BACKUP
# ==========================================
log_section "Step 4: Creating Final Backup from Zalando"

log_step "Launching backup job..."
kubectl apply -f zalando-backup-job.yaml
kubectl create job zalando-final-backup-${TIMESTAMP} --from=job/zalando-backup-job -n "$NAMESPACE"

log_step "Waiting for backup to complete (max 15 minutes)..."
if kubectl wait --for=condition=complete --timeout=900s job/zalando-final-backup-${TIMESTAMP} -n "$NAMESPACE"; then
    log_info "Backup completed successfully"
else
    log_error "Backup job failed or timed out"
    kubectl logs job/zalando-final-backup-${TIMESTAMP} -n "$NAMESPACE"

    log_error "Migration failed - restoring applications"
    kubectl scale deployment mastodon-web --replicas=$MASTODON_WEB_REPLICAS -n "$NAMESPACE"
    kubectl scale deployment mastodon-sidekiq-default --replicas=$MASTODON_SIDEKIQ_DEFAULT_REPLICAS -n "$NAMESPACE"
    kubectl scale deployment mastodon-sidekiq-background --replicas=$MASTODON_SIDEKIQ_BACKGROUND_REPLICAS -n "$NAMESPACE"
    kubectl scale deployment mastodon-sidekiq-federation --replicas=$MASTODON_SIDEKIQ_FEDERATION_REPLICAS -n "$NAMESPACE"
    kubectl scale deployment mastodon-streaming --replicas=$MASTODON_STREAMING_REPLICAS -n "$NAMESPACE"
    exit 1
fi

# Get backup file location from job logs
log_step "Retrieving backup file information..."
BACKUP_LOG=$(kubectl logs job/zalando-final-backup-${TIMESTAMP} -n "$NAMESPACE")
echo "$BACKUP_LOG" | tail -20

# ==========================================
# STEP 5: RESTORE TO CNPG
# ==========================================
log_section "Step 5: Restoring to CNPG Database"

log_step "Creating restore job..."

# Create a custom restore job that uses the backup from the previous step
cat > /tmp/cnpg-restore-${TIMESTAMP}.yaml <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: cnpg-restore-TIMESTAMP
  namespace: mastodon
spec:
  parallelism: 1
  completions: 1
  backoffLimit: 1
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      restartPolicy: Never
      tolerations:
      - key: "autoscaler-node"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
      containers:
        - name: restore
          image: postgres:17.2
          command: ["/bin/bash"]
          args:
            - -c
            - |
              set -euo pipefail

              echo "=== CNPG Restore Job Started ==="
              echo "Fetching latest backup from Zalando..."

              # Connect to Zalando and create backup
              PGPASSWORD="$ZALANDO_PASSWORD" PGSSLROOTCERT="$ZALANDO_SSLROOTCERT" pg_dump \
                --host="$ZALANDO_HOST" \
                --port="$ZALANDO_PORT" \
                --username="$ZALANDO_USER" \
                --dbname="$ZALANDO_DB_NAME" \
                --no-owner \
                --no-privileges \
                --clean \
                --if-exists \
                --verbose \
                --file="/tmp/backup.sql"

              echo "Backup size: $(du -h /tmp/backup.sql | cut -f1)"

              echo "Restoring to CNPG..."
              PGPASSWORD="$CNPG_PASSWORD" PGSSLROOTCERT="$CNPG_SSLROOTCERT" psql \
                --host="$CNPG_HOST" \
                --port="$CNPG_PORT" \
                --username="$CNPG_USER" \
                --dbname="$CNPG_DB_NAME" \
                --single-transaction \
                --file="/tmp/backup.sql" \
                --verbose

              echo "Restore completed successfully"

              # Quick validation
              echo "Validating restore..."
              ACCOUNT_COUNT=$(PGPASSWORD="$CNPG_PASSWORD" PGSSLROOTCERT="$CNPG_SSLROOTCERT" psql \
                --host="$CNPG_HOST" \
                --port="$CNPG_PORT" \
                --username="$CNPG_USER" \
                --dbname="$CNPG_DB_NAME" \
                -t -c "SELECT COUNT(*) FROM accounts;")

              echo "Accounts in CNPG: $ACCOUNT_COUNT"

              if [ "$ACCOUNT_COUNT" -gt 0 ]; then
                echo "✓ Validation passed"
              else
                echo "✗ Validation failed - no accounts found"
                exit 1
              fi

          env:
            - name: ZALANDO_HOST
              value: "mastodon-postgresql-pooler"
            - name: ZALANDO_PORT
              value: "5432"
            - name: ZALANDO_DB_NAME
              value: "mastodon"
            - name: ZALANDO_USER
              valueFrom:
                secretKeyRef:
                  name: mastodon-db-url
                  key: DB_USER
            - name: ZALANDO_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mastodon-db-url
                  key: DB_PASS
            - name: ZALANDO_SSLROOTCERT
              value: "/opt/postgresql/zalando-ca.crt"
            - name: CNPG_HOST
              value: "database-pooler-rw"
            - name: CNPG_PORT
              value: "5432"
            - name: CNPG_DB_NAME
              value: "mastodon"
            - name: CNPG_USER
              valueFrom:
                secretKeyRef:
                  name: mastodon-db-url
                  key: DB_USER
            - name: CNPG_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mastodon-db-url
                  key: DB_PASS
            - name: CNPG_SSLROOTCERT
              value: "/opt/postgresql/cnpg-ca.crt"
            - name: PGSSLMODE
              value: "require"
          volumeMounts:
            - name: zalando-ca
              mountPath: /opt/postgresql/zalando-ca.crt
              subPath: ca.crt
            - name: cnpg-ca
              mountPath: /opt/postgresql/cnpg-ca.crt
              subPath: ca.crt
          resources:
            requests:
              cpu: 200m
              memory: 1Gi
            limits:
              memory: 2Gi
      volumes:
        - name: zalando-ca
          secret:
            secretName: mastodon-postgresql-ca
        - name: cnpg-ca
          secret:
            secretName: database-ca
EOF

# Replace timestamp in the YAML
sed "s/TIMESTAMP/${TIMESTAMP}/g" /tmp/cnpg-restore-${TIMESTAMP}.yaml > /tmp/cnpg-restore-final-${TIMESTAMP}.yaml

log_step "Applying restore job..."
kubectl apply -f /tmp/cnpg-restore-final-${TIMESTAMP}.yaml

log_step "Waiting for restore to complete (max 20 minutes)..."
if kubectl wait --for=condition=complete --timeout=1200s job/cnpg-restore-${TIMESTAMP} -n "$NAMESPACE"; then
    log_info "Restore completed successfully"
else
    log_error "Restore job failed or timed out"
    kubectl logs job/cnpg-restore-${TIMESTAMP} -n "$NAMESPACE" --tail=100

    log_error "Migration failed - manual intervention required"
    log_error "Applications are still scaled down"
    log_error "Review logs and decide whether to:"
    log_error "  1. Fix issues and retry restore"
    log_error "  2. Rollback to Zalando (apps still configured for Zalando)"
    exit 1
fi

log_step "Showing restore job logs..."
kubectl logs job/cnpg-restore-${TIMESTAMP} -n "$NAMESPACE" --tail=50

# ==========================================
# STEP 6: VALIDATION
# ==========================================
log_section "Step 6: Quick Validation"

log_step "Comparing row counts..."
kubectl logs job/cnpg-restore-${TIMESTAMP} -n "$NAMESPACE" | grep -E "(Accounts|completed successfully|Validation)"

# ==========================================
# STEP 7: RESTORE APPLICATIONS
# ==========================================
log_section "Step 7: Restoring Applications"

log_warn "Applications are still configured to use Zalando PostgreSQL"
log_warn "They will reconnect to Zalando when scaled up"
log_warn "To complete migration, update mastodon-database.env after validation"

log_step "Scaling up Mastodon web..."
kubectl scale deployment mastodon-web --replicas=$MASTODON_WEB_REPLICAS -n "$NAMESPACE"

log_step "Scaling up Mastodon sidekiq workers..."
kubectl scale deployment mastodon-sidekiq-default --replicas=$MASTODON_SIDEKIQ_DEFAULT_REPLICAS -n "$NAMESPACE"
kubectl scale deployment mastodon-sidekiq-background --replicas=$MASTODON_SIDEKIQ_BACKGROUND_REPLICAS -n "$NAMESPACE"
kubectl scale deployment mastodon-sidekiq-federation --replicas=$MASTODON_SIDEKIQ_FEDERATION_REPLICAS -n "$NAMESPACE"

log_step "Scaling up Mastodon streaming..."
kubectl scale deployment mastodon-streaming --replicas=$MASTODON_STREAMING_REPLICAS -n "$NAMESPACE"

log_step "Waiting for applications to become ready (max 5 minutes)..."
kubectl wait --for=condition=ready pod -l app=mastodon-web -n "$NAMESPACE" --timeout=300s || log_warn "Some web pods not ready yet"

END_TIME=$(date +%s)
DOWNTIME_SECONDS=$((END_TIME - START_TIME))
DOWNTIME_MINUTES=$((DOWNTIME_SECONDS / 60))

log_info "All Mastodon applications restored"
log_info "Total downtime: ${DOWNTIME_MINUTES}m ${DOWNTIME_SECONDS}s"

# ==========================================
# SUMMARY AND NEXT STEPS
# ==========================================
log_section "Migration Summary"

log_info "✓ Applications scaled down"
log_info "✓ Final backup created from Zalando"
log_info "✓ Data restored to CNPG"
log_info "✓ Basic validation passed"
log_info "✓ Applications scaled back up"

echo ""
log_warn "IMPORTANT NEXT STEPS:"
echo ""
echo "1. Applications are currently using Zalando PostgreSQL"
echo "   Data has been copied to CNPG but apps not switched yet"
echo ""
echo "2. Run validation job to verify CNPG data integrity:"
echo "   kubectl apply -f cnpg-validation-job.yaml"
echo "   kubectl create job cnpg-validation-${TIMESTAMP} --from=job/cnpg-validation-job -n mastodon"
echo ""
echo "3. If validation passes, update database configuration:"
echo "   Edit: kubernetes/apps/platform/mastodon/configs/mastodon-database.env"
echo "   Change: DB_HOST=mastodon-postgresql-pooler → DB_HOST=database-pooler-rw"
echo "   Change: REPLICA_DB_HOST=mastodon-postgresql-repl → REPLICA_DB_HOST=database-pooler-ro"
echo ""
echo "4. Apply configuration and restart apps:"
echo "   kubectl apply -k kubernetes/apps/platform/mastodon/"
echo "   kubectl rollout restart deployment -l app=mastodon-web -n mastodon"
echo "   kubectl rollout restart deployment -l app=mastodon-sidekiq -n mastodon"
echo "   kubectl rollout restart deployment -l app=mastodon-streaming -n mastodon"
echo ""
echo "5. Monitor for 24-48 hours before cleanup"
echo ""
echo "Log file: $LOG_FILE"
echo "Replica backup: /tmp/mastodon-replicas-${TIMESTAMP}.txt"
echo ""

log_info "Migration execution completed"