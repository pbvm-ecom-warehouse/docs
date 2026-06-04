# Catalog (Ecommerce) — Use Cases

## Tổng quan

| # | Tên | Actor | Trạng thái |
|---|---|---|---|
| UC-C01 | Duyệt danh mục & sản phẩm | Khách | 🔄 Đang phân tích |
| UC-C02 | Tìm kiếm & lọc | Khách | 🔄 Đang phân tích |
| UC-C03 | Xem chi tiết & chọn biến thể | Khách | 🔄 Đang phân tích |
| UC-C04 | Quản lý thư viện design | Khách | 🔄 Đang phân tích |
| UC-C05 | Quản trị catalog (CRUD) | Admin | 🔄 Đang phân tích |
| UC-C06 | Đồng bộ availableQty từ WMS | Hệ thống | 🔄 Đang phân tích |

> **Ánh xạ UC ↔ Workflow** (số WF không trùng số UC — workflow gộp duyệt+tìm và bỏ qua phần admin):
>
> | Use-case | Workflow |
> |---|---|
> | UC-C01 Duyệt + UC-C02 Tìm kiếm | [WF-C01 Duyệt & tìm kiếm](./workflow.md#wf-c01-duyệt--tìm-kiếm) |
> | UC-C03 Xem chi tiết & chọn biến thể | [WF-C02](./workflow.md#wf-c02-chi-tiết--chọn-biến-thể) |
> | UC-C04 Thư viện design | [WF-C03](./workflow.md#wf-c03-chọnupload-design-ly-in-custom_print) |
> | UC-C05 Quản trị catalog | *(thao tác admin, chưa vẽ workflow)* |
> | UC-C06 Đồng bộ availableQty | [WF-C04](./workflow.md#wf-c04-đồng-bộ-tồn-consumer) |

---

## UC-C01: Duyệt danh mục & sản phẩm

**Actor:** Khách
**Mục đích:** Xem sản phẩm theo cây danh mục.

### Luồng chính
1. Hệ hiển thị cây `Category` (theo `parentId`, sắp theo `position`)
2. Khách chọn danh mục → list `Product` có `status = ACTIVE` thuộc `categoryId`
3. Mỗi product hiện ảnh đại diện, tên, khoảng giá (min/max `price` các variant), trạng thái còn-hàng (`Σ availableQty > 0`)

---

## UC-C02: Tìm kiếm & lọc

**Actor:** Khách
**Mục đích:** Tìm nhanh theo từ khóa và thu hẹp kết quả.

### Luồng chính
1. Khách nhập từ khóa → search text theo `Product.name`
2. Lọc thêm: `categoryId`, khoảng `price`, **còn-hàng** (`availableQty > 0`)
3. Hệ trả danh sách product `ACTIVE` khớp điều kiện *(query + index Mongo; v1 không Elasticsearch)*

---

## UC-C03: Xem chi tiết & chọn biến thể

**Actor:** Khách
**Mục đích:** Xem 1 sản phẩm và chọn variant để mua.

### Luồng chính
1. Khách mở chi tiết `Product` (ảnh, mô tả, SEO) → danh sách `ProductVariant` `isActive`
2. Chọn variant theo `attributes` (vd size) → hiển thị `price`, `availableQty`
3. Phân nhánh theo `fulfillmentType`:
   - `STANDARD` / `PRINTED_TEMPLATE` → "Thêm vào giỏ" như hàng thường (`isPrintItem = false`)
   - `CUSTOM_PRINT` → yêu cầu design trước khi thêm giỏ → chuyển [UC-C04](#uc-c04-quản-lý-thư-viện-design)
4. Hết hàng (`availableQty = 0`) → chặn thêm giỏ, hiện cảnh báo

---

## UC-C04: Quản lý thư viện design

**Actor:** Khách
**Mục đích:** Upload / chọn lại / xóa design dùng cho ly-in.

### Luồng chính
1. Với variant `CUSTOM_PRINT`, khách chọn 1 trong 2:
   - **Upload mới:** validate kỹ thuật (định dạng/kích thước) → tạo `Design{customerId, name, file, thumbnail}`
   - **Chọn lại:** chọn từ thư viện `designs` của mình (sắp theo `lastUsedAt`)
2. Thêm vào giỏ → set `CartItem{ sku(blank), isPrintItem = true, designId, designFile }`; cập nhật `Design.lastUsedAt`
3. Khách có thể **xóa** design khỏi thư viện *(đơn cũ vẫn an toàn nhờ `OrderItem.designFile` snapshot; `designId` thành dangling — chỉ mất nút reuse)*

---

## UC-C05: Quản trị catalog (CRUD)

**Actor:** Admin
**Mục đích:** Tạo/sửa danh mục, sản phẩm, biến thể. *(Mức use-case — chi tiết phân quyền/UI quản trị để module sau.)*

### Luồng chính
1. Tạo/sửa `Category` (gắn `parentId`, `position`)
2. Tạo `Product` (gắn `categoryId`, ảnh, `seo`); mặc định `status = DRAFT`
3. Tạo `ProductVariant`: gắn `sku` **khớp WMS**, set `price`, `fulfillmentType`, `attributes`
4. Chuyển `Product.status = ACTIVE` để lên kệ; `HIDDEN` để ẩn tạm

---

## UC-C06: Đồng bộ availableQty từ WMS

**Actor:** Hệ thống (consumer event)
**Trigger:** Sự kiện `stock.changed` / `stock.expired` từ WMS.

### Luồng chính
1. Worker nhận event `{ sku, delta }` (hoặc giảm do `stock.expired`)
2. Tìm `ProductVariant` theo `sku` → `availableQty += delta`
3. Variant không khớp `sku` → bỏ qua *(sản phẩm chưa gắn kho)*
4. `availableQty` âm tạm (event lệch thứ tự) → clamp hiển thị về 0

> Chi tiết cơ chế sync: [data-ownership](../overview/data-ownership.md#sync-tồn-kho-qua-event).

> **Lưu ý:** consumer này chỉ xử lý **đường WMS-event**. Reserve/release lúc checkout/hủy do module Order tự cập nhật `availableQty` trong transaction, không đi qua worker này.
