---
title: "S2-06: Hạ tầng event BullMQ/Redis + phát stock.changed"
labels: infra,module:warehouse,sprint:2,size:M
---

**Sprint:** 2 · **Size:** M · **Depends-on:** S1-04

## Bối cảnh
Giao tiếp bất đồng bộ giữa app qua event (BullMQ + Redis). WMS là nguồn chân lý tồn → phát `stock.changed` để (sau này) Ecom sync `availableQty`. Trong 4 tuần chỉ **phát**, chưa có consumer Ecom. Theo [overview/system-context.md](../../overview/system-context.md) + [data-ownership.md](../../overview/data-ownership.md).

## Phạm vi
- [ ] Cấu hình BullMQ + Redis trong `libs/common` (kết nối, queue name chuẩn).
- [ ] `EventPublisher` service phát event với payload chuẩn (sku, delta, warehouseId, available, timestamp).
- [ ] Gắn publisher vào `applyStockChange` (S1-04): mọi biến động `onHand`/`available` phát `stock.changed`.
- [ ] Định nghĩa hằng tên event trong `libs/shared-types` khớp [data-ownership.md](../../overview/data-ownership.md) (`stock.changed`, dự phòng `stock.expired`).
- [ ] Idempotency key cho event.

## Acceptance criteria
- Cộng/trừ tồn → có job `stock.changed` trên queue Redis với payload đúng.
- Tên event/queue khớp định danh trong data-ownership.

## Tham chiếu
- [overview/system-context.md](../../overview/system-context.md) — BullMQ/Redis.
- [overview/data-ownership.md](../../overview/data-ownership.md) — các event đồng bộ WMS↔Ecom.
