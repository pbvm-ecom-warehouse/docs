# Ecommerce — Thiết kế module Order (cụm mua hàng)

> Ngày: 2026-06-04
> Trạng thái: Spec — chờ review trước khi viết plan
> Phạm vi: tài liệu (`docs/order/`) + mô hình dữ liệu Ecommerce (cart → checkout → order → payment → fulfillment)

## Context

Module Kho (WMS) đã có docs đầy đủ & nhất quán. Đầu kia của mọi sự kiện với WMS là **app Ecommerce** nhưng chưa có doc riêng — nhiều logic đơn hàng (reserve, chống oversell, `fulfillWarehouseId`, `validateStock`, `order.confirmed/cancelled/returned`, `payment.success`) đang nằm rải rác trong [data-ownership.md](../../overview/data-ownership.md). Spec này gom chúng thành thiết kế hoàn chỉnh cho cụm mua hàng phía khách.

Mục tiêu: định nghĩa ranh giới module, mô hình dữ liệu, state machine đơn, các luồng nghiệp vụ và sự kiện tích hợp — đủ chi tiết để viết plan triển khai.

## Quyết định đã chốt (qua brainstorming)

| # | Quyết định |
|---|---|
| Phạm vi | Cụm mua hàng đầy đủ: cart → checkout → order → payment → fulfillment. **Catalog** tách riêng (doc sau). |
| Thanh toán | **Cả COD và online** (cổng VNPay/Momo...). |
| Reserve | **Giữ tồn ngay khi đặt** (cả COD/online). Đơn có ly-in (make-to-order) **bắt buộc trả trước online** mới mở print job. |
| Tài khoản | **Chỉ khách đã đăng nhập** (collection `customers`). Không guest checkout. |
| Đơn trộn | Hàng sẵn + ly-in → **chờ in xong, giao 1 lần** (1 GoodsIssue/đơn). |
| Hủy đơn | Khách tự hủy **trước khi xuất kho**; ly-in chỉ hủy **trước khi mở print job**; online đã trả → hoàn tiền; sau xuất kho → RMA (UC-09). |
| Trạng thái | **3 trục độc lập** (payment × order × fulfillment) — tránh state lai. |

---

## 1. Ranh giới module (app `ecommerce`)

```
ecommerce/src/modules/
├── cart/        Giỏ hàng — 1 cart ACTIVE / customer; chưa giữ tồn
├── checkout/    Điều phối: validateStock → reserve (WMS, atomic) → tạo Order → khởi tạo Payment
├── order/       Vòng đời đơn (3 trục trạng thái), lịch sử, hủy, RMA
└── payment/     COD + cổng online; webhook; hoàn tiền
```

- **catalog** (tách riêng): cấp giá/ảnh/mô tả; `availableQty` do WMS sync về (cơ chế đã có trong data-ownership).
- Tích hợp ngoài: **WMS** (reserve/issue/print qua event BullMQ), **Notification** (email/SMS), **Shipping** (doc sau — chỉ chừa interface tiêu thụ `goods.issued`).
- Liên kết WMS **chỉ qua `sku`** + `printJobId`/`fulfillWarehouseId` (không đọc chéo collection).

---

## 2. Mô hình dữ liệu

### Cart / CartItem (giỏ tạm — chưa giữ tồn)

**Cart**: `id`, `customerId`, `status` (`ACTIVE`/`CONVERTED`/`ABANDONED`), `updatedAt`.

**CartItem**: `cartId`, `sku`, `quantity`, `isPrintItem` (bool), `designFile?` (ly-in).

### Order

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| code | String | Mã đơn hiển thị (unique) |
| customerId | ObjectId | Bắt buộc (đã đăng nhập) |
| items | OrderItem[] | |
| shippingAddress | Object | **Snapshot** tên/SĐT/địa chỉ lúc đặt |
| subtotal / shippingFee / total | Number | Tiền chốt lúc đặt |
| paymentMethod | Enum | `COD` / `ONLINE` |
| **paymentStatus** | Enum | `UNPAID` / `PAID` / `REFUND_PENDING` / `REFUNDED` |
| **orderStatus** | Enum | `PLACED` / `CONFIRMED` / `CANCELLED` / `CLOSED` |
| **fulfillmentStatus** | Enum | `NONE` / `AWAITING_PRINT` / `READY_TO_PICK` / `ISSUED` / `SHIPPED` / `DELIVERED` / `RETURNED` |
| fulfillWarehouseId | ObjectId | Kho WMS đã giữ tồn (1 kho/đơn, ưu tiên CENTRAL) |
| hasPrintItems | Boolean | Có ly-in → gate trả-trước |
| paymentDeadline | DateTime | Hạn trả online; quá hạn chưa `PAID` → tự hủy |
| cancelReason | String | |
| placedAt / updatedAt | DateTime | |

### OrderItem

`orderId`, `sku`, `name` (snapshot), `unitPrice` (snapshot), `quantity`, `isPrintItem`, `designFile?`, `printJobId?` (WMS — khi đã mở lệnh in).

### Payment

`orderId`, `method` (`COD`/`ONLINE`), `provider`, `amount`, `status` (`INIT`/`SUCCESS`/`FAILED`/`REFUNDED`), `providerTxnId` (idempotency key), `paidAt`, `raw` (payload webhook).

> **Snapshot:** giá/tên/địa chỉ chốt vào Order lúc đặt → không phụ thuộc catalog/customer đổi sau.

---

## 3. State machine — 3 trục độc lập

**`paymentStatus`**: `UNPAID → PAID → REFUND_PENDING → REFUNDED`
- ONLINE: `UNPAID → PAID` khi `payment.success` (webhook cổng).
- COD: giữ `UNPAID` đến khi `DELIVERED` → `PAID`.

**`orderStatus`**: `PLACED → CONFIRMED → CLOSED` (+ `CANCELLED`)
- `PLACED`: vừa đặt, đã reserve tồn.
- `CONFIRMED`: COD xác nhận ngay sau đặt; ONLINE xác nhận khi `PAID`.
- `CLOSED`: giao xong (hoặc đóng sau hoàn tất/giao thiếu).
- `CANCELLED`: hủy trước xuất kho.

**`fulfillmentStatus`**: `NONE → AWAITING_PRINT → READY_TO_PICK → ISSUED → SHIPPED → DELIVERED` (+ `RETURNED`)
- `AWAITING_PRINT`: đơn có ly-in, đang chờ in (chỉ vào nhánh này khi đã `PAID`).
- `READY_TO_PICK`: WMS sinh GoodsIssue (UC-05).
- `ISSUED` ← `goods.issued`; `SHIPPED`/`DELIVERED` ← Shipping (module sau).

> Ví dụ tổ hợp: COD đang giao = `{UNPAID, CONFIRMED, SHIPPED}`; ly-in online chờ in = `{PAID, CONFIRMED, AWAITING_PRINT}`.

---

## 4. Luồng nghiệp vụ

### Checkout
```
Giỏ → validateStock (sơ bộ từ availableQty)
   → chọn kho có available ≥ qty (ưu tiên CENTRAL) + reserve ATOMIC trên wms_db.stock_balances (1 transaction)
   → tạo Order{PLACED, UNPAID, fulfillment NONE, fulfillWarehouseId}
   → khởi tạo Payment
   → reserve fail (đua món cuối) → rollback, không tạo đơn, báo hết hàng
```
- **Chặn checkout:** đơn **có ly-in mà chọn COD** → không cho (bắt chuyển ONLINE).

### Sau khi đặt
- **Hàng sẵn + COD** → `CONFIRMED` ngay → `READY_TO_PICK`.
- **Hàng sẵn + ONLINE** → chờ `payment.success` → `PAID` + `CONFIRMED` → `READY_TO_PICK`.
- **Có ly-in (luôn ONLINE)** → `payment.success` → `CONFIRMED` → phát `print.requested` (WMS mở PrintJob/UC-04) → `AWAITING_PRINT` → in xong tất cả → `READY_TO_PICK`.

### Fulfillment
`READY_TO_PICK` → WMS GoodsIssue (UC-05) → `goods.issued` → `ISSUED` → Shipping → `SHIPPED` → `DELIVERED`.
- COD: tới `DELIVERED` → `paymentStatus = PAID`.
- `DELIVERED` → `orderStatus = CLOSED`.

### Hủy đơn
- Khách hủy khi `fulfillmentStatus` chưa tới `ISSUED` (trước khi xuất kho) → phát `order.cancelled` (WMS release reserve) → `orderStatus = CANCELLED`.
- ONLINE đã `PAID` → `REFUND_PENDING` → (hoàn tiền) → `REFUNDED`.
- **Ly-in:** chỉ hủy được **trước khi mở PrintJob** (trước `AWAITING_PRINT`); đã in → không hủy (hàng custom).

### Hoàn hàng (RMA)
- Sau `DELIVERED`, trong **hạn đổi trả** (mặc định **7 ngày** kể từ `DELIVERED`, cấu hình được) → phát `order.returned` → WMS UC-09 (nhập lại hàng tốt / scrap hàng hỏng).
- Ly-in custom **không nhận hoàn trừ khi lỗi/hỏng**.

---

## 5. Sự kiện tích hợp

| Event | Từ → Đến | Khi nào | Tác động |
|---|---|---|---|
| `order.placed` | Ecom → WMS | **lúc checkout** (COD/online) | reserve `+= qty` (atomic, trong transaction checkout) |
| `print.requested` | Ecom → WMS | `payment.success` & `hasPrintItems` | WMS mở PrintJob (UC-04) cho từng ly-in |
| `order.cancelled` | Ecom → WMS | hủy trước xuất kho | release reserve (blank/printed tùy giai đoạn) |
| `order.returned` | Ecom → WMS | RMA sau giao | UC-09 nhập lại/scrap |
| `goods.issued` | WMS → Ecom | xuất kho xong | `fulfillmentStatus = ISSUED` |
| `payment.success` | Ecom → Notification | trả online OK | email xác nhận |
| `order.placed/shipped/delivered` | Ecom → Notification | mốc đơn | thông báo khách |

### ⚠️ Cần sửa lại doc WMS đã viết (mâu thuẫn ngữ nghĩa)

Quyết định "reserve **ngay khi đặt**" làm lệch [data-ownership.md](../../overview/data-ownership.md) hiện tại — đang ghi `order.confirmed` reserve **"sau khi thanh toán xong"**. Khi triển khai phải cập nhật docs WMS:
- Tách **reserve** (lúc đặt, qua `order.placed`) khỏi **payment** (chỉ gate mở print job + xác nhận đơn online).
- Đổi `order.confirmed` → `order.placed` trong bảng event WMS; thêm `print.requested`.
- Hàng `order.cancelled`/`order.returned` giữ nguyên ngữ nghĩa.

*(Việc cập nhật docs WMS nằm trong plan triển khai, không thuộc brainstorm.)*

---

## 6. Edge cases

1. **Reserve fail lúc checkout** (đua mua món cuối): transaction rollback → không tạo đơn → báo hết hàng. Không bao giờ oversell (cùng cluster).
2. **Online trả lỗi/bỏ giữa chừng:** đơn `PLACED/UNPAID`; quá `paymentDeadline` (vd 30') chưa `PAID` → tự `order.cancelled` (release reserve) → `CANCELLED`. Ly-in chưa in nên an toàn.
3. **Webhook trùng/đến trễ:** Payment xử lý **idempotent** theo `providerTxnId`.
4. **Tồn đổi giữa add-to-cart và checkout:** `availableQty` chỉ là bản copy → chốt thật ở **reserve atomic** lúc checkout.
5. **Đổi giá/ảnh catalog sau khi đặt:** không ảnh hưởng — Order snapshot giá/tên lúc đặt.

---

## Ngoài phạm vi (YAGNI)
- **Catalog** (sản phẩm/biến thể/giá/SEO) — doc & module riêng.
- **Shipping** (đối tác giao vận, tracking) — doc riêng; spec này chỉ chừa interface `goods.issued`.
- **Giao thiếu / xuất một phần số lượng** (đặt 10 giao 7) — chưa làm; mặc định giao trọn số lượng đã đặt, lệch tồn xử lý sau.
- Khuyến mãi/voucher/điểm thưởng.
- Guest checkout.

## Verification (khi triển khai)
- Lần theo 4 luồng end-to-end khớp 3 trục trạng thái: (1) hàng sẵn COD, (2) hàng sẵn ONLINE, (3) ly-in ONLINE, (4) hủy + hoàn tiền.
- Kiểm reserve atomic chống oversell (2 đơn đua món cuối → 1 thành công).
- Kiểm idempotency webhook (gửi 2 lần `payment.success` → 1 lần chuyển `PAID`).
- Đối chiếu lại các sự kiện với docs WMS sau khi cập nhật `order.placed`/`print.requested`.
