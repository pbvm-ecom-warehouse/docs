# Auth-Ecom (Khách hàng) — Use Cases

> Trạng thái: 🔄 Đang phân tích
> Module Auth phía Ecommerce — danh tính **khách hàng** (`customers`). Cơ chế JWT/token chung: xem [system-context#auth](../overview/system-context.md#auth). Spec: [2026-06-05-auth-design](../superpowers/specs/2026-06-05-auth-design.md).

## Tổng quan

| # | Tên | Actor | Trạng thái |
|---|---|---|---|
| UC-AE01 | Đăng ký tài khoản | Khách | 🔄 Đang phân tích |
| UC-AE02 | Đăng nhập | Khách | 🔄 Đang phân tích |
| UC-AE03 | Làm mới token (refresh) | Khách | 🔄 Đang phân tích |
| UC-AE04 | Đăng xuất | Khách | 🔄 Đang phân tích |
| UC-AE05 | Xác minh email | Khách | 🔄 Đang phân tích |
| UC-AE06 | Quên mật khẩu | Khách | 🔄 Đang phân tích |
| UC-AE07 | Đặt lại mật khẩu | Khách | 🔄 Đang phân tích |
| UC-AE08 | Đổi mật khẩu | Khách (đã đăng nhập) | 🔄 Đang phân tích |
| UC-AE09 | Quản lý sổ địa chỉ | Khách (đã đăng nhập) | 🔄 Đang phân tích |

> **Mọi token cấp ở đây mang claim `type = customer`** → không bao giờ qua được route admin của Ecommerce (route admin bắt buộc `type = user`, xem [auth-wms](../auth-wms/use-cases.md)).

---

## UC-AE01: Đăng ký tài khoản

**Actor:** Khách
**Mục đích:** Tạo tài khoản mua hàng.

### Luồng chính
1. Nhập `email` (unique), mật khẩu, `name`, `phone` → tạo `customers` với `emailVerified = false`, `status = ACTIVE`
2. Phát event [`customer.verify_requested`](../overview/data-ownership.md#các-event-đồng-bộ-giữa-wms-và-ecommerce) → Notification gửi email link xác minh
3. Cấp luôn access + refresh token (đăng nhập ngay) — **chưa verify vẫn mua được**, chỉ hiển thị nhắc xác minh
4. Email đã tồn tại → báo lỗi (không tạo trùng)

> Sơ đồ: [WF-AE01](./workflow.md#wf-ae01-đăng-ký--xác-minh-email).

---

## UC-AE02: Đăng nhập

**Actor:** Khách
**Mục đích:** Lấy token truy cập.

### Luồng chính
1. Nhập `email` + mật khẩu → so `passwordHash`
2. Hợp lệ → cấp **access** (~15 phút) + **refresh** (lưu DB `customer_refresh_tokens`)
3. `status = LOCKED` ⇒ **chặn**, báo tài khoản bị khóa
4. Sai mật khẩu → báo lỗi chung (không lộ email tồn tại hay không)

---

## UC-AE03: Làm mới token (refresh)

**Actor:** Khách
**Mục đích:** Gia hạn phiên không cần đăng nhập lại.

### Luồng chính
1. Gửi refresh token → tra `customer_refresh_tokens` (còn hạn, chưa `revokedAt`)
2. Hợp lệ → **xoay token**: cấp access mới + refresh mới, revoke refresh cũ
3. Refresh hết hạn/đã revoke → buộc đăng nhập lại

---

## UC-AE04: Đăng xuất

**Actor:** Khách
**Luồng chính:** Revoke refresh token hiện tại (`revokedAt = now`). Access còn sống tự hết sau vài phút.

---

## UC-AE05: Xác minh email

**Actor:** Khách
**Trigger:** Mở link trong email (mang token).

### Luồng chính
1. Token `type = VERIFY_EMAIL` trong `customer_auth_tokens` còn hạn, chưa `usedAt`
2. Hợp lệ → `customers.emailVerified = true`, đánh dấu token `usedAt`
3. Token hết hạn → cho gửi lại email xác minh (phát lại `customer.verify_requested`)

---

## UC-AE06: Quên mật khẩu

**Actor:** Khách
**Mục đích:** Khởi tạo luồng đặt lại mật khẩu.

### Luồng chính
1. Nhập `email` → nếu tồn tại: tạo token `RESET_PASSWORD` (`customer_auth_tokens`, hạn ~1h) → phát event [`customer.password_reset_requested`](../overview/data-ownership.md#các-event-đồng-bộ-giữa-wms-và-ecommerce)
2. **Luôn trả thông báo trung tính** ("nếu email tồn tại, đã gửi hướng dẫn") — không lộ email có trong hệ hay không

> Sơ đồ: [WF-AE03](./workflow.md#wf-ae03-quên--đặt-lại-mật-khẩu).

---

## UC-AE07: Đặt lại mật khẩu

**Actor:** Khách
**Trigger:** Mở link reset (mang token).

### Luồng chính
1. Token `RESET_PASSWORD` còn hạn, chưa `usedAt` + mật khẩu mới
2. Đổi `passwordHash`, đánh dấu token `usedAt`
3. **Revoke toàn bộ refresh token** của khách (đăng xuất mọi thiết bị)

---

## UC-AE08: Đổi mật khẩu

**Actor:** Khách (đã đăng nhập)
**Luồng chính:** Nhập mật khẩu cũ + mới → khớp cũ → đổi `passwordHash`. (Tùy chọn: revoke refresh khác để đăng xuất thiết bị khác.)

---

## UC-AE09: Quản lý sổ địa chỉ

**Actor:** Khách (đã đăng nhập)
**Mục đích:** CRUD `addresses[]` để chọn nhanh lúc checkout.

### Luồng chính
1. Thêm/sửa/xóa địa chỉ (`label`, `recipientName`, `phone`, `line`, `ward`, `district`, `province`)
2. Đặt mặc định: bật `isDefault` cho 1 mục → tắt mục cũ (**bất biến: đúng 1 mục `isDefault = true`**)
3. Checkout đọc `addresses[]` để gợi ý; Order **snapshot** địa chỉ đã chọn lên đơn — không trỏ ref (xem [order/data-model](../order/data-model.md))
