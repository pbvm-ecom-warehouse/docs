# Migration code: bỏ entity Warehouse khỏi app WMS — Design

**Ngày:** 2026-07-24
**Trạng thái:** Chờ duyệt
**Kế thừa:** [2026-07-23-single-warehouse-app-boundary-design.md](2026-07-23-single-warehouse-app-boundary-design.md)
  (spec docs-only, đã chốt kiến trúc đích: bỏ Warehouse, cây vị trí còn
  `Zone → Rack → Shelf`, bỏ `warehouseId`/`fulfillWarehouseId` khỏi mọi
  nghiệp vụ và event contract). Spec này hiện thực hóa §6 "Hướng migration
  code sau này" của spec đó — **có sửa code**, không chỉ tài liệu.

## 1. Bối cảnh

Spec 23/7 đã chốt hướng nhưng nói rõ code lúc đó "vẫn dùng Warehouse và
`warehouseId`". Giờ triển khai phần code. Khảo sát hiện trạng: 162 file TS
trong `apps/`/`libs/` tham chiếu "warehouse", trải trên gần như mọi module
WMS + 1 điểm nối chéo app sang Ecommerce (`fulfillWarehouseId`,
`preferWarehouse`).

Môi trường hiện tại **chỉ có dữ liệu dev/seed** — không cần viết migration
script gộp dữ liệu Mongo; xóa collection cũ và reseed lại sau khi đổi
schema là đủ.

## 2. Quyết định thiết kế

### 2.1 Xóa hoàn toàn entity `Warehouse`

- Xóa `warehouse.schema.ts`, CRUD (`warehouse.controller.ts`/`.service.ts`
  phần liên quan Warehouse), DTO `warehouse.dto.ts`, error code
  `WAREHOUSE_NOT_FOUND`/`WAREHOUSE_CODE_EXISTS`.
- Không thay bằng singleton document, constant ID, hay
  `DEFAULT_WAREHOUSE_ID` — đúng như spec gốc đã loại trừ phương án đó.

### 2.2 Đổi tên module `warehouse/` → `location/`

Module chỉ còn Zone/Rack/Shelf nên đổi tên cho đúng ngữ nghĩa:

| Cũ | Mới |
|---|---|
| `apps/wms/src/warehouse/` | `apps/wms/src/location/` |
| `WarehouseModule` | `LocationModule` |
| `WarehouseController` | `LocationController` |
| `WarehouseService` | `LocationService` |
| `WarehouseRepository` | `LocationRepository` |

Mọi import ở 10 module đang dùng `WarehouseModule`
(`goods-return`, `print-job`, `purchase-order`, `put-away-suggestion`,
`scrap-note`, `reservation`, `goods-receipt-note`, `stock-count`,
`goods-issue`, `put-away`) đổi sang `LocationModule`. `StockModule` không
import module này (chỉ lưu `warehouseId` như field phẳng) — không cần đổi
import, nhưng field đó sẽ bị xóa (xem 2.3).

### 2.3 Cây vị trí còn `Zone → Rack → Shelf`

- `Zone` bỏ field `warehouseId`. Index đổi:
  `{warehouseId:1, code:1}` unique → `{code:1}` unique (partial,
  `deletedAt:null`). Bỏ index `{warehouseId:1, deletedAt:1}`.
- `Shelf` bỏ field `warehouseId` (denormalized, không còn lý do tồn tại).
  Bỏ index `{warehouseId:1, isStaging:1}`.
- **Thêm mới** — ràng buộc "đúng 1 staging shelf toàn hệ thống": partial
  unique index trên `Shelf`:
  ```ts
  ShelfSchema.index(
    { isStaging: 1 },
    { unique: true, partialFilterExpression: { isStaging: true, deletedAt: null } },
  );
  ```
  Hiện trạng đây chỉ là quy ước ngầm (không ràng buộc DB) — nay siết lại
  thành invariant thật vì "1 kho = tối đa 1 staging shelf" luôn đúng.
- `WarehouseRepository.findShelvesByWarehouse(warehouseId)` →
  `LocationRepository.findShelves()` (bỏ tham số, bỏ filter `warehouseId`).
- `findStagingShelfByWarehouse(warehouseId)` →
  `findStagingShelf()` (bỏ tham số).
- `findAllActiveWarehouseIds`, CRUD Warehouse (`createWarehouse`,
  `findAllWarehouses`, `findWarehouseById`, `updateWarehouse`,
  `softDeleteWarehouse`) — xóa hoàn toàn khỏi repository.

### 2.4 Bỏ `warehouseId` khỏi mọi schema/DTO nghiệp vụ

Xóa field + index liên quan trên:

- **Tồn kho / sổ cái**: `StockBalance` (unique `{itemId,warehouseId}` →
  `{itemId}`), `InventoryStock` (unique
  `{itemId,warehouseId,shelfId,lotId}` → `{itemId,shelfId,lotId}`),
  `StockMovement` (index `{itemId,warehouseId,createdAt}` →
  `{itemId,createdAt}`).
- **Chứng từ**: `PurchaseOrder`, `GoodsReceiptNote`, `PutAwayTask`,
  `GoodsIssue`, `GoodsReturn`, `ScrapNote`, `StockCount`, `PrintJob` — xóa
  field `warehouseId` khỏi schema, mọi DTO (create/query/response), mọi
  `@ApiProperty`/`@ApiQuery` Swagger liên quan, và điều kiện lọc trong
  service/repository.
- **User**: xóa field `warehouseId?` (kho mặc định nhân viên) khỏi schema,
  `update-user.dto.ts`, `query-users.dto.ts`, `user.response.dto.ts`.
- **put-away-suggestion**: `suggest(warehouseId, ...)` bỏ tham số
  `warehouseId`; DTO bỏ field `warehouseId!` bắt buộc; controller bỏ
  truyền `query.warehouseId`.

Repository nào có method nhận `warehouseId` làm tham số lọc thì bỏ tham số
đó (ví dụ `stockRepo.reserveIfAvailable(itemId, warehouseId, qty,
session)` → `reserveIfAvailable(itemId, qty, session)`,
`stockRepo.upsertBalance(itemId, warehouseId, ...)` →
`upsertBalance(itemId, ...)`).

### 2.5 Đơn giản hóa `ReservationService`

Bỏ hoàn toàn vòng lặp chọn kho (`findAllActiveWarehouseIds` +
`tryReserveAllAtWarehouse`). Logic mới:

```
reserveForOrder(orderId, items):
  1. Idempotency check (giữ nguyên).
  2. Resolve sku → WarehouseItem, gom missingSkus (giữ nguyên).
  3. Nếu missingSkus rỗng:
     - stagingShelf = locationRepo.findStagingShelf()
     - Nếu không có staging shelf → emitReserveFailed (lý do: cấu hình thiếu)
     - Mở 1 transaction, reserve từng sku trên StockBalance/InventoryStock
       (không còn warehouseId), insert movement RESERVE.
     - Đủ hết → emitReserved (KHÔNG kèm fulfillWarehouseId)
     - Thiếu 1 sku → abort transaction, emitReserveFailed
  4. Có missingSkus → emitReserveFailed luôn (giữ nguyên).
```

Không còn khái niệm "thử kho tiếp theo nếu 1 kho thất bại" — vì chỉ có 1
pool tồn kho, "không đủ tồn" là kết luận cuối cùng, không phải lý do đổi
kho.

Tham số `preferWarehouse` bị xóa khỏi method signature
`reserveForOrder` (không còn nhận, không còn "nhận nhưng bỏ qua" như hiện
tại).

`releaseForOrder` bỏ `warehouseId` khỏi `upsertBalance`/`insertMovement`
calls, giữ nguyên phần còn lại.

### 2.6 Event contract (`libs/events/src/events.ts`)

Xóa:
- `StockReserveRequestedPayload.preferWarehouse?: string`
- `StockReservedPayload.fulfillWarehouseId: string`
- `OrderReadyToFulfillPayload.fulfillWarehouseId: string`
- `PrintRequestedPayload.warehouseId: string`
- `StockLowPayload.warehouseId: string`

Đây là breaking change lên contract dùng chung — cả 2 app (WMS producer,
Ecom consumer) phải deploy cùng lúc hoặc Ecom deploy trước (bỏ field
optional trước khi WMS ngừng gửi). Vì đây là monorepo build/deploy độc
lập nhưng cùng 1 lần release trong task này, xử lý đồng thời — không cần
chiến lược tương thích ngược nhiều phiên bản (khác khuyến cáo "cần chiến
lược tương thích" ở spec gốc §6, không áp dụng vì đây không phải rolling
deploy nhiều môi trường).

### 2.7 Ecommerce app

- `apps/ecommerce/prisma/schema.prisma`: xóa `Order.fulfillWarehouseId`
  (đã là tài liệu tham chiếu, không còn được Prisma đọc — sửa cho khớp
  Mongoose schema).
- `apps/ecommerce/src/order/schemas/order.schema.ts`: xóa field
  `fulfillWarehouseId`.
- `apps/ecommerce/src/order/dto/order.dto.ts`: xóa field response.
- `apps/ecommerce/src/order/reserve.consumer.ts`: bỏ
  `updateOrder(orderId, { fulfillWarehouseId })`.
- `apps/ecommerce/src/order/checkout.service.ts`: bỏ gửi
  `preferWarehouse: 'CENTRAL'` khi emit `STOCK_RESERVE_REQUESTED`.

### 2.8 Seed script

`apps/wms/src/seed/seed.ts`: bỏ bước tạo Warehouse
(`seedWarehouseAndItems` không còn tạo `Warehouse` document); Zone tạo
không kèm `warehouseId`.

### 2.9 Test

Cập nhật/xóa theo phạm vi tương ứng:

- Xóa: `warehouse.service.spec.ts`, `warehouse.repository.spec.ts` (thay
  bằng `location.service.spec.ts`, `location.repository.spec.ts` — giữ
  test Zone/Rack/Shelf, xóa test Warehouse CRUD).
- Sửa: mọi spec còn lại có mock/assert `warehouseId` trên các domain liệt
  kê ở 2.4 — bỏ field đó khỏi fixture và assertion.
- `reservation.service.spec.ts`, `reservation.consumer.spec.ts`: viết lại
  theo logic mới ở 2.5 (không còn candidate loop).
- `apps/wms/test/happy-path.e2e-spec.ts`: bỏ `checkWarehouseId`, bỏ
  `warehouseId` khỏi query Mongo kiểm tra, bỏ `fulfillWarehouseId` khỏi
  payload dựng tay.

## 3. Thứ tự triển khai (theo dependency)

Bám sát §6 spec gốc, cụ thể hóa cho code:

1. **`libs/events`** — sửa event contract trước (2.6), vì mọi app khác
   phụ thuộc type từ đây.
2. **`apps/wms/src/location/`** (đổi tên từ `warehouse/`) — Zone/Rack/Shelf
   bỏ `warehouseId`, thêm unique index staging shelf, xóa Warehouse CRUD
   (2.2, 2.3).
3. **`apps/wms/src/stock/`** — bỏ `warehouseId` khỏi
   StockBalance/InventoryStock/StockMovement + repository methods (2.4).
4. **`apps/wms/src/reservation/`** — viết lại theo 2.5, import
   `LocationModule` thay `WarehouseModule`.
5. **Các module chứng từ còn lại** (`purchase-order`, `goods-receipt-note`,
   `put-away`, `put-away-suggestion`, `goods-issue`, `goods-return`,
   `scrap-note`, `stock-count`, `print-job`, `users`) — bỏ `warehouseId`
   khỏi schema/DTO/service, đổi import `WarehouseModule` →
   `LocationModule` (2.4).
6. **`libs/common/src/errors/error-codes.ts`** — xóa
   `WAREHOUSE_NOT_FOUND`/`WAREHOUSE_CODE_EXISTS`.
7. **`apps/ecommerce`** — 2.7.
8. **Seed** (2.8) — sau khi mọi schema đã đổi.
9. **Test** (2.9) — cập nhật song song với từng bước, không dồn về cuối.
10. **Wipe + reseed dev DB** — xóa collection `warehouses`,
    `zones`/`shelves` cũ (có `warehouseId` field thừa), chạy seed lại.

## 4. Ngoài phạm vi

- Data migration script cho môi trường có dữ liệu thật nhiều kho (không
  cần — môi trường hiện tại chỉ có seed data).
- Warehouse transfer feature (chưa từng tồn tại — không có gì để xóa
  thêm ngoài các điểm đã liệt kê).
- Chiến lược rolling-deploy tương thích ngược cho event contract (xem lý
  do ở 2.6).
- Cập nhật tài liệu `docs/overview/*` — đã xử lý ở spec 23/7 (docs-only),
  không lặp lại ở đây.

## 5. Tiêu chí hoàn thành

- `grep -ril "warehouseId"` trong `apps/`, `libs/` (trừ file lịch sử/spec)
  trả về rỗng.
- Không còn schema/collection `warehouses`; `WarehouseModule`,
  `WarehouseService`, `WarehouseRepository`, `WarehouseController` không
  còn tồn tại trong code.
- `ShelfSchema` có unique index đảm bảo tối đa 1 `isStaging:true`.
- `ReservationService.reserveForOrder` không còn tham số `preferWarehouse`
  và không còn vòng lặp nhiều kho.
- `StockReservedPayload`/`OrderReadyToFulfillPayload` không còn
  `fulfillWarehouseId`; `StockReserveRequestedPayload` không còn
  `preferWarehouse`.
- Ecom `Order` không còn `fulfillWarehouseId` ở schema/DTO/Prisma tham
  chiếu.
- `pnpm lint`, `pnpm test`, `pnpm build` chạy sạch cho cả `wms` và
  `ecommerce`.
- Seed chạy lại thành công, tạo được Zone/Rack/Shelf không có
  `warehouseId`, đúng 1 staging shelf.
