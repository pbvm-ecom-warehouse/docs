---
title: "S3-02: UC-04 In ly make-to-order (CUP_BLANK→CUP_PRINTED)"
labels: feat,module:warehouse,sprint:3,size:L
---

**Sprint:** 3 · **Size:** L · **Depends-on:** S1-04

## Bối cảnh
Lệnh in ly theo đơn. Bất biến: mỗi mẫu in = 1 SKU `CUP_PRINTED` riêng (per-design); chuỗi hold: tạo `PrintJob` giữ `CUP_BLANK` → in xong **chuyển** sang `CUP_PRINTED` cho đúng đơn. Theo [warehouse/use-cases.md UC-04](../../warehouse/use-cases.md).

## Phạm vi
- [ ] Schema `PrintJob` (đơn, mẫu in/design, sku `CUP_PRINTED` đích, sku `CUP_BLANK` nguồn, qty, trạng thái).
- [ ] Tạo PrintJob (MANAGER) → **hold** (reserve) `CUP_BLANK` qty tương ứng.
- [ ] PRINTER xác nhận in xong → chuyển tồn: trừ `CUP_BLANK`, cộng `CUP_PRINTED` (2 lớp + `StockMovement`), giải phóng hold.
- [ ] Sinh/in tem barcode cho `CUP_PRINTED`.

## Acceptance criteria
- Tạo PrintJob → `CUP_BLANK.reserved` tăng đúng qty.
- In xong → `CUP_BLANK.onHand` giảm, `CUP_PRINTED.onHand` tăng cùng qty; có 2 `StockMovement` (CONVERT_OUT/CONVERT_IN).
- Mỗi design có SKU `CUP_PRINTED` riêng.

## Tham chiếu
- [warehouse/use-cases.md](../../warehouse/use-cases.md) UC-04.
- [db/04-in-ly.md](../../db/04-in-ly.md)
