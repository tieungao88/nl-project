#!/usr/bin/env bash
#
# ═══════════════════════════════════════════════════════════════════════════════
# EKS Cluster Discovery & Upgrade Suggestion Script
# ═══════════════════════════════════════════════════════════════════════════════
#
# Description: Discovers EKS cluster information, applications, and provides
#              upgrade/optimization suggestions. READ-ONLY - no changes made.
#
# Usage:
#   ./eks-discovery.sh -c <cluster-name> -r <region>
#   ./eks-discovery.sh -c <cluster-name> -r <region> -o /tmp/reports
#   ./eks-discovery.sh -h
#
# Requirements:
#   - AWS CLI v2 (configured with EKS access)
#   - kubectl (connected to target cluster)
#   - jq (JSON processor)
#   - Optional: helm (for Helm release discovery)
#
# Output:
#   - Text report:  eks-report-<cluster>-<timestamp>.txt
#   - CSV report:   eks-report-<cluster>-<timestamp>.csv
#
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# GLOBAL VARIABLES
# ─────────────────────────────────────────────────────────────────────────────
VERSION="1.2.0"
SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
DATE_HUMAN="$(date '+%Y-%m-%d %H:%M:%S %Z')"
CLUSTER_NAME=""
REGION=""
REPORT_FILE=""
CSV_FILE=""
HTML_FILE=""
REPORT_DIR="."
CHECK_CHARTS=false

# Counters for summary
CRITICAL_COUNT=0
WARNING_COUNT=0
INFO_COUNT=0

# Color codes (for terminal output)
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# EKS Version Lifecycle Data (updated Aug 2026)
# Format: VERSION:END_STANDARD_SUPPORT:END_EXTENDED_SUPPORT
declare -a EKS_LIFECYCLE=(
    "1.27:2024-07-24:2025-07-24"
    "1.28:2024-11-26:2025-11-26"
    "1.29:2025-03-23:2026-03-23"
    "1.30:2025-07-23:2026-07-23"
    "1.31:2025-11-26:2026-11-26"
    "1.32:2026-03-23:2027-03-23"
    "1.33:2026-07-29:2027-07-29"
    "1.34:2026-12-02:2027-12-02"
)
LATEST_EKS_VERSION="1.34"

# AL2 AMI Types (used to detect AL2 vs AL2023)
# AL2 types: AL2_x86_64, AL2_x86_64_GPU, AL2_ARM_64
# AL2023 types: AL2023_x86_64_STANDARD, AL2023_x86_64_GPU, AL2023_ARM_64_STANDARD, AL2023_x86_64_NEURON, AL2023_x86_64_NVIDIA
declare -A AL2_AMI_TYPES=(
    ["AL2_x86_64"]="AL2023_x86_64_STANDARD"
    ["AL2_x86_64_GPU"]="AL2023_x86_64_GPU"
    ["AL2_ARM_64"]="AL2023_ARM_64_STANDARD"
)

# ─────────────────────────────────────────────────────────────────────────────
# UTILITY FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
${SCRIPT_NAME} v${VERSION} - EKS Cluster Discovery & Upgrade Suggestions

Usage:
  ${SCRIPT_NAME} -c <cluster-name> -r <region> [OPTIONS]

Required:
  -c, --cluster    EKS cluster name
  -r, --region     AWS region (e.g., ap-southeast-1)

Options:
  -o, --output       Output directory for report files (default: current dir)
  -C, --check-charts Compare installed Helm charts against upstream releases.
                     OFF by default: this is the only part of the script that
                     talks to anything other than the AWS API and the cluster.
                     It sends chart names to artifacthub.io over HTTPS - no
                     cluster data, no identifiers, no credentials - and needs
                     curl plus outbound internet access.
  -h, --help         Show this help message

Examples:
  ${SCRIPT_NAME} -c my-cluster -r ap-southeast-1
  ${SCRIPT_NAME} -c my-cluster -r ap-southeast-1 -o /tmp/reports
  ${SCRIPT_NAME} -c my-cluster -r ap-southeast-1 --check-charts

Output Files:
  - eks-report-<cluster>-<timestamp>.txt  (Text report)
  - eks-report-<cluster>-<timestamp>.csv  (CSV data for spreadsheet)

EOF
    exit 0
}

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

# Write to report file (strip ANSI colors)
report() {
    echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g' >> "$REPORT_FILE"
}

# Write to both terminal and report
output() {
    echo -e "$1"
    report "$1"
}

# Write CSV row (properly escape fields)
csv_row() {
    local IFS=','
    echo "$*" >> "$CSV_FILE"
}

# Section header
section_header() {
    local title="$1"
    local icon="${2:-📋}"
    output ""
    output "${BOLD}${icon} ${title}${NC}"
    output "─────────────────────────────────────────────────────────────────"
}

# Sub-section header
sub_header() {
    local title="$1"
    output ""
    output "  ${CYAN}▸ ${title}${NC}"
}

# Add suggestion with severity
add_suggestion() {
    local severity="$1"  # CRITICAL, WARNING, INFO
    local message="$2"
    local detail="${3:-}"

    # Also write to CSV
    csv_row "\"SUGGESTION\"" "\"$severity\"" "\"$message\"" "\"$detail\"" "" "" "" ""

    case "$severity" in
        CRITICAL)
            SUGGESTIONS_CRITICAL+=("$message|$detail")
            ((CRITICAL_COUNT++)) || true
            ;;
        WARNING)
            SUGGESTIONS_WARNING+=("$message|$detail")
            ((WARNING_COUNT++)) || true
            ;;
        INFO)
            SUGGESTIONS_INFO+=("$message|$detail")
            ((INFO_COUNT++)) || true
            ;;
    esac
}

# Initialize suggestion arrays
declare -a SUGGESTIONS_CRITICAL=()
declare -a SUGGESTIONS_WARNING=()
declare -a SUGGESTIONS_INFO=()

# Reduce a component version string to its bare semver so that differently
# formatted-but-equivalent versions compare equal:
#   v1.11.4-eksbuild.14        -> 1.11.4
#   v1.32.6-minimal-eksbuild.12 -> 1.32.6
#   v1.40.0                     -> 1.40.0   (image tags often omit -eksbuild.N)
normalize_component_version() {
    local v="${1#v}"
    echo "${v%%-*}"
}

# Major.minor of a bare semver: 1.11.4 -> 1.11
major_minor() {
    local v="$1"
    echo "$v" | cut -d'.' -f1,2
}

# ── Helm chart currency lookup (opt-in, --check-charts) ──────────────────────
#
# NOTE ON NETWORK ACCESS: everything else in this script talks only to the AWS
# API and the cluster. These two functions are the sole exception - they make
# outbound HTTPS GETs to artifacthub.io. Only a chart name is sent; no cluster
# data, no identifiers, no credentials. That is why it is behind a flag and off
# by default: the no-egress property of the default run is worth preserving.

# Map a chart name to its Artifact Hub "<repo>/<package>" coordinates.
# Vendor-distributed charts (Rancher's 105.x line, in-house charts) return
# empty - there is no upstream release stream to compare them against.
chart_to_artifacthub() {
    case "$1" in
        ingress-nginx)                echo "ingress-nginx/ingress-nginx" ;;
        argo-cd)                      echo "argo/argo-cd" ;;
        argo-workflows)               echo "argo/argo-workflows" ;;
        argo-rollouts)                echo "argo/argo-rollouts" ;;
        cert-manager)                 echo "cert-manager/cert-manager" ;;
        kube-prometheus-stack)        echo "prometheus-community/kube-prometheus-stack" ;;
        prometheus)                   echo "prometheus-community/prometheus" ;;
        loki)                         echo "grafana/loki" ;;
        loki-distributed)             echo "grafana/loki-distributed" ;;
        loki-stack)                   echo "grafana/loki-stack" ;;
        promtail)                     echo "grafana/promtail" ;;
        grafana)                      echo "grafana/grafana" ;;
        alloy)                        echo "grafana/alloy" ;;
        metrics-server)               echo "metrics-server/metrics-server" ;;
        aws-load-balancer-controller) echo "aws/aws-load-balancer-controller" ;;
        external-dns)                 echo "external-dns/external-dns" ;;
        cluster-autoscaler)           echo "autoscaler/cluster-autoscaler" ;;
        velero)                       echo "vmware-tanzu/velero" ;;
        external-secrets)             echo "external-secrets/external-secrets" ;;
        sealed-secrets)               echo "sealed-secrets/sealed-secrets" ;;
        keda)                         echo "kedacore/keda" ;;
        *)                            echo "" ;;
    esac
}

# Latest chart version, its app version, and whether upstream has marked the
# chart deprecated - as a TSV triple. Empty on any failure (offline, rate
# limited, package renamed); the caller degrades to "-".
#
# The deprecated flag matters as much as the version: a chart frozen at its
# final release reports as "up to date" while actually being abandoned.
artifacthub_latest() {
    local pkg="$1"
    curl -fsS --max-time 10 -H 'Accept: application/json' \
        "https://artifacthub.io/api/v1/packages/helm/${pkg}" 2>/dev/null \
        | jq -r '[(.version // ""), (.app_version // ""), ((.deprecated // false) | tostring)] | @tsv' 2>/dev/null || echo ""
}

# Convert date to epoch for comparison (cross-platform)
date_to_epoch() {
    local d="$1"
    if date --version >/dev/null 2>&1; then
        # GNU date (Linux/CloudShell)
        date -d "$d" +%s 2>/dev/null || echo "0"
    else
        # BSD date (macOS)
        date -j -f "%Y-%m-%d" "$d" +%s 2>/dev/null || echo "0"
    fi
}

# Get current epoch
current_epoch() {
    date +%s
}

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--cluster) CLUSTER_NAME="$2"; shift 2 ;;
            -r|--region)  REGION="$2"; shift 2 ;;
            -o|--output)  REPORT_DIR="$2"; shift 2 ;;
            -C|--check-charts) CHECK_CHARTS=true; shift ;;
            -h|--help)    usage ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done

    # Validate required parameters
    if [[ -z "$CLUSTER_NAME" ]]; then
        log_error "Missing required parameter: -c <cluster-name>"
        echo ""
        usage
    fi
    if [[ -z "$REGION" ]]; then
        log_error "Missing required parameter: -r <region>"
        echo ""
        usage
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

preflight_checks() {
    log "Running pre-flight checks..."

    # Check required tools
    local missing=()
    for cmd in aws kubectl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Please install them before running this script."
        exit 1
    fi
    log_success "Required tools: aws, kubectl, jq"

    # Check optional tools
    if command -v helm &>/dev/null; then
        HAS_HELM=true
        log_success "Optional tool: helm (available)"
    else
        HAS_HELM=false
        log_warn "Optional tool: helm (not found - Helm release discovery will be skipped)"
    fi

    # --check-charts is the only feature that reaches outside AWS/the cluster.
    # Say so plainly at start-up rather than surprising anyone reading logs.
    if [[ "$CHECK_CHARTS" == true ]]; then
        if ! command -v curl &>/dev/null; then
            log_warn "--check-charts requested but curl not found - chart currency check disabled"
            CHECK_CHARTS=false
        elif [[ "$HAS_HELM" != true ]]; then
            log_warn "--check-charts requested but helm not found - nothing to compare, check disabled"
            CHECK_CHARTS=false
        else
            log_warn "--check-charts enabled: will send chart names to artifacthub.io over HTTPS"
            log_warn "  (no cluster data, identifiers or credentials leave this machine)"
        fi
    fi

    # Verify kubectl connectivity
    if ! kubectl cluster-info &>/dev/null; then
        log_warn "kubectl not connected. Attempting to update kubeconfig..."
        if ! aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null; then
            log_error "Failed to connect to cluster $CLUSTER_NAME in region $REGION"
            exit 1
        fi
    fi
    log_success "kubectl connected to cluster"

    # Setup report files
    mkdir -p "$REPORT_DIR"
    REPORT_FILE="${REPORT_DIR}/eks-report-${CLUSTER_NAME}-${TIMESTAMP}.txt"
    CSV_FILE="${REPORT_DIR}/eks-report-${CLUSTER_NAME}-${TIMESTAMP}.csv"
    HTML_FILE="${REPORT_DIR}/eks-report-${CLUSTER_NAME}-${TIMESTAMP}.html"
    touch "$REPORT_FILE"

    # Initialize CSV with headers
    echo "CATEGORY,ITEM,NAMESPACE,NAME,CURRENT_VALUE,RECOMMENDED_VALUE,STATUS,DETAIL" > "$CSV_FILE"

    log_success "Text report : $REPORT_FILE"
    log_success "CSV report  : $CSV_FILE"
    log_success "HTML report : $HTML_FILE"

    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 1: CLUSTER INFORMATION
# ─────────────────────────────────────────────────────────────────────────────

discover_cluster_info() {
    section_header "SECTION 1: CLUSTER OVERVIEW" "📋"

    local cluster_json
    cluster_json=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --output json 2>/dev/null)

    if [[ -z "$cluster_json" ]]; then
        output "  ${RED}ERROR: Failed to describe cluster${NC}"
        return
    fi

    # Basic info
    local k8s_version platform_version status endpoint created_at
    k8s_version=$(echo "$cluster_json" | jq -r '.cluster.version')
    platform_version=$(echo "$cluster_json" | jq -r '.cluster.platformVersion // "N/A"')
    status=$(echo "$cluster_json" | jq -r '.cluster.status')
    endpoint=$(echo "$cluster_json" | jq -r '.cluster.endpoint')
    created_at=$(echo "$cluster_json" | jq -r '.cluster.createdAt')

    # Store for later use
    CLUSTER_K8S_VERSION="$k8s_version"

    # Determine support status
    local support_status="UNKNOWN"
    local support_status_plain="UNKNOWN"
    local support_detail=""
    local now_epoch
    now_epoch=$(current_epoch)

    for lifecycle in "${EKS_LIFECYCLE[@]}"; do
        IFS=':' read -r ver end_std end_ext <<< "$lifecycle"
        if [[ "$ver" == "$k8s_version" ]]; then
            local std_epoch ext_epoch
            std_epoch=$(date_to_epoch "$end_std")
            ext_epoch=$(date_to_epoch "$end_ext")

            if [[ "$now_epoch" -lt "$std_epoch" ]]; then
                support_status="${GREEN}STANDARD SUPPORT${NC}"
                support_status_plain="STANDARD_SUPPORT"
                support_detail="Standard support ends: $end_std"
            elif [[ "$now_epoch" -lt "$ext_epoch" ]]; then
                support_status="${YELLOW}⚠️  EXTENDED SUPPORT${NC}"
                support_status_plain="EXTENDED_SUPPORT"
                support_detail="Extended support ends: $end_ext (cost: \$0.60/hr vs \$0.10/hr)"
                add_suggestion "WARNING" \
                    "Cluster version $k8s_version is in Extended Support (6x cost increase)" \
                    "Extended support ends: $end_ext. Consider upgrading to reduce costs."
            else
                support_status="${RED}🔴 END OF LIFE${NC}"
                support_status_plain="END_OF_LIFE"
                support_detail="Extended support ended: $end_ext"
                add_suggestion "CRITICAL" \
                    "Cluster version $k8s_version has reached End of Life!" \
                    "AWS may auto-upgrade your cluster. Upgrade immediately."
            fi
            break
        fi
    done

    # CSV: Cluster overview
    csv_row "\"CLUSTER\"" "\"version\"" "\"\"" "\"$CLUSTER_NAME\"" "\"$k8s_version\"" "\"$LATEST_EKS_VERSION\"" "\"$support_status_plain\"" "\"$support_detail\""
    csv_row "\"CLUSTER\"" "\"platform\"" "\"\"" "\"$CLUSTER_NAME\"" "\"$platform_version\"" "\"\"" "\"$status\"" "\"Created: $created_at\""

    # Check if upgrade is available
    if [[ "$k8s_version" != "$LATEST_EKS_VERSION" ]]; then
        # Build upgrade path
        local upgrade_path="$k8s_version"
        local found=false
        for lifecycle in "${EKS_LIFECYCLE[@]}"; do
            IFS=':' read -r ver _ _ <<< "$lifecycle"
            if [[ "$found" == true ]]; then
                upgrade_path="$upgrade_path → $ver"
            fi
            if [[ "$ver" == "$k8s_version" ]]; then
                found=true
            fi
        done
        add_suggestion "CRITICAL" \
            "Cluster version $k8s_version is not the latest (latest: $LATEST_EKS_VERSION)" \
            "Upgrade path (sequential): $upgrade_path"
    fi

    output "  Cluster Name      : ${BOLD}$CLUSTER_NAME${NC}"
    output "  Kubernetes Version: ${BOLD}$k8s_version${NC}"
    output "  Platform Version  : $platform_version"
    output "  Status            : $status"
    output "  Support Status    : $support_status"
    output "  Support Detail    : $support_detail"
    output "  Created At        : $created_at"
    output "  Endpoint          : $endpoint"
    output "  Region            : $REGION"

    # Networking
    sub_header "Networking"
    local vpc_id
    vpc_id=$(echo "$cluster_json" | jq -r '.cluster.resourcesVpcConfig.vpcId // "N/A"')
    local subnet_ids
    subnet_ids=$(echo "$cluster_json" | jq -r 'if (.cluster.resourcesVpcConfig.subnetIds | type) == "array" and (.cluster.resourcesVpcConfig.subnetIds | length) > 0 then .cluster.resourcesVpcConfig.subnetIds | join(", ") else "N/A" end' 2>/dev/null || echo "N/A")
    local sg_ids
    sg_ids=$(echo "$cluster_json" | jq -r 'if (.cluster.resourcesVpcConfig.securityGroupIds | type) == "array" and (.cluster.resourcesVpcConfig.securityGroupIds | length) > 0 then .cluster.resourcesVpcConfig.securityGroupIds | join(", ") else "N/A" end' 2>/dev/null || echo "N/A")
    local cluster_sg
    cluster_sg=$(echo "$cluster_json" | jq -r '.cluster.resourcesVpcConfig.clusterSecurityGroupId // "N/A"')
    local public_access
    public_access=$(echo "$cluster_json" | jq -r '.cluster.resourcesVpcConfig.endpointPublicAccess')
    local private_access
    private_access=$(echo "$cluster_json" | jq -r '.cluster.resourcesVpcConfig.endpointPrivateAccess')

    # Which source IPs may reach the public endpoint. Without this, a cluster
    # with public+private access enabled looked fine even when its API server
    # was reachable from the entire internet.
    local public_cidrs
    public_cidrs=$(echo "$cluster_json" | jq -r 'if (.cluster.resourcesVpcConfig.publicAccessCidrs | type) == "array" and (.cluster.resourcesVpcConfig.publicAccessCidrs | length) > 0 then .cluster.resourcesVpcConfig.publicAccessCidrs | join(", ") else "N/A" end' 2>/dev/null || echo "N/A")

    output "  VPC ID            : $vpc_id"
    output "  Subnets           : $subnet_ids"
    output "  Security Groups   : $sg_ids"
    output "  Cluster SG        : $cluster_sg"
    output "  Public Access     : $public_access"
    output "  Private Access    : $private_access"
    if [[ "$public_access" == "true" ]]; then
        if echo "$public_cidrs" | grep -q '0\.0\.0\.0/0'; then
            output "  Public Access CIDR: ${RED}$public_cidrs (open to the entire internet)${NC}"
        else
            output "  Public Access CIDR: $public_cidrs"
        fi
    fi

    csv_row "\"CLUSTER\"" "\"endpoint_access\"" "\"\"" "\"$CLUSTER_NAME\"" "\"public=$public_access, private=$private_access\"" "\"\"" "\"\"" "\"public_cidrs=$public_cidrs\""

    if [[ "$public_access" == "true" && "$private_access" == "false" ]]; then
        add_suggestion "WARNING" \
            "Cluster endpoint is publicly accessible without private access" \
            "Consider enabling private endpoint access for better security."
    fi

    if [[ "$public_access" == "true" ]] && echo "$public_cidrs" | grep -q '0\.0\.0\.0/0'; then
        add_suggestion "CRITICAL" \
            "Kubernetes API server is reachable from any IP address (publicAccessCidrs = 0.0.0.0/0)" \
            "Anyone on the internet can reach the control plane endpoint; only authentication stands between them and the API. Restrict to office/VPN ranges via: aws eks update-cluster-config --name $CLUSTER_NAME --region $REGION --resources-vpc-config publicAccessCidrs=<your-cidrs>  -- or disable public access entirely if private access is enabled."
    fi

    # Logging
    sub_header "Control Plane Logging"
    local logging_json
    logging_json=$(echo "$cluster_json" | jq -r '.cluster.logging.clusterLogging[0]' 2>/dev/null)
    local logging_enabled
    logging_enabled=$(echo "$logging_json" | jq -r '.enabled // false')
    local logging_types
    logging_types=$(echo "$logging_json" | jq -r '.types | join(", ") // "none"' 2>/dev/null || echo "none")

    if [[ "$logging_enabled" == "true" ]]; then
        output "  Logging Enabled   : ${GREEN}Yes${NC}"
        output "  Log Types         : $logging_types"
    else
        output "  Logging Enabled   : ${RED}No${NC}"
        add_suggestion "WARNING" \
            "Control plane logging is not enabled" \
            "Enable at least 'api', 'audit', and 'authenticator' logs for security and troubleshooting."
    fi

    # Encryption
    sub_header "Encryption"
    local encryption
    encryption=$(echo "$cluster_json" | jq -r '.cluster.encryptionConfig // empty' 2>/dev/null)
    if [[ -n "$encryption" && "$encryption" != "null" ]]; then
        local kms_key
        kms_key=$(echo "$encryption" | jq -r '.[0].provider.keyArn // "N/A"')
        output "  Secrets Encryption: ${GREEN}Enabled${NC}"
        output "  KMS Key           : $kms_key"
    else
        output "  Secrets Encryption: ${YELLOW}Not configured${NC}"
        add_suggestion "INFO" \
            "Secrets encryption with KMS is not configured" \
            "Consider enabling envelope encryption for Kubernetes secrets."
    fi

    # OIDC Provider
    sub_header "Identity"
    local oidc
    oidc=$(echo "$cluster_json" | jq -r '.cluster.identity.oidc.issuer // "N/A"')
    output "  OIDC Issuer       : $oidc"

    # Authentication mode
    local auth_mode
    auth_mode=$(echo "$cluster_json" | jq -r '.cluster.accessConfig.authenticationMode // "N/A"')
    output "  Auth Mode         : $auth_mode"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 2: NODE GROUPS (Enhanced with AL2 → AL2023 detection)
# ─────────────────────────────────────────────────────────────────────────────

discover_node_groups() {
    section_header "SECTION 2: NODE GROUPS" "🖥️"

    # Managed Node Groups from AWS API
    sub_header "Managed Node Groups (AWS API)"
    local nodegroups
    nodegroups=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'nodegroups' --output json 2>/dev/null)
    local ng_count
    ng_count=$(echo "$nodegroups" | jq -r 'length' 2>/dev/null || echo "0")

    if [[ "$ng_count" -gt 0 ]]; then
        output "  Total Managed Node Groups: $ng_count"
        output ""

        for ng_name in $(echo "$nodegroups" | jq -r '.[]'); do
            local ng_json
            ng_json=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng_name" --region "$REGION" --output json 2>/dev/null)

            local ng_status ng_version ng_ami_type ng_instance_types ng_desired ng_min ng_max ng_ami_release disk_size capacity_type
            local ng_launch_template ng_lt_version ng_labels ng_taints ng_subnets
            ng_status=$(echo "$ng_json" | jq -r '.nodegroup.status // "N/A"')
            ng_version=$(echo "$ng_json" | jq -r '.nodegroup.version // "N/A"')
            ng_ami_type=$(echo "$ng_json" | jq -r '.nodegroup.amiType // "N/A"')
            ng_instance_types=$(echo "$ng_json" | jq -r 'if (.nodegroup.instanceTypes | type) == "array" and (.nodegroup.instanceTypes | length) > 0 then .nodegroup.instanceTypes | join(", ") else "N/A" end' 2>/dev/null || echo "N/A")
            ng_desired=$(echo "$ng_json" | jq -r '.nodegroup.scalingConfig.desiredSize // "N/A"')
            ng_min=$(echo "$ng_json" | jq -r '.nodegroup.scalingConfig.minSize // "N/A"')
            ng_max=$(echo "$ng_json" | jq -r '.nodegroup.scalingConfig.maxSize // "N/A"')
            ng_ami_release=$(echo "$ng_json" | jq -r '.nodegroup.releaseVersion // "N/A"')
            disk_size=$(echo "$ng_json" | jq -r '.nodegroup.diskSize // "N/A"')
            capacity_type=$(echo "$ng_json" | jq -r '.nodegroup.capacityType // "ON_DEMAND"')
            ng_launch_template=$(echo "$ng_json" | jq -r '.nodegroup.launchTemplate.name // "N/A"')
            ng_lt_version=$(echo "$ng_json" | jq -r '.nodegroup.launchTemplate.version // "N/A"')
            ng_labels=$(echo "$ng_json" | jq -r 'if (.nodegroup.labels | type) == "object" and (.nodegroup.labels | length) > 0 then .nodegroup.labels | to_entries | map(.key + "=" + .value) | join(", ") else "none" end' 2>/dev/null || echo "none")
            ng_taints=$(echo "$ng_json" | jq -r 'if (.nodegroup.taints | type) == "array" and (.nodegroup.taints | length) > 0 then .nodegroup.taints | map(.key + "=" + (.value // "") + ":" + .effect) | join(", ") else "none" end' 2>/dev/null || echo "none")
            ng_subnets=$(echo "$ng_json" | jq -r 'if (.nodegroup.subnets | type) == "array" and (.nodegroup.subnets | length) > 0 then .nodegroup.subnets | join(", ") else "N/A" end' 2>/dev/null || echo "N/A")

            # Detect node AMI ID from launch template or release version
            local ng_ami_id="N/A"
            if [[ "$ng_launch_template" != "N/A" && "$ng_lt_version" != "N/A" ]]; then
                ng_ami_id=$(aws ec2 describe-launch-template-versions \
                    --launch-template-name "$ng_launch_template" \
                    --versions "$ng_lt_version" \
                    --region "$REGION" \
                    --query 'LaunchTemplateVersions[0].LaunchTemplateData.ImageId' \
                    --output text 2>/dev/null || echo "N/A")
                # `--output text` prints the literal string "None" for a null
                # result (e.g. a launch template that does not pin an AMI),
                # which then leaked into the report as "AMI ID: None".
                [[ -z "$ng_ami_id" || "$ng_ami_id" == "None" ]] && ng_ami_id="N/A"
            fi

            # Determine AL2 migration status
            local ami_migration_status=""
            local ami_migration_color=""
            local ami_recommended=""

            if [[ -n "${AL2_AMI_TYPES[$ng_ami_type]+_}" ]]; then
                # This is an AL2 AMI type!
                ami_recommended="${AL2_AMI_TYPES[$ng_ami_type]}"
                ami_migration_status="⛔ AL2 (UNSUPPORTED)"
                ami_migration_color="${RED}"
                add_suggestion "CRITICAL" \
                    "Node group '$ng_name' uses AL2 AMI type ($ng_ami_type) - UNSUPPORTED since Nov 2025" \
                    "Migrate to AL2023 ($ami_recommended). AL2 EKS AMI support ended Nov 26, 2025. AL2 OS EOL: Jun 30, 2026. Migration requires creating new node group with AL2023 AMI and draining old nodes. Key changes: cgroup v2, IMDSv2 enforced, nodeadm instead of bootstrap.sh."
            elif echo "$ng_ami_type" | grep -q "AL2023"; then
                ami_migration_status="✅ AL2023 (Current)"
                ami_migration_color="${GREEN}"
                ami_recommended="$ng_ami_type"
            elif echo "$ng_ami_type" | grep -q "BOTTLEROCKET"; then
                ami_migration_status="✅ Bottlerocket (Current)"
                ami_migration_color="${GREEN}"
                ami_recommended="$ng_ami_type"
            elif echo "$ng_ami_type" | grep -q "WINDOWS"; then
                ami_migration_status="ℹ️ Windows"
                ami_migration_color="${CYAN}"
                ami_recommended="$ng_ami_type"
            elif [[ "$ng_ami_type" == "CUSTOM" ]]; then
                ami_migration_status="⚠️ CUSTOM AMI (manual check required)"
                ami_migration_color="${YELLOW}"
                ami_recommended="CUSTOM"
                add_suggestion "WARNING" \
                    "Node group '$ng_name' uses CUSTOM AMI - cannot auto-detect AL2 vs AL2023" \
                    "AMI ID: $ng_ami_id. Manually verify if this is based on AL2 or AL2023. If AL2-based, migrate to AL2023."
            else
                ami_migration_status="⚠️ Unknown AMI type"
                ami_migration_color="${YELLOW}"
                ami_recommended="N/A"
            fi

            # Also check node AMI via OS image on the nodes if custom
            if [[ "$ng_ami_type" == "CUSTOM" && "$ng_ami_id" != "N/A" ]]; then
                local ami_name
                ami_name=$(aws ec2 describe-images --image-ids "$ng_ami_id" --region "$REGION" --query 'Images[0].Name' --output text 2>/dev/null || echo "N/A")
                if echo "$ami_name" | grep -qi "amzn2-ami\|amazon-linux-2[^0]"; then
                    ami_migration_status="⛔ CUSTOM AMI based on AL2 (UNSUPPORTED)"
                    ami_migration_color="${RED}"
                    add_suggestion "CRITICAL" \
                        "Node group '$ng_name' uses CUSTOM AMI based on Amazon Linux 2 ($ami_name)" \
                        "AMI ID: $ng_ami_id. Rebuild custom AMI based on AL2023 and create new node group."
                elif echo "$ami_name" | grep -qi "al2023\|amazon-linux-2023"; then
                    ami_migration_status="✅ CUSTOM AMI based on AL2023"
                    ami_migration_color="${GREEN}"
                fi
            fi

            output "  ┌─ Node Group: ${BOLD}$ng_name${NC}"
            output "  │  Status         : $ng_status"
            output "  │  K8s Version    : $ng_version"
            output "  │  AMI Type       : $ng_ami_type"
            output "  │  AMI Status     : ${ami_migration_color}${ami_migration_status}${NC}"
            if [[ -n "${AL2_AMI_TYPES[$ng_ami_type]+_}" ]]; then
                output "  │  ${RED}AMI Migrate To : $ami_recommended${NC}"
            fi
            output "  │  AMI Release    : $ng_ami_release"
            if [[ "$ng_ami_id" != "N/A" ]]; then
                output "  │  AMI ID         : $ng_ami_id"
            fi
            output "  │  Instance Types : $ng_instance_types"
            output "  │  Capacity Type  : $capacity_type"
            output "  │  Disk Size (GB) : $disk_size"
            output "  │  Scaling        : min=$ng_min, desired=$ng_desired, max=$ng_max"
            if [[ "$ng_launch_template" != "N/A" ]]; then
                output "  │  Launch Template: $ng_launch_template (v$ng_lt_version)"
            fi
            output "  │  Labels         : $ng_labels"
            output "  │  Taints         : $ng_taints"
            output "  │  Subnets        : $ng_subnets"
            output "  └──────────────────────────────────────"

            # CSV: Node Group data
            csv_row "\"NODE_GROUP\"" "\"managed\"" "\"\"" "\"$ng_name\"" "\"$ng_ami_type\"" "\"$ami_recommended\"" "\"$ng_status\"" "\"version=$ng_version, instances=$ng_instance_types, scaling=min:$ng_min/desired:$ng_desired/max:$ng_max, capacity=$capacity_type, disk=${disk_size}GB, release=$ng_ami_release\""

            # Check version skew between nodegroup and control plane
            if [[ "$ng_version" != "$CLUSTER_K8S_VERSION" ]]; then
                add_suggestion "WARNING" \
                    "Node group '$ng_name' version ($ng_version) differs from control plane ($CLUSTER_K8S_VERSION)" \
                    "Update the node group to match the control plane version."
            fi

            # Check if node group needs K8s upgrade (version behind latest)
            if [[ "$ng_version" != "$LATEST_EKS_VERSION" && "$ng_version" == "$CLUSTER_K8S_VERSION" ]]; then
                add_suggestion "INFO" \
                    "Node group '$ng_name' K8s version ($ng_version) will need upgrade after control plane upgrade" \
                    "After upgrading the control plane, update this node group to match."
            fi

            # Check latest AMI release version for this nodegroup
            if [[ "$ng_ami_type" != "CUSTOM" && "$ng_ami_type" != "N/A" ]]; then
                local latest_ami_release
                latest_ami_release=$(aws ssm get-parameter \
                    --name "/aws/service/eks/optimized-ami/${ng_version}/$(echo "$ng_ami_type" | tr '[:upper:]' '[:lower:]' | sed 's/_/-/g')/recommended/release_version" \
                    --region "$REGION" \
                    --query 'Parameter.Value' \
                    --output text 2>/dev/null || echo "")

                if [[ -n "$latest_ami_release" && "$latest_ami_release" != "$ng_ami_release" && "$latest_ami_release" != "None" ]]; then
                    add_suggestion "WARNING" \
                        "Node group '$ng_name' AMI release ($ng_ami_release) is not the latest ($latest_ami_release)" \
                        "Update node group AMI to get latest security patches and bug fixes."
                    csv_row "\"NODE_GROUP\"" "\"ami_update\"" "\"\"" "\"$ng_name\"" "\"$ng_ami_release\"" "\"$latest_ami_release\"" "\"UPDATE_AVAILABLE\"" "\"New AMI release available\""
                fi
            fi
        done
    else
        output "  No managed node groups found."
        add_suggestion "INFO" \
            "No managed node groups detected" \
            "Cluster may be using self-managed nodes or Fargate profiles. Check manually."
    fi

    # Fargate Profiles
    sub_header "Fargate Profiles"
    local fargate_profiles
    fargate_profiles=$(aws eks list-fargate-profiles --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'fargateProfileNames' --output json 2>/dev/null || echo "[]")
    local fargate_count
    fargate_count=$(echo "$fargate_profiles" | jq -r 'length' 2>/dev/null || echo "0")

    output "  Total Fargate Profiles: $fargate_count"
    if [[ "$fargate_count" -gt 0 ]]; then
        output ""
        for fp_name in $(echo "$fargate_profiles" | jq -r '.[]'); do
            local fp_json
            fp_json=$(aws eks describe-fargate-profile --cluster-name "$CLUSTER_NAME" --fargate-profile-name "$fp_name" --region "$REGION" --output json 2>/dev/null)

            local fp_status fp_selectors
            fp_status=$(echo "$fp_json" | jq -r '.fargateProfile.status // "N/A"')
            fp_selectors=$(echo "$fp_json" | jq -r 'if (.fargateProfile.selectors | type) == "array" and (.fargateProfile.selectors | length) > 0 then [.fargateProfile.selectors[].namespace] | join(", ") else "N/A" end' 2>/dev/null || echo "N/A")

            output "  ┌─ Fargate Profile: ${BOLD}$fp_name${NC}"
            output "  │  Status      : $fp_status"
            output "  │  Namespaces  : $fp_selectors"
            output "  └──────────────────────────────────────"

            csv_row "\"NODE_GROUP\"" "\"fargate\"" "\"\"" "\"$fp_name\"" "\"Fargate\"" "\"\"" "\"$fp_status\"" "\"namespaces=$fp_selectors\""
        done
    fi

    # Nodes from kubectl
    sub_header "Nodes (kubectl)"
    output ""
    local nodes_json
    nodes_json=$(kubectl get nodes -o json 2>/dev/null)
    local node_count
    node_count=$(echo "$nodes_json" | jq -r '.items | length' 2>/dev/null || echo "0")

    output "  Total Nodes: $node_count"
    output ""

    if [[ "$node_count" -gt 0 ]]; then
        # Header
        printf "  %-40s %-8s %-18s %-15s %-20s %s\n" "NODE NAME" "STATUS" "KUBELET VERSION" "INSTANCE TYPE" "OS IMAGE" "ARCH" | tee -a "$REPORT_FILE"
        printf "  %-40s %-8s %-18s %-15s %-20s %s\n" "────────────────────────────────────────" "────────" "──────────────────" "───────────────" "────────────────────" "──────" | tee -a "$REPORT_FILE"

        # NOTE: fed via process substitution (not a pipe) so that add_suggestion
        # runs in this shell - a pipeline would put the loop in a subshell and
        # discard every suggestion and counter it produces.
        local al2_nodes=() skewed_nodes=()
        while IFS=$'\t' read -r name ready kubelet itype os arch; do
            local status_display status_plain
            if [[ "$ready" == "True" ]]; then
                status_display="${GREEN}Ready${NC}"
                status_plain="Ready"
            else
                status_display="${RED}NotReady${NC}"
                status_plain="NotReady"
                add_suggestion "CRITICAL" \
                    "Node $name is not in Ready state" \
                    "Investigate node health immediately."
            fi
            printf "  %-40s %-8b %-18s %-15s %-20s %s\n" "$name" "$status_display" "$kubelet" "$itype" "$os" "$arch"
            # Report file (no colors)
            printf "  %-40s %-8s %-18s %-15s %-20s %s\n" "$name" "$status_plain" "$kubelet" "$itype" "$os" "$arch" >> "$REPORT_FILE"

            # CSV: Node data
            csv_row "\"NODE\"" "\"node\"" "\"\"" "\"$name\"" "\"$kubelet\"" "\"\"" "\"$status_plain\"" "\"instance=$itype, os=$os, arch=$arch\""

            # Check if OS image indicates AL2 (not AL2023) - collected, reported once below
            if echo "$os" | grep -qi "Amazon Linux 2" && ! echo "$os" | grep -qi "2023"; then
                al2_nodes+=("$name")
            fi

            # Check kubelet version skew - collected, reported once below
            local kubelet_minor
            kubelet_minor=$(echo "$kubelet" | grep -oE '1\.[0-9]+' | head -1)
            if [[ -n "$kubelet_minor" && "$kubelet_minor" != "$CLUSTER_K8S_VERSION" ]]; then
                skewed_nodes+=("$name ($kubelet)")
            fi
        done < <(echo "$nodes_json" | jq -r '.items[] | [
            .metadata.name,
            (.status.conditions[] | select(.type=="Ready") | .status),
            .status.nodeInfo.kubeletVersion,
            (.metadata.labels["node.kubernetes.io/instance-type"] // "N/A"),
            .status.nodeInfo.osImage,
            .status.nodeInfo.architecture
        ] | @tsv' 2>/dev/null)

        # Aggregate node-level findings into one suggestion each instead of one per node
        if [[ ${#al2_nodes[@]} -gt 0 ]]; then
            add_suggestion "CRITICAL" \
                "${#al2_nodes[@]} of $node_count node(s) are running Amazon Linux 2 - UNSUPPORTED" \
                "AL2 EKS AMI support ended Nov 26, 2025. AL2 OS EOL: Jun 30, 2026. Migrate to AL2023. Nodes: ${al2_nodes[*]}"
        fi
        if [[ ${#skewed_nodes[@]} -gt 0 ]]; then
            add_suggestion "WARNING" \
                "${#skewed_nodes[@]} node(s) have a kubelet version differing from the control plane ($CLUSTER_K8S_VERSION)" \
                "Update these nodes to match the control plane. Nodes: ${skewed_nodes[*]}"
        fi
    fi

    # Node resource summary. HAS_METRICS_SERVER is consumed later by the HPA
    # check - an HPA without metrics-server silently never scales, and the two
    # facts were previously reported in separate sections with no link drawn.
    sub_header "Node Resource Summary"
    output ""
    local top_output
    top_output=$(kubectl top nodes 2>/dev/null || echo "")
    if [[ -n "$top_output" ]]; then
        HAS_METRICS_SERVER=true
        while IFS= read -r line; do
            output "  $line"
        done < <(echo "$top_output")
    else
        HAS_METRICS_SERVER=false
        output "  ${YELLOW}(metrics-server not available - kubectl top nodes failed)${NC}"
        add_suggestion "WARNING" \
            "metrics-server is not installed or not responding" \
            "Without it 'kubectl top' returns nothing, HorizontalPodAutoscalers cannot scale, and you have no CPU/memory data to size nodes with - which you need before planning an AL2023 migration. Install: kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
    fi

    # AL2 → AL2023 Migration Summary
    sub_header "AL2 → AL2023 Migration Reference"
    output ""
    output "  ${BOLD}Amazon Linux 2 (AL2) EKS AMI Timeline:${NC}"
    output "  ├─ ${RED}EKS AMI support ended : Nov 26, 2025${NC}"
    output "  ├─ ${RED}AL2 OS End of Life    : Jun 30, 2026${NC}"
    output "  └─ ${GREEN}AL2023 is the default since EKS 1.30+${NC}"
    output ""
    output "  ${BOLD}AL2 → AL2023 Key Differences:${NC}"
    output "  ├─ cgroup v1 → ${CYAN}cgroup v2${NC} (check monitoring tools compatibility)"
    output "  ├─ IMDSv1 allowed → ${CYAN}IMDSv2 enforced${NC} (check SDK/app IMDS calls)"
    output "  ├─ bootstrap.sh → ${CYAN}nodeadm (YAML-based)${NC} (update user data scripts)"
    output "  ├─ yum → ${CYAN}dnf${NC} (update package manager commands)"
    output "  ├─ Amazon Linux extras → ${CYAN}not available${NC} (use dnf packages)"
    output "  └─ kernel 5.10 → ${CYAN}kernel 6.1${NC} (check kernel module compatibility)"
    output ""
    output "  ${BOLD}Migration Strategy (No in-place upgrade supported):${NC}"
    output "  1. Create new node group with AL2023 AMI type"
    output "  2. Cordon old AL2 nodes (kubectl cordon <node>)"
    output "  3. Drain old AL2 nodes (kubectl drain <node> --ignore-daemonsets --delete-emptydir-data)"
    output "  4. Verify workloads on new AL2023 nodes"
    output "  5. Delete old AL2 node group"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 3: EKS ADD-ONS
# ─────────────────────────────────────────────────────────────────────────────

discover_addons() {
    section_header "SECTION 3: EKS ADD-ONS" "🔌"

    # Managed Add-ons
    sub_header "Managed EKS Add-ons"
    local addons_json
    addons_json=$(aws eks list-addons --cluster-name "$CLUSTER_NAME" --region "$REGION" --output json 2>/dev/null)
    local addon_list
    addon_list=$(echo "$addons_json" | jq -r '.addons[]' 2>/dev/null)

    if [[ -n "$addon_list" ]]; then
        output ""
        for addon_name in $addon_list; do
            local addon_detail
            addon_detail=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$addon_name" --region "$REGION" --output json 2>/dev/null)

            local addon_version addon_status addon_health
            addon_version=$(echo "$addon_detail" | jq -r '.addon.addonVersion // "N/A"')
            addon_status=$(echo "$addon_detail" | jq -r '.addon.status // "N/A"')
            addon_health=$(echo "$addon_detail" | jq -r '.addon.health.issues | length // 0' 2>/dev/null || echo "0")

            # Check for available updates
            local latest_version
            latest_version=$(aws eks describe-addon-versions \
                --addon-name "$addon_name" \
                --kubernetes-version "$CLUSTER_K8S_VERSION" \
                --region "$REGION" \
                --query 'addons[0].addonVersions[0].addonVersion' \
                --output text 2>/dev/null || echo "N/A")

            local update_available="No"
            if [[ "$latest_version" != "N/A" && "$latest_version" != "$addon_version" ]]; then
                update_available="${YELLOW}Yes → $latest_version${NC}"
                add_suggestion "WARNING" \
                    "Add-on '$addon_name' has an update available: $addon_version → $latest_version" \
                    "Update via: aws eks update-addon --cluster-name $CLUSTER_NAME --addon-name $addon_name --addon-version $latest_version"
            fi

            local status_color
            if [[ "$addon_status" == "ACTIVE" ]]; then
                status_color="${GREEN}$addon_status${NC}"
            elif [[ "$addon_status" == "DEGRADED" ]]; then
                status_color="${RED}$addon_status${NC}"
                add_suggestion "CRITICAL" \
                    "Add-on '$addon_name' is in DEGRADED state" \
                    "Check add-on health: aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name $addon_name"
            else
                status_color="${YELLOW}$addon_status${NC}"
            fi

            output "  ┌─ Add-on: ${BOLD}$addon_name${NC}"
            output "  │  Version         : $addon_version"
            output "  │  Status          : $status_color"
            output "  │  Health Issues   : $addon_health"
            output "  │  Update Available: $update_available"
            output "  └──────────────────────────────────────"

            # CSV: Addon data
            csv_row "\"ADDON\"" "\"managed\"" "\"kube-system\"" "\"$addon_name\"" "\"$addon_version\"" "\"$latest_version\"" "\"$addon_status\"" "\"health_issues=$addon_health\""
        done
    else
        output "  No managed add-ons found."
        output ""
        add_suggestion "INFO" \
            "No managed EKS add-ons detected" \
            "Consider using managed add-ons (vpc-cni, coredns, kube-proxy) for easier lifecycle management."
    fi

    # ── Core components: running version vs AWS-recommended version ──
    #
    # The previous version of this section only printed the image string, so a
    # component running five minor versions behind the control plane looked
    # identical to an up-to-date one. Each component below is checked against
    # the version AWS recommends for this cluster's Kubernetes version, and
    # flagged when it is self-managed (i.e. not in the managed add-on list),
    # since self-managed components never surface in the add-on update check.
    sub_header "Core Component Versions (running vs recommended)"
    output ""
    printf "  %-14s %-13s %-28s %-24s %s\n" "COMPONENT" "MANAGED BY" "RUNNING" "RECOMMENDED" "STATUS" | tee -a "$REPORT_FILE"
    printf "  %-14s %-13s %-28s %-24s %s\n" "──────────────" "─────────────" "────────────────────────────" "────────────────────────" "──────────" | tee -a "$REPORT_FILE"

    # addon_name : kubectl resource : display label
    local core_components=(
        "coredns:deploy/coredns:CoreDNS"
        "kube-proxy:ds/kube-proxy:kube-proxy"
        "vpc-cni:ds/aws-node:VPC CNI"
        "aws-ebs-csi-driver:deploy/ebs-csi-controller:EBS CSI"
        "aws-efs-csi-driver:deploy/efs-csi-controller:EFS CSI"
    )

    local cc_entry cc_addon cc_res cc_label
    for cc_entry in "${core_components[@]}"; do
        IFS=':' read -r cc_addon cc_res cc_label <<< "$cc_entry"

        local cc_image
        cc_image=$(kubectl get "$cc_res" -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
        # Not installed at all - skip silently (EFS CSI is optional)
        [[ -z "$cc_image" ]] && continue

        # Tag is everything after the last ':' (ECR registries carry no port)
        local cc_running="${cc_image##*:}"
        [[ "$cc_running" == "$cc_image" ]] && cc_running="untagged"

        # Is it a managed add-on, or self-managed?
        local cc_managed="self-managed"
        if echo "$addon_list" | grep -qx "$cc_addon"; then
            cc_managed="EKS add-on"
        fi

        local cc_recommended
        cc_recommended=$(aws eks describe-addon-versions \
            --addon-name "$cc_addon" \
            --kubernetes-version "$CLUSTER_K8S_VERSION" \
            --region "$REGION" \
            --query 'addons[0].addonVersions[0].addonVersion' \
            --output text 2>/dev/null || echo "N/A")

        local cc_status cc_status_plain
        if [[ "$cc_recommended" == "N/A" || "$cc_recommended" == "None" || "$cc_running" == "untagged" ]]; then
            cc_status="${YELLOW}unknown${NC}"
            cc_status_plain="UNKNOWN"
        else
            local run_base rec_base run_mm rec_mm
            run_base=$(normalize_component_version "$cc_running")
            rec_base=$(normalize_component_version "$cc_recommended")
            run_mm=$(major_minor "$run_base")
            rec_mm=$(major_minor "$rec_base")

            if [[ "$run_base" == "$rec_base" ]]; then
                cc_status="${GREEN}current${NC}"
                cc_status_plain="CURRENT"
            elif [[ "$run_mm" != "$rec_mm" ]]; then
                # Differs by more than a patch release - this is the case that
                # matters, and the one the old code could not see at all.
                cc_status="${RED}OUTDATED${NC}"
                cc_status_plain="OUTDATED"
                add_suggestion "CRITICAL" \
                    "$cc_label is significantly out of date: $cc_running (recommended for K8s $CLUSTER_K8S_VERSION: $cc_recommended)" \
                    "Running as $cc_managed. A component several minor versions behind the control plane is unsupported and is a likely blocker for upgrading past K8s $CLUSTER_K8S_VERSION. Upgrade before any cluster version bump."
            else
                cc_status="${YELLOW}patch behind${NC}"
                cc_status_plain="PATCH_BEHIND"
                add_suggestion "WARNING" \
                    "$cc_label is behind on patch releases: $cc_running → $cc_recommended" \
                    "Running as $cc_managed. Update to pick up security and bug fixes."
            fi
        fi

        # Self-managed core components have no lifecycle management at all
        if [[ "$cc_managed" == "self-managed" ]]; then
            add_suggestion "WARNING" \
                "$cc_label is self-managed, not an EKS managed add-on" \
                "It will never appear in add-on update checks and must be upgraded by hand. Convert with: aws eks create-addon --cluster-name $CLUSTER_NAME --addon-name $cc_addon --region $REGION --resolve-conflicts OVERWRITE"
        fi

        printf "  %-14s %-13s %-28s %-24s %b\n" "$cc_label" "$cc_managed" "$cc_running" "$cc_recommended" "$cc_status"
        printf "  %-14s %-13s %-28s %-24s %s\n" "$cc_label" "$cc_managed" "$cc_running" "$cc_recommended" "$cc_status_plain" >> "$REPORT_FILE"

        csv_row "\"ADDON\"" "\"core_component\"" "\"kube-system\"" "\"$cc_label\"" "\"$cc_running\"" "\"$cc_recommended\"" "\"$cc_status_plain\"" "\"managed_by=$cc_managed, image=$cc_image\""
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 4: APPLICATION DISCOVERY
# ─────────────────────────────────────────────────────────────────────────────

discover_applications() {
    section_header "SECTION 4: APPLICATIONS & WORKLOADS" "📦"

    # Namespaces
    sub_header "Namespaces"
    output ""
    local ns_list
    ns_list=$(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null)
    local ns_count
    ns_count=$(echo "$ns_list" | wc -l | tr -d ' ')
    output "  Total Namespaces: $ns_count"
    output ""
    while IFS=$'\t' read -r ns_name ns_phase; do
        if [[ -n "$ns_name" ]]; then
            output "  - $ns_name ($ns_phase)"
            csv_row "\"NAMESPACE\"" "\"namespace\"" "\"$ns_name\"" "\"$ns_name\"" "\"$ns_phase\"" "\"\"" "\"$ns_phase\"" "\"\""
        fi
    done <<< "$ns_list"

    # Deployments
    sub_header "Deployments"
    output ""
    local deploy_json
    deploy_json=$(kubectl get deployments -A -o json 2>/dev/null)
    local deploy_count
    deploy_count=$(echo "$deploy_json" | jq -r '.items | length' 2>/dev/null || echo "0")
    output "  Total Deployments: $deploy_count"
    output ""

    if [[ "$deploy_count" -gt 0 ]]; then
        printf "  %-25s %-40s %-8s %-8s %s\n" "NAMESPACE" "NAME" "READY" "AVAIL" "IMAGES" | tee -a "$REPORT_FILE"
        printf "  %-25s %-40s %-8s %-8s %s\n" "─────────────────────────" "────────────────────────────────────────" "────────" "────────" "──────────────────────" | tee -a "$REPORT_FILE"

        # NOTE: process substitution, not a pipe - see the nodes loop above.
        local single_replica=()
        while IFS=$'\t' read -r ns name ready avail images; do
            printf "  %-25s %-40s %-8s %-8s %s\n" "$ns" "$name" "$ready" "$avail" "$images" | tee -a "$REPORT_FILE"

            # CSV: Deployment data
            csv_row "\"DEPLOYMENT\"" "\"deployment\"" "\"$ns\"" "\"$name\"" "\"$images\"" "\"\"" "\"ready=$ready\"" "\"available=$avail\""

            local ready_count desired_count
            ready_count=$(echo "$ready" | cut -d'/' -f1)
            desired_count=$(echo "$ready" | cut -d'/' -f2)

            # Check single replica - collected, reported once below
            if [[ "$desired_count" == "1" && "$ns" != "kube-system" ]]; then
                single_replica+=("$ns/$name")
            fi

            # Check for :latest or untagged image. Check each image separately:
            # a single grep over the joined list cannot tell which image is bad.
            local bad_images=""
            local img
            for img in ${images//,/ }; do
                [[ -z "$img" ]] && continue
                # Strip any digest, then look for a tag on the final path segment
                local ref="${img%%@*}"
                if [[ "$ref" == *:latest ]]; then
                    bad_images+="${bad_images:+, }$img (:latest)"
                elif [[ "${ref##*/}" != *:* ]]; then
                    bad_images+="${bad_images:+, }$img (untagged)"
                fi
            done
            if [[ -n "$bad_images" ]]; then
                add_suggestion "WARNING" \
                    "Deployment '$name' in '$ns' uses ':latest' or untagged image" \
                    "Images: $bad_images. Use specific version tags for reproducibility."
            fi

            # Check if not all replicas ready
            if [[ "$ready_count" != "$desired_count" ]]; then
                add_suggestion "WARNING" \
                    "Deployment '$name' in '$ns' has insufficient ready replicas ($ready)" \
                    "Investigate why not all replicas are ready."
            fi
        done < <(echo "$deploy_json" | jq -r '.items[] | [
            .metadata.namespace,
            .metadata.name,
            ((.status.readyReplicas // 0) | tostring) + "/" + ((.spec.replicas // 0) | tostring),
            (.status.availableReplicas // 0 | tostring),
            ([.spec.template.spec.containers[]?.image] | join(", "))
        ] | @tsv' 2>/dev/null | sort)

        # Aggregate single-replica findings into one suggestion instead of one per deployment
        if [[ ${#single_replica[@]} -gt 0 ]]; then
            add_suggestion "INFO" \
                "${#single_replica[@]} deployment(s) run with only 1 replica" \
                "No HA and guaranteed downtime during node drain/upgrade. Consider 2+ replicas and a PodDisruptionBudget. Deployments: ${single_replica[*]}"
        fi
    fi

    # StatefulSets
    sub_header "StatefulSets"
    output ""
    local sts_json
    sts_json=$(kubectl get statefulsets -A -o json 2>/dev/null)
    local sts_count
    sts_count=$(echo "$sts_json" | jq -r '.items | length' 2>/dev/null || echo "0")
    output "  Total StatefulSets: $sts_count"
    if [[ "$sts_count" -gt 0 ]]; then
        output ""
        kubectl get statefulsets -A 2>/dev/null | while IFS= read -r line; do
            output "  $line"
        done
        # CSV for StatefulSets. Also flag unhealthy ones - StatefulSets carry
        # the stateful workloads (databases, queues, agents), so one sitting at
        # 0 ready replicas matters more than a Deployment doing the same, and
        # nothing checked for it before.
        while IFS=$'\t' read -r ns name ready images; do
            csv_row "\"STATEFULSET\"" "\"statefulset\"" "\"$ns\"" "\"$name\"" "\"$images\"" "\"\"" "\"ready=$ready\"" "\"\""

            local sts_ready sts_desired
            sts_ready="${ready%%/*}"
            sts_desired="${ready##*/}"
            if [[ "$sts_desired" != "0" && "$sts_ready" != "$sts_desired" ]]; then
                local sts_sev="WARNING"
                [[ "$sts_ready" == "0" ]] && sts_sev="CRITICAL"
                add_suggestion "$sts_sev" \
                    "StatefulSet '$name' in '$ns' has insufficient ready replicas ($ready)" \
                    "Investigate: kubectl -n $ns describe sts $name; kubectl -n $ns logs sts/$name"
            fi
        done < <(echo "$sts_json" | jq -r '.items[]? | [.metadata.namespace, .metadata.name, ((.status.readyReplicas // 0) | tostring) + "/" + ((.spec.replicas // 0) | tostring), ([.spec.template.spec.containers[]?.image] | join(", "))] | @tsv' 2>/dev/null)
    fi

    # DaemonSets
    sub_header "DaemonSets"
    output ""
    local ds_json
    ds_json=$(kubectl get daemonsets -A -o json 2>/dev/null)
    local ds_count
    ds_count=$(echo "$ds_json" | jq -r '.items | length' 2>/dev/null || echo "0")
    output "  Total DaemonSets: $ds_count"
    if [[ "$ds_count" -gt 0 ]]; then
        output ""
        kubectl get daemonsets -A 2>/dev/null | while IFS= read -r line; do
            output "  $line"
        done
        echo "$ds_json" | jq -r '.items[]? | [.metadata.namespace, .metadata.name, (.status.desiredNumberScheduled | tostring), ([.spec.template.spec.containers[]?.image] | join(", "))] | @tsv' 2>/dev/null | while IFS=$'\t' read -r ns name desired images; do
            csv_row "\"DAEMONSET\"" "\"daemonset\"" "\"$ns\"" "\"$name\"" "\"$images\"" "\"\"" "\"desired=$desired\"" "\"\""
        done
    fi

    # CronJobs & Jobs
    sub_header "CronJobs & Jobs"
    output ""
    local cj_count
    cj_count=$(kubectl get cronjobs -A --no-headers 2>/dev/null | grep -c '[^ ]' 2>/dev/null || true)
    local job_count
    job_count=$(kubectl get jobs -A --no-headers 2>/dev/null | grep -c '[^ ]' 2>/dev/null || true)
    output "  Total CronJobs: $cj_count"
    output "  Total Jobs    : $job_count"
    if [[ "$cj_count" -gt 0 ]]; then
        output ""
        kubectl get cronjobs -A 2>/dev/null | while IFS= read -r line; do
            output "  $line"
        done
    fi

    # Services
    sub_header "Services"
    output ""
    local svc_output
    svc_output=$(kubectl get services -A --no-headers 2>/dev/null)
    local svc_count
    svc_count=$(echo "$svc_output" | grep -c '[^ ]' 2>/dev/null || true)
    output "  Total Services: $svc_count"
    output ""
    kubectl get services -A 2>/dev/null | while IFS= read -r line; do
        output "  $line"
    done

    # Check for LoadBalancer services
    local lb_count
    lb_count=$(echo "$svc_output" | grep -c "LoadBalancer" 2>/dev/null || true)
    if [[ "$lb_count" -gt 0 ]]; then
        output ""
        output "  ${CYAN}LoadBalancer services detected: $lb_count${NC}"
    fi

    # CSV: Services
    kubectl get services -A -o json 2>/dev/null | jq -r '.items[]? | [.metadata.namespace, .metadata.name, .spec.type, (if .spec.ports != null then (.spec.ports | map(.port | tostring) | join(";")) else "none" end), (.spec.clusterIP // "N/A")] | @tsv' 2>/dev/null | while IFS=$'\t' read -r ns name stype ports cip; do
        csv_row "\"SERVICE\"" "\"service\"" "\"$ns\"" "\"$name\"" "\"type=$stype\"" "\"\"" "\"\"" "\"ports=$ports, clusterIP=$cip\""
    done

    # Ingresses
    sub_header "Ingresses"
    output ""
    local ingress_output
    ingress_output=$(kubectl get ingress -A --no-headers 2>/dev/null)
    local ingress_count
    ingress_count=$(echo "$ingress_output" | grep -c '[^ ]' 2>/dev/null || true)
    output "  Total Ingresses: $ingress_count"
    if [[ "$ingress_count" -gt 0 ]]; then
        output ""
        kubectl get ingress -A 2>/dev/null | while IFS= read -r line; do
            output "  $line"
        done
    fi

    # PVCs
    sub_header "Persistent Volume Claims"
    output ""
    local pvc_output
    pvc_output=$(kubectl get pvc -A --no-headers 2>/dev/null)
    local pvc_count
    pvc_count=$(echo "$pvc_output" | grep -c '[^ ]' 2>/dev/null || true)
    output "  Total PVCs: $pvc_count"
    if [[ "$pvc_count" -gt 0 ]]; then
        output ""
        kubectl get pvc -A 2>/dev/null | while IFS= read -r line; do
            output "  $line"
        done
    fi

    # Helm Releases
    if [[ "$HAS_HELM" == true ]]; then
        sub_header "Helm Releases"
        output ""
        local helm_output
        helm_output=$(helm list -A --output json 2>/dev/null)
        local helm_count
        helm_count=$(echo "$helm_output" | jq -r 'length' 2>/dev/null || echo "0")
        output "  Total Helm Releases: $helm_count"

        if [[ "$CHECK_CHARTS" == true ]]; then
            output "  Chart currency check: ${CYAN}enabled${NC} (queries artifacthub.io)"
        else
            output "  Chart currency check: disabled (re-run with --check-charts to compare against upstream)"
        fi

        if [[ "$helm_count" -gt 0 ]]; then
            output ""
            printf "  %-27s %-26s %-34s %-13s %-15s %s\n" "NAMESPACE" "NAME" "CHART" "APP VERSION" "STATUS" "LATEST CHART" | tee -a "$REPORT_FILE"
            printf "  %-27s %-26s %-34s %-13s %-15s %s\n" "───────────────────────────" "──────────────────────────" "──────────────────────────────────" "─────────────" "───────────────" "────────────" | tee -a "$REPORT_FILE"

            local stuck_releases=()
            while IFS=$'\t' read -r ns name chart appver status; do
                [[ -z "$ns" ]] && continue

                # Split "ingress-nginx-4.7.1" into chart name + chart version.
                # Handles v-prefixes and build metadata: "cert-manager-v1.17.1",
                # "fleet-crd-105.0.4+up0.11.4".
                local chart_name chart_ver
                chart_name=$(echo "$chart" | sed -E 's/-(v?[0-9]+\.[0-9]+.*)$//')
                chart_ver=$(echo "$chart" | sed -E 's/^.*-(v?[0-9]+\.[0-9]+.*)$/\1/')
                [[ "$chart_ver" == "$chart" ]] && chart_ver=""

                # A release that is not "deployed" is mid-failure: a stuck
                # pending-upgrade blocks every later helm operation on it.
                if [[ "$status" != "deployed" ]]; then
                    stuck_releases+=("$ns/$name ($status)")
                fi

                # Keep a colourless twin of the status cell: the colour codes are
                # literal "\033..." strings here, so stripping them after the
                # fact would not work for the report file.
                local latest_chart="" latest_app="" chart_deprecated=""
                local latest_display="-" latest_plain="-"
                if [[ "$CHECK_CHARTS" == true && -n "$chart_ver" ]]; then
                    local ah_pkg
                    ah_pkg=$(chart_to_artifacthub "$chart_name")
                    if [[ -n "$ah_pkg" ]]; then
                        IFS=$'\t' read -r latest_chart latest_app chart_deprecated <<< "$(artifacthub_latest "$ah_pkg")"
                        if [[ -z "$latest_chart" ]]; then
                            latest_display="(lookup failed)"; latest_plain="(lookup failed)"
                        elif [[ "$chart_deprecated" == "true" ]]; then
                            # Deprecated wins over "N versions behind": a frozen
                            # chart can even read as up-to-date, and telling
                            # someone to upgrade to a dead chart is wrong advice.
                            latest_display="${RED}DEPRECATED${NC}"; latest_plain="DEPRECATED"
                            add_suggestion "WARNING" \
                                "Helm chart '$chart_name' (release '$name' in $ns) is marked DEPRECATED upstream" \
                                "No further releases will be published - this needs migrating to a replacement chart, not upgrading. Last published: chart $latest_chart (app ${latest_app:-unknown}), currently on chart $chart_ver (app ${appver:-unknown})."
                        else
                            local cur_mm new_mm
                            cur_mm=$(major_minor "$(normalize_component_version "$chart_ver")")
                            new_mm=$(major_minor "$(normalize_component_version "$latest_chart")")

                            if [[ "$(normalize_component_version "$chart_ver")" == "$(normalize_component_version "$latest_chart")" ]]; then
                                latest_display="${GREEN}current${NC}"; latest_plain="current"
                            elif [[ "$cur_mm" != "$new_mm" ]]; then
                                latest_display="${YELLOW}${latest_chart}${NC}"; latest_plain="$latest_chart"
                                add_suggestion "WARNING" \
                                    "Helm release '$name' ($ns) is on an outdated chart: $chart_name $chart_ver → $latest_chart" \
                                    "App version ${appver:-unknown} → ${latest_app:-unknown}. Upgrade: helm repo update && helm upgrade $name <repo>/$chart_name --version <target> -n $ns. Back up first: helm get values $name -n $ns -o yaml"
                            else
                                latest_display="${CYAN}${latest_chart}${NC}"; latest_plain="$latest_chart"
                                add_suggestion "INFO" \
                                    "Helm release '$name' ($ns) is a patch release behind: $chart_name $chart_ver → $latest_chart" \
                                    "App version ${appver:-unknown} → ${latest_app:-unknown}."
                            fi
                        fi
                    else
                        # Vendor-specific charts (Rancher's 105.x line, etc.) have
                        # no meaningful upstream to compare against.
                        latest_display="(no upstream)"; latest_plain="(no upstream)"
                    fi
                fi

                printf "  %-27s %-26s %-34s %-13s %-15s %b\n" "$ns" "$name" "$chart" "$appver" "$status" "$latest_display"
                printf "  %-27s %-26s %-34s %-13s %-15s %s\n" "$ns" "$name" "$chart" "$appver" "$status" "$latest_plain" >> "$REPORT_FILE"

                csv_row "\"HELM\"" "\"helm_release\"" "\"$ns\"" "\"$name\"" "\"$chart\"" "\"$latest_chart\"" "\"$status\"" "\"app_version=$appver, latest_app=$latest_app\""
            done < <(echo "$helm_output" | jq -r '.[]? | [.namespace, .name, .chart, .app_version, .status] | @tsv' 2>/dev/null | sort)

            if [[ ${#stuck_releases[@]} -gt 0 ]]; then
                add_suggestion "WARNING" \
                    "${#stuck_releases[@]} Helm release(s) are not in 'deployed' state" \
                    "A release stuck in pending-upgrade/pending-rollback/failed blocks all further helm operations on it until resolved (helm rollback, or delete the stuck revision secret). Releases: ${stuck_releases[*]}"
            fi
        fi
    fi

    # ArgoCD Applications (if installed)
    sub_header "ArgoCD Applications"
    output ""
    local argocd_apps
    argocd_apps=$(kubectl get applications.argoproj.io -A -o json 2>/dev/null)
    local argocd_count
    argocd_count=$(echo "$argocd_apps" | jq -r '.items | length' 2>/dev/null || echo "0")
    output "  Total ArgoCD Applications: $argocd_count"
    if [[ "$argocd_count" -gt 0 ]]; then
        output ""
        kubectl get applications.argoproj.io -A 2>/dev/null | while IFS= read -r line; do
            output "  $line"
        done
        # CSV + health/sync assessment. If ArgoCD is the deployment path into
        # production, an app it cannot see or reconcile means the cluster's
        # real state has drifted from git - previously reported as raw text
        # only, with no suggestion raised.
        local argo_unknown=() argo_outofsync=() argo_unhealthy=()
        while IFS=$'\t' read -r ns name sync health repo; do
            csv_row "\"ARGOCD\"" "\"application\"" "\"$ns\"" "\"$name\"" "\"sync=$sync\"" "\"\"" "\"health=$health\"" "\"repo=$repo\""

            case "$sync" in
                Synced)    ;;
                OutOfSync) argo_outofsync+=("$name") ;;
                *)         argo_unknown+=("$name") ;;
            esac
            case "$health" in
                Healthy|Progressing) ;;
                *) argo_unhealthy+=("$name ($health)") ;;
            esac
        done < <(echo "$argocd_apps" | jq -r '.items[]? | [.metadata.namespace, .metadata.name, (.status.sync.status // "N/A"), (.status.health.status // "N/A"), (.spec.source.repoURL // "N/A")] | @tsv' 2>/dev/null)

        if [[ ${#argo_unhealthy[@]} -gt 0 ]]; then
            add_suggestion "CRITICAL" \
                "${#argo_unhealthy[@]} ArgoCD application(s) are in a Degraded/Missing health state" \
                "Apps: ${argo_unhealthy[*]}"
        fi
        if [[ ${#argo_unknown[@]} -gt 0 ]]; then
            add_suggestion "WARNING" \
                "${#argo_unknown[@]} ArgoCD application(s) have Unknown sync status" \
                "ArgoCD cannot reach the source repo or the app is orphaned - it is no longer reconciling, so drift goes unnoticed. Check repo access/credentials for: ${argo_unknown[*]}"
        fi
        if [[ ${#argo_outofsync[@]} -gt 0 ]]; then
            add_suggestion "WARNING" \
                "${#argo_outofsync[@]} ArgoCD application(s) are OutOfSync" \
                "Live state differs from git. Determine whether this is manual drift on the cluster or an un-synced commit before the next sync overwrites it. Apps: ${argo_outofsync[*]}"
        fi
    else
        output "  ${YELLOW}(ArgoCD CRDs not found or no applications)${NC}"
    fi

    # Container Image Summary
    sub_header "Container Image Inventory"
    output ""
    local all_images
    all_images=$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | sort | uniq -c | sort -rn)
    local unique_image_count
    unique_image_count=$(echo "$all_images" | grep -c '[^ ]' 2>/dev/null || true)
    output "  Unique Container Images: $unique_image_count"
    output ""
    output "  COUNT  IMAGE"
    output "  ─────  ──────────────────────────────────────────────────"
    # Text report is capped at 50 rows for readability, but the CSV gets every
    # image - it is the machine-readable copy, and truncating it also made the
    # HTML "unique images" card under-report.
    local shown=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local img_count img_name
        img_count=$(echo "$line" | awk '{print $1}')
        img_name=$(echo "$line" | awk '{print $2}')
        csv_row "\"IMAGE\"" "\"container_image\"" "\"\"" "\"$img_name\"" "\"count=$img_count\"" "\"\"" "\"\"" "\"\""
        if [[ "$shown" -lt 50 ]]; then
            output "  $line"
            ((shown++)) || true
        fi
    done < <(echo "$all_images")
    if [[ "$unique_image_count" -gt 50 ]]; then
        output "  ... and $((unique_image_count - 50)) more (full list in the CSV report)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 5: SECURITY & BEST PRACTICES
# ─────────────────────────────────────────────────────────────────────────────

discover_security() {
    section_header "SECTION 5: SECURITY & BEST PRACTICES" "🔒"

    # Pods without resource limits
    sub_header "Pods without Resource Limits/Requests"
    output ""
    local pods_no_limits
    pods_no_limits=$(kubectl get pods -A -o json 2>/dev/null | jq -r '
        .items[] |
        select(.metadata.namespace != "kube-system") |
        .metadata.namespace as $ns |
        .metadata.name as $pod |
        .spec.containers[] |
        select(.resources.limits == null or .resources.requests == null) |
        "\($ns)\t\($pod)\t\(.name)"
    ' 2>/dev/null)
    local no_limits_count
    no_limits_count=$(echo "$pods_no_limits" | grep -c '[^ ]' 2>/dev/null || true)

    output "  Pods/Containers without limits: $no_limits_count"
    if [[ "$no_limits_count" -gt 0 ]]; then
        output ""
        printf "  %-25s %-45s %s\n" "NAMESPACE" "POD" "CONTAINER" | tee -a "$REPORT_FILE"
        printf "  %-25s %-45s %s\n" "─────────────────────────" "─────────────────────────────────────────────" "──────────────" | tee -a "$REPORT_FILE"
        echo "$pods_no_limits" | head -30 | while IFS=$'\t' read -r ns pod container; do
            printf "  %-25s %-45s %s\n" "$ns" "$pod" "$container" | tee -a "$REPORT_FILE"
            csv_row "\"SECURITY\"" "\"no_resource_limits\"" "\"$ns\"" "\"$pod\"" "\"container=$container\"" "\"Set resource limits\"" "\"WARNING\"" "\"\""
        done
        if [[ "$no_limits_count" -gt 30 ]]; then
            output "  ... and $((no_limits_count - 30)) more"
        fi
        add_suggestion "WARNING" \
            "$no_limits_count pod/container(s) running without resource limits" \
            "Set resource requests and limits to prevent resource contention and enable HPA."
    fi

    # Pods without health checks (liveness/readiness probes)
    sub_header "Pods without Health Checks"
    output ""
    local pods_no_probes
    pods_no_probes=$(kubectl get pods -A -o json 2>/dev/null | jq -r '
        .items[] |
        select(.metadata.namespace != "kube-system") |
        .metadata.namespace as $ns |
        .metadata.name as $pod |
        .spec.containers[] |
        select(.livenessProbe == null and .readinessProbe == null) |
        "\($ns)\t\($pod)\t\(.name)"
    ' 2>/dev/null)
    local no_probes_count
    no_probes_count=$(echo "$pods_no_probes" | grep -c '[^ ]' 2>/dev/null || true)

    output "  Pods/Containers without probes: $no_probes_count"
    if [[ "$no_probes_count" -gt 0 ]]; then
        output ""
        printf "  %-25s %-45s %s\n" "NAMESPACE" "POD" "CONTAINER" | tee -a "$REPORT_FILE"
        printf "  %-25s %-45s %s\n" "─────────────────────────" "─────────────────────────────────────────────" "──────────────" | tee -a "$REPORT_FILE"
        echo "$pods_no_probes" | head -20 | while IFS=$'\t' read -r ns pod container; do
            printf "  %-25s %-45s %s\n" "$ns" "$pod" "$container" | tee -a "$REPORT_FILE"
            csv_row "\"SECURITY\"" "\"no_health_checks\"" "\"$ns\"" "\"$pod\"" "\"container=$container\"" "\"Add liveness/readiness probes\"" "\"WARNING\"" "\"\""
        done
        if [[ "$no_probes_count" -gt 20 ]]; then
            output "  ... and $((no_probes_count - 20)) more"
        fi
        add_suggestion "WARNING" \
            "$no_probes_count pod/container(s) running without liveness/readiness probes" \
            "Add health checks to ensure Kubernetes can detect and restart unhealthy pods."
    fi

    # Privileged containers
    sub_header "Privileged Containers"
    output ""
    local privileged_pods
    privileged_pods=$(kubectl get pods -A -o json 2>/dev/null | jq -r '
        .items[] |
        .metadata.namespace as $ns |
        .metadata.name as $pod |
        .spec.containers[] |
        select(.securityContext.privileged == true) |
        "\($ns)\t\($pod)\t\(.name)"
    ' 2>/dev/null)
    local priv_count
    priv_count=$(echo "$privileged_pods" | grep -c '[^ ]' 2>/dev/null || true)

    # Split by namespace: CSI node drivers and kube-proxy are legitimately
    # privileged and run on every node, so a raw cluster-wide total is
    # dominated by them (nodes x system DaemonSets) and buries the handful of
    # workload containers that actually warrant review.
    local priv_system=0 priv_workload=0
    local priv_workload_list=()
    if [[ "$priv_count" -gt 0 ]]; then
        output ""
        while IFS=$'\t' read -r ns pod container; do
            [[ -z "$ns" ]] && continue
            csv_row "\"SECURITY\"" "\"privileged\"" "\"$ns\"" "\"$pod\"" "\"container=$container\"" "\"Remove privileged mode\"" "\"WARNING\"" "\"\""
            if [[ "$ns" == "kube-system" ]]; then
                ((priv_system++)) || true
            else
                ((priv_workload++)) || true
                output "  - $ns / $pod / $container"
                priv_workload_list+=("$ns/$pod/$container")
            fi
        done < <(echo "$privileged_pods")

        output ""
        output "  Total privileged            : $priv_count"
        output "  ├─ kube-system (expected)   : $priv_system  (CSI node drivers, kube-proxy - one set per node)"
        output "  └─ ${BOLD}workload namespaces${NC}      : $priv_workload  ${BOLD}← review these${NC}"

        if [[ "$priv_workload" -gt 0 ]]; then
            add_suggestion "WARNING" \
                "$priv_workload container(s) outside kube-system run in privileged mode" \
                "A privileged container can escape to the host. Review whether each truly needs it, or replace with specific capabilities. Containers: ${priv_workload_list[*]}"
        else
            add_suggestion "INFO" \
                "All $priv_count privileged containers are in kube-system (expected system components)" \
                "No workload container runs privileged - nothing to act on here."
        fi
    fi

    # Containers running as root
    sub_header "Containers Running as Root"
    output ""
    local root_pods
    root_pods=$(kubectl get pods -A -o json 2>/dev/null | jq -r '
        .items[] |
        select(.metadata.namespace != "kube-system") |
        .metadata.namespace as $ns |
        .metadata.name as $pod |
        .spec.containers[] |
        select(
            (.securityContext.runAsNonRoot == null or .securityContext.runAsNonRoot == false) and
            (.securityContext.runAsUser == null or .securityContext.runAsUser == 0)
        ) |
        "\($ns)\t\($pod)\t\(.name)"
    ' 2>/dev/null)
    local root_count
    root_count=$(echo "$root_pods" | grep -c '[^ ]' 2>/dev/null || true)

    output "  Containers potentially running as root: $root_count"
    if [[ "$root_count" -gt 0 && "$root_count" -lt 50 ]]; then
        add_suggestion "INFO" \
            "$root_count container(s) potentially running as root (non-kube-system)" \
            "Set 'runAsNonRoot: true' and specify a non-root 'runAsUser' in securityContext."
    elif [[ "$root_count" -ge 50 ]]; then
        add_suggestion "WARNING" \
            "$root_count container(s) potentially running as root (non-kube-system)" \
            "Set 'runAsNonRoot: true' and specify a non-root 'runAsUser' in securityContext."
    fi

    # Network Policies
    sub_header "Network Policies"
    output ""
    local netpol_count
    netpol_count=$(kubectl get networkpolicies -A --no-headers 2>/dev/null | grep -c '[^ ]' 2>/dev/null || true)
    output "  Total Network Policies: $netpol_count"
    if [[ "$netpol_count" -eq 0 ]]; then
        add_suggestion "INFO" \
            "No Network Policies configured in the cluster" \
            "Consider implementing Network Policies to restrict pod-to-pod communication."
    else
        kubectl get networkpolicies -A 2>/dev/null | while IFS= read -r line; do
            output "  $line"
        done
    fi

    # PodDisruptionBudgets
    sub_header "PodDisruptionBudgets"
    output ""
    local pdb_count
    pdb_count=$(kubectl get pdb -A --no-headers 2>/dev/null | grep -c '[^ ]' 2>/dev/null || true)
    output "  Total PDBs: $pdb_count"
    if [[ "$pdb_count" -gt 0 ]]; then
        output ""
        kubectl get pdb -A 2>/dev/null | while IFS= read -r line; do
            output "  $line"
        done
    else
        add_suggestion "INFO" \
            "No PodDisruptionBudgets configured" \
            "PDBs help ensure availability during node maintenance and cluster upgrades."
    fi

    # HorizontalPodAutoscalers
    sub_header "HorizontalPodAutoscalers"
    output ""
    local hpa_count
    hpa_count=$(kubectl get hpa -A --no-headers 2>/dev/null | grep -c '[^ ]' 2>/dev/null || true)
    output "  Total HPAs: $hpa_count"
    if [[ "$hpa_count" -gt 0 ]]; then
        output ""
        kubectl get hpa -A 2>/dev/null | while IFS= read -r line; do
            output "  $line"
        done
        # An HPA with no metrics source is inert, not merely degraded
        if [[ "${HAS_METRICS_SERVER:-false}" != "true" ]]; then
            add_suggestion "CRITICAL" \
                "$hpa_count HorizontalPodAutoscaler(s) exist but metrics-server is not available" \
                "CPU/memory-based HPAs cannot read metrics, so they are silently not scaling at all - the workloads they protect are effectively running at fixed replica counts. Install metrics-server."
        fi
    elif [[ "${HAS_METRICS_SERVER:-false}" == "true" ]]; then
        add_suggestion "INFO" \
            "No HorizontalPodAutoscalers configured" \
            "metrics-server is available, so HPAs could be used to scale workloads on demand instead of fixed replica counts."
    fi

    # Service Accounts with IRSA
    sub_header "Service Accounts with IAM Roles (IRSA)"
    output ""
    local irsa_sa
    irsa_sa=$(kubectl get serviceaccounts -A -o json 2>/dev/null | jq -r '
        .items[] |
        select(.metadata.annotations["eks.amazonaws.com/role-arn"] != null) |
        "\(.metadata.namespace)\t\(.metadata.name)\t\(.metadata.annotations["eks.amazonaws.com/role-arn"])"
    ' 2>/dev/null)
    local irsa_count
    irsa_count=$(echo "$irsa_sa" | grep -c '[^ ]' 2>/dev/null || true)

    output "  Service Accounts with IRSA: $irsa_count"
    if [[ "$irsa_count" -gt 0 ]]; then
        output ""
        printf "  %-20s %-30s %s\n" "NAMESPACE" "SERVICE ACCOUNT" "IAM ROLE ARN" | tee -a "$REPORT_FILE"
        printf "  %-20s %-30s %s\n" "────────────────────" "──────────────────────────────" "────────────────────────────────────" | tee -a "$REPORT_FILE"
        while IFS=$'\t' read -r ns sa role; do
            [[ -z "$ns" ]] && continue
            printf "  %-20s %-30s %s\n" "$ns" "$sa" "$role" | tee -a "$REPORT_FILE"
            csv_row "\"SECURITY\"" "\"irsa\"" "\"$ns\"" "\"$sa\"" "\"$role\"" "\"\"" "\"OK\"" "\"\""

            # An IAM role bound to a ServiceAccount in 'default' is reachable by
            # any pod that lands there without specifying a ServiceAccount.
            if [[ "$ns" == "default" ]]; then
                add_suggestion "WARNING" \
                    "ServiceAccount '$sa' in the 'default' namespace has an IAM role attached" \
                    "Role: $role. Anything deployed into 'default' can assume it. Move the workload to a dedicated namespace, or remove the annotation if unused."
            fi
        done < <(echo "$irsa_sa")
    fi

    # Recent warning events - the fastest signal for problems that no static
    # config check can see (image pull failures, OOMKills, failed scheduling,
    # probe failures). Not previously collected at all.
    sub_header "Recent Warning Events"
    output ""
    local warn_events
    warn_events=$(kubectl get events -A --field-selector type=Warning \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.reason}{"\t"}{.involvedObject.kind}/{.involvedObject.name}{"\t"}{.message}{"\n"}{end}' 2>/dev/null || echo "")
    local warn_count
    warn_count=$(echo "$warn_events" | grep -c '[^[:space:]]' 2>/dev/null || true)

    if [[ "$warn_count" -eq 0 ]]; then
        output "  ${GREEN}✓ No warning events in the retained event window${NC}"
    else
        output "  Warning events (retained window, typically last ~1h): $warn_count"
        output ""
        # Group by reason so a single flapping pod does not dominate the list
        local reason_summary
        reason_summary=$(echo "$warn_events" | awk -F'\t' 'NF>1 {print $2}' | sort | uniq -c | sort -rn)
        output "  COUNT  REASON"
        output "  ─────  ──────────────────────────────────────────────────"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            output "  $line"
            local ev_count ev_reason
            ev_count=$(echo "$line" | awk '{print $1}')
            ev_reason=$(echo "$line" | awk '{print $2}')
            csv_row "\"EVENT\"" "\"warning\"" "\"\"" "\"$ev_reason\"" "\"count=$ev_count\"" "\"\"" "\"WARNING\"" "\"\""

            # Reasons that indicate a workload is actually broken right now
            case "$ev_reason" in
                Failed|FailedScheduling|FailedMount|FailedCreatePodSandBox|BackOff|OOMKilling|Evicted|ErrImagePull|ImagePullBackOff|Unhealthy|NodeNotReady)
                    add_suggestion "WARNING" \
                        "$ev_count recent warning event(s) with reason '$ev_reason'" \
                        "Investigate: kubectl get events -A --field-selector type=Warning,reason=$ev_reason --sort-by=.lastTimestamp"
                    ;;
            esac
        done < <(echo "$reason_summary")
    fi

    # Upgrade Readiness (EKS Cluster Insights)
    #
    # This replaces a hand-rolled deprecated-API scan that used:
    #   kubectl get <kind> -A -o jsonpath="{range .items[?(@.apiVersion=='<ver>')]}..."
    # That check produced a false positive for every kind that exists in the
    # cluster: items inside a typed List response do not carry an apiVersion
    # field, so the filter never matches meaningfully and the template still
    # emits a bare "/". It also cannot work in principle - an API removed in
    # 1.22 cannot be served by a 1.32 API server, so kubectl can never return
    # one. AWS already runs this analysis server-side against real audit data.
    sub_header "Upgrade Readiness (EKS Cluster Insights)"
    output ""

    local insights_json
    insights_json=$(aws eks list-insights \
        --cluster-name "$CLUSTER_NAME" \
        --region "$REGION" \
        --filter '{"categories":["UPGRADE_READINESS"]}' \
        --output json 2>/dev/null || echo "")

    if [[ -z "$insights_json" ]]; then
        output "  ${YELLOW}(EKS Cluster Insights unavailable - needs AWS CLI v2.17+ and eks:ListInsights)${NC}"
        output "  Run one of these to check deprecated APIs before upgrading:"
        output "    pluto detect-all-in-cluster"
        output "    kubent"
        add_suggestion "INFO" \
            "Deprecated API check was skipped - EKS Cluster Insights not available" \
            "Update AWS CLI and grant eks:ListInsights, or run 'pluto detect-all-in-cluster' / 'kubent' manually before upgrading."
        return
    fi

    local insight_count
    insight_count=$(echo "$insights_json" | jq -r '.insights | length' 2>/dev/null || echo "0")
    output "  Total upgrade-readiness insights: $insight_count"
    output ""

    local issues_found=0
    local ins_id ins_name ins_status ins_desc
    while IFS=$'\t' read -r ins_id ins_name ins_status; do
        [[ -z "$ins_id" ]] && continue

        case "$ins_status" in
            PASSING)
                output "  ${GREEN}✓${NC} $ins_name"
                continue
                ;;
            ERROR|WARNING)
                output "  ${RED}⚠ $ins_name${NC} [$ins_status]"
                ;;
            *)
                output "  ${YELLOW}? $ins_name${NC} [$ins_status]"
                continue
                ;;
        esac

        ((issues_found++)) || true

        # Pull the detail (which resources / client user-agents triggered it)
        local detail_json
        detail_json=$(aws eks describe-insight \
            --cluster-name "$CLUSTER_NAME" \
            --id "$ins_id" \
            --region "$REGION" \
            --output json 2>/dev/null || echo "")

        ins_desc=$(echo "$detail_json" | jq -r '.insight.description // ""' 2>/dev/null || echo "")
        local ins_resources
        ins_resources=$(echo "$detail_json" | jq -r '
            [.insight.categorySpecificSummary.deprecationDetails[]?
             | .usage // .clientStats[]?.userAgent // empty] | unique | join("; ")' 2>/dev/null || echo "")

        [[ -n "$ins_desc" ]] && output "    $ins_desc"
        [[ -n "$ins_resources" ]] && output "    Detected: $ins_resources"

        local severity="WARNING"
        [[ "$ins_status" == "ERROR" ]] && severity="CRITICAL"
        add_suggestion "$severity" \
            "Upgrade readiness check failed: $ins_name" \
            "${ins_desc}${ins_resources:+ Detected: $ins_resources}"

        csv_row "\"UPGRADE_READINESS\"" "\"insight\"" "\"\"" "\"$ins_name\"" "\"$ins_status\"" "\"PASSING\"" "\"$ins_status\"" "\"$ins_resources\""
    done < <(echo "$insights_json" | jq -r '.insights[]? | [.id, .name, .insightStatus.status] | @tsv' 2>/dev/null)

    if [[ "$issues_found" -eq 0 && "$insight_count" -gt 0 ]]; then
        output ""
        output "  ${GREEN}✓ All upgrade-readiness checks passing${NC}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 6: UPGRADE SUGGESTIONS
# ─────────────────────────────────────────────────────────────────────────────

print_suggestions() {
    section_header "SECTION 6: UPGRADE & OPTIMIZATION SUGGESTIONS" "🔧"
    output ""

    # Summary bar
    output "  ╔═══════════════════════════════════════════════════════════╗"
    output "  ║  Summary: ${RED}🔴 CRITICAL: $CRITICAL_COUNT${NC}  ${YELLOW}🟡 WARNING: $WARNING_COUNT${NC}  ${GREEN}🟢 INFO: $INFO_COUNT${NC}  ║"
    output "  ╚═══════════════════════════════════════════════════════════╝"

    # Critical suggestions
    if [[ ${#SUGGESTIONS_CRITICAL[@]} -gt 0 ]]; then
        output ""
        output "  ${RED}${BOLD}🔴 CRITICAL${NC}"
        output "  ────────────────────────────────────────────────────────"
        for item in "${SUGGESTIONS_CRITICAL[@]}"; do
            IFS='|' read -r msg detail <<< "$item"
            output "  ${RED}✗${NC} $msg"
            if [[ -n "$detail" ]]; then
                output "    ${CYAN}→ $detail${NC}"
            fi
            output ""
        done
    fi

    # Warning suggestions
    if [[ ${#SUGGESTIONS_WARNING[@]} -gt 0 ]]; then
        output ""
        output "  ${YELLOW}${BOLD}🟡 WARNING${NC}"
        output "  ────────────────────────────────────────────────────────"
        for item in "${SUGGESTIONS_WARNING[@]}"; do
            IFS='|' read -r msg detail <<< "$item"
            output "  ${YELLOW}⚠${NC} $msg"
            if [[ -n "$detail" ]]; then
                output "    ${CYAN}→ $detail${NC}"
            fi
            output ""
        done
    fi

    # Info suggestions
    if [[ ${#SUGGESTIONS_INFO[@]} -gt 0 ]]; then
        output ""
        output "  ${GREEN}${BOLD}🟢 INFO${NC}"
        output "  ────────────────────────────────────────────────────────"
        for item in "${SUGGESTIONS_INFO[@]}"; do
            IFS='|' read -r msg detail <<< "$item"
            output "  ${GREEN}ℹ${NC} $msg"
            if [[ -n "$detail" ]]; then
                output "    ${CYAN}→ $detail${NC}"
            fi
            output ""
        done
    fi

    if [[ "$CRITICAL_COUNT" -eq 0 && "$WARNING_COUNT" -eq 0 && "$INFO_COUNT" -eq 0 ]]; then
        output "  ${GREEN}✓ No issues found. Your cluster looks healthy!${NC}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# HTML REPORT GENERATION
# ─────────────────────────────────────────────────────────────────────────────

generate_html_report() {
    log "Generating HTML report..."

    cat > "$HTML_FILE" <<'HTMLHEADER'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>EKS Cluster Discovery Report</title>
<style>
  :root {
    --bg-primary: #0f172a;
    --bg-secondary: #1e293b;
    --bg-card: #1e293b;
    --bg-card-hover: #334155;
    --text-primary: #f1f5f9;
    --text-secondary: #94a3b8;
    --text-muted: #64748b;
    --border: #334155;
    --accent-blue: #3b82f6;
    --accent-cyan: #06b6d4;
    --accent-green: #22c55e;
    --accent-yellow: #eab308;
    --accent-red: #ef4444;
    --accent-purple: #a855f7;
    --critical-bg: rgba(239,68,68,0.1);
    --critical-border: rgba(239,68,68,0.3);
    --warning-bg: rgba(234,179,8,0.1);
    --warning-border: rgba(234,179,8,0.3);
    --info-bg: rgba(34,197,94,0.1);
    --info-border: rgba(34,197,94,0.3);
  }
  * { margin:0; padding:0; box-sizing:border-box; }
  body {
    font-family: 'Segoe UI',system-ui,-apple-system,sans-serif;
    background: var(--bg-primary);
    color: var(--text-primary);
    line-height: 1.6;
    padding: 0;
  }
  .header {
    background: linear-gradient(135deg, #1e3a5f 0%, #0f172a 50%, #1a1a2e 100%);
    border-bottom: 1px solid var(--border);
    padding: 2rem 2rem 1.5rem;
  }
  .header h1 {
    font-size: 1.75rem;
    font-weight: 700;
    background: linear-gradient(135deg, var(--accent-cyan), var(--accent-blue));
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    margin-bottom: 0.5rem;
  }
  .header .meta {
    display: flex;
    gap: 2rem;
    flex-wrap: wrap;
    color: var(--text-secondary);
    font-size: 0.875rem;
  }
  .header .meta span { display:flex; align-items:center; gap:0.375rem; }
  .container { max-width: 1400px; margin: 0 auto; padding: 1.5rem; }
  .summary-cards {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 1rem;
    margin-bottom: 2rem;
  }
  .summary-card {
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: 0.75rem;
    padding: 1.25rem;
    transition: transform 0.2s, box-shadow 0.2s;
  }
  .summary-card:hover {
    transform: translateY(-2px);
    box-shadow: 0 8px 25px rgba(0,0,0,0.3);
  }
  .summary-card .label {
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-muted);
    margin-bottom: 0.25rem;
  }
  .summary-card .value {
    font-size: 1.75rem;
    font-weight: 700;
  }
  .summary-card .sub { font-size:0.8rem; color:var(--text-secondary); margin-top:0.25rem; }
  .summary-card.critical { border-left: 4px solid var(--accent-red); }
  .summary-card.critical .value { color: var(--accent-red); }
  .summary-card.warning { border-left: 4px solid var(--accent-yellow); }
  .summary-card.warning .value { color: var(--accent-yellow); }
  .summary-card.info { border-left: 4px solid var(--accent-green); }
  .summary-card.info .value { color: var(--accent-green); }
  .summary-card.neutral { border-left: 4px solid var(--accent-blue); }
  .summary-card.neutral .value { color: var(--accent-blue); }
  .section {
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: 0.75rem;
    margin-bottom: 1.5rem;
    overflow: hidden;
  }
  .section-header {
    padding: 1rem 1.25rem;
    border-bottom: 1px solid var(--border);
    display: flex;
    align-items: center;
    gap: 0.625rem;
    cursor: pointer;
    user-select: none;
    background: rgba(255,255,255,0.02);
  }
  .section-header:hover { background: rgba(255,255,255,0.04); }
  .section-header h2 {
    font-size: 1.1rem;
    font-weight: 600;
  }
  .section-header .icon { font-size: 1.25rem; }
  .section-header .toggle {
    margin-left: auto;
    color: var(--text-muted);
    transition: transform 0.3s;
    font-size: 0.875rem;
  }
  .section-header .toggle.collapsed { transform: rotate(-90deg); }
  .section-body { padding: 1.25rem; }
  .section-body.collapsed { display: none; }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.85rem;
  }
  thead th {
    text-align: left;
    padding: 0.625rem 0.75rem;
    border-bottom: 2px solid var(--border);
    color: var(--text-secondary);
    font-weight: 600;
    text-transform: uppercase;
    font-size: 0.7rem;
    letter-spacing: 0.05em;
    white-space: nowrap;
  }
  tbody td {
    padding: 0.5rem 0.75rem;
    border-bottom: 1px solid rgba(51,65,85,0.5);
    color: var(--text-primary);
    vertical-align: top;
    word-break: break-word;
  }
  tbody tr:hover { background: rgba(255,255,255,0.03); }
  tbody tr:last-child td { border-bottom: none; }
  .badge {
    display: inline-block;
    padding: 0.125rem 0.5rem;
    border-radius: 9999px;
    font-size: 0.7rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.025em;
  }
  .badge-critical { background:var(--critical-bg); color:var(--accent-red); border:1px solid var(--critical-border); }
  .badge-warning { background:var(--warning-bg); color:var(--accent-yellow); border:1px solid var(--warning-border); }
  .badge-info { background:var(--info-bg); color:var(--accent-green); border:1px solid var(--info-border); }
  .badge-ok { background:rgba(34,197,94,0.15); color:var(--accent-green); border:1px solid rgba(34,197,94,0.3); }
  .badge-neutral { background:rgba(59,130,246,0.1); color:var(--accent-blue); border:1px solid rgba(59,130,246,0.3); }
  .suggestion-card {
    border-radius: 0.5rem;
    padding: 0.875rem 1rem;
    margin-bottom: 0.75rem;
  }
  .suggestion-card.critical {
    background: var(--critical-bg);
    border-left: 4px solid var(--accent-red);
  }
  .suggestion-card.warning {
    background: var(--warning-bg);
    border-left: 4px solid var(--accent-yellow);
  }
  .suggestion-card.info-card {
    background: var(--info-bg);
    border-left: 4px solid var(--accent-green);
  }
  .suggestion-card .msg {
    font-weight: 600;
    margin-bottom: 0.25rem;
  }
  .suggestion-card .detail {
    font-size: 0.8rem;
    color: var(--text-secondary);
  }
  .kv-grid {
    display: grid;
    grid-template-columns: 180px 1fr;
    gap: 0.375rem 1rem;
    font-size: 0.875rem;
  }
  .kv-grid .k { color:var(--text-muted); font-weight:500; }
  .kv-grid .v { color:var(--text-primary); word-break:break-all; }
  .pre-block {
    background: var(--bg-primary);
    border: 1px solid var(--border);
    border-radius: 0.5rem;
    padding: 1rem;
    font-family: 'Cascadia Code','Fira Code',monospace;
    font-size: 0.8rem;
    white-space: pre-wrap;
    word-break: break-word;
    color: var(--text-secondary);
    overflow-x: auto;
    margin-top: 0.75rem;
  }
  .footer {
    text-align: center;
    padding: 2rem;
    color: var(--text-muted);
    font-size: 0.8rem;
    border-top: 1px solid var(--border);
    margin-top: 2rem;
  }
  @media (max-width: 768px) {
    .summary-cards { grid-template-columns: repeat(2, 1fr); }
    .kv-grid { grid-template-columns: 140px 1fr; }
    .container { padding: 0.75rem; }
  }
</style>
</head>
<body>
HTMLHEADER

    # ── Header ──
    cat >> "$HTML_FILE" <<EOF
<div class="header">
  <h1>🚀 EKS Cluster Discovery &amp; Upgrade Report</h1>
  <div class="meta">
    <span>📦 <strong>${CLUSTER_NAME}</strong></span>
    <span>🌍 ${REGION}</span>
    <span>📅 ${DATE_HUMAN}</span>
    <span>⚙️ v${VERSION}</span>
  </div>
</div>
<div class="container">
EOF

    # ── Summary Cards ──
    # Count categories from CSV
    local total_nodegroups total_nodes total_addons total_deployments total_images
    total_nodegroups=$(grep -c '"NODE_GROUP"' "$CSV_FILE" 2>/dev/null || true)
    total_nodes=$(grep -c '"NODE"' "$CSV_FILE" 2>/dev/null || true)
    total_addons=$(grep -c '"ADDON"' "$CSV_FILE" 2>/dev/null || true)
    total_deployments=$(grep -c '"DEPLOYMENT"' "$CSV_FILE" 2>/dev/null || true)
    total_images=$(grep -c '"IMAGE"' "$CSV_FILE" 2>/dev/null || true)

    cat >> "$HTML_FILE" <<EOF
<div class="summary-cards">
  <div class="summary-card neutral">
    <div class="label">K8s Version</div>
    <div class="value">${CLUSTER_K8S_VERSION}</div>
    <div class="sub">Latest: ${LATEST_EKS_VERSION}</div>
  </div>
  <div class="summary-card critical">
    <div class="label">Critical Issues</div>
    <div class="value">${CRITICAL_COUNT}</div>
    <div class="sub">Require immediate action</div>
  </div>
  <div class="summary-card warning">
    <div class="label">Warnings</div>
    <div class="value">${WARNING_COUNT}</div>
    <div class="sub">Should be addressed</div>
  </div>
  <div class="summary-card info">
    <div class="label">Info</div>
    <div class="value">${INFO_COUNT}</div>
    <div class="sub">Recommendations</div>
  </div>
  <div class="summary-card neutral">
    <div class="label">Node Groups</div>
    <div class="value">${total_nodegroups}</div>
    <div class="sub">${total_nodes} nodes</div>
  </div>
  <div class="summary-card neutral">
    <div class="label">Deployments</div>
    <div class="value">${total_deployments}</div>
    <div class="sub">${total_images} unique images</div>
  </div>
</div>
EOF

    # ── Suggestions Section (top priority) ──
    cat >> "$HTML_FILE" <<'EOF'
<div class="section">
  <div class="section-header" onclick="toggleSection(this)">
    <span class="icon">🔧</span>
    <h2>Upgrade &amp; Optimization Suggestions</h2>
    <span class="toggle">▼</span>
  </div>
  <div class="section-body">
EOF

    # Critical suggestions
    if [[ ${#SUGGESTIONS_CRITICAL[@]} -gt 0 ]]; then
        echo '<h3 style="color:var(--accent-red);margin-bottom:0.75rem;">🔴 Critical</h3>' >> "$HTML_FILE"
        for item in "${SUGGESTIONS_CRITICAL[@]}"; do
            IFS='|' read -r msg detail <<< "$item"
            local escaped_msg escaped_detail
            escaped_msg=$(echo "$msg" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
            escaped_detail=$(echo "$detail" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
            cat >> "$HTML_FILE" <<EOF
    <div class="suggestion-card critical">
      <div class="msg">✗ ${escaped_msg}</div>
      <div class="detail">→ ${escaped_detail}</div>
    </div>
EOF
        done
    fi

    # Warning suggestions
    if [[ ${#SUGGESTIONS_WARNING[@]} -gt 0 ]]; then
        echo '<h3 style="color:var(--accent-yellow);margin:1rem 0 0.75rem;">🟡 Warning</h3>' >> "$HTML_FILE"
        for item in "${SUGGESTIONS_WARNING[@]}"; do
            IFS='|' read -r msg detail <<< "$item"
            local escaped_msg escaped_detail
            escaped_msg=$(echo "$msg" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
            escaped_detail=$(echo "$detail" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
            cat >> "$HTML_FILE" <<EOF
    <div class="suggestion-card warning">
      <div class="msg">⚠ ${escaped_msg}</div>
      <div class="detail">→ ${escaped_detail}</div>
    </div>
EOF
        done
    fi

    # Info suggestions
    if [[ ${#SUGGESTIONS_INFO[@]} -gt 0 ]]; then
        echo '<h3 style="color:var(--accent-green);margin:1rem 0 0.75rem;">🟢 Info</h3>' >> "$HTML_FILE"
        for item in "${SUGGESTIONS_INFO[@]}"; do
            IFS='|' read -r msg detail <<< "$item"
            local escaped_msg escaped_detail
            escaped_msg=$(echo "$msg" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
            escaped_detail=$(echo "$detail" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
            cat >> "$HTML_FILE" <<EOF
    <div class="suggestion-card info-card">
      <div class="msg">ℹ ${escaped_msg}</div>
      <div class="detail">→ ${escaped_detail}</div>
    </div>
EOF
        done
    fi

    if [[ "$CRITICAL_COUNT" -eq 0 && "$WARNING_COUNT" -eq 0 && "$INFO_COUNT" -eq 0 ]]; then
        echo '<div class="suggestion-card info-card"><div class="msg">✓ No issues found. Your cluster looks healthy!</div></div>' >> "$HTML_FILE"
    fi

    echo '</div></div>' >> "$HTML_FILE"

    # ── Helper: generate HTML table from CSV category ──
    html_table_from_csv() {
        local category="$1"
        local title="$2"
        local icon="$3"

        local rows
        rows=$(grep "^\"${category}\"" "$CSV_FILE" 2>/dev/null || echo "")
        if [[ -z "$rows" ]]; then
            return
        fi

        cat >> "$HTML_FILE" <<EOF
<div class="section">
  <div class="section-header" onclick="toggleSection(this)">
    <span class="icon">${icon}</span>
    <h2>${title}</h2>
    <span class="toggle">▼</span>
  </div>
  <div class="section-body">
    <table>
      <thead>
        <tr><th>Item</th><th>Namespace</th><th>Name</th><th>Current Value</th><th>Recommended</th><th>Status</th><th>Detail</th></tr>
      </thead>
      <tbody>
EOF

        echo "$rows" | while IFS= read -r line; do
            # Parse CSV fields (handle quoted fields)
            local item ns name curr rec status detail
            item=$(echo "$line" | awk -F',' '{gsub(/"/,"",$2); print $2}')
            ns=$(echo "$line" | awk -F',' '{gsub(/"/,"",$3); print $3}')
            name=$(echo "$line" | awk -F',' '{gsub(/"/,"",$4); print $4}')
            curr=$(echo "$line" | awk -F',' '{gsub(/"/,"",$5); print $5}')
            rec=$(echo "$line" | awk -F',' '{gsub(/"/,"",$6); print $6}')
            status=$(echo "$line" | awk -F',' '{gsub(/"/,"",$7); print $7}')
            detail=$(echo "$line" | awk -F',' '{gsub(/"/,"",$8); print $8}')

            # Escape HTML
            item=$(echo "$item" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
            ns=$(echo "$ns" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
            name=$(echo "$name" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
            curr=$(echo "$curr" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
            rec=$(echo "$rec" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
            status=$(echo "$status" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
            detail=$(echo "$detail" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')

            # Status badge
            local badge_class="badge-neutral"
            case "$status" in
                *ACTIVE*|*Ready*|*OK*|*Bound*) badge_class="badge-ok" ;;
                *DEGRADED*|*NotReady*|*ERROR*|*END_OF_LIFE*|*UNSUPPORTED*) badge_class="badge-critical" ;;
                *WARNING*|*UPDATE_AVAILABLE*|*EXTENDED*) badge_class="badge-warning" ;;
                *deployed*|*STANDARD*) badge_class="badge-ok" ;;
            esac

            cat >> "$HTML_FILE" <<EOF
        <tr>
          <td>${item}</td>
          <td>${ns:-—}</td>
          <td><strong>${name}</strong></td>
          <td>${curr:-—}</td>
          <td>${rec:-—}</td>
          <td><span class="badge ${badge_class}">${status:-—}</span></td>
          <td>${detail:-—}</td>
        </tr>
EOF
        done

        echo '      </tbody></table></div></div>' >> "$HTML_FILE"
    }

    # ── Generate tables for each category ──
    html_table_from_csv "CLUSTER" "Cluster Overview" "📋"
    html_table_from_csv "NODE_GROUP" "Node Groups" "🖥️"
    html_table_from_csv "NODE" "Nodes" "💻"
    html_table_from_csv "ADDON" "Add-ons &amp; Components" "🔌"
    html_table_from_csv "DEPLOYMENT" "Deployments" "📦"
    html_table_from_csv "STATEFULSET" "StatefulSets" "📦"
    html_table_from_csv "DAEMONSET" "DaemonSets" "📦"
    html_table_from_csv "SERVICE" "Services" "🌐"
    html_table_from_csv "HELM" "Helm Releases" "⎈"
    html_table_from_csv "ARGOCD" "ArgoCD Applications" "🔄"
    html_table_from_csv "IMAGE" "Container Images" "🐳"
    html_table_from_csv "SECURITY" "Security Findings" "🔒"
    html_table_from_csv "UPGRADE_READINESS" "Upgrade Readiness (EKS Insights)" "🚦"
    html_table_from_csv "EVENT" "Recent Warning Events" "🔔"

    # ── Full Text Report (collapsible) ──
    cat >> "$HTML_FILE" <<'EOF'
<div class="section">
  <div class="section-header" onclick="toggleSection(this)">
    <span class="icon">📄</span>
    <h2>Full Text Report</h2>
    <span class="toggle collapsed">▼</span>
  </div>
  <div class="section-body collapsed">
    <div class="pre-block">
EOF

    # Embed full text report (HTML-escaped)
    sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$REPORT_FILE" >> "$HTML_FILE"

    cat >> "$HTML_FILE" <<'EOF'
    </div>
  </div>
</div>
EOF

    # ── Footer & JS ──
    cat >> "$HTML_FILE" <<EOF
<div class="footer">
  Generated by EKS Discovery Script v${VERSION} • ${DATE_HUMAN} • Cluster: ${CLUSTER_NAME} • Region: ${REGION}
</div>
</div>
<script>
function toggleSection(header) {
  const body = header.nextElementSibling;
  const toggle = header.querySelector('.toggle');
  body.classList.toggle('collapsed');
  toggle.classList.toggle('collapsed');
}
</script>
</body>
</html>
EOF

    log_success "HTML report generated: $HTML_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}   EKS Cluster Discovery & Upgrade Suggestion Tool v${VERSION}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    preflight_checks

    # Report header
    report "═══════════════════════════════════════════════════════════════"
    report "   EKS CLUSTER DISCOVERY & UPGRADE REPORT"
    report "   Cluster: $CLUSTER_NAME | Region: $REGION"
    report "   Generated: $DATE_HUMAN"
    report "   Script Version: $VERSION"
    report "═══════════════════════════════════════════════════════════════"

    # Run all discovery modules (|| true ensures one module failure doesn't abort entire script)
    log "Starting cluster discovery..."
    echo ""

    discover_cluster_info || { log_warn "Module 1 (Cluster Info) encountered errors, continuing..."; }
    discover_node_groups || { log_warn "Module 2 (Node Groups) encountered errors, continuing..."; }
    discover_addons || { log_warn "Module 3 (Add-ons) encountered errors, continuing..."; }
    discover_applications || { log_warn "Module 4 (Applications) encountered errors, continuing..."; }
    discover_security || { log_warn "Module 5 (Security) encountered errors, continuing..."; }
    print_suggestions || { log_warn "Module 6 (Suggestions) encountered errors, continuing..."; }

    # Generate HTML report
    generate_html_report || { log_warn "HTML report generation encountered errors"; }

    # Footer
    output ""
    output "═══════════════════════════════════════════════════════════════"
    output "   Report generated: $DATE_HUMAN"
    output "   Text report     : $REPORT_FILE"
    output "   CSV report      : $CSV_FILE"
    output "   HTML report     : $HTML_FILE"
    output "═══════════════════════════════════════════════════════════════"

    echo ""
    log_success "Discovery complete!"
    log_success "Text report : ${BOLD}$REPORT_FILE${NC}"
    log_success "CSV report  : ${BOLD}$CSV_FILE${NC}"
    log_success "HTML report : ${BOLD}$HTML_FILE${NC}"
    echo ""
}

main "$@"
