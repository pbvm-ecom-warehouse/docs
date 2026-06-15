---
title: "S4-03: Module Report — tồn & hiệu suất kho (read-only)"
labels: feat,module:report,sprint:4,size:L
---

**Sprint:** 4 · **Size:** L · **Depends-on:** S1-04

## Bối cảnh
Báo cáo đọc-only từ collection sẵn có (`stock_balances`, `inventory_stocks`, `stock_movements`). Phạm vi WMS: tồn + hiệu suất nhập/xuất/kiểm (doanh thu/đơn hàng cần Order → ngoài phạm vi). Theo [gap-analysis Hạng 5](../../overview/gap-analysis.md).

## Phạm vi
- [ ] Báo cáo tồn theo SKU / theo kho / theo lô (kèm hàng sắp/đã hết hạn).
- [ ] Báo cáo hiệu suất: số lượng nhập/xuất/điều chỉnh theo khoảng thời gian (đọc `stock_movements`).
- [ ] Endpoint read-only, guard `@Roles('MANAGER','ADMIN')`, hỗ trợ filter (kho, SKU, khoảng ngày).

## Acceptance criteria
- Báo cáo tồn theo SKU trả số khớp `Σ InventoryStock` và `StockBalance.onHand`.
- Báo cáo hiệu suất khớp đếm trên `stock_movements` trong khoảng ngày.

## Tham chiếu
- [overview/gap-analysis.md](../../overview/gap-analysis.md) §5 Report.
- [db/02-hang-hoa-va-ton-kho.md](../../db/02-hang-hoa-va-ton-kho.md)
