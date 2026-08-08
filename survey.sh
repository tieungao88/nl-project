#!/usr/bin/env bash
#
# Khảo sát ingress-nginx trước khi lên kế hoạch nâng cấp.
#
# READ-ONLY. kubectl chỉ get/describe/list, AWS chỉ describe/list/get.
# Ngoại lệ duy nhất: mục 3.1 dùng `kubectl exec ... -- cat` để đọc nginx.conf đã
# render (nội dung này không lấy được qua API). Tắt bằng --no-exec.
#
#   ./survey.sh                     # tên file theo timestamp
#   ./survey.sh -o bao-cao.md       # chỉ định tên file
#   ./survey.sh --no-exec           # bỏ phần đọc nginx.conf
#
set -uo pipefail

NS=${NS:-nginx-ingress}
REL=${REL:-ingress-nginx}
REGION=${REGION:-ap-southeast-1}
ARGO_APP=${ARGO_APP:-nginx}
OUT=""
ALLOW_EXEC=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)    OUT="$2"; shift 2 ;;
    -n|--namespace) NS="$2"; shift 2 ;;
    -r|--region)    REGION="$2"; shift 2 ;;
    -a|--argo-app)  ARGO_APP="$2"; shift 2 ;;
    --no-exec)      ALLOW_EXEC=false; shift ;;
    -h|--help)      sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "Tham số lạ: $1"; exit 1 ;;
  esac
done
[[ -z "$OUT" ]] && OUT="survey-ingress-nginx-$(date +%Y%m%d_%H%M%S).md"

for t in kubectl jq; do
  command -v "$t" >/dev/null || { echo "Thiếu công cụ: $t"; exit 1; }
done
HAS_AWS=false; command -v aws >/dev/null && HAS_AWS=true

: > "$OUT"
say()   { printf '  %s\n' "$*" >&2; }
md()    { printf '%s\n' "$*" >> "$OUT"; }
block() { # $1 = ngôn ngữ, $2 = nội dung
  md '```'"$1"
  if [[ -n "${2//[[:space:]]/}" ]]; then printf '%s\n' "$2" >> "$OUT"
  else printf '(không có dữ liệu)\n' >> "$OUT"; fi
  md '```'; md ''
}
q()    { kubectl "$@" 2>/dev/null; }
awsq() { if $HAS_AWS; then aws "$@" --region "$REGION" 2>/dev/null; fi; }
jqs()  { local r; r=$(printf '%s' "$1" | jq -r "$2" 2>/dev/null); printf '%s' "${r:-?}"; }
jqn()  { local r; r=$(printf '%s' "$1" | jq -r "$2" 2>/dev/null); printf '%s' "${r:-0}"; }

echo "Khảo sát ingress-nginx → $OUT" >&2; echo "" >&2

# ═════════════════════════════════════════════════════════════
say "1/10  Service / DaemonSet / Ingress…"
SVC_JSON=$(q -n "$NS" get svc "$REL"-controller -o json)
DS_JSON=$(q  -n "$NS" get ds  "$REL"-controller -o json)
ING_JSON=$(q get ingress -A -o json)

SVC_TYPE=$(jqs  "$SVC_JSON" '.spec.type // "?"')
ETP=$(jqs       "$SVC_JSON" '.spec.externalTrafficPolicy // "?"')
NODEPORTS=$(jqs "$SVC_JSON" '[.spec.ports[]? | "\(.port)→\(.nodePort // "-")"] | join(", ")')
LB_HOST=$(jqs   "$SVC_JSON" '.status.loadBalancer.ingress[0].hostname // ""')
HOSTPORTS=$(jqs "$DS_JSON"  '[.spec.template.spec.containers[0].ports[]? | select(.hostPort) | "\(.name):\(.hostPort)"] | join(", ")')
DS_DESIRED=$(jqn "$DS_JSON" '.status.desiredNumberScheduled // 0')
DS_READY=$(jqn   "$DS_JSON" '.status.numberReady // 0')
MAXUNAVAIL=$(jqs "$DS_JSON" '.spec.updateStrategy.rollingUpdate.maxUnavailable // "mặc định (1)"')
ING_COUNT=$(jqn  "$ING_JSON" '[.items[]?] | length')

ANNOT_KINDS=$(printf '%s' "$ING_JSON" | jq -r '.items[]? | (.metadata.annotations // {} | keys[])' 2>/dev/null \
              | grep -c '^nginx\.ingress\.kubernetes\.io' || true)
ANNOT_DISTINCT=$(printf '%s' "$ING_JSON" | jq -r '.items[]? | (.metadata.annotations // {} | keys[])' 2>/dev/null \
              | grep '^nginx\.ingress\.kubernetes\.io' | sort -u | wc -l | tr -d ' ')
SNIPPET_VARIANTS=$(printf '%s' "$ING_JSON" | jq -r '
  [.items[]? | .metadata.annotations["nginx.ingress.kubernetes.io/configuration-snippet"] // empty]
  | map(gsub("\\s+";" ") | sub("^ ";"") | sub(" $";"")) | unique | length' 2>/dev/null)
SNIPPET_USERS=$(printf '%s' "$ING_JSON" | jq -r '.items[]? | select(.metadata.annotations["nginx.ingress.kubernetes.io/configuration-snippet"]) | .metadata.name' 2>/dev/null | grep -c . || true)
HAS_SM=$(q  -n "$NS" get servicemonitor -o name | grep -c . || true)
HAS_PDB=$(q -n "$NS" get pdb -o name | grep -c . || true)

# ═════════════════════════════════════════════════════════════
say "2/10  Classic ELB + security group…"
LB_KIND="?"; LB_INSTANCE_PORTS=""; LB_RAW=""; LB_SCHEME="?"; CLB_SGS=""
SG_RAW=""; SG_OPEN="chưa xác định — thiếu AWS CLI hoặc quyền đọc"
if [[ -n "$LB_HOST" && "$LB_HOST" != "?" ]] && $HAS_AWS; then
  LB_NAME="${LB_HOST%%-*}"
  LB_RAW=$(awsq elb describe-load-balancers --load-balancer-names "$LB_NAME" --output json)
  if [[ -n "$LB_RAW" ]]; then
    LB_KIND="Classic ELB"
    LB_INSTANCE_PORTS=$(jqs "$LB_RAW" '[.LoadBalancerDescriptions[0].ListenerDescriptions[].Listener | "\(.LoadBalancerPort)→instance:\(.InstancePort)"] | join(", ")')
    LB_SCHEME=$(jqs "$LB_RAW" '.LoadBalancerDescriptions[0].Scheme')
    CLB_SGS=$(jqs   "$LB_RAW" '.LoadBalancerDescriptions[0].SecurityGroups | join(" ")')
  fi
fi

# ── Câu hỏi số một: CLB có gọi thẳng từ Internet được không? ──
if [[ -n "${CLB_SGS// /}" && "$CLB_SGS" != "?" ]] && $HAS_AWS; then
  SG_RAW=$(awsq ec2 describe-security-groups --group-ids $CLB_SGS --output json)
  OPEN_N=$(jqs  "$SG_RAW" '[.SecurityGroups[]?.IpPermissions[]?.IpRanges[]? | select(.CidrIp=="0.0.0.0/0")] | length')
  FROM_SG=$(jqs "$SG_RAW" '[.SecurityGroups[]?.IpPermissions[]?.UserIdGroupPairs[]?.GroupId] | unique | join(", ")')
  if [[ "$OPEN_N" =~ ^[1-9] ]]; then
    SG_OPEN="🔴 **CÓ mở 0.0.0.0/0** — gọi thẳng CLB được, bỏ qua cả ALB lẫn WAF"
  elif [[ -n "${FROM_SG// /}" && "$FROM_SG" != "?" ]]; then
    SG_OPEN="✅ chỉ nhận từ security group \`$FROM_SG\`"
  else
    SG_OPEN="⚠️ không thấy 0.0.0.0/0 nhưng cũng không giới hạn theo SG — đọc mục 1.1"
  fi
fi

# ═════════════════════════════════════════════════════════════
say "3/10  Tìm ALB đứng trước + WAF…"
ALB_LIST=""; ALB_SUMMARY=""; WAF_SUMMARY=""; WAF_ACLS=""
if $HAS_AWS; then
  ALB_LIST=$(awsq elbv2 describe-load-balancers --output json)
  ALB_SUMMARY=$(printf '%s' "$ALB_LIST" | jq -r '.LoadBalancers[]? | "\(.LoadBalancerName)\t\(.Type)\t\(.Scheme)\t\(.DNSName)"' 2>/dev/null)
  while IFS= read -r arn; do
    [[ -z "$arn" ]] && continue
    nm=$(printf '%s' "$ALB_LIST" | jq -r --arg a "$arn" '.LoadBalancers[]|select(.LoadBalancerArn==$a)|.LoadBalancerName' 2>/dev/null)
    acl=$(awsq wafv2 get-web-acl-for-resource --resource-arn "$arn" --output json | jq -r '.WebACL.Name // empty' 2>/dev/null)
    WAF_SUMMARY+="$nm → ${acl:-<KHÔNG có WAF>}"$'\n'
  done < <(printf '%s' "$ALB_LIST" | jq -r '.LoadBalancers[]? | select(.Type=="application") | .LoadBalancerArn' 2>/dev/null)
  WAF_ACLS=$(awsq wafv2 list-web-acls --scope REGIONAL --output json | jq -r '.WebACLs[]? | "\(.Name)  id=\(.Id)"' 2>/dev/null)
fi

# ═════════════════════════════════════════════════════════════
say "4/10  Đọc nginx.conf đã render…"
NGINX_REALIP=""; REALIP_RECURSIVE="?"
if [[ "$ALLOW_EXEC" == true ]]; then
  POD=$(q -n "$NS" get pod -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')
  if [[ -n "$POD" ]]; then
    NGINX_REALIP=$(kubectl -n "$NS" exec "$POD" -- cat /etc/nginx/nginx.conf 2>/dev/null \
                   | grep -nE 'real_ip_header|set_real_ip_from|real_ip_recursive|proxy_set_header X-Forwarded-For' | head -40)
    if   printf '%s' "$NGINX_REALIP" | grep -q 'real_ip_recursive on';  then REALIP_RECURSIVE="on"
    elif printf '%s' "$NGINX_REALIP" | grep -q 'real_ip_recursive off'; then REALIP_RECURSIVE="off"
    else REALIP_RECURSIVE="không khai báo → nginx mặc định \`off\`"; fi
  fi
else
  REALIP_RECURSIVE="bỏ qua (--no-exec)"
fi

# ═════════════════════════════════════════════════════════════
say "5/10  Viết kết luận…"
md "# Khảo sát ingress-nginx"
md ""
md "| | |"
md "|---|---|"
md "| Thời điểm | \`$(date '+%Y-%m-%d %H:%M:%S %Z')\` |"
md "| Namespace / Release | \`$NS\` / \`$REL\` |"
md "| Region | \`$REGION\` |"
md "| Cluster | \`$(kubectl config current-context 2>/dev/null || echo '?')\` |"
md "| AWS CLI | $($HAS_AWS && echo 'có' || echo '**không có** → mục 1 thiếu dữ liệu ELB/ALB/WAF') |"
md ""
md "> Khảo sát chỉ đọc. Không thay đổi gì trên cluster hay AWS."
md ""
md "---"
md ""
md "## 0. Kết luận nhanh"
md ""
md "### A. Bảo mật đường vào"
md ""
md "| Câu hỏi | Kết quả |"
md "|---|---|"
md "| **CLB có gọi thẳng từ Internet được không?** | $SG_OPEN |"
md "| CLB scheme | \`$LB_SCHEME\` |"
md "| CLB security group | \`${CLB_SGS:-?}\` |"
md "| \`real_ip_recursive\` | $REALIP_RECURSIVE |"
md "| externalTrafficPolicy | \`$ETP\` |"
md ""
md "> **Vì sao quan trọng:** chuỗi thiết kế là Client → ALB (WAF) → CLB → NodePort → nginx."
md "> ALB *append* \`X-Forwarded-For\` nên client không spoof được qua đường đó."
md "> Nhưng nếu CLB mở \`0.0.0.0/0\` thì gọi thẳng CLB sẽ bỏ qua ALB và WAF, và vì"
md "> không còn ai chèn XFF nên client tự đặt header này → nginx tin →"
md "> **vượt \`whitelist-source-range\`**. Cần siết ngay, không chờ đợt nâng cấp."
md ""
md "### B. Đường traffic"
md ""
md "| Câu hỏi | Kết quả |"
md "|---|---|"
md "| Loại Load Balancer | $LB_KIND |"
md "| Listener → instance port | \`${LB_INSTANCE_PORTS:-?}\` |"
md "| Service type | \`$SVC_TYPE\` |"
md "| NodePort | \`${NODEPORTS:-?}\` |"
md "| hostPort trên DaemonSet | \`${HOSTPORTS:-không có}\` |"
md "| Pod controller | $DS_READY / $DS_DESIRED sẵn sàng |"
md "| maxUnavailable | \`$MAXUNAVAIL\` |"
md ""
md "### C. Cấu hình cần xử lý khi nâng cấp"
md ""
md "| Câu hỏi | Kết quả |"
md "|---|---|"
md "| Tổng số Ingress | $ING_COUNT |"
md "| Loại annotation nginx | $ANNOT_DISTINCT loại / $ANNOT_KINDS lần dùng |"
md "| Ingress dùng \`configuration-snippet\` | $SNIPPET_USERS |"
md "| Biến thể snippet *(chuẩn hoá khoảng trắng)* | **$SNIPPET_VARIANTS** |"
md "| ServiceMonitor | $([[ "$HAS_SM" -gt 0 ]] && echo 'có' || echo '**không có**') |"
md "| PodDisruptionBudget | $([[ "$HAS_PDB" -gt 0 ]] && echo 'có' || echo '**không có**') |"
md ""
md "### D. Cần đọc kỹ"
md ""
[[ "$ETP" == "Cluster" ]] && md "- \`externalTrafficPolicy: Cluster\` → source IP bị SNAT, cơ chế khôi phục client IP đang thật sự có tác dụng. Phải thay bằng tuỳ chọn ConfigMap trước khi nâng version."
[[ "$ETP" == "Local" ]]   && md "- \`externalTrafficPolicy: Local\` → nginx nhận client IP thật ngay ở tầng service; annotation khôi phục IP **có thể đã thừa**."
if [[ "$SNIPPET_VARIANTS" == "1" ]]; then
  md "- Cả $SNIPPET_USERS ingress dùng **cùng một nội dung snippet** → gom về ConfigMap xử lý được một lần."
elif [[ "$SNIPPET_VARIANTS" =~ ^[0-9]+$ && "$SNIPPET_VARIANTS" -gt 1 ]]; then
  md "- Có **$SNIPPET_VARIANTS biến thể snippet** thật sự khác nhau → xử lý theo nhóm, xem mục 2.2."
fi
[[ "$ANNOT_DISTINCT" -gt 1 ]] && md "- Dùng **$ANNOT_DISTINCT loại annotation nginx**. Bản 1.11+ siết validation — đối chiếu giá trị thực ở mục 2.3 và 2.4."
[[ "$HAS_SM" -eq 0 ]] && md "- Không có ServiceMonitor → **bật metrics trước khi nâng** để có baseline error rate."
[[ "$HAS_PDB" -eq 0 ]] && md "- Không có PodDisruptionBudget cho ingress controller."
md ""
md "---"
md ""

# ═════════════════════════════════════════════════════════════
say "6/10  Mục 1 — WAF / ALB / ELB…"
md "## 1. Đường vào — WAF, ALB, ELB, Service"
md ""
md "### 1.1 Security group của Classic ELB — **quan trọng nhất**"
block json "$(printf '%s' "$SG_RAW" | jq -r '[.SecurityGroups[]? | {GroupId, GroupName, Ingress:[.IpPermissions[]? | {Protocol:.IpProtocol, FromPort, ToPort, Cidrs:[.IpRanges[]?.CidrIp], FromSG:[.UserIdGroupPairs[]?.GroupId]}]}]' 2>/dev/null)"
md "### 1.2 ALB trong region"
md ""
md "| Tên | Loại | Scheme | DNS |"
md "|---|---|---|---|"
if [[ -n "$ALB_SUMMARY" ]]; then
  while IFS=$'\t' read -r n t s d; do
    [[ -z "$n" ]] && continue
    md "| \`$n\` | $t | $s | \`$d\` |"
  done <<< "$ALB_SUMMARY"
else
  md "| *(không đọc được — thiếu AWS CLI hoặc quyền elbv2)* | | | |"
fi
md ""
md "### 1.3 WAF gắn vào ALB nào"
md ""
md "Nếu ALB phục vụ các domain này mà hiện \`<KHÔNG có WAF>\` thì WAF đang không bảo vệ đường đi thực tế."
md ""
block text "$WAF_SUMMARY"
md "### 1.4 Web ACL đang có trong region"
block text "$WAF_ACLS"
md "### 1.5 Target group của ALB — xem ALB trỏ vào đâu"
block json "$(awsq elbv2 describe-target-groups --output json | jq -r '[.TargetGroups[]? | {Name:.TargetGroupName, TargetType, Port, Protocol, VpcId, LBs:.LoadBalancerArns}]' 2>/dev/null)"
md "### 1.6 DNS thực tế của các domain"
md ""
md "Cho biết client vào qua ALB, qua CDN, hay thẳng vào CLB."
md ""
DNSOUT=""
if command -v dig >/dev/null; then
  while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    DNSOUT+="$h"$'\n'"    $(dig +short "$h" 2>/dev/null | tr '\n' ' ')"$'\n'
  done < <(printf '%s' "$ING_JSON" | jq -r '[.items[]?.spec.rules[]?.host] | unique | .[]' 2>/dev/null | head -12)
elif command -v nslookup >/dev/null; then
  DNSOUT=$(nslookup "$(printf '%s' "$ING_JSON" | jq -r '[.items[]?.spec.rules[]?.host]|unique|.[0]' 2>/dev/null)" 2>/dev/null)
else
  DNSOUT="(không có dig/nslookup)"
fi
block text "$DNSOUT"
md "### 1.7 Service \`$REL-controller\`"
block json "$(printf '%s' "$SVC_JSON" | jq -r '{type:.spec.type, externalTrafficPolicy:.spec.externalTrafficPolicy, ports:.spec.ports, annotations:.metadata.annotations, loadBalancer:.status.loadBalancer}' 2>/dev/null)"
md "### 1.8 Cổng trên DaemonSet"
block text "$(printf '%s' "$DS_JSON" | jq -r '.spec.template.spec.containers[0].ports[]? | "name=\(.name)  container=\(.containerPort)  host=\(.hostPort // "-")"' 2>/dev/null)"
md "### 1.9 Classic ELB đầy đủ"
block json "$LB_RAW"

# ═════════════════════════════════════════════════════════════
say "7/10  Mục 2 — annotation + giá trị thực…"
md "## 2. Annotation trên Ingress"
md ""
md "### 2.1 Thống kê theo loại"
block text "$(printf '%s' "$ING_JSON" | jq -r '.items[]? | (.metadata.annotations // {} | keys[])' 2>/dev/null | grep '^nginx\.ingress\.kubernetes\.io' | sort | uniq -c | sort -rn)"
md "### 2.2 Biến thể \`configuration-snippet\`"
block nginx "$(printf '%s' "$ING_JSON" | jq -r '
  [.items[]? | .metadata.annotations["nginx.ingress.kubernetes.io/configuration-snippet"] // empty]
  | group_by(gsub("\\s+";" ") | sub("^ ";"") | sub(" $";""))
  | map("=== \(length) ingress dùng nội dung này ===\n\(.[0])") | join("\n")' 2>/dev/null)"
md "### 2.3 Giá trị \`whitelist-source-range\`"
md ""
md "Bản 1.11+ siết validation annotation — giá trị sai định dạng sẽ bị **từ chối** khi apply."
md ""
block text "$(printf '%s' "$ING_JSON" | jq -r '.items[]? | select(.metadata.annotations["nginx.ingress.kubernetes.io/whitelist-source-range"]) | "\(.metadata.namespace)/\(.metadata.name)\n    \(.metadata.annotations["nginx.ingress.kubernetes.io/whitelist-source-range"])"' 2>/dev/null)"
md "### 2.4 Giá trị CORS"
block text "$(printf '%s' "$ING_JSON" | jq -r '.items[]? | .metadata.namespace as $n | .metadata.name as $m | (.metadata.annotations // {} | to_entries[] | select(.key|test("cors")) | "\($n)/\($m)\n    \(.key) = \(.value)")' 2>/dev/null)"
md "### 2.5 Toàn bộ annotation nginx kèm giá trị"
block text "$(printf '%s' "$ING_JSON" | jq -r '.items[]? | .metadata.namespace as $n | .metadata.name as $m | (.metadata.annotations // {} | to_entries[] | select(.key|startswith("nginx.ingress.kubernetes.io")) | "\($n)/\($m)\t\(.key|sub("nginx.ingress.kubernetes.io/";""))\t\(.value|tostring|gsub("\n";"⏎")|.[0:70])")' 2>/dev/null | sort)"

# ═════════════════════════════════════════════════════════════
say "8/10  Mục 3 — cấu hình controller…"
md "## 3. Cấu hình controller đang chạy"
md ""
md "### 3.1 nginx.conf đã render — chỉ thị real_ip"
md ""
md "Quyết định \`X-Forwarded-For\` có spoof được không. \`real_ip_recursive off\` (mặc định)"
md "nghĩa là nginx lấy **entry cuối cùng** của XFF — chính là IP mà ALB nối vào, nên spoof"
md "qua đường ALB không ăn. Nếu \`on\` thì nginx đi ngược từ phải sang, bỏ qua các IP tin cậy."
md ""
block nginx "$NGINX_REALIP"
md "### 3.2 Args"
block text "$(printf '%s' "$DS_JSON" | jq -r '.spec.template.spec.containers[0].args[]?' 2>/dev/null)"
md "### 3.3 Image"
block text "$(printf '%s' "$DS_JSON" | jq -r '.spec.template.spec.containers[0].image' 2>/dev/null)"
md "### 3.4 ConfigMap"
block json "$(q -n "$NS" get cm "$REL"-controller -o json | jq '.data' 2>/dev/null)"
md "### 3.5 ConfigMap TCP/UDP"
block text "$(q -n "$NS" get cm -o name | grep -Ei 'tcp|udp')"
md "### 3.6 IngressClass"
block text "$(q get ingressclass -o json | jq -r '.items[]? | "name=\(.metadata.name)  controller=\(.spec.controller)  default=\(.metadata.annotations["ingressclass.kubernetes.io/is-default-class"] // "false")"' 2>/dev/null)"
md "### 3.7 Resources"
block json "$(printf '%s' "$DS_JSON" | jq -r '.spec.template.spec.containers[0].resources' 2>/dev/null)"

# ═════════════════════════════════════════════════════════════
say "9/10  Mục 4-6 — webhook, trạng thái, TLS…"
md "## 4. Admission webhook — đường khai thác CVE-2025-1974"
block text "$(q get validatingwebhookconfiguration "$REL"-admission -o json | jq -r '.webhooks[]? | "webhook=\(.name)\n  failurePolicy=\(.failurePolicy)\n  service=\(.clientConfig.service.namespace)/\(.clientConfig.service.name):\(.clientConfig.service.port // 443)\n  timeoutSeconds=\(.timeoutSeconds // "-")"' 2>/dev/null)"

md "## 5. Trạng thái & khả năng quan sát"
md ""
md "### 5.1 DaemonSet"
block text "$(printf '%s' "$DS_JSON" | jq -r '"desired=\(.status.desiredNumberScheduled)  ready=\(.status.numberReady)  updated=\(.status.updatedNumberScheduled)  strategy=\(.spec.updateStrategy.type)  maxUnavailable=\(.spec.updateStrategy.rollingUpdate.maxUnavailable // "1 (mặc định)")"' 2>/dev/null)"
md "### 5.2 PodDisruptionBudget"
block text "$(q -n "$NS" get pdb -o wide)"
md "### 5.3 ServiceMonitor"
block text "$(q -n "$NS" get servicemonitor -o name)"
md "### 5.4 Pod"
block text "$(q -n "$NS" get pods -o wide)"
md "### 5.5 Cảnh báo gần đây"
block text "$(q -n "$NS" get events --field-selector type=Warning --sort-by=.lastTimestamp | tail -25)"

md "## 6. TLS"
md ""
md "### 6.1 Secret TLS được ingress tham chiếu"
block text "$(printf '%s' "$ING_JSON" | jq -r '.items[]? | .metadata.namespace as $n | (.spec.tls // [])[] | "\($n)/\(.secretName)"' 2>/dev/null | sort -u)"
md "### 6.2 Secret do cert-manager quản lý"
block text "$(q get secret -A -l controller.cert-manager.io/fao=true -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')"
md "### 6.3 Certificate resource"
block text "$(q get certificate -A -o wide)"
md "### 6.4 Hạn dùng"
md ""
md "| Namespace | Secret | Hết hạn | Còn lại | Issuer |"
md "|---|---|---|---|---|"
NOW=$(date +%s)
printf '%s' "$ING_JSON" | jq -r '.items[]? | .metadata.namespace as $n | (.spec.tls // [])[] | "\($n) \(.secretName)"' 2>/dev/null | sort -u \
| while read -r ns sec; do
    crt=$(q -n "$ns" get secret "$sec" -o jsonpath='{.data.tls\.crt}' | base64 -d 2>/dev/null)
    end=""; iss=""; left="*?*"
    if [[ -n "$crt" ]]; then
      end=$(printf '%s' "$crt" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      iss=$(printf '%s' "$crt" | openssl x509 -noout -issuer  2>/dev/null | sed 's/.*CN *= *//; s/,.*//')
      if [[ -n "$end" ]]; then
        ep=$(date -d "$end" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$end" +%s 2>/dev/null)
        if [[ -n "$ep" ]]; then
          d=$(( (ep - NOW) / 86400 ))
          if   [[ "$d" -lt 0  ]]; then left="🔴 **quá hạn ${d#-} ngày**"
          elif [[ "$d" -lt 60 ]]; then left="⚠️ **còn $d ngày**"
          else                          left="còn $d ngày"; fi
        fi
      fi
    fi
    md "| \`$ns\` | \`$sec\` | ${end:-*không đọc được*} | $left | ${iss:-*?*} |"
  done
md ""

# ═════════════════════════════════════════════════════════════
say "10/10 Mục 7 — GitOps…"
md "## 7. GitOps — sửa ở đâu"
md ""
md "### 7.1 Nguồn của ArgoCD app \`$ARGO_APP\`"
md ""
md "Đây là repo phải sửa để gỡ \`configuration-snippet\` khỏi các Ingress."
md ""
block json "$(q -n argocd get application "$ARGO_APP" -o json | jq '{repoURL:(.spec.source.repoURL // .spec.sources), path:.spec.source.path, targetRevision:.spec.source.targetRevision, destination:.spec.destination, syncPolicy:.spec.syncPolicy, status:{sync:.status.sync.status, health:.status.health.status}}' 2>/dev/null)"
md "### 7.2 Ingress nào do ai quản"
md ""
md "| Ingress | ArgoCD app |"
md "|---|---|"
printf '%s' "$ING_JSON" | jq -r '.items[]? | "| `\(.metadata.namespace)/\(.metadata.name)` | \(.metadata.labels["argocd.argoproj.io/instance"] // "— **sửa tay**") |"' 2>/dev/null >> "$OUT"
md ""
md "### 7.3 Helm release"
block text "$(command -v helm >/dev/null && helm list -n "$NS" 2>/dev/null || echo '(helm không có)')"
md "### 7.4 Helm values"
block yaml "$(command -v helm >/dev/null && helm get values "$REL" -n "$NS" 2>/dev/null)"
md ""
md "---"
md ""
md "*Sinh bởi \`survey.sh\`.*"

echo "" >&2; echo "Xong: $OUT" >&2; ls -la "$OUT" >&2
