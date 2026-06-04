# Spec thiết kế — Module Shipping (Vận chuyển)

> Trạng thái: 🔄 Đang phân tích — spec brainstorm, nguồn cho việc sinh `shipping/use-cases.md` + `data-model.md` + `workflow.md`.
> Ngày: 2026-06-04. Gap Hạng 1 theo [gap-analysis](../../overview/gap-analysis.md#1-shipping-vận-chuyển--hạng-1).

## 1. Mục tiêu & phạm vi

Module **Shipping** lấp gap Hạng 1 — chặn happy-path end-to-end sau bước xuất kho (`goods.issued`) đến đóng đơn (`CLOSED`). Hiện `fulfillmentStatus` đã có sẵn `ISSUED → SHIPPED → DELIVERED (+ RETURNED)` nhưng đoạn `[Shipping]` là "module sau".

**Mức triển khai: hybrid.** Thiết kế abstraction `Carrier`/`Shipment` để **vận hành thủ công ngay** (nhân viên gán đơn vị vận chuyển, nhập mã tracking, tự đẩy trạng thái), đồng thời chừa interface mở cho tích hợp API hãng (GHN/GHTK/Viettel Post...) về sau. **YAGNI phần adapter API** — chưa hiện thực trong vòng này.

**Bất biến phải giữ:**
- Liên kết Ecom↔WMS **chỉ qua event** (BullMQ+Redis), không đọc chéo collection.
- Đơn **xuất nguyên kiện, 1 kho/đơn** — 1 đơn = 1 vận đơn (không split, không partial fulfillment).
- COD: `paymentStatus = PAID` khi `DELIVERED` (chỉ flip, không đối soát dòng tiền remittance — YAGNI).
- `shippingFee`: **giữ hoãn** (ngoài phạm vi) — module này không tính phí.

## 2. Vị trí & chủ sở hữu dữ liệu

**Shipping = module trong app WMS, dữ liệu ở `wms_db`** (thư mục mới `shipping/`).

Lý do nghiệp vụ: bàn giao vật lý cho hãng diễn ra tại kho; nhân viên kho quản lý vòng đời vận đơn. Hệ quả kiến trúc: WMS **không đọc được `ecom_db.orders`**, nên mọi dữ liệu đơn cần để dựng vận đơn (địa chỉ, người nhận, COD) phải **đi kèm trong event**; và mọi thay đổi trạng thái giao phải **phát event ngược về Ecom** để cập nhật Order.

## 3. Data model (`wms_db`)

### 3.1. `carriers` — đơn vị vận chuyển (master data, config tay)

| Field | Kiểu | Ghi chú |
|---|---|---|
| `_id` | ObjectId | |
| `name` | String | Tên hãng (vd "Giao Hàng Nhanh") |
| `code` | String | Mã ngắn duy nhất (vd `GHN`) |
| `status` | Enum | `ACTIVE` / `INACTIVE` |
| `contactInfo` | Object | SĐT/đầu mối liên hệ |
| `note` | String | |
| `apiConfig?` | Object | **Optional, để trống** — chỗ chừa cho tích hợp API sau (endpoint/token). Không dùng trong vòng này. |

### 3.2. `shipments` — vận đơn (1:1 với GoodsIssue/đơn)

| Field | Kiểu | Ghi chú |
|---|---|---|
| `_id` | ObjectId | |
| `orderId` | String/ObjectId | **Id tham chiếu** đơn Ecom — KHÔNG đọc chéo, chỉ lưu để đối soát/đẩy event |
| `goodsIssueId` | ObjectId | Phiếu xuất WMS (UC-05) — nguồn sinh vận đơn |
| `fulfillWarehouseId` | ObjectId | Kho xuất (1 kho/đơn) |
| `carrierId` | ObjectId | Ref `carriers` — gán tay |
| `trackingNumber` | String | Mã vận đơn hãng — nhập tay |
| `shipmentStatus` | Enum | `PENDING` / `PICKED_UP` / `IN_TRANSIT` / `DELIVERED` / `FAILED` / `RETURNING` / `RETURNED` |
| `recipient` | Object | **Snapshot** `{name, phone, address}` — nhận qua event `order.ready_to_fulfill` |
| `paymentMethod` | Enum | `COD` / `ONLINE` — để biết có thu hộ không |
| `codAmount` | Number | Số tiền thu hộ (0 nếu `ONLINE` đã trả) |
| `attempts` | Number | Số lần giao đã thử |
| `failReason` | String | Lý do thất bại lần gần nhất |
| `statusHistory[]` | Array | Append log `{status, at, by, note}` |
| `shippedAt` / `deliveredAt` | Date | Mốc thời gian |

## 4. Hai trục trạng thái (nội bộ WMS vs Order Ecom)

WMS giữ `shipmentStatus` chi tiết; Order chỉ thấy 3 mốc `fulfillmentStatus`:

| `shipmentStatus` (WMS) | → `fulfillmentStatus` (Order) | Hệ quả khác trên Order |
|---|---|---|
| `PENDING` / `PICKED_UP` | (vẫn `ISSUED`) | — |
| `IN_TRANSIT` (đã bàn giao hãng) | `SHIPPED` | — |
| `DELIVERED` | `DELIVERED` | COD → `paymentStatus=PAID`; `orderStatus=CLOSED` |
| `FAILED` | (giữ nguyên) | retry → `attempts++`, quay lại `IN_TRANSIT` |
| `RETURNING → RETURNED` (hàng về kho) | `RETURNED` | `orderStatus=CANCELLED`; online đã trả → `REFUND_PENDING` |

**Quyết định:** return-to-sender (đơn **chưa từng giao thành công**, COD chưa thu) → `orderStatus = CANCELLED`. Khác biệt có chủ đích với RMA-sau-`DELIVERED` (vốn giữ `CLOSED`, xem [order/data-model](../../order/data-model.md)). Hàng vật lý về kho xử lý bằng **UC-09 (Hoàn hàng)** sẵn có (tốt→nhập lại / hỏng→scrap), có thể tạo phiếu hoàn "lập tay" tại WMS.

## 5. Events

| Event | Hướng | Ý nghĩa |
|---|---|---|
| `order.ready_to_fulfill` **(MỞ RỘNG payload)** | Ecom→WMS | Bổ sung `shippingAddress` + `recipient{name,phone}` + `paymentMethod` + `codAmount` để WMS dựng `Shipment`. (Trigger UC-05 giữ nguyên.) |
| `goods.issued` *(đã có)* | WMS→Ecom | Xuất kho xong → Order `ISSUED`. **Nội bộ WMS: auto sinh `Shipment{PENDING}`** 1:1 với GoodsIssue. |
| `shipment.shipped` **(MỚI)** | WMS→Ecom | Đã bàn giao hãng (`IN_TRANSIT`) → `fulfillmentStatus=SHIPPED` |
| `shipment.delivered` **(MỚI)** | WMS→Ecom | Giao thành công → `DELIVERED`; COD→`PAID`; `orderStatus=CLOSED` |
| `shipment.returned` **(MỚI)** | WMS→Ecom | Hoàn về hẳn → `RETURNED`; `orderStatus=CANCELLED`; online→`REFUND_PENDING` |
| `shipment.shipped` / `shipment.delivered` **(MỚI)** | WMS→Notification | Thông báo khách (đang giao / đã giao) |

**Điều chỉnh:** thông báo "đang giao" cho khách **chuyển từ `goods.issued` sang `shipment.shipped`** — `goods.issued` (xuất kho xong) chưa phải đã bàn giao cho hãng. `goods.issued → Notification` hiện tại được thay bằng `shipment.shipped → Notification`.

## 6. Use-cases (`shipping/use-cases.md`, prefix `UC-S`)

| Mã | Tên | Actor |
|---|---|---|
| UC-S01 | Quản lý đơn vị vận chuyển (CRUD `carriers`) | MANAGER |
| UC-S02 | Tạo & gán vận đơn (auto sinh sau `goods.issued`; gán carrier + tracking) | SHIPPER |
| UC-S03 | Cập nhật trạng thái giao (`PICKED_UP → IN_TRANSIT → DELIVERED`) | SHIPPER |
| UC-S04 | Xử lý giao thất bại & hoàn về (`FAILED`→retry / `RETURNING → RETURNED` + nối UC-09) | SHIPPER + RECEIVER |
| UC-S05 | Tra cứu vận đơn | SHIPPER (khách tra qua Order tracking) |

## 7. Workflow (`shipping/workflow.md`)

- **WF-S01 — Vòng đời vận đơn (happy path):** `goods.issued` → auto `Shipment{PENDING}` → gán carrier+tracking → `PICKED_UP` → `IN_TRANSIT` (`shipment.shipped` → SHIPPED) → `DELIVERED` (`shipment.delivered` → DELIVERED, COD→PAID, CLOSED).
- **WF-S02 — Giao thất bại & hoàn về:** `FAILED` → retry (`attempts++`, quay lại `IN_TRANSIT`); bỏ cuộc → `RETURNING` → hàng về kho `RETURNED` → `shipment.returned` (Order: RETURNED/CANCELLED) + UC-09 nhập lại/scrap.

## 8. File liên đới phải cập nhật (đầu ra của plan)

- `shipping/use-cases.md`, `shipping/data-model.md`, `shipping/workflow.md` — **tạo mới**.
- [overview/main-flow.md](../../overview/main-flow.md) — chi tiết hóa **P7** với shipment.* events.
- [overview/data-ownership.md](../../overview/data-ownership.md) — thêm collections `carriers`/`shipments` (WMS sở hữu) + 3 event mới; cập nhật dòng `goods.issued → Notification`.
- [overview/gap-analysis.md](../../overview/gap-analysis.md) — đánh dấu Shipping ✅ đã thiết kế.
- [order/workflow.md](../../order/workflow.md) — **WF-E03** dùng `shipment.shipped/delivered/returned` thay cho mô tả "[Shipping] (sau)".
- [warehouse/use-cases.md](../../warehouse/use-cases.md) — **UC-05** nối auto-sinh Shipment; **UC-09** ghi nhận nguồn return-to-sender.
- [README.md](../../README.md) — thêm module Shipping vào mục lục.

## 9. Ngoài phạm vi (YAGNI ghi nhận)

- Tích hợp API hãng (tạo vận đơn/webhook/tính phí real-time) — chỉ chừa interface, chưa hiện thực.
- `shippingFee` tự tính — giữ hoãn.
- Đối soát dòng tiền COD/remittance từ hãng — chỉ flip PAID khi DELIVERED.
- Partial fulfillment / split nhiều vận đơn / gộp đơn — đơn xuất nguyên kiện, 1 vận đơn/đơn.
