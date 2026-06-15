---
title: "S1-05: (docs) Viết module Notification"
labels: docs,module:notification,sprint:1,size:M
---

**Sprint:** 1 · **Size:** M · **Depends-on:** —

## Bối cảnh
Track docs song song. App `notification` (:3003) đã nêu trong [system-context](../../overview/system-context.md#các-ứng-dụng) nhưng thiếu docs (xem [gap-analysis Hạng 4](../../overview/gap-analysis.md)). Tập trung phần phục vụ WMS trước (`stock.low`, `stock.near_expiry`).

## Phạm vi
- [ ] Tạo bộ 3 file `notification/use-cases.md` + `data-model.md` + `workflow.md`.
- [ ] Mô tả consumer các event: `stock.low`, `stock.near_expiry` (+ ghi nhận `payment.success`, `goods.issued` cho sau).
- [ ] Template theo kênh (email/sms/push), cơ chế retry + idempotent.
- [ ] Cập nhật [README.md](../../README.md) (bảng module) + [data-ownership.md](../../overview/data-ownership.md) (collection mới nếu có).

## Acceptance criteria
- 3 file tạo xong, link & anchor phân giải đúng.
- Tên event khớp [data-ownership.md](../../overview/data-ownership.md).
- gap-analysis Hạng 4 cập nhật trạng thái.

## Tham chiếu
- [overview/gap-analysis.md](../../overview/gap-analysis.md) §4 Notification.
- [overview/data-ownership.md](../../overview/data-ownership.md) — các event đồng bộ.
