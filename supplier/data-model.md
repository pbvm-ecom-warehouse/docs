# Supplier — Data Model

> Trạng thái: 🔄 Đang phân tích
> **Ownership:** `suppliers` và `supplier_items` thuộc `wms_db`, do module **supplier** (app WMS) sở hữu. Không bán trên Ecommerce → không sync sang ecom. Xem [data-ownership](../overview/data-ownership.md).

> **Audit (chung):** `suppliers`/`supplier_items` là master → mang `createdBy`/`updatedBy`/`createdAt`/`updatedAt`/`deletedAt` theo [Quy ước Audit](../overview/data-ownership.md#quy-ước-audit-chung-mọi-collection). Bảng dưới chỉ liệt kê field nghiệp vụ.

## Supplier (Nhà cung cấp)

> Đích của `PurchaseOrder.supplierId` (xem [warehouse/data-model](../warehouse/data-model.md#purchaseorder-đơn-đặt-hàng-ncc--uc-01)). Trước đây nằm trong WMS Nhóm 5 — nay tách về module supplier.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| code | String | Mã NCC (unique) |
| name | String | Tên nhà cung cấp |
| contactName | String | Người liên hệ |
| phone | String | |
| email | String | |
| address | String | |
| taxCode | String | Mã số thuế |
| status | Enum | `ACTIVE` / `INACTIVE` / `BLACKLIST` |
| note | String | Ghi chú |
| createdAt | DateTime | |

> **Trạng thái thay cho `isActive` boolean cũ:** chỉ NCC `ACTIVE` mới qua được guard tạo PO (`DRAFT→CONFIRMED`). Vòng đời xem [WF-S01](./workflow.md#wf-s01-vòng-đời-trạng-thái-ncc).

## SupplierItem (Hồ sơ mua hàng — 1 dòng/SKU)

> Danh mục giá nhập: **1 SKU ↔ 1 NCC chính** (unique `itemId`). Đổi NCC chính = cập nhật dòng hiện có, không thêm dòng mới. *(Đường nâng cấp đa-NCC: bỏ ràng buộc unique `itemId` + thêm cờ `isPrimary` — chưa làm ở v1.)*

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| itemId | ObjectId | **unique** — WarehouseItem (SKU) |
| supplierId | ObjectId | NCC chính |
| supplierItemCode | String | Mã hàng phía NCC (đối chiếu `WarehouseItem.altBarcodes`) |
| purchasePrice | Number | Giá nhập gợi ý (dùng làm mặc định cho `PurchaseOrderItem.unitPrice`) |
| leadTimeDays | Number | Thời gian giao dự kiến |
| minOrderQty | Number | Số lượng đặt tối thiểu (MOQ) |
| isActive | Boolean | Báo giá còn hiệu lực? `false` → không gợi ý khi tạo PO |
| updatedAt | DateTime | |
