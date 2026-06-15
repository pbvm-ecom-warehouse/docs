---
title: "S2-04: UC-03 Put-away — chuyển staging→shelf thật"
labels: feat,module:warehouse,sprint:2,size:L
---

**Sprint:** 2 · **Size:** L · **Depends-on:** S2-03

## Bối cảnh
Sắp hàng từ shelf staging vào shelf thật. Bất biến: chỉ đổi lớp vị trí (`InventoryStock` từ shelf staging → shelf thật), `onHand` **không đổi** nên không sync Ecom; kích hoạt ngay khi GRN `CONFIRMED`. Theo [warehouse/use-cases.md UC-03](../../warehouse/use-cases.md).

## Phạm vi
- [ ] Sinh danh sách hàng cần put-away từ GRN vừa `CONFIRMED`.
- [ ] Quét barcode SKU → quét barcode shelf → nhập qty; khớp dòng GRN (sai item/qty lệch → cảnh báo).
- [ ] Tách 1 SKU ra nhiều shelf (quét nhiều shelf).
- [ ] Xác nhận → di chuyển `InventoryStock` staging→shelf trong transaction; `StockMovement` type `PUTAWAY`; `StockBalance.onHand` giữ nguyên.

## Acceptance criteria
- Put-away xong: `InventoryStock` không còn ở staging, xuất hiện ở shelf đích; `onHand` không đổi.
- Quét nhầm SKU hoặc qty vượt dòng GRN → cảnh báo, không ghi.

## Tham chiếu
- [warehouse/use-cases.md](../../warehouse/use-cases.md) UC-03.
- [db/03-nhap-kho.md](../../db/03-nhap-kho.md)
