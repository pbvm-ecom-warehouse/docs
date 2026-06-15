---
title: "S2-02: UC-01 Purchase Order"
labels: feat,module:warehouse,sprint:2,size:M
---

**Sprint:** 2 · **Size:** M · **Depends-on:** S2-01

## Bối cảnh
Tạo phiếu đặt mua (PO) — đầu luồng nhập, theo [warehouse/use-cases.md UC-01](../../warehouse/use-cases.md).

## Phạm vi
- [ ] Schema `PurchaseOrder` + dòng `items[]` (sku, qty, đơn giá) + enum trạng thái (`DRAFT`/`ORDERED`/`PARTIALLY_RECEIVED`/`COMPLETED`/`CANCELLED`).
- [ ] `POST /purchase-orders` (guard `@Roles('MANAGER')`); gợi ý giá từ `SupplierItem`; chặn NCC blacklist.
- [ ] Cập nhật trạng thái PO theo lượng đã nhận (sẽ do GRN gọi ở S2-03).

## Acceptance criteria
- Tạo PO với NCC hợp lệ → trạng thái `ORDERED`; với NCC blacklist → bị từ chối.
- Đơn giá để trống → tự điền từ bảng giá NCC.

## Tham chiếu
- [warehouse/use-cases.md](../../warehouse/use-cases.md) UC-01.
- [db/03-nhap-kho.md](../../db/03-nhap-kho.md)
