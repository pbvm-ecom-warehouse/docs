# Order (Ecommerce) — Data Model

> Trạng thái: 🔄 Đang phân tích — theo spec [2026-06-04-ecommerce-order-module-design](../superpowers/specs/2026-06-04-ecommerce-order-module-design.md)

> **Ownership:** Module Order sở hữu `carts`/`orders`/`payments`. `customerId` trỏ tài khoản khách (`customers`) do **module Auth** sở hữu — Order **không định nghĩa schema Customer**, chỉ tham chiếu id. Liên kết WMS **chỉ qua `sku`** + `printJobId`/`fulfillWarehouseId` — không đọc chéo collection. Xem [data-ownership](../overview/data-ownership.md).

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
| designId | ObjectId | Trỏ `designs` (thư viện khách, khi `isPrintItem`) — truy vết & reuse |

> Giỏ **chưa giữ tồn** — chỉ đọc `availableQty` (bản copy WMS sync) để hiển thị/cảnh báo. Giữ tồn thật xảy ra ở checkout.

> **Vòng đời Cart:** mỗi khách có tối đa 1 giỏ `ACTIVE`. Checkout thành công ([WF-E01](./workflow.md#wf-e01-checkout--giữ-tồn)) → `ACTIVE → CONVERTED` (đóng giỏ, tạo Order). Giỏ `ACTIVE` không đụng tới quá `N` ngày (cấu hình được) → job nền chuyển `ABANDONED` (giải phóng để khách mở giỏ mới). Giỏ không bao giờ tự giữ tồn nên không cần release khi `ABANDONED`.

> **Design ly-in:** với `isPrintItem`, storefront cho khách upload mới hoặc chọn lại từ thư viện → set `designId` + copy `designFile` (snapshot). Xem [Catalog data-model](../catalog/data-model.md).

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
| designId | ObjectId | Trỏ `designs` (khi `isPrintItem`); `designFile` là snapshot file lúc đặt |
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
| refundedAt | DateTime | Thời điểm hoàn tiền (khi `status = REFUNDED`) |
| raw | Object | Payload webhook (lưu đối soát) |

> **Luồng hoàn tiền (refund):** chỉ áp dụng cho ONLINE đã `PAID` (hủy [WF-E04](./workflow.md#wf-e04-hủy-đơn-trước-xuất-kho) hoặc RMA [WF-E05](./workflow.md#wf-e05-hoàn-hàng-rma)). Khi đơn vào `paymentStatus = REFUND_PENDING`, **hệ thống (job)/admin** gọi API hoàn tiền của cổng → nhận callback → set `Payment.status = REFUNDED` (idempotent theo `providerTxnId`) + `refundedAt` → cập nhật `Order.paymentStatus = REFUNDED`. Refund thất bại → giữ `REFUND_PENDING`, cảnh báo để xử lý tay. COD chưa thu tiền → không refund.

## Nhóm 4: Ba trục trạng thái

> Trạng thái đơn tách **3 trục độc lập** để tránh state lai (COD/online × make-to-order):

| Trục | Giá trị | Nguồn chuyển |
|---|---|---|
| `paymentStatus` | UNPAID → PAID → REFUND_PENDING → REFUNDED | ONLINE: `payment.success`; COD: PAID khi `DELIVERED` |
| `orderStatus` | PLACED → CONFIRMED → CLOSED (+ CANCELLED) | đặt → (COD xác nhận ngay / online khi PAID) → giao xong |
| `fulfillmentStatus` | NONE → AWAITING_PRINT → READY_TO_PICK → ISSUED → SHIPPED → DELIVERED (+ RETURNED) | print xong / `goods.issued` / Shipping |

> Ví dụ: COD đang giao = `{UNPAID, CONFIRMED, SHIPPED}`; ly-in online chờ in = `{PAID, CONFIRMED, AWAITING_PRINT}`.

> **Đơn xuất nguyên kiện (không tách):** `fulfillmentStatus` là **một trục cho cả đơn**, không theo từng dòng. Đơn **hỗn hợp** (vừa `CUSTOM_PRINT` vừa hàng sẵn) đi chung một nhịp: cả đơn `AWAITING_PRINT` cho tới khi in xong **mọi** ly-in → rồi mới `READY_TO_PICK` → một `GoodsIssue` xuất toàn bộ. **Chưa hỗ trợ giao từng phần** (partial fulfillment) — hàng sẵn trong đơn hỗn hợp vẫn chờ in xong mới xuất cùng.
