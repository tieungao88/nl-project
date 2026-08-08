#!/usr/bin/env bash
#
# Khảo sát ingress-nginx trước khi lên kế hoạch nâng cấp.
# READ-ONLY: chỉ dùng get/describe/list — không sửa gì trên cluster hay AWS.
#
#   ./survey.sh > survey-$(date +%Y%m%d).txt 2>&1
#
set -uo pipefail

NS=nginx-ingress
REL=ingress-nginx
REGION=${REGION:-ap-southeast-1}

hr() { printf '\n%s\n%s\n' "══ $* " "────────────────────────────────────────────────────────"; }

hr "1. ĐƯỜNG VÀO — ELB trỏ NodePort hay hostPort?"
echo "# Service spec (chú ý type, externalTrafficPolicy, annotations aws-load-balancer-*)"
kubectl -n "$NS" get svc "$REL"-controller -o yaml 2>/dev/null \
  | sed -n '/^metadata:/,/^status:/p'
echo
echo "# externalTrafficPolicy (quyết định có giữ được client IP hay không)"
kubectl -n "$NS" get svc "$REL"-controller -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}' 2>/dev/null
echo
echo "# hostPort thực tế trên DaemonSet"
kubectl -n "$NS" get ds "$REL"-controller \
  -o jsonpath='{range .spec.template.spec.containers[0].ports[*]}{.name}{" container="}{.containerPort}{" host="}{.hostPort}{"\n"}{end}' 2>/dev/null
echo
echo "# ELB phía AWS: loại gì, listener nào, target port nào"
LB_HOST=$(kubectl -n "$NS" get svc "$REL"-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
echo "LB hostname: ${LB_HOST:-<không có>}"
if [[ -n "${LB_HOST:-}" ]]; then
  LB_NAME="${LB_HOST%%-*}"
  echo "--- Classic ELB ---"
  aws elb describe-load-balancers --load-balancer-names "$LB_NAME" --region "$REGION" \
    --query 'LoadBalancerDescriptions[0].{Listeners:ListenerDescriptions[].Listener,HealthCheck:HealthCheck,Instances:length(Instances),Subnets:Subnets}' \
    --output json 2>/dev/null || echo "(không phải Classic ELB, thử ELBv2)"
  echo "--- ELBv2 (ALB/NLB) ---"
  aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?contains(DNSName,'${LB_NAME}')].{Name:LoadBalancerName,Type:Type,Scheme:Scheme,AZs:length(AvailabilityZones)}" \
    --output json 2>/dev/null
fi

hr "2. ANNOTATION — có đúng chỉ 1 loại snippet không?"
echo "# Đếm theo loại annotation nginx trên toàn bộ ingress"
kubectl get ingress -A -o json 2>/dev/null | jq -r '
  .items[] | (.metadata.annotations // {} | keys[])' \
  | grep '^nginx.ingress.kubernetes.io' | sort | uniq -c | sort -rn
echo
echo "# Nội dung snippet từng ingress — kiểm tra có giống nhau hết không"
kubectl get ingress -A -o json 2>/dev/null | jq -r '
  .items[]
  | select(.metadata.annotations["nginx.ingress.kubernetes.io/configuration-snippet"])
  | "── \(.metadata.namespace)/\(.metadata.name)\n\(.metadata.annotations["nginx.ingress.kubernetes.io/configuration-snippet"])"'
echo
echo "# Hash nội dung snippet — nếu ra 1 dòng duy nhất thì cả 21 giống hệt nhau"
kubectl get ingress -A -o json 2>/dev/null | jq -r '
  .items[] | .metadata.annotations["nginx.ingress.kubernetes.io/configuration-snippet"] // empty' \
  | sort | uniq -c

hr "3. CẤU HÌNH ĐANG CHẠY — args, ConfigMap, IngressClass"
echo "# Args của controller (lộ ra các flag đang bật)"
kubectl -n "$NS" get ds "$REL"-controller \
  -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' 2>/dev/null
echo
echo "# ConfigMap tuning hiện tại (rỗng = đang chạy default hoàn toàn)"
kubectl -n "$NS" get cm "$REL"-controller -o jsonpath='{.data}' 2>/dev/null; echo
echo
echo "# TCP/UDP services (nếu có thì phải giữ khi nâng)"
kubectl -n "$NS" get cm -o name 2>/dev/null | grep -E 'tcp|udp' || echo "(không có)"
echo
echo "# IngressClass — kiểm tra chỉ có 1 controller"
kubectl get ingressclass -o custom-columns='NAME:.metadata.name,CONTROLLER:.spec.controller,DEFAULT:.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class' 2>/dev/null

hr "4. ADMISSION WEBHOOK — đường khai thác của CVE-2025-1974"
kubectl get validatingwebhookconfiguration 2>/dev/null | grep -i ingress || echo "(không có)"
echo
kubectl get validatingwebhookconfiguration "$REL"-admission \
  -o jsonpath='{range .webhooks[*]}name={.name}{"\n"}failurePolicy={.failurePolicy}{"\n"}service={.clientConfig.service.namespace}/{.clientConfig.service.name}:{.clientConfig.service.port}{"\n"}{end}' 2>/dev/null

hr "5. TRẠNG THÁI & KHẢ NĂNG QUAN SÁT"
echo "# DaemonSet: update strategy quyết định mức gián đoạn khi rollout"
kubectl -n "$NS" get ds "$REL"-controller \
  -o jsonpath='desired={.status.desiredNumberScheduled} ready={.status.numberReady} strategy={.spec.updateStrategy.type} maxUnavailable={.spec.updateStrategy.rollingUpdate.maxUnavailable}{"\n"}' 2>/dev/null
echo
echo "# PodDisruptionBudget cho ingress (report cho thấy toàn cluster chỉ có 2 PDB)"
kubectl -n "$NS" get pdb 2>/dev/null || echo "(không có PDB)"
echo
echo "# Có ServiceMonitor không — không có nghĩa là không đo được error rate lúc rollout"
kubectl -n "$NS" get servicemonitor 2>/dev/null || echo "(không có ServiceMonitor → Prometheus không scrape ingress-nginx)"
echo
echo "# Resource requests/limits của controller"
kubectl -n "$NS" get ds "$REL"-controller \
  -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}' 2>/dev/null
echo
echo "# Cảnh báo gần đây trong namespace"
kubectl -n "$NS" get events --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -20

hr "6. TLS — 21 ingress đang dùng cert nào, ai cấp"
echo "# Secret TLS mà ingress tham chiếu"
kubectl get ingress -A -o json 2>/dev/null | jq -r '
  .items[] | .metadata.namespace as $ns | (.spec.tls // [])[] | "\($ns)/\(.secretName)"' | sort -u
echo
echo "# Secret do cert-manager quản lý (phần chênh lệch = cert thủ công)"
kubectl get secret -A -l controller.cert-manager.io/fao=true \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "(không có secret nào do cert-manager tạo)"
echo
echo "# Hạn của từng cert đang dùng"
kubectl get ingress -A -o json 2>/dev/null | jq -r '
  .items[] | .metadata.namespace as $ns | (.spec.tls // [])[] | "\($ns) \(.secretName)"' | sort -u \
| while read -r ns sec; do
    end=$(kubectl -n "$ns" get secret "$sec" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
          | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    printf '  %-16s %-28s %s\n' "$ns" "$sec" "${end:-<không đọc được>}"
  done

hr "7. GITOPS — ingress do ai quản, sửa ở đâu"
kubectl get ingress -A -o json 2>/dev/null | jq -r '
  .items[] | "\(.metadata.namespace)/\(.metadata.name)\targocd=\(.metadata.labels["argocd.argoproj.io/instance"] // "-")\thelm=\(.metadata.labels["app.kubernetes.io/managed-by"] // "-")"' \
  | sort | column -t -s $'\t'

hr "XONG"
echo "Gửi lại file kết quả để lên kế hoạch nâng cấp."
