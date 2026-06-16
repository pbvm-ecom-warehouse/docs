# Auth-WMS (Nhân viên) — Data Model

> Trạng thái: 🔄 Đang phân tích
> **Ownership:** `users`, `user_refresh_tokens` thuộc `wms_db`, do module **auth-wms** (app WMS) sở hữu. `users` là danh bạ nhân viên duy nhất cho cả kho lẫn back-office shop. Xem [data-ownership](../overview/data-ownership.md).
> Cơ chế token chung (access ngắn + refresh lưu DB, claim `type`): [system-context#auth](../overview/system-context.md#auth).

> **Audit (chung):** `users` (master) mang `createdBy`/`updatedBy`/`createdAt`/`updatedAt`/`deletedAt`; `user_refresh_tokens` dùng `createdAt`+`revokedAt`. Theo [Quy ước Audit](../overview/data-ownership.md#quy-ước-audit-chung-mọi-collection).

## User (Tài khoản nhân viên)

> Đích của mọi `@Roles(...)` guard trong WMS. Token `type = user` chỉ dùng trong WMS — Ecom có auth riêng (`ecom_db.admin_users`).

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| username | String | **unique** — định danh đăng nhập nội bộ |
| email | String | liên hệ (không dùng verify như khách) |
| passwordHash | String | bcrypt/argon2 |
| name | String | |
| roles | String[] | `ADMIN` / `MANAGER` / `RECEIVER` / `PICKER` / `PRINTER` / `COUNTER` |
| status | Enum | `ACTIVE` / `LOCKED` |
| mustChangePassword | Boolean | `true` sau khi ADMIN tạo/reset mật khẩu tạm → ép đổi lần đăng nhập kế |
| createdAt | DateTime | |
| updatedAt | DateTime | |

> **Nhiều role/user:** RolesGuard cho qua nếu `roles` giao với `@Roles(...)` ≠ ∅; `ADMIN` bypass mọi guard. `MANAGER` phụ trách kho (PO, GRN, in, kiểm). Back-office shop (catalog, đơn) dùng `ecom_db.admin_users` riêng — xem [auth-ecom/data-model](../auth-ecom/data-model.md).

## UserRefreshToken (`user_refresh_tokens`)

> Refresh token nhân viên — cấu trúc song song [`customer_refresh_tokens`](../auth-ecom/data-model.md#customerrefreshtoken-customer_refresh_tokens). Access token JWT stateless không lưu.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| userId | ObjectId | → User |
| tokenHash | String | hash của refresh token |
| expiresAt | DateTime | ~7–30 ngày |
| createdAt | DateTime | |
| revokedAt | DateTime? | set khi logout / xoay token / reset / khóa tài khoản |

> Nhân viên **không** có collection token verify/reset qua email — quên mật khẩu xử lý bằng ADMIN reset mật khẩu tạm ([UC-AW04](./use-cases.md#uc-aw04-reset-mật-khẩu-tạm)).
