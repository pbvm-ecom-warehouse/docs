# 06 — Supplier (Nhà cung cấp)

> Bảng: `suppliers`, `supplier_items` · Schema gốc: [supplier/data-model](../supplier/data-model.md)

Module nhỏ trong `wms_db`: quản lý NCC và **bảng giá nhập**. Không bán trên Ecom → không sync sang `ecom_db`.

## suppliers

| Field | Ý nghĩa |
|---|---|
| `code` | Mã NCC (unique) |
| `status` | `ACTIVE` / `INACTIVE` / `BLACKLIST` |
| taxCode, contactName, phone, email… | Thông tin liên hệ |

> **`status` thay cho `isActive` boolean cũ:** chỉ NCC `ACTIVE` mới qua được guard tạo PO (`DRAFT→CONFIRMED`). `BLACKLIST` = NCC bị cấm hợp tác.

## supplier_items — bảng giá nhập

**Hồ sơ mua hàng: 1 SKU ↔ 1 NCC chính.**

| Field | Ý nghĩa |
|---|---|
| `itemId` | **unique** — WarehouseItem (SKU). Mỗi SKU chỉ 1 dòng |
| `supplierId` | NCC chính của SKU đó |
| `supplierItemCode` | Mã hàng phía NCC (đối chiếu `warehouse_items.altBarcodes`) |
| `purchasePrice` | Giá nhập gợi ý → mặc định cho `purchase_order_items.unitPrice` |
| `leadTimeDays` | Thời gian giao dự kiến |
| `minOrderQty` | Số lượng đặt tối thiểu (MOQ) |
| `isActive` | Báo giá còn hiệu lực? `false` → không gợi ý khi tạo PO |

## Vì sao `itemId` unique (1 SKU ↔ 1 NCC)?

Đơn giản hóa v1: mỗi mặt hàng có **một nguồn cung chính**. Đổi NCC = **cập nhật dòng hiện có**, không thêm dòng mới.

> **Đường nâng cấp đa-NCC** (chưa làm): bỏ ràng buộc unique `itemId` + thêm cờ `isPrimary`. Khi đó 1 SKU có nhiều báo giá từ nhiều NCC, chọn 1 cái primary.

## Liên kết

`supplier_items` là **cầu nối giá** giữa danh mục hàng (`warehouse_items`) và đơn đặt (`purchase_orders`):

```
warehouse_items ──1:1──► supplier_items ──N:1──► suppliers
   (SKU)                  (giá nhập)              (NCC)
        purchasePrice gợi ý ──► purchase_order_items.unitPrice
```

---

← [05 — Xuất kho & nội bộ](05-xuat-kho-va-noi-bo.md) · → [07 — Shipping](07-shipping.md)
