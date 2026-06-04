# Shipping (WMS) — Use Cases

> Trạng thái: 🔄 Đang phân tích

## Tổng quan

| # | Tên | Actor | Trạng thái |
|---|---|---|---|
| UC-S01 | Quản lý đơn vị vận chuyển | MANAGER | 🔄 Đang phân tích |
| UC-S02 | Tạo & gán vận đơn | SHIPPER | 🔄 Đang phân tích |
| UC-S03 | Cập nhật trạng thái giao | SHIPPER | 🔄 Đang phân tích |
| UC-S04 | Xử lý giao thất bại & hoàn về | SHIPPER + RECEIVER | 🔄 Đang phân tích |
| UC-S05 | Tra cứu vận đơn | SHIPPER | 🔄 Đang phân tích |

---

## UC-S01: Quản lý đơn vị vận chuyển

**Actor:** MANAGER  
**Mục đích:** Duy trì danh mục hãng vận chuyển (`carriers`) — thêm mới, cập nhật thông tin, kích hoạt/vô hiệu hóa

### Luồng chính

1. MANAGER tạo hãng mới — nhập `name`, `code` (duy nhất), `contactInfo`, `note`; trạng thái mặc định `ACTIVE`
2. MANAGER cập nhật thông tin hãng (tên, đầu mối liên hệ, ghi chú)
3. MANAGER đặt trạng thái `ACTIVE` / `INACTIVE` — **không xóa cứng** nếu hãng đã từng được gán cho vận đơn; chuyển sang `INACTIVE` thay vì xóa để giữ lịch sử đối soát
4. Hãng `INACTIVE` không hiển thị trong danh sách chọn khi tạo vận đơn mới

### Trạng thái Carrier

| Status | Mô tả |
|---|---|
| `ACTIVE` | Đang hoạt động, có thể gán cho vận đơn mới |
| `INACTIVE` | Ngừng hợp tác; giữ nguyên dữ liệu để đối soát lịch sử |

---

## UC-S02: Tạo & gán vận đơn

**Actor:** SHIPPER  
**Trigger:** WMS hoàn tất xuất kho (UC-05) → phát sự kiện `goods.issued` → hệ thống **tự động sinh** `Shipment{PENDING}` 1:1 với GoodsIssue

### Luồng chính

1. Hệ thống nhận `goods.issued` → tạo bản ghi `Shipment` với `shipmentStatus = PENDING`; copy `recipient`, `paymentMethod`, `codAmount` từ payload `order.ready_to_fulfill` đã lưu trong GoodsIssue
2. SHIPPER mở danh sách vận đơn `PENDING` → chọn vận đơn cần xử lý
3. SHIPPER chọn hãng vận chuyển (`carrierId`) từ danh sách hãng `ACTIVE`
4. SHIPPER nhập `trackingNumber` (mã vận đơn do hãng cấp)
5. Hệ thống lưu thông tin — vận đơn sẵn sàng bàn giao hãng

> **1 đơn = 1 vận đơn:** đơn xuất nguyên kiện, không tách giao từng phần. Mỗi `GoodsIssue` sinh đúng 1 `Shipment`.

---

## UC-S03: Cập nhật trạng thái giao

**Actor:** SHIPPER  
**Mục đích:** Phản ánh tiến trình giao hàng thực tế — mỗi lần đổi trạng thái ghi thêm một dòng vào `statusHistory`

### Luồng chính

1. Hãng đến lấy hàng tại kho → SHIPPER cập nhật `PICKED_UP`; hệ thống ghi `statusHistory`
2. Hàng rời kho, bàn giao cho hãng → SHIPPER cập nhật `IN_TRANSIT`
   - Hệ thống phát `shipment.shipped` → Ecommerce cập nhật `fulfillmentStatus = SHIPPED`
   - Ghi `shippedAt`
3. Hàng giao thành công → SHIPPER (hoặc hệ thống nhận phản hồi hãng) cập nhật `DELIVERED`
   - Hệ thống phát `shipment.delivered` → Ecommerce cập nhật `fulfillmentStatus = DELIVERED`, `orderStatus = CLOSED`
   - Đơn **COD**: Ecommerce đổi `paymentStatus = PAID` (tiền thu hộ được ghi nhận)
   - Đơn **ONLINE**: `paymentStatus` giữ nguyên `PAID` (đã thanh toán trước)
   - Ghi `deliveredAt`

### Luồng trạng thái

```
PENDING → PICKED_UP → IN_TRANSIT → DELIVERED
                                ↘ (thất bại → UC-S04)
```

---

## UC-S04: Xử lý giao thất bại & hoàn về

**Actor:** SHIPPER (cập nhật vận đơn), RECEIVER (nhập lại hàng tại kho)  
**Trigger:** Giao thất bại — khách vắng nhà, sai địa chỉ, từ chối nhận

### Luồng chính — Giao thất bại & retry

1. Hãng báo giao không được → SHIPPER cập nhật `FAILED`; nhập `failReason`; hệ thống tăng `attempts`
2. **Có thể retry:** SHIPPER lên lịch giao lại → cập nhật lại `IN_TRANSIT`; quay lại UC-S03 bước 3
3. Mỗi lần đổi trạng thái đều ghi thêm dòng vào `statusHistory`

### Luồng chính — Bỏ cuộc & hoàn về kho

4. Hết số lần retry hoặc khách từ chối hẳn → SHIPPER đánh dấu `RETURNING`; hàng trên đường về kho
5. Hàng về đến kho → SHIPPER xác nhận → `RETURNED`
   - Hệ thống phát `shipment.returned` → Ecommerce cập nhật: `fulfillmentStatus = RETURNED`, `orderStatus = CANCELLED`
   - Đơn **ONLINE**: Ecommerce đổi `paymentStatus = REFUND_PENDING` (cần hoàn tiền cho khách)
   - Đơn **COD**: không thu được tiền, không cần hoàn

### Nhập lại hàng vật lý (bàn giao cho kho)

6. RECEIVER tiếp nhận hàng hoàn về — xử lý qua **[warehouse UC-09](../warehouse/use-cases.md#uc-09-hoàn-hàng-return--rma)**:
   - Hàng **còn tốt** → nhập lại kho (`StockBalance.onHand +=`; `available` tăng → sync Ecommerce)
   - Hàng **hỏng** → chuyển sang UC-08 Scrap (không nhập kho)

> **Return-to-sender ≠ RMA:** vận đơn `RETURNING → RETURNED` là hàng chưa từng giao được (`orderStatus = CANCELLED`). Khác với RMA-sau-DELIVERED — trường hợp đó đơn giữ nguyên `CLOSED` (xem [order/data-model](../order/data-model.md)).

---

## UC-S05: Tra cứu vận đơn

**Actor:** SHIPPER  
**Mục đích:** Tìm kiếm, lọc và xem chi tiết vận đơn để xử lý công việc hàng ngày

### Luồng chính

1. SHIPPER truy cập danh sách vận đơn
2. Lọc theo một hoặc nhiều tiêu chí:
   - **Trạng thái** (`shipmentStatus`): PENDING / PICKED_UP / IN_TRANSIT / DELIVERED / FAILED / RETURNING / RETURNED
   - **Đơn hàng** (`orderId`): tra theo mã đơn Ecommerce
   - **Hãng vận chuyển** (`carrierId`): lọc theo hãng
3. Xem chi tiết vận đơn: thông tin người nhận, mã tracking, lịch sử trạng thái (`statusHistory`), số lần thử (`attempts`), lý do thất bại
4. Xuất danh sách nếu cần đối soát nội bộ

> **Tra cứu phía khách hàng** (tracking đơn theo link hoặc mã vận đơn) thuộc Ecommerce — nằm ngoài phạm vi module Shipping WMS.
