# System Context — Kiến trúc tổng thể

## Mô hình triển khai

```
Client (Web / Mobile)
         ↓
      Nginx (Reverse Proxy + SSL)
      ├── /api/wms/*      → WMS App      :3001  (internal, IP whitelist)
      ├── /api/shop/*     → Ecommerce    :3002  (public)
      └── /api/notify/*   → Notification :3003  (internal)
```

---

## Các ứng dụng

| App | Port | Người dùng | Mô tả |
|---|---|---|---|
| `wms` | 3001 | Admin / Manager / Receiver / Picker / Printer / Counter | Quản lý kho, nhập xuất, in ly, kiểm kho |
| `ecommerce` | 3002 | Khách hàng | Cửa hàng online, đặt hàng, thanh toán |
| `notification` | 3003 | Internal | Gửi email / SMS / push cho cả 2 app |

---

## Cấu trúc monorepo (NestJS)

```
wms-ecom/
├── apps/
│   ├── wms/                  ← NestJS app nội bộ
│   │   └── src/modules/
│   │       ├── warehouse/
│   │       ├── product/
│   │       ├── supplier/
│   │       └── report/
│   ├── ecommerce/            ← NestJS app public
│   │   └── src/modules/
│   │       ├── catalog/
│   │       ├── cart/
│   │       ├── order/
│   │       └── payment/      ← Module trong ecommerce, không tách riêng
│   └── notification/         ← Shared notification service
│       └── src/channels/
│           ├── email/
│           ├── sms/
│           └── push/
├── libs/
│   ├── auth/                 ← JWT strategy, guards, roles
│   ├── database/             ← Prisma client, MongoDB config
│   ├── shared-types/         ← DTOs, enums, interfaces dùng chung
│   └── common/               ← Pipes, filters, decorators, utils
├── nest-cli.json
├── docker-compose.yml
└── docs/
```

### nest-cli.json

```json
{
  "monorepo": true,
  "root": "apps/wms",
  "projects": {
    "wms":          { "root": "apps/wms",          "entryFile": "main" },
    "ecommerce":    { "root": "apps/ecommerce",    "entryFile": "main" },
    "notification": { "root": "apps/notification", "entryFile": "main" }
  }
}
```

---

## Auth

### Phân loại user

| Loại | App | Collection | Roles |
|---|---|---|---|
| Nhân viên nội bộ | WMS | `users` | ADMIN / MANAGER / RECEIVER / PICKER / PRINTER / COUNTER |
| Khách hàng | Ecommerce | `customers` | — |

> **User giữ nhiều role** — field `roles: String[]`. Một nhân viên có thể vừa `RECEIVER` vừa `PICKER`.

| Role | Phụ trách |
|---|---|
| `ADMIN` | Toàn quyền, bypass mọi guard |
| `MANAGER` | Tạo PO, tạo lệnh in/kiểm/chuyển, **duyệt** |
| `RECEIVER` | Nhận hàng + put-away (GRN, put-away, nhận hàng chuyển kho) |
| `PICKER` | Soạn & xuất hàng (xuất kho, xuất hàng chuyển kho) |
| `PRINTER` | Vận hành in (xác nhận in xong) |
| `COUNTER` | Kiểm đếm tồn |

### Cơ chế

- **JWT stateless** — mỗi app tự validate token bằng shared secret, không gọi sang app khác
- Shared logic nằm trong `libs/auth/`

```
libs/auth/
├── jwt.strategy.ts       ← Decode & validate JWT payload
├── jwt-auth.guard.ts     ← Bảo vệ route yêu cầu đăng nhập
├── roles.guard.ts        ← Cho qua nếu user.roles GIAO với @Roles(...) ≠ ∅; ADMIN bypass
└── auth.module.ts        ← Import vào bất kỳ app nào
```

```typescript
// Dùng chung ở mọi app
// RolesGuard cho qua nếu user.roles chứa ÍT NHẤT MỘT role trong @Roles(...)
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('MANAGER')
@Get('purchase-orders')
findAll() { ... }
```

---

## Giao tiếp giữa các app

| Từ | Đến | Cách | Khi nào |
|---|---|---|---|
| Ecommerce | WMS | Event (BullMQ) | Khách đặt hàng → WMS xử lý xuất kho |
| WMS | Notification | Event (BullMQ) | Xuất kho xong → gửi thông báo khách |
| Ecommerce | Notification | Event (BullMQ) | Thanh toán thành công → gửi email xác nhận |

> Dùng **BullMQ + Redis** cho message queue nội bộ — đơn giản, không cần Kafka/RabbitMQ ở giai đoạn này.

---

## Infrastructure (docker-compose)

```
MongoDB        ← 1 cluster, 2 logical DB: wms_db + ecom_db
Redis          ← BullMQ queue + cache
WMS app
Ecommerce app
Notification app
Nginx          ← Reverse proxy
```

---

## Tại sao không phải Microservices?

| Tiêu chí | Microservices | Monorepo 3-app |
|---|---|---|
| Distributed transaction | Phức tạp (Saga/2PC) | Đơn giản (cùng MongoDB) |
| Độ phức tạp infra | Cao (K8s, service mesh) | Thấp (docker-compose) |
| Phù hợp team nhỏ | Không | Có |
| Scale độc lập | Có | Có (3 app riêng) |
| Tách sau khi cần | — | Dễ, vì module đã rõ boundary |
