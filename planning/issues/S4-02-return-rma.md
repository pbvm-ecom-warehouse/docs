---
title: "S4-02: UC-09 Return / RMA — nhận hoàn về kho"
labels: feat,module:warehouse,sprint:4,size:M
---

**Sprint:** 4 · **Size:** M · **Depends-on:** S1-04

## Bối cảnh
Nhận hàng hoàn về kho (RECEIVER). Trong phạm vi WMS-thuần: nhập lại tồn cho hàng còn bán được, hoặc đẩy sang scrap nếu hỏng. RMA từng phần ngoài phạm vi. Theo [warehouse/use-cases.md UC-09](../../warehouse/use-cases.md).

## Phạm vi
- [ ] Schema `ReturnNote` (nguồn hoàn, dòng sku/qty/lô, tình trạng: tái nhập/hỏng).
- [ ] RECEIVER nhận hoàn → nếu tái nhập: `applyStockChange(+qty)` (`StockMovement` `RETURN_IN`) + put-away; nếu hỏng → tạo `ScrapRequest` (S4-01).
- [ ] Quét barcode khi nhận.

## Acceptance criteria
- Hàng tái nhập → `onHand` tăng đúng; `StockMovement` `RETURN_IN`.
- Hàng hỏng → sinh đề xuất scrap, không cộng tồn khả dụng.

## Tham chiếu
- [warehouse/use-cases.md](../../warehouse/use-cases.md) UC-09.
