# Shipping (WMS) — Data Model

> Trạng thái: 🔄 Đang phân tích

Module Shipping thuộc app **WMS**, dữ liệu lưu ở `wms_db`. Liên kết với đơn Ecommerce **chỉ qua `orderId`** (id tham chiếu) và event bất đồng bộ — không bao giờ đọc chéo `ecom_db`. Xem [data-ownership](../overview/data-ownership.md).

> **Audit (chung):** `carriers` (master) mang đủ `createdBy`/`updatedBy`/`createdAt`/`updatedAt`/`deletedAt`; `shipments` (chứng từ) mang `createdBy`/`createdAt`/`updatedAt` + `statusHistory[]`. Theo [Quy ước Audit](../overview/data-ownership.md#quy-ước-audit-chung-mọi-collection). Bảng dưới chỉ liệt kê field nghiệp vụ.

---

## carriers

Danh mục hãng vận chuyển — được WMS quản lý nội bộ.

| Field | Kiểu | Ghi chú |
|---|---|---|
| `_id` | ObjectId | |
| `name` | String | Tên hãng, vd "Giao Hàng Nhanh" |
| `code` | String | Mã ngắn duy nhất, vd `GHN` |
| `status` | Enum | `ACTIVE` / `INACTIVE` |
| `contactInfo` | Object | SĐT/đầu mối liên hệ |
| `note` | String | Ghi chú nội bộ |
| `apiConfig?` | Object | **Optional, để trống** — chỗ chừa cho tích hợp API hãng sau (endpoint/token). Chưa dùng trong vòng này (YAGNI adapter) |

---

## shipments

Vận đơn — **1 đơn = 1 vận đơn** (xuất nguyên kiện, không tách). Auto-sinh sau khi `goods.issued` từ WMS.

| Field | Kiểu | Ghi chú |
|---|---|---|
| `_id` | ObjectId | |
| `orderId` | String / ObjectId | **Id tham chiếu** đơn Ecom — KHÔNG đọc chéo `ecom_db`, chỉ lưu để đối soát & đẩy event |
| `goodsIssueId` | ObjectId | Phiếu xuất WMS (UC-05) — nguồn auto-sinh vận đơn |
| `carrierId` | ObjectId | Ref `carriers` — gán tay bởi nhân viên kho |
| `trackingNumber` | String | Mã vận đơn hãng — nhập tay |
| `shipmentStatus` | Enum | Xem [mục Enum bên dưới](#enum-shipmentstatus) |
| `recipient` | Object | **Snapshot** `{name, phone, address}` — nhận qua payload event `order.ready_to_fulfill` (WMS không đọc `ecom_db`) |
| `paymentMethod` | Enum | `COD` / `ONLINE` — để biết có thu hộ không |
| `codAmount` | Number | Tiền thu hộ (COD); = 0 nếu ONLINE đã thanh toán trước |
| `attempts` | Number | Số lần giao đã thử |
| `failReason` | String | Lý do thất bại lần giao gần nhất |
| `statusHistory[]` | Array | Append log `{status, at, by, note}` — không xóa, chỉ thêm |
| `shippedAt` | Date | Mốc bàn giao hãng (`IN_TRANSIT`) |
| `deliveredAt` | Date | Mốc giao thành công (`DELIVERED`) |

---

## Enum shipmentStatus

| Giá trị | Mô tả |
|---|---|
| `PENDING` | Vừa auto-sinh sau `goods.issued`, chưa gán hãng / chưa bàn giao |
| `PICKED_UP` | Hãng vận chuyển đã đến lấy hàng tại kho |
| `IN_TRANSIT` | Đang trên đường giao — đã bàn giao hãng (trigger `shipment.shipped`) |
| `DELIVERED` | Giao thành công — nhận xác nhận từ hãng hoặc nhập tay |
| `FAILED` | Giao thất bại 1 lần (khách vắng, sai địa chỉ…); có thể retry → quay về `IN_TRANSIT` |
| `RETURNING` | Đã bỏ cuộc (hết số lần retry / khách từ chối), đang hoàn về kho |
| `RETURNED` | Hàng đã về tới kho — kết thúc vòng đời vận đơn |

---

## Quan hệ với Order (Ecommerce)

WMS đẩy event → Ecommerce cập nhật các trục trạng thái tương ứng. Chỉ **3 mốc** làm lộ trạng thái sang Order:

| shipmentStatus (WMS) | Event phát | fulfillmentStatus (Order) | paymentStatus | orderStatus |
|---|---|---|---|---|
| `PENDING` / `PICKED_UP` | — | `ISSUED` (không đổi) | — | — |
| `IN_TRANSIT` | `shipment.shipped` | `ISSUED → SHIPPED` | — | — |
| `DELIVERED` | `shipment.delivered` | `SHIPPED → DELIVERED` | COD → `PAID`; ONLINE không đổi (đã `PAID`) | `→ CLOSED` |
| `FAILED` | — | Giữ nguyên (retry → quay lại `IN_TRANSIT`) | — | — |
| `RETURNING → RETURNED` | `shipment.returned` | `→ RETURNED` | ONLINE đã trả → `REFUND_PENDING` | `→ CANCELLED` |

> **1 đơn = 1 vận đơn:** đơn xuất nguyên kiện, không tách giao từng phần. `shipmentStatus` là trục duy nhất cho cả lô hàng.

> **Return-to-sender ≠ RMA:** vận đơn `RETURNING → RETURNED` là hàng chưa từng giao được → `orderStatus = CANCELLED`. Khác với RMA-sau-DELIVERED (hoàn hàng sau khi khách đã nhận) — trường hợp đó đơn giữ nguyên `CLOSED` (xem [order/data-model](../order/data-model.md#nhóm-4-ba-trục-trạng-thái)).
