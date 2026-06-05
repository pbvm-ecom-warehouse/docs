# Order (Ecommerce) — Use Cases

## Tổng quan

| # | Tên | Actor | Trạng thái |
|---|---|---|---|
| UC-E01 | Quản lý giỏ hàng | Khách | 🔄 Đang phân tích |
| UC-E02 | Checkout & đặt hàng | Khách | 🔄 Đang phân tích |
| UC-E03 | Thanh toán (COD/online) | Khách + cổng TT | 🔄 Đang phân tích |
| UC-E04 | Theo dõi & fulfillment đơn | Khách + Hệ thống | 🔄 Đang phân tích |
| UC-E05 | Hủy đơn | Khách | 🔄 Đang phân tích |
| UC-E06 | Hoàn hàng (RMA) | Khách | 🔄 Đang phân tích |

---

## UC-E01: Quản lý giỏ hàng

**Actor:** Khách (đã đăng nhập)
**Mục đích:** Thêm/sửa/xóa món trước khi đặt; chưa giữ tồn.

### Luồng chính
1. Khách thêm SKU vào giỏ (nhập số lượng; ly-in → chọn/đính kèm `designFile`, đặt `isPrintItem = true`)
2. Hệ hiển thị `availableQty` (bản copy WMS sync) để cảnh báo nếu thiếu — **không giữ tồn** ở bước này
3. Sửa số lượng / xóa món → cập nhật giỏ

---

## UC-E02: Checkout & đặt hàng

**Actor:** Khách
**Mục đích:** Chốt đơn, **giữ tồn atomic**, tạo Order.

### Luồng chính
1. Khách chọn địa chỉ giao + phương thức thanh toán (`COD`/`ONLINE`)
2. **Chặn:** đơn có ly-in (`hasPrintItems`) mà chọn `COD` → từ chối, bắt chuyển `ONLINE` (make-to-order phải trả trước)
3. `validateStock` sơ bộ theo `availableQty`
4. Hệ chọn kho có `available ≥ qty` (ưu tiên `CENTRAL`) → **transaction atomic xuyên 2 DB**: `reserved += qty` trên `wms_db.stock_balances` + `availableQty −= qty` trên `ecom_db.product_variants` (Ecom tự trừ bản copy, không qua event); lưu `fulfillWarehouseId`
5. Tạo `Order{orderStatus: PLACED, paymentStatus: UNPAID, fulfillmentStatus: NONE}` + snapshot giá/địa chỉ; phát `order.placed` (**thông báo thuần** — tồn đã giữ trong transaction, WMS không reserve lại)
6. Chưa ghi sổ tiền lúc này — `payment_transactions` chỉ append khi có biến động thật (CHARGE lúc trả online / COD_COLLECT lúc giao)
7. Reserve fail (đua mua món cuối) → rollback, **không tạo đơn**, báo hết hàng

---

## UC-E03: Thanh toán (COD/online)

**Actor:** Khách + cổng thanh toán
**Mục đích:** Xác nhận đơn; mở lệnh in cho ly-in.

### Luồng chính — ONLINE
1. Khách chuyển sang cổng (VNPay/Momo) trả `total`
2. Cổng gọi webhook → xử lý **idempotent** theo `providerTxnId` → append `payment_transactions{type: CHARGE, status: SUCCESS}` → recompute `Order.paymentStatus = PAID` (trả lỗi → append `CHARGE/FAILED`, không đổi trạng thái)
3. `orderStatus → CONFIRMED`
4. Nếu `hasPrintItems` → phát `print.requested` (WMS mở PrintJob/UC-04) → `fulfillmentStatus = AWAITING_PRINT`; ngược lại → `READY_TO_PICK` → phát `order.ready_to_fulfill` (WMS sinh GoodsIssue)
5. Quá `paymentDeadline` chưa `PAID` (mặc định ~30 phút, cấu hình được) → tự phát `order.cancelled` (release reserve) → `orderStatus = CANCELLED`. Bao trùm cả case khách trả lỗi/bỏ dở giữa chừng.

### Luồng chính — COD
1. Đơn chỉ gồm hàng sẵn (ly-in đã bị chặn ở UC-E02)
2. `orderStatus → CONFIRMED` ngay sau đặt; `fulfillmentStatus = READY_TO_PICK` → phát `order.ready_to_fulfill` (WMS sinh GoodsIssue)
3. `paymentStatus` giữ `UNPAID` đến khi `DELIVERED`: consumer `shipment.delivered` append `payment_transactions{type: COD_COLLECT, status: SUCCESS}` → recompute `PAID`

---

## UC-E04: Theo dõi & fulfillment đơn

**Actor:** Khách (xem) + Hệ thống
### Luồng chính
1. **Đơn ly-in:** WMS in xong → phát `print.completed` (mang `printJobId`) → Ecom set `OrderItem.printJobId`; khi **mọi** ly-in của đơn đã in xong → `fulfillmentStatus: AWAITING_PRINT → READY_TO_PICK`
2. `READY_TO_PICK` → phát `order.ready_to_fulfill` → WMS sinh GoodsIssue (UC-05), xuất kho từ `fulfillWarehouseId`
3. `goods.issued` (WMS→Ecom) → `fulfillmentStatus = ISSUED`
4. Shipping (module sau) → `SHIPPED` → `DELIVERED`
5. `DELIVERED`: nếu COD → `paymentStatus = PAID`; `orderStatus = CLOSED`
6. Khách tra cứu trạng thái đơn theo 3 trục

---

## UC-E05: Hủy đơn

**Actor:** Khách
**Mục đích:** Hủy trước khi xuất kho, trả tồn.

### Luồng chính
1. Khách yêu cầu hủy khi `fulfillmentStatus` **chưa tới `ISSUED`**
2. **Ly-in:** chỉ hủy được **trước khi mở PrintJob** (trước `AWAITING_PRINT`); đã in → từ chối (hàng custom)
3. Phát `order.cancelled` → WMS release reserve → `orderStatus = CANCELLED`
4. ONLINE đã `PAID` → `paymentStatus = REFUND_PENDING` → hoàn tiền → `REFUNDED`
5. Đã `ISSUED` rồi → không hủy, dùng UC-E06 (RMA)

---

## UC-E06: Hoàn hàng (RMA)

**Actor:** Khách
**Trigger:** Sau `DELIVERED`, trong hạn đổi trả (mặc định 7 ngày, cấu hình được)

### Luồng chính
1. Khách tạo yêu cầu hoàn → phát `order.returned` (Ecom→WMS)
2. WMS xử lý [UC-09 Hoàn hàng](../warehouse/use-cases.md#uc-09-hoàn-hàng-return--rma): hàng tốt nhập lại, hàng hỏng scrap
3. `fulfillmentStatus = RETURNED`; hoàn tiền nếu hợp lệ
4. **Ly-in custom không nhận hoàn trừ khi lỗi/hỏng**
