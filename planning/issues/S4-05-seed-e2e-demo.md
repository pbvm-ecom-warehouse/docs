---
title: "S4-05: Seed data + E2E happy-path WMS + bug bash + demo"
labels: test,module:warehouse,sprint:4,size:L
---

**Sprint:** 4 · **Size:** L · **Depends-on:** S2-04, S3-01, S3-04

## Bối cảnh
Chốt chất lượng: kịch bản end-to-end chạy được từ seed, demo luồng WMS hoàn chỉnh. Đây là việc cuối, gom cả đội.

## Phạm vi
- [ ] Seed script: kho CENTRAL + zone/rack/shelf (có kích thước), vài WarehouseItem (MATERIAL/CUP_BLANK), 1 supplier + bảng giá, users mọi role.
- [ ] Test E2E happy-path: `login → tạo PO → GRN CONFIRMED (onHand tăng) → put-away (+ gợi ý) → xuất hàng (onHand giảm, goods.issued) → kiểm kê khớp`.
- [ ] Test bất biến: `onHand === Σ InventoryStock.quantity` sau toàn kịch bản; số dòng `StockMovement` khớp số thao tác.
- [ ] Bug bash buổi cuối; ghi `planning/demo-script.md` (kịch bản demo từng bước).

## Acceptance criteria
- Chạy 1 lệnh seed + 1 lệnh E2E → pass toàn kịch bản happy-path.
- Bất biến tồn 2 lớp không lệch sau kịch bản.
- Có demo-script chạy lại được.

## Tham chiếu
- [overview/main-flow.md](../../overview/main-flow.md) — luồng end-to-end (phần WMS P0→P4).
- [warehouse/workflow.md](../../warehouse/workflow.md)
