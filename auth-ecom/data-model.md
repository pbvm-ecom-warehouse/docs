# Auth-Ecom (Khách hàng) — Data Model

> Trạng thái: 🔄 Đang phân tích
> **Ownership:** `customers`, `customer_refresh_tokens`, `customer_auth_tokens`, `admin_users`, `admin_refresh_tokens` thuộc `ecom_db`, do module **auth-ecom** (app Ecommerce) sở hữu. Xem [data-ownership](../overview/data-ownership.md).
> Cơ chế token (access ngắn + refresh lưu DB): [system-context#auth](../overview/system-context.md#auth). Ecom tự ký token bằng key riêng — không dùng chung secret với WMS.

> **Audit (chung):** `customers` (master) mang `createdAt`/`updatedAt`/`deletedAt`; các collection token dùng `createdAt`+`revokedAt`/`usedAt`. Theo [Quy ước Audit](../overview/data-ownership.md#quy-ước-audit-chung-mọi-collection).

## Customer (Tài khoản khách)

> Đích của `customerId` mà [Order](../order/data-model.md) và [Catalog](../catalog/data-model.md) tham chiếu. Trước đây chưa định nghĩa (gap) — nay module auth-ecom sở hữu.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | = `customerId` Order/Catalog trỏ tới |
| email | String | **unique** — định danh đăng nhập |
| passwordHash | String | bcrypt/argon2 |
| name | String | |
| phone | String | |
| emailVerified | Boolean | mặc định `false` — **không chặn** mua hàng, chỉ hiển thị nhắc |
| status | Enum | `ACTIVE` / `LOCKED` |
| addresses | Address[] | Sổ địa chỉ (embedded) — xem dưới |
| createdAt | DateTime | |
| updatedAt | DateTime | |

### Address (embedded trong Customer)

> Sổ địa chỉ nhiều mục; **bất biến: đúng 1 mục `isDefault = true`**. Order **snapshot** địa chỉ lúc checkout — không trỏ ref `Address._id`.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| label | String | Nhãn ("Nhà", "Công ty") |
| recipientName | String | Người nhận |
| phone | String | |
| line | String | Số nhà, đường |
| ward | String | Phường/xã |
| district | String | Quận/huyện |
| province | String | Tỉnh/thành |
| isDefault | Boolean | |

## AdminUser (`admin_users`)

> Tài khoản nhân viên back-office shop — **tách biệt hoàn toàn** với `wms_db.users`. Ecom backend tự quản auth, ký token bằng key riêng.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| username | String | **unique** — định danh đăng nhập |
| email | String | liên hệ |
| passwordHash | String | bcrypt/argon2 |
| name | String | |
| roles | String[] | `ECOM_MANAGER` — mở rộng sau nếu cần |
| status | Enum | `ACTIVE` / `LOCKED` |
| mustChangePassword | Boolean | `true` sau khi tạo/reset mật khẩu tạm |
| createdAt | DateTime | |
| updatedAt | DateTime | |

> **Tạo account:** WMS_ADMIN hoặc người có quyền truy cập Ecom backend tạo thủ công (seed script hoặc endpoint riêng). Ít người, ít thay đổi — không cần UI quản lý phức tạp ở v1.

## AdminRefreshToken (`admin_refresh_tokens`)

> Song song với `user_refresh_tokens` bên WMS — cùng cơ chế thu hồi.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| adminId | ObjectId | → AdminUser |
| tokenHash | String | hash của refresh token |
| expiresAt | DateTime | ~7–30 ngày |
| createdAt | DateTime | |
| revokedAt | DateTime? | set khi logout / xoay token / reset / khóa |

## CustomerRefreshToken (`customer_refresh_tokens`)

> Refresh token lưu DB để thu hồi được (logout / khóa tài khoản). Access token JWT stateless không lưu.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| customerId | ObjectId | → Customer |
| tokenHash | String | hash của refresh token (không lưu plaintext) |
| expiresAt | DateTime | ~7–30 ngày |
| createdAt | DateTime | |
| revokedAt | DateTime? | set khi logout / xoay token / reset mật khẩu / khóa |

## CustomerAuthToken (`customer_auth_tokens`)

> Token một-lần cho verify email & reset mật khẩu (gộp 1 collection theo `type`).

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| customerId | ObjectId | → Customer |
| type | Enum | `VERIFY_EMAIL` / `RESET_PASSWORD` |
| tokenHash | String | hash của token gửi qua email |
| expiresAt | DateTime | verify ~24h, reset ~1h |
| usedAt | DateTime? | đánh dấu đã dùng (một-lần) |
