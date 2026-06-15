---
title: "S1-04: Schema tồn 2 lớp + helper transaction"
labels: feat,module:warehouse,sprint:1,size:L
---

**Sprint:** 1 · **Size:** L · **Depends-on:** S1-01

## Bối cảnh
Lõi tồn kho 2 lớp — nền cho mọi nghiệp vụ nhập/xuất/kiểm/chuyển. Bất biến: `StockBalance.onHand` = Σ `InventoryStock.quantity` mọi shelf; `available = onHand − reserved − expired`; mọi biến động cập nhật **cả 2 lớp trong 1 transaction**; `StockMovement` append-only. Theo [warehouse/data-model.md → Nhóm 2](../../warehouse/data-model.md) và [db/02-hang-hoa-va-ton-kho.md](../../db/02-hang-hoa-va-ton-kho.md).

## Phạm vi
- [ ] Schema `WarehouseItem` (SKU, loại MATERIAL/CUP_BLANK/CUP_PRINTED/PACKAGING, `unitVolume`, `isPerishable`, kích thước item).
- [ ] Schema `StockBalance` (per SKU per warehouse: `onHand`, `reserved`, `expired`).
- [ ] Schema `InventoryStock` (per SKU per shelf per lô: `quantity`, `lotNumber`, `expiryDate`).
- [ ] Schema `StockMovement` (append-only: type, sku, từ/tới shelf, qty, refType/refId, timestamp).
- [ ] Helper `applyStockChange()` chạy trong Mongo transaction: cập nhật `InventoryStock` + `StockBalance` + ghi `StockMovement` **nguyên tử**; ném lỗi nếu vi phạm bất biến (Σ ≠ onHand).

## Acceptance criteria
- Gọi `applyStockChange(+10)` → `InventoryStock.quantity`, `StockBalance.onHand` đều +10 và có 1 `StockMovement`.
- Mô phỏng lỗi giữa transaction → rollback cả 3, không để lệch lớp.
- Test khẳng định `onHand === Σ InventoryStock.quantity` sau chuỗi thao tác.

## Tham chiếu
- [warehouse/data-model.md](../../warehouse/data-model.md) §Nhóm 2 — Hàng hóa & tồn kho.
- [db/02-hang-hoa-va-ton-kho.md](../../db/02-hang-hoa-va-ton-kho.md).
- [overview/data-ownership.md](../../overview/data-ownership.md) — quy ước tồn & event.
