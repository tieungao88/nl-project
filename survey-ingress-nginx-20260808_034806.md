# Khảo sát ingress-nginx

| | |
|---|---|
| Thời điểm | `2026-08-08 03:48:11 UTC` |
| Namespace | `nginx-ingress` |
| Release | `ingress-nginx` |
| Region | `ap-southeast-1` |
| Cluster | `arn:aws:eks:ap-southeast-1:347599856906:cluster/Ale-EKS-Cluster` |

> Khảo sát chỉ đọc dữ liệu. Không có thay đổi nào được thực hiện.

---

## 0. Kết luận nhanh

| Câu hỏi | Kết quả |
|---|---|
| **ELB trỏ vào đâu?** | **NodePort** — kube-proxy điều phối, rollout êm hơn |
| Loại Load Balancer | Classic ELB |
| Listener → instance port | `443→instance:30924, 80→instance:30828` |
| Service type | `LoadBalancer` |
| externalTrafficPolicy | `Cluster` |
| NodePort được cấp | `80→30828, 443→30924` |
| hostPort trên DaemonSet | `http:80, https:443` |
| Pod controller | 17 / 17 sẵn sàng |
| maxUnavailable khi rollout | `1` |
| Tổng số Ingress | 21 |
| Loại annotation nginx đang dùng | 16 loại / 118 lần xuất hiện |
| Ingress dùng `configuration-snippet` | 19 |
| Số biến thể nội dung snippet | **3** |
| ServiceMonitor (Prometheus) | **không có** — thiếu số liệu lúc rollout |
| PodDisruptionBudget | **không có** |

### Cần đọc kỹ

- `externalTrafficPolicy: Cluster` → source IP bị SNAT, nên annotation khôi phục client IP
  đúng là đang có tác dụng thật. Phải chuyển sang ConfigMap tương đương trước khi nâng version.
- Có **3 biến thể snippet khác nhau** → không gom chung được, phải xử lý từng nhóm. Xem mục 2.
- Đang dùng **16 loại annotation nginx**, không chỉ mỗi snippet. Xem mục 2 để biết loại nào.
- Không có ServiceMonitor → **bật metrics trước khi nâng cấp** để có baseline error rate.

---

## 1. Đường vào — ELB, Service, hostPort

### Service `ingress-nginx-controller`
```yaml
{
  "type": "LoadBalancer",
  "externalTrafficPolicy": "Cluster",
  "ports": [
    {
      "name": "http",
      "nodePort": 30828,
      "port": 80,
      "protocol": "TCP",
      "targetPort": "http"
    },
    {
      "name": "https",
      "nodePort": 30924,
      "port": 443,
      "protocol": "TCP",
      "targetPort": "https"
    }
  ],
  "annotations": {
    "field.cattle.io/publicEndpoints": "[{\"addresses\":[\"ac315cb56769b4242b96bcbea26bb316-654502702.ap-southeast-1.elb.amazonaws.com\"],\"port\":80,\"protocol\":\"TCP\",\"serviceName\":\"nginx-ingress:ingress-nginx-controller\",\"allNodes\":false},{\"addresses\":[\"ac315cb56769b4242b96bcbea26bb316-654502702.ap-southeast-1.elb.amazonaws.com\"],\"port\":443,\"protocol\":\"TCP\",\"serviceName\":\"nginx-ingress:ingress-nginx-controller\",\"allNodes\":false}]",
    "meta.helm.sh/release-name": "ingress-nginx",
    "meta.helm.sh/release-namespace": "nginx-ingress"
  },
  "loadBalancer": {
    "ingress": [
      {
        "hostname": "ac315cb56769b4242b96bcbea26bb316-654502702.ap-southeast-1.elb.amazonaws.com"
      }
    ]
  }
}
```

### Cổng trên DaemonSet
```text
name=http  container=80  host=80  protocol=TCP
name=https  container=443  host=443  protocol=TCP
name=webhook  container=8443  host=-  protocol=TCP
```

### Load Balancer phía AWS

- DNS: `ac315cb56769b4242b96bcbea26bb316-654502702.ap-southeast-1.elb.amazonaws.com`
- Loại: Classic ELB

```json
{
    "LoadBalancerDescriptions": [
        {
            "LoadBalancerName": "ac315cb56769b4242b96bcbea26bb316",
            "DNSName": "ac315cb56769b4242b96bcbea26bb316-654502702.ap-southeast-1.elb.amazonaws.com",
            "CanonicalHostedZoneName": "ac315cb56769b4242b96bcbea26bb316-654502702.ap-southeast-1.elb.amazonaws.com",
            "CanonicalHostedZoneNameID": "Z1LMS91P8CMLE5",
            "ListenerDescriptions": [
                {
                    "Listener": {
                        "Protocol": "TCP",
                        "LoadBalancerPort": 443,
                        "InstanceProtocol": "TCP",
                        "InstancePort": 30924
                    },
                    "PolicyNames": []
                },
                {
                    "Listener": {
                        "Protocol": "TCP",
                        "LoadBalancerPort": 80,
                        "InstanceProtocol": "TCP",
                        "InstancePort": 30828
                    },
                    "PolicyNames": []
                }
            ],
            "Policies": {
                "AppCookieStickinessPolicies": [],
                "LBCookieStickinessPolicies": [],
                "OtherPolicies": []
            },
            "BackendServerDescriptions": [],
            "AvailabilityZones": [
                "ap-southeast-1a",
                "ap-southeast-1b"
            ],
            "Subnets": [
                "subnet-064622148029f7ca8",
                "subnet-0799eaef1280aaef5"
            ],
            "VPCId": "vpc-024d6e1b698cb8267",
            "Instances": [
                {
                    "InstanceId": "i-0cc35cd091b63606d"
                },
                {
                    "InstanceId": "i-011b94cce8cdf4607"
                },
                {
                    "InstanceId": "i-0040311271f87814c"
                },
                {
                    "InstanceId": "i-0328f0a152d942c1e"
                },
                {
                    "InstanceId": "i-075c498d8e684222f"
                },
                {
                    "InstanceId": "i-01cfa4abb2aaa3494"
                },
                {
                    "InstanceId": "i-0c65f525d7d1d596a"
                },
                {
                    "InstanceId": "i-0d8f2ed5119628c5a"
                },
                {
                    "InstanceId": "i-0c4e76cc47e09d869"
                },
                {
                    "InstanceId": "i-0737b028500f58cc3"
                },
                {
                    "InstanceId": "i-04fe54de3ed217186"
                },
                {
                    "InstanceId": "i-0d394ab95b8fc551e"
                },
                {
                    "InstanceId": "i-0e2576c2a9e8c2e81"
                },
                {
                    "InstanceId": "i-0d9010af00f03c9c7"
                },
                {
                    "InstanceId": "i-05c035d43607b8ce7"
                },
                {
                    "InstanceId": "i-03cf0206c4784e85b"
                },
                {
                    "InstanceId": "i-0b223d2946071adbf"
                }
            ],
            "HealthCheck": {
                "Target": "TCP:30828",
                "Interval": 10,
                "Timeout": 5,
                "UnhealthyThreshold": 6,
                "HealthyThreshold": 2
            },
            "SourceSecurityGroup": {
                "OwnerAlias": "347599856906",
                "GroupName": "k8s-elb-ac315cb56769b4242b96bcbea26bb316"
            },
            "SecurityGroups": [
                "sg-056bf232dc7f7c2d6"
            ],
            "CreatedTime": "2023-09-09T20:32:22.300000+00:00",
            "Scheme": "internet-facing"
        }
    ]
}
```

## 2. Annotation trên Ingress

### Thống kê theo loại
```text
     19 nginx.ingress.kubernetes.io/configuration-snippet
     14 nginx.ingress.kubernetes.io/proxy-send-timeout
     14 nginx.ingress.kubernetes.io/proxy-read-timeout
     14 nginx.ingress.kubernetes.io/proxy-connect-timeout
     13 nginx.ingress.kubernetes.io/whitelist-source-range
     12 nginx.ingress.kubernetes.io/proxy-body-size
      6 nginx.ingress.kubernetes.io/session-cookie-name
      6 nginx.ingress.kubernetes.io/session-cookie-max-age
      6 nginx.ingress.kubernetes.io/session-cookie-expires
      6 nginx.ingress.kubernetes.io/affinity
      2 nginx.ingress.kubernetes.io/enable-cors
      2 nginx.ingress.kubernetes.io/cors-allow-origin
      1 nginx.ingress.kubernetes.io/proxy-http-version
      1 nginx.ingress.kubernetes.io/proxy-buffering
      1 nginx.ingress.kubernetes.io/cors-allow-methods
      1 nginx.ingress.kubernetes.io/cors-allow-headers
```

### Biến thể nội dung `configuration-snippet`

Cột đầu là số ingress dùng nội dung đó. Ra đúng **một** dòng nghĩa là toàn bộ giống hệt nhau.

```nginx
     18 
     18 real_ip_header X-Forwarded-For;
      1 real_ip_header X-Forwarded-For; 
     19 set_real_ip_from 10.0.0.0/8;
```

### Chi tiết từng ingress có snippet
```text
── alepay-prod/alepay-api-payment.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── alepay-prod/alepay-gateway.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── alepay-prod/alepay-merchant.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── alepay-prod/alepay-ops-backup.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── alepay-prod/alepay-ops.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── alepay-prod/alepay-v3-merchant.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── alepay-prod/alepay-v3.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For; 

── alepay-prod/alepay-v3.nganluong.vn-admintool
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── alepay-prod/alepay.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── alepay-prod/alepay.nganluong.vn-checkout-virtual-notify
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── alepay-prod/alepay.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── alepay-prod/alepay.vn-appimage
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── alepay-prod/core-checkout.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── alepay-prod/fptpay.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── alepay-prod/report-alepay.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── argocd/deploy-alepay.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── cattle-system/rancher-alepay.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;
── monitoring/grafana-alepay.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;

── monitoring/prometheus-alepay.nganluong.vn
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;
```

### Toàn bộ annotation nginx theo từng ingress
```text
alepay-prod/alepay-api-payment.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/alepay-api-payment.nganluong.vn	nginx.ingress.kubernetes.io/proxy-body-size
alepay-prod/alepay-api-payment.nganluong.vn	nginx.ingress.kubernetes.io/proxy-connect-timeout
alepay-prod/alepay-api-payment.nganluong.vn	nginx.ingress.kubernetes.io/proxy-read-timeout
alepay-prod/alepay-api-payment.nganluong.vn	nginx.ingress.kubernetes.io/proxy-send-timeout
alepay-prod/alepay-api-payment.nganluong.vn	nginx.ingress.kubernetes.io/whitelist-source-range
alepay-prod/alepay-gateway.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/alepay-gateway.nganluong.vn	nginx.ingress.kubernetes.io/whitelist-source-range
alepay-prod/alepay-merchant.nganluong.vn	nginx.ingress.kubernetes.io/affinity
alepay-prod/alepay-merchant.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/alepay-merchant.nganluong.vn	nginx.ingress.kubernetes.io/proxy-body-size
alepay-prod/alepay-merchant.nganluong.vn	nginx.ingress.kubernetes.io/proxy-connect-timeout
alepay-prod/alepay-merchant.nganluong.vn	nginx.ingress.kubernetes.io/proxy-read-timeout
alepay-prod/alepay-merchant.nganluong.vn	nginx.ingress.kubernetes.io/proxy-send-timeout
alepay-prod/alepay-merchant.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-expires
alepay-prod/alepay-merchant.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-max-age
alepay-prod/alepay-merchant.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-name
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	nginx.ingress.kubernetes.io/affinity
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	nginx.ingress.kubernetes.io/proxy-body-size
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	nginx.ingress.kubernetes.io/proxy-connect-timeout
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	nginx.ingress.kubernetes.io/proxy-read-timeout
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	nginx.ingress.kubernetes.io/proxy-send-timeout
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	nginx.ingress.kubernetes.io/session-cookie-expires
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	nginx.ingress.kubernetes.io/session-cookie-max-age
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	nginx.ingress.kubernetes.io/session-cookie-name
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	nginx.ingress.kubernetes.io/whitelist-source-range
alepay-prod/alepay.nganluong.vn	nginx.ingress.kubernetes.io/affinity
alepay-prod/alepay.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-body-size
alepay-prod/alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-connect-timeout
alepay-prod/alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-read-timeout
alepay-prod/alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-send-timeout
alepay-prod/alepay.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-expires
alepay-prod/alepay.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-max-age
alepay-prod/alepay.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-name
alepay-prod/alepay-ops-backup.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/alepay-ops-backup.nganluong.vn	nginx.ingress.kubernetes.io/proxy-body-size
alepay-prod/alepay-ops-backup.nganluong.vn	nginx.ingress.kubernetes.io/proxy-connect-timeout
alepay-prod/alepay-ops-backup.nganluong.vn	nginx.ingress.kubernetes.io/proxy-read-timeout
alepay-prod/alepay-ops-backup.nganluong.vn	nginx.ingress.kubernetes.io/proxy-send-timeout
alepay-prod/alepay-ops-backup.nganluong.vn	nginx.ingress.kubernetes.io/whitelist-source-range
alepay-prod/alepay-ops.nganluong.vn	nginx.ingress.kubernetes.io/affinity
alepay-prod/alepay-ops.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/alepay-ops.nganluong.vn	nginx.ingress.kubernetes.io/proxy-body-size
alepay-prod/alepay-ops.nganluong.vn	nginx.ingress.kubernetes.io/proxy-connect-timeout
alepay-prod/alepay-ops.nganluong.vn	nginx.ingress.kubernetes.io/proxy-read-timeout
alepay-prod/alepay-ops.nganluong.vn	nginx.ingress.kubernetes.io/proxy-send-timeout
alepay-prod/alepay-ops.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-expires
alepay-prod/alepay-ops.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-max-age
alepay-prod/alepay-ops.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-name
alepay-prod/alepay-ops.nganluong.vn	nginx.ingress.kubernetes.io/whitelist-source-range
alepay-prod/alepay-v3-merchant.nganluong.vn	nginx.ingress.kubernetes.io/affinity
alepay-prod/alepay-v3-merchant.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/alepay-v3-merchant.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-expires
alepay-prod/alepay-v3-merchant.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-max-age
alepay-prod/alepay-v3-merchant.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-name
alepay-prod/alepay-v3.nganluong.vn-admintool	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/alepay-v3.nganluong.vn-admintool	nginx.ingress.kubernetes.io/whitelist-source-range
alepay-prod/alepay-v3.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/alepay-v3.nganluong.vn	nginx.ingress.kubernetes.io/cors-allow-headers
alepay-prod/alepay-v3.nganluong.vn	nginx.ingress.kubernetes.io/cors-allow-methods
alepay-prod/alepay-v3.nganluong.vn	nginx.ingress.kubernetes.io/cors-allow-origin
alepay-prod/alepay-v3.nganluong.vn	nginx.ingress.kubernetes.io/enable-cors
alepay-prod/alepay.vn-appimage	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/alepay.vn-appimage	nginx.ingress.kubernetes.io/whitelist-source-range
alepay-prod/alepay.vn	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/core-checkout.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/core-checkout.nganluong.vn	nginx.ingress.kubernetes.io/proxy-body-size
alepay-prod/core-checkout.nganluong.vn	nginx.ingress.kubernetes.io/proxy-connect-timeout
alepay-prod/core-checkout.nganluong.vn	nginx.ingress.kubernetes.io/proxy-read-timeout
alepay-prod/core-checkout.nganluong.vn	nginx.ingress.kubernetes.io/proxy-send-timeout
alepay-prod/core-checkout.nganluong.vn	nginx.ingress.kubernetes.io/whitelist-source-range
alepay-prod/crontab-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-body-size
alepay-prod/crontab-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-connect-timeout
alepay-prod/crontab-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-read-timeout
alepay-prod/crontab-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-send-timeout
alepay-prod/crontab-alepay.nganluong.vn	nginx.ingress.kubernetes.io/whitelist-source-range
alepay-prod/fptpay.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/fptpay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-body-size
alepay-prod/fptpay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-connect-timeout
alepay-prod/fptpay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-read-timeout
alepay-prod/fptpay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-send-timeout
alepay-prod/report-alepay.nganluong.vn	nginx.ingress.kubernetes.io/affinity
alepay-prod/report-alepay.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
alepay-prod/report-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-body-size
alepay-prod/report-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-connect-timeout
alepay-prod/report-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-read-timeout
alepay-prod/report-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-send-timeout
alepay-prod/report-alepay.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-expires
alepay-prod/report-alepay.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-max-age
alepay-prod/report-alepay.nganluong.vn	nginx.ingress.kubernetes.io/session-cookie-name
alepay-prod/report-alepay.nganluong.vn	nginx.ingress.kubernetes.io/whitelist-source-range
alepay-prod/static-alepay.nganluong.vn	nginx.ingress.kubernetes.io/cors-allow-origin
alepay-prod/static-alepay.nganluong.vn	nginx.ingress.kubernetes.io/enable-cors
alepay-prod/static-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-body-size
alepay-prod/static-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-connect-timeout
alepay-prod/static-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-read-timeout
alepay-prod/static-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-send-timeout
argocd/deploy-alepay.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
argocd/deploy-alepay.nganluong.vn	nginx.ingress.kubernetes.io/whitelist-source-range
cattle-system/rancher-alepay.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
cattle-system/rancher-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-buffering
cattle-system/rancher-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-connect-timeout
cattle-system/rancher-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-http-version
cattle-system/rancher-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-read-timeout
cattle-system/rancher-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-send-timeout
monitoring/grafana-alepay.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
monitoring/grafana-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-connect-timeout
monitoring/grafana-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-read-timeout
monitoring/grafana-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-send-timeout
monitoring/grafana-alepay.nganluong.vn	nginx.ingress.kubernetes.io/whitelist-source-range
monitoring/prometheus-alepay.nganluong.vn	nginx.ingress.kubernetes.io/configuration-snippet
monitoring/prometheus-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-body-size
monitoring/prometheus-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-connect-timeout
monitoring/prometheus-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-read-timeout
monitoring/prometheus-alepay.nganluong.vn	nginx.ingress.kubernetes.io/proxy-send-timeout
monitoring/prometheus-alepay.nganluong.vn	nginx.ingress.kubernetes.io/whitelist-source-range
```

## 3. Cấu hình controller đang chạy

### Args
```text
/nginx-ingress-controller
--publish-service=$(POD_NAMESPACE)/ingress-nginx-controller
--election-id=ingress-nginx-leader
--controller-class=k8s.io/ingress-nginx
--ingress-class=nginx
--configmap=$(POD_NAMESPACE)/ingress-nginx-controller
--validating-webhook=:8443
--validating-webhook-certificate=/usr/local/certificates/cert
--validating-webhook-key=/usr/local/certificates/key
```

### Image
```text
registry.k8s.io/ingress-nginx/controller:v1.8.1@sha256:e5c4824e7375fcf2a393e1c03c293b69759af37a9ca6abdb91b13d78a93da8bd
```

### ConfigMap tuning

Rỗng nghĩa là toàn bộ nginx đang chạy tham số mặc định của chart.

```json
{"allow-snippet-annotations":"true","log-format-escape-json":"true","log-format-upstream":"{\"msec\": \"$msec\", \"connection\": \"$connection\", \"connection_requests\": \"$connection_requests\", \"pid\": \"$pid\", \"request_id\": \"$request_id\", \"request_length\": \"$request_length\", \"remote_addr\": \"$remote_addr\", \"remote_user\": \"$remote_user\", \"remote_port\": \"$remote_port\", \"time_local\": \"$time_local\", \"time_iso8601\": \"$time_iso8601\", \"request\": \"$request\", \"request_uri\": \"$request_uri\", \"args\": \"$args\", \"status\": \"$status\", \"body_bytes_sent\": \"$body_bytes_sent\", \"bytes_sent\": \"$bytes_sent\", \"http_referer\": \"$http_referer\", \"http_user_agent\": \"$http_user_agent\", \"http_x_forwarded_for\": \"$http_x_forwarded_for\", \"http_host\": \"$http_host\", \"server_name\": \"$server_name\", \"request_time\": \"$request_time\", \"upstream\": \"$upstream_addr\", \"upstream_connect_time\": \"$upstream_connect_time\", \"upstream_header_time\": \"$upstream_header_time\", \"upstream_response_time\": \"$upstream_response_time\", \"upstream_response_length\": \"$upstream_response_length\", \"upstream_cache_status\": \"$upstream_cache_status\", \"ssl_protocol\": \"$ssl_protocol\", \"ssl_cipher\": \"$ssl_cipher\", \"scheme\": \"$scheme\", \"request_method\": \"$request_method\", \"server_protocol\": \"$server_protocol\", \"pipe\": \"$pipe\", \"gzip_ratio\": \"$gzip_ratio\", \"http_cf_ray\": \"$http_cf_ray\", \"geoip_country_code\": \"$geoip_country_code\"}","real-ip-header":"X-Real-IP"}
```

### ConfigMap TCP/UDP (nếu có thì phải giữ khi nâng cấp)
```text
(không có dữ liệu)
```

### IngressClass
```text
name=nginx  controller=k8s.io/ingress-nginx  default=false
```

### Resource requests / limits
```json
{
  "requests": {
    "cpu": "100m",
    "memory": "90Mi"
  }
}
```

## 4. Admission webhook — đường khai thác của CVE-2025-1974

```text
name=ingress-nginx-admission
```

```text
webhook=validate.nginx.ingress.kubernetes.io
  failurePolicy=Fail
  service=nginx-ingress/ingress-nginx-controller-admission:443
  timeoutSeconds=10
```

## 5. Trạng thái & khả năng quan sát

### DaemonSet
```text
desired=17  ready=17  updated=17  strategy=RollingUpdate  maxUnavailable=1
```

### PodDisruptionBudget
```text
(không có dữ liệu)
```

### ServiceMonitor
```text
(không có dữ liệu)
```

### Pod đang chạy
```text
NAME                             READY   STATUS    RESTARTS   AGE    IP             NODE                                              NOMINATED NODE   READINESS GATES
ingress-nginx-controller-56fhg   1/1     Running   0          204d   10.16.41.211   ip-10-16-41-12.ap-southeast-1.compute.internal    <none>           <none>
ingress-nginx-controller-5cdfk   1/1     Running   0          204d   10.16.41.252   ip-10-16-41-76.ap-southeast-1.compute.internal    <none>           <none>
ingress-nginx-controller-7qpnx   1/1     Running   0          204d   10.16.41.113   ip-10-16-41-83.ap-southeast-1.compute.internal    <none>           <none>
ingress-nginx-controller-b5zfj   1/1     Running   0          204d   10.16.41.192   ip-10-16-41-44.ap-southeast-1.compute.internal    <none>           <none>
ingress-nginx-controller-cn5hr   1/1     Running   0          204d   10.16.41.35    ip-10-16-41-6.ap-southeast-1.compute.internal     <none>           <none>
ingress-nginx-controller-cz4nl   1/1     Running   0          204d   10.16.41.15    ip-10-16-41-152.ap-southeast-1.compute.internal   <none>           <none>
ingress-nginx-controller-ld2rg   1/1     Running   0          204d   10.16.42.72    ip-10-16-42-156.ap-southeast-1.compute.internal   <none>           <none>
ingress-nginx-controller-p7lw9   1/1     Running   0          204d   10.16.42.170   ip-10-16-42-67.ap-southeast-1.compute.internal    <none>           <none>
ingress-nginx-controller-rjtrx   1/1     Running   0          204d   10.16.42.244   ip-10-16-42-145.ap-southeast-1.compute.internal   <none>           <none>
ingress-nginx-controller-sn58h   1/1     Running   0          204d   10.16.42.40    ip-10-16-42-149.ap-southeast-1.compute.internal   <none>           <none>
ingress-nginx-controller-w6cc9   1/1     Running   0          204d   10.16.42.37    ip-10-16-42-23.ap-southeast-1.compute.internal    <none>           <none>
ingress-nginx-controller-w897c   1/1     Running   0          204d   10.16.41.97    ip-10-16-41-117.ap-southeast-1.compute.internal   <none>           <none>
ingress-nginx-controller-w9zvt   1/1     Running   0          204d   10.16.42.201   ip-10-16-42-71.ap-southeast-1.compute.internal    <none>           <none>
ingress-nginx-controller-wn4dt   1/1     Running   0          206d   10.16.41.129   ip-10-16-41-114.ap-southeast-1.compute.internal   <none>           <none>
ingress-nginx-controller-wtj8l   1/1     Running   0          206d   10.16.42.94    ip-10-16-42-144.ap-southeast-1.compute.internal   <none>           <none>
ingress-nginx-controller-wv2hp   1/1     Running   0          204d   10.16.41.150   ip-10-16-41-101.ap-southeast-1.compute.internal   <none>           <none>
ingress-nginx-controller-wxbp4   1/1     Running   0          204d   10.16.42.182   ip-10-16-42-43.ap-southeast-1.compute.internal    <none>           <none>
```

### Cảnh báo gần đây trong namespace
```text
(không có dữ liệu)
```

## 6. TLS — cert của 21 ingress

### Secret TLS đang được tham chiếu
```text
alepay-prod/cert-alepay-2024
alepay-prod/cert-wildcard-nganluong
alepay-prod/wc-nganluong
argocd/wc-nganluong-2025
monitoring/wc-nganluong
```

### Secret do cert-manager quản lý

Phần chênh lệch giữa hai danh sách chính là cert đang cấp thủ công.

```text
(không có dữ liệu)
```

### Certificate resource của cert-manager
```text
(không có dữ liệu)
```

### Hạn dùng từng cert

| Namespace | Secret | Hết hạn | Issuer |
|---|---|---|---|
| `alepay-prod` | `cert-alepay-2024` | May 28 03:18:10 2025 GMT | GlobalSign GCC R6 AlphaSSL CA 2023 |
| `alepay-prod` | `cert-wildcard-nganluong` | May 28 03:18:10 2025 GMT | GlobalSign GCC R6 AlphaSSL CA 2023 |
| `alepay-prod` | `wc-nganluong` | Sep 21 02:54:08 2026 GMT | GlobalSign GCC R6 AlphaSSL CA 2025 |
| `argocd` | `wc-nganluong-2025` | Sep 21 02:54:08 2026 GMT | GlobalSign GCC R6 AlphaSSL CA 2025 |
| `monitoring` | `wc-nganluong` | Sep 20 09:09:19 2025 GMT | GlobalSign GCC R6 AlphaSSL CA 2023 |

## 7. GitOps — ingress do đâu quản lý

| Ingress | ArgoCD app | Managed by |
|---|---|---|
| `alepay-prod/alepay-api-payment.nganluong.vn` | nginx | — |
| `alepay-prod/alepay-gateway.nganluong.vn` | nginx | — |
| `alepay-prod/alepay-merchant.nganluong.vn` | nginx | — |
| `alepay-prod/alepay-ops-backup.nganluong.vn` | nginx | — |
| `alepay-prod/alepay-ops.nganluong.vn` | nginx | — |
| `alepay-prod/alepay-v3-merchant.nganluong.vn` | nginx | — |
| `alepay-prod/alepay-v3.nganluong.vn` | nginx | — |
| `alepay-prod/alepay-v3.nganluong.vn-admintool` | nginx | — |
| `alepay-prod/alepay.nganluong.vn` | nginx | — |
| `alepay-prod/alepay.nganluong.vn-checkout-virtual-notify` | nginx | — |
| `alepay-prod/alepay.vn` | nginx | — |
| `alepay-prod/alepay.vn-appimage` | nginx | — |
| `alepay-prod/core-checkout.nganluong.vn` | nginx | — |
| `alepay-prod/crontab-alepay.nganluong.vn` | nginx | — |
| `alepay-prod/fptpay.nganluong.vn` | nginx | — |
| `alepay-prod/report-alepay.nganluong.vn` | nginx | — |
| `alepay-prod/static-alepay.nganluong.vn` | nginx | — |
| `argocd/deploy-alepay.nganluong.vn` | nginx | — |
| `cattle-system/rancher-alepay.nganluong.vn` | — | — |
| `monitoring/grafana-alepay.nganluong.vn` | nginx | — |
| `monitoring/prometheus-alepay.nganluong.vn` | nginx | — |

### Helm release
```text
NAME         	NAMESPACE    	REVISION	UPDATED                                  	STATUS  	CHART              	APP VERSION
ingress-nginx	nginx-ingress	1       	2023-07-31 09:46:55.620901496 +0700 +0700	deployed	ingress-nginx-4.7.1	1.8.1      
```

### Helm values đang áp dụng
```yaml
USER-SUPPLIED VALUES:
controller:
  hostPort:
    enabled: true
  kind: DaemonSet
```


---

*Sinh bởi `survey.sh` — chỉ đọc, không thay đổi hệ thống.*
