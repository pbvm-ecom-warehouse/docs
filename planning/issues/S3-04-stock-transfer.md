---
title: "S3-04: UC-07 Chuyển kho (Stock Transfer)"
labels: feat,module:warehouse,sprint:3,size:L
---

**Sprint:** 3 · **Size:** L · **Depends-on:** S3-01

## Bối cảnh
Chuyển hàng giữa 2 kho (vd gom về CENTRAL trước khi xuất — vì phân bổ 1 kho/đơn, không split). Xuất kho nguồn (PICKER) → nhận kho đích (RECEIVER); giữ nhất quán 2 lớp ở cả hai kho. Theo [warehouse/use-cases.md UC-07](../../warehouse/use-cases.md).

## Phạm vi
- [ ] Schema `StockTransfer` (kho nguồn, kho đích, dòng sku/qty/lô, trạng thái `CREATED`/`ISSUED`/`RECEIVED`).
- [ ] PICKER xuất kho nguồn: `applyStockChange(−)` ở kho nguồn (`StockMovement` `TRANSFER_OUT`), hàng ở trạng thái in-transit.
- [ ] RECEIVER nhận kho đích: `applyStockChange(+)` ở kho đích (`StockMovement` `TRANSFER_IN`) + put-away vào shelf.
- [ ] Quét barcode ở cả 2 đầu; giữ lô/expiry xuyên suốt.

## Acceptance criteria
- Sau chuyển hoàn tất: `onHand` kho nguồn giảm, kho đích tăng cùng qty; tổng tồn 2 kho không đổi.
- Lô/expiry của hàng perishable giữ nguyên ở kho đích.
- Có cặp `StockMovement` `TRANSFER_OUT`/`TRANSFER_IN`.

## Tham chiếu
- [warehouse/use-cases.md](../../warehouse/use-cases.md) UC-07.
- [db/05-xuat-kho-va-noi-bo.md](../../db/05-xuat-kho-va-noi-bo.md)
