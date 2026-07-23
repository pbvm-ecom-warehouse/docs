# Single-Warehouse Docs Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cập nhật tài liệu nguồn để app WMS chính là kho duy nhất, xóa entity `Warehouse`, CRUD kho, `warehouseId` và `fulfillWarehouseId` khỏi mô hình đích mà chưa thay đổi code.

**Architecture:** Boundary deployment của app WMS thay cho document Warehouse. Cây vị trí bắt đầu tại `Zone → Rack → Shelf`; mọi chứng từ và tồn kho tự thuộc WMS hiện tại. Tài liệu nguồn được sửa thành nguồn chuẩn mới, còn spec/plan lịch sử chỉ nhận banner cảnh báo để không làm sai lệch lịch sử.

**Tech Stack:** Markdown tiếng Việt, Mermaid ERD, tài liệu GitHub, `rg`, Git.

## Global Constraints

- Chỉ sửa repo `docs`; không sửa `be` hoặc `be-pbvm-wms`.
- Không tạo singleton Warehouse, constant ID hay `DEFAULT_WAREHOUSE_ID`.
- Không đổi tên domain module `warehouse` hoặc `WarehouseItem`; hai tên này chỉ miền nghiệp vụ kho/hàng kho, không phải entity Warehouse.
- Xóa `warehouseId`/`fulfillWarehouseId` khỏi mô hình đích, DTO và event được mô tả trong tài liệu nguồn.
- Giữ `Zone → Rack → Shelf`, barcode vị trí, shelf staging, tồn hai lớp và bất biến sổ cái.
- Mỗi app WMS có đúng một shelf staging đang hoạt động.
- Spec/plan lịch sử không viết lại nội dung; chỉ thêm banner `Superseded`.
- Mọi tài liệu nguồn phải ghi rõ code hiện tại chưa migration.
- Giữ nguyên mọi thay đổi có sẵn của người dùng; mỗi commit chỉ stage file thuộc task.

---

## File Structure

### Nguồn kiến trúc

- `CLAUDE.md`: bất biến “app WMS là kho”.
- `README.md`: cây vị trí cấp cao.
- `overview/main-flow.md`: reserve một kho, không chọn ứng viên.
- `overview/data-ownership.md`: collection và contract sở hữu dữ liệu.
- `overview/erd-concept.md`: ERD khái niệm.
- `overview/erd.md`: ERD chi tiết và quan hệ.

### Nguồn nghiệp vụ WMS

- `warehouse/data-model.md`: schema đích của cấu trúc vị trí, tồn và chứng từ.
- `warehouse/use-cases.md`: luồng không chọn kho.
- `warehouse/workflow.md`: cây vị trí và phạm vi toàn kho.
- `db/00-khai-niem-loi.md` đến `db/05-xuat-kho-va-noi-bo.md`: diễn giải database WMS.
- `db/08-auth-wms.md`: bỏ kho mặc định của user.
- `db/10-order.md`: reserve tại WMS hiện tại.
- `db/13-tong-quan-he-thong.md` và `db/README.md`: mục lục/tổng quan.

### Contract xuyên app

- `planning/ecommerce-apis-specification.md`: Order và event reserve.
- `notification/data-model.md`: payload `stock.low`.
- `notification/use-cases.md`: topic FCM chung.
- `notification/consumer-design.md`: consumer không chia topic theo kho.
- `notification/template-design.md`: email không hiển thị warehouse ID.

### Kế hoạch công việc đang hoạt động

- `planning/sprint-1-foundation.md`: Definition of Done.
- `planning/issues/S1-03-warehouse-structure-schema.md`: Zone/Rack/Shelf.
- `planning/issues/S1-04-inventory-two-layer-schema.md`: tồn không khóa theo kho.
- `planning/issues/S2-02-purchase-order.md`: PO không chọn kho.
- `planning/issues/S2-03-grn.md`: staging toàn app.
- `planning/issues/S2-04-putaway.md`: task không có kho.
- `planning/issues/S2-05-putaway-suggestion.md`: API không nhận kho.
- `planning/issues/S2-06-event-infra.md`: event stock không mang kho.
- `planning/issues/S3-01-goods-issue.md`: xuất không mang kho.
- `planning/issues/S3-02-cup-printing.md`: print job không mang kho.
- `planning/issues/S3-03-stock-count.md`: bỏ phạm vi kho.
- `planning/issues/S4-01-scrap.md`: scrap không mang kho.
- `planning/issues/S4-02-return-rma.md`: return không mang kho.
- `planning/issues/S4-05-seed-e2e-demo.md`: seed không tạo Warehouse.
- `planning/demo-script.md`: bỏ placeholder và query warehouse.

### Lịch sử

- Các file trong `superpowers/specs/` và `superpowers/plans/` có
  `warehouseId`, `fulfillWarehouseId`, chọn kho hoặc CRUD Warehouse: thêm banner
  trỏ về
  `../specs/2026-07-23-single-warehouse-app-boundary-design.md` hoặc đường dẫn
  tương đối tương ứng.

---

### Task 1: Cập nhật boundary và ERD kiến trúc

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `overview/main-flow.md`
- Modify: `overview/data-ownership.md`
- Modify: `overview/erd-concept.md`
- Modify: `overview/erd.md`

**Interfaces:**
- Consumes: quyết định trong `superpowers/specs/2026-07-23-single-warehouse-app-boundary-design.md`.
- Produces: định nghĩa chuẩn “app WMS là kho” cho mọi task sau.

- [ ] **Step 1: Sửa bất biến và cây vị trí cấp cao**

Trong `CLAUDE.md`, thay bất biến một kho bằng nguyên văn:

```markdown
- **App WMS chính là kho duy nhất.** Không có entity/collection/CRUD `Warehouse`; cây vị trí bắt đầu từ `Zone → Rack → Shelf`. Mọi tồn kho và chứng từ tự thuộc WMS hiện tại, không mang `warehouseId`; không phân bổ/chọn/chuyển/split đa kho.
```

Trong `README.md`, thay cây hiện tại bằng:

```text
App WMS (đại diện kho trung tâm duy nhất)
  └── Zone (Khu vực: A, B, C)
        └── Rack (Kệ: A1, A2)
              └── Shelf (Tầng/ô có barcode vị trí)
```

- [ ] **Step 2: Sửa ownership**

Trong `overview/data-ownership.md`:

- bỏ `warehouses` khỏi nhóm master data;
- đổi mục “Phân bổ kho khi chốt đơn” thành “Giữ tồn tại WMS”;
- ghi rõ `stock_balances` unique theo `itemId`;
- xóa mọi mô tả chọn kho, kho trung tâm như một document và
  `fulfillWarehouseId`;
- thêm ghi chú chuyển tiếp:

```markdown
> **Trạng thái migration:** tài liệu mô tả mô hình đích không có Warehouse/`warehouseId`; code hiện tại vẫn còn contract cũ cho đến khi hoàn tất migration riêng.
```

- [ ] **Step 3: Sửa main flow reserve**

Trong `overview/main-flow.md`, thay phần WMS thử nhiều kho bằng quy tắc:

```markdown
WMS atomic-reserve (`reserved += qty`) toàn bộ SKU của đơn trong một Mongo transaction. Nếu bất kỳ SKU nào thiếu, transaction rollback và WMS phát `stock.reserve_failed`; nếu đủ, WMS phát `stock.reserved` chỉ với kết quả của đơn, không trả `fulfillWarehouseId`.
```

Giữ nguyên saga bất đồng bộ và cơ chế release khi hủy đơn.

- [ ] **Step 4: Sửa hai ERD**

Trong `overview/erd-concept.md`:

- đổi cụm cấu trúc kho thành `Zone → Rack → Shelf`;
- bỏ entity `Warehouse`.

Trong `overview/erd.md`:

- xóa block entity `Warehouse`;
- xóa mọi field `warehouseId` và `fulfillWarehouseId`;
- xóa mọi relationship nối vào Warehouse;
- nối `Zone` như root, giữ `Zone ||--o{ Rack` và `Rack ||--o{ Shelf`;
- đổi danh sách collection warehouse thành
  `warehouse_items`, `stock_balances`, `inventory_stocks`, `lots`,
  `stock_movements`, `zones`, `racks`, `shelves` và các chứng từ.

- [ ] **Step 5: Kiểm tra task 1**

Run:

```bash
rtk rg -n "warehouses|Warehouse → Zone|fulfillWarehouseId|mọi kho active|kho ứng viên|ưu tiên CENTRAL" CLAUDE.md README.md overview/main-flow.md overview/data-ownership.md overview/erd-concept.md overview/erd.md
rtk git diff --check -- CLAUDE.md README.md overview/main-flow.md overview/data-ownership.md overview/erd-concept.md overview/erd.md
```

Expected: lệnh `rg` không có kết quả ngoài ghi chú migration có chủ đích; `git diff --check` không có output.

- [ ] **Step 6: Commit task 1**

```bash
rtk git add CLAUDE.md README.md overview/main-flow.md overview/data-ownership.md overview/erd-concept.md overview/erd.md
rtk git commit -m "docs(architecture): make WMS app the warehouse boundary"
```

---

### Task 2: Cập nhật mô hình và luồng nghiệp vụ WMS

**Files:**
- Modify: `warehouse/data-model.md`
- Modify: `warehouse/use-cases.md`
- Modify: `warehouse/workflow.md`
- Modify: `db/00-khai-niem-loi.md`
- Modify: `db/01-kho-va-vi-tri.md`
- Modify: `db/02-hang-hoa-va-ton-kho.md`
- Modify: `db/03-nhap-kho.md`
- Modify: `db/04-in-ly.md`
- Modify: `db/05-xuat-kho-va-noi-bo.md`
- Modify: `db/08-auth-wms.md`
- Modify: `db/10-order.md`
- Modify: `db/13-tong-quan-he-thong.md`
- Modify: `db/README.md`

**Interfaces:**
- Consumes: boundary và ERD từ Task 1.
- Produces: schema/flow chuẩn không có định danh kho.

- [ ] **Step 1: Đổi cấu trúc vị trí**

Trong `warehouse/data-model.md`:

- xóa toàn bộ section `Warehouse (Kho)`;
- đổi cây thành `Zone → Rack → Shelf`;
- xóa `Zone.warehouseId`;
- quy định app có đúng một shelf `isStaging = true` đang hoạt động.

Trong `warehouse/use-cases.md` và `warehouse/workflow.md`, mọi mô tả vị trí dùng
`Zone → Rack → Shelf`; không yêu cầu chọn kho ở PO, GRN, put-away, issue hoặc
stock count.

- [ ] **Step 2: Xóa field định danh kho khỏi data model**

Trong `warehouse/data-model.md`, xóa `warehouseId` khỏi:

```text
StockBalance
InventoryStock
StockMovement
PurchaseOrder
GoodsReceiveNote
PutAwayTask
PrintJob
GoodsIssue
StockCount
ScrapNote
GoodsReturn
User
```

Đổi các bất biến thành:

```text
StockBalance.onHand (theo item) = Σ InventoryStock.quantity mọi shelf
StockBalance unique theo itemId
InventoryStock unique theo itemId + shelfId + lotId
StockCount.zoneId null = kiểm toàn bộ app WMS
```

- [ ] **Step 3: Sửa tài liệu database**

Áp dụng các thay đổi chuẩn:

- `db/01-kho-va-vi-tri.md`: bảng chỉ còn `zones`, `racks`, `shelves`; xóa mục
  `warehouses`;
- `db/02-hang-hoa-va-ton-kho.md`: tồn tổng theo item, tồn vị trí theo
  item+shelf+lot;
- `db/03-nhap-kho.md`: PO/GRN không chọn kho; GRN tìm shelf staging duy nhất;
- `db/04-in-ly.md`: PrintJob không giữ định danh kho;
- `db/05-xuat-kho-va-noi-bo.md`: GoodsIssue/StockCount/Scrap/Return không có
  `warehouseId`;
- `db/08-auth-wms.md`: xóa `User.warehouseId`;
- `db/10-order.md`: app WMS tự là kho, event thành công không trả ID kho;
- `db/13-tong-quan-he-thong.md`: bỏ Warehouses khỏi danh sách entity;
- `db/README.md`: mục 01 liệt kê `zones`, `racks`, `shelves`;
- `db/00-khai-niem-loi.md`: thay mọi khóa theo item+kho bằng khóa theo item.

- [ ] **Step 4: Kiểm tra task 2**

Run:

```bash
rtk rg -n -i "warehouse.?id|fulfill.?warehouse|warehouses|Warehouse → Zone|chọn kho|phân bổ kho" warehouse db
rtk git diff --check -- warehouse db
```

Expected: không còn contract/entity Warehouse; từ `warehouse` chỉ được xuất hiện trong tên module hoặc `WarehouseItem`.

- [ ] **Step 5: Commit task 2**

```bash
rtk git add warehouse db
rtk git commit -m "docs(warehouse): remove Warehouse entity and warehouse IDs"
```

---

### Task 3: Cập nhật contract Ecommerce và Notification

**Files:**
- Modify: `order/use-cases.md`
- Modify: `planning/ecommerce-apis-specification.md`
- Modify: `notification/data-model.md`
- Modify: `notification/use-cases.md`
- Modify: `notification/consumer-design.md`
- Modify: `notification/template-design.md`

**Interfaces:**
- Consumes: reserve flow từ Task 1 và WMS data model từ Task 2.
- Produces: event/payload docs không có `fulfillWarehouseId` hoặc
  `warehouseId`.

- [ ] **Step 1: Sửa checkout/order contract**

Trong `order/use-cases.md`, mô tả checkout theo saga:

```markdown
Ecommerce tạo Order ở trạng thái `PLACED`, phát `stock.reserve_requested { orderId, items }`; WMS giữ tồn atomic trong app hiện tại. `stock.reserved { orderId }` xác nhận thành công, còn `stock.reserve_failed { orderId, reason, failedSkus }` làm Ecom hủy đơn và phục hồi giỏ.
```

Không mô tả transaction xuyên hai DB và không lưu kho fulfillment trên Order.

Trong `planning/ecommerce-apis-specification.md`:

- xóa `Order.fulfillWarehouseId`;
- đổi `STOCK_RESERVED (orderId, fulfillWarehouseId)` thành
  `STOCK_RESERVED (orderId)`;
- xóa bước cập nhật `Order.fulfillWarehouseId`;
- giữ các trạng thái order/payment/fulfillment hiện có.

- [ ] **Step 2: Sửa payload stock.low**

Trong `notification/data-model.md`, payload chuẩn là:

```ts
interface StockLowPayload {
  sku: string;
  available: number;
  minQuantity: number;
}
```

Trong `notification/template-design.md`, props email là:

```ts
{ sku: string; available: number; minQuantity: number }
```

Nội dung email không in mã kho.

- [ ] **Step 3: Sửa FCM topic và consumer**

Trong `notification/use-cases.md` và `notification/consumer-design.md`:

- topic cố định là `stock_alert`;
- `data` chỉ mang `sku`, `available`, `minQuantity`;
- bỏ mọi interpolation `${warehouseId}`;
- giải thích app chỉ có một kho nên MANAGER subscribe một topic chung.

- [ ] **Step 4: Kiểm tra task 3**

Run:

```bash
rtk rg -n "warehouseId|fulfillWarehouseId|stock_alert_" order planning/ecommerce-apis-specification.md notification
rtk git diff --check -- order/use-cases.md planning/ecommerce-apis-specification.md notification
```

Expected: không có output từ `rg`; `git diff --check` không có output.

- [ ] **Step 5: Commit task 3**

```bash
rtk git add order/use-cases.md planning/ecommerce-apis-specification.md notification
rtk git commit -m "docs(events): remove warehouse IDs from cross-app contracts"
```

---

### Task 4: Cập nhật sprint, issue và demo đang hoạt động

**Files:**
- Modify: `planning/sprint-1-foundation.md`
- Modify: `planning/issues/S1-03-warehouse-structure-schema.md`
- Modify: `planning/issues/S1-04-inventory-two-layer-schema.md`
- Modify: `planning/issues/S2-02-purchase-order.md`
- Modify: `planning/issues/S2-03-grn.md`
- Modify: `planning/issues/S2-04-putaway.md`
- Modify: `planning/issues/S2-05-putaway-suggestion.md`
- Modify: `planning/issues/S2-06-event-infra.md`
- Modify: `planning/issues/S3-01-goods-issue.md`
- Modify: `planning/issues/S3-02-cup-printing.md`
- Modify: `planning/issues/S3-03-stock-count.md`
- Modify: `planning/issues/S4-01-scrap.md`
- Modify: `planning/issues/S4-02-return-rma.md`
- Modify: `planning/issues/S4-05-seed-e2e-demo.md`
- Modify: `planning/demo-script.md`

**Interfaces:**
- Consumes: schema, API và event docs từ Tasks 1–3.
- Produces: backlog có thể triển khai mà không tái tạo Warehouse.

- [ ] **Step 1: Viết lại S1-03 và Sprint 1**

Đổi title S1-03 thành:

```yaml
title: "S1-03: Schema vị trí (Zone/Rack/Shelf) + CRUD"
```

Phạm vi S1-03 phải gồm:

```markdown
- [ ] Schema `Zone`, `Rack`, `Shelf`; `Zone` là cấp gốc của app WMS.
- [ ] `Shelf` có kích thước, `usableVolume`, `fillFactor`, cờ `isStaging`.
- [ ] CRUD REST cho Zone/Rack/Shelf.
- [ ] Ràng buộc đúng một shelf staging đang hoạt động trong app.
- [ ] Sinh/đọc barcode vị trí shelf.
```

Trong Sprint 1, đổi Definition of Done từ CRUD kho thành CRUD cấu trúc vị trí
và đổi tên issue tương ứng.

- [ ] **Step 2: Sửa issue tồn và inbound**

- S1-04: unique `StockBalance(itemId)`;
- S2-02: DTO PO không nhận `warehouseId`;
- S2-03: GRN dùng shelf staging duy nhất;
- S2-04: PutAwayTask không có `warehouseId`;
- S2-05: endpoint là
  `GET /putaway/suggestions?sku=&qty=` và duyệt mọi shelf non-staging;
- S2-06: payload `stock.changed` gồm `sku`, `delta`, `available`,
  `timestamp`.

- [ ] **Step 3: Sửa issue outbound và vận hành**

- S3-01: GoodsIssue không có `warehouseId`/`fulfillWarehouseId`;
- S3-02: PrintJob không có `warehouseId`;
- S3-03: tạo StockCount với `zoneId?`; bỏ trống là toàn app;
- S4-01: ScrapNote không có `warehouseId`;
- S4-02: GoodsReturn không có `warehouseId`;
- S4-05: seed trực tiếp Zone/Rack/Shelf, không tạo Warehouse.

- [ ] **Step 4: Sửa demo script**

Trong `planning/demo-script.md`:

- bỏ `<WAREHOUSE_ID>`;
- seed log chỉ cần shelf staging và shelf chính;
- POST PO không gửi `warehouseId`;
- put-away suggestion không có query `warehouseId`;
- POST stock-count dùng `{}` hoặc `{ "zoneId": "<ZONE_ID>" }`;
- thay link lấy shelf bằng endpoint Zone/Rack/Shelf thực tế được mô tả ở S1-03.

- [ ] **Step 5: Kiểm tra task 4**

Run:

```bash
rtk rg -n -i "warehouse.?id|fulfill.?warehouse|Warehouse → Zone|schema .*Warehouse|CRUD kho|<WAREHOUSE_ID>|warehouses/" planning --glob '*.md' -g '!superpowers/**'
rtk git diff --check -- planning
```

Expected: không còn yêu cầu/placeholder Warehouse trong planning đang hoạt động; `git diff --check` không có output.

- [ ] **Step 6: Commit task 4**

```bash
rtk git add planning/sprint-1-foundation.md planning/issues planning/demo-script.md
rtk git commit -m "docs(planning): align WMS backlog with app-level warehouse"
```

---

### Task 5: Đánh dấu spec và plan lịch sử bị thay thế

**Files:**
- Modify: `superpowers/plans/2026-06-04-ecom-review-fixes.md`
- Modify: `superpowers/plans/2026-06-04-ecommerce-order-module.md`
- Modify: `superpowers/plans/2026-06-04-shipping.md`
- Modify: `superpowers/plans/2026-06-25-ecom-week2-checkout-order-payment.md`
- Modify: `superpowers/plans/2026-06-25-wms-auth-cookie-response-dto.md`
- Modify: `superpowers/plans/2026-06-30-s1-03-warehouse-structure.md`
- Modify: `superpowers/plans/2026-06-30-s1-04-stock-schema-transaction-helper.md`
- Modify: `superpowers/plans/2026-06-30-s1-05-notification-module-docs.md`
- Modify: `superpowers/plans/2026-07-02-s2-02-purchase-order.md`
- Modify: `superpowers/plans/2026-07-03-s2-03-grn.md`
- Modify: `superpowers/plans/2026-07-04-s1-04-warehouse-item-create.md`
- Modify: `superpowers/plans/2026-07-04-s2-04-putaway.md`
- Modify: `superpowers/plans/2026-07-06-s2-05-putaway-suggestion.md`
- Modify: `superpowers/plans/2026-07-06-s3-01-goods-issue.md`
- Modify: `superpowers/plans/2026-07-13-s3-02-print-job.md`
- Modify: `superpowers/plans/2026-07-14-s3-03-stock-count.md`
- Modify: `superpowers/plans/2026-07-14-s4-01-scrap-note.md`
- Modify: `superpowers/plans/2026-07-15-s4-02-return-rma.md`
- Modify: `superpowers/plans/2026-07-15-s4-03-report-module.md`
- Modify: `superpowers/plans/2026-07-17-s4-04-notification-consumer.md`
- Modify: `superpowers/plans/2026-07-18-s4-05-seed-e2e-demo.md`
- Modify: `superpowers/plans/2026-07-20-expired-lot-scan.md`
- Modify: `superpowers/plans/2026-07-20-shipping-module-implementation.md`
- Modify: `superpowers/plans/2026-07-20-stock-reservation-saga.md`
- Modify: `superpowers/plans/2026-07-21-single-role-migration-and-reseed.md`
- Modify: `superpowers/plans/2026-07-21-users-crud-admin.md`
- Modify: `superpowers/plans/2026-07-22-sku-template-barcode-generation.md`
- Modify: `superpowers/specs/2026-06-04-ecom-review-design.md`
- Modify: `superpowers/specs/2026-06-04-ecommerce-order-module-design.md`
- Modify: `superpowers/specs/2026-06-04-shipping-design.md`
- Modify: `superpowers/specs/2026-06-25-wms-auth-cookie-response-dto-design.md`
- Modify: `superpowers/specs/2026-07-02-s2-02-purchase-order-design.md`
- Modify: `superpowers/specs/2026-07-03-s2-03-grn-design.md`
- Modify: `superpowers/specs/2026-07-04-s2-04-putaway-design.md`
- Modify: `superpowers/specs/2026-07-06-s2-05-putaway-suggestion-design.md`
- Modify: `superpowers/specs/2026-07-06-s3-01-goods-issue-design.md`
- Modify: `superpowers/specs/2026-07-13-s3-02-print-job-design.md`
- Modify: `superpowers/specs/2026-07-14-s3-03-stock-count-design.md`
- Modify: `superpowers/specs/2026-07-14-s4-01-scrap-note-design.md`
- Modify: `superpowers/specs/2026-07-15-s4-02-return-rma-design.md`
- Modify: `superpowers/specs/2026-07-15-s4-03-report-module-design.md`
- Modify: `superpowers/specs/2026-07-17-s4-04-notification-consumer-design.md`
- Modify: `superpowers/specs/2026-07-18-s4-05-seed-e2e-demo-design.md`
- Modify: `superpowers/specs/2026-07-20-expired-lot-scan-design.md`
- Modify: `superpowers/specs/2026-07-20-shipping-module-implementation-design.md`
- Modify: `superpowers/specs/2026-07-20-stock-reservation-saga-design.md`
- Modify: `superpowers/specs/2026-07-21-users-crud-admin-design.md`

**Interfaces:**
- Consumes: spec quyết định 2026-07-23.
- Produces: lịch sử được giữ nguyên nhưng không thể bị hiểu là hướng triển khai hiện hành.

- [ ] **Step 1: Chốt inventory lịch sử**

Run:

```bash
rtk rg -l "warehouseId|fulfillWarehouseId|mọi kho active|kho ứng viên|ưu tiên CENTRAL|CRUD.*Warehouse" superpowers/specs superpowers/plans --glob '*.md' | sort
```

Expected: danh sách khớp đúng tập file trong mục **Files**. Hai file
`2026-07-23-single-warehouse-app-boundary-design.md` và
`2026-07-23-single-warehouse-docs-migration.md` không thuộc tập sửa.

- [ ] **Step 2: Thêm banner vào spec lịch sử**

Ngay sau heading H1 của mỗi spec trong inventory, thêm:

```markdown
> **Superseded về mô hình kho:** Tài liệu này giữ lại để tham khảo lịch sử. Mô hình hiện hành coi app WMS là kho duy nhất và không còn entity `Warehouse`, `warehouseId` hoặc `fulfillWarehouseId`. Xem [App WMS là kho duy nhất — Design](./2026-07-23-single-warehouse-app-boundary-design.md).
```

Không sửa nội dung còn lại.

- [ ] **Step 3: Thêm banner vào plan lịch sử**

Ngay sau heading H1 của mỗi plan trong inventory, thêm:

```markdown
> **Superseded về mô hình kho:** Không thực thi nguyên trạng các bước liên quan `Warehouse`, `warehouseId`, `fulfillWarehouseId` hoặc chọn kho. Áp dụng [design hiện hành](../specs/2026-07-23-single-warehouse-app-boundary-design.md) và lập plan migration code riêng.
```

Không sửa checkbox, code mẫu hoặc commit lịch sử phía dưới.

- [ ] **Step 4: Kiểm tra banner**

Run:

```bash
rtk rg -l "Superseded về mô hình kho" superpowers/specs superpowers/plans --glob '*.md' | sort
rtk git diff --check -- superpowers/specs superpowers/plans
```

Expected: lệnh đầu liệt kê đủ mọi file trong mục **Files** và không liệt kê hai
tài liệu 2026-07-23; `git diff --check` không có output.

- [ ] **Step 5: Commit task 5**

```bash
rtk git add superpowers/specs superpowers/plans
rtk git commit -m "docs(history): mark warehouse-ID plans as superseded"
```

---

### Task 6: Kiểm tra nhất quán toàn repo docs

**Files:**
- Verify: toàn bộ repo `docs`

**Interfaces:**
- Consumes: mọi task trước.
- Produces: bằng chứng docs nguồn không còn contract kho cũ và link Markdown hợp lệ.

- [ ] **Step 1: Quét contract cũ ngoài lịch sử**

Run:

```bash
rtk rg -n -i "warehouse.?id|fulfill.?warehouse|warehouses|Warehouse → Zone|mọi kho active|kho ứng viên|ưu tiên CENTRAL|CRUD kho|<WAREHOUSE_ID>" . --glob '*.md' -g '!superpowers/specs/**' -g '!superpowers/plans/**'
```

Expected: không có output, ngoại trừ ghi chú migration nói rõ code cũ vẫn còn
`warehouseId`; kiểm tra thủ công từng kết quả ngoại lệ.

- [ ] **Step 2: Quét quy tắc mới**

Run:

```bash
rtk rg -n "App WMS.*kho|Zone → Rack → Shelf|stock_alert" CLAUDE.md README.md overview warehouse db notification planning
```

Expected: có định nghĩa boundary ở `CLAUDE.md`, cây vị trí trong overview và
warehouse docs, topic `stock_alert` không có suffix kho.

- [ ] **Step 3: Kiểm tra link Markdown tương đối**

Run:

```bash
rtk rg -o "\\]\\([^)]*\\.md(?:#[^)]*)?\\)" . --glob '*.md'
```

Expected: liệt kê link để kiểm tra; mọi target file mới hoặc đã sửa đều tồn tại.
Đối chiếu riêng link từ banner lịch sử về spec 2026-07-23.

- [ ] **Step 4: Kiểm tra whitespace và trạng thái Git**

Run:

```bash
rtk git diff --check
rtk git status --short
rtk git log -6 --oneline
```

Expected: `git diff --check` không có output; status chỉ còn thay đổi có sẵn của
người dùng không thuộc plan; log có các commit của Tasks 1–5.

- [ ] **Step 5: Ghi kết quả kiểm tra vào commit cuối nếu cần sửa**

Nếu Step 1–4 phát hiện lỗi docs thuộc plan, sửa đúng file, chạy lại toàn bộ bốn
step rồi commit:

```bash
rtk git add CLAUDE.md README.md overview warehouse db order shipping auth-wms notification planning superpowers/specs superpowers/plans
rtk git commit -m "docs(warehouse): fix single-warehouse consistency"
```

Nếu không có lỗi, không tạo commit rỗng.
