# Ecommerce Catalog Module — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Viết bộ tài liệu phân tích nghiệp vụ cho module Catalog (Ecommerce) theo đúng chuẩn module Kho/Order, và cập nhật docs liên quan (data-ownership, order, README) cho khớp.

**Architecture:** Repo tài liệu thuần (`.md`). "Implementation" = tạo `docs/catalog/{data-model,use-cases,workflow}.md` + cập nhật `overview/data-ownership.md`, `order/data-model.md`, `README.md`. Nguồn nội dung là spec [2026-06-04-ecommerce-catalog-module-design.md](../specs/2026-06-04-ecommerce-catalog-module-design.md).

**Tech Stack:** Markdown (GitHub-flavored), bảng + sơ đồ ASCII swimlane như `warehouse/workflow.md` và `order/workflow.md`. Không có test tự động → **verification = grep nhất quán + đối chiếu spec + kiểm anchor link**.

**Quy ước:**
- Mỗi task = 1 file, kết thúc bằng 1 commit (`docs: ...`, tiếng Việt, kèm `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`).
- Tên collection/field/enum phải khớp **đúng** spec (xem Bảng tham chiếu cuối plan).
- Làm Task theo thứ tự: Task 1 (data-ownership) trước vì các file sau trỏ tới nó; Task 5 (order) sau khi catalog data-model đã định nghĩa `designId`.

---

## File Structure

| File | Trách nhiệm | Hành động |
|---|---|---|
| `overview/data-ownership.md` | Thêm `categories`/`designs` vào sở hữu Ecom; nêu catalog là consumer `stock.changed` | Modify |
| `catalog/data-model.md` | Category/Product/ProductVariant/Design + chỉnh `designId` cho Order | Create |
| `catalog/use-cases.md` | UC-C01..C06 (duyệt/tìm/chi tiết/design library/quản trị/sync tồn) | Create |
| `catalog/workflow.md` | Swimlane WF-C01..C04 | Create |
| `order/data-model.md` | Thêm `designId?` vào CartItem & OrderItem | Modify |
| `README.md` | Bảng module: thêm dòng Catalog | Modify |

---

## Task 1: Cập nhật `overview/data-ownership.md` (collection mới + consumer tồn)

**Files:**
- Modify: `overview/data-ownership.md`

- [ ] **Step 1: Thêm `categories` và `designs` vào sơ đồ sở hữu Ecommerce**

Trong block "WMS sở hữu / Ecommerce sở hữu" (mục "Nguyên tắc: 2 logical DB"), cột **Ecommerce sở hữu** hiện có: `products`, `product_variants`, `orders`, `customers`, `carts`, `payments`. Thêm 2 dòng `categories` và `designs`. Kết quả cột Ecommerce:

```
Ecommerce sở hữu:
──────────────────────
products
product_variants
categories
designs
orders
customers
carts
payments
```

- [ ] **Step 2: Thêm ghi chú catalog là consumer sự kiện tồn**

Ngay sau bảng "Các event đồng bộ giữa WMS và Ecommerce", thêm câu:

```markdown
> **Catalog là consumer tồn:** `stock.changed` và `stock.expired` được module **Catalog** (Ecommerce) tiêu thụ → cập nhật `ProductVariant.availableQty` (match theo `sku`). Xem [Catalog data-model](../catalog/data-model.md).
```

- [ ] **Step 3: Verify**

Run: `grep -n "categories\|designs" overview/data-ownership.md`
Expected: cả 2 collection xuất hiện trong block sở hữu Ecommerce.
Run: `grep -n "Catalog là consumer" overview/data-ownership.md`
Expected: có 1 dòng ghi chú; link `../catalog/data-model.md` đúng cú pháp tương đối.

- [ ] **Step 4: Commit**

```bash
git add overview/data-ownership.md
git commit -m "docs: data-ownership thêm categories/designs + catalog consumer tồn

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Tạo `catalog/data-model.md`

**Files:**
- Create: `catalog/data-model.md`

- [ ] **Step 1: Viết file với nội dung sau**

````markdown
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
````

- [ ] **Step 2: Verify — collection/enum khớp spec, link tương đối đúng**

Run: `grep -n "fulfillmentType\|STANDARD\|PRINTED_TEMPLATE\|CUSTOM_PRINT\|availableQty\|designId" catalog/data-model.md`
Expected: đủ; tên khớp Bảng tham chiếu cuối plan.
Kiểm thủ công: header UC-04 trong `warehouse/use-cases.md` sinh slug khớp anchor `#uc-04-lệnh-in-ly-make-to-order` đã dùng.

- [ ] **Step 3: Commit**

```bash
git add catalog/data-model.md
git commit -m "docs: Catalog data-model - category/product/variant/design + link Order

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Tạo `catalog/use-cases.md`

**Files:**
- Create: `catalog/use-cases.md`

- [ ] **Step 1: Viết file với nội dung sau**

````markdown
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
````

- [ ] **Step 2: Verify — anchor nội bộ & enum khớp**

Run: `grep -n "UC-C0" catalog/use-cases.md`
Expected: đủ UC-C01..C06.
Run: `grep -n "STANDARD\|PRINTED_TEMPLATE\|CUSTOM_PRINT\|fulfillmentType" catalog/use-cases.md`
Expected: tên khớp `catalog/data-model.md`.
Kiểm thủ công: anchor `#uc-c04-quản-lý-thư-viện-design` khớp slug header UC-C04; link `../overview/data-ownership.md#sync-tồn-kho-qua-event` trỏ header tồn tại.

- [ ] **Step 3: Commit**

```bash
git add catalog/use-cases.md
git commit -m "docs: Catalog use-cases UC-C01..C06 (duyệt/tìm/chi tiết/design/CRUD/sync)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Tạo `catalog/workflow.md`

**Files:**
- Create: `catalog/workflow.md`

- [ ] **Step 1: Viết file với nội dung sau** (swimlane ASCII như `order/workflow.md`)

````markdown
# Catalog (Ecommerce) — Workflow

> Trạng thái: 🔄 Đang phân tích

## Luồng tổng quan

```
Category tree → [WF-C01 Duyệt/Tìm] → [WF-C02 Chi tiết+chọn variant]
                                              ↓
                          STANDARD/PRINTED_TEMPLATE → giỏ (như hàng thường)
                          CUSTOM_PRINT → [WF-C03 Design] → giỏ (isPrintItem)
                                              ↓
                                    (sang Checkout — module Order)

[WF-C04 Sync tồn]  WMS stock.changed/expired → availableQty
```

> Sau khi vào giỏ, luồng tiếp tục ở [Order workflow](../order/workflow.md). Catalog chỉ lo tới bước thêm-vào-giỏ.

---

## WF-C01: Duyệt & tìm kiếm

```
KHÁCH                     CATALOG                    (dữ liệu)
  |                          |                           |
  |-- Mở cây danh mục ------>|                           |
  |                    Lấy Category (parentId, position) |
  |<-- Cây + list product ---|  Product status=ACTIVE    |
  |                          |                           |
  |-- Search/lọc ----------->|  name + categoryId        |
  |   (từ khóa, giá, còn hàng)  + price range + availableQty>0
  |<-- Kết quả --------------|  (query + index Mongo)    |
```

---

## WF-C02: Chi tiết & chọn biến thể

```
KHÁCH                     CATALOG
  |                          |
  |-- Mở chi tiết product -->|
  |<-- Ảnh/mô tả + variants -|  ProductVariant isActive
  |-- Chọn variant --------->|  hiển thị price, availableQty
  |                    fulfillmentType?                  
  |   STANDARD/PRINTED_TEMPLATE → "Thêm giỏ" (isPrintItem=false)
  |   CUSTOM_PRINT            → cần design (WF-C03)
  |   availableQty=0          → chặn thêm giỏ
```

---

## WF-C03: Chọn/Upload design (ly-in CUSTOM_PRINT)

```
KHÁCH                     DESIGN LIB                 CART (Order)
  |                          |                           |
  |-- [Upload mới] --------->|  validate định dạng/size  |
  |                    Tạo Design{customerId,file,thumb} |
  |-- [Chọn lại] ----------->|  list designs (lastUsedAt)|
  |<-- Chọn xong ------------|                           |
  |                    Design.lastUsedAt = now           |
  |                          |-- Thêm vào giỏ ---------->| CartItem{sku(blank),
  |                          |                           |  isPrintItem=true,
  |                          |                           |  designId, designFile}
```
> Tiếp luồng checkout ở [Order WF-E01](../order/workflow.md#wf-e01-checkout--giữ-tồn) (ly-in bắt buộc trả-trước ONLINE).

---

## WF-C04: Đồng bộ tồn (consumer)

```
WMS                       CATALOG (worker)           product_variants
  |                          |                           |
  |-- stock.changed{sku,delta} ->|                       |
  |                    Tìm variant theo sku              |
  |                          |-- availableQty += delta ->|
  |-- stock.expired -------->|  availableQty giảm        |
  |                    sku không khớp → bỏ qua           |
  |                    availableQty<0 → clamp hiển thị 0 |
```
````

- [ ] **Step 2: Verify — sơ đồ nhất quán tên enum/sự kiện/anchor**

Run: `grep -n "CUSTOM_PRINT\|PRINTED_TEMPLATE\|stock.changed\|availableQty\|designId" catalog/workflow.md`
Expected: tên khớp `catalog/data-model.md`.
Kiểm thủ công: link `../order/workflow.md#wf-e01-checkout--giữ-tồn` khớp slug header WF-E01 trong `order/workflow.md` (lưu ý double-hyphen từ ` & `).

- [ ] **Step 3: Commit**

```bash
git add catalog/workflow.md
git commit -m "docs: Catalog workflow WF-C01..C04 (duyệt/chi tiết/design/sync)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Cập nhật `order/data-model.md` (thêm `designId`)

**Files:**
- Modify: `order/data-model.md`

- [ ] **Step 1: Thêm `designId` vào bảng CartItem**

Trong `order/data-model.md`, bảng **CartItem**, thêm dòng ngay sau dòng `designFile`:

```markdown
| designId | ObjectId | Trỏ `designs` (thư viện khách, khi `isPrintItem`) — truy vết & reuse |
```

- [ ] **Step 2: Thêm `designId` vào bảng OrderItem**

Trong bảng **OrderItem**, thêm dòng ngay sau dòng `designFile`:

```markdown
| designId | ObjectId | Trỏ `designs` (khi `isPrintItem`); `designFile` là snapshot file lúc đặt |
```

- [ ] **Step 3: Thêm ghi chú liên kết Catalog**

Ngay dưới block ghi chú "Giỏ **chưa giữ tồn**..." (cuối Nhóm 1), thêm:

```markdown
> **Design ly-in:** với `isPrintItem`, storefront cho khách upload mới hoặc chọn lại từ thư viện → set `designId` + copy `designFile` (snapshot). Xem [Catalog data-model](../catalog/data-model.md).
```

- [ ] **Step 4: Verify**

Run: `grep -n "designId" order/data-model.md`
Expected: xuất hiện ở CartItem và OrderItem.
Run: `grep -n "Catalog data-model" order/data-model.md`
Expected: có dòng ghi chú; link `../catalog/data-model.md` đúng.

- [ ] **Step 5: Commit**

```bash
git add order/data-model.md
git commit -m "docs: Order CartItem/OrderItem thêm designId liên kết thư viện design

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Cập nhật `README.md` (thêm module Catalog) + review tổng

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Thêm dòng Catalog vào bảng "Danh mục module"**

Thêm dòng ngay **trên** dòng "Đơn hàng & E-commerce" (catalog là nền của order):

```markdown
| [Catalog (Ecommerce)](./catalog/) | [UC](./catalog/use-cases.md) | [Data Model](./catalog/data-model.md) | [Workflow](./catalog/workflow.md) |
```

- [ ] **Step 2: Review nhất quán toàn cục**

Run: `grep -rln "fulfillmentType" catalog/`
Expected: xuất hiện ở data-model, use-cases, workflow.

Run: `grep -rln "designId" order/ catalog/`
Expected: order/data-model + catalog/data-model (+ workflow/use-cases catalog).

Run: `grep -rn "categories\|designs" overview/data-ownership.md`
Expected: cả 2 collection trong block sở hữu Ecommerce.

Kiểm thủ công các anchor đã dùng không gãy:
- `catalog/data-model.md` → `../warehouse/use-cases.md#uc-04-lệnh-in-ly-make-to-order`
- `catalog/use-cases.md` → `#uc-c04-quản-lý-thư-viện-design`, `../overview/data-ownership.md#sync-tồn-kho-qua-event`
- `catalog/workflow.md` → `../order/workflow.md#wf-e01-checkout--giữ-tồn`

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README thêm module Catalog + đồng bộ liên kết catalog/order

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Bảng tham chiếu tên (PHẢI khớp tuyệt đối)

**Collection (Ecom sở hữu, thêm mới):** `categories`, `designs` (cùng `products`, `product_variants` đã có).

**Catalog enums:**
- `Product.status`: `DRAFT` / `ACTIVE` / `HIDDEN`
- `ProductVariant.fulfillmentType`: `STANDARD` / `PRINTED_TEMPLATE` / `CUSTOM_PRINT`

**Field then chốt:**
- Category: `parentId`, `slug`, `position`
- Product: `slug`, `categoryId`, `status`, `seo`
- ProductVariant: `sku`, `attributes`, `price`, `availableQty`, `fulfillmentType`, `isActive`
- Design: `customerId`, `file`, `thumbnail`, `lastUsedAt`
- Order (thêm): `designId` (CartItem + OrderItem)

**Sự kiện tiêu thụ:** `stock.changed`, `stock.expired` (WMS → Catalog).

**Ngữ nghĩa chốt:** `PRINTED_TEMPLATE` mua như hàng thường (`isPrintItem = false`); chỉ `CUSTOM_PRINT` là make-to-order (`isPrintItem = true`, cần `designId`/`designFile`).

---

## Self-Review (đã chạy khi viết plan)

- **Spec coverage:** Category/Product/Variant/Design (Task 2), 3 `fulfillmentType` (Task 2-4), thư viện design + reuse (Task 2-4, UC-C04/WF-C03), sync `availableQty` (Task 1-4, UC-C06/WF-C04), search/filter (UC-C02/WF-C01), `designId` vào Order (Task 5), quản trị mức use-case (UC-C05), README (Task 6). ✅
- **Placeholder scan:** không có TBD/TODO; nội dung từng file viết đầy đủ. ✅
- **Type consistency:** enum/field/collection thống nhất qua Bảng tham chiếu; các task dùng đúng tên đó (`fulfillmentType`, `availableQty`, `designId`, `parentId`...). ✅
- **Out of scope** (admin chi tiết, voucher, review, Elasticsearch) đã loại khỏi spec → không có task. ✅
