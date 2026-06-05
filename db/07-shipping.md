# 07 — Shipping (Vận chuyển)

> Bảng: `carriers`, `shipments` · Schema gốc: [shipping/data-model](../shipping/data-model.md)

Module trong `wms_db`: quản lý hãng vận chuyển và vận đơn. Nối với đơn Ecom **chỉ qua `orderId`** + event.

## carriers — hãng vận chuyển

| Field | Ý nghĩa |
|---|---|
| `code` | Mã ngắn duy nhất, vd `GHN` |
| `status` | `ACTIVE` / `INACTIVE` |
| `contactInfo` | SĐT/đầu mối |
| `apiConfig?` | **Để trống** — chỗ chừa cho tích hợp API hãng sau (YAGNI: chưa làm adapter vòng này) |

## shipments — vận đơn

**1 đơn = 1 vận đơn** (xuất nguyên kiện, không tách). **Auto-sinh** sau khi `goods.issued`.

| Field | Ý nghĩa |
|---|---|
| `orderId` | Đơn Ecom (reference id — không đọc chéo `ecom_db`) |
| `goodsIssueId` | Phiếu xuất nguồn (1:1) |
| `carrierId` | Hãng — **gán tay** bởi nhân viên kho |
| `trackingNumber` | Mã vận đơn hãng — **nhập tay** |
| `recipient` | **Snapshot** `{name, phone, address}` — nhận qua payload event (WMS không đọc Ecom) |
| `paymentMethod` + `codAmount` | Để biết có **thu hộ COD** không; ONLINE đã trả thì `codAmount=0` |
| `attempts` / `failReason` | Số lần giao đã thử / lý do thất bại gần nhất |
| `statusHistory[]` | **Append log** `{status, at, by, note}` — audit, không xóa |
| `shippedAt` / `deliveredAt` | Mốc bàn giao hãng / giao thành công |

## shipmentStatus — vòng đời vận đơn

```
PENDING ──► PICKED_UP ──► IN_TRANSIT ──► DELIVERED
                              │  ▲
                              ▼  │ retry
                           FAILED
                              │ hết retry / khách từ chối
                              ▼
                         RETURNING ──► RETURNED
```

| Trạng thái | Nghĩa |
|---|---|
| `PENDING` | Vừa auto-sinh, chưa gán hãng |
| `PICKED_UP` | Hãng đã đến lấy hàng |
| `IN_TRANSIT` | Đang giao (đã bàn giao hãng) |
| `DELIVERED` | Giao thành công |
| `FAILED` | Thất bại 1 lần (khách vắng…), có thể retry → quay lại `IN_TRANSIT` |
| `RETURNING → RETURNED` | Bỏ cuộc, hoàn về kho |

## 3 mốc làm lộ trạng thái sang Order

Chỉ 3 chuyển trạng thái phát event sang Ecom:

| shipmentStatus | Event | fulfillmentStatus | paymentStatus | orderStatus |
|---|---|---|---|---|
| `IN_TRANSIT` | `shipment.shipped` | ISSUED → SHIPPED | — | — |
| `DELIVERED` | `shipment.delivered` | SHIPPED → DELIVERED | **COD → PAID** | → CLOSED |
| `RETURNED` | `shipment.returned` | → RETURNED | ONLINE đã trả → REFUND_PENDING | → CANCELLED |

> **COD thu tiền lúc DELIVERED:** chính ở mốc này hệ ghi `payment_transactions: COD_COLLECT` → `paymentStatus = PAID`.

## Return-to-sender ≠ RMA

- **Vận đơn `RETURNED`** (chưa từng giao được) → `orderStatus = CANCELLED`.
- **RMA** (hoàn sau khi khách đã nhận, [bài 05](05-xuat-kho-va-noi-bo.md) / `goods_returns`) → đơn vẫn `CLOSED`, chỉ `fulfillmentStatus → RETURNED`.

Hai cái khác nhau về thời điểm và hệ quả trạng thái đơn.

---

← [06 — Supplier](06-supplier.md) · → [08 — Auth-WMS](08-auth-wms.md)
