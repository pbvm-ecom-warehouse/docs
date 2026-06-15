---
title: "S4-04: Notification consumer (stock.low, stock.near_expiry)"
labels: feat,module:notification,sprint:4,size:M
---

**Sprint:** 4 · **Size:** M · **Depends-on:** S1-05

## Bối cảnh
Hiện thực consumer theo docs Notification (S1-05). Phạm vi WMS: cảnh báo tồn thấp & sắp hết hạn cho MANAGER. Theo [gap-analysis Hạng 4](../../overview/gap-analysis.md).

## Phạm vi
- [ ] Scaffold app/worker `notification` (hoặc module trong monorepo) consume BullMQ.
- [ ] Phát `stock.low` khi `available` xuống dưới ngưỡng (ngưỡng cấu hình theo SKU); `stock.near_expiry` cho lô gần `expiryDate`.
- [ ] Consumer gửi thông báo (email/log stub) — idempotent, retry.

## Acceptance criteria
- Tồn xuống dưới ngưỡng → phát `stock.low`, consumer nhận đúng 1 lần (idempotent khi retry).
- Lô gần hết hạn → phát `stock.near_expiry`.

## Tham chiếu
- [overview/gap-analysis.md](../../overview/gap-analysis.md) §4 Notification.
- [overview/data-ownership.md](../../overview/data-ownership.md) — event.
