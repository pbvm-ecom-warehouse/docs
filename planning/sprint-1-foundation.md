# Sprint 1 — Nền móng & Auth (Week 1)

**Mục tiêu:** Dựng được monorepo WMS chạy, đăng nhập theo role, và có đủ schema lõi (cấu trúc kho + tồn 2 lớp) để các sprint sau ghi tồn vào.

**Định nghĩa Done sprint:** `npm run start:dev wms` chạy; login ADMIN trả JWT; gọi được CRUD kho qua Swagger; 4 schema tồn tạo được document mẫu với helper transaction cập nhật cả 2 lớp.

## Issues

- [ ] [S1-01](issues/S1-01-scaffold-monorepo.md) — Scaffold NestJS monorepo + kết nối `wms_db` · `infra/L`
- [ ] [S1-02](issues/S1-02-auth-wms.md) — Auth-WMS: login, JWT, RolesGuard, seed ADMIN · `feat/L` *(dep S1-01)*
- [ ] [S1-03](issues/S1-03-warehouse-structure-schema.md) — Schema cấu trúc kho + CRUD · `feat/M` *(dep S1-01)*
- [ ] [S1-04](issues/S1-04-inventory-two-layer-schema.md) — Schema tồn 2 lớp + helper transaction · `feat/L` *(dep S1-01)*
- [ ] [S1-05](issues/S1-05-docs-notification.md) — *(docs)* Viết module Notification · `docs/M`

## Lưu ý điều phối

S1-01 chặn mọi việc còn lại → ưu tiên xong sớm ngày 1-2. Sau đó S1-02/S1-03/S1-04 chạy song song (3 dev) hoặc tuần tự (2 dev, có thể đẩy S1-04 sang đầu Sprint 2). S1-05 là track docs độc lập.
