# Auth & User — Design Spec

> Trạng thái: 🔄 Đang phân tích → chốt thiết kế. Spec cho 2 module tài liệu `auth-wms/` và `auth-ecom/`.
> Ngày: 2026-06-05. Lấp Hạng 2 trong [gap-analysis](../../overview/gap-analysis.md#2-auth--user--hạng-2--đã-thiết-kế).

## 1. Bối cảnh & phạm vi

Hệ WMS-ECOM có **3 nhóm người dùng**, nhưng tài liệu cũ mới định nghĩa 2:

| Nhóm | App | Thao tác | Hiện trạng trước spec |
|---|---|---|---|
| 1. Nhân viên kho | WMS | nhập/xuất/in/kiểm | ✅ `users` + roles (system-context) |
| 2. Khách hàng | Ecommerce | mua hàng | ❌ `customers` chưa có schema |
| 3. Back-office shop | Ecommerce | sửa giá, CRUD catalog, duyệt đơn, hoàn tiền | ❌ chỉ gọi trống "Admin" ([catalog UC-C05](../../catalog/use-cases.md)) |

**Spec này định nghĩa:** danh tính + cơ chế đăng nhập/token cho cả 3 nhóm, schema `customers` (lấp chỗ Order/Catalog đang trỏ `customerId`), quản lý tài khoản nhân viên, refresh token, verify email, quên/đổi mật khẩu, khóa tài khoản.

**Ngoài phạm vi (YAGNI):** sổ cái tiền `payment_transactions` (brainstorm riêng cho Order/Payment ngay sau spec này); SSO/OAuth social login; 2FA; guest checkout (đã loại ở gap-analysis); tách `SHOP_MANAGER` thành `CATALOG_MANAGER`/`ORDER_MANAGER` nếu cần phân tầng hơn.

## 2. Cấu trúc tài liệu

Hai thư mục module, mỗi cái bộ 3 file chuẩn:

```
auth-wms/    (wms_db)   use-cases.md · data-model.md · workflow.md   — nhân viên nội bộ (kho + back-office shop)
auth-ecom/   (ecom_db)  use-cases.md · data-model.md · workflow.md   — khách hàng
```

Phần JWT/`libs/auth` dùng chung **không lặp đặc tả**: [system-context.md#auth](../../overview/system-context.md) là **nguồn chuẩn**; mỗi `data-model.md` chỉ trỏ tới nó và mô tả phần token riêng của app.

## 3. Nguyên tắc & bất biến

- Không đọc chéo collection giữa 2 app. WMS `users` ∈ `wms_db`; Ecom `customers` ∈ `ecom_db`. Mỗi app có collection refresh-token riêng.
- Auth nội-app đồng bộ. Auth chỉ phát event **sang Notification** (không phát event giữa WMS↔Ecom).
- `customers._id` = `customerId` mà Order/Catalog tham chiếu. Order vẫn **snapshot** địa chỉ lúc checkout (không trỏ ref địa chỉ).

## 4. Cơ chế token

- **Access token** JWT, sống ngắn (~15 phút), **stateless** — mỗi app tự validate bằng **public key riêng** (RS256). Không shared secret.
- **Refresh token** sống dài (~7–30 ngày), **lưu DB (đã hash)**, thu hồi được. Mỗi lần refresh **xoay token** (cấp refresh mới, revoke cũ).
- **JWT payload claim `type`**: `user` = nhân viên kho (WMS token), `customer` = khách (Ecom token), `admin` = nhân viên shop (Ecom token từ `admin_users`).
- **Logout** = revoke refresh token hiện tại.
- **Khóa tài khoản** (`status=LOCKED`) = revoke toàn bộ refresh của user + chặn cấp access/refresh mới.

### Back-office shop dùng collection riêng (Hướng B)

- `ecom_db.admin_users` = danh bạ nhân viên shop, role `ECOM_MANAGER`.
- Nhân viên shop đăng nhập qua Ecom FE `/admin/login` → Ecom backend → token `type=admin`.
- Route `/admin/*` của Ecom: bắt buộc `type=admin`. Token khách (`type=customer`) hoặc token kho (`type=user`) đều không qua được.
- WMS và Ecom auth hoàn toàn độc lập — mỗi app có private/public key riêng.

## 5. Data Model

### 5.1 auth-ecom (`ecom_db`)

**`customers`** — module Auth sở hữu:

| Field | Kiểu | Ghi chú |
|---|---|---|
| `_id` | ObjectId | = `customerId` Order/Catalog tham chiếu |
| `email` | string, unique | định danh đăng nhập |
| `passwordHash` | string | bcrypt/argon2 |
| `name` | string | |
| `phone` | string | |
| `emailVerified` | bool | mặc định `false`, **không chặn** mua hàng |
| `status` | enum `ACTIVE` / `LOCKED` | |
| `addresses` | embedded[] | sổ địa chỉ — xem dưới |
| `createdAt` / `updatedAt` | date | |

**`addresses[]`** (embedded): `{ _id, label, recipientName, phone, line, ward, district, province, isDefault }`. Bất biến: đúng **1 mục** `isDefault=true`.

**`customer_refresh_tokens`**: `{ _id, customerId, tokenHash, expiresAt, createdAt, revokedAt? }`.

**`customer_auth_tokens`** (gộp verify-email + reset-password): `{ _id, customerId, type: VERIFY_EMAIL | RESET_PASSWORD, tokenHash, expiresAt, usedAt? }`. Token một-lần; hết hạn ngắn (verify ~24h, reset ~1h).

### 5.2 auth-wms (`wms_db`)

**`users`**:

| Field | Kiểu | Ghi chú |
|---|---|---|
| `_id` | ObjectId | |
| `username` | string, unique | đăng nhập nội bộ |
| `email` | string | liên hệ (không dùng verify) |
| `passwordHash` | string | |
| `name` | string | |
| `roles` | string[] | ADMIN / MANAGER / RECEIVER / PICKER / PRINTER / COUNTER |
| `status` | enum `ACTIVE` / `LOCKED` | |
| `mustChangePassword` | bool | `true` sau khi ADMIN reset mật khẩu tạm |
| `createdAt` / `updatedAt` | date | |

**`user_refresh_tokens`**: `{ _id, userId, tokenHash, expiresAt, createdAt, revokedAt? }`. Nhân viên **không** có verify-email/forgot-password qua email — ADMIN reset mật khẩu tạm.

## 6. Use Cases

### 6.1 auth-ecom (khách — token `type=customer`)

| UC | Tên | Tóm tắt |
|---|---|---|
| UC-AE01 | Đăng ký | tạo `customers` (`emailVerified=false`) → phát `customer.verify_requested` → trả access+refresh (login luôn) |
| UC-AE02 | Đăng nhập | email+mật khẩu → cấp access+refresh; chặn nếu `LOCKED` |
| UC-AE03 | Refresh token | refresh hợp lệ → cấp access mới + xoay refresh |
| UC-AE04 | Đăng xuất | revoke refresh hiện tại |
| UC-AE05 | Xác minh email | token verify hợp lệ → `emailVerified=true`, `usedAt` |
| UC-AE06 | Quên mật khẩu | nhập email → phát `customer.password_reset_requested`; trả thông báo trung tính (không lộ email tồn tại) |
| UC-AE07 | Đặt lại mật khẩu | token reset hợp lệ + mật khẩu mới → đổi hash + revoke toàn bộ refresh |
| UC-AE08 | Đổi mật khẩu | (đã login) mật khẩu cũ+mới → đổi hash |
| UC-AE09 | Quản lý sổ địa chỉ | CRUD `addresses[]`, đặt mặc định (đảm bảo đúng 1 default) |

### 6.2 auth-wms (nhân viên — token `type=user`, dùng được cả 2 app)

| UC | Tên | Tóm tắt |
|---|---|---|
| UC-AW01 | ADMIN tạo tài khoản nhân viên | username + roles[] + mật khẩu tạm, `mustChangePassword=true`; không tự đăng ký |
| UC-AW02 | ADMIN gán/sửa roles | cập nhật `roles[]` (giao với enum hợp lệ) |
| UC-AW03 | ADMIN khóa/mở khóa | `status=LOCKED/ACTIVE`; khóa ⇒ revoke toàn bộ refresh của user |
| UC-AW04 | ADMIN reset mật khẩu tạm | đặt mật khẩu tạm + `mustChangePassword=true` + revoke refresh |
| UC-AW05 | Đăng nhập nhân viên | cấp token `type=user` (dùng cả WMS + route admin Ecom) |
| UC-AW06 | Refresh / Đăng xuất nhân viên | như UC-AE03/04 |
| UC-AW07 | Đổi mật khẩu | xử lý `mustChangePassword` (ép đổi sau login đầu) |

## 7. Workflows (vẽ ở từng `workflow.md`)

- **auth-ecom:** Đăng ký→verify · Đăng nhập+refresh (xoay token) · Quên→reset mật khẩu · Quản lý sổ địa chỉ.
- **auth-wms:** ADMIN onboard nhân viên (mật khẩu tạm→ép đổi) · Đăng nhập nhân viên cấp token `type=user` dùng 2 app · Khóa tài khoản→revoke refresh.

## 8. Events mới (Auth → Notification)

| Event | Từ | Đến | Khi nào |
|---|---|---|---|
| `customer.verify_requested` | Ecommerce (Auth) | Notification | Khách đăng ký → gửi email link xác minh |
| `customer.password_reset_requested` | Ecommerce (Auth) | Notification | Khách quên mật khẩu → gửi email link/OTP reset |

## 9. Cập nhật cross-file (nhất quán)

1. **[data-ownership.md](../../overview/data-ownership.md)** — thêm `customers` (đặc tả), `customer_refresh_tokens`, `customer_auth_tokens` (cột Ecommerce) + `users`, `user_refresh_tokens` (cột WMS); thêm 2 event mục §8; ghi rõ back-office shop = `users` qua shared JWT (`type=user`).
2. **[system-context.md#auth](../../overview/system-context.md)** — bổ sung cơ chế access-ngắn + refresh-DB + claim `type`; ghi chú `users` phục vụ cả back-office Ecom.
3. **[gap-analysis.md](../../overview/gap-analysis.md)** — đánh dấu Auth ✅ (auth-wms + auth-ecom); thêm dòng follow-up "xem xét `payment_transactions` append-only cho đối soát dòng tiền".
4. **[catalog/use-cases.md UC-C05](../../catalog/use-cases.md)** + chú thích refund ở order/payment — trỏ Actor "Admin" về role ADMIN/MANAGER (`type=user`).
5. **[README.md](../../README.md)** — thêm 2 module vào mục lục.

## 10. Quyết định thiết kế (chốt qua brainstorm)

| # | Quyết định | Lý do |
|---|---|---|
| D1 | 2 thư mục `auth-wms` + `auth-ecom` | 2 app khác DB, khác user-type → boundary rõ |
| D2 | Access ngắn + refresh lưu DB | cân bằng stateless & nhu cầu thu hồi (khóa/logout) |
| D3 | Verify email khi đăng ký + reset qua email | xác minh khách, Auth thành producer event Notification |
| D4 | Chưa verify vẫn login & mua | ít ma sát, Order không cần check cờ verify |
| D5 | `customers.addresses[]` sổ địa chỉ nhiều mục | linh hoạt; Order vẫn snapshot lúc checkout |
| D6 | ADMIN tạo/khóa/reset nhân viên, không tự đăng ký | chuẩn nội bộ |
| D7 | Back-office shop = `ecom_db.admin_users` riêng (Hướng B); role `ECOM_MANAGER`; RS256 key riêng từng app | auth hoàn toàn độc lập, không shared secret; lộ key Ecom không ảnh hưởng WMS |

## 11. Follow-up (sau spec này)

- **Brainstorm Order/Payment:** sổ cái tiền `payment_transactions` append-only + đối soát COD/cổng (đã hẹn).
