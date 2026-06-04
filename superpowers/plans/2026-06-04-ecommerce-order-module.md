# Ecommerce Order Module — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Viết bộ tài liệu phân tích nghiệp vụ cho module Order (Ecommerce) theo đúng chuẩn module Kho, và cập nhật docs WMS cho khớp ngữ nghĩa reserve-lúc-đặt.

**Architecture:** Đây là **repo tài liệu thuần** (`.md`). "Implementation" = tạo `docs/order/{use-cases,data-model,workflow}.md` + cập nhật `overview/data-ownership.md`, `warehouse/use-cases.md`, `README.md`. Nguồn nội dung là spec [2026-06-04-ecommerce-order-module-design.md](../specs/2026-06-04-ecommerce-order-module-design.md).

**Tech Stack:** Markdown (GitHub-flavored), sơ đồ ASCII swimlane như `warehouse/workflow.md`. Không có test tự động → **verification = grep nhất quán + đối chiếu spec + kiểm anchor link**.

**Quy ước:**
- Mỗi task = 1 file, kết thúc bằng 1 commit (`docs: ...`, tiếng Việt, kèm `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`).
- Tên sự kiện/field/enum phải khớp **đúng** spec (xem bảng tham chiếu cuối plan).
- Làm Task theo thứ tự: Task 1 (data-ownership) trước vì các file sau trỏ tới nó.

---

## File Structure

| File | Trách nhiệm | Hành động |
|---|---|---|
| `overview/data-ownership.md` | Sự kiện Ecom↔WMS, reserve tách khỏi payment | Modify |
| `order/data-model.md` | Cart/CartItem/Order/OrderItem/Payment + 3 trục trạng thái | Create |
| `order/use-cases.md` | UC-E01..E06 (giỏ→checkout→pay→fulfill→hủy→RMA) | Create |
| `order/workflow.md` | Swimlane WF-E01..E05 | Create |
| `warehouse/use-cases.md` | UC-04 trigger trỏ `print.requested`; UC-05 nhắc `order.placed` | Modify |
| `README.md` | Bảng module: điền link cho Order | Modify |

---

## Task 1: Cập nhật `overview/data-ownership.md` (reserve tách khỏi payment)

**Files:**
- Modify: `overview/data-ownership.md`

- [ ] **Step 1: Sửa bảng "Các event đồng bộ" — đổi `order.confirmed` → `order.placed` và thêm `print.requested`**

Thay dòng `order.confirmed` hiện tại bằng:

```markdown
| `order.placed` | Ecommerce | WMS | **Khách chốt đơn (cả COD/online)** → WMS giữ tồn (`reserved += qty`, atomic lúc checkout). **Tách khỏi thanh toán** — reserve ngay khi đặt, không chờ trả tiền |
| `print.requested` | Ecommerce | WMS | `payment.success` & đơn có ly-in → WMS mở PrintJob (UC-04) cho từng ly-in (make-to-order chỉ chạy sau khi đã trả) |
```

Giữ nguyên `order.cancelled`, `order.returned`, `goods.issued`.

- [ ] **Step 2: Sửa câu mô tả ở mục "Sync tồn kho qua Event" / "Chống oversell" cho khớp**

Trong mục **Chống oversell khi xác nhận đơn**, đảm bảo câu chữ nói reserve xảy ra **lúc checkout/chốt đơn** (không phải "sau thanh toán"). Nếu có cụm "thanh toán xong" gắn với reserve → đổi thành "chốt đơn". Thêm 1 câu:

```markdown
> **Reserve tách khỏi thanh toán:** tồn được giữ ngay khi đặt (`order.placed`), áp dụng cho cả COD và online. Thanh toán (`payment.success`) chỉ dùng để **xác nhận đơn online** và **mở lệnh in** cho đơn ly-in (`print.requested`). Đơn online quá hạn chưa trả → tự `order.cancelled` (release reserve).
```

- [ ] **Step 3: Verify — không còn `order.confirmed` mồ côi & ngữ nghĩa nhất quán**

Run: `grep -rn "order.confirmed\|thanh toán xong" overview/ warehouse/`
Expected: không còn dòng nào gắn reserve với "thanh toán xong"; `order.confirmed` không còn trong bảng event (nếu còn ở chỗ khác phải là tham chiếu lịch sử có chủ đích).

- [ ] **Step 4: Commit**

```bash
git add overview/data-ownership.md
git commit -m "docs: reserve tách khỏi payment - order.placed + print.requested

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Tạo `order/data-model.md`

**Files:**
- Create: `order/data-model.md`

- [ ] **Step 1: Viết file với nội dung sau**

````markdown
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
````

- [ ] **Step 2: Verify — field/enum khớp spec, link tương đối đúng**

Run: `grep -n "fulfillWarehouseId\|paymentStatus\|fulfillmentStatus\|providerTxnId" order/data-model.md`
Expected: có đủ; tên khớp bảng tham chiếu cuối plan. Mở link `../overview/data-ownership.md` và `../superpowers/specs/...` đảm bảo đường dẫn tồn tại.

- [ ] **Step 3: Commit**

```bash
git add order/data-model.md
git commit -m "docs: Order data-model - cart/order/payment + 3 trục trạng thái

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Tạo `order/use-cases.md`

**Files:**
- Create: `order/use-cases.md`

- [ ] **Step 1: Viết file với nội dung sau**

````markdown
# Order (Ecommerce) — Use Cases

## Tổng quan

| # | Tên | Actor | Trạng thái |
|---|---|---|---|
| UC-E01 | Quản lý giỏ hàng | Khách | 🔄 Đang phân tích |
| UC-E02 | Checkout & đặt hàng | Khách | 🔄 Đang phân tích |
| UC-E03 | Thanh toán (COD/online) | Khách + cổng TT | 🔄 Đang phân tích |
| UC-E04 | Theo dõi & fulfillment đơn | Khách + Hệ thống | 🔄 Đang phân tích |
| UC-E05 | Hủy đơn | Khách | 🔄 Đang phân tích |
| UC-E06 | Hoàn hàng (RMA) | Khách | 🔄 Đang phân tích |

---

## UC-E01: Quản lý giỏ hàng

**Actor:** Khách (đã đăng nhập)
**Mục đích:** Thêm/sửa/xóa món trước khi đặt; chưa giữ tồn.

### Luồng chính
1. Khách thêm SKU vào giỏ (nhập số lượng; ly-in → chọn/đính kèm `designFile`, đặt `isPrintItem = true`)
2. Hệ hiển thị `availableQty` (bản copy WMS sync) để cảnh báo nếu thiếu — **không giữ tồn** ở bước này
3. Sửa số lượng / xóa món → cập nhật giỏ

---

## UC-E02: Checkout & đặt hàng

**Actor:** Khách
**Mục đích:** Chốt đơn, **giữ tồn atomic**, tạo Order.

### Luồng chính
1. Khách chọn địa chỉ giao + phương thức thanh toán (`COD`/`ONLINE`)
2. **Chặn:** đơn có ly-in (`hasPrintItems`) mà chọn `COD` → từ chối, bắt chuyển `ONLINE` (make-to-order phải trả trước)
3. `validateStock` sơ bộ theo `availableQty`
4. Hệ chọn kho có `available ≥ qty` (ưu tiên `CENTRAL`) → **reserve ATOMIC** trên `wms_db.stock_balances` trong 1 transaction; lưu `fulfillWarehouseId`
5. Tạo `Order{orderStatus: PLACED, paymentStatus: UNPAID, fulfillmentStatus: NONE}` + snapshot giá/địa chỉ; phát `order.placed` (WMS đã giữ tồn trong transaction)
6. Khởi tạo `Payment`
7. Reserve fail (đua mua món cuối) → rollback, **không tạo đơn**, báo hết hàng

---

## UC-E03: Thanh toán (COD/online)

**Actor:** Khách + cổng thanh toán
**Mục đích:** Xác nhận đơn; mở lệnh in cho ly-in.

### Luồng chính — ONLINE
1. Khách chuyển sang cổng (VNPay/Momo) trả `total`
2. Cổng gọi webhook → Payment xử lý **idempotent** theo `providerTxnId` → `Payment.status = SUCCESS`, `Order.paymentStatus = PAID`
3. `orderStatus → CONFIRMED`
4. Nếu `hasPrintItems` → phát `print.requested` (WMS mở PrintJob/UC-04) → `fulfillmentStatus = AWAITING_PRINT`; ngược lại → `READY_TO_PICK`
5. Quá `paymentDeadline` chưa `PAID` → tự phát `order.cancelled` (release reserve) → `orderStatus = CANCELLED`

### Luồng chính — COD
1. Đơn chỉ gồm hàng sẵn (ly-in đã bị chặn ở UC-E02)
2. `orderStatus → CONFIRMED` ngay sau đặt; `fulfillmentStatus = READY_TO_PICK`
3. `paymentStatus` giữ `UNPAID` đến khi `DELIVERED` → `PAID`

---

## UC-E04: Theo dõi & fulfillment đơn

**Actor:** Khách (xem) + Hệ thống
### Luồng chính
1. `READY_TO_PICK` → WMS sinh GoodsIssue (UC-05), xuất kho từ `fulfillWarehouseId`
2. `goods.issued` (WMS→Ecom) → `fulfillmentStatus = ISSUED`
3. Shipping (module sau) → `SHIPPED` → `DELIVERED`
4. `DELIVERED`: nếu COD → `paymentStatus = PAID`; `orderStatus = CLOSED`
5. Khách tra cứu trạng thái đơn theo 3 trục

---

## UC-E05: Hủy đơn

**Actor:** Khách
**Mục đích:** Hủy trước khi xuất kho, trả tồn.

### Luồng chính
1. Khách yêu cầu hủy khi `fulfillmentStatus` **chưa tới `ISSUED`**
2. **Ly-in:** chỉ hủy được **trước khi mở PrintJob** (trước `AWAITING_PRINT`); đã in → từ chối (hàng custom)
3. Phát `order.cancelled` → WMS release reserve → `orderStatus = CANCELLED`
4. ONLINE đã `PAID` → `paymentStatus = REFUND_PENDING` → hoàn tiền → `REFUNDED`
5. Đã `ISSUED` rồi → không hủy, dùng UC-E06 (RMA)

---

## UC-E06: Hoàn hàng (RMA)

**Actor:** Khách
**Trigger:** Sau `DELIVERED`, trong hạn đổi trả (mặc định 7 ngày, cấu hình được)

### Luồng chính
1. Khách tạo yêu cầu hoàn → phát `order.returned` (Ecom→WMS)
2. WMS xử lý [UC-09 Hoàn hàng](../warehouse/use-cases.md#uc-09-hoàn-hàng-return--rma): hàng tốt nhập lại, hàng hỏng scrap
3. `fulfillmentStatus = RETURNED`; hoàn tiền nếu hợp lệ
4. **Ly-in custom không nhận hoàn trừ khi lỗi/hỏng**
````

- [ ] **Step 2: Verify — anchor link UC-09 đúng & event khớp**

Run: `grep -n "uc-09-hoàn-hàng" warehouse/use-cases.md` (đối chiếu slug header thực tế)
Expected: header UC-09 trong `warehouse/use-cases.md` sinh slug khớp anchor đã dùng. `grep -n "order.placed\|print.requested\|order.cancelled\|order.returned\|goods.issued" order/use-cases.md` → đủ 5 sự kiện.

- [ ] **Step 3: Commit**

```bash
git add order/use-cases.md
git commit -m "docs: Order use-cases UC-E01..E06 (giỏ→checkout→pay→fulfill→hủy→RMA)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Tạo `order/workflow.md`

**Files:**
- Create: `order/workflow.md`

- [ ] **Step 1: Viết file với nội dung sau** (swimlane ASCII như `warehouse/workflow.md`)

````markdown
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
  |                          |-- reserve ATOMIC -------->| reserved += qty
  |                          |   (chọn kho, ưu tiên CENTRAL)  (khóa document)
  |                          |<-- OK / hết hàng ---------|
  |                    Tạo Order{PLACED, UNPAID, NONE}    |
  |                    fulfillWarehouseId, order.placed   |
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
  |                    fulfillment → AWAITING_PRINT   | in xong → (báo) READY_TO_PICK
  |                    Có ly-in? --no--> READY_TO_PICK|
  |                          |                       |
  | [COD]                    |                       |
  |-- Đặt (hàng sẵn) ------->|                       |
  |                    orderStatus → CONFIRMED        |
  |                    fulfillment → READY_TO_PICK    |
  |                          |                       |
  | [Quá paymentDeadline chưa PAID] → order.cancelled → release reserve → CANCELLED
```

---

## WF-E03: Giao hàng

```
WMS                      ORDER                     SHIPPING (sau)
  |                        |                           |
  | READY_TO_PICK          |                           |
  |-- GoodsIssue (UC-05) ->|                           |
  |-- goods.issued ------->| fulfillment → ISSUED      |
  |                        |-- Bàn giao vận chuyển --->|
  |                        | fulfillment → SHIPPED     |
  |                        | fulfillment → DELIVERED   |
  |                        | COD → paymentStatus = PAID|
  |                        | orderStatus → CLOSED      |
```

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
````

- [ ] **Step 2: Verify — sơ đồ nhất quán tên trục/sự kiện**

Run: `grep -n "READY_TO_PICK\|AWAITING_PRINT\|order.placed\|print.requested" order/workflow.md`
Expected: tên trạng thái/sự kiện khớp `order/data-model.md` và spec.

- [ ] **Step 3: Commit**

```bash
git add order/workflow.md
git commit -m "docs: Order workflow WF-E01..E05 (swimlane)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Cập nhật docs WMS cho khớp (UC-04 trigger, UC-05)

**Files:**
- Modify: `warehouse/use-cases.md`

- [ ] **Step 1: UC-04 — trigger trỏ `print.requested`**

Trong UC-04, dòng `**Trigger:**` đổi thành:

```markdown
**Trigger:** Sự kiện `print.requested` từ Ecommerce (đơn ly-in đã `PAID`) — xem [data-ownership](../overview/data-ownership.md)
```

- [ ] **Step 2: UC-05 — làm rõ nguồn "đơn đã xác nhận"**

Trong UC-05, câu giả định reserve, thêm tham chiếu: tồn đã giữ từ `order.placed` (lúc khách đặt), đơn ở `orderStatus = CONFIRMED` mới sinh phiếu xuất. Chỉnh 1 câu cho khớp, không đổi logic tồn.

- [ ] **Step 3: Verify**

Run: `grep -n "print.requested\|order.placed" warehouse/use-cases.md`
Expected: UC-04 trigger có `print.requested`; không tái xuất hiện "order.confirmed".

- [ ] **Step 4: Commit**

```bash
git add warehouse/use-cases.md
git commit -m "docs: WMS UC-04 trigger print.requested; UC-05 nhắc order.placed

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Cập nhật `README.md` (điền link module Order) + review tổng

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Điền link cho dòng "Đơn hàng & E-commerce"**

Đổi dòng module Order trong bảng "Danh mục module" để trỏ:

```markdown
| [Đơn hàng & E-commerce](./order/) | [UC](./order/use-cases.md) | [Data Model](./order/data-model.md) | [Workflow](./order/workflow.md) |
```

- [ ] **Step 2: Review nhất quán toàn cục**

Run: `grep -rn "order.confirmed" .`
Expected: không còn (hoặc chỉ trong spec lịch sử có chú thích).

Run: `grep -rln "order.placed\|print.requested" overview/ warehouse/ order/`
Expected: xuất hiện đồng bộ ở data-ownership + order + warehouse.

Kiểm thủ công: mở `order/use-cases.md` anchor `../warehouse/use-cases.md#uc-09-...` không gãy.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README link module Order + đồng bộ order.placed/print.requested

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Bảng tham chiếu tên (PHẢI khớp tuyệt đối)

**Sự kiện:** `order.placed`, `print.requested`, `order.cancelled`, `order.returned`, `goods.issued`, `payment.success`, `stock.changed`.

**Order enums:**
- `paymentMethod`: `COD` / `ONLINE`
- `paymentStatus`: `UNPAID` / `PAID` / `REFUND_PENDING` / `REFUNDED`
- `orderStatus`: `PLACED` / `CONFIRMED` / `CANCELLED` / `CLOSED`
- `fulfillmentStatus`: `NONE` / `AWAITING_PRINT` / `READY_TO_PICK` / `ISSUED` / `SHIPPED` / `DELIVERED` / `RETURNED`
- `Payment.status`: `INIT` / `SUCCESS` / `FAILED` / `REFUNDED`
- `Cart.status`: `ACTIVE` / `CONVERTED` / `ABANDONED`

**Field then chốt:** `fulfillWarehouseId`, `hasPrintItems`, `paymentDeadline`, `providerTxnId`, `printJobId`.

---

## Self-Review (đã chạy khi viết plan)

- **Spec coverage:** mỗi mục spec có task — phạm vi/4 module (Task 2-4), thanh toán COD+online (UC-E03/WF-E02), reserve-lúc-đặt (Task 1), ly-in gate trả trước (UC-E02/E03), 3 trục trạng thái (Task 2), hủy/RMA (UC-E05/E06), edge case (rải trong UC + data-model), sửa docs WMS (Task 1, 5). ✅
- **Placeholder scan:** không có TBD/TODO; nội dung từng file viết đầy đủ. ✅
- **Type consistency:** enum/field/sự kiện thống nhất qua Bảng tham chiếu; các task dùng đúng tên đó. ✅
- **Giao thiếu** đã loại khỏi spec → không có task (đúng chủ ý). ✅
