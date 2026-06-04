# Order (Ecommerce) — Data Model

> Trạng thái: 🔄 Đang phân tích — theo spec [2026-06-04-ecommerce-order-module-design](../superpowers/specs/2026-06-04-ecommerce-order-module-design.md)

> **Ownership:** Ecommerce sở hữu `carts`/`orders`/`payments`/`customers`. Liên kết WMS **chỉ qua `sku`** + `printJobId`/`fulfillWarehouseId` — không đọc chéo collection. Xem [data-ownership](../overview/data-ownership.md).

## Nhóm 1: Giỏ hàng

### Cart (1 giỏ ACTIVE / khách)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| customerId | ObjectId | Bắt buộc (đã đăng nhập) |
| status | Enum | `ACTIVE` / `CONVERTED` / `ABANDONED` |
| updatedAt | DateTime | |

### CartItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| cartId | ObjectId | |
| sku | String | Liên kết WMS/catalog |
| quantity | Number | |
| isPrintItem | Boolean | Là ly-in (make-to-order)? |
| designFile | String | File design (chỉ khi `isPrintItem`) |

> Giỏ **chưa giữ tồn** — chỉ đọc `availableQty` (bản copy WMS sync) để hiển thị/cảnh báo. Giữ tồn thật xảy ra ở checkout.

## Nhóm 2: Đơn hàng

### Order

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| code | String | Mã đơn hiển thị (unique) |
| customerId | ObjectId | Bắt buộc |
| shippingAddress | Object | **Snapshot** tên/SĐT/địa chỉ lúc đặt |
| subtotal | Number | Tiền hàng (snapshot) |
| shippingFee | Number | |
| total | Number | |
| paymentMethod | Enum | `COD` / `ONLINE` |
| paymentStatus | Enum | `UNPAID` / `PAID` / `REFUND_PENDING` / `REFUNDED` |
| orderStatus | Enum | `PLACED` / `CONFIRMED` / `CANCELLED` / `CLOSED` |
| fulfillmentStatus | Enum | `NONE` / `AWAITING_PRINT` / `READY_TO_PICK` / `ISSUED` / `SHIPPED` / `DELIVERED` / `RETURNED` |
| fulfillWarehouseId | ObjectId | Kho WMS đã giữ tồn (1 kho/đơn, ưu tiên CENTRAL) |
| hasPrintItems | Boolean | Có ly-in → gate trả-trước |
| paymentDeadline | DateTime | Hạn trả online; quá hạn chưa `PAID` → tự hủy |
| cancelReason | String | |
| placedAt | DateTime | |
| updatedAt | DateTime | |

### OrderItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| orderId | ObjectId | |
| sku | String | |
| name | String | Snapshot tên lúc đặt |
| unitPrice | Number | Snapshot giá lúc đặt |
| quantity | Number | |
| isPrintItem | Boolean | |
| designFile | String | (khi `isPrintItem`) |
| printJobId | ObjectId | Tham chiếu PrintJob bên WMS (khi đã mở lệnh in) |

## Nhóm 3: Thanh toán

### Payment

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| orderId | ObjectId | |
| method | Enum | `COD` / `ONLINE` |
| provider | String | VNPay / Momo... (null nếu COD) |
| amount | Number | |
| status | Enum | `INIT` / `SUCCESS` / `FAILED` / `REFUNDED` |
| providerTxnId | String | Mã giao dịch cổng — **khóa idempotency** webhook |
| paidAt | DateTime | |
| raw | Object | Payload webhook (lưu đối soát) |

## Nhóm 4: Ba trục trạng thái

> Trạng thái đơn tách **3 trục độc lập** để tránh state lai (COD/online × make-to-order):

| Trục | Giá trị | Nguồn chuyển |
|---|---|---|
| `paymentStatus` | UNPAID → PAID → REFUND_PENDING → REFUNDED | ONLINE: `payment.success`; COD: PAID khi `DELIVERED` |
| `orderStatus` | PLACED → CONFIRMED → CLOSED (+ CANCELLED) | đặt → (COD xác nhận ngay / online khi PAID) → giao xong |
| `fulfillmentStatus` | NONE → AWAITING_PRINT → READY_TO_PICK → ISSUED → SHIPPED → DELIVERED (+ RETURNED) | print xong / `goods.issued` / Shipping |

> Ví dụ: COD đang giao = `{UNPAID, CONFIRMED, SHIPPED}`; ly-in online chờ in = `{PAID, CONFIRMED, AWAITING_PRINT}`.
