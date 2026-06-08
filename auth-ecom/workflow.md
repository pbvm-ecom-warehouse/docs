# Auth-Ecom (Khách hàng) — Workflow

> Trạng thái: 🔄 Đang phân tích

## Luồng tổng quan

```
[WF-AE01 Đăng ký → xác minh email]    [WF-AE02 Đăng nhập + refresh (xoay token)]
[WF-AE03 Quên → đặt lại mật khẩu]      → revoke toàn bộ refresh
```

---

## WF-AE01: Đăng ký → xác minh email

```
KHÁCH                AUTH-ECOM                 NOTIFICATION
  |-- đăng ký ----------->| tạo customers (emailVerified=false)
  |                       |-- customer.verify_requested ----->| gửi email link
  |<-- access+refresh ----| (đăng nhập ngay nhưng không mua được)   |
  |                                                            |
  |-- mở link (token) --->| VERIFY_EMAIL còn hạn & chưa dùng? |
  |                       |   YES → emailVerified=true, token.usedAt
  |                       |   token hết hạn → cho gửi lại
```

> Chưa verify **không chặn** đăng nhập/checkout — chỉ hiển thị nhắc (xem [UC-AE01](./use-cases.md#uc-ae01-đăng-ký-tài-khoản)).

---

## WF-AE02: Đăng nhập + refresh (xoay token)

```
KHÁCH                AUTH-ECOM
  |-- email+mật khẩu ---->| khớp hash? status=ACTIVE?
  |<-- access + refresh --| (refresh lưu customer_refresh_tokens)
  |                       |
  |  ... access hết hạn (~15') ...
  |-- refresh token ----->| còn hạn & chưa revoke?
  |<-- access' + refresh' | XOAY: cấp mới, revoke refresh cũ
  |                       |
  |-- đăng xuất --------->| revoke refresh hiện tại
```

> `status = LOCKED` → chặn cấp token; mọi refresh đã bị revoke (xem [WF khóa tài khoản](../auth-wms/workflow.md)).

---

## WF-AE03: Quên → đặt lại mật khẩu

```
KHÁCH                AUTH-ECOM                 NOTIFICATION
  |-- quên (email) ------>| email tồn tại? → tạo RESET_PASSWORD (hạn ~1h)
  |                       |-- customer.password_reset_requested ->| gửi email link
  |<-- thông báo trung tính (không lộ email tồn tại hay không)    |
  |                                                                |
  |-- mở link + mật khẩu mới ->| token còn hạn & chưa dùng?
  |                       |   YES → đổi passwordHash, token.usedAt
  |                       |         + REVOKE toàn bộ refresh (đăng xuất mọi thiết bị)
```
