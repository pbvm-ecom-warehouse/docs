# Catalog (Ecommerce) — Data Model

> Trạng thái: 🔄 Đang phân tích — theo spec [2026-06-04-ecommerce-catalog-module-design](../superpowers/specs/2026-06-04-ecommerce-catalog-module-design.md)

> **Ownership:** Ecommerce sở hữu `categories`/`products`/`product_variants`/`designs`. Liên kết WMS **chỉ qua `sku`**; `availableQty` là bản copy sync từ `stock.changed` — không đọc chéo collection. Xem [data-ownership](../overview/data-ownership.md).

## Nhóm 1: Danh mục

### Category (cây danh mục)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| name | String | |
| slug | String | Unique, dùng cho URL |
| parentId | ObjectId? | Null = danh mục gốc; tự tham chiếu tạo cây |
| position | Number | Thứ tự hiển thị giữa các anh em |

## Nhóm 2: Sản phẩm

### Product (entity marketing)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| name | String | Tên hiển thị |
| slug | String | Unique, URL |
| description | String | Mô tả dài |
| images | String[] | Ảnh sản phẩm |
| categoryId | ObjectId | Trỏ Category |
| status | Enum | `DRAFT` / `ACTIVE` / `HIDDEN` (chỉ `ACTIVE` hiện ra storefront) |
| seo | Object | `{ title, description, keywords }` |
| createdAt | DateTime | |
| updatedAt | DateTime | |

### ProductVariant

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| productId | ObjectId | |
| sku | String | **Khớp WMS** — khóa sync tồn |
| attributes | Object | `{ size: "M", ... }` — phân biệt biến thể |
| price | Number | Giá bán (ly-in: đã gồm phí in) |
| availableQty | Number | **Bản copy WMS sync** (`Σ available` mọi kho) |
| fulfillmentType | Enum | `STANDARD` / `PRINTED_TEMPLATE` / `CUSTOM_PRINT` |
| isActive | Boolean | Tắt biến thể không bán |

> **`fulfillmentType`:**
> - `STANDARD` — hàng sẵn (ly trắng bán nguyên, phụ kiện...). `sku` = item WMS thường, mua như hàng thường.
> - `PRINTED_TEMPLATE` — mẫu in **dựng sẵn của shop**, đã in nằm kho. `sku` = `CUP_PRINTED` per-design. Khách chọn, **không upload**; mua như hàng thường (**`isPrintItem = false`**, không cần PrintJob).
> - `CUSTOM_PRINT` — ly trắng cho khách in design riêng (make-to-order). `sku` = `CUP_BLANK`. Vào giỏ là `isPrintItem = true`, **bắt buộc** kèm `designId`/`designFile`. WMS ánh xạ design→`CUP_PRINTED` lúc in (xem [Order](../order/data-model.md) + [WMS UC-04](../warehouse/use-cases.md#uc-04-lệnh-in-ly-make-to-order)).

> `availableQty` **không xử lý riêng** theo loại: CUSTOM_PRINT phản ánh tồn ly trắng, PRINTED_TEMPLATE phản ánh tồn ly đã in — đều qua `sku`.

## Nhóm 3: Thư viện design của khách

### Design

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| customerId | ObjectId | Sở hữu — chỉ chủ thấy |
| name | String | Tên khách đặt cho design |
| file | String | File artwork gốc |
| thumbnail | String | Ảnh xem trước |
| createdAt | DateTime | |
| lastUsedAt | DateTime | Cập nhật mỗi lần dùng lại (sắp xếp "dùng gần đây") |

> Khách upload 1 lần → tái dùng nhiều đơn. Khi thêm variant `CUSTOM_PRINT` vào giỏ: **upload mới** (tạo `Design`) hoặc **chọn từ thư viện** → set `CartItem.designId` + copy `designFile`; cập nhật `Design.lastUsedAt`.

## Nhóm 4: Đồng bộ tồn (availableQty)

Catalog là **consumer** sự kiện tồn từ WMS (cơ chế chung ở [data-ownership](../overview/data-ownership.md)):

| Event | Từ → Đến | Tác động |
|---|---|---|
| `stock.changed` | WMS → Ecom | `ProductVariant.availableQty += delta` (match theo `sku`) |
| `stock.expired` | WMS → Ecom | `availableQty` giảm (lô hết hạn rời `available`) |

> Variant không có `sku` khớp item WMS → `availableQty` đứng yên (mặc định 0) → hiện "hết hàng". `availableQty âm` tạm (event lệch thứ tự) → clamp hiển thị về 0. Chốt thật ở **reserve atomic** lúc checkout (xem [Order](../order/data-model.md)).

## Liên kết module Order (`designId`)

`CartItem` và `OrderItem` (module Order) được bổ sung field **`designId?` (ObjectId)** trỏ `designs` khi `isPrintItem`. `designFile` giữ làm **snapshot** file lúc đặt (đề phòng khách xóa design khỏi thư viện sau). Chi tiết xem [Order data-model](../order/data-model.md).
