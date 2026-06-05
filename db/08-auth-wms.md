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

## `users` là chủ thể `type = user` — vì sao quan trọng?

JWT của nhân viên mang claim **`type = user`**. Đây là mấu chốt của thiết kế auth:

```
Nhân viên đăng nhập (WMS) ──► JWT { type: user, roles: [...] }
                                   │
                                   ▼ shared secret
         Route admin app Ecommerce validate TẠI CHỖ (không đọc chéo wms_db)
```

- Route admin của Ecommerce (vd quản lý catalog) **tin** token `type = user` qua **shared secret**, không cần query `wms_db`.
- Token khách mang `type = customer` → **không** qua được route admin.

→ Đây là cách hiện thực Actor "Admin" của catalog mà **không phá** nguyên tắc không đọc chéo DB. Cũng là lý do `createdBy` của các bảng catalog Ecom ghi "admin user (cross-app)".

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
