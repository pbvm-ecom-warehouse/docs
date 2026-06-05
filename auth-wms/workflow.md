# Auth-WMS (Nhân viên) — Workflow

> Trạng thái: 🔄 Đang phân tích

## Luồng tổng quan

```
[WF-AW01 ADMIN onboard nhân viên] → mật khẩu tạm → ép đổi
[WF-AW02 Đăng nhập → token type=user dùng cả 2 app]
[WF-AW03 Khóa tài khoản → revoke toàn bộ refresh]
```

---

## WF-AW01: ADMIN onboard nhân viên

```
ADMIN                 AUTH-WMS
  |-- tạo user (username, roles[], mật khẩu tạm) -->| status=ACTIVE, mustChangePassword=true
  |                                                  |
NHÂN VIÊN
  |-- đăng nhập (mật khẩu tạm) -->| mustChangePassword? YES → ép đổi mật khẩu
  |-- đặt mật khẩu mới ---------->| mustChangePassword=false → vào hệ thống
```

> Không có tự đăng ký nhân viên (xem [UC-AW01](./use-cases.md#uc-aw01-tạo-tài-khoản-nhân-viên)).

---

## WF-AW02: Đăng nhập → token dùng cả 2 app

```
NHÂN VIÊN            AUTH-WMS (app nội bộ)        ECOMMERCE (app public)
  |-- username+mật khẩu ->| khớp hash? ACTIVE?         |
  |<-- access(type=user)+refresh                       |
  |                                                    |
  |== gọi route admin Ecom (sửa giá / duyệt đơn) ====> | JwtAuthGuard + RolesGuard
  |       (kèm access token)                           |  validate shared secret tại chỗ
  |                                                    |  type==user? roles ⊇ {ADMIN,MANAGER}?
  |                                                    |  YES → cho qua (KHÔNG đọc wms_db)
  |<-------------------------------------------------- |  token type=customer → 403
```

> App Ecommerce **không đọc `wms_db.users`** — chỉ tin claim trong token đã ký bằng shared secret. Đây là cách hiện thực Hướng A (một danh bạ nhân viên).

---

## WF-AW03: Khóa tài khoản

```
ADMIN                 AUTH-WMS
  |-- khóa user -->| status=LOCKED
  |                |-- revoke TẤT CẢ user_refresh_tokens (revokedAt=now)
  |                |   → không refresh được nữa; access cũ tự hết sau ~15'
  |
  |-- mở khóa ---->| status=ACTIVE (nhân viên đăng nhập lại để lấy token mới)
```

> Cùng cơ chế thu hồi áp dụng khi reset mật khẩu tạm ([UC-AW04](./use-cases.md#uc-aw04-reset-mật-khẩu-tạm)) và khi khách reset mật khẩu ([WF-AE03](../auth-ecom/workflow.md#wf-ae03-quên--đặt-lại-mật-khẩu)).
