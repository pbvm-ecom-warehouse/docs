# Ecommerce — Thiết kế module Catalog (sản phẩm & danh mục)

> Ngày: 2026-06-04
> Trạng thái: Spec — chờ review trước khi viết plan
> Phạm vi: tài liệu module riêng `docs/catalog/` (use-cases / data-model / workflow như các module khác) + mô hình dữ liệu Ecommerce phía trưng bày (category → product → variant → design)

## Context

Module [Order (cụm mua hàng)](2026-06-04-ecommerce-order-module-design.md) đã có docs đầy đủ: cart → checkout → order → payment → fulfillment. Order **giả định có sẵn catalog**: `CartItem.sku`/`OrderItem.sku` trỏ sản phẩm, `availableQty` là bản copy WMS sync, ly-in mang `isPrintItem`/`designFile`. Nhưng phía **trưng bày sản phẩm** (cái khách duyệt trước khi cho vào giỏ) chưa có doc.

Spec này định nghĩa module **Catalog**: cây danh mục, sản phẩm/biến thể, giá/ảnh/SEO, đồng bộ tồn (`availableQty`), tìm kiếm/lọc, và — đặc thù của shop ly in — **thư viện design của khách** (upload 1 lần, tái dùng đơn sau) song song với **mẫu in dựng sẵn của shop**.

Catalog là **nền** cho Order: mọi `sku` trong cart/order đến từ `product_variants` ở đây.

## Quyết định đã chốt (qua brainstorming)

| # | Quyết định |
|---|---|
| Phạm vi v1 | Product + Variant + Pricing, Category (cây), Sync tồn `availableQty`, Search/filter tối giản. |
| Mô hình ly-in | **Một Product model + Variant gắn `fulfillmentType`** (hướng A): STANDARD / PRINTED_TEMPLATE / CUSTOM_PRINT. |
| Ly-in | Hỗ trợ **cả hai**: mẫu in dựng sẵn của shop (PRINTED_TEMPLATE) **và** khách upload design riêng trên ly trắng (CUSTOM_PRINT). |
| Thư viện design | Collection `designs` (sở hữu ecommerce, gắn `customerId`) — khách **chọn lại design cũ** của chính mình. |
| Liên kết Order | Thêm `designId?` vào `CartItem`/`OrderItem` (truy vết + reuse); `designFile` giữ làm snapshot file lúc đặt. |
| Liên kết WMS | **Chỉ qua `sku`**; `availableQty` sync từ `stock.changed`/`stock.expired` — không case riêng cho ly-in. |
| Giá ly-in | Giá đã-in nằm thẳng trên `price` của variant (gồm phí in) — **không** tách `printFee`. |
| Quản trị | CRUD catalog chỉ mô tả ở **mức use-case**; chi tiết quản trị admin để module sau. |
| Search | Query + index Mongo (name/category/price/còn-hàng). **Không** Elasticsearch (YAGNI). |

---

## 1. Ranh giới module (app `ecommerce`)

```
ecommerce/src/modules/
├── catalog/     Category, Product, ProductVariant — trưng bày, search/filter, sync availableQty
│   └── design/  Thư viện design của khách (upload, chọn lại) — sub-module của catalog
├── cart/        (đã có) — đọc variant để thêm vào giỏ
├── order/       (đã có)
└── payment/     (đã có)
```

- **Consumer tồn:** catalog là nơi nhận `stock.changed`/`stock.expired` (WMS→Ecom) → cập nhật `ProductVariant.availableQty` (cơ chế đã mô tả ở [data-ownership](../../overview/data-ownership.md)).
- Liên kết WMS **chỉ qua `sku`** — không đọc chéo `wms_db`.
- Quản trị (tạo/sửa product, gắn sku, set giá) — chỉ nêu use-case; UI/role admin để doc sau.

---

## 2. Mô hình dữ liệu

### Category (cây danh mục)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| name | String | |
| slug | String | Unique, dùng cho URL |
| parentId | ObjectId? | Null = danh mục gốc; tự tham chiếu tạo cây |
| position | Number | Thứ tự hiển thị giữa các anh em |

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
| createdAt / updatedAt | DateTime | |

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

**`fulfillmentType`:**
- `STANDARD` — hàng sẵn (ly trắng bán nguyên, phụ kiện...). `sku` = item WMS thường.
- `PRINTED_TEMPLATE` — mẫu in dựng sẵn của shop. `sku` = `CUP_PRINTED` per-design (đã tồn tại WMS). Khách chọn, **không upload**.
- `CUSTOM_PRINT` — ly trắng cho khách in design riêng. `sku` = `CUP_BLANK`. Là `isPrintItem` ở Order; bắt buộc kèm `designId`/`designFile` khi vào giỏ. (Make-to-order: reserve trên blank, WMS ánh xạ design→CUP_PRINTED lúc in — xem Order spec.)

> `availableQty` **không cần xử lý riêng** theo loại: CUSTOM_PRINT phản ánh tồn ly trắng, PRINTED_TEMPLATE phản ánh tồn ly đã in — đều qua `sku`.

### Design (thư viện design của khách)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| customerId | ObjectId | Sở hữu — chỉ chủ thấy |
| name | String | Tên khách đặt cho design |
| file | String | File artwork gốc |
| thumbnail | String | Ảnh xem trước |
| createdAt | DateTime | |
| lastUsedAt | DateTime | Cập nhật mỗi lần dùng lại (sắp xếp "dùng gần đây") |

> Upload 1 lần → tái dùng nhiều đơn. Khi khách thêm variant `CUSTOM_PRINT` vào giỏ: **upload mới** (tạo `Design`) hoặc **chọn từ thư viện** → set `CartItem.designId` + copy `designFile`.

### Chỉnh nhỏ module Order (liên kết design)

Thêm vào `CartItem` và `OrderItem`:

| Field | Type | Mô tả |
|---|---|---|
| designId | ObjectId? | Trỏ `designs` (khi `isPrintItem`) — truy vết & reuse |

`designFile` **giữ nguyên** làm snapshot file lúc đặt (đề phòng khách xóa design khỏi thư viện sau).

---

## 3. Đồng bộ tồn (availableQty)

Catalog là **consumer** của sự kiện tồn từ WMS — cơ chế đã có ở [data-ownership](../../overview/data-ownership.md):

| Event | Từ → Đến | Tác động catalog |
|---|---|---|
| `stock.changed` | WMS → Ecom | `ProductVariant.availableQty += delta` (match theo `sku`) |
| `stock.expired` | WMS → Ecom | `availableQty` giảm (lô hết hạn rời `available`) |

- Variant không có `sku` khớp item WMS nào → `availableQty` đứng yên (vd sản phẩm draft chưa gắn kho).
- Hiển thị: `availableQty > 0` = còn hàng; `= 0` = hết (vẫn hiện nhưng chặn thêm giỏ / cảnh báo). Chốt thật ở **reserve atomic** lúc checkout (Order spec).

---

## 4. Luồng nghiệp vụ

### Duyệt & tìm
```
Category tree → list Product status=ACTIVE (lọc categoryId)
   → search text theo name + lọc price range + còn-hàng (availableQty>0)
   → chi tiết Product → chọn ProductVariant
```

### Thêm ly-in vào giỏ (CUSTOM_PRINT)
```
Chọn variant CUSTOM_PRINT
   → khách: [upload design mới → tạo Design] HOẶC [chọn từ thư viện designs của mình]
   → set CartItem{ sku(blank), isPrintItem=true, designId, designFile }
   → cập nhật Design.lastUsedAt
   → (tiếp luồng checkout Order: gate bắt buộc ONLINE trả-trước)
```

### Thêm mẫu shop / hàng sẵn vào giỏ
```
Chọn variant PRINTED_TEMPLATE | STANDARD
   → CartItem{ sku, isPrintItem=(template? vẫn false — đã in sẵn, mua như hàng thường) }
```

> **Lưu ý ngữ nghĩa:** PRINTED_TEMPLATE là ly **đã in sẵn nằm kho** → mua như hàng thường (`isPrintItem=false`, không cần PrintJob). Chỉ `CUSTOM_PRINT` mới là make-to-order (`isPrintItem=true`).

### Quản trị (mức use-case, không chi tiết)
```
Admin tạo Category → tạo Product (gắn categoryId, ảnh, SEO)
   → tạo ProductVariant (gắn sku khớp WMS, set price, fulfillmentType)
   → status DRAFT → ACTIVE để lên kệ
```

---

## 5. Use cases dự kiến (chi tiết hóa khi viết docs)

| # | Tên | Actor |
|---|---|---|
| UC-C01 | Duyệt danh mục & sản phẩm | Khách |
| UC-C02 | Tìm kiếm & lọc | Khách |
| UC-C03 | Xem chi tiết & chọn biến thể | Khách |
| UC-C04 | Quản lý thư viện design (upload/chọn lại/xóa) | Khách |
| UC-C05 | Quản trị catalog (CRUD product/variant/category) | Admin (mức use-case) |
| UC-C06 | Đồng bộ availableQty từ WMS | Hệ thống (consumer event) |

---

## 6. Edge cases

1. **Variant chưa gắn sku / sku không có ở WMS** → `availableQty` đứng yên (mặc định 0) → hiện "hết hàng"; chặn thêm giỏ.
2. **Khách xóa Design đang được tham chiếu bởi đơn cũ** → đơn vẫn an toàn nhờ `OrderItem.designFile` snapshot; `designId` thành dangling (chấp nhận — chỉ mất nút "reuse").
3. **Product `HIDDEN`/`DRAFT` nhưng đã nằm trong giỏ ai đó** → checkout validate lại trạng thái variant `isActive`/product `ACTIVE`; không active → báo lỗi, bỏ khỏi giỏ.
4. **availableQty âm tạm (event đến lệch thứ tự)** → clamp hiển thị về 0; nguồn thật vẫn là reserve atomic lúc checkout.
5. **Upload design quá khổ/sai định dạng** → validate ở tầng upload (kích thước/định dạng), không lưu Design lỗi.

---

## Ngoài phạm vi (YAGNI)
- **Chi tiết quản trị admin** (UI, phân quyền tạo/sửa catalog) — module/doc riêng.
- **Khuyến mãi/voucher/giá theo campaign** — Order spec đã loại; catalog chỉ giữ `price` tĩnh.
- **Đánh giá/review, gợi ý sản phẩm, wishlist.**
- **Elasticsearch / full-text nâng cao** — v1 dùng query Mongo.
- **Duyệt/kiểm duyệt nội dung design** của khách (chỉ validate kỹ thuật, không kiểm duyệt thủ công).
- **Biến thể đa trục phức tạp** (matrix size×màu×...) — `attributes` để mở nhưng v1 chủ yếu theo size.

## Verification (khi triển khai)
- Lần theo luồng duyệt→chi tiết→chọn variant→vào giỏ cho cả 3 `fulfillmentType` khớp module Order.
- Kiểm `CartItem.designId`/`designFile` set đúng khi upload mới vs chọn lại design cũ; `Design.lastUsedAt` cập nhật.
- Kiểm consumer `stock.changed` cập nhật đúng `availableQty` theo `sku` (đối chiếu data-ownership).
- Đối chiếu chỉnh `CartItem`/`OrderItem` (`designId`) với docs Order — cập nhật cho khớp.
- Search/filter trả đúng tập (name/category/price/còn-hàng) trên dữ liệu mẫu.
