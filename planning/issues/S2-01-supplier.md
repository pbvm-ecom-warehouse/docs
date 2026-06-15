---
title: "S2-01: Supplier + SupplierItem (bảng giá, blacklist, guard giá)"
labels: feat,module:supplier,sprint:2,size:M
---

**Sprint:** 2 · **Size:** M · **Depends-on:** S1-01

## Bối cảnh
Master data nhà cung cấp + danh mục giá, theo [supplier/](../../supplier/use-cases.md). Dùng cho guard giá khi tạo PO (S2-02).

## Phạm vi
- [ ] Schema `Supplier` (thông tin, trạng thái, cờ `isBlacklisted`).
- [ ] Schema `SupplierItem` (1 NCC/SKU: giá, đơn vị) — ràng buộc duy nhất (supplierId, sku).
- [ ] CRUD NCC + danh mục giá (guard `@Roles('MANAGER')`).
- [ ] API gợi ý giá theo SKU; guard chặn tạo PO với NCC blacklist.

## Acceptance criteria
- Tạo NCC + bảng giá; trùng (supplierId, sku) bị từ chối.
- Blacklist NCC → API "có thể tạo PO?" trả false.

## Tham chiếu
- [supplier/use-cases.md](../../supplier/use-cases.md) · [supplier/data-model.md](../../supplier/data-model.md)
- [db/06-supplier.md](../../db/06-supplier.md)
