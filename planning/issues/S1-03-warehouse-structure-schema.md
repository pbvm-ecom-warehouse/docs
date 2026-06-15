---
title: "S1-03: Schema cấu trúc kho (Warehouse/Zone/Rack/Shelf) + CRUD"
labels: feat,module:warehouse,sprint:1,size:M
---

**Sprint:** 1 · **Size:** M · **Depends-on:** S1-01

## Bối cảnh
Cấu trúc phân cấp kho `Warehouse → Zone → Rack → Shelf`, kèm **kích thước Shelf** để phục vụ gợi ý put-away (S2-05). Theo [warehouse/data-model.md → Nhóm 1](../../warehouse/data-model.md).

## Phạm vi
- [ ] Schema `Warehouse` (loại `CENTRAL`/`SUB`), `Zone`, `Rack`, `Shelf`.
- [ ] `Shelf` có kích thước (`length`/`width`/`height`), `usableVolume` (dẫn xuất), `fillFactor`, cờ `isStaging`.
- [ ] CRUD REST cho từng cấp (guard `@Roles('MANAGER')` cho ghi).
- [ ] Sinh/đọc barcode vị trí (shelf).

## Acceptance criteria
- Tạo được cây kho mẫu CENTRAL có ≥1 zone/rack/shelf qua API.
- Shelf staging và shelf thật phân biệt được bằng `isStaging`.
- `usableVolume` tính đúng từ kích thước × `fillFactor`.

## Tham chiếu
- [warehouse/data-model.md](../../warehouse/data-model.md) §Nhóm 1 — Cấu trúc kho & vị trí.
- [db/01-kho-va-vi-tri.md](../../db/01-kho-va-vi-tri.md).
