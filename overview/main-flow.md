# Main Flow — Luồng nghiệp vụ toàn hệ thống

> Trạng thái: 🔄 Đang phân tích — tổng hợp happy-path xuyên suốt 2 app (WMS + Ecommerce) và module Notification.
> File này **nối** các workflow chi tiết của từng module; mỗi pha có link tới sơ đồ gốc. Tên collection/enum/event khớp [data-ownership](./data-ownership.md) và [system-context](./system-context.md).

## Bối cảnh

- **2 app, 2 logical DB** (chung 1 MongoDB cluster): `wms` (nội bộ, `wms_db`) và `ecommerce` (public, `ecom_db`). Giao tiếp **bất đồng bộ qua event** (BullMQ + Redis) — không đọc chéo DB, liên kết **chỉ qua `sku`**. Xem [system-context](./system-context.md).
- **Actor chính:** Khách (ecommerce) · MANAGER/RECEIVER/PICKER/PRINTER/COUNTER (WMS) · Hệ thống (worker/event).

---

## 1. Bản đồ luồng tổng quan (happy path)

```
WMS (nội bộ)                          Ecommerce (public)                 Notification
────────────                          ──────────────────                 ────────────
NCC → [P0 Nhập: PO→GRN→Put-away]
            │
            │ stock.changed(+) ───────────▶ availableQty += delta  (sync hiển thị)
            │                                         │
            │                              KHÁCH → [P1 Duyệt/Tìm]
            │                                       → [P2 Chi tiết + variant (+design)]
            │                                       → [P3 Checkout: reserve qua SAGA event]
            │ ◀── stock.reserve_requested ─────────  │  (Ecom → WMS, tạo Order{PLACED,UNPAID,NONE})
            │ ── stock.reserved / stock.reserve_failed ──▶  (WMS → Ecom, giữ tồn hoặc hủy đơn)
            │                                       [P4 Thanh toán]  │
            │                                         │ payment.success ──▶ email xác nhận
            │ ◀── print.requested ───── (chỉ khi có ly-in, đã PAID)
   [P5 In ly] CUP_BLANK→CUP_PRINTED                   │
            │                              fulfillment = READY_TO_PICK
   [P6 Xuất kho] ── goods.issued ─────────▶ fulfillment = ISSUED
            │                                         │
            │                              [P7 Giao hàng] → SHIPPED → DELIVERED → CLOSED
            │                                         │              (COD: PAID khi giao)
            │                                         ▼
            │ ◀── order.cancelled (trước ISSUED) ── [Hủy]  → release reserve, refund
            │ ◀── order.returned  (sau DELIVERED) ─ [RMA]  → nhập lại / scrap
```
> Mũi tên `◀──` = event Ecom→WMS; `──▶` = event WMS→Ecom/Notification. **Reserve tồn kho lúc checkout là SAGA BẤT ĐỒNG BỘ qua event (không transaction xuyên 2 DB)**: Ecom phát `stock.reserve_requested` → WMS giữ tồn (`reserved += qty` trong `stock_balances`, atomic theo từng sku) → WMS phản hồi `stock.reserved` (đủ tồn) hoặc `stock.reserve_failed` (thiếu tồn, Ecom tự hủy đơn). Hủy đơn sau khi đã reserve → Ecom phát `order.cancelled` → WMS giải phóng `reserved` tương ứng. Không bắn `stock.changed` cho reserve/release (đây là biến động nội bộ `reserved`, không đổi `available` tổng theo cách `stock.changed` đồng bộ). Xem [.claude/rules/architecture.md](../../be/.claude/rules/architecture.md).

| Pha | Module | Workflow gốc |
|---|---|---|
| P0 Nhập hàng | WMS | [WF-01](../warehouse/workflow.md#wf-01-nhập-hàng-từ-nhà-cung-cấp-uc-01--uc-02--uc-03) |
| P1 Duyệt/Tìm | Catalog | [WF-C01](../catalog/workflow.md#wf-c01-duyệt--tìm-kiếm) |
| P2 Chi tiết + design | Catalog | [WF-C02](../catalog/workflow.md#wf-c02-chi-tiết--chọn-biến-thể) · [WF-C03](../catalog/workflow.md#wf-c03-chọnupload-design-ly-in-custom_print) |
| P3 Checkout + reserve | Order | [WF-E01](../order/workflow.md#wf-e01-checkout--giữ-tồn) |
| P4 Thanh toán | Order | [WF-E02](../order/workflow.md#wf-e02-thanh-toán--xác-nhận) |
| P5 In ly (nếu có ly-in) | WMS | [WF-02](../warehouse/workflow.md#wf-02-lệnh-in-ly-theo-đơn-hàng-uc-04) |
| P6 Xuất kho | WMS | [WF-03](../warehouse/workflow.md#wf-03-xuất-kho-theo-đơn-hàng-uc-05) |
| P7 Giao hàng | Shipping | [WF-E03](../order/workflow.md#wf-e03-giao-hàng) · [WF-S01](../shipping/workflow.md#wf-s01-vòng-đời-vận-đơn-happy-path) |
| Hủy / RMA | Order | [WF-E04](../order/workflow.md#wf-e04-hủy-đơn-trước-xuất-kho) · [WF-E05](../order/workflow.md#wf-e05-hoàn-hàng-rma) |
| Sync tồn (xuyên suốt) | Catalog | [WF-C04](../catalog/workflow.md#wf-c04-đồng-bộ-tồn-consumer) |

---

## 2. Main flow chi tiết (swimlane end-to-end)

### P0 — Nhập hàng vào kho (tiền đề: phải có tồn để bán)

```
NCC          MANAGER/RECEIVER         WMS                       Ecommerce
 |                |                     |                          |
 |                |-- Tạo PO → SENT --->|                          |
 |-- Giao hàng -->|                     |                          |
 |                |-- GRN (ref PO) ---->| onHand+ (CONFIRMED)      |
 |                |-- Put-away -------->| lưu vị trí (sellable)    |
 |                |                     |-- stock.changed{sku,+} ->| availableQty += delta
```
> Chi tiết & audit (APPROVED) xem [WF-01](../warehouse/workflow.md#wf-01-nhập-hàng-từ-nhà-cung-cấp-uc-01--uc-02--uc-03). Từ đây sản phẩm có thể "còn hàng" trên storefront.

### P1+P2 — Khách duyệt, chọn biến thể (và design nếu ly-in)

```
KHÁCH                     CATALOG (ecommerce)
 |                          |
 |-- Duyệt cây / search --->| Product status=ACTIVE, lọc còn-hàng (availableQty>0)
 |-- Mở chi tiết product -->| list ProductVariant isActive
 |-- Chọn variant --------->| fulfillmentType?
 |   STANDARD/PRINTED_TEMPLATE → "Thêm giỏ" (isPrintItem=false)
 |   CUSTOM_PRINT → [upload mới | chọn từ thư viện designs] → set designId+designFile
 |-- Thêm vào giỏ --------->| CartItem{ sku, quantity, isPrintItem, designId?, designFile? }
```
> Giỏ **chưa giữ tồn** — chỉ đọc `availableQty` để cảnh báo. Chi tiết: [WF-C02](../catalog/workflow.md#wf-c02-chi-tiết--chọn-biến-thể)/[WF-C03](../catalog/workflow.md#wf-c03-chọnupload-design-ly-in-custom_print).

### P3 — Checkout & giữ tồn (reserve qua saga event)

```
KHÁCH                  CHECKOUT (order)            WMS (stock_balances)                Ecom (order)
 |                          |                          |                                    |
 |-- Địa chỉ + PTTT ------->| Chặn: ly-in + COD → từ chối
 |   (COD/ONLINE)           |-- tạo Order{PLACED,UNPAID,NONE} (optimistic, chưa reserve)
 |                          |-- stock.reserve_requested ────────────────────────────────────>|
 |<-- Đơn đã tạo (PLACED) --|                          |  WMS: thử từng kho active, atomic reserve
 |                          |                          |  từng sku trong 1 transaction/kho
 |                          |<─── stock.reserved (đủ tồn) / stock.reserve_failed (thiếu) ─────|
 |                          |  đủ tồn → CONFIRMED (COD) / chờ thanh toán (ONLINE)
 |                          |  thiếu tồn → tự hủy đơn, phục hồi giỏ hàng
```
> Checkout tạo đơn **optimistic** (`PLACED`, chưa giữ tồn) rồi phát `stock.reserve_requested` sang WMS — **saga bất đồng bộ qua event, không phải transaction xuyên 2 DB**. WMS thử lần lượt từng kho active, atomic reserve (`reserved += qty`) toàn bộ sku trong đơn trong 1 Mongo transaction/kho — nếu 1 sku thiếu tồn ở kho đang thử, transaction đó rollback, chuyển sang kho tiếp theo. Không kho nào đủ toàn bộ đơn → phát `stock.reserve_failed`, Ecom tự hủy đơn + phục hồi giỏ hàng. Reserve **tách khỏi thanh toán**, giữ tồn ngay khi đặt (không chờ thanh toán xong). Hủy đơn sau khi đã reserve (trước khi xuất kho) → Ecom phát `order.cancelled` → WMS giải phóng `reserved`. [WF-E01](../order/workflow.md#wf-e01-checkout--giữ-tồn).

### P4 — Thanh toán & xác nhận

```
KHÁCH               PAYMENT/ORDER              WMS / Notification
 |                       |                          |
 | [ONLINE] Trả cổng --->| Webhook idempotent → paymentStatus=PAID, orderStatus=CONFIRMED
 |                       |-- payment.success ------->| (Notification: email xác nhận)
 |                       | Có ly-in? --yes--> print.requested ──> WMS mở PrintJob (P5)
 |                       |                    fulfillment=AWAITING_PRINT
 |                       | Có ly-in? --no--> fulfillment=READY_TO_PICK
 | [COD] Đặt (hàng sẵn)->| orderStatus=CONFIRMED, fulfillment=READY_TO_PICK
 | [Quá paymentDeadline chưa PAID] → order.cancelled → release reserve → CANCELLED
```
> Ly-in **bắt buộc ONLINE trả-trước** (make-to-order chỉ chạy sau khi đã trả). [WF-E02](../order/workflow.md#wf-e02-thanh-toán--xác-nhận).

### P5 — In ly (chỉ khi đơn có ly-in CUSTOM_PRINT)

```
WMS (PrintJob)          PRINTER                  stock_balances
 |                          |                          |
 | print.requested →        |                          |
 | Kiểm tồn CUP_BLANK → GIỮ (reserved) → Job=PENDING    |
 |                          |-- Quét SKU+shelf, in --->| CUP_BLANK onHand−, reserved−
 |                          |-- Xác nhận in xong ----->| CUP_PRINTED onHand+ và reserve cho đơn
 |                    Job=COMPLETED ── print.completed ──> Ecom: đủ mọi ly-in? → fulfillment=READY_TO_PICK
```
> Hold "chuyển" từ blank sang `CUP_PRINTED` đúng đơn; nếu đã có CUP_PRINTED đủ → bỏ qua in. [WF-02](../warehouse/workflow.md#wf-02-lệnh-in-ly-theo-đơn-hàng-uc-04).

### P6 — Xuất kho

```
ORDER                   WMS / PICKER             stock_balances
 | READY_TO_PICK           |                       |
 |-- order.ready_to_fulfill ->| WMS sinh GoodsIssue (UC-05)
 |                         |-- Quét + Xác nhận xuất ->| onHand−, reserved− → GoodsIssue=CONFIRMED
 |<-- goods.issued --------| fulfillment=ISSUED
```
> Xuất trên đúng tồn đã reserve: hàng sẵn reserve từ P3; ly-in xuất trên `CUP_PRINTED` (hold đã chuyển từ blank ở P5). Không trừ `available` lần nữa — đã trừ lúc chốt đơn. [WF-03](../warehouse/workflow.md#wf-03-xuất-kho-theo-đơn-hàng-uc-05).

### P7 — Giao hàng & đóng đơn

```
WMS / SHIPPING           ORDER                    KHÁCH
 | ISSUED                  |                          |
 | auto sinh Shipment{PENDING}; gán carrier+tracking  |
 |-- shipment.shipped ---->| fulfillment=SHIPPED      |
 |                         |-- Giao tới ------------->| 
 |-- shipment.delivered -->| fulfillment=DELIVERED    |
 | COD → paymentStatus=PAID; orderStatus=CLOSED       |
 |  [giao thất bại hẳn]    |                          |
 |-- shipment.returned --->| fulfillment=RETURNED; orderStatus=CANCELLED
```
> [WF-E03](../order/workflow.md#wf-e03-giao-hàng) · chi tiết [shipping/workflow.md](../shipping/workflow.md#wf-s01-vòng-đời-vận-đơn-happy-path). Notification gửi thông báo giao hàng qua `shipment.shipped`/`shipment.delivered`.

---

## 3. Nhánh phụ (không thuộc happy path)

```
[Hủy đơn] (trước ISSUED; ly-in trước AWAITING_PRINT)
  KHÁCH → ORDER: orderStatus=CANCELLED → order.cancelled ──▶ WMS: reserved −= qty (giải phóng tồn)
                 ONLINE đã PAID → REFUND_PENDING → REFUNDED.  [WF-E04]

[RMA hoàn] (sau DELIVERED, trong 7 ngày)
  KHÁCH → ORDER: order.returned → WMS (UC-09): hàng tốt→nhập lại / hỏng→scrap
                 fulfillment=RETURNED, hoàn tiền nếu hợp lệ.  [WF-E05]
  → Ly-in custom không nhận hoàn trừ khi lỗi/hỏng.

[Vận hành kho nền] (chạy độc lập, đều phát stock.changed → sync availableQty)
  Kiểm kho (WF-04) · Lô hết hạn → stock.expired → scrap (UC-08)
```

---

## 4. Dòng sự kiện xuyên suốt (event timeline)

| Thứ tự | Event | Từ → Đến | Ý nghĩa trong main flow |
|---|---|---|---|
| P0 | `stock.changed` (+) | WMS → Ecom | Nhập kho xong → hàng "còn" trên storefront |
| P3 | `stock.reserve_requested` | Ecom → WMS | Chốt đơn tạm (`PLACED`) → yêu cầu WMS giữ tồn |
| P3 | `stock.reserved` / `stock.reserve_failed` | WMS → Ecom | Đủ tồn → `CONFIRMED`; thiếu tồn → tự hủy đơn |
| P4 | `payment.success` | Ecom → Notification | Trả tiền OK → email xác nhận |
| P4 | `print.requested` | Ecom → WMS | Đơn ly-in đã PAID → mở PrintJob |
| P5 | `print.completed` | WMS → Ecom | In xong → set `printJobId`; đủ mọi ly-in → `READY_TO_PICK` |
| P6 | `order.ready_to_fulfill` | Ecom → WMS | Đơn `READY_TO_PICK` → WMS sinh GoodsIssue |
| P6 | `goods.issued` | WMS → Ecom | Xuất kho xong → `fulfillment=ISSUED` (không trừ available lần nữa) |
| P7 | `shipment.shipped` | WMS → Ecom | Bàn giao hãng → `fulfillment=SHIPPED` |
| P7 | `shipment.delivered` | WMS → Ecom | Giao thành công → `DELIVERED`; COD→`PAID`; `orderStatus=CLOSED` |
| P7 | `shipment.returned` | WMS → Ecom | Giao thất bại hẳn → `RETURNED`; `orderStatus=CANCELLED` |
| Hủy | `order.cancelled` | Ecom → WMS | Trả tồn (`reserved−`, available+) |
| RMA | `order.returned` | Ecom → WMS | Mở phiếu hoàn (UC-09) |
| Nền | `stock.expired` | WMS → Ecom | Lô hết hạn → `availableQty` giảm |

> Bảng đầy đủ (gồm `stock.low`, `stock.near_expiry`) xem [data-ownership](./data-ownership.md#các-event-đồng-bộ-giữa-wms-và-ecommerce).

---

## 5. Vòng đồng bộ tồn (luôn chạy nền)

```
WMS biến động available phía kho (GRN, kiểm kho, in ly, hết hạn)
        │  stock.changed{sku, delta} / stock.expired
        │  (reserve/release lúc checkout/hủy KHÔNG qua đây — Ecom tự trừ/cộng
        │   availableQty ngay trong transaction của mình, phối hợp với WMS qua
        │   saga stock.reserve_requested/reserved/reserve_failed riêng ở P3)
        ▼
Catalog worker: tìm ProductVariant theo sku → availableQty += delta (clamp hiển thị ≥ 0)
        ▼
Storefront hiển thị còn/hết hàng — nhưng CHỐT THẬT ở reserve qua saga lúc checkout (P3)
```
> `availableQty` là **bản copy** để hiển thị nhanh, không phải nguồn chân lý. Nguồn thật = `wms_db.stock_balances`. [WF-C04](../catalog/workflow.md#wf-c04-đồng-bộ-tồn-consumer).
