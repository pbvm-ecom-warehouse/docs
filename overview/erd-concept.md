# ERD mức concept — Tổng quan thực thể WMS-ECOM (1 slide)

> Bản **concept** (cao): chỉ **entity + quan hệ**, lược bỏ field và các bảng `*Item` chi tiết (gộp vào entity cha). Dùng cho slide tổng quan. Bản đầy đủ (có field): [erd.md](erd.md).

**Quy ước:** nét liền = quan hệ trong cùng app; **nét đứt** = liên kết **xuyên 2 app** (chỉ qua `sku`/`orderId`, không đọc chéo, giao tiếp qua event).

```mermaid
erDiagram
    %% ===== WMS — wms_db =====
    Warehouse ||--o{ Zone : ""
    Zone ||--o{ Rack : ""
    Rack ||--o{ Shelf : ""

    WarehouseItem ||--o{ StockBalance : "tồn tổng"
    Warehouse ||--o{ StockBalance : ""
    WarehouseItem ||--o{ InventoryStock : "tồn vị trí"
    Shelf ||--o{ InventoryStock : ""
    WarehouseItem ||--o{ Lot : ""
    Lot ||--o{ InventoryStock : ""
    WarehouseItem ||--o{ StockMovement : "sổ cái"

    Supplier ||--o{ WarehouseItem : "cung cấp"
    Supplier ||--o{ PurchaseOrder : ""
    Warehouse ||--o{ PurchaseOrder : ""
    PurchaseOrder ||--o{ GoodsReceiveNote : ""
    GoodsReceiveNote ||--o{ PutAwayTask : ""

    Warehouse ||--o{ PrintJob : ""
    Warehouse ||--o{ GoodsIssue : ""
    Warehouse ||--o{ StockCount : ""
    Warehouse ||--o{ StockTransfer : ""
    Warehouse ||--o{ ScrapNote : ""
    Warehouse ||--o{ GoodsReturn : ""

    GoodsIssue ||--o| Shipment : "auto-sinh"
    Carrier ||--o{ Shipment : ""
    User ||--o{ Warehouse : "thao tác"

    %% ===== Ecommerce — ecom_db =====
    Category ||--o{ Category : "cây"
    Category ||--o{ Product : ""
    Product ||--o{ ProductVariant : "biến thể"

    Customer ||--o{ Cart : ""
    Customer ||--o{ Order : "đặt"
    Customer ||--o{ Design : ""
    Order ||--o{ PaymentTransaction : "sổ cái tiền"
    Design ||--o{ Order : "ly-in"

    %% ===== Liên kết xuyên 2 app (nét đứt) =====
    WarehouseItem ||..o{ ProductVariant : "sku — link DUY NHẤT"
    Warehouse ||..o{ Order : "fulfillWarehouseId"
    Order ||..o{ PrintJob : "orderId"
    Order ||..o| GoodsIssue : "orderId"
    Order ||..o| GoodsReturn : "orderId"
    Order ||..o| Shipment : "orderId"
```

## Đọc theo cụm

| App / DB | Cụm | Entity (đã gộp `*Item`) |
|---|---|---|
| **WMS** `wms_db` | Cấu trúc kho | `Warehouse → Zone → Rack → Shelf` |
| | Hàng & tồn | `WarehouseItem` · `StockBalance` (tổng) · `InventoryStock` (vị trí) · `Lot` · `StockMovement` (sổ cái) |
| | Nhập | `Supplier → PurchaseOrder → GoodsReceiveNote → PutAwayTask` |
| | Xuất / nội bộ | `PrintJob` · `GoodsIssue` · `StockCount` · `StockTransfer` · `ScrapNote` · `GoodsReturn` |
| | Giao hàng | `Carrier · Shipment` |
| | Nhân sự | `User` |
| **Ecommerce** `ecom_db` | Catalog | `Category → Product → ProductVariant` · `Design` |
| | Đơn | `Customer → Cart` · `Customer → Order → PaymentTransaction` |

> **3 cây cầu xuyên app (nét đứt):** `WarehouseItem.sku ⟷ ProductVariant.sku` (đồng bộ tồn) · `Order ⟷ PrintJob/GoodsIssue/GoodsReturn/Shipment` qua `orderId` · `Order.fulfillWarehouseId ⟷ Warehouse`. Tất cả qua **event (BullMQ + Redis)**, không đọc chéo collection.
