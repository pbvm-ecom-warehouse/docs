# App WMS là kho duy nhất — Design

**Ngày:** 2026-07-23  
**Trạng thái:** Đã duyệt hướng thiết kế. Migration code đang triển khai theo
[2026-07-24-single-warehouse-code-migration-design.md](2026-07-24-single-warehouse-code-migration-design.md).  
**Phạm vi hiện tại:** Tài liệu trước, chưa thay đổi code

## 1. Bối cảnh

Hệ thống chỉ vận hành một kho trung tâm và mỗi deployment của app WMS đại diện
cho đúng kho đó. Mô hình hiện tại vẫn có collection `warehouses`, CRUD
Warehouse, `warehouseId` trên hầu hết chứng từ và thuật toán chọn kho khi giữ
tồn. Cấu trúc này tạo ra khả năng đa kho không được sử dụng, làm API phức tạp
hơn và cho phép tạo trạng thái sai như nhiều warehouse cùng active.

Thiết kế mới xác lập **app WMS là boundary của kho duy nhất**. Không biểu diễn
kho bằng một document nghiệp vụ riêng và không truyền định danh kho giữa các
module.

## 2. Quyết định kiến trúc

### 2.1 Bỏ thực thể Warehouse

- Xóa khái niệm entity/collection `Warehouse` và collection `warehouses`.
- Bỏ toàn bộ CRUD Warehouse và các màn hình hoặc API chọn kho.
- Không thay Warehouse bằng singleton document, constant ID hoặc cấu hình
  `DEFAULT_WAREHOUSE_ID`.
- Tên, địa chỉ và thông tin vận hành của cơ sở, nếu cần trong tương lai, là cấu
  hình deployment hoặc hồ sơ tổ chức; không phải master data để CRUD trong WMS.

### 2.2 Cấu trúc vị trí bắt đầu từ Zone

Cây vị trí vật lý đổi từ:

```text
Warehouse → Zone → Rack → Shelf
```

thành:

```text
Zone → Rack → Shelf
```

- `Zone` là cấp gốc và không có `warehouseId`.
- `Rack` tiếp tục thuộc một `Zone`.
- `Shelf` tiếp tục thuộc một `Rack`.
- Barcode vị trí, shelf staging, kích thước shelf và gợi ý put-away được giữ
  nguyên.
- Quy tắc “một shelf staging cho mỗi kho” đổi thành “app WMS có đúng một shelf
  staging đang hoạt động”.

### 2.3 Bỏ định danh kho khỏi nghiệp vụ

Xóa `warehouseId` khỏi:

- tồn kho hai lớp và sổ cái: `StockBalance`, `InventoryStock`,
  `StockMovement`;
- nhập kho: `PurchaseOrder`, `GoodsReceiveNote`, `PutAwayTask`;
- vận hành: `PrintJob`, `GoodsIssue`, `StockCount`, `ScrapNote`,
  `GoodsReturn`;
- người dùng, shipping, báo cáo, DTO, filter và query liên quan.

Mọi dữ liệu do app WMS sở hữu mặc định thuộc kho duy nhất của deployment hiện
tại. Các khóa và index được rút gọn theo boundary này. Ví dụ:

- `StockBalance` unique theo `itemId`, không còn theo
  `(itemId, warehouseId)`;
- `InventoryStock` unique theo `(itemId, shelfId, lotId)`;
- truy vấn báo cáo và kiểm kê không nhận bộ lọc `warehouseId`.

### 2.4 Bỏ định danh kho khỏi tích hợp Ecommerce

- Xóa `fulfillWarehouseId` khỏi Order, Shipment và payload event xuyên app.
- Event đặt hàng/giữ tồn chỉ mang dữ liệu cần cho nghiệp vụ, không yêu cầu WMS
  chọn kho.
- Reservation kiểm tra và giữ tồn trong app WMS hiện tại; không duyệt danh sách
  kho active, không ưu tiên `CENTRAL`, không split hoặc fallback sang kho khác.
- Goods Issue và Shipping tiếp tục liên kết qua `orderId`/`goodsIssueId`, không
  cần định danh kho.

Liên kết giữa WMS và Ecommerce vẫn chỉ qua `sku` cùng các ID chứng từ scalar đã
được xác định trong tài liệu ownership; việc bỏ `fulfillWarehouseId` không cho
phép đọc chéo database.

## 3. Luồng dữ liệu sau thay đổi

### 3.1 Nhập và put-away

1. PO và GRN được tạo cho app WMS hiện tại, không chọn kho.
2. GRN confirmed cộng tồn vào `StockBalance` của item và
   `InventoryStock` tại shelf staging duy nhất.
3. Put-away chuyển tồn từ staging sang một hoặc nhiều shelf thật trong cây
   `Zone → Rack → Shelf`.

### 3.2 Giữ và xuất tồn

1. Ecommerce yêu cầu giữ tồn theo `orderId` và danh sách SKU.
2. WMS atomic-reserve trực tiếp trên `StockBalance` của từng item.
3. Thành công chỉ cần trả kết quả giữ tồn cho đơn, không trả
   `fulfillWarehouseId`.
4. Khi đơn sẵn sàng, WMS tạo Goods Issue và chọn shelf/lô theo tồn vị trí.

### 3.3 Kiểm kê, hủy và hoàn hàng

Các chứng từ nhận phạm vi theo `zoneId`, `shelfId`, item hoặc chứng từ nguồn
tùy nghiệp vụ. Không có phạm vi `warehouseId`; bỏ trống `zoneId` nghĩa là toàn
bộ kho được đại diện bởi app WMS.

## 4. Phạm vi cập nhật tài liệu

### 4.1 Tài liệu nguồn chuẩn

Rà và cập nhật đồng bộ các nhóm sau:

- `overview/`: system context, main flow, ownership, ERD và mô tả kiến trúc;
- `warehouse/`: data model, use cases, workflow;
- `db/`: kho/vị trí, tồn kho, nhập/xuất/nội bộ, order và luồng end-to-end;
- `order/`, `shipping/`, `auth-wms/` và các module có contract
  `warehouseId`/`fulfillWarehouseId`;
- `planning/`: sprint và issue đang dùng CRUD/chọn kho.

### 4.2 Task S1-03

Đổi mục tiêu từ “Warehouse/Zone/Rack/Shelf + CRUD” thành “Zone/Rack/Shelf +
quản lý cấu trúc vị trí”:

- bỏ schema và CRUD Warehouse;
- giữ CRUD Zone/Rack/Shelf;
- acceptance criteria bắt đầu từ Zone và yêu cầu đúng một shelf staging;
- bỏ tiêu chí Sprint 1 “gọi được CRUD kho”.

### 4.3 Spec và plan lịch sử

Spec/plan cũ là bằng chứng của quyết định tại thời điểm viết, nên không viết lại
toàn bộ nội dung. Những tài liệu trực tiếp có thể dẫn triển khai sai phải có
banner `Superseded` trỏ về spec này, tối thiểu gồm:

- S1-03 warehouse structure;
- stock reservation/chọn kho;
- seed E2E tạo Warehouse;
- các plan truyền `warehouseId` như một lựa chọn của client.

## 5. Ranh giới và tương thích

### Trong phạm vi

- Xác lập mô hình docs không có Warehouse.
- Loại bỏ contract `warehouseId`/`fulfillWarehouseId` khỏi thiết kế đích.
- Lập danh sách tài liệu và task cần sửa.
- Ghi rõ code hiện tại chưa đồng bộ.

### Ngoài phạm vi của giai đoạn docs

- Sửa schema, controller, service, repository hoặc test.
- Migration/xóa field trong MongoDB.
- Thay đổi event producer/consumer đang chạy.
- Thay đổi dữ liệu seed.
- Hỗ trợ nhiều deployment WMS chia sẻ một Ecommerce.

Trong thời gian docs đã đổi nhưng code chưa đổi, tài liệu phải có ghi chú chuyển
tiếp rõ ràng: **code hiện tại vẫn dùng Warehouse và `warehouseId`; không dùng
docs mới để giả định migration đã hoàn tất**.

## 6. Hướng migration code sau này

Thay đổi code phải được lập kế hoạch riêng và triển khai theo thứ tự dependency:

1. Chốt contract event và mô hình dữ liệu đích.
2. Chuyển dữ liệu, index và repository tồn kho.
3. Chuyển cấu trúc vị trí sang `Zone → Rack → Shelf`.
4. Chuyển các nghiệp vụ WMS khỏi `warehouseId`.
5. Chuyển Ecommerce, event và shipping khỏi `fulfillWarehouseId`.
6. Xóa Warehouse CRUD/schema và mã tương thích tạm.
7. Reseed, chạy unit/integration/E2E và kiểm tra bất biến tồn kho hai lớp.

Migration cần có chiến lược tương thích event trong thời gian deploy lệch phiên
bản; chi tiết sẽ được chốt trong implementation plan, không quyết định trong
spec docs này.

## 7. Tiêu chí hoàn thành cập nhật docs

- Không còn tài liệu nguồn chuẩn mô tả nhiều Warehouse, chọn kho, ưu tiên
  `CENTRAL` hoặc CRUD Warehouse.
- Cây vị trí nhất quán là `Zone → Rack → Shelf`.
- Schema và contract đích không còn `warehouseId`/`fulfillWarehouseId`.
- Reservation, PO/GRN, tồn, xuất, kiểm kê, báo cáo và shipping đều mặc định
  thuộc app WMS hiện tại.
- S1-03 và Sprint 1 không còn yêu cầu CRUD Warehouse.
- Spec/plan lịch sử dễ gây triển khai sai có banner trỏ về quyết định mới.
- Tài liệu ghi rõ trạng thái chuyển tiếp cho đến khi migration code hoàn tất.

