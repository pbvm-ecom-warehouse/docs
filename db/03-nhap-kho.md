# 03 — Nhập kho (hàng đi vào)

> Bảng: `purchase_orders` (+items), `goods_receive_notes` (+items), `putaway_tasks` (+items) · Schema gốc: [warehouse/data-model — Nhóm 4](../warehouse/data-model.md#nhóm-4-giao-dịch-kho)

Dòng chảy 3 bước: **Đặt → Nhận → Xếp**.

```
PurchaseOrder ──► GoodsReceiveNote ──► PutAwayTask
   (đặt NCC)         (nhận thực tế)       (xếp lên kệ)
```

Mỗi bước là cặp **chứng từ cha + dòng chi tiết** (`*_items`). Pattern này lặp lại ở mọi phiếu kho: cha giữ thông tin chung (kho, trạng thái, người tạo), con giữ từng dòng hàng.

## purchase_orders (+ items) — UC-01

Đơn đặt hàng gửi NCC.

| Field (cha) | Ý nghĩa |
|---|---|
| `supplierId` | → `suppliers` (NCC) |
| `status` | `DRAFT → CONFIRMED → SENT → PARTIALLY_RECEIVED → COMPLETED` (+ CANCELLED) |

| Field (item) | Ý nghĩa |
|---|---|
| `expectedQty` + `unit` | Đặt bao nhiêu, theo đơn vị nào (có thể là đơn vị phụ `thùng`) |
| `unitPrice` | Mặc định gợi ý từ [`supplier_items.purchasePrice`](06-supplier.md), sửa tay được |

> **Trạng thái PO do GRN cập nhật:** mỗi GRN cộng dồn `actualQty` vào số đã nhận. Còn thiếu → `PARTIALLY_RECEIVED`; đủ → `COMPLETED`. PO không tự nhảy 2 trạng thái này.

## goods_receive_notes (+ items) — UC-02

Phiếu nhập **thực tế** (Goods Receive Note). Đây là lúc tồn **thật sự tăng**.

| Field (cha) | Ý nghĩa |
|---|---|
| `purchaseOrderId` | Nhận theo PO nào |
| `status` | `DRAFT → CONFIRMED → APPROVED` |
| `createdBy` / `approvedBy` | RECEIVER nhận / MANAGER duyệt |

| Field (item) | Ý nghĩa |
|---|---|
| `expectedQty` vs `actualQty` | Số theo PO vs số thực nhận (lệch thì ghi `note`) |
| `lotNumber` + `expiryDate` | Nếu `isPerishable` → hệ **tạo `Lot`** |

> Khi GRN `CONFIRMED`: `onHand += actualQty` (vào shelf **staging**), ghi `stock_movements: RECEIVE +`. Hàng đã trong kho nhưng chưa đúng chỗ.

## putaway_tasks (+ items) — UC-03

Lệnh **xếp hàng** từ staging lên kệ thật.

| Field (item) | Ý nghĩa |
|---|---|
| `shelfId` | Vị trí chỉ định xếp vào |
| `lotId` | Lô được xếp (null nếu không theo lô) |

> Hoàn tất PutAway sinh **2 bút toán** cùng `refId`: `PUTAWAY −qty` (shelf staging) + `PUTAWAY +qty` (shelf thật). `onHand` không đổi (net=0), nhưng `inventory_stocks` chuyển từ staging sang vị trí thật.

## Quy đổi đơn vị (UoM) — xuyên suốt nhập

PO/GRN có thể nhập theo **đơn vị phụ** (thùng, bao). Khi cộng/trừ tồn, hệ **luôn quy về đơn vị cơ sở**: `baseQty = qty × factor`. `stock_balances`/`inventory_stocks`/`stock_movements` đều theo đơn vị cơ sở. → Nhập "2 thùng" (factor 50) thành `onHand += 100 cái`.

## Ví dụ

```
PO: đặt NCC 2 thùng ly (1 thùng=50) → expectedQty 2 thùng
GRN: nhận thực 2 thùng, lotNumber L240601, HSD 2025-06-01
     → tạo Lot L240601; onHand += 100 (staging); movement RECEIVE +100
PutAway: xếp 100 lên A1-T2
     → movement PUTAWAY −100 (staging) + PUTAWAY +100 (A1-T2)
     → inventory_stocks: {A1-T2, lot L240601, qty 100}
```

---

← [02 — Hàng hóa & tồn kho](02-hang-hoa-va-ton-kho.md) · → [04 — In ly](04-in-ly.md)
