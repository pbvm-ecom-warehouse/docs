# 10 — Order (Ecommerce)

> Bảng: `carts` (+items), `orders` (+items), `payment_transactions` · Schema gốc: [order/data-model](../order/data-model.md)

Phần **mua & trả tiền** bên `ecom_db`. Đây là nơi diễn ra **chống oversell** — điểm kỹ thuật quan trọng nhất của cả hệ.

## carts (+ items) — giỏ hàng

| Field (cart) | Ý nghĩa |
|---|---|
| `customerId` | 1 giỏ `ACTIVE` / khách |
| `status` | `ACTIVE → CONVERTED` (checkout xong) / `ABANDONED` (job nền dọn giỏ cũ) |

| Field (item) | Ý nghĩa |
|---|---|
| `sku` | Liên kết WMS/catalog |
| `isPrintItem` | Là ly-in? |
| `designId` + `designFile` | Trỏ `designs` + snapshot file (khi `isPrintItem`) |

> **Giỏ CHƯA giữ tồn** — chỉ đọc `availableQty` (bản copy) để hiển thị/cảnh báo. Giữ tồn thật xảy ra ở **checkout**.

## orders (+ items) — đơn hàng

| Field (order) | Ý nghĩa |
|---|---|
| `code` | Mã đơn hiển thị (unique) |
| `shippingAddress` | **Snapshot** địa chỉ lúc đặt |
| `subtotal`/`shippingFee`/`total` | Tiền (snapshot) |
| `paymentMethod` | `COD` / `ONLINE` |
| 3 trục: `paymentStatus`/`orderStatus`/`fulfillmentStatus` | Xem [khái niệm ⑤](00-khai-niem-loi.md) |
| `fulfillWarehouseId` | **Kho đã giữ tồn** (1 kho/đơn, ưu tiên CENTRAL) |
| `hasPrintItems` | Có ly-in → gate trả-trước |
| `paymentDeadline` | Hạn trả online; quá hạn chưa PAID → tự hủy |

| Field (item) | Ý nghĩa |
|---|---|
| `sku`, `name`, `unitPrice` | **Snapshot** lúc đặt |
| `designId`/`designFile` | Khi ly-in |
| `printJobId` | Ref PrintJob bên WMS — Ecom set khi nhận `print.completed` |

## Chống oversell — reserve ATOMIC lúc checkout

`availableQty` chỉ là **kiểm tra sơ bộ** (bản copy có thể trễ). Nếu 2 khách mua cùng lúc món cuối, cả 2 đọc `availableQty = 1` → cả 2 lọt → **oversell**.

Khi **chốt đơn**, giữ tồn **atomic** trên nguồn thật `wms_db.stock_balances` trong **1 transaction** (cùng cluster nên xuyên 2 DB được):

```
Đặt hàng → chọn kho có available ≥ qty (ưu tiên CENTRAL) → mở transaction:
  1. wms_db.stock_balances: kiểm onHand−reserved ≥ qty → reserved += qty (khóa document)
  2. ecom_db.product_variants: availableQty −= qty   (Ecom tự trừ bản copy — KHÔNG qua event)
  3. ecom_db.orders: tạo Order + OrderItem (snapshot)
  → commit cùng lúc; thiếu → rollback + báo hết hàng
```

> Hai khách mua đồng thời ly cuối → **chỉ 1 transaction commit được** → không bao giờ oversell. Đây là lợi thế của monolith cùng cluster (microservices tách DB riêng mới phải dùng Saga).

> **Reserve tách khỏi thanh toán:** tồn giữ ngay khi đặt (cả COD/online). `order.placed` chỉ là **thông báo thuần**. Thanh toán (`payment.success`) chỉ để **xác nhận đơn online** + **mở lệnh in**.

## Phân bổ 1 kho/đơn (chưa split đa kho)

- Đơn giữ tồn ở **một kho** có `available ≥ qty` (ưu tiên CENTRAL), lưu `fulfillWarehouseId`.
- Không kho đơn lẻ nào đủ — dù **tổng** mọi kho đủ — đơn **bị từ chối**. Cần thì [Chuyển kho](05-xuat-kho-va-noi-bo.md) gom hàng về 1 kho trước.

## payment_transactions — sổ cái tiền (append-only)

Mỗi biến động tiền = **1 dòng**, không sửa/xóa.

| Field | Ý nghĩa |
|---|---|
| `type` | `CHARGE` (thu online) / `REFUND` (hoàn) / `COD_COLLECT` (thu COD lúc giao) |
| `status` | `SUCCESS` / `FAILED` / `PENDING` (PENDING chỉ cho REFUND chờ callback) |
| `amount` | Luôn **dương**; hướng tiền suy từ `type` |
| `providerTxnId` | **unique** (online) — khóa idempotency callback cổng |
| `idempotencyKey` | Duy nhất mỗi dòng — chống ghi trùng |

### `Order.paymentStatus` là cache dẫn xuất

Tính lại từ sổ cái mỗi lần append dòng SUCCESS/PENDING:

| Sổ cái có | → paymentStatus |
|---|---|
| Chưa có CHARGE/COD_COLLECT SUCCESS | `UNPAID` |
| CHARGE SUCCESS (online) **hoặc** COD_COLLECT SUCCESS | `PAID` |
| REFUND PENDING | `REFUND_PENDING` |
| REFUND SUCCESS (đủ amount) | `REFUNDED` |
| dòng FAILED | (chỉ audit, không đổi status) |

> **Refund** chỉ cho ONLINE đã PAID (hủy hoặc RMA): append `REFUND/PENDING` → callback → `REFUND/SUCCESS` (idempotent theo `providerTxnId`) → `REFUNDED`. COD chưa thu thì không refund.

---

← [09 — Catalog](09-catalog.md) · → [11 — Auth-Ecom](11-auth-ecom.md)
