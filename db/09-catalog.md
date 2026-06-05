# 09 — Catalog (Ecommerce)

> Bảng: `categories`, `products`, `product_variants`, `designs` · Schema gốc: [catalog/data-model](../catalog/data-model.md)

Phần **trưng bày & bán** bên `ecom_db`. Nối WMS **chỉ qua `sku`**.

## categories — cây danh mục

| Field | Ý nghĩa |
|---|---|
| `slug` | unique, dùng cho URL |
| `parentId` | **Tự tham chiếu** — null = danh mục gốc → tạo cây nhiều cấp |
| `position` | Thứ tự hiển thị giữa các anh em |

## products — entity marketing

| Field | Ý nghĩa |
|---|---|
| `name`, `description`, `images`, `seo` | Phần "đẹp" để bán |
| `categoryId` | Trỏ Category |
| `status` | `DRAFT` / `ACTIVE` / `HIDDEN` — chỉ `ACTIVE` hiện ra storefront |

> `products` **không có giá, không có tồn** — đó là việc của `product_variants`.

## product_variants — biến thể bán được (cầu nối WMS)

Đây là bảng **nối Ecom với WMS**. Mỗi biến thể = 1 `sku`.

| Field | Ý nghĩa |
|---|---|
| `productId` | Thuộc product nào |
| `sku` | **Khớp WMS** — khóa sync tồn |
| `attributes` | `{size: "M", ...}` phân biệt biến thể |
| `price` | Giá bán (ly-in: đã gồm phí in) |
| `availableQty` | **Bản copy** WMS sync (`Σ available` mọi kho) |
| `fulfillmentType` | `STANDARD` / `PRINTED_TEMPLATE` / `CUSTOM_PRINT` |

### `availableQty` là bản COPY — không phải nguồn thật

```
WMS stock_balances.available ──stock.changed──► product_variants.availableQty
       (nguồn chân lý)            (event)              (bản copy hiển thị)
```

- Ecom đọc `availableQty` của chính mình để hiển thị/validate sơ bộ → **nhanh, không phụ thuộc WMS uptime**.
- Có thể trễ (sync bất đồng bộ) → chốt thật ở **reserve atomic** lúc checkout ([bài 10](10-order.md)).
- Variant không có `sku` khớp → `availableQty = 0` → "hết hàng".

### `fulfillmentType` — 3 kiểu giao hàng

| Loại | `sku` trỏ tới | Cách mua |
|---|---|---|
| `STANDARD` | item WMS thường (ly trắng, phụ kiện) | Như hàng thường |
| `PRINTED_TEMPLATE` | `CUP_PRINTED` mẫu shop in sẵn | Như hàng thường (**không** PrintJob) |
| `CUSTOM_PRINT` | `CUP_BLANK` | Make-to-order: cần `designId`, sinh PrintJob, trả-trước online |

## designs — thư viện artwork của khách

| Field | Ý nghĩa |
|---|---|
| `customerId` | Sở hữu — chỉ chủ thấy |
| `file` / `thumbnail` | Artwork gốc / ảnh xem trước |
| `lastUsedAt` | Cập nhật mỗi lần dùng lại (sắp xếp "dùng gần đây") |

> Khách upload 1 lần → **tái dùng nhiều đơn**. Khi thêm variant `CUSTOM_PRINT` vào giỏ: upload mới (tạo `Design`) hoặc chọn từ thư viện → set `CartItem.designId` + **copy `designFile`** (snapshot). `Design` thuộc Ecom; khi gửi sang WMS chỉ truyền **file** (xem [bài 04](04-in-ly.md)).

## Catalog là consumer tồn

Module này **lắng nghe** `stock.changed` / `stock.expired` từ WMS → cập nhật `availableQty` (match theo `sku`). Đây là **đường 1** cập nhật tồn; đường 2 (reserve/release lúc checkout) do module Order tự làm trong transaction — xem [bài 10](10-order.md).

---

← [08 — Auth-WMS](08-auth-wms.md) · → [10 — Order](10-order.md)
