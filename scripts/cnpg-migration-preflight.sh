#!/usr/bin/env bash
# CloudNativePG Migration - Command Validation Script
# This script validates that all prerequisites are met before migration

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "CloudNativePG Migration Preflight Checks"
echo "========================================="
echo ""

# Check 1: kubectl is installed
echo -n "✓ Checking kubectl... "
if command -v kubectl &> /dev/null; then
    echo -e "${GREEN}OK${NC} ($(kubectl version --client --short 2>/dev/null || kubectl version --client))"
else
    echo -e "${RED}FAILED${NC}"
    echo "  kubectl is not installed. Please install it first."
    exit 1
fi

# Check 2: kubectl cnpg plugin
echo -n "✓ Checking kubectl-cnpg plugin... "
if kubectl cnpg version &> /dev/null; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}WARNING${NC}"
    echo "  kubectl-cnpg plugin not found. Install with:"
    echo "  curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh | sh -s -- -b /usr/local/bin"
fi

# Check 3: Kubernetes cluster connectivity
echo -n "✓ Checking cluster connectivity... "
if kubectl cluster-info &> /dev/null; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED${NC}"
    echo "  Cannot connect to Kubernetes cluster"
    exit 1
fi

# Check 4: Mastodon namespace exists
echo -n "✓ Checking mastodon namespace... "
if kubectl get namespace mastodon &> /dev/null; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED${NC}"
    echo "  Namespace 'mastodon' does not exist"
    exit 1
fi

# Check 5: Zalando cluster running
echo -n "✓ Checking Zalando cluster... "
if kubectl get postgresql mastodon-postgresql -n mastodon &> /dev/null; then
    ZALANDO_STATUS=$(kubectl get postgresql mastodon-postgresql -n mastodon -o jsonpath='{.status.PostgresClusterStatus}')
    if [ "$ZALANDO_STATUS" = "Running" ]; then
        echo -e "${GREEN}OK${NC} (Status: $ZALANDO_STATUS)"
    else
        echo -e "${YELLOW}WARNING${NC} (Status: $ZALANDO_STATUS)"
    fi
else
    echo -e "${RED}FAILED${NC}"
    echo "  Zalando cluster 'mastodon-postgresql' not found"
    exit 1
fi

# Check 6: ExternalSecret for standby credentials
echo -n "✓ Checking zalando-standby-credentials secret... "
if kubectl get secret zalando-standby-credentials -n mastodon &> /dev/null; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED${NC}"
    echo "  Secret 'zalando-standby-credentials' not found"
    exit 1
fi

# Check 7: TLS certificates
echo -n "✓ Checking TLS certificates... "
CERT_COUNT=0
if kubectl get secret mastodon-postgresql-ca -n mastodon &> /dev/null; then
    ((CERT_COUNT++))
fi
if kubectl get secret mastodon-postgresql-server -n mastodon &> /dev/null; then
    ((CERT_COUNT++))
fi

if [ $CERT_COUNT -eq 2 ]; then
    echo -e "${GREEN}OK${NC} (mastodon-postgresql-ca, mastodon-postgresql-server)"
else
    echo -e "${YELLOW}WARNING${NC}"
    echo "  Missing TLS certificates. Found $CERT_COUNT/2"
fi

# Check 8: CloudNativePG operator
echo -n "✓ Checking CloudNativePG operator... "
if kubectl get deployment -n cnpg-system cloudnative-pg &> /dev/null 2>&1; then
    READY=$(kubectl get deployment -n cnpg-system cloudnative-pg -o jsonpath='{.status.readyReplicas}')
    echo -e "${GREEN}OK${NC} (Ready replicas: $READY)"
elif kubectl get deployment -l app.kubernetes.io/name=cloudnative-pg --all-namespaces &> /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED${NC}"
    echo "  CloudNativePG operator not found"
    exit 1
fi

# Check 9: Database size
echo -n "✓ Checking database size... "
DB_SIZE=$(kubectl exec -n mastodon mastodon-postgresql-0 -- \
    psql -U postgres -t -c "SELECT pg_size_pretty(pg_database_size('mastodon'));" 2>/dev/null | xargs)
if [ -n "$DB_SIZE" ]; then
    echo -e "${GREEN}OK${NC} (Size: $DB_SIZE)"
else
    echo -e "${YELLOW}WARNING${NC}"
    echo "  Could not determine database size"
fi

# Check 10: Standby user privileges
echo -n "✓ Checking standby user privileges... "
STANDBY_CHECK=$(kubectl exec -n mastodon mastodon-postgresql-0 -- \
    psql -U postgres -t -c "SELECT rolsuper OR rolreplication FROM pg_roles WHERE rolname = 'standby';" 2>/dev/null | xargs)
if [ "$STANDBY_CHECK" = "t" ]; then
    echo -e "${GREEN}OK${NC} (User has sufficient privileges)"
else
    echo -e "${YELLOW}WARNING${NC}"
    echo "  Standby user may not have sufficient privileges for pg_dump"
    echo "  Run: kubectl exec -n mastodon mastodon-postgresql-0 -- psql -U postgres -c \"SELECT * FROM pg_roles WHERE rolname = 'standby';\""
fi

# Check 11: Disk space on source
echo -n "✓ Checking disk space on source... "
DISK_AVAIL=$(kubectl exec -n mastodon mastodon-postgresql-0 -- \
    df -h /home/postgres/pgdata 2>/dev/null | tail -1 | awk '{print $4}')
if [ -n "$DISK_AVAIL" ]; then
    echo -e "${GREEN}OK${NC} (Available: $DISK_AVAIL)"
else
    echo -e "${YELLOW}WARNING${NC}"
    echo "  Could not determine available disk space"
fi

# Check 12: Test connectivity from temp pod
echo -n "✓ Testing PostgreSQL connectivity... "
STANDBY_PASS=$(kubectl get secret zalando-standby-credentials -n mastodon -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
if [ -n "$STANDBY_PASS" ]; then
    if kubectl run pg-test-preflight --rm -i --restart=Never \
        --image=ghcr.io/cloudnative-pg/postgresql:17.5 \
        --namespace=mastodon \
        -- bash -c "export PGPASSWORD=\"$STANDBY_PASS\" && psql 'host=mastodon-postgresql.mastodon.svc.cluster.local port=5432 user=standby dbname=mastodon sslmode=require' -c 'SELECT 1;'" &> /dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        echo "  Could not connect to Zalando cluster"
        echo "  Run the connectivity test from MIGRATION-PGDUMP.md section 2 for details"
    fi
else
    echo -e "${YELLOW}SKIPPED${NC} (Could not retrieve password)"
fi

# Check 13: Version compatibility
echo -n "✓ Checking PostgreSQL versions... "
SOURCE_VERSION=$(kubectl exec -n mastodon mastodon-postgresql-0 -- \
    psql -U postgres -t -c "SHOW server_version;" 2>/dev/null | xargs | cut -d' ' -f1)
if [ -n "$SOURCE_VERSION" ]; then
    echo -e "${GREEN}OK${NC} (Source: PostgreSQL $SOURCE_VERSION)"
    # Check if CNPG cluster exists
    if kubectl get cluster database-cnpg -n mastodon &> /dev/null; then
        TARGET_VERSION=$(kubectl cnpg psql database-cnpg -n mastodon -- -t -c "SHOW server_version;" 2>/dev/null | xargs | cut -d' ' -f1)
        if [ -n "$TARGET_VERSION" ]; then
            echo "  Target: PostgreSQL $TARGET_VERSION"
        fi
    fi
else
    echo -e "${YELLOW}WARNING${NC}"
fi

echo ""
echo "========================================="
echo "Preflight Check Summary"
echo "========================================="
echo ""
echo "Core Prerequisites:"
echo "  • kubectl: ✓"
echo "  • Cluster connectivity: ✓"
echo "  • Mastodon namespace: ✓"
echo "  • Zalando cluster: ✓"
echo "  • CloudNativePG operator: ✓"
echo ""
echo "Migration Prerequisites:"
echo "  • Standby credentials secret: ✓"
echo "  • TLS certificates: Check output above"
echo "  • Standby user privileges: Check output above"
echo "  • Database connectivity: Check output above"
echo ""
echo "Database Info:"
echo "  • Source PostgreSQL version: $SOURCE_VERSION"
echo "  • Database size: $DB_SIZE"
echo "  • Available disk space: $DISK_AVAIL"
echo ""
echo -e "${GREEN}Preflight checks complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Review MIGRATION-PGDUMP.md thoroughly"
echo "  2. Run staging test (highly recommended)"
echo "  3. Schedule maintenance window"
echo "  4. Execute Phase 1: Initial Import"
echo ""
