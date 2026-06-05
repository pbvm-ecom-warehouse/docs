# Auth-WMS (Nhân viên) — Use Cases

> Trạng thái: 🔄 Đang phân tích
> Module Auth phía WMS — danh tính **nhân viên** (`users`). `users` là **danh bạ nhân viên DUY NHẤT** cho cả kho lẫn back-office shop (Ecommerce). Cơ chế JWT/token chung: [system-context#auth](../overview/system-context.md#auth). Spec: [2026-06-05-auth-design](../superpowers/specs/2026-06-05-auth-design.md).

## Tổng quan

| # | Tên | Actor | Trạng thái |
|---|---|---|---|
| UC-AW01 | Tạo tài khoản nhân viên | ADMIN | 🔄 Đang phân tích |
| UC-AW02 | Gán/sửa roles | ADMIN | 🔄 Đang phân tích |
| UC-AW03 | Khóa / mở khóa tài khoản | ADMIN | 🔄 Đang phân tích |
| UC-AW04 | Reset mật khẩu tạm | ADMIN | 🔄 Đang phân tích |
| UC-AW05 | Đăng nhập nhân viên | Nhân viên | 🔄 Đang phân tích |
| UC-AW06 | Làm mới token / Đăng xuất | Nhân viên | 🔄 Đang phân tích |
| UC-AW07 | Đổi mật khẩu | Nhân viên | 🔄 Đang phân tích |

> **Token nhân viên mang claim `type = user`** → dùng được trên app WMS **và** route admin của Ecommerce (validate bằng shared secret, không đọc chéo DB). Route admin Ecom bắt buộc `type = user` + role ⊇ {ADMIN, MANAGER} — token khách (`type = customer`) không bao giờ qua được. Đây là cách làm rõ Actor "Admin" của [catalog UC-C05](../catalog/use-cases.md#uc-c05-quản-trị-catalog-crud).

---

## UC-AW01: Tạo tài khoản nhân viên

**Actor:** ADMIN
**Mục đích:** Onboard nhân viên — **không có tự đăng ký**.

### Luồng chính
1. Nhập `username` (unique), `name`, `email`, `roles[]` (giao với enum hợp lệ) + mật khẩu tạm
2. Tạo `users` với `status = ACTIVE`, `mustChangePassword = true`
3. Nhân viên đăng nhập lần đầu bị ép đổi mật khẩu (xem [UC-AW07](#uc-aw07-đổi-mật-khẩu))

---

## UC-AW02: Gán/sửa roles

**Actor:** ADMIN
**Mục đích:** Phân quyền theo nghiệp vụ.

### Luồng chính
1. Cập nhật `roles[]` — tập con của `ADMIN/MANAGER/RECEIVER/PICKER/PRINTER/COUNTER`
2. 1 user giữ **nhiều role** (vd vừa `RECEIVER` vừa `PICKER`); RolesGuard cho qua nếu giao ≠ ∅, `ADMIN` bypass
3. Việc back-office shop (sửa giá, CRUD catalog, duyệt đơn, hoàn tiền) tạm dùng `ADMIN`/`MANAGER` — *(đường nâng cấp: tách `CATALOG_MANAGER`/`ORDER_MANAGER`, chưa làm ở v1)*

---

## UC-AW03: Khóa / mở khóa tài khoản

**Actor:** ADMIN
**Mục đích:** Vô hiệu hóa nhân viên nghỉ việc / sự cố.

### Luồng chính
1. `status = LOCKED` ⇒ chặn đăng nhập + **revoke toàn bộ refresh** của user (`user_refresh_tokens`)
2. Access token đang sống tự hết sau ~15 phút (đánh đổi của stateless)
3. `LOCKED → ACTIVE` để khôi phục

> Sơ đồ: [WF-AW03](./workflow.md#wf-aw03-khóa-tài-khoản).

---

## UC-AW04: Reset mật khẩu tạm

**Actor:** ADMIN
**Mục đích:** Cấp lại mật khẩu khi nhân viên quên (không có luồng email tự phục vụ cho nhân viên).

### Luồng chính
1. ADMIN đặt mật khẩu tạm → `mustChangePassword = true` + **revoke toàn bộ refresh**
2. Nhân viên đăng nhập bằng mật khẩu tạm → bị ép đổi ngay

---

## UC-AW05: Đăng nhập nhân viên

**Actor:** Nhân viên
**Luồng chính:**
1. `username` + mật khẩu → khớp `passwordHash`, `status = ACTIVE`
2. Cấp **access** (`type = user`, ~15 phút) + **refresh** (lưu `user_refresh_tokens`)
3. `mustChangePassword = true` → buộc đổi mật khẩu trước khi thao tác (xem [UC-AW07](#uc-aw07-đổi-mật-khẩu))

---

## UC-AW06: Làm mới token / Đăng xuất

**Actor:** Nhân viên
**Luồng chính:** Refresh hợp lệ → xoay token (cấp mới, revoke cũ). Đăng xuất → revoke refresh hiện tại. (Giống [UC-AE03/04](../auth-ecom/use-cases.md#uc-ae03-làm-mới-token-refresh).)

---

## UC-AW07: Đổi mật khẩu

**Actor:** Nhân viên
**Luồng chính:** Nhập mật khẩu cũ + mới → đổi `passwordHash`, hạ `mustChangePassword = false`. Trường hợp ép đổi sau reset/đăng nhập đầu cũng đi qua đây.
