---
title: "S2-05: Thuật toán gợi ý vị trí put-away"
labels: feat,module:warehouse,sprint:2,size:M
---

**Sprint:** 2 · **Size:** M · **Depends-on:** S2-04

## Bối cảnh
Gợi ý vị trí (advisory) cho put-away theo thể tích — best-fit + ràng buộc lọt 3 chiều. Mô tả thuật toán đầy đủ ở [warehouse/workflow.md WF-01](../../warehouse/workflow.md) (mục "Gợi ý vị trí put-away"). Gợi ý **không cưỡng chế** — RECEIVER vẫn quét xác nhận, được đặt khác.

## Phạm vi
Với item `I` (đã khai `unitVolume`, kích thước), số lượng `Q`, kho `W` — duyệt mọi shelf non-staging đã khai kích thước:
- [ ] **Ràng buộc 3 chiều (cho xoay 90°):** sắp giảm dần 3 chiều của `I` và shelf; yêu cầu `I[i] ≤ shelf[i]` mọi chiều, trượt thì loại.
- [ ] **Đã chiếm** = `Σ (quantity × unitVolume)` mọi `InventoryStock` trên shelf (mọi SKU & lô) — tính động từ tồn thật.
- [ ] **Còn trống** = `usableVolume × fillFactor − đã chiếm`; **sức chứa** = `floor(còn trống ÷ I.unitVolume)`.
- [ ] **Xếp hạng:** ưu tiên shelf đã chứa cùng SKU (đủ `Q`) → rồi best-fit (còn trống nhỏ nhất mà đủ `Q`); không shelf đơn nào đủ → gợi ý tổ hợp nhiều shelf.
- [ ] `GET /putaway/suggestions?sku=&qty=&warehouseId=` → `[{shelf, capacity}]`.
- [ ] Item/shelf chưa khai kích thước → bỏ qua gợi ý; hàng vượt mọi shelf → cảnh báo.

## Acceptance criteria
- Hàng quá to không lọt tầng → shelf đó bị loại khỏi kết quả.
- Có shelf đã chứa cùng SKU & đủ chỗ → xếp hạng đầu.
- Không shelf đơn đủ `Q` → trả tổ hợp nhiều shelf (vd `A:30, B:20`).

## Tham chiếu
- [warehouse/workflow.md](../../warehouse/workflow.md) WF-01 — định nghĩa thuật toán (nguồn chuẩn).
- [superpowers/specs/2026-06-08-shelf-putaway-recommendation-design.md](../../superpowers/specs/2026-06-08-shelf-putaway-recommendation-design.md)
- [superpowers/plans/2026-06-08-shelf-putaway-recommendation.md](../../superpowers/plans/2026-06-08-shelf-putaway-recommendation.md)
