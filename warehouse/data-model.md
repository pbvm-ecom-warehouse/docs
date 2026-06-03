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
| code | String | Mã tầng — **giá trị barcode vị trí** (dán tem ở mỗi shelf, quét khi put-away/pick) |
| isStaging | Boolean | `true` = shelf "khu nhận hàng" (mỗi kho có 1), nơi hàng nằm tạm sau GRN trước khi put-away |

---

## Nhóm 2: Hàng hóa

> **Ownership:** WMS chỉ giữ phần *vật lý* của hàng hóa (`warehouse_items`): SKU, đơn vị, loại, thuộc tính, vị trí, tồn. Phần *bán hàng* (tên hiển thị, ảnh, **giá**, danh mục) thuộc Ecommerce (`products`/`product_variants`). Hai bên nối nhau **chỉ qua `sku`** — xem [data-ownership.md](../overview/data-ownership.md).

### WarehouseItem (Hàng trong kho — đơn vị lưu kho)

> Mỗi WarehouseItem = **1 SKU duy nhất** = đơn vị đếm tồn. Biến thể (size/màu...) là các SKU khác nhau → các WarehouseItem khác nhau. Thuộc tính lưu linh động (key-value), thêm thuộc tính mới không cần sửa schema. **Không có giá** (giá là của Ecommerce).

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| sku | String | **Mã SKU (unique, required)** — khóa định danh & liên kết với Ecommerce |
| barcode | String | Giá trị tem in cho SKU (Code128/QR). Mặc định **= `sku`**; quét ra → tra item |
| altBarcodes | String[] | Mã NCC/nhà sản xuất (EAN/UPC sẵn trên hàng) map về cùng item |
| name | String | Tên nội bộ (VD: Ly nhựa 500ml Đỏ) |
| type | Enum | `MATERIAL` / `CUP_BLANK` / `CUP_PRINTED` / `PACKAGING` |
| unit | String | **Đơn vị cơ sở** — tồn kho luôn lưu & đếm theo đơn vị này (cái, kg, lít...) |
| altUnits | Array | Đơn vị phụ + hệ số quy đổi: `[{ unit, factor }]` — vd `{thùng, 50}` = 1 thùng = 50 cái |
| attributes | Array | Danh sách thuộc tính: `[{ name, value, code }]` |
| isPerishable | Boolean | Theo dõi lô/hạn dùng? Mặc định `true` nếu `type = MATERIAL` |
| nearExpiryDays | Number | Báo cận hạn trước bao nhiêu ngày (vd 7) — chỉ dùng khi `isPerishable` |
| isActive | Boolean | |

> **Định danh vật lý:** quét `barcode` (hoặc `altBarcodes`) → tra ra đúng `WarehouseItem`. Quét mã chưa có trong hệ → **chặn**, yêu cầu khai báo item trước (không cho tồn kho "mồ côi").

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

## Nhóm 3: Tồn kho — 2 lớp

> Tồn kho tách **2 lớp** với bất biến luôn đúng:
> ```
> StockBalance.onHand (lớp 1)  =  Σ InventoryStock.quantity mọi shelf của kho đó (lớp 2, gồm staging)
> available                    =  onHand − reserved − expired
> ```
> Mọi thay đổi tồn cập nhật **cả 2 lớp trong cùng transaction**.

### StockBalance (Lớp 1 — tồn tổng theo SKU + kho)

> Dùng cho **đặt/giữ hàng & chống oversell & sync Ecommerce**. `available` là số đẩy sang Ecommerce.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| itemId | ObjectId | WarehouseItem (SKU) |
| warehouseId | ObjectId | Kho |
| onHand | Number | Tổng vật lý đang có (gồm cả hàng chưa put-away ở staging) |
| reserved | Number | Đã giữ cho đơn/print job, chưa xuất |
| expired | Number | Tồn thuộc lô **đã hết hạn** — còn vật lý nhưng không bán được, chờ scrap |
| minQuantity | Number | Ngưỡng cảnh báo tồn thấp → phát `stock.low` khi `available < minQuantity` |

> `available = onHand − reserved − expired` (tính khi cần, không lưu trùng).
>
> **Edge case — không để `available` âm:** một lô đang được tính trong `reserved` mà hết hạn (job chuyển sang `expired`) có thể làm `reserved + expired > onHand`. Khi job đánh dấu lô `EXPIRED`, nếu phần `onHand` còn lại không đủ phủ `reserved`, hệ **giải phóng bớt `reserved`** của các đơn chưa xuất tương ứng (đơn rơi về trạng thái chờ tồn) — đảm bảo `available ≥ 0`.

### InventoryStock (Lớp 2 — tồn theo vị trí)

> Cho biết hàng **nằm shelf nào** để cất/lấy thực tế. Một WarehouseItem có thể nằm ở nhiều shelf / nhiều kho. Shelf `isStaging` chứa hàng vừa nhận, chưa put-away.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| itemId | ObjectId | WarehouseItem (SKU) |
| warehouseId | ObjectId | Kho chứa |
| shelfId | ObjectId | Vị trí shelf cụ thể (gồm cả shelf staging) |
| lotId | ObjectId | Lô hàng — **null** nếu item không `isPerishable` |
| quantity | Number | Số lượng tại shelf + lô này |

### Lot (Lô hàng — chỉ cho item `isPerishable`)

> Mỗi lô = một đợt hàng có cùng hạn dùng. Tồn theo lô nằm ở lớp 2 (`InventoryStock.lotId`); lớp 1 (`StockBalance`) chỉ tính tổng, không theo lô.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| itemId | ObjectId | WarehouseItem |
| lotNumber | String | Mã lô (từ NCC hoặc hệ sinh) — unique theo `itemId` |
| expiryDate | Date | Hạn dùng — cơ sở cho FEFO & cảnh báo |
| receivedDate | Date | Ngày nhập lô |
| status | Enum | `ACTIVE` / `EXPIRED` *(job định kỳ chuyển khi tới hạn)* |

### StockMovement (Sổ cái di chuyển — thẻ kho)

> **Append-only.** Ghi **mọi** thay đổi tồn vật lý (onHand & vị trí) — là **nguồn sự thật** để đối soát 2 lớp tồn, truy vết khi lệch, và sinh thẻ kho/báo cáo. Không sửa/xóa, chỉ thêm.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| itemId | ObjectId | WarehouseItem (SKU) |
| warehouseId | ObjectId | Kho |
| shelfId | ObjectId | Vị trí shelf của bút toán (mọi `type` đều gắn shelf). *(Reserve/release KHÔNG ghi vào sổ này — chỉ đổi `StockBalance.reserved`, không đổi onHand/vị trí)* |
| lotId | ObjectId | Lô (null nếu không theo lô) |
| type | Enum | `RECEIVE` / `PUTAWAY` / `ISSUE` / `TRANSFER_OUT` / `TRANSFER_IN` / `ADJUST` / `SCRAP` / `PRINT_CONSUME` / `PRINT_OUTPUT` |
| quantity | Number | Số lượng **có dấu** (+ nhập / − xuất) |
| refType | String | Loại chứng từ nguồn: `GRN` / `PutAway` / `GoodsIssue` / `StockTransfer` / `StockCount` / `ScrapNote` / `PrintJob` / `GoodsReturn` |
| refId | ObjectId | ID chứng từ nguồn |
| createdBy | ObjectId | Người thao tác |
| createdAt | DateTime | Thời điểm (bất biến) |

> Đối soát: `StockBalance.onHand = Σ StockMovement.quantity` (theo item+kho, các type ảnh hưởng onHand). Thẻ kho 1 SKU = lọc theo `itemId` sắp xếp `createdAt`.

> **Giao dịch đổi chỗ sinh 2 bút toán** (cùng `refId`, lệch dấu — đối soát onHand net = 0, nhưng InventoryStock 2 shelf đều đúng):
> - **Put-away:** `PUTAWAY −qty` tại shelf staging + `PUTAWAY +qty` tại shelf thật.
> - **Chuyển kho:** `TRANSFER_OUT −qty` (shelf kho nguồn) + `TRANSFER_IN +qty` (shelf kho đích).
> Đối soát **lớp 2** theo từng shelf: `InventoryStock.quantity = Σ StockMovement.quantity` lọc theo `itemId + shelfId (+ lotId)`.

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
| expectedQty | Number | Số lượng đặt (theo `unit` dưới đây) |
| unit | String | Đơn vị đặt — có thể là đơn vị phụ (vd `thùng`); hệ quy về cơ sở bằng `altUnits.factor` |
| unitPrice | Number | Giá đặt |

> **Quy đổi đơn vị (UoM):** PO/GRN có thể nhập theo đơn vị phụ (thùng, bao...). Khi cộng/trừ tồn, hệ **luôn quy về đơn vị cơ sở**: `baseQty = qty × factor`. `StockBalance`, `InventoryStock`, `StockMovement` đều theo đơn vị cơ sở.

> **Trạng thái PO do GRN cập nhật:** mỗi GRN `CONFIRMED` cộng dồn `actualQty` vào số đã nhận của từng dòng PO. Hệ tự chuyển PO: còn thiếu → `PARTIALLY_RECEIVED`; nhận đủ mọi dòng → `COMPLETED`. PO không tự chuyển 2 trạng thái này (luôn theo GRN).

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
| unit | String | Đơn vị nhập (có thể là đơn vị phụ → quy về cơ sở) |
| lotNumber | String | Mã lô (nếu `isPerishable`) → hệ tạo `Lot` |
| expiryDate | Date | Hạn dùng (nếu `isPerishable`) |
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
| lotId | ObjectId | Lô được xếp (null nếu không `isPerishable`) |
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
| outputItemId | ObjectId | WarehouseItem CUP_PRINTED đầu ra — **mỗi design = 1 SKU riêng** (per-design) |
| quantity | Number | |

> **CUP_PRINTED per-design:** mỗi mẫu in là một `WarehouseItem` CUP_PRINTED riêng (SKU riêng), tồn kho theo từng design. SKU sinh từ ly nền + mã design (vd `CUP-PLA-500-WHT-DSG042`). Khi tạo lệnh in cho design chưa có item → hệ tạo item CUP_PRINTED mới + sinh/in tem barcode.

> **Reserve & hủy lệnh in:**
> - Khi tạo PrintJob (PENDING) → **giữ (`reserved`) CUP_BLANK đầu vào** để 2 lệnh in không tranh nhau ly trắng. Khi in (`IN_PROGRESS`) → tiêu thụ thật: `CUP_BLANK onHand−=, reserved−=` (`PRINT_CONSUME`); in xong → `CUP_PRINTED onHand+=` (`PRINT_OUTPUT`).
> - `CANCELLED` **trước** khi in → giải phóng `reserved` CUP_BLANK. `CANCELLED` **sau** khi đã tiêu thụ → ly trắng đã mất; ly đã in (nếu có) nhập kho bình thường, không tự hoàn ly trắng.

---

### GoodsIssue (Phiếu xuất kho — UC-05)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| orderId | ObjectId | Đơn hàng |
| warehouseId | ObjectId | Kho xuất — **phải = kho đã giữ tồn lúc chốt đơn** (`order.fulfillWarehouseId`, xem [data-ownership](../overview/data-ownership.md#phân-bổ-kho-khi-chốt-đơn-1-kho-đơn--chưa-split)) |
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
| lotId | ObjectId | Lô được lấy theo FEFO (null nếu không `isPerishable`) |
| quantity | Number | |
| shelfId | ObjectId | Lấy từ shelf nào |
| unit | String | Đơn vị cơ sở |

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
| lotId | ObjectId | Lô được đếm (null nếu không `isPerishable`) |
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
| lotId | ObjectId | Lô được chuyển (null nếu không `isPerishable`) |
| quantity | Number | |
| fromShelfId | ObjectId | Lấy từ shelf nào |
| toShelfId | ObjectId | Đặt vào shelf nào tại kho đích |

---

### ScrapNote (Phiếu hủy hàng — UC-08)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| warehouseId | ObjectId | Kho |
| status | Enum | `DRAFT` / `APPROVED` / `REJECTED` |
| note | String | |
| createdBy | ObjectId | COUNTER/RECEIVER đề xuất |
| approvedBy | ObjectId | MANAGER |

### ScrapNoteItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| scrapNoteId | ObjectId | |
| itemId | ObjectId | |
| lotId | ObjectId | Lô bị hủy (null nếu không theo lô) |
| shelfId | ObjectId | Lấy giảm từ shelf nào |
| quantity | Number | |
| reason | Enum/String | Hết hạn / vỡ / ẩm mốc / khác |

---

### GoodsReturn (Phiếu hoàn hàng — UC-09)

> Khách trả hàng (RMA). RECEIVER kiểm tra → hàng tốt nhập lại kho, hàng hỏng chuyển scrap.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| orderId | ObjectId | Đơn hàng gốc (tham chiếu Ecommerce qua sku/order ref) |
| warehouseId | ObjectId | Kho nhận hàng trả |
| status | Enum | `DRAFT` / `INSPECTED` / `RESTOCKED` / `CANCELLED` |
| note | String | |
| createdBy | ObjectId | RECEIVER |

### GoodsReturnItem

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| goodsReturnId | ObjectId | |
| itemId | ObjectId | |
| quantity | Number | |
| condition | Enum | `GOOD` (nhập lại kho) / `DAMAGED` (chuyển scrap) |
| shelfId | ObjectId | Vị trí nhập lại (khi `GOOD`) |
| lotId | ObjectId | Lô (nếu `isPerishable` & còn truy được) |

---

## Nhóm 5: Nhà cung cấp & Người dùng

### Supplier (Nhà cung cấp — UC-01)

> Đích của `PurchaseOrder.supplierId`.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| name | String | Tên nhà cung cấp |
| code | String | Mã NCC (unique) |
| contactName | String | Người liên hệ |
| phone | String | |
| email | String | |
| address | String | |
| taxCode | String | Mã số thuế |
| isActive | Boolean | |

### User (Nhân viên nội bộ WMS — collection `users`)

> Mang `roles[]` đã chốt. RolesGuard kiểm tra giao giữa `roles` và `@Roles(...)`.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| username | String | Đăng nhập (unique) |
| passwordHash | String | Mật khẩu đã hash |
| name | String | Họ tên |
| roles | String[] | Tập role ∈ `ADMIN / MANAGER / RECEIVER / PICKER / PRINTER / COUNTER` |
| warehouseId | ObjectId | Kho mặc định (tùy chọn) |
| isActive | Boolean | |
| createdAt | DateTime | |
