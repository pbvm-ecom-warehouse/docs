# Payment Ledger — Design Spec

> Trạng thái: 🔄 Đang phân tích → chốt thiết kế. Nối tiếp follow-up của [auth-design](./2026-06-05-auth-design.md).
> Ngày: 2026-06-05. Phạm vi: module **Order/Payment** (Ecommerce, `ecom_db`).

## 1. Bối cảnh & động lực

Hiện tại [order/data-model Nhóm 3](../../order/data-model.md) dùng collection `payments` **ghi-đè status** (`INIT/SUCCESS/FAILED/REFUNDED`), refund cập nhật tại chỗ. Mất vết lịch sử khi có nhiều lần thử/callback.

**Động lực chốt:** **Audit + idempotency giao dịch** (không mô hình hóa đối soát remittance COD/hãng — để ngoài phạm vi). Thay bằng **sổ cái append-only** kiểu `stock_movements` của WMS: mỗi biến động tiền = 1 dòng bất biến.

**Ngoài phạm vi (YAGNI):** đối soát COD remittance với hãng vận chuyển, partial refund nhiều dòng phức tạp, đa cổng thanh toán, phí cổng/chiết khấu.

## 2. Quyết định (chốt qua brainstorm)

| # | Quyết định | Lý do |
|---|---|---|
| P1 | Mục tiêu = audit + idempotency, không remittance | giữ phạm vi trong Order/Payment, không chạm Shipping |
| P2 | **Thay** `payments` → `payment_transactions` append-only | bỏ ghi-đè, khớp triết lý `stock_movements` |
| P3 | Ghi đủ loại: `CHARGE` / `REFUND` / `COD_COLLECT`, **gồm cả `FAILED`** | đủ vết audit retry/gian lận; idempotency theo `providerTxnId` |
| P4 | `Order.paymentStatus` thành **cache dẫn xuất** từ chuỗi giao dịch | nguồn chân lý tiền = sổ cái |
| P5 | Đổi tên `payments` → `payment_transactions` | đúng bản chất sổ cái |

## 3. Data Model

### PaymentTransaction (`payment_transactions`) — append-only, bất biến

> Thay thế collection `payments` cũ. Mỗi biến động tiền = 1 dòng; **không sửa/xóa** sau khi ghi (giống `stock_movements`).

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| orderId | ObjectId | → Order |
| type | Enum | `CHARGE` / `REFUND` / `COD_COLLECT` |
| status | Enum | `SUCCESS` / `FAILED` / `PENDING` (PENDING chỉ dùng cho REFUND chờ callback) |
| method | Enum | `ONLINE` / `COD` |
| amount | Number | luôn **dương**; hướng tiền suy từ `type` (CHARGE/COD_COLLECT = thu vào, REFUND = trả ra) |
| providerTxnId | String? | **unique** (online) — khóa idempotency cho callback cổng |
| idempotencyKey | String | duy nhất mỗi dòng; COD_COLLECT = `orderId + delivery`, lần retry fail có key riêng |
| gatewayPayload | Object? | snapshot callback cổng (audit) |
| createdAt | DateTime | bất biến |

### Order.paymentStatus — cache dẫn xuất

> `paymentStatus` vẫn là field trên Order (giữ mô hình 3 trục trạng thái) nhưng **được recompute** từ sổ cái mỗi lần append dòng SUCCESS/PENDING, **trong cùng transaction**.

Quy tắc dẫn xuất (theo các dòng của đơn):
- Chưa có `CHARGE`/`COD_COLLECT` SUCCESS → `UNPAID`
- Có `CHARGE` SUCCESS (online) **hoặc** `COD_COLLECT` SUCCESS (COD lúc `shipment.delivered`) → `PAID`
- Có `REFUND` PENDING → `REFUND_PENDING`
- `REFUND` SUCCESS (đủ amount) → `REFUNDED`
- Dòng `FAILED` **không** đổi `paymentStatus` (chỉ lưu vết audit)

## 4. Idempotency

- Callback cổng tra `providerTxnId` (unique) → đã có dòng thì **bỏ qua** (không append trùng, không đổi trạng thái).
- `COD_COLLECT` idempotent theo `idempotencyKey = orderId + delivery` → một lần giao chỉ thu 1 lần.

## 5. Tích hợp (không đổi module Shipping)

| Tình huống | Hành động sổ cái | Kết quả paymentStatus |
|---|---|---|
| Online trả thành công (`payment.success`) | append `CHARGE/SUCCESS/ONLINE` | `PAID` |
| Online trả lỗi | append `CHARGE/FAILED/ONLINE` | không đổi |
| COD giao thành công (consumer `shipment.delivered`) | append `COD_COLLECT/SUCCESS/COD` | `PAID` |
| Hủy/RMA đơn online đã `PAID` | append `REFUND/PENDING` → callback hoàn → `REFUND/SUCCESS` | `REFUND_PENDING` → `REFUNDED` |
| Refund thất bại | giữ `REFUND/PENDING`, cảnh báo xử lý tay | `REFUND_PENDING` |

> COD chưa thu (chưa `DELIVERED`) → không có dòng COD_COLLECT → không refund.

## 6. Cập nhật cross-file

1. **[order/data-model.md](../../order/data-model.md)** — thay Nhóm 3 (`Payment`) bằng `PaymentTransaction`; ghi rõ `paymentStatus` là cache dẫn xuất; cập nhật chú thích luồng refund.
2. **[order/workflow.md](../../order/workflow.md)** — luồng refund/COD tham chiếu sổ cái append-only.
3. **[data-ownership.md](../../overview/data-ownership.md)** — đổi `payments` → `payment_transactions` trong ô sở hữu Ecommerce.
4. **[gap-analysis.md](../../overview/gap-analysis.md)** — đánh dấu mục `payment_transactions` ✅ (đã thiết kế), gỡ trạng thái "xem xét".

## 7. Bất biến giữ đúng

- Sổ cái bất biến, append-only — không sửa/xóa dòng (đối soát về sau).
- Nguồn chân lý tiền = `payment_transactions`; `Order.paymentStatus` chỉ là cache.
- Không đọc chéo DB; không đổi module Shipping (chỉ là consumer event sẵn có `shipment.delivered`).
