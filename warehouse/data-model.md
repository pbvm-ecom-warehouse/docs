# WMS — Data Model

> Trạng thái: 🔄 Đang phân tích — có thể còn điều chỉnh

## Nhóm 1: Cấu trúc kho & vị trí

```
Warehouse → Zone → Rack → Shelf
```

### Warehouse (Kho)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| name | String | Tên kho |
| type | Enum | `CENTRAL` / `SUB` |
| address | String | Địa chỉ |
| isActive | Boolean | |

### Zone (Khu vực trong kho)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| warehouseId | ObjectId | Thuộc kho nào |
| name | String | Tên khu vực |
| code | String | Mã khu (A, B, C...) |

### Rack (Kệ trong zone)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| zoneId | ObjectId | Thuộc zone nào |
| name | String | Tên kệ |
| code | String | Mã kệ (A1, B2...) |

### Shelf (Tầng trong rack)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| rackId | ObjectId | Thuộc rack nào |
| level | Number | Số tầng (1, 2, 3...) |
| code | String | Mã tầng |

---

## Nhóm 2: Hàng hóa

> **Ownership:** WMS chỉ giữ phần *vật lý* của hàng hóa (`warehouse_items`): SKU, đơn vị, loại, thuộc tính, vị trí, tồn. Phần *bán hàng* (tên hiển thị, ảnh, **giá**, danh mục) thuộc Ecommerce (`products`/`product_variants`). Hai bên nối nhau **chỉ qua `sku`** — xem [data-ownership.md](../overview/data-ownership.md).

### WarehouseItem (Hàng trong kho — đơn vị lưu kho)

> Mỗi WarehouseItem = **1 SKU duy nhất** = đơn vị đếm tồn. Biến thể (size/màu...) là các SKU khác nhau → các WarehouseItem khác nhau. Thuộc tính lưu linh động (key-value), thêm thuộc tính mới không cần sửa schema. **Không có giá** (giá là của Ecommerce).

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| sku | String | **Mã SKU (unique, required)** — khóa định danh & liên kết với Ecommerce |
| name | String | Tên nội bộ (VD: Ly nhựa 500ml Đỏ) |
| type | Enum | `MATERIAL` / `CUP_BLANK` / `CUP_PRINTED` / `PACKAGING` |
| unit | String | Đơn vị tính (kg, lít, cái, thùng, cuộn...) |
| attributes | Array | Danh sách thuộc tính: `[{ name, value, code }]` |
| isActive | Boolean | |

**attributes[]** — mỗi phần tử:

| Field | Type | Mô tả |
|---|---|---|
| name | String | Tên thuộc tính (vd `ML`, `Màu`) |
| value | String | Giá trị hiển thị, có dấu (vd `500ml`, `Đỏ`) |
| code | String | Mã ngắn ASCII để ghép SKU (vd `500`, `RED`) |

**Quy ước sinh SKU (tự gợi ý + sửa được):**

- Gợi ý: `{tiền tố}-{các attribute.code ghép lại}` → vd `CUP-PLA-500-RED`. Tiền tố nhập tay hoặc suy từ `type`/nhóm.
- Ghép theo `code` (không dùng `value` để tránh dấu/khoảng trắng), theo **đúng thứ tự** phần tử trong `attributes[]`.
- Thiếu `code` → fallback slugify `value` (bỏ dấu, HOA, thay khoảng trắng bằng `-`).
- Chuẩn hoá: HOA toàn bộ, chỉ gồm `[A-Z0-9-]`.
- Cho **sửa tay** trước khi lưu; khi lưu **validate unique** toàn hệ thống.

---

## Nhóm 3: Tồn kho

### InventoryStock (Tồn kho theo vị trí)

> Một WarehouseItem có thể nằm ở nhiều shelf khác nhau, hoặc ở nhiều kho khác nhau.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| itemId | ObjectId | WarehouseItem (SKU) |
| warehouseId | ObjectId | Kho chứa |
| shelfId | ObjectId | Vị trí shelf cụ thể |
| quantity | Number | Số lượng hiện tại |
| minQuantity | Number | Ngưỡng cảnh báo tồn thấp |

---

## Nhóm 4: Giao dịch kho

### PurchaseOrder (Đơn đặt hàng NCC — UC-01)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| supplierId | ObjectId | Nhà cung cấp |
| warehouseId | ObjectId | Kho nhận hàng |
| orderDate | DateTime | |
| expectedDate | DateTime | Ngày dự kiến nhận |
| status | Enum | `DRAFT` / `CONFIRMED` / `SENT` / `PARTIALLY_RECEIVED` / `COMPLETED` / `CANCELLED` |
| note | String | |
| createdBy | ObjectId | User tạo |

### PurchaseOrderItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| purchaseOrderId | ObjectId | |
| itemId | ObjectId | |
| expectedQty | Number | Số lượng đặt |
| unit | String | |
| unitPrice | Number | Giá đặt |

---

### GoodsReceiveNote (Phiếu nhập kho — UC-02)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| purchaseOrderId | ObjectId | Tham chiếu PO |
| warehouseId | ObjectId | Kho nhận |
| receiveDate | DateTime | |
| status | Enum | `DRAFT` / `CONFIRMED` / `APPROVED` |
| note | String | |
| createdBy | ObjectId | RECEIVER |
| approvedBy | ObjectId | MANAGER |

### GoodsReceiveItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| grnId | ObjectId | |
| itemId | ObjectId | |
| expectedQty | Number | Số lượng theo PO |
| actualQty | Number | Số lượng thực tế nhận |
| unit | String | |
| note | String | Ghi chú nếu lệch |

---

### PutAwayTask (Lệnh sắp xếp — UC-03)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| grnId | ObjectId | Từ GRN nào |
| warehouseId | ObjectId | |
| status | Enum | `PENDING` / `COMPLETED` |
| createdBy | ObjectId | RECEIVER |

### PutAwayItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| putAwayTaskId | ObjectId | |
| itemId | ObjectId | |
| quantity | Number | |
| shelfId | ObjectId | Vị trí chỉ định |

---

### PrintJob (Lệnh in ly — UC-04)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| orderId | ObjectId | Đơn hàng tham chiếu |
| warehouseId | ObjectId | |
| designFile | String | File design/logo |
| status | Enum | `PENDING` / `IN_PROGRESS` / `COMPLETED` / `CANCELLED` |
| note | String | |
| createdBy | ObjectId | MANAGER (tạo lệnh in) |
| confirmedBy | ObjectId | PRINTER (xác nhận in xong, nhập CUP_PRINTED) |

### PrintJobItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| printJobId | ObjectId | |
| inputItemId | ObjectId | WarehouseItem CUP_BLANK đầu vào |
| outputItemId | ObjectId | WarehouseItem CUP_PRINTED đầu ra |
| quantity | Number | |

---

### GoodsIssue (Phiếu xuất kho — UC-05)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| orderId | ObjectId | Đơn hàng |
| warehouseId | ObjectId | Kho xuất |
| issueDate | DateTime | |
| status | Enum | `DRAFT` / `CONFIRMED` |
| note | String | |
| createdBy | ObjectId | PICKER |

### GoodsIssueItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| goodsIssueId | ObjectId | |
| itemId | ObjectId | |
| quantity | Number | |
| shelfId | ObjectId | Lấy từ shelf nào |
| unit | String | |

---

### StockCount (Phiếu kiểm kho — UC-06)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| warehouseId | ObjectId | |
| zoneId | ObjectId | Phạm vi kiểm (null = toàn kho) |
| countDate | DateTime | |
| status | Enum | `DRAFT` / `IN_PROGRESS` / `COMPLETED` / `APPROVED` |
| note | String | |
| createdBy | ObjectId | MANAGER (tạo phiếu) |
| countedBy | ObjectId | COUNTER (kiểm đếm thực tế) |
| approvedBy | ObjectId | MANAGER (duyệt điều chỉnh) |

### StockCountItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| stockCountId | ObjectId | |
| itemId | ObjectId | |
| shelfId | ObjectId | |
| systemQty | Number | Tồn theo hệ thống |
| actualQty | Number | Tồn thực tế đếm được |
| delta | Number | Chênh lệch (actualQty - systemQty) |
| reason | String | Lý do chênh lệch |

---

### StockTransfer (Lệnh chuyển kho — UC-07)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| fromWarehouseId | ObjectId | Kho nguồn |
| toWarehouseId | ObjectId | Kho đích |
| transferDate | DateTime | |
| status | Enum | `DRAFT` / `CONFIRMED` / `IN_TRANSIT` / `COMPLETED` / `CANCELLED` |
| note | String | |
| createdBy | ObjectId | MANAGER |
| approvedBy | ObjectId | MANAGER |

### StockTransferItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| stockTransferId | ObjectId | |
| itemId | ObjectId | |
| quantity | Number | |
| fromShelfId | ObjectId | Lấy từ shelf nào |
| toShelfId | ObjectId | Đặt vào shelf nào tại kho đích |
