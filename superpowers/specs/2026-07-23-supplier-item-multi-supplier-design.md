# SupplierItem hỗ trợ nhiều NCC/SKU — Design

**Ngày:** 2026-07-23
**App:** `apps/wms`
**Trạng thái:** Approved (chờ implementation plan)
**Issue:** [#30](https://github.com/pbvm-ecom-warehouse/be-wms-ecom/issues/30)

## Bối cảnh

`SupplierItem` (`apps/wms/src/supplier/schemas/supplier-item.schema.ts`) hiện mô hình hóa quan hệ **1 SKU ↔ 1 NCC chính** qua `itemId: { unique: true }`. `upsertSupplierItem` ghi đè bản ghi cũ nếu SKU đã có báo giá — không lưu song song được nhiều NCC cho cùng SKU, mất báo giá cũ khi NCC khác báo giá mới.

Xác nhận thực tế nghiệp vụ: **một SKU thường mua được từ nhiều NCC khác nhau**, cần lưu song song để so sánh giá trước khi đặt PO. Thiết kế hiện tại không khớp thực tế này.

Không có dữ liệu `SupplierItem` thật trong DB (toàn dữ liệu test) — không cần migration bảo toàn dữ liệu.

## Mục tiêu

Đổi `SupplierItem` từ mô hình 1-1 (SKU → NCC) sang mô hình n-n: mỗi cặp (SKU, NCC) là 1 báo giá độc lập.

## Ngoài phạm vi (đã chốt khi brainstorm)

- Không thêm cờ "NCC ưu tiên/mặc định" cho SKU — giữ đơn giản, người dùng tự chọn NCC khi tạo PO.
- Không xử lý lịch sử thay đổi giá theo thời gian (audit trail) — vấn đề riêng, xem issue #32.
- Không cần migration dữ liệu thật.

## Quyết định thiết kế

### 1. Schema — đổi unique constraint

`apps/wms/src/supplier/schemas/supplier-item.schema.ts`:
- Bỏ `unique: true` trên riêng `itemId`.
- Thêm compound unique index: `SupplierItemSchema.index({ itemId: 1, supplierId: 1 }, { unique: true })`.

Kết quả: 1 SKU có thể có nhiều `SupplierItem` (mỗi NCC 1 bản ghi), nhưng 1 cặp (SKU, NCC) chỉ có đúng 1 báo giá.

### 2. Repository — tách API "list theo SKU" và "tìm đúng 1 cặp"

`apps/wms/src/supplier/supplier.repository.ts`:
- `findSupplierItemByItemId(itemId)` (trả 1 bản ghi) → đổi thành `findSupplierItemsByItemId(itemId)`, trả `SupplierItemDocument[]` (mọi NCC báo giá SKU đó, không lọc `isActive` — để caller tự quyết định lọc).
- Thêm `findSupplierItemByItemAndSupplier(itemId, supplierId)` → trả `SupplierItemDocument | null`, tra đúng 1 bản ghi theo compound key. Dùng cho cả `upsertSupplierItem` và PO auto-fill giá.

### 3. Service

`apps/wms/src/supplier/supplier.service.ts`:
- `upsertSupplierItem(dto)`: đổi điều kiện "đã tồn tại" từ `findSupplierItemByItemId(dto.itemId)` sang `findSupplierItemByItemAndSupplier(dto.itemId, dto.supplierId)`. Nếu tìm thấy → update bản ghi đó (giữ nguyên logic loại `itemId`/`supplierId` khỏi payload update — 2 field này là khóa, bất biến sau khi tạo qua đường upsert; đổi NCC của 1 báo giá đã có phải làm qua `PATCH /supplier/items/:id` như hiện tại). Nếu không thấy → tạo mới.
- `getSupplierItemByItemId(itemId)` (trả 1 doc, throw `SUPPLIER_ITEM_NOT_FOUND` nếu rỗng) → đổi thành `listSupplierItemsByItemId(itemId)`, trả mảng (rỗng nếu không có, không throw — "chưa có báo giá nào" là trạng thái hợp lệ khi liệt kê).
- Thêm `getSupplierItemByItemAndSupplier(itemId, supplierId)`: throw `SUPPLIER_ITEM_NOT_FOUND` nếu không có — dùng cho PO (cần throw vì PO bắt buộc phải có giá).

### 3b. Xử lý conflict khi PATCH đổi supplierId trùng cặp đã tồn tại

`PATCH /supplier/items/:id` cho phép đổi `supplierId` của 1 báo giá (`UpdateSupplierItemDto.supplierId`). Với compound unique index, nếu đổi sang `(itemId hiện tại, supplierId mới)` mà cặp đó đã có báo giá khác → Mongo ném lỗi trùng khóa (code 11000). `updateSupplierItem` bắt lỗi này và dịch sang `AppException('SUPPLIER_ITEM_SUPPLIER_CONFLICT')` (thêm error code mới vào `apps/wms/src/common/error-codes.ts`, tầng `WMS_ERRORS`) — nhất quán với cách `StockService.createWarehouseItem` xử lý trùng khóa sku (`STOCK_ITEM_SKU_CONFLICT`).

### 4. Controller

`apps/wms/src/supplier/supplier.controller.ts`:
- `GET /supplier/items/by-item/:itemId`: đổi response từ `SupplierItemResponseDto` (1 object) sang `[SupplierItemResponseDto]` (mảng). Đổi `@ApiOkResponse({ type: SupplierItemResponseDto })` → `{ type: [SupplierItemResponseDto] }`.
- Các route khác (`POST items`, `GET items/by-supplier/:supplierId`, `GET items/:id`, `PATCH items/:id`) giữ nguyên contract.

### 5. Purchase Order — dùng đúng compound key, gỡ patch tạm của issue #29

`apps/wms/src/purchase-order/purchase-order.service.ts`:
- Đổi lời gọi từ `supplierService.getSupplierItemByItemId(item.itemId)` sang `supplierService.getSupplierItemByItemAndSupplier(item.itemId, dto.supplierId)`.
- **Gỡ bỏ** đoạn so sánh `supplierItem.supplierId.toString() !== dto.supplierId` thêm ở fix #29 (commit `63fe496`) — không còn cần thiết vì query đã lọc đúng cặp (SKU, NCC) ngay từ đầu, không thể trả về báo giá của NCC khác nữa.
- Giữ nguyên: nếu không tìm thấy → catch `SUPPLIER_ITEM_NOT_FOUND` → dịch sang `PO_PRICE_MISSING`; nếu `isActive=false` → cũng `PO_PRICE_MISSING`.

## Test cần cập nhật/thêm

- `apps/wms/src/supplier/schemas/supplier-item.schema.spec.ts` — cập nhật kỳ vọng index (compound thay vì single).
- `apps/wms/src/supplier/supplier.repository.spec.ts` — test `findSupplierItemsByItemId` (mảng), `findSupplierItemByItemAndSupplier`.
- `apps/wms/src/supplier/supplier.service.spec.ts` — test `upsertSupplierItem` với 2 case: cùng (itemId, supplierId) → update; cùng itemId khác supplierId → tạo mới (không ghi đè). Test `listSupplierItemsByItemId` trả mảng rỗng khi không có. Test `getSupplierItemByItemAndSupplier` throw đúng mã lỗi.
- `apps/wms/src/purchase-order/purchase-order.service.spec.ts` — sửa mock `getSupplierItemByItemId` → `getSupplierItemByItemAndSupplier`; xóa test case "throw PO_PRICE_MISSING khi supplierId khác" (không còn kịch bản này — query đã lọc đúng cặp, nếu khác supplierId thì kết quả luôn là "không tìm thấy" → đã được test qua case `SUPPLIER_ITEM_NOT_FOUND` sẵn có).

## Rủi ro / lưu ý

- Đây là breaking change về contract API (`GET /supplier/items/by-item/:itemId` đổi từ object sang array) — chấp nhận được vì chưa có dữ liệu/consumer thật phụ thuộc.
- Đổi unique index trên Mongoose: vì collection hiện trống/test, không cần viết migration drop-index thủ công — Mongoose tự đồng bộ index khi app khởi động lại (theo quy ước dự án, không có bước migrate riêng).
