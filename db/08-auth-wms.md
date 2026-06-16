# 08 — Auth-WMS (Nhân viên)

> Bảng: `users`, `user_refresh_tokens` · Schema gốc: [auth-wms/data-model](../auth-wms/data-model.md)

Quản lý tài khoản **nhân viên nội bộ** — danh bạ DUY NHẤT cho cả kho lẫn back-office shop.

## users

| Field | Ý nghĩa |
|---|---|
| `username` | **unique** — định danh đăng nhập |
| `passwordHash` | bcrypt/argon2 |
| `roles[]` | Tập role: `ADMIN` / `MANAGER` / `RECEIVER` / `PICKER` / `PRINTER` / `COUNTER` |
| `status` | `ACTIVE` / `LOCKED` |
| `mustChangePassword` | `true` sau khi ADMIN tạo/reset mật khẩu tạm → ép đổi lần đăng nhập kế |
| `warehouseId` | Kho mặc định (tùy chọn) |

## Nhiều role / 1 user

- Một nhân viên có thể giữ **nhiều role** cùng lúc (vd vừa PICKER vừa PRINTER).
- **RolesGuard** cho qua nếu `roles` **giao** với `@Roles(...)` yêu cầu ≠ ∅.
- `ADMIN` **bypass mọi guard**.

## `users` là danh bạ nhân viên kho

JWT của nhân viên kho mang claim **`type = user`**, chỉ dùng trong WMS app. WMS backend ký token bằng **private key riêng** (RS256).

Back-office shop (catalog, đơn hàng) dùng `ecom_db.admin_users` với auth riêng của Ecom backend — token mang claim `type = admin`. Hai hệ thống auth hoàn toàn độc lập, không shared secret. Xem [auth-ecom/data-model](../auth-ecom/data-model.md).

## user_refresh_tokens

| Field | Ý nghĩa |
|---|---|
| `userId` | → users |
| `tokenHash` | Hash của refresh token (không lưu plaintext) |
| `expiresAt` | ~7–30 ngày |
| `revokedAt?` | Set khi logout / xoay token / reset / khóa tài khoản |

> **Access token JWT stateless không lưu** (hết hạn ngắn). Chỉ **refresh token lưu DB** để **thu hồi được** (logout, khóa tài khoản). Nhân viên **không** có token verify/reset qua email — quên mật khẩu thì ADMIN reset mật khẩu tạm (UC-AW04).

---

← [07 — Shipping](07-shipping.md) · → [09 — Catalog](09-catalog.md)
