# 04 — In ly (make-to-order)

> Bảng: `print_jobs`, `print_job_items` · Schema gốc: [warehouse/data-model — PrintJob](../warehouse/data-model.md#printjob-lệnh-in-ly--uc-04)

Đây là phần "đặc sản" của hệ: khách mua **ly in design riêng** — hàng **không có sẵn**, phải in theo đơn (make-to-order).

## Nguyên tắc nền

- **Mỗi mẫu in = 1 SKU `CUP_PRINTED` riêng** (per-design). VD ly nền `CUP-PLA-500-WHT` + design DSG042 → SKU mới `CUP-PLA-500-WHT-DSG042`.
- Make-to-order **bắt buộc trả-trước ONLINE** — chỉ in sau khi `payment.success` (tránh in xong khách bỏ).
- WMS chỉ cần **file artwork** để in, nhận qua event `print.requested` (không đọc `designs` của Ecom).

## print_jobs

| Field | Ý nghĩa |
|---|---|
| `orderId` | Đơn Ecom (reference id, cross-app — không join) |
| `designFile` | **Snapshot file** artwork nhận qua payload event |
| `status` | `PENDING → IN_PROGRESS → COMPLETED` (+ CANCELLED) |
| `createdBy` / `confirmedBy` | MANAGER tạo lệnh / PRINTER xác nhận in xong |

## print_job_items

| Field | Ý nghĩa |
|---|---|
| `inputItemId` | WarehouseItem **CUP_BLANK** đầu vào (ly trắng) |
| `outputItemId` | WarehouseItem **CUP_PRINTED** đầu ra (ly đã in, SKU riêng) |
| `quantity` | Số lượng |

## Chuỗi giữ tồn (hold) blank → printed

Đây là chỗ tinh tế nhất — theo dõi kỹ:

```
1. Tạo PrintJob (PENDING) từ đơn
   → giữ CUP_BLANK: reserved += qty  (chính là hold của đơn, KHÔNG reserve 2 lần)

2. Bắt đầu in (IN_PROGRESS) → tiêu thụ ly trắng THẬT
   → CUP_BLANK: onHand −= qty, reserved −= qty   | movement PRINT_CONSUME −

3. In xong (COMPLETED) → ly in nhập kho NHƯNG giữ cho đúng đơn
   → CUP_PRINTED: onHand += qty AND reserved += qty | movement PRINT_OUTPUT +
   → available của CUP_PRINTED KHÔNG đổi → KHÔNG bắn stock.changed
   → phát print.completed cho Ecom (set OrderItem.printJobId)

4. UC-05 xuất CUP_PRINTED đã reserve như hàng thường
```

> **Vì sao bước 3 vừa `onHand+=` vừa `reserved+=`?** Ly in ra là dành riêng cho đơn đó, **không phải hàng bán chung**. Nếu chỉ `onHand+=` thì `available` tăng → Ecom tưởng có hàng bán → sai. Giữ luôn `reserved` để `available` đứng yên.

> **Ngoại lệ — in vào kho (không gắn đơn):** không reserve → `available` printed tăng → **có** bắn `stock.changed`. Đây là khi shop in sẵn mẫu `PRINTED_TEMPLATE` để bán.

## Hủy lệnh in

| Hủy khi | Hệ quả |
|---|---|
| **Trước** khi in (PENDING) | Giải phóng `reserved` CUP_BLANK |
| **Sau** khi đã tiêu thụ | Ly trắng đã mất; ly đã in (nếu có) nhập kho bình thường, **không** tự hoàn ly trắng |

## Nối với Catalog

`product_variants.fulfillmentType`:
- `CUSTOM_PRINT` → `sku` = CUP_BLANK, cần `designId` → sinh PrintJob (bài này).
- `PRINTED_TEMPLATE` → `sku` = CUP_PRINTED in sẵn, **không** PrintJob, mua như hàng thường.

---

← [03 — Nhập kho](03-nhap-kho.md) · → [05 — Xuất kho & nội bộ](05-xuat-kho-va-noi-bo.md)
