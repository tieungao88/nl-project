# Khảo sát ingress-nginx

| | |
|---|---|
| Thời điểm | `2026-08-08 04:35:35 UTC` |
| Namespace / Release | `nginx-ingress` / `ingress-nginx` |
| Region | `ap-southeast-1` |
| Cluster | `?` |
| AWS CLI | có |

> Khảo sát chỉ đọc. Không thay đổi gì trên cluster hay AWS.

---

## 0. Kết luận nhanh

### A. Bảo mật đường vào

| Câu hỏi | Kết quả |
|---|---|
| **CLB có gọi thẳng từ Internet được không?** | chưa xác định — thiếu AWS CLI hoặc quyền đọc |
| CLB scheme | `?` |
| CLB security group | `?` |
| `real_ip_recursive` | ? |
| externalTrafficPolicy | `?` |

> **Vì sao quan trọng:** chuỗi thiết kế là Client → ALB (WAF) → CLB → NodePort → nginx.
> ALB *append* `X-Forwarded-For` nên client không spoof được qua đường đó.
> Nhưng nếu CLB mở `0.0.0.0/0` thì gọi thẳng CLB sẽ bỏ qua ALB và WAF, và vì
> không còn ai chèn XFF nên client tự đặt header này → nginx tin →
> **vượt `whitelist-source-range`**. Cần siết ngay, không chờ đợt nâng cấp.

### B. Đường traffic

| Câu hỏi | Kết quả |
|---|---|
| Loại Load Balancer | ? |
| Listener → instance port | `?` |
| Service type | `?` |
| NodePort | `?` |
| hostPort trên DaemonSet | `?` |
| Pod controller | 0 / 0 sẵn sàng |
| maxUnavailable | `?` |

### C. Cấu hình cần xử lý khi nâng cấp

| Câu hỏi | Kết quả |
|---|---|
| Tổng số Ingress | 0 |
| Loại annotation nginx | 0 loại / 0 lần dùng |
| Ingress dùng `configuration-snippet` | 0 |
| Biến thể snippet *(chuẩn hoá khoảng trắng)* | **** |
| ServiceMonitor | **không có** |
| PodDisruptionBudget | **không có** |

### D. Cần đọc kỹ

- Không có ServiceMonitor → **bật metrics trước khi nâng** để có baseline error rate.
- Không có PodDisruptionBudget cho ingress controller.

---

## 1. Đường vào — WAF, ALB, ELB, Service

### 1.1 Security group của Classic ELB — **quan trọng nhất**
```json
(không có dữ liệu)
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

### 1.5 Target group của ALB — xem ALB trỏ vào đâu
```json
[
  {
    "Name": "alb-tg",
    "TargetType": "instance",
    "Port": 80,
    "Protocol": "HTTP",
    "VpcId": "vpc-024d6e1b698cb8267",
    "LBs": [
      "arn:aws:elasticloadbalancing:ap-southeast-1:347599856906:loadbalancer/app/alepay-ALB/5f98d146561ba1a9"
    ]
  },
  {
    "Name": "alb-tg-tls",
    "TargetType": "instance",
    "Port": 443,
    "Protocol": "HTTPS",
    "VpcId": "vpc-024d6e1b698cb8267",
    "LBs": [
      "arn:aws:elasticloadbalancing:ap-southeast-1:347599856906:loadbalancer/app/alepay-ALB/5f98d146561ba1a9"
    ]
  },
  {
    "Name": "alb-tg-tls-test",
    "TargetType": "instance",
    "Port": 443,
    "Protocol": "HTTPS",
    "VpcId": "vpc-024d6e1b698cb8267",
    "LBs": []
  }
]
```

### 1.6 DNS thực tế của các domain

Cho biết client vào qua ALB, qua CDN, hay thẳng vào CLB.

```text
(không có dig/nslookup)
```

### 1.7 Service `ingress-nginx-controller`
```json
(không có dữ liệu)
```

### 1.8 Cổng trên DaemonSet
```text
(không có dữ liệu)
```

### 1.9 Classic ELB đầy đủ
```json
(không có dữ liệu)
```

## 2. Annotation trên Ingress

### 2.1 Thống kê theo loại
```text
(không có dữ liệu)
```

### 2.2 Biến thể `configuration-snippet`
```nginx
(không có dữ liệu)
```

### 2.3 Giá trị `whitelist-source-range`

Bản 1.11+ siết validation annotation — giá trị sai định dạng sẽ bị **từ chối** khi apply.

```text
(không có dữ liệu)
```

### 2.4 Giá trị CORS
```text
(không có dữ liệu)
```

### 2.5 Toàn bộ annotation nginx kèm giá trị
```text
(không có dữ liệu)
```

## 3. Cấu hình controller đang chạy

### 3.1 nginx.conf đã render — chỉ thị real_ip

Quyết định `X-Forwarded-For` có spoof được không. `real_ip_recursive off` (mặc định)
nghĩa là nginx lấy **entry cuối cùng** của XFF — chính là IP mà ALB nối vào, nên spoof
qua đường ALB không ăn. Nếu `on` thì nginx đi ngược từ phải sang, bỏ qua các IP tin cậy.

```nginx
(không có dữ liệu)
```

### 3.2 Args
```text
(không có dữ liệu)
```

### 3.3 Image
```text
(không có dữ liệu)
```

### 3.4 ConfigMap
```json
(không có dữ liệu)
```

### 3.5 ConfigMap TCP/UDP
```text
(không có dữ liệu)
```

### 3.6 IngressClass
```text
(không có dữ liệu)
```

### 3.7 Resources
```json
(không có dữ liệu)
```

## 4. Admission webhook — đường khai thác CVE-2025-1974
```text
(không có dữ liệu)
```

## 5. Trạng thái & khả năng quan sát

### 5.1 DaemonSet
```text
(không có dữ liệu)
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
(không có dữ liệu)
```

### 5.5 Cảnh báo gần đây
```text
(không có dữ liệu)
```

## 6. TLS

### 6.1 Secret TLS được ingress tham chiếu
```text
(không có dữ liệu)
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

## 7. GitOps — sửa ở đâu

### 7.1 Nguồn của ArgoCD app `nginx`

Đây là repo phải sửa để gỡ `configuration-snippet` khỏi các Ingress.

```json
(không có dữ liệu)
```

### 7.2 Ingress nào do ai quản

| Ingress | ArgoCD app |
|---|---|

### 7.3 Helm release
```text
(helm không có)
```

### 7.4 Helm values
```yaml
(không có dữ liệu)
```


---

*Sinh bởi `survey.sh`.*
