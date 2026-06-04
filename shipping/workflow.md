# Shipping (WMS) — Workflow

> Trạng thái: 🔄 Đang phân tích

Module Shipping quản lý 2 trục trạng thái độc lập: **`shipmentStatus`** (nội bộ WMS, 7 bước chi tiết) và **`fulfillmentStatus`** (Order Ecommerce — chỉ thấy `ISSUED → SHIPPED → DELIVERED / RETURNED`). Mỗi đơn hàng = 1 vận đơn (xuất nguyên kiện, không tách).

---

## WF-S01: Vòng đời vận đơn (happy path)

```
WMS / SHIPPING                    ORDER (Ecom)              NOTIFICATION
       |                               |                          |
[UC-05 GoodsIssue hoàn tất]           |                          |
goods.issued ─────────────────────────►                          |
       │  ← Tự động sinh Shipment      │ fulfillmentStatus        |
       │    {PENDING}                  │   = ISSUED (giữ nguyên)  |
       │                               │                          |
SHIPPER gán carrierId +                │                          |
       trackingNumber (UC-S02)         │                          |
       │  shipmentStatus: PENDING      │                          |
       │                               │                          |
Hãng đến lấy hàng tại kho             │                          |
       │  shipmentStatus: PICKED_UP    │                          |
       │  (ghi statusHistory)          │  ← không đổi trục nào   |
       │                               │                          |
Bàn giao hãng – rời kho               │                          |
       │  shipmentStatus: IN_TRANSIT   │                          |
       │  ghi shippedAt                │                          |
       ├── shipment.shipped ───────────► fulfillmentStatus        |
       │                               │   ISSUED → SHIPPED       |
       │                               ├──────────────────────────► "Đơn đang giao"
       │                               │                          |
Hàng giao thành công                  │                          |
       │  shipmentStatus: DELIVERED    │                          |
       │  ghi deliveredAt              │                          |
       ├── shipment.delivered ─────────► fulfillmentStatus        |
       │                               │   SHIPPED → DELIVERED    |
       │                               │ COD → paymentStatus=PAID |
       │                               │ orderStatus → CLOSED     |
       │                               ├──────────────────────────► "Đã giao thành công"
       │                               │                          |
```

**Trục thay đổi theo bước:**

| Bước | shipmentStatus (WMS) | fulfillmentStatus (Order) | paymentStatus | orderStatus |
|---|---|---|---|---|
| goods.issued → auto sinh | `PENDING` | `ISSUED` (giữ) | — | — |
| Gán hãng + tracking | `PENDING` | — | — | — |
| Hãng lấy hàng | `PICKED_UP` | — | — | — |
| Bàn giao hãng | `IN_TRANSIT` | `ISSUED → SHIPPED` | — | — |
| Giao thành công | `DELIVERED` | `SHIPPED → DELIVERED` | COD → `PAID` | `→ CLOSED` |

---

## WF-S02: Giao thất bại & hoàn về

```
WMS / SHIPPING                    ORDER (Ecom)              NOTIFICATION
       |                               |                          |
       │ (đang IN_TRANSIT)             │                          |
       │                               │                          |
Giao không được (khách vắng,           │                          |
       sai địa chỉ, từ chối nhận)      │                          |
       │  shipmentStatus: FAILED       │                          |
       │  failReason ghi lý do         │  ← fulfillment giữ       |
       │  attempts++                   │    nguyên (SHIPPED)      |
       │  (ghi statusHistory)          │                          |
       │                               │                          |
       ├─── Nhánh A: Retry ────────────────────────────────────── |
       │  SHIPPER lên lịch giao lại    │                          |
       │  shipmentStatus: IN_TRANSIT   │  ← không đổi trục nào   |
       │  → quay lại WF-S01 từ        │                          |
       │    bước "Bàn giao hãng"       │                          |
       │                               │                          |
       ├─── Nhánh B: Bỏ cuộc ──────────────────────────────────── |
       │  Hết retry / khách từ chối    │                          |
       │  shipmentStatus: RETURNING    │  ← không đổi trục nào   |
       │  (hàng trên đường về kho)     │                          |
       │                               │                          |
Hàng về đến kho                        │                          |
       │  shipmentStatus: RETURNED     │                          |
       ├── shipment.returned ──────────► fulfillmentStatus        |
       │                               │   → RETURNED             |
       │                               │ orderStatus → CANCELLED  |
       │                               │ ONLINE → paymentStatus   |
       │                               │   = REFUND_PENDING       |
       │                               │ COD → không đổi          |
       │                               ├──────────────────────────► "Đơn bị hoàn về"
       │                               │                          |
RECEIVER nhập lại hàng vật lý          │                          |
(UC-S04 / warehouse)                   │                          |
       │  Hàng còn tốt → nhập lại kho  │                          |
       │    StockBalance.onHand +=     │                          |
       │    available tăng → sync Ecom │                          |
       │  Hàng hỏng → Scrap (UC-08)   │                          |
```

**Trục thay đổi theo bước:**

| Bước | shipmentStatus (WMS) | fulfillmentStatus (Order) | paymentStatus | orderStatus |
|---|---|---|---|---|
| Giao thất bại | `IN_TRANSIT → FAILED` | Giữ nguyên (`SHIPPED`) | — | — |
| Retry | `FAILED → IN_TRANSIT` | Giữ nguyên | — | — |
| Bỏ cuộc – hàng trên đường về | `FAILED → RETURNING` | Giữ nguyên | — | — |
| Hàng về kho | `RETURNING → RETURNED` | `→ RETURNED` | ONLINE → `REFUND_PENDING` | `→ CANCELLED` |

> **Nhập lại hàng hoàn về:** RECEIVER xử lý qua [warehouse UC-09](../warehouse/use-cases.md#uc-09-hoàn-hàng-return--rma) — hàng còn tốt nhập lại kho (`StockBalance.onHand +=`; `availableQty` sync Ecommerce); hàng hỏng chuyển sang UC-08 Scrap.

> **Return-to-sender ≠ RMA:** vận đơn `RETURNING → RETURNED` là hàng chưa từng giao được → `orderStatus = CANCELLED`. Khác với RMA sau khi khách đã nhận (`DELIVERED`) — trường hợp đó đơn giữ nguyên `CLOSED` (xem WF-E05 trong [order/workflow](../order/workflow.md#wf-e05-hoàn-hàng-rma)).
