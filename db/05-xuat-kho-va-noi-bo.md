# 05 — Xuất kho & nội bộ

> Bảng: `goods_issues`, `stock_counts`, `scrap_notes`, `goods_returns` (mỗi bảng + `*_items`) · Schema gốc: [warehouse/data-model — Nhóm 4](../warehouse/data-model.md#nhóm-4-giao-dịch-kho)

4 loại phiếu làm **giảm/điều chỉnh** tồn. Tất cả đều ghi vào sổ cái `stock_movements`.

## goods_issues (+items) — UC-05: Phiếu xuất

Xuất hàng cho đơn. **Trigger:** event `order.ready_to_fulfill` từ Ecom.

| Field | Ý nghĩa |
|---|---|
| `orderId` | Đơn Ecom (reference id) |
| `warehouseId` | Kho trung tâm (kho duy nhất) |
| `createdBy` | PICKER |
| item: `lotId` | Lô lấy theo **FEFO** (lô gần hết hạn trước), null nếu không `isPerishable` |
| item: `shelfId` | Lấy từ shelf nào |

> Khi xuất: `onHand −= qty`, `reserved −= qty` → `available` **không đổi** (đã trừ lúc chốt đơn) → **không bắn event**. Ghi `stock_movements: ISSUE −`. Sau đó auto-sinh `shipments`.

## stock_counts (+items) — UC-06: Kiểm kho

So tồn hệ thống vs thực tế, ra chênh lệch để điều chỉnh.

| Field | Ý nghĩa |
|---|---|
| `zoneId` | Phạm vi kiểm (null = toàn kho) |
| `status` | `DRAFT → IN_PROGRESS → COMPLETED → APPROVED` |
| `createdBy`/`countedBy`/`approvedBy` | MANAGER tạo / COUNTER đếm / MANAGER duyệt |
| item: `systemQty` vs `actualQty` → `delta` | Tồn hệ vs đếm thực → chênh lệch + `reason` |

> Duyệt điều chỉnh ghi `stock_movements: ADJUST ±delta`. Đây là cách hợp thức hóa hao hụt/dư.

## scrap_notes (+items) — UC-08: Hủy hàng

Loại bỏ hàng hỏng/hết hạn khỏi tồn.

| Field | Ý nghĩa |
|---|---|
| `status` | `DRAFT → APPROVED` / `REJECTED` |
| `createdBy`/`approvedBy` | COUNTER/RECEIVER đề xuất / MANAGER duyệt |
| item: `reason` | Hết hạn / vỡ / ẩm mốc / khác |

> Duyệt → `onHand −= qty` (và `expired −=` nếu hủy lô hết hạn), ghi `stock_movements: SCRAP −`. **SCRAP không bắn `stock.changed`** (hàng đã không bán được).

## goods_returns (+items) — UC-09: Hoàn hàng (RMA)

Khách trả hàng. RECEIVER kiểm → hàng tốt nhập lại, hàng hỏng chuyển scrap.

| Field | Ý nghĩa |
|---|---|
| `orderId` | Đơn gốc (reference id) |
| `status` | `DRAFT → INSPECTED → RESTOCKED` (+ CANCELLED) |
| item: `condition` | `GOOD` (nhập lại kho) / `DAMAGED` (chuyển scrap) |
| item: `shelfId` | Vị trí nhập lại khi `GOOD` |

> Hàng `GOOD` nhập lại → `onHand += qty` → **bắn `stock.changed`** (hàng bán lại được). Hàng `DAMAGED` → đẩy sang scrap.

## Bảng tổng — phiếu nào sinh movement gì & có bắn event không

| Phiếu | movement.type | onHand | Bắn `stock.changed`? |
|---|---|---|---|
| GoodsIssue | ISSUE − | giảm | ❌ (đã trừ lúc chốt đơn) |
| StockCount | ADJUST ± | ± | ✅ (nếu available đổi) |
| ScrapNote | SCRAP − | giảm | ❌ |
| GoodsReturn (GOOD) | RECEIVE/ADJUST + | tăng | ✅ |

---

← [04 — In ly](04-in-ly.md) · → [06 — Supplier](06-supplier.md)
