# 02 — Hàng hóa & tồn kho 2 lớp

> Bảng: `warehouse_items`, `stock_balances`, `inventory_stocks`, `lots`, `stock_movements` · Schema gốc: [warehouse/data-model — Nhóm 2 & 3](../warehouse/data-model.md#nhóm-2-hàng-hóa)

Đây là **trái tim của WMS**. Hiểu cụm này là hiểu 60% hệ thống.

## warehouse_items — định nghĩa 1 SKU

Mỗi dòng = **1 SKU = 1 đơn vị đếm tồn**. Biến thể (size/màu) là **các SKU khác nhau** → các dòng khác nhau.

| Field | Ý nghĩa |
|---|---|
| `sku` | **Khóa định danh & liên kết Ecommerce** (unique). Quét barcode ra → tra item |
| `type` | `MATERIAL` (nguyên liệu) / `CUP_BLANK` (ly trắng) / `CUP_PRINTED` (ly đã in) / `PACKAGING` |
| `unit` | **Đơn vị cơ sở** — tồn luôn đếm theo đơn vị này (cái, kg, lít) |
| `altUnits` | Đơn vị phụ + hệ số: `{thùng, 50}` = 1 thùng = 50 cái |
| `attributes[]` | `{name, value, code}` linh động — thêm thuộc tính không cần sửa schema |
| `isPerishable` | Có theo dõi lô/hạn dùng không (mặc định `true` nếu MATERIAL) |

> **Không có `price`** — giá là của Ecommerce. WMS chỉ giữ phần *vật lý*.

## Tồn kho 2 lớp — vì sao cần cả hai?

```
                onHand = 200
stock_balances ────────────────────────► dùng để CHỐNG OVERSELL + SYNC Ecom
(lớp 1: SKU+kho)   reserved=30, expired=0     available = 200−30−0 = 170

inventory_stocks ──────────────────────► dùng để PICKER ĐI LẤY HÀNG THẬT
(lớp 2: shelf+lô)  A1-T2:120 + A1-T3:80   Σ = 200 (khớp lớp 1)
```

- **Lớp 1 không đủ:** biết tổng 200 nhưng không biết lấy ở đâu.
- **Lớp 2 không đủ:** tính `available` để bán phải gom mọi shelf — chậm, và không có chỗ giữ `reserved`/`expired`.
- → Giữ cả hai, ràng buộc `onHand = Σ inventory_stocks.quantity` luôn đúng.

### stock_balances (lớp 1)
| Field | Ý nghĩa |
|---|---|
| `onHand` | Tổng vật lý đang có (gồm cả hàng ở staging) |
| `reserved` | Đã giữ cho đơn/print/chuyển kho, **chưa xuất** |
| `expired` | Tồn thuộc lô **đã hết hạn** — còn vật lý nhưng không bán được |
| `minQuantity` | Ngưỡng cảnh báo → phát `stock.low` khi `available < minQuantity` |

> `available = onHand − reserved − expired` — **tính khi cần, không lưu** (tránh lưu trùng dễ lệch).

### inventory_stocks (lớp 2)
Một SKU có thể nằm nhiều shelf / nhiều kho / nhiều lô → mỗi tổ hợp là 1 dòng. `lotId = null` nếu item không `isPerishable`.

### lots — chỉ cho item có hạn
| Field | Ý nghĩa |
|---|---|
| `lotNumber` | Mã lô (từ NCC hoặc hệ sinh) |
| `expiryDate` | Hạn dùng — cơ sở cho **FEFO** (xuất lô gần hết hạn trước) & cảnh báo cận hạn |
| `status` | `ACTIVE` / `EXPIRED` (job định kỳ chuyển khi tới hạn → dồn vào `expired`) |

## stock_movements — sổ cái thẻ kho (append-only)

Ghi **mọi** thay đổi tồn vật lý. **Không sửa/xóa, chỉ thêm.**

| Field | Ý nghĩa |
|---|---|
| `type` | `RECEIVE`/`PUTAWAY`/`ISSUE`/`TRANSFER_OUT`/`TRANSFER_IN`/`ADJUST`/`SCRAP`/`PRINT_CONSUME`/`PRINT_OUTPUT` |
| `quantity` | Số lượng **có dấu** (+ nhập / − xuất) |
| `refType`/`refId` | Chứng từ nguồn (GRN/GoodsIssue/StockTransfer…) → truy ngược |

> **Đối soát:** `onHand = Σ quantity` (theo item+kho). Thẻ kho 1 SKU = lọc `itemId` sắp theo `createdAt`.

> **Giao dịch đổi chỗ sinh 2 bút toán lệch dấu** (net=0 cho onHand nhưng 2 shelf đều đúng):
> - Put-away: `PUTAWAY −` shelf staging + `PUTAWAY +` shelf thật.
> - Chuyển kho: `TRANSFER_OUT −` kho nguồn + `TRANSFER_IN +` kho đích.

> ⚠️ **Reserve/release KHÔNG ghi vào sổ này** — chỉ đổi `stock_balances.reserved`, không đụng onHand/vị trí.

## Ví dụ số liệu — nhập 200 ly rồi bán 30

```
1. GRN nhận 200 → onHand 0→200 (vào shelf staging) | movement: RECEIVE +200
2. PutAway xếp lên A1-T2 (120) & A1-T3 (80)         | movement: PUTAWAY −200 staging, +120, +80
3. Khách đặt 30 → reserved 0→30 (atomic)            | KHÔNG ghi movement
   available = 200 − 30 = 170 → đẩy stock.changed cho Ecom? (xem ghi chú)
4. PICKER xuất 30 từ A1-T2 → onHand 200→170, reserved 30→0 | movement: ISSUE −30
   available vẫn 170 (đã trừ từ bước 3) → KHÔNG bắn event lần nữa
```

---

← [01 — Kho & vị trí](01-kho-va-vi-tri.md) · → [03 — Nhập kho](03-nhap-kho.md)
