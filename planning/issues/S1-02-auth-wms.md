---
title: "S1-02: Auth-WMS — login, JWT + refresh, RolesGuard, seed ADMIN"
labels: feat,module:auth,sprint:1,size:L
---

**Sprint:** 1 · **Size:** L · **Depends-on:** S1-01

## Bối cảnh
Auth riêng cho nhân viên WMS (collection `users`), theo [auth-wms/](../../auth-wms/use-cases.md) và spec [2026-06-05-auth-design](../../superpowers/specs/2026-06-05-auth-design.md). 1 user nhiều role (`User.roles[]`).

## Phạm vi
- [ ] Schema `User` (collection `users`): `email`, `passwordHash`, `roles[]` (ADMIN/MANAGER/RECEIVER/PICKER/PRINTER/COUNTER), `isActive`.
- [ ] `POST /auth/login` → access token ngắn + refresh token lưu DB (thu hồi được).
- [ ] `POST /auth/refresh`, `POST /auth/logout` (xóa refresh đã lưu).
- [ ] JWT payload có `sub`, `roles`, `type=user` (theo nestjs-monorepo §JWT Payload).
- [ ] `JwtAuthGuard` + `RolesGuard` (`@Roles(...)`; pass nếu roles giao với yêu cầu; ADMIN bypass).
- [ ] Seed script tạo 1 ADMIN từ env.

## Acceptance criteria
- Login ADMIN trả access+refresh; gọi endpoint `@Roles('MANAGER')` bằng token ADMIN → 200 (bypass), bằng token RECEIVER → 403.
- Refresh đã logout không dùng lại được.

## Tham chiếu
- [auth-wms/use-cases.md](../../auth-wms/use-cases.md) · [auth-wms/data-model.md](../../auth-wms/data-model.md)
- [overview/nestjs-monorepo.md](../../overview/nestjs-monorepo.md) §2 Auth, §Guard trong WMS app.
