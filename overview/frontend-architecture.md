# Frontend Architecture

> Hệ thống có **2 FE app** phục vụ 2 nhóm người dùng hoàn toàn khác nhau, mỗi app có auth riêng biệt. Không shared secret giữa WMS và Ecom.

## Hai FE App

| | WMS FE | Ecom FE |
|---|---|---|
| **Đối tượng** | Nhân viên kho | Nhân viên shop + Khách hàng |
| **Truy cập** | Internal (VPN / mạng nội bộ) | Public internet |
| **Auth** | `wms_db.users` — login bằng `username + password` | `ecom_db.admin_users` (shop) + `ecom_db.customers` (khách) |
| **Token** | Signed bằng WMS private key | Signed bằng Ecom private key |
| **Backend** | WMS app | Ecom app |

---

## WMS FE — Cấu trúc route

```
/login                    ← đăng nhập nhân viên kho (auth-wms)

/warehouse/
  ├── purchase-orders/    ← MANAGER, ADMIN
  ├── grn/                ← RECEIVER, MANAGER, ADMIN
  ├── print-jobs/         ← PRINTER, MANAGER, ADMIN
  ├── goods-issues/       ← PICKER, ADMIN
  ├── stock-checks/       ← COUNTER, MANAGER, ADMIN
  └── transfers/          ← MANAGER, PICKER, RECEIVER, ADMIN

/staff/                   ← ADMIN
  └── users/              ← Tạo/khóa/reset tài khoản nhân viên kho
```

> WMS FE **chỉ gọi WMS backend**. Không biết gì về Ecom backend.

---

## Ecom FE — Cấu trúc route

```
/                         ← Trang chủ, browse sản phẩm (public)
/products/:slug           ← Chi tiết sản phẩm (public)
/cart                     ← Giỏ hàng (public)
/checkout                 ← Đặt hàng (yêu cầu đăng nhập khách)
/account/                 ← Khách đã đăng nhập
  ├── orders/
  ├── addresses/
  └── profile/
/auth/                    ← Auth khách hàng
  ├── login
  ├── register
  ├── verify-email
  └── reset-password

/admin/                   ← Nhân viên shop (ECOM_MANAGER)
  ├── login               ← Đăng nhập riêng — gọi Ecom backend /admin/auth/login
  ├── catalog/
  │   ├── categories/     ← CRUD danh mục
  │   ├── products/       ← CRUD sản phẩm, set giá, DRAFT/ACTIVE/HIDDEN
  │   └── variants/       ← Gắn SKU, fulfillmentType
  └── orders/
      ├── list/           ← Xem danh sách đơn (3 trục trạng thái)
      ├── detail/:id      ← Chi tiết, can thiệp thủ công
      └── returns/        ← Xử lý hoàn hàng (RMA)
```

---

## Auth flow cho từng nhóm

### Nhân viên kho (WMS FE)
```
WMS FE /login
  → POST /auth/login (WMS backend)
  → wms_db.users kiểm tra username + password
  → token { type: "user", roles: [...] } ký bằng WMS private key
  → WMS FE dùng token gọi WMS backend routes
```

### Nhân viên shop (Ecom FE /admin)
```
Ecom FE /admin/login
  → POST /admin/auth/login (Ecom backend)
  → ecom_db.admin_users kiểm tra username + password
  → token { type: "admin", roles: ["ECOM_MANAGER"] } ký bằng Ecom private key
  → Ecom FE dùng token gọi Ecom backend /admin/* routes
```

### Khách hàng (Ecom FE)
```
Ecom FE /auth/login
  → POST /auth/login (Ecom backend)
  → ecom_db.customers kiểm tra email + password
  → token { type: "customer" } ký bằng Ecom private key
  → Ecom FE dùng token gọi Ecom backend /account/* routes
```

> Ecom backend phân biệt 2 loại token của mình bằng claim `type`: `admin` cho nhân viên shop, `customer` cho khách. Route `/admin/*` bắt buộc `type = admin`.

---

## Quyết định kiến trúc

| # | Quyết định | Lý do |
|---|---|---|
| FA-1 | WMS FE = kho thuần, Ecom FE = shop + khách | Tách biệt rõ, mỗi FE chỉ biết backend của mình |
| FA-2 | Ecom FE có `/admin` section với login riêng | ECOM_MANAGER auth qua Ecom backend, không qua WMS |
| FA-3 | Không shared secret — mỗi app ký token bằng key riêng (RS256) | Lộ key Ecom không ảnh hưởng WMS, và ngược lại |
| FA-4 | Guard `/admin/*` check `type = admin` trước khi check role | Khách dù có token Ecom cũng không vào được admin routes |
