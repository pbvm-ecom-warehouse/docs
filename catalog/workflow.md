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
