# 12 — Luồng end-to-end (ráp 45 bảng lại)

> Một vòng đời đơn hàng đi qua hầu hết các bảng. Đây là bài "tổng duyệt" — đọc sau khi đã nắm 11 bài trước. Tham chiếu nghiệp vụ đầy đủ: [main-flow.md](../overview/main-flow.md).

## Sơ đồ tổng

```
       ECOMMERCE (ecom_db)                    WMS (wms_db)
       ───────────────────                    ────────────
P0  Nhập hàng                          ┌─► purchase_orders → goods_receive_notes
                                       │   → putaway_tasks → inventory_stocks
                                       │   stock_balances.onHand += , movement RECEIVE/PUTAWAY
                                       │
P1  Khách duyệt catalog                │
    products/product_variants          │   ◄── availableQty ◄─ stock.changed ◄─┘
    (availableQty = copy)
        │
P2  Thêm giỏ → carts/cart_items (chưa giữ tồn)
        │
P3  CHECKOUT ─ transaction atomic xuyên 2 DB ─────►
    orders + order_items (snapshot)          stock_balances.reserved += qty
    product_variants.availableQty −=          (chống oversell)
    order.placed ─────────────────────────►  (thông báo thuần)
        │
P4  Thanh toán
    COD → orderStatus CONFIRMED ngay
    ONLINE → payment_transactions(CHARGE) → paymentStatus PAID
        │ có ly-in?
        ├─ CÓ: print.requested ──────────►  print_jobs + print_job_items
        │      fulfillmentStatus AWAITING_PRINT   in: PRINT_CONSUME / PRINT_OUTPUT
        │      ◄── print.completed ──────────────  set order_items.printJobId
        │      → READY_TO_PICK
        └─ KHÔNG: READY_TO_PICK ngay (COD) / khi PAID (online)
        │
P5  order.ready_to_fulfill ──────────►  goods_issues + goods_issue_items
    (payload: địa chỉ, recipient,        PICKER lấy theo FEFO (lots/inventory_stocks)
     paymentMethod, codAmount)           onHand −= , reserved −= , movement ISSUE −
        ◄── goods.issued ──────────────  → auto-sinh shipments
        │   fulfillmentStatus ISSUED
        │
P6  Giao hàng                            shipments: PENDING → IN_TRANSIT → DELIVERED
        ◄── shipment.shipped ──────────  fulfillmentStatus SHIPPED
        ◄── shipment.delivered ────────  fulfillmentStatus DELIVERED
            COD → payment_transactions(COD_COLLECT) → PAID
            orderStatus CLOSED
        │
P7  Hậu mãi (nếu có)
        Hủy trước xuất → order.cancelled → release reserved
        Trả hàng (RMA) → order.returned ─► goods_returns (GOOD nhập lại / DAMAGED scrap)
        Giao thất bại → shipment.returned → orderStatus CANCELLED
        Refund online → payment_transactions(REFUND) → REFUNDED
```

## Bảng nào "sáng đèn" ở mỗi pha

| Pha | Bảng chính tham gia |
|---|---|
| P0 Nhập | suppliers, purchase_orders, goods_receive_notes, putaway_tasks, lots, inventory_stocks, stock_balances, stock_movements |
| P1 Duyệt | categories, products, product_variants *(availableQty sync)* |
| P2 Giỏ | carts, cart_items, designs *(nếu ly-in)* |
| P3 Checkout | orders, order_items, stock_balances *(reserve)*, product_variants *(availableQty−)* |
| P4 Thanh toán | payment_transactions, print_jobs, print_job_items |
| P5 Xuất | goods_issues, stock_movements, shipments |
| P6 Giao | shipments, payment_transactions *(COD_COLLECT)* |
| P7 Hậu mãi | goods_returns, scrap_notes, payment_transactions *(REFUND)* |

## 3 chỗ "ráp" 2 app — nhắc lại

1. **`sku`** — `product_variants.sku ⟷ warehouse_items.sku` (đồng bộ tồn qua event).
2. **`orderId`** (reference id) — `print_jobs`/`goods_issues`/`goods_returns`/`shipments` giữ `orderId`, không join.
3. **`printJobId`** — Order ghi lại id bên WMS để truy vết.

Mọi giao tiếp khác qua **event (BullMQ + Redis)**, không đọc chéo DB.

## Bất biến phải luôn đúng (checklist khi present)

- [ ] `onHand = Σ inventory_stocks.quantity` (2 lớp khớp)
- [ ] `onHand = Σ stock_movements.quantity` (sổ cái khớp)
- [ ] `available = onHand − reserved − expired ≥ 0`
- [ ] Reserve atomic → không oversell
- [ ] `Order.paymentStatus` = recompute từ `payment_transactions`
- [ ] 1 đơn = 1 vận đơn (`shipments`)
- [ ] Snapshot ở order_items / shippingAddress / recipient / designFile

---

← [11 — Auth-Ecom](11-auth-ecom.md) · [⌂ Index](README.md)
