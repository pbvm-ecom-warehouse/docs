---
title: "S4-01: UC-08 Scrap — hủy hàng hết hạn/hỏng"
labels: feat,module:warehouse,sprint:4,size:M
---

**Sprint:** 4 · **Size:** M · **Depends-on:** S1-04

## Bối cảnh
Loại bỏ hàng hết hạn/hỏng khỏi tồn khả dụng. COUNTER/RECEIVER đề xuất → MANAGER duyệt. Theo [warehouse/use-cases.md UC-08](../../warehouse/use-cases.md).

## Phạm vi
- [ ] Schema `ScrapRequest` (dòng sku/shelf/lô/qty, lý do, trạng thái đề xuất/duyệt).
- [ ] Đề xuất scrap (gợi ý hàng quá `expiryDate`).
- [ ] MANAGER duyệt → `applyStockChange(−qty)` (`StockMovement` `SCRAP`), giảm `onHand`/`expired` phù hợp.

## Acceptance criteria
- Duyệt scrap → tồn giảm đúng; `StockMovement` `SCRAP` ghi lý do.
- Hàng quá hạn được gợi ý vào đề xuất.

## Tham chiếu
- [warehouse/use-cases.md](../../warehouse/use-cases.md) UC-08.
