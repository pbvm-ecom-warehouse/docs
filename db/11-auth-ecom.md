# 11 — Auth-Ecom (Khách hàng)

> Bảng: `customers`, `customer_refresh_tokens`, `customer_auth_tokens` · Schema gốc: [auth-ecom/data-model](../auth-ecom/data-model.md)

Quản lý tài khoản **khách hàng** bên `ecom_db`. Chủ thể `type = customer`.

## customers

| Field | Ý nghĩa |
|---|---|
| `email` | **unique** — định danh đăng nhập |
| `passwordHash` | bcrypt/argon2 |
| `emailVerified` | mặc định `false` — **không chặn** mua hàng, chỉ hiển thị nhắc |
| `status` | `ACTIVE` / `LOCKED` |
| `addresses[]` | **Sổ địa chỉ embedded** — xem dưới |

> `customers.id` chính là **`customerId`** mà [Order](10-order.md) và [Catalog](09-catalog.md) (`designs`) tham chiếu. Order/Catalog **không định nghĩa schema Customer** — chỉ trỏ id.

### addresses[] — embedded, không phải bảng riêng

| Field | Ý nghĩa |
|---|---|
| label, recipientName, phone | Nhãn ("Nhà"/"Công ty"), người nhận |
| line, ward, district, province | Địa chỉ chi tiết |
| `isDefault` | **Bất biến: đúng 1 mục `isDefault = true`** |

> **Vì sao embedded?** Sổ địa chỉ luôn đọc/ghi cùng customer, không truy vấn độc lập → nhúng thẳng vào document customer (đặc trưng MongoDB), gọn hơn 1 bảng riêng + join.

> **Order snapshot địa chỉ lúc checkout** — không trỏ ref `Address._id`. Khách sửa/xóa địa chỉ sau này không ảnh hưởng đơn đã đặt (xem [khái niệm ④](00-khai-niem-loi.md)).

## Hai loại token — vì sao tách 2 bảng?

### customer_refresh_tokens — phiên đăng nhập
| Field | Ý nghĩa |
|---|---|
| `tokenHash` | Hash refresh token (không lưu plaintext) |
| `expiresAt` | ~7–30 ngày |
| `revokedAt?` | logout / xoay / reset / khóa |

Để **thu hồi phiên** được (access JWT stateless không thu hồi được).

### customer_auth_tokens — token một-lần
| Field | Ý nghĩa |
|---|---|
| `type` | `VERIFY_EMAIL` / `RESET_PASSWORD` (gộp 1 bảng theo type) |
| `tokenHash` | Hash token gửi qua email |
| `expiresAt` | verify ~24h, reset ~1h |
| `usedAt?` | Đánh dấu đã dùng (một-lần) |

> **Tách 2 bảng vì khác bản chất:** refresh token = **phiên dài hạn** (thu hồi khi logout); auth token = **mã một-lần ngắn hạn** gửi email (dùng xong khóa). Gộp chung sẽ lẫn vòng đời.

## So với Auth-WMS

| | Auth-Ecom (khách) | Auth-WMS (nhân viên) |
|---|---|---|
| claim | `type = customer` | `type = user` |
| Verify/reset qua email | ✅ (`customer_auth_tokens`) | ❌ (ADMIN reset tay) |
| Sổ địa chỉ | ✅ embedded | ❌ |

Cấu trúc refresh token **song song** nhau (cùng pattern).

---

← [10 — Order](10-order.md) · → [12 — Luồng end-to-end](12-luong-end-to-end.md)
