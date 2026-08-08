# Khảo sát ingress-nginx

| | |
|---|---|
| Thời điểm | `2026-08-08 06:00:50 UTC` |
| Namespace / Release | `nginx-ingress` / `ingress-nginx` |
| Region | `ap-southeast-1` |
| Cluster | `arn:aws:eks:ap-southeast-1:347599856906:cluster/Ale-EKS-Cluster` |
| AWS CLI | có |

> Khảo sát chỉ đọc. Không thay đổi gì trên cluster hay AWS.

---

## 0. Kết luận nhanh

### A. Bảo mật đường vào

| Câu hỏi | Kết quả |
|---|---|
| **CLB có gọi thẳng từ Internet được không?** | 🔴 **CÓ mở 0.0.0.0/0** — gọi thẳng CLB được, bỏ qua cả ALB lẫn WAF |
| CLB scheme | `internet-facing` |
| CLB security group | `sg-056bf232dc7f7c2d6` |
| `real_ip_recursive` | không khai báo → nginx mặc định `off` |
| externalTrafficPolicy | `Cluster` |
| **Domain đi qua đường nào?** | ✅ tất cả 17 domain đi qua ALB |
| **Tổng số Classic ELB mở ra Internet** | 🔴 **3 / 3** — xem mục 1.0 |

> **Vì sao quan trọng:** chuỗi thiết kế là Client → ALB (WAF) → CLB → NodePort → nginx.
> ALB *append* `X-Forwarded-For` nên client không spoof được qua đường đó.
> Nhưng nếu CLB mở `0.0.0.0/0` thì gọi thẳng CLB sẽ bỏ qua ALB và WAF, và vì
> không còn ai chèn XFF nên client tự đặt header này → nginx tin →
> **vượt `whitelist-source-range`**. Cần siết ngay, không chờ đợt nâng cấp.

### B. Đường traffic

| Câu hỏi | Kết quả |
|---|---|
| **ALB trỏ vào đâu?** | 🔴 **ALB đi THẲNG vào hostPort của node** (`alb-tg-tls` → instance:443) — rolling update DaemonSet sẽ làm node mất cổng, ALB phải chờ health check mới ngừng gửi traffic |
| Loại Load Balancer | Classic ELB |
| Listener → instance port | `443→instance:30924, 80→instance:30828` |
| Service type | `LoadBalancer` |
| NodePort | `80→30828, 443→30924` |
| hostPort trên DaemonSet | `http:80, https:443` |
| Pod controller | 17 / 17 sẵn sàng |
| maxUnavailable | `1` |

### C. Cấu hình cần xử lý khi nâng cấp

| Câu hỏi | Kết quả |
|---|---|
| Tổng số Ingress | 21 |
| Loại annotation nginx | 16 loại / 118 lần dùng |
| Ingress dùng `configuration-snippet` | 19 |
| Biến thể snippet *(chuẩn hoá khoảng trắng)* | **1** |
| ServiceMonitor | **không có** |
| PodDisruptionBudget | **không có** |

### D. Cần đọc kỹ

- `externalTrafficPolicy: Cluster` → source IP bị SNAT, cơ chế khôi phục client IP đang thật sự có tác dụng. Phải thay bằng tuỳ chọn ConfigMap trước khi nâng version.
- Cả 19 ingress dùng **cùng một nội dung snippet** → gom về ConfigMap xử lý được một lần.
- Dùng **16 loại annotation nginx**. Bản 1.11+ siết validation — đối chiếu giá trị thực ở mục 2.3 và 2.4.
- Không có ServiceMonitor → **bật metrics trước khi nâng** để có baseline error rate.
- Không có PodDisruptionBudget cho ingress controller.
- **3 Classic ELB đang mở `0.0.0.0/0`** — mỗi cái là một đường vào bỏ qua WAF. Đối chiếu cột traffic ở mục 1.0 để biết cái nào là di sản có thể gỡ, cái nào còn dùng và phải siết theo SG.
- **ALB đi thẳng vào hostPort** → kế hoạch rollout phải tính tới việc từng node mất cổng 80/443. Xem deregistration delay và health check ở mục 1.5.

---

## 1. Đường vào — WAF, ALB, ELB, Service

### 1.0 Toàn cảnh Load Balancer — mọi cửa vào của account

Mỗi Classic ELB `internet-facing` có security group mở `0.0.0.0/0` là một đường vào
**bỏ qua ALB và WAF**. Cột traffic cho biết cái nào còn được dùng thật, cái nào là di sản.

> ⚠️ Classic ELB dùng listener **TCP** không phát metric `RequestCount` — chỉ HTTP/HTTPS mới có.
> Vì vậy cột traffic đo cả `EstimatedProcessedBytes` và `EstimatedALBNewConnectionCount`;
> chỉ khi **cả ba** đều bằng 0 mới kết luận là không có traffic.

| Load Balancer | Loại | Scheme | SG mở 0.0.0.0/0 | K8s Service / WAF | Traffic 14 ngày |
|---|---|---|---|---|---|
| `ac315cb56769b4242b96bcbea26bb316` | Classic | internet-facing | 🔴 CÓ | nginx-ingress/ingress-nginx-controller | 🟢 đang có traffic |
| `a4569862880e348aea2bfcddd88936d1` | Classic | internet-facing | 🔴 CÓ | ingress-nginx/ingress-nginx-controller | 🟢 đang có traffic |
| `ac3403930de34478cb19ece85259cdd6` | Classic | internet-facing | 🔴 CÓ | ingress-nginx/ingress-nginx-controller | 🟢 đang có traffic |
| `alepay-ALB` | Application | internet-facing | *(SG riêng)* | WAF: alepay-waf | 🟢 7.3M request |

#### Chi tiết từng Classic ELB
```text
── ac315cb56769b4242b96bcbea26bb316
   DNS          : ac315cb56769b4242b96bcbea26bb316-654502702.ap-southeast-1.elb.amazonaws.com
   scheme       : internet-facing   |  listener: TCP:443→30924,TCP:80→30828  |  instance: 17
   k8s service  : nginx-ingress/ingress-nginx-controller
   traffic 14d  : request=18.5K  bytes=345.1M  conn=3.4M  |  backend error=0
   mở Internet  : 🔴 CÓ
     sg-056bf232dc7f7c2d6 k8s-elb-ac315cb56769b4242b96bcbea26bb316
       tcp 80-80 từ 0.0.0.0/0
       icmp 3-4 từ 0.0.0.0/0
       tcp 443-443 từ 0.0.0.0/0

── a4569862880e348aea2bfcddd88936d1
   DNS          : a4569862880e348aea2bfcddd88936d1-301879731.ap-southeast-1.elb.amazonaws.com
   scheme       : internet-facing   |  listener: TCP:443→30374,TCP:80→30250  |  instance: 0
   k8s service  : ingress-nginx/ingress-nginx-controller
   traffic 14d  : request=0  bytes=5.6M  conn=633.7K  |  backend error=0
   mở Internet  : 🔴 CÓ
     sg-0fc6016a285db9f8e k8s-elb-a4569862880e348aea2bfcddd88936d1
       tcp 80-80 từ 0.0.0.0/0
       icmp 3-4 từ 0.0.0.0/0
       tcp 443-443 từ 0.0.0.0/0

── ac3403930de34478cb19ece85259cdd6
   DNS          : ac3403930de34478cb19ece85259cdd6-600967180.ap-southeast-1.elb.amazonaws.com
   scheme       : internet-facing   |  listener: TCP:443→32492,TCP:80→30690  |  instance: 0
   k8s service  : ingress-nginx/ingress-nginx-controller
   traffic 14d  : request=0  bytes=6.1M  conn=606.6K  |  backend error=0
   mở Internet  : 🔴 CÓ
     sg-024fdcd4395624d6e k8s-elb-ac3403930de34478cb19ece85259cdd6
       tcp 80-80 từ 0.0.0.0/0
       icmp 3-4 từ 0.0.0.0/0
       tcp 443-443 từ 0.0.0.0/0


```

### 1.1 Security group của Classic ELB gắn với ingress — **quan trọng nhất**
```json
[
  {
    "GroupId": "sg-056bf232dc7f7c2d6",
    "GroupName": "k8s-elb-ac315cb56769b4242b96bcbea26bb316",
    "Ingress": [
      {
        "Protocol": "tcp",
        "FromPort": 80,
        "ToPort": 80,
        "Cidrs": [
          "0.0.0.0/0"
        ],
        "FromSG": []
      },
      {
        "Protocol": "icmp",
        "FromPort": 3,
        "ToPort": 4,
        "Cidrs": [
          "0.0.0.0/0"
        ],
        "FromSG": []
      },
      {
        "Protocol": "tcp",
        "FromPort": 443,
        "ToPort": 443,
        "Cidrs": [
          "0.0.0.0/0"
        ],
        "FromSG": []
      }
    ]
  }
]
```

### 1.2 ALB trong region

| Tên | Loại | Scheme | DNS |
|---|---|---|---|
| `alepay-ALB` | application | internet-facing | `alepay-ALB-2094548182.ap-southeast-1.elb.amazonaws.com` |

### 1.3 WAF gắn vào ALB nào

Nếu ALB phục vụ các domain này mà hiện `<KHÔNG có WAF>` thì WAF đang không bảo vệ đường đi thực tế.

```text
alepay-ALB → alepay-waf

```

### 1.4 Web ACL đang có trong region
```text
alepay-waf  id=5a2e5441-3f67-4b37-b94f-724a74f91415
alepay-waf-test  id=2eabbc2d-18d5-4270-a735-4d67bb339f55
```

### 1.5 Target group của ALB — instance nào, cổng nào, health ra sao

`TargetType: instance` + cổng **80/443** nghĩa là ALB đi thẳng vào `hostPort` của node,
không qua Classic ELB. Khi đó rolling update DaemonSet làm node mất cổng, và ALB chỉ
ngừng gửi traffic sau khi health check đủ số lần thất bại — đó là cửa sổ rớt request.

🔴 **ALB đi THẲNG vào hostPort của node** (`alb-tg-tls` → instance:443) — rolling update DaemonSet sẽ làm node mất cổng, ALB phải chờ health check mới ngừng gửi traffic

```text
── alb-tg  (type=instance, port=80)
   health check      : interval=30s timeout=5s healthy=5 unhealthy=2 path=/
   deregistration    : 300s
   target            : 17/17 healthy
     i-0328f0a152d942c1e:80  healthy  
     i-075c498d8e684222f:80  healthy  
     i-04fe54de3ed217186:80  healthy  
     i-0b223d2946071adbf:80  healthy  
     i-0c65f525d7d1d596a:80  healthy  
     i-0e2576c2a9e8c2e81:80  healthy  
     i-011b94cce8cdf4607:80  healthy  
     i-01cfa4abb2aaa3494:80  healthy  
     i-0737b028500f58cc3:80  healthy  
     i-0d8f2ed5119628c5a:80  healthy  
     i-0d394ab95b8fc551e:80  healthy  
     i-03cf0206c4784e85b:80  healthy  
     i-0d9010af00f03c9c7:80  healthy  
     i-0040311271f87814c:80  healthy  
     i-05c035d43607b8ce7:80  healthy  
     i-0cc35cd091b63606d:80  healthy  
     i-0c4e76cc47e09d869:80  healthy  

── alb-tg-tls  (type=instance, port=443)
   health check      : interval=30s timeout=5s healthy=5 unhealthy=2 path=/
   deregistration    : 3000s
   target            : 17/17 healthy
     i-0d9010af00f03c9c7:443  healthy  
     i-075c498d8e684222f:443  healthy  
     i-01cfa4abb2aaa3494:443  healthy  
     i-03cf0206c4784e85b:443  healthy  
     i-0b223d2946071adbf:443  healthy  
     i-0737b028500f58cc3:443  healthy  
     i-05c035d43607b8ce7:443  healthy  
     i-0328f0a152d942c1e:443  healthy  
     i-0cc35cd091b63606d:443  healthy  
     i-0c4e76cc47e09d869:443  healthy  
     i-0d8f2ed5119628c5a:443  healthy  
     i-0d394ab95b8fc551e:443  healthy  
     i-011b94cce8cdf4607:443  healthy  
     i-04fe54de3ed217186:443  healthy  
     i-0040311271f87814c:443  healthy  
     i-0e2576c2a9e8c2e81:443  healthy  
     i-0c65f525d7d1d596a:443  healthy  


```

#### Định nghĩa target group
```json
[
  {
    "Name": "alb-tg",
    "TargetType": "instance",
    "Port": 80,
    "Protocol": "HTTP",
    "VpcId": "vpc-024d6e1b698cb8267",
    "HealthCheck": {
      "Interval": 30,
      "Timeout": 5,
      "Healthy": 5,
      "Unhealthy": 2,
      "Path": "/"
    },
    "AttachedTo": [
      "arn:aws:elasticloadbalancing:ap-southeast-1:347599856906:loadbalancer/app/alepay-ALB/5f98d146561ba1a9"
    ]
  },
  {
    "Name": "alb-tg-tls",
    "TargetType": "instance",
    "Port": 443,
    "Protocol": "HTTPS",
    "VpcId": "vpc-024d6e1b698cb8267",
    "HealthCheck": {
      "Interval": 30,
      "Timeout": 5,
      "Healthy": 5,
      "Unhealthy": 2,
      "Path": "/"
    },
    "AttachedTo": [
      "arn:aws:elasticloadbalancing:ap-southeast-1:347599856906:loadbalancer/app/alepay-ALB/5f98d146561ba1a9"
    ]
  },
  {
    "Name": "alb-tg-tls-test",
    "TargetType": "instance",
    "Port": 443,
    "Protocol": "HTTPS",
    "VpcId": "vpc-024d6e1b698cb8267",
    "HealthCheck": {
      "Interval": 30,
      "Timeout": 5,
      "Healthy": 5,
      "Unhealthy": 2,
      "Path": "/"
    },
    "AttachedTo": []
  }
]
```

### 1.6 DNS thực tế — domain đi qua đường nào

Đối chiếu IP của từng domain với IP của ALB và của Classic ELB. Domain nào trỏ
thẳng CLB là traffic của nó **không đi qua WAF**.

- Công cụ phân giải dùng: `getent`
- ALB `alepay-ALB-2094548182.ap-southeast-1.elb.amazonaws.com` →` 18.141.5.201 54.251.6.204 `
- CLB `ac315cb56769b4242b96bcbea26bb316-654502702.ap-southeast-1.elb.amazonaws.com` →` 18.139.195.78 52.77.183.35 `

✅ tất cả 17 domain đi qua ALB

| Domain | IP phân giải | Đường đi |
|---|---|---|
| `alepay-api-payment.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `alepay-gateway.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `alepay-merchant.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `alepay-ops-backup.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `alepay-ops.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `alepay-v3-merchant.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `alepay-v3.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `alepay.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `alepay.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `core-checkout.nganluong.vn` | `—` | ❔ không phân giải được |
| `crontab-alepay.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `deploy-alepay.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `fptpay.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `grafana-alepay-dr.nganluong.vn` | `—` | ❔ không phân giải được |
| `grafana-alepay.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `prometheus-alepay.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `rancher-alepay.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `report-alepay.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |
| `static-alepay.nganluong.vn` | `18.141.5.201 54.251.6.204 ` | ✅ qua ALB (có WAF) |

### 1.7 Service `ingress-nginx-controller`
```json
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

### 1.8 Cổng trên DaemonSet
```text
name=http  container=80  host=80
name=https  container=443  host=443
name=webhook  container=8443  host=-
```

### 1.9 Classic ELB đầy đủ
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

### 2.1 Thống kê theo loại
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

### 2.2 Biến thể `configuration-snippet`
```nginx
=== 19 ingress dùng nội dung này ===
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;
```

### 2.3 Giá trị `whitelist-source-range`

Bản 1.11+ siết validation annotation — giá trị sai định dạng sẽ bị **từ chối** khi apply.

```text
alepay-prod/alepay-api-payment.nganluong.vn
    124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14.177.239.203/32,118.69.34.233/32,18.136.230.133/32,54.251.103.128/32,10.16.2.0/24,10.16.1.0/24,113.161.48.116/32,118.69.34.152/32,103.109.32.0/24,103.109.33.0/24,103.52.113.234/32,103.52.113.202/32
alepay-prod/alepay-gateway.nganluong.vn
    124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14.177.239.203/32,118.69.34.233/32,18.136.230.133/32,54.251.103.128/32,10.16.2.0/24,10.16.1.0/24,113.161.48.116/32,118.69.34.152/32,103.109.32.0/24,103.109.33.0/24,103.52.113.234/32,103.52.113.202/32,103.111.247.15/32
alepay-prod/alepay-ops-backup.nganluong.vn
    14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14.177.239.203/32,103.109.32.44/32,118.69.34.233/32,103.109.32.47/32,18.136.230.133/32,54.251.103.128/32,10.16.2.0/24,10.16.1.0/24,103.109.32.46/32,103.109.32.38/32,171.244.53.226/32,103.52.113.234/32,103.52.113.202/32,10.0.25.0/24,103.109.32.37/32
alepay-prod/alepay-ops.nganluong.vn
    124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14.177.239.203/32,103.109.32.44/32,118.69.34.233/32,103.109.32.47/32,18.136.230.133/32,54.251.103.128/32,10.16.2.0/24,10.16.1.0/24,103.109.32.46/32,103.109.32.38/32,171.244.53.226/32,113.161.48.116/32,118.69.34.152/32,103.52.113.234/32,103.52.113.202/32,10.0.25.0/24,103.109.32.140/32,103.145.79.11/32,103.145.79.125/32
alepay-prod/alepay-v3.nganluong.vn-admintool
    14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14.177.239.203/32,118.69.34.233/32,103.109.32.47/32,103.109.33.31/32,103.109.32.44/32,10.16.2.0/24,10.16.1.0/24,103.52.113.234/32,103.52.113.202/32
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify
    42.112.208.12, 123.30.20.10, 42.112.208.164
alepay-prod/alepay.vn-appimage
    14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14.177.239.203/32,118.69.34.233/32,103.109.32.47/32,103.109.33.31/32,103.109.32.44/32,10.16.2.0/24,10.16.1.0/24,18.136.230.133/32,54.251.103.128/32,52.74.45.126/32,103.52.113.234/32,103.52.113.202/32
alepay-prod/core-checkout.nganluong.vn
    14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14.177.239.203/32,103.109.32.44/32,118.69.34.233/32,103.109.32.47/32,103.52.113.234/32,103.52.113.202/32
alepay-prod/crontab-alepay.nganluong.vn
    14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14.177.239.203/32,103.109.32.44/32,118.69.34.233/32,103.109.32.47/32,10.16.2.0/24,10.16.1.0/24,103.52.113.234/32,103.52.113.202/32
alepay-prod/report-alepay.nganluong.vn
    124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14.177.239.203/32,103.109.32.44/32,118.69.34.233/32,103.109.32.47/32,113.161.48.116/32,10.16.2.0/24,10.16.1.0/24,118.69.34.152/32,103.52.113.234/32,103.52.113.202/32
argocd/deploy-alepay.nganluong.vn
    124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14.177.239.203/32,118.69.34.233/32,103.109.32.47/32,103.109.33.31/32,103.109.32.44/32,10.16.2.0/24,10.16.1.0/24,103.52.113.234/32,103.52.113.202/32
monitoring/grafana-alepay.nganluong.vn
    124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14.177.239.203/32,103.109.32.44/32,118.69.34.233/32,103.109.32.47/32,10.16.2.0/24,10.16.1.0/24,103.52.113.234/32,103.52.113.202/32
monitoring/prometheus-alepay.nganluong.vn
    124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14.177.239.203/32,103.109.32.44/32,118.69.34.233/32,103.109.32.47/32,10.16.2.0/24,10.16.1.0/24,103.52.113.234/32,103.52.113.202/32
```

### 2.4 Giá trị CORS
```text
alepay-prod/alepay-v3.nganluong.vn
    nginx.ingress.kubernetes.io/cors-allow-headers = DNT,X-CustomHeader,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Authorization
alepay-prod/alepay-v3.nganluong.vn
    nginx.ingress.kubernetes.io/cors-allow-methods = GET, PUT, POST, DELETE, PATCH, OPTIONS
alepay-prod/alepay-v3.nganluong.vn
    nginx.ingress.kubernetes.io/cors-allow-origin = *
alepay-prod/alepay-v3.nganluong.vn
    nginx.ingress.kubernetes.io/enable-cors = true
alepay-prod/static-alepay.nganluong.vn
    nginx.ingress.kubernetes.io/cors-allow-origin = https://alepay.vn, https://alepay-v3-sandbox.nganluong.vn, https://alepay-merchant.nganluong.vn , https://alepay-merchant-staging.nganluong.vn
alepay-prod/static-alepay.nganluong.vn
    nginx.ingress.kubernetes.io/enable-cors = true
```

### 2.5 Toàn bộ annotation nginx kèm giá trị
```text
alepay-prod/alepay-api-payment.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/alepay-api-payment.nganluong.vn	proxy-body-size	10m
alepay-prod/alepay-api-payment.nganluong.vn	proxy-connect-timeout	3600
alepay-prod/alepay-api-payment.nganluong.vn	proxy-read-timeout	3600
alepay-prod/alepay-api-payment.nganluong.vn	proxy-send-timeout	3600
alepay-prod/alepay-api-payment.nganluong.vn	whitelist-source-range	124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14
alepay-prod/alepay-gateway.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/alepay-gateway.nganluong.vn	whitelist-source-range	124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14
alepay-prod/alepay-merchant.nganluong.vn	affinity	cookie
alepay-prod/alepay-merchant.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/alepay-merchant.nganluong.vn	proxy-body-size	10m
alepay-prod/alepay-merchant.nganluong.vn	proxy-connect-timeout	3600
alepay-prod/alepay-merchant.nganluong.vn	proxy-read-timeout	7200
alepay-prod/alepay-merchant.nganluong.vn	proxy-send-timeout	7200
alepay-prod/alepay-merchant.nganluong.vn	session-cookie-expires	172800
alepay-prod/alepay-merchant.nganluong.vn	session-cookie-max-age	172800
alepay-prod/alepay-merchant.nganluong.vn	session-cookie-name	route
alepay-prod/alepay.nganluong.vn	affinity	cookie
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	affinity	cookie
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	proxy-body-size	10m
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	proxy-connect-timeout	300
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	proxy-read-timeout	300
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	proxy-send-timeout	300
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	session-cookie-expires	172800
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	session-cookie-max-age	172800
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	session-cookie-name	route
alepay-prod/alepay.nganluong.vn-checkout-virtual-notify	whitelist-source-range	42.112.208.12, 123.30.20.10, 42.112.208.164
alepay-prod/alepay.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/alepay.nganluong.vn	proxy-body-size	10m
alepay-prod/alepay.nganluong.vn	proxy-connect-timeout	300
alepay-prod/alepay.nganluong.vn	proxy-read-timeout	300
alepay-prod/alepay.nganluong.vn	proxy-send-timeout	300
alepay-prod/alepay.nganluong.vn	session-cookie-expires	172800
alepay-prod/alepay.nganluong.vn	session-cookie-max-age	172800
alepay-prod/alepay.nganluong.vn	session-cookie-name	route
alepay-prod/alepay-ops-backup.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/alepay-ops-backup.nganluong.vn	proxy-body-size	10m
alepay-prod/alepay-ops-backup.nganluong.vn	proxy-connect-timeout	300
alepay-prod/alepay-ops-backup.nganluong.vn	proxy-read-timeout	300
alepay-prod/alepay-ops-backup.nganluong.vn	proxy-send-timeout	300
alepay-prod/alepay-ops-backup.nganluong.vn	whitelist-source-range	14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14
alepay-prod/alepay-ops.nganluong.vn	affinity	cookie
alepay-prod/alepay-ops.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/alepay-ops.nganluong.vn	proxy-body-size	10m
alepay-prod/alepay-ops.nganluong.vn	proxy-connect-timeout	300
alepay-prod/alepay-ops.nganluong.vn	proxy-read-timeout	300
alepay-prod/alepay-ops.nganluong.vn	proxy-send-timeout	300
alepay-prod/alepay-ops.nganluong.vn	session-cookie-expires	172800
alepay-prod/alepay-ops.nganluong.vn	session-cookie-max-age	172800
alepay-prod/alepay-ops.nganluong.vn	session-cookie-name	route
alepay-prod/alepay-ops.nganluong.vn	whitelist-source-range	124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14
alepay-prod/alepay-v3-merchant.nganluong.vn	affinity	cookie
alepay-prod/alepay-v3-merchant.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/alepay-v3-merchant.nganluong.vn	session-cookie-expires	172800
alepay-prod/alepay-v3-merchant.nganluong.vn	session-cookie-max-age	172800
alepay-prod/alepay-v3-merchant.nganluong.vn	session-cookie-name	route
alepay-prod/alepay-v3.nganluong.vn-admintool	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/alepay-v3.nganluong.vn-admintool	whitelist-source-range	14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14
alepay-prod/alepay-v3.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For; ⏎
alepay-prod/alepay-v3.nganluong.vn	cors-allow-headers	DNT,X-CustomHeader,Keep-Alive,User-Agent,X-Requested-With,If-Modified-
alepay-prod/alepay-v3.nganluong.vn	cors-allow-methods	GET, PUT, POST, DELETE, PATCH, OPTIONS
alepay-prod/alepay-v3.nganluong.vn	cors-allow-origin	*
alepay-prod/alepay-v3.nganluong.vn	enable-cors	true
alepay-prod/alepay.vn-appimage	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/alepay.vn-appimage	whitelist-source-range	14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14
alepay-prod/alepay.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/core-checkout.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/core-checkout.nganluong.vn	proxy-body-size	10m
alepay-prod/core-checkout.nganluong.vn	proxy-connect-timeout	3600
alepay-prod/core-checkout.nganluong.vn	proxy-read-timeout	3600
alepay-prod/core-checkout.nganluong.vn	proxy-send-timeout	3600
alepay-prod/core-checkout.nganluong.vn	whitelist-source-range	14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14
alepay-prod/crontab-alepay.nganluong.vn	proxy-body-size	10m
alepay-prod/crontab-alepay.nganluong.vn	proxy-connect-timeout	300
alepay-prod/crontab-alepay.nganluong.vn	proxy-read-timeout	300
alepay-prod/crontab-alepay.nganluong.vn	proxy-send-timeout	300
alepay-prod/crontab-alepay.nganluong.vn	whitelist-source-range	14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14.177.239.244/32,14
alepay-prod/fptpay.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/fptpay.nganluong.vn	proxy-body-size	10m
alepay-prod/fptpay.nganluong.vn	proxy-connect-timeout	3600
alepay-prod/fptpay.nganluong.vn	proxy-read-timeout	3600
alepay-prod/fptpay.nganluong.vn	proxy-send-timeout	3600
alepay-prod/report-alepay.nganluong.vn	affinity	cookie
alepay-prod/report-alepay.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
alepay-prod/report-alepay.nganluong.vn	proxy-body-size	10m
alepay-prod/report-alepay.nganluong.vn	proxy-connect-timeout	300
alepay-prod/report-alepay.nganluong.vn	proxy-read-timeout	300
alepay-prod/report-alepay.nganluong.vn	proxy-send-timeout	300
alepay-prod/report-alepay.nganluong.vn	session-cookie-expires	172800
alepay-prod/report-alepay.nganluong.vn	session-cookie-max-age	172800
alepay-prod/report-alepay.nganluong.vn	session-cookie-name	route
alepay-prod/report-alepay.nganluong.vn	whitelist-source-range	124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14
alepay-prod/static-alepay.nganluong.vn	cors-allow-origin	https://alepay.vn, https://alepay-v3-sandbox.nganluong.vn, https://ale
alepay-prod/static-alepay.nganluong.vn	enable-cors	true
alepay-prod/static-alepay.nganluong.vn	proxy-body-size	10m
alepay-prod/static-alepay.nganluong.vn	proxy-connect-timeout	3600
alepay-prod/static-alepay.nganluong.vn	proxy-read-timeout	3600
alepay-prod/static-alepay.nganluong.vn	proxy-send-timeout	3600
argocd/deploy-alepay.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
argocd/deploy-alepay.nganluong.vn	whitelist-source-range	124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14
cattle-system/rancher-alepay.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;
cattle-system/rancher-alepay.nganluong.vn	proxy-buffering	off
cattle-system/rancher-alepay.nganluong.vn	proxy-connect-timeout	3600
cattle-system/rancher-alepay.nganluong.vn	proxy-http-version	1.1
cattle-system/rancher-alepay.nganluong.vn	proxy-read-timeout	3600
cattle-system/rancher-alepay.nganluong.vn	proxy-send-timeout	3600
monitoring/grafana-alepay.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
monitoring/grafana-alepay.nganluong.vn	proxy-connect-timeout	360
monitoring/grafana-alepay.nganluong.vn	proxy-read-timeout	360
monitoring/grafana-alepay.nganluong.vn	proxy-send-timeout	360
monitoring/grafana-alepay.nganluong.vn	whitelist-source-range	124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14
monitoring/prometheus-alepay.nganluong.vn	configuration-snippet	set_real_ip_from 10.0.0.0/8;⏎real_ip_header X-Forwarded-For;⏎
monitoring/prometheus-alepay.nganluong.vn	proxy-body-size	10m
monitoring/prometheus-alepay.nganluong.vn	proxy-connect-timeout	300
monitoring/prometheus-alepay.nganluong.vn	proxy-read-timeout	300
monitoring/prometheus-alepay.nganluong.vn	proxy-send-timeout	300
monitoring/prometheus-alepay.nganluong.vn	whitelist-source-range	124.197.17.122/32,14.177.239.192/32,101.99.7.132/32,101.99.7.213/32,14
```

## 3. Cấu hình controller đang chạy

### 3.1 nginx.conf đã render — chỉ thị real_ip

Quyết định `X-Forwarded-For` có spoof được không. `real_ip_recursive off` (mặc định)
nghĩa là nginx lấy **entry cuối cùng** của XFF — chính là IP mà ALB nối vào, nên spoof
qua đường ALB không ăn. Nếu `on` thì nginx đi ngược từ phải sang, bỏ qua các IP tin cậy.

```nginx
370:			proxy_set_header X-Forwarded-For        $remote_addr;
546:			proxy_set_header X-Forwarded-For        $remote_addr;
585:			set_real_ip_from 10.0.0.0/8;
586:			real_ip_header X-Forwarded-For;
705:			proxy_set_header X-Forwarded-For        $remote_addr;
744:			set_real_ip_from 10.0.0.0/8;
745:			real_ip_header X-Forwarded-For;
844:			proxy_set_header X-Forwarded-For        $remote_addr;
883:			set_real_ip_from 10.0.0.0/8;
884:			real_ip_header X-Forwarded-For;
1004:			proxy_set_header X-Forwarded-For        $remote_addr;
1043:			set_real_ip_from 10.0.0.0/8;
1044:			real_ip_header X-Forwarded-For;
1169:			proxy_set_header X-Forwarded-For        $remote_addr;
1208:			set_real_ip_from 10.0.0.0/8;
1209:			real_ip_header X-Forwarded-For;
1308:			proxy_set_header X-Forwarded-For        $remote_addr;
1347:			set_real_ip_from 10.0.0.0/8;
1348:			real_ip_header X-Forwarded-For;
1477:			proxy_set_header X-Forwarded-For        $remote_addr;
1516:			set_real_ip_from 10.0.0.0/8;
1517:			real_ip_header X-Forwarded-For;
1628:			proxy_set_header X-Forwarded-For        $remote_addr;
1667:			set_real_ip_from 10.0.0.0/8;
1668:			real_ip_header X-Forwarded-For;
1779:			proxy_set_header X-Forwarded-For        $remote_addr;
1818:			set_real_ip_from 10.0.0.0/8;
1819:			real_ip_header X-Forwarded-For;
1930:			proxy_set_header X-Forwarded-For        $remote_addr;
1969:			set_real_ip_from 10.0.0.0/8;
1970:			real_ip_header X-Forwarded-For;
2081:			proxy_set_header X-Forwarded-For        $remote_addr;
2120:			set_real_ip_from 10.0.0.0/8;
2121:			real_ip_header X-Forwarded-For;
2232:			proxy_set_header X-Forwarded-For        $remote_addr;
2271:			set_real_ip_from 10.0.0.0/8;
2272:			real_ip_header X-Forwarded-For;
2383:			proxy_set_header X-Forwarded-For        $remote_addr;
2422:			set_real_ip_from 10.0.0.0/8;
2423:			real_ip_header X-Forwarded-For;
```

### 3.2 Args
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

### 3.3 Image
```text
registry.k8s.io/ingress-nginx/controller:v1.8.1@sha256:e5c4824e7375fcf2a393e1c03c293b69759af37a9ca6abdb91b13d78a93da8bd
```

### 3.4 ConfigMap
```json
{
  "allow-snippet-annotations": "true",
  "log-format-escape-json": "true",
  "log-format-upstream": "{\"msec\": \"$msec\", \"connection\": \"$connection\", \"connection_requests\": \"$connection_requests\", \"pid\": \"$pid\", \"request_id\": \"$request_id\", \"request_length\": \"$request_length\", \"remote_addr\": \"$remote_addr\", \"remote_user\": \"$remote_user\", \"remote_port\": \"$remote_port\", \"time_local\": \"$time_local\", \"time_iso8601\": \"$time_iso8601\", \"request\": \"$request\", \"request_uri\": \"$request_uri\", \"args\": \"$args\", \"status\": \"$status\", \"body_bytes_sent\": \"$body_bytes_sent\", \"bytes_sent\": \"$bytes_sent\", \"http_referer\": \"$http_referer\", \"http_user_agent\": \"$http_user_agent\", \"http_x_forwarded_for\": \"$http_x_forwarded_for\", \"http_host\": \"$http_host\", \"server_name\": \"$server_name\", \"request_time\": \"$request_time\", \"upstream\": \"$upstream_addr\", \"upstream_connect_time\": \"$upstream_connect_time\", \"upstream_header_time\": \"$upstream_header_time\", \"upstream_response_time\": \"$upstream_response_time\", \"upstream_response_length\": \"$upstream_response_length\", \"upstream_cache_status\": \"$upstream_cache_status\", \"ssl_protocol\": \"$ssl_protocol\", \"ssl_cipher\": \"$ssl_cipher\", \"scheme\": \"$scheme\", \"request_method\": \"$request_method\", \"server_protocol\": \"$server_protocol\", \"pipe\": \"$pipe\", \"gzip_ratio\": \"$gzip_ratio\", \"http_cf_ray\": \"$http_cf_ray\", \"geoip_country_code\": \"$geoip_country_code\"}",
  "real-ip-header": "X-Real-IP"
}
```

### 3.5 ConfigMap TCP/UDP
```text
(không có dữ liệu)
```

### 3.6 IngressClass
```text
name=nginx  controller=k8s.io/ingress-nginx  default=false
```

### 3.7 Resources
```json
{
  "requests": {
    "cpu": "100m",
    "memory": "90Mi"
  }
}
```

## 4. Admission webhook — đường khai thác CVE-2025-1974
```text
webhook=validate.nginx.ingress.kubernetes.io
  failurePolicy=Fail
  service=nginx-ingress/ingress-nginx-controller-admission:443
  timeoutSeconds=10
```

## 5. Trạng thái & khả năng quan sát

### 5.1 DaemonSet
```text
desired=17  ready=17  updated=17  strategy=RollingUpdate  maxUnavailable=1
```

### 5.2 PodDisruptionBudget
```text
(không có dữ liệu)
```

### 5.3 ServiceMonitor
```text
(không có dữ liệu)
```

### 5.4 Pod
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

### 5.5 Cảnh báo gần đây
```text
(không có dữ liệu)
```

## 6. TLS

### 6.1 Secret TLS được ingress tham chiếu
```text
alepay-prod/cert-alepay-2024
alepay-prod/cert-wildcard-nganluong
alepay-prod/wc-nganluong
argocd/wc-nganluong-2025
monitoring/wc-nganluong
```

### 6.2 Secret do cert-manager quản lý
```text
(không có dữ liệu)
```

### 6.3 Certificate resource
```text
(không có dữ liệu)
```

### 6.4 Hạn dùng

| Namespace | Secret | Hết hạn | Còn lại | Issuer |
|---|---|---|---|---|
| `alepay-prod` | `cert-alepay-2024` | May 28 03:18:10 2025 GMT | 🔴 **quá hạn 437 ngày** | GlobalSign GCC R6 AlphaSSL CA 2023 |
| `alepay-prod` | `cert-wildcard-nganluong` | *không đọc được* | *?* | *?* |
| `alepay-prod` | `wc-nganluong` | Sep 21 02:54:08 2026 GMT | ⚠️ **còn 43 ngày** | GlobalSign GCC R6 AlphaSSL CA 2025 |
| `argocd` | `wc-nganluong-2025` | Sep 21 02:54:08 2026 GMT | ⚠️ **còn 43 ngày** | GlobalSign GCC R6 AlphaSSL CA 2025 |
| `monitoring` | `wc-nganluong` | Sep 20 09:09:19 2025 GMT | 🔴 **quá hạn 321 ngày** | GlobalSign GCC R6 AlphaSSL CA 2023 |

## 7. GitOps — sửa ở đâu

### 7.1 Nguồn của ArgoCD app `nginx`

Đây là repo phải sửa để gỡ `configuration-snippet` khỏi các Ingress.

```json
{
  "repoURL": "https://gitlab.saobang.vn/system/argocd/alepay/argocd-alepay-aws.git",
  "path": "nginx",
  "targetRevision": "release",
  "destination": {
    "namespace": "alepay-prod",
    "server": "https://kubernetes.default.svc"
  },
  "syncPolicy": {
    "automated": {}
  },
  "status": {
    "sync": "Synced",
    "health": "Healthy"
  }
}
```

### 7.2 Ingress nào do ai quản

| Ingress | ArgoCD app |
|---|---|
| `alepay-prod/alepay-api-payment.nganluong.vn` | nginx |
| `alepay-prod/alepay-gateway.nganluong.vn` | nginx |
| `alepay-prod/alepay-merchant.nganluong.vn` | nginx |
| `alepay-prod/alepay-ops-backup.nganluong.vn` | nginx |
| `alepay-prod/alepay-ops.nganluong.vn` | nginx |
| `alepay-prod/alepay-v3-merchant.nganluong.vn` | nginx |
| `alepay-prod/alepay-v3.nganluong.vn` | nginx |
| `alepay-prod/alepay-v3.nganluong.vn-admintool` | nginx |
| `alepay-prod/alepay.nganluong.vn` | nginx |
| `alepay-prod/alepay.nganluong.vn-checkout-virtual-notify` | nginx |
| `alepay-prod/alepay.vn` | nginx |
| `alepay-prod/alepay.vn-appimage` | nginx |
| `alepay-prod/core-checkout.nganluong.vn` | nginx |
| `alepay-prod/crontab-alepay.nganluong.vn` | nginx |
| `alepay-prod/fptpay.nganluong.vn` | nginx |
| `alepay-prod/report-alepay.nganluong.vn` | nginx |
| `alepay-prod/static-alepay.nganluong.vn` | nginx |
| `argocd/deploy-alepay.nganluong.vn` | nginx |
| `cattle-system/rancher-alepay.nganluong.vn` | — **sửa tay** |
| `monitoring/grafana-alepay.nganluong.vn` | nginx |
| `monitoring/prometheus-alepay.nganluong.vn` | nginx |

### 7.3 Helm release
```text
NAME         	NAMESPACE    	REVISION	UPDATED                                  	STATUS  	CHART              	APP VERSION
ingress-nginx	nginx-ingress	1       	2023-07-31 09:46:55.620901496 +0700 +0700	deployed	ingress-nginx-4.7.1	1.8.1      
```

### 7.4 Helm values
```yaml
USER-SUPPLIED VALUES:
controller:
  hostPort:
    enabled: true
  kind: DaemonSet
```


---

*Sinh bởi `survey.sh`.*
