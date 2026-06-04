# Order (Ecommerce) — Workflow

> Trạng thái: 🔄 Đang phân tích

## Luồng tổng quan

```
Giỏ → [WF-E01 Checkout+reserve] → [WF-E02 Thanh toán] → Kho (WMS xuất)
                                                              ↓
Khách  ←  [WF-E03 Giao hàng]  ←  ISSUED/SHIPPED/DELIVERED
   ↑
[WF-E04 Hủy] (trước xuất kho)    [WF-E05 RMA] (sau giao)
```

> **3 trục trạng thái:** mỗi sơ đồ ghi rõ trục nào đổi: payment / order / fulfillment.

---

## WF-E01: Checkout & giữ tồn

```
KHÁCH                     CHECKOUT                  WMS (stock_balances)
  |                          |                           |
  |-- Chọn địa chỉ + PTTT -->|                           |
  |   (COD/ONLINE)           |                           |
  |                    Chặn: ly-in + COD → từ chối        |
  |                          |-- validateStock (copy) -->|
  |                          |-- reserve ATOMIC (txn) -->| reserved += qty (wms_db)
  |                          |   availableQty −= qty (ecom_db, cùng txn)  (khóa document)
  |                          |<-- OK / hết hàng ---------|
  |                    Tạo Order{PLACED, UNPAID, NONE}    |
  |                    fulfillWarehouseId; order.placed (thông báo thuần)

  |                    Khởi tạo Payment                   |
  |<-- Đơn đã tạo -----------|                           |
```
> Reserve fail → rollback, không tạo đơn.

---

## WF-E02: Thanh toán & xác nhận

```
KHÁCH                  PAYMENT / ORDER             WMS
  |                          |                       |
  | [ONLINE]                 |                       |
  |-- Trả qua cổng --------->|                       |
  |                    Webhook (idempotent txnId)    |
  |                    paymentStatus → PAID           |
  |                    orderStatus → CONFIRMED        |
  |                    Có ly-in? --yes--> print.requested -->| mở PrintJob (UC-04)
  |                    fulfillment → AWAITING_PRINT   |
  |                    <-- print.completed (đủ mọi ly-in) ---| in xong
  |                    fulfillment → READY_TO_PICK    |
  |                    Có ly-in? --no--> READY_TO_PICK|
  |                    READY_TO_PICK → order.ready_to_fulfill -->| (WMS sinh GoodsIssue)
  |                          |                       |
  | [COD]                    |                       |
  |-- Đặt (hàng sẵn) ------->|                       |
  |                    orderStatus → CONFIRMED        |
  |                    fulfillment → READY_TO_PICK → order.ready_to_fulfill -->| (WMS sinh GoodsIssue)
  |                          |                       |
  | [Quá paymentDeadline chưa PAID] → order.cancelled → release reserve → CANCELLED
```

---

## WF-E03: Giao hàng

```
WMS / SHIPPING           ORDER                     
  |                        |                          
  |<-- order.ready_to_fulfill (READY_TO_PICK) --|     
  | GoodsIssue (UC-05)     |                          
  |-- goods.issued ------->| fulfillment → ISSUED     
  | auto sinh Shipment{PENDING}; gán carrier+tracking 
  |-- shipment.shipped --->| fulfillment → SHIPPED    
  |-- shipment.delivered ->| fulfillment → DELIVERED  
  |                        | COD → paymentStatus = PAID
  |                        | orderStatus → CLOSED     
  |  [giao thất bại hẳn]   |                          
  |-- shipment.returned -->| fulfillment → RETURNED   
  |                        | orderStatus → CANCELLED  
  |                        | ONLINE → REFUND_PENDING  
```
> Chi tiết vòng đời vận đơn & xử lý giao thất bại: [shipping/workflow.md](../shipping/workflow.md#wf-s01-vòng-đời-vận-đơn-happy-path).

---

## WF-E04: Hủy đơn (trước xuất kho)

```
KHÁCH                     ORDER                     WMS
  |                          |                        |
  |-- Yêu cầu hủy ---------->|                        |
  |                    fulfillment < ISSUED?           |
  |                    ly-in: trước AWAITING_PRINT?    |
  |                    Nếu hợp lệ:                     |
  |                          |-- order.cancelled ----->| release reserve
  |                    orderStatus → CANCELLED         |
  |                    ONLINE đã PAID → REFUND_PENDING → REFUNDED
  |<-- Đã hủy / hoàn tiền ---|                        |
```
> Đã `ISSUED` → từ chối hủy, hướng dẫn dùng RMA (WF-E05).

---

## WF-E05: Hoàn hàng (RMA)

```
KHÁCH                     ORDER                     WMS
  |                          |                        |
  |-- Yêu cầu hoàn --------->| (trong hạn 7 ngày)     |
  |   (sau DELIVERED)        |-- order.returned ----->| UC-09: tốt→nhập lại / hỏng→scrap
  |                    fulfillment → RETURNED          |
  |                    Hoàn tiền nếu hợp lệ            |
  |<-- Kết quả --------------|                        |
```
> Ly-in custom không nhận hoàn trừ khi lỗi/hỏng.
