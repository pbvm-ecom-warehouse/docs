---
title: "S1-01: Scaffold NestJS monorepo + kết nối wms_db"
labels: infra,module:warehouse,sprint:1,size:L
---

**Sprint:** 1 · **Size:** L · **Depends-on:** —

## Bối cảnh
Khởi tạo monorepo theo [overview/nestjs-monorepo.md](../../overview/nestjs-monorepo.md). Đây là issue chặn toàn bộ phần code còn lại — ưu tiên xong sớm.

## Phạm vi
- [ ] `nest new` monorepo; tạo app `apps/wms`.
- [ ] Tạo libs: `libs/database`, `libs/shared-types`, `libs/common`, `libs/auth` + path alias `@app/*` trong `tsconfig.json`.
- [ ] `@nestjs/mongoose` kết nối MongoDB logical DB `wms_db`; đọc `MONGO_URI` từ `apps/wms/.env`.
- [ ] `@nestjs/config` + validation env (Joi).
- [ ] Swagger tại `/docs`.
- [ ] Script `start:dev wms`, `build wms`, lint, format.
- [ ] Healthcheck `GET /health` trả `{status:'ok'}`.

## Acceptance criteria
- `npm run start:dev wms` khởi động không lỗi, kết nối được Mongo.
- `GET /health` → 200; Swagger mở được tại `/docs`.
- `npm run build wms` ra `dist/apps/wms/main`.

## Tham chiếu
- [overview/nestjs-monorepo.md](../../overview/nestjs-monorepo.md) — layout app/libs, path alias, .env.
- [overview/system-context.md](../../overview/system-context.md) — định danh app/DB.
