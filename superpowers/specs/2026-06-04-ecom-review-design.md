# Ecom Business Review — Spec sửa nhất quán & vá mạch event

> Ngày: 2026-06-04
> Phạm vi: rà soát lại nghiệp vụ **Ecommerce** (module Catalog + Order, mạch event với WMS). Sửa mâu thuẫn, vá đứt mạch, ghi nhận YAGNI.
> Trạng thái: ✅ Đã chốt (brainstorm) — chờ sinh plan triển khai sửa docs.

## Bối cảnh

Rà soát phần ecom phát hiện 3 nhóm vấn đề:

- **Sai/mâu thuẫn:** mô tả `order.placed` trong bảng event ([data-ownership.md](../../overview/data-ownership.md)) nói "WMS giữ tồn (reserved += qty)", ngược với mục "Chống oversell" (reserve atomic **trong transaction checkout** do app Ecommerce thực hiện) → nguy cơ hiểu là reserve 2 lần; chưa rõ ai trừ bản copy `availableQty`.
- **Thiếu:** không có event báo "in xong" (WMS→Ecom) để lật `AWAITING_PRINT → READY_TO_PICK`; không có event báo WMS "đến lúc xuất kho" để sinh `GoodsIssue`. Happy-path bị đứt ở 2 chỗ này.
- **Dư:** không đáng kể. RMA trên đơn `CLOSED` cần nói rõ trạng thái (không phải dư thật).

Các vùng đã biết thiếu (Shipping, Auth/Customer) vẫn theo [gap-analysis](../../overview/gap-analysis.md), không mở rộng ở spec này.

## Quyết định thiết kế

### QĐ-1: Reserve & sync `availableQty` — Ecom self-update in-transaction (Hướng B)

Reserve **không** đi qua event. Transaction checkout của app Ecommerce làm **3 việc atomic** (cùng MongoDB cluster nên 1 transaction xuyên 2 logical DB):

1. `wms_db.stock_balances`: kiểm `onHand − reserved ≥ qty` rồi `reserved += qty` (khóa document, ưu tiên kho `CENTRAL`).
2. `ecom_db.product_variants`: `availableQty −= qty` (Ecom tự trừ bản copy của chính mình).
3. `ecom_db.orders`: tạo `Order` + `OrderItem` (snapshot giá/địa chỉ), lưu `fulfillWarehouseId`.

→ commit cùng lúc; reserve fail (đua mua món cuối) → rollback toàn bộ, **không tạo đơn**.

**Hủy/release** (UC-E05, auto-cancel quá hạn) làm ngược lại **cũng in-transaction**: `reserved −= qty` (`wms_db`) + `availableQty += qty` (`ecom_db`) + `orderStatus = CANCELLED`.

**Hệ quả với `stock.changed`:** event này **KHÔNG** còn bắn cho "giữ hàng khi chốt đơn" và "hủy đơn" — vì Ecom đã tự cập nhật `availableQty`. `stock.changed` chỉ còn dùng cho biến động phía **WMS** (GRN, kiểm kho, chuyển kho, in-vào-kho-không-gắn-đơn, hoàn hàng). → `availableQty` có **2 đường cập nhật**, không trùng đếm:

- **Đường WMS-event:** biến động kho do WMS khởi xướng → `stock.changed`/`stock.expired` → Ecom `availableQty += delta`.
- **Đường self-update:** reserve/release lúc checkout/hủy do Ecom khởi xướng → cập nhật thẳng trong transaction, không event.

*Lý do chọn Hướng B:* tránh "tự bắn event cho chính mình" hoặc phải dựng change-stream watcher; gọn, đúng tinh thần "cùng cluster, không cần Saga".

### QĐ-2: `order.placed` là event thông báo thuần (KHÔNG reserve)

`order.placed` (Ecom→WMS) giữ lại nhưng **đổi nghĩa**: thông báo đơn đã đặt để WMS ghi nhận; **KHÔNG** reserve (tồn đã giữ atomic trong transaction checkout — QĐ-1). Trigger xuất kho là `order.ready_to_fulfill` (QĐ-3), không phải `order.placed`.

### QĐ-3: Thêm mạch event fulfillment 2 chiều (vá đứt mạch)

Thêm 2 event:

| Event | Chiều | Khi nào (trigger) | Hành động consumer |
|---|---|---|---|
| `print.completed` | WMS→Ecom | Một PrintJob của đơn in xong | Ecom set `OrderItem.printJobId`; kiểm "đã in xong **mọi** ly-in của đơn?" → nếu xong, lật `fulfillmentStatus: AWAITING_PRINT → READY_TO_PICK` |
| `order.ready_to_fulfill` | Ecom→WMS | Đơn vào `READY_TO_PICK` | WMS sinh `GoodsIssue` (UC-05), xuất từ `fulfillWarehouseId` |

`print.completed` mang `printJobId` để Ecom set `OrderItem.printJobId` (trước đây field này không có nguồn ghi).

**Trigger `READY_TO_PICK`** (→ phát `order.ready_to_fulfill`) theo nhánh:

- **COD:** ngay sau checkout (đơn `CONFIRMED`, không có ly-in).
- **Online không-in:** khi `payment.success` (đơn `CONFIRMED`, `hasPrintItems = false`).
- **Đơn ly-in (online):** sau khi nhận đủ `print.completed` cho **mọi** ly-in của đơn.

**Mạch khép kín đầy đủ (đơn ly-in):**

```
checkout (reserve in-transaction) → PLACED/UNPAID/NONE
  → payment.success → CONFIRMED/PAID → print.requested (Ecom→WMS)
  → WMS mở PrintJob (UC-04) → in xong
  → print.completed (WMS→Ecom) → đủ mọi ly-in? → READY_TO_PICK
  → order.ready_to_fulfill (Ecom→WMS) → WMS GoodsIssue (UC-05)
  → goods.issued (WMS→Ecom) → ISSUED → (Shipping) SHIPPED → DELIVERED → CLOSED
```

### QĐ-4: Khuyến mãi/voucher/discount — YAGNI deferred

Không mô hình hóa discount/voucher/khuyến mãi đợt này. `Order` giữ `subtotal/shippingFee/total`. Ghi nhận là gap hoãn trong [gap-analysis](../../overview/gap-analysis.md). `shippingFee` phụ thuộc module Shipping (Hạng 1) — checkout tạm chưa có nguồn tính phí ship cho tới khi Shipping xong.

### QĐ-5: RMA trên đơn `CLOSED` — ghi rõ trạng thái

RMA (UC-E06) xảy ra sau `DELIVERED`, lúc đó `orderStatus = CLOSED`. Làm rõ: RMA **không mở lại** `orderStatus`; chỉ chuyển `fulfillmentStatus → RETURNED` và đẩy `paymentStatus` theo luồng refund (`REFUND_PENDING → REFUNDED`) nếu hợp lệ. Đơn vẫn `CLOSED`.

## Ngoài phạm vi (YAGNI)

- Discount/voucher/khuyến mãi, thuế/VAT.
- RMA từng phần (partial return), partial fulfillment — giữ "xuất nguyên kiện".
- Guest checkout (giỏ vẫn bắt buộc `customerId`).
- Shipping & Auth/Customer — theo gap-analysis, module riêng.
- Split đa kho — giữ "1 kho/đơn".

## Danh sách file phải sửa (giữ nhất quán chéo)

1. [overview/data-ownership.md](../../overview/data-ownership.md)
   - Sửa mô tả `order.placed` → "thông báo thuần, KHÔNG reserve" (QĐ-2).
   - Bỏ "giữ hàng khi chốt đơn" và "hủy đơn" khỏi danh sách trigger `stock.changed` (QĐ-1).
   - Thêm `print.completed` (WMS→Ecom) và `order.ready_to_fulfill` (Ecom→WMS) vào bảng event (QĐ-3).
   - Mục "Sync tồn kho": ghi rõ `availableQty` có 2 đường cập nhật (WMS-event vs self-update in-transaction).
   - Mục "Chống oversell": ghi rõ transaction checkout cập nhật cả `availableQty` (việc ②).
2. [order/use-cases.md](../../order/use-cases.md)
   - UC-E02: nêu rõ transaction checkout self-update `availableQty`.
   - UC-E03/E04: thêm phát `order.ready_to_fulfill` khi vào `READY_TO_PICK`; xử lý nhận `print.completed`.
3. [order/workflow.md](../../order/workflow.md)
   - WF-E02: vẽ mạch `print.requested → print.completed → READY_TO_PICK → order.ready_to_fulfill`.
   - WF-E03: GoodsIssue được kích bởi `order.ready_to_fulfill`.
4. [order/data-model.md](../../order/data-model.md)
   - Ghi chú `OrderItem.printJobId` được set qua `print.completed`.
   - Nhóm 4 (3 trục): ghi rõ RMA không mở lại `orderStatus = CLOSED` (QĐ-5).
5. [catalog/data-model.md](../../catalog/data-model.md) & [catalog/use-cases.md](../../catalog/use-cases.md)
   - UC-C06 / Nhóm 4: ghi rõ availableQty 2 đường cập nhật (event + self-update reserve/release).
6. [overview/gap-analysis.md](../../overview/gap-analysis.md)
   - Ghi nhận discount/voucher YAGNI-deferred; shippingFee phụ thuộc Shipping.
7. [overview/main-flow.md](../../overview/main-flow.md)
   - Đối chiếu mạch event mới (P-print, P-ready-to-fulfill) cho khớp.

## Verify (không có build/test)

- Anchor & link `.md` phân giải đúng sau sửa: `grep -n "^## " <file>` và `grep -ohE '\]\(\.\.?/[^)#]+\.md' <file>`.
- Tên event/enum khớp giữa: data-ownership ↔ order (use-cases/workflow/data-model) ↔ catalog ↔ main-flow. Không còn chỗ nào mô tả `order.placed` reserve, không còn `stock.changed` cho reserve/cancel.
- Mạch fulfillment khép kín 3 nhánh (COD / online-không-in / ly-in) đọc nhất quán giữa use-cases ↔ workflow.
