#!/usr/bin/env bash
#
# Khảo sát ingress-nginx trước khi lên kế hoạch nâng cấp.
#
# READ-ONLY: chỉ dùng get/describe/list. Không sửa gì trên cluster hay AWS.
# Kết quả ghi ra file Markdown trong thư mục hiện tại.
#
#   ./survey.sh                     # tự đặt tên file theo timestamp
#   ./survey.sh -o bao-cao.md       # chỉ định tên file
#
set -uo pipefail

NS=${NS:-nginx-ingress}
REL=${REL:-ingress-nginx}
REGION=${REGION:-ap-southeast-1}
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) OUT="$2"; shift 2 ;;
    -n|--namespace) NS="$2"; shift 2 ;;
    -r|--region) REGION="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Tham số lạ: $1"; exit 1 ;;
  esac
done
[[ -z "$OUT" ]] && OUT="survey-ingress-nginx-$(date +%Y%m%d_%H%M%S).md"

for t in kubectl jq; do
  command -v "$t" >/dev/null || { echo "Thiếu công cụ: $t"; exit 1; }
done

: > "$OUT"
say()   { printf '  %s\n' "$*" >&2; }
md()    { printf '%s\n' "$*" >> "$OUT"; }
block() { # $1 = ngôn ngữ tô màu, $2 = nội dung
  md '```'"$1"
  if [[ -n "${2//[[:space:]]/}" ]]; then printf '%s\n' "$2" >> "$OUT"
  else printf '(không có dữ liệu)\n' >> "$OUT"; fi
  md '```'; md ''
}
q() { kubectl "$@" 2>/dev/null; }   # truy vấn im lặng

echo "Khảo sát ingress-nginx → $OUT" >&2
echo "" >&2

# ─────────────────────────────────────────────────────────────
# Thu thập các dữ kiện chính trước, để dựng phần kết luận ở đầu file
# ─────────────────────────────────────────────────────────────
say "1/8  Thu thập dữ kiện chính…"

SVC_JSON=$(q -n "$NS" get svc "$REL"-controller -o json)
DS_JSON=$(q  -n "$NS" get ds  "$REL"-controller -o json)
ING_JSON=$(q get ingress -A -o json)

jqs() { local r; r=$(printf '%s' "$1" | jq -r "$2" 2>/dev/null); printf '%s' "${r:-?}"; }
jqn() { local r; r=$(printf '%s' "$1" | jq -r "$2" 2>/dev/null); printf '%s' "${r:-0}"; }

SVC_TYPE=$(jqs "$SVC_JSON" '.spec.type // "?"')
ETP=$(jqs      "$SVC_JSON" '.spec.externalTrafficPolicy // "?"')
NODEPORTS=$(jqs "$SVC_JSON" '[.spec.ports[]? | "\(.port)→\(.nodePort // "-")"] | join(", ")')
LB_HOST=$(jqs  "$SVC_JSON" '.status.loadBalancer.ingress[0].hostname // ""')
HOSTPORTS=$(jqs "$DS_JSON" '[.spec.template.spec.containers[0].ports[]? | select(.hostPort) | "\(.name):\(.hostPort)"] | join(", ")')
DS_DESIRED=$(jqn "$DS_JSON" '.status.desiredNumberScheduled // 0')
DS_READY=$(jqn   "$DS_JSON" '.status.numberReady // 0')
MAXUNAVAIL=$(jqs "$DS_JSON" '.spec.updateStrategy.rollingUpdate.maxUnavailable // "mặc định (1)"')
ING_COUNT=$(jqn  "$ING_JSON" '[.items[]?] | length')

ANNOT_KINDS=$(printf '%s' "$ING_JSON" | jq -r '.items[]? | (.metadata.annotations // {} | keys[])' 2>/dev/null \
              | grep -c '^nginx\.ingress\.kubernetes\.io' || true)
ANNOT_DISTINCT=$(printf '%s' "$ING_JSON" | jq -r '.items[]? | (.metadata.annotations // {} | keys[])' 2>/dev/null \
              | grep '^nginx\.ingress\.kubernetes\.io' | sort -u | wc -l | tr -d ' ')
SNIPPET_VARIANTS=$(printf '%s' "$ING_JSON" | jq -r '.items[]? | .metadata.annotations["nginx.ingress.kubernetes.io/configuration-snippet"] // empty' 2>/dev/null \
              | sort -u | grep -c . || true)
SNIPPET_USERS=$(printf '%s' "$ING_JSON" | jq -r '.items[]? | select(.metadata.annotations["nginx.ingress.kubernetes.io/configuration-snippet"]) | .metadata.name' 2>/dev/null \
              | grep -c . || true)

HAS_SM=$(q -n "$NS" get servicemonitor -o name | grep -c . || true)
HAS_PDB=$(q -n "$NS" get pdb -o name | grep -c . || true)

# ── ELB: đây là câu hỏi quyết định mức gián đoạn khi rollout ──
say "2/8  Kiểm tra ELB phía AWS…"
LB_KIND="?"; LB_INSTANCE_PORTS=""; LB_RAW=""
if [[ -n "$LB_HOST" ]] && command -v aws >/dev/null; then
  LB_NAME="${LB_HOST%%-*}"
  LB_RAW=$(aws elb describe-load-balancers --load-balancer-names "$LB_NAME" --region "$REGION" --output json 2>/dev/null)
  if [[ -n "$LB_RAW" ]]; then
    LB_KIND="Classic ELB"
    LB_INSTANCE_PORTS=$(printf '%s' "$LB_RAW" | jq -r '[.LoadBalancerDescriptions[0].ListenerDescriptions[].Listener | "\(.LoadBalancerPort)→instance:\(.InstancePort)"] | join(", ")' 2>/dev/null)
  else
    LB_RAW=$(aws elbv2 describe-load-balancers --region "$REGION" --output json 2>/dev/null \
             | jq --arg h "$LB_HOST" '.LoadBalancers[] | select(.DNSName==$h)' 2>/dev/null)
    [[ -n "$LB_RAW" ]] && LB_KIND=$(printf '%s' "$LB_RAW" | jq -r '.Type + " (ELBv2)"' 2>/dev/null)
  fi
fi

# Suy luận đường vào từ instance port của listener
VERDICT="chưa xác định được — cần quyền đọc ELB"
case "$LB_INSTANCE_PORTS" in
  *instance:80*|*instance:443*) VERDICT="**hostPort** — rolling update sẽ làm node mất cổng 80/443, RỦI RO CAO" ;;
  *instance:3*)                 VERDICT="**NodePort** — kube-proxy điều phối, rollout êm hơn" ;;
esac

# ─────────────────────────────────────────────────────────────
say "3/8  Viết phần kết luận…"

md "# Khảo sát ingress-nginx"
md ""
md "| | |"
md "|---|---|"
md "| Thời điểm | \`$(date '+%Y-%m-%d %H:%M:%S %Z')\` |"
md "| Namespace | \`$NS\` |"
md "| Release | \`$REL\` |"
md "| Region | \`$REGION\` |"
md "| Cluster | \`$(kubectl config current-context 2>/dev/null || echo '?')\` |"
md ""
md "> Khảo sát chỉ đọc dữ liệu. Không có thay đổi nào được thực hiện."
md ""
md "---"
md ""
md "## 0. Kết luận nhanh"
md ""
md "| Câu hỏi | Kết quả |"
md "|---|---|"
md "| **ELB trỏ vào đâu?** | $VERDICT |"
md "| Loại Load Balancer | $LB_KIND |"
md "| Listener → instance port | \`${LB_INSTANCE_PORTS:-?}\` |"
md "| Service type | \`$SVC_TYPE\` |"
md "| externalTrafficPolicy | \`$ETP\` |"
md "| NodePort được cấp | \`${NODEPORTS:-?}\` |"
md "| hostPort trên DaemonSet | \`${HOSTPORTS:-không có}\` |"
md "| Pod controller | $DS_READY / $DS_DESIRED sẵn sàng |"
md "| maxUnavailable khi rollout | \`$MAXUNAVAIL\` |"
md "| Tổng số Ingress | $ING_COUNT |"
md "| Loại annotation nginx đang dùng | $ANNOT_DISTINCT loại / $ANNOT_KINDS lần xuất hiện |"
md "| Ingress dùng \`configuration-snippet\` | $SNIPPET_USERS |"
md "| Số biến thể nội dung snippet | **$SNIPPET_VARIANTS** |"
md "| ServiceMonitor (Prometheus) | $([[ "$HAS_SM" -gt 0 ]] && echo "có" || echo "**không có** — thiếu số liệu lúc rollout") |"
md "| PodDisruptionBudget | $([[ "$HAS_PDB" -gt 0 ]] && echo "có" || echo "**không có**") |"
md ""

md "### Cần đọc kỹ"
md ""
if [[ "$ETP" == "Local" ]]; then
  md "- \`externalTrafficPolicy: Local\` → nginx đã nhận được client IP thật ở tầng service."
  md "  Nếu đúng vậy thì annotation \`set_real_ip_from\` **có thể đã thừa** — cần kiểm chứng trước khi"
  md "  mất công chuyển sang ConfigMap."
elif [[ "$ETP" == "Cluster" ]]; then
  md "- \`externalTrafficPolicy: Cluster\` → source IP bị SNAT, nên annotation khôi phục client IP"
  md "  đúng là đang có tác dụng thật. Phải chuyển sang ConfigMap tương đương trước khi nâng version."
fi
if [[ "$SNIPPET_VARIANTS" -eq 1 ]]; then
  md "- Cả $SNIPPET_USERS ingress dùng **cùng một nội dung snippet** → gom về ConfigMap là xử lý được hết một lần."
elif [[ "$SNIPPET_VARIANTS" -gt 1 ]]; then
  md "- Có **$SNIPPET_VARIANTS biến thể snippet khác nhau** → không gom chung được, phải xử lý từng nhóm. Xem mục 2."
fi
if [[ "$ANNOT_DISTINCT" -gt 1 ]]; then
  md "- Đang dùng **$ANNOT_DISTINCT loại annotation nginx**, không chỉ mỗi snippet. Xem mục 2 để biết loại nào."
fi
[[ "$HAS_SM" -eq 0 ]] && md "- Không có ServiceMonitor → **bật metrics trước khi nâng cấp** để có baseline error rate."
md ""
md "---"
md ""

# ─────────────────────────────────────────────────────────────
say "4/8  Mục 1 — đường vào…"
md "## 1. Đường vào — ELB, Service, hostPort"
md ""
md "### Service \`$REL-controller\`"
block yaml "$(printf '%s' "$SVC_JSON" | jq -r '{type:.spec.type, externalTrafficPolicy:.spec.externalTrafficPolicy, ports:.spec.ports, annotations:.metadata.annotations, loadBalancer:.status.loadBalancer}' 2>/dev/null)"
md "### Cổng trên DaemonSet"
block text "$(printf '%s' "$DS_JSON" | jq -r '.spec.template.spec.containers[0].ports[]? | "name=\(.name)  container=\(.containerPort)  host=\(.hostPort // "-")  protocol=\(.protocol // "TCP")"' 2>/dev/null)"
md "### Load Balancer phía AWS"
md ""
md "- DNS: \`${LB_HOST:-<không có>}\`"
md "- Loại: $LB_KIND"
md ""
block json "$LB_RAW"

# ─────────────────────────────────────────────────────────────
say "5/8  Mục 2 — annotation…"
md "## 2. Annotation trên Ingress"
md ""
md "### Thống kê theo loại"
block text "$(printf '%s' "$ING_JSON" | jq -r '.items[]? | (.metadata.annotations // {} | keys[])' 2>/dev/null | grep '^nginx\.ingress\.kubernetes\.io' | sort | uniq -c | sort -rn)"
md "### Biến thể nội dung \`configuration-snippet\`"
md ""
md "Cột đầu là số ingress dùng nội dung đó. Ra đúng **một** dòng nghĩa là toàn bộ giống hệt nhau."
md ""
block nginx "$(printf '%s' "$ING_JSON" | jq -r '.items[]? | .metadata.annotations["nginx.ingress.kubernetes.io/configuration-snippet"] // empty' 2>/dev/null | sort | uniq -c)"
md "### Chi tiết từng ingress có snippet"
block text "$(printf '%s' "$ING_JSON" | jq -r '.items[]? | select(.metadata.annotations["nginx.ingress.kubernetes.io/configuration-snippet"]) | "── \(.metadata.namespace)/\(.metadata.name)\n\(.metadata.annotations["nginx.ingress.kubernetes.io/configuration-snippet"])"' 2>/dev/null)"
md "### Toàn bộ annotation nginx theo từng ingress"
block text "$(printf '%s' "$ING_JSON" | jq -r '.items[]? | .metadata.namespace as $n | .metadata.name as $m | (.metadata.annotations // {} | to_entries[] | select(.key|startswith("nginx.ingress.kubernetes.io")) | "\($n)/\($m)\t\(.key)")' 2>/dev/null | sort)"

# ─────────────────────────────────────────────────────────────
say "6/8  Mục 3 — cấu hình controller…"
md "## 3. Cấu hình controller đang chạy"
md ""
md "### Args"
block text "$(printf '%s' "$DS_JSON" | jq -r '.spec.template.spec.containers[0].args[]?' 2>/dev/null)"
md "### Image"
block text "$(printf '%s' "$DS_JSON" | jq -r '.spec.template.spec.containers[0].image' 2>/dev/null)"
md "### ConfigMap tuning"
md ""
md "Rỗng nghĩa là toàn bộ nginx đang chạy tham số mặc định của chart."
md ""
block json "$(q -n "$NS" get cm "$REL"-controller -o jsonpath='{.data}')"
md "### ConfigMap TCP/UDP (nếu có thì phải giữ khi nâng cấp)"
block text "$(q -n "$NS" get cm -o name | grep -Ei 'tcp|udp')"
md "### IngressClass"
block text "$(q get ingressclass -o json | jq -r '.items[]? | "name=\(.metadata.name)  controller=\(.spec.controller)  default=\(.metadata.annotations["ingressclass.kubernetes.io/is-default-class"] // "false")"' 2>/dev/null)"
md "### Resource requests / limits"
block json "$(printf '%s' "$DS_JSON" | jq -r '.spec.template.spec.containers[0].resources' 2>/dev/null)"

# ─────────────────────────────────────────────────────────────
say "7/8  Mục 4-6 — webhook, trạng thái, TLS…"
md "## 4. Admission webhook — đường khai thác của CVE-2025-1974"
md ""
block text "$(q get validatingwebhookconfiguration -o json | jq -r '.items[]? | select(.metadata.name|test("ingress";"i")) | "name=\(.metadata.name)"' 2>/dev/null)"
block text "$(q get validatingwebhookconfiguration "$REL"-admission -o json | jq -r '.webhooks[]? | "webhook=\(.name)\n  failurePolicy=\(.failurePolicy)\n  service=\(.clientConfig.service.namespace)/\(.clientConfig.service.name):\(.clientConfig.service.port // 443)\n  timeoutSeconds=\(.timeoutSeconds // "-")"' 2>/dev/null)"

md "## 5. Trạng thái & khả năng quan sát"
md ""
md "### DaemonSet"
block text "$(printf '%s' "$DS_JSON" | jq -r '"desired=\(.status.desiredNumberScheduled)  ready=\(.status.numberReady)  updated=\(.status.updatedNumberScheduled)  strategy=\(.spec.updateStrategy.type)  maxUnavailable=\(.spec.updateStrategy.rollingUpdate.maxUnavailable // "1 (mặc định)")"' 2>/dev/null)"
md "### PodDisruptionBudget"
block text "$(q -n "$NS" get pdb -o wide)"
md "### ServiceMonitor"
block text "$(q -n "$NS" get servicemonitor -o name)"
md "### Pod đang chạy"
block text "$(q -n "$NS" get pods -o wide)"
md "### Cảnh báo gần đây trong namespace"
block text "$(q -n "$NS" get events --field-selector type=Warning --sort-by=.lastTimestamp | tail -25)"

md "## 6. TLS — cert của $ING_COUNT ingress"
md ""
md "### Secret TLS đang được tham chiếu"
block text "$(printf '%s' "$ING_JSON" | jq -r '.items[]? | .metadata.namespace as $n | (.spec.tls // [])[] | "\($n)/\(.secretName)"' 2>/dev/null | sort -u)"
md "### Secret do cert-manager quản lý"
md ""
md "Phần chênh lệch giữa hai danh sách chính là cert đang cấp thủ công."
md ""
block text "$(q get secret -A -l controller.cert-manager.io/fao=true -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')"
md "### Certificate resource của cert-manager"
block text "$(q get certificate -A -o wide)"
md "### Hạn dùng từng cert"
md ""
md "| Namespace | Secret | Hết hạn | Issuer |"
md "|---|---|---|---|"
printf '%s' "$ING_JSON" | jq -r '.items[]? | .metadata.namespace as $n | (.spec.tls // [])[] | "\($n) \(.secretName)"' 2>/dev/null | sort -u \
| while read -r ns sec; do
    crt=$(q -n "$ns" get secret "$sec" -o jsonpath='{.data.tls\.crt}' | base64 -d 2>/dev/null)
    if [[ -n "$crt" ]]; then
      end=$(printf '%s' "$crt" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      iss=$(printf '%s' "$crt" | openssl x509 -noout -issuer 2>/dev/null | sed 's/.*CN *= *//; s/,.*//')
    fi
    md "| \`$ns\` | \`$sec\` | ${end:-*không đọc được*} | ${iss:-*?*} |"
  done
md ""

# ─────────────────────────────────────────────────────────────
say "8/8  Mục 7 — GitOps…"
md "## 7. GitOps — ingress do đâu quản lý"
md ""
md "| Ingress | ArgoCD app | Managed by |"
md "|---|---|---|"
printf '%s' "$ING_JSON" | jq -r '.items[]? | "| `\(.metadata.namespace)/\(.metadata.name)` | \(.metadata.labels["argocd.argoproj.io/instance"] // "—") | \(.metadata.labels["app.kubernetes.io/managed-by"] // "—") |"' 2>/dev/null >> "$OUT"
md ""
md "### Helm release"
block text "$(command -v helm >/dev/null && helm list -n "$NS" 2>/dev/null || echo '(helm không có trên máy này)')"
md "### Helm values đang áp dụng"
block yaml "$(command -v helm >/dev/null && helm get values "$REL" -n "$NS" 2>/dev/null)"
md ""
md "---"
md ""
md "*Sinh bởi \`survey.sh\` — chỉ đọc, không thay đổi hệ thống.*"

echo "" >&2
echo "Xong: $OUT" >&2
ls -la "$OUT" >&2
