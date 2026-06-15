---
title: "S3-03: UC-06 Kiểm kê & điều chỉnh tồn"
labels: feat,module:warehouse,sprint:3,size:M
---

**Sprint:** 3 · **Size:** M · **Depends-on:** S1-04

## Bối cảnh
Kiểm đếm tồn thực tế và điều chỉnh chênh lệch. Mọi điều chỉnh phải qua `applyStockChange` để ghi `StockMovement` (loại `ADJUSTMENT`) — không sửa thẳng `onHand`. Theo [warehouse/use-cases.md UC-06](../../warehouse/use-cases.md).

## Phạm vi
- [ ] Schema `StockCount` (phiên đếm: phạm vi zone/rack/shelf, dòng: sku, shelf, qty hệ thống, qty đếm thực).
- [ ] COUNTER nhập số đếm thực (quét shelf + SKU).
- [ ] Tính chênh lệch; MANAGER duyệt → `applyStockChange(±diff)` sinh `StockMovement` `ADJUSTMENT`.
- [ ] Báo cáo chênh lệch của phiên.

## Acceptance criteria
- Đếm lệch +N/−N → sau duyệt, `onHand` khớp số đếm thực; có `StockMovement` `ADJUSTMENT` đúng dấu.
- Chưa duyệt → tồn chưa đổi.

## Tham chiếu
- [warehouse/use-cases.md](../../warehouse/use-cases.md) UC-06.
- [db/05-xuat-kho-va-noi-bo.md](../../db/05-xuat-kho-va-noi-bo.md)
