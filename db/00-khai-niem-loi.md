# 00 — 5 khái niệm lõi

> Nắm 5 ý này thì 45 bảng tự sáng. Mọi bảng đều là hệ quả của 5 nguyên tắc dưới đây.

---

## ① Hai app, hai DB, nối nhau DUY NHẤT qua `sku`

Cùng một "ly nhựa 500ml" nhưng 2 app nhìn khác nhau:

| | WMS (`wms_db`) | Ecommerce (`ecom_db`) |
|---|---|---|
| Quan tâm | SKU, số lượng, vị trí kho, hạn dùng | Tên, ảnh, **giá**, danh mục, SEO |
| Bảng | `warehouse_items` | `products` + `product_variants` |

- **1 MongoDB cluster** tách 2 logical DB. Cùng cluster nên **transaction atomic xuyên 2 DB vẫn làm được** (quan trọng cho chống oversell).
- **KHÔNG bao giờ đọc chéo collection** giữa 2 app. Liên kết DUY NHẤT là **`sku`** (chuỗi trùng nhau). Giao tiếp bất đồng bộ qua **event (BullMQ + Redis)**.

> Hệ quả thấy khắp nơi: `order_items` dùng `sku` (không FK tới catalog); `print_jobs` ôm `designFile` (file) chứ không ref `designs`; `shipments` chỉ giữ `orderId` (reference id) chứ không join `orders`.

**Ngược lại:** *trong cùng 1 app*, id ref bình thường (vd `order_items → orders`, `product_variants → products`). Quy tắc "chỉ qua sku" chỉ áp cho liên kết **xuyên app**.

---

## ② Tồn kho 2 lớp

```
StockBalance.onHand (lớp 1, tổng)  =  Σ InventoryStock.quantity (lớp 2, từng shelf)
available = onHand − reserved − expired      ← số đẩy sang Ecom hiển thị
```

- **Lớp 1 — `stock_balances`** (theo SKU + kho): dùng để **chống oversell & sync Ecom**. Không cần biết shelf.
- **Lớp 2 — `inventory_stocks`** (theo shelf + lô): biết **hàng nằm đâu** mà đi lấy.
- **Bất biến:** mọi biến động cập nhật **cả 2 lớp trong cùng 1 transaction**, nếu không 2 lớp lệch nhau.

Ví dụ 200 ly ở kho CENTRAL, nằm 2 shelf:

```
stock_balances:  {sku: LY-500, kho: CENTRAL, onHand: 200, reserved: 0, expired: 0}
inventory_stocks: {shelf: A1-T2, qty: 120}  +  {shelf: A1-T3, qty: 80}   → Σ = 200 ✓
```

---

## ③ Sổ cái append-only (immutable ledger)

Hai bảng **chỉ thêm, không sửa/xóa**:

| Bảng | Ghi gì |
|---|---|
| `stock_movements` | Mọi biến động tồn vật lý (thẻ kho) |
| `payment_transactions` | Mọi biến động tiền của đơn |

- Là **nguồn sự thật** để đối soát: `onHand = Σ stock_movements.quantity`; `paymentStatus = f(payment_transactions)`.
- Các field trạng thái (`Order.paymentStatus`…) chỉ là **cache dẫn xuất** — tính lại từ sổ cái, không phải nguồn gốc.
- Sai sót → **ghi dòng đảo (bút toán điều chỉnh)**, không sửa dòng cũ. Giữ vết audit tuyệt đối.

---

## ④ Snapshot (đóng băng lịch sử)

Một số chỗ **sao chép dữ liệu tại thời điểm xảy ra**, thay vì trỏ ref sống:

| Nơi | Snapshot gì | Vì sao |
|---|---|---|
| `order_items` | `name`, `unitPrice` | Sửa giá/tên SP sau này không làm méo đơn cũ |
| `orders.shippingAddress` | địa chỉ giao | Khách đổi sổ địa chỉ không ảnh hưởng đơn đã đặt |
| `shipments.recipient` | người nhận | WMS không đọc `ecom_db`, nhận qua payload event |
| `print_jobs.designFile` | file artwork | WMS chỉ cần file để in, không cần entity Design |

---

## ⑤ Đơn hàng 3 trục trạng thái độc lập

Thay vì 1 enum "trạng thái đơn" hỗn loạn, tách **3 trục rời nhau**:

| Trục | Giá trị | Ai chuyển |
|---|---|---|
| `paymentStatus` | UNPAID → PAID → REFUND_PENDING → REFUNDED | ONLINE: `payment.success`; COD: PAID khi DELIVERED |
| `orderStatus` | PLACED → CONFIRMED → CLOSED (+ CANCELLED) | đặt → xác nhận → giao xong |
| `fulfillmentStatus` | NONE → AWAITING_PRINT → READY_TO_PICK → ISSUED → SHIPPED → DELIVERED (+ RETURNED) | in/xuất/giao |

> Vì sao tách? Vì COD × online × make-to-order tổ hợp ra rất nhiều "state lai". Tách 3 trục thì mỗi trục đơn giản, ghép lại mô tả mọi tình huống. VD: *COD đang giao* = `{UNPAID, CONFIRMED, SHIPPED}`; *ly-in online chờ in* = `{PAID, CONFIRMED, AWAITING_PRINT}`.

---

→ Tiếp theo: [01 — Kho & vị trí](01-kho-va-vi-tri.md)
