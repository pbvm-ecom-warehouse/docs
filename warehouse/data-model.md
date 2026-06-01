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

### Product (Sản phẩm / Nguyên liệu)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| name | String | Tên sản phẩm |
| sku | String | Mã SKU (unique) |
| type | Enum | `MATERIAL` / `CUP_BLANK` / `CUP_PRINTED` / `PACKAGING` |
| unit | String | Đơn vị tính (kg, lít, cái, thùng, cuộn...) |
| description | String | Mô tả |
| isActive | Boolean | |

### ProductVariant (Biến thể)

> Dùng cho ly: phân theo size, chất liệu. Dùng cho nguyên liệu: phân theo đóng gói.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| productId | ObjectId | |
| name | String | Tên biến thể (VD: Ly nhựa 500ml) |
| size | String | S / M / L / XL / 250ml / 500ml... |
| material | String | PLASTIC / PAPER / ... |
| color | String | Màu (nếu có) |
| price | Number | Giá bán |
| isActive | Boolean | |

---

## Nhóm 3: Tồn kho

### InventoryStock (Tồn kho theo vị trí)

> Một sản phẩm/biến thể có thể nằm ở nhiều shelf khác nhau, hoặc ở nhiều kho khác nhau.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| variantId | ObjectId | Biến thể sản phẩm |
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
| variantId | ObjectId | |
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
| createdBy | ObjectId | STAFF |
| approvedBy | ObjectId | MANAGER |

### GoodsReceiveItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| grnId | ObjectId | |
| variantId | ObjectId | |
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
| createdBy | ObjectId | |

### PutAwayItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| putAwayTaskId | ObjectId | |
| variantId | ObjectId | |
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
| createdBy | ObjectId | MANAGER |

### PrintJobItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| printJobId | ObjectId | |
| inputVariantId | ObjectId | CUP_BLANK đầu vào |
| outputVariantId | ObjectId | CUP_PRINTED đầu ra |
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
| createdBy | ObjectId | STAFF |

### GoodsIssueItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| goodsIssueId | ObjectId | |
| variantId | ObjectId | |
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
| createdBy | ObjectId | MANAGER |
| approvedBy | ObjectId | MANAGER |

### StockCountItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| stockCountId | ObjectId | |
| variantId | ObjectId | |
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
| variantId | ObjectId | |
| quantity | Number | |
| fromShelfId | ObjectId | Lấy từ shelf nào |
| toShelfId | ObjectId | Đặt vào shelf nào tại kho đích |
