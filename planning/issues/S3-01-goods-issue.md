---
title: "S3-01: UC-05 Soạn & xuất hàng — pick, trừ tồn, goods.issued"
labels: feat,module:warehouse,sprint:3,size:L
---

**Sprint:** 3 · **Size:** L · **Depends-on:** S1-04, S2-06

## Bối cảnh
Xuất kho: soạn hàng theo yêu cầu, trừ tồn, phát `goods.issued`. Trong WMS-thuần (Ecom ngoài phạm vi 4 tuần), trigger xuất là **lệnh nội bộ/thủ công** (MANAGER tạo) thay cho `order.placed`; reserve/trừ tồn vẫn chạy trực tiếp trên `wms_db`. Theo [warehouse/use-cases.md UC-05](../../warehouse/use-cases.md).

## Phạm vi
- [ ] Schema `PickList`/`GoodsIssue` (dòng: sku, qty, shelf gợi ý theo vị trí tồn).
- [ ] Hệ hiển thị vị trí (Zone/Rack/Shelf) để PICKER lấy; ưu tiên lô FEFO cho hàng `isPerishable`.
- [ ] PICKER quét SKU + quét shelf để xác nhận đúng chỗ.
- [ ] Xác nhận xuất → `applyStockChange(−qty)` (2 lớp + `StockMovement` type `ISSUE`) trong transaction; phát `stock.changed(−)` + `goods.issued`.

## Acceptance criteria
- Xuất hàng → `onHand` −= đúng; `StockMovement` `ISSUE` ghi nhận; event `goods.issued` phát ra.
- Quét sai shelf (không có tồn SKU đó) → cảnh báo, không trừ.
- Hàng perishable: gợi ý lô hết hạn sớm nhất trước (FEFO).

## Tham chiếu
- [warehouse/use-cases.md](../../warehouse/use-cases.md) UC-05.
- [db/05-xuat-kho-va-noi-bo.md](../../db/05-xuat-kho-va-noi-bo.md)
