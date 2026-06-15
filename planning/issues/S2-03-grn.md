---
title: "S2-03: UC-02 GRN — nhận hàng, cộng tồn 2 lớp, lot/expiry"
labels: feat,module:warehouse,sprint:2,size:L
---

**Sprint:** 2 · **Size:** L · **Depends-on:** S1-04, S2-02

## Bối cảnh
Good Receive Note: nhận hàng theo PO, cộng tồn. Bất biến: GRN `CONFIRMED` cộng `onHand` (hàng sellable ngay); hàng `isPerishable` bắt buộc `lotNumber + expiryDate`; mọi cộng tồn qua helper `applyStockChange` (S1-04) để ghi `StockMovement`. Theo [warehouse/use-cases.md UC-02](../../warehouse/use-cases.md) + [workflow.md WF-01](../../warehouse/workflow.md).

## Phạm vi
- [ ] Schema `GoodsReceiptNote` + dòng nhận (sku, qty, lot, expiry) tham chiếu PO.
- [ ] Nhận hàng vào **shelf staging**; quét barcode SKU.
- [ ] `CONFIRMED` → gọi `applyStockChange(+qty)` cộng `onHand` (2 lớp + `StockMovement` type `RECEIPT`) trong 1 transaction.
- [ ] Validate `isPerishable` thiếu lot/expiry → từ chối.
- [ ] Cập nhật trạng thái PO (`PARTIALLY_RECEIVED`/`COMPLETED`).
- [ ] Phát event `stock.changed(+)` (qua S2-06 nếu đã có; nếu chưa, để TODO publisher).

## Acceptance criteria
- GRN `CONFIRMED` làm `onHand` += đúng tổng qty; có `StockMovement` `RECEIPT`.
- Hàng perishable thiếu expiry → 400.
- Nhận đủ PO → PO `COMPLETED`; nhận một phần → `PARTIALLY_RECEIVED`.

## Tham chiếu
- [warehouse/use-cases.md](../../warehouse/use-cases.md) UC-02 · [warehouse/workflow.md](../../warehouse/workflow.md) WF-01.
- [db/03-nhap-kho.md](../../db/03-nhap-kho.md)
