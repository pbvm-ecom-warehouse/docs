# S3-03: UC-06 Kiểm kê & điều chỉnh tồn — Design

**Nguồn:** [planning/issues/S3-03-stock-count.md](../../planning/issues/S3-03-stock-count.md), [warehouse/use-cases.md#UC-06](../../warehouse/use-cases.md), [db/05-xuat-kho-va-noi-bo.md](../../db/05-xuat-kho-va-noi-bo.md), [overview/erd.dbml](../../overview/erd.dbml)

## Bối cảnh

UC-06 khác các module trước (`GoodsIssue`, `PrintJob`, `PutAwayTask`): **không sinh tự động từ event**, mà do MANAGER chủ động khởi tạo. Mục đích: đối chiếu tồn hệ thống (`InventoryStock`) với tồn đếm thực tế tại vị trí (shelf/lot), phát hiện chênh lệch, và MANAGER duyệt để hợp thức hoá bằng `StockMovement` loại `ADJUST` — **không bao giờ sửa thẳng `onHand`**.

Actor: **MANAGER** tạo phiếu + duyệt điều chỉnh; **COUNTER** đếm thực tế và nhập số.

## Phạm vi & quyết định thiết kế đã chốt

1. **Phiếu tạo tay bởi MANAGER, không qua consumer event** — khác mọi module trước. `POST /stock-counts` nhận `warehouseId` + `zoneId?` (`null`/bỏ qua = toàn kho).
2. **Danh sách dòng cần đếm auto-generate từ `InventoryStock` hiện có** — không phải MANAGER tự nhập tay từng sku. Tại thời điểm tạo phiếu, hệ thống liệt kê mọi bản ghi `InventoryStock` trong phạm vi (lọc theo `warehouseId`, và theo `zoneId` nếu có — join `Shelf.rackId → Rack.zoneId` để lấy danh sách `shelfId` thuộc zone, xem chi tiết ở mục "WarehouseRepository" bên dưới), copy `systemQty = InventoryStock.quantity` vào từng dòng. Vị trí (shelf/lot) không có `InventoryStock` (tồn = 0) sẽ không xuất hiện trong phiếu — ngoài phạm vi task này (chỉ đối chiếu tồn đã ghi nhận, không phát hiện "hàng lạ chưa từng nhập").
3. **Đếm theo (item, shelf, lot) khớp ERD `stock_count_items`** — không gộp theo item. Mỗi dòng ứng với đúng 1 `InventoryStock` cụ thể, phát hiện được cả lệch số lượng lẫn lệch vị trí.
4. **2 bước tách biệt: COUNTER nhập đếm → MANAGER duyệt riêng** — khớp acceptance criteria "Chưa duyệt → tồn chưa đổi". COUNTER nhập `actualQty` không làm thay đổi tồn ngay; chỉ khi MANAGER gọi `approve` mới áp dụng `ADJUST`.
5. **Trạng thái tự chuyển `IN_PROGRESS`/`COMPLETED` theo tiến độ nhập, `APPROVED` do MANAGER chủ động** — COUNTER nhập dòng đầu tiên → `DRAFT → IN_PROGRESS` (set `countedBy`); nhập xong dòng cuối cùng → tự `IN_PROGRESS → COMPLETED` (giống `markConfirmedIfAllDone` của `GoodsIssue`). `approve` chỉ cho phép khi `status = COMPLETED`.
6. **1 action `approve` duyệt cả phiếu, kèm 1 `reason` chung** — không duyệt/reject từng dòng riêng lẻ. Áp dụng `ADJUST` cho **mọi dòng có `delta !== 0`** trong cùng 1 transaction. Khớp scope size M của issue.
7. **Luôn bắn `stock.changed` khi `delta !== 0`** — vì điều chỉnh đổi thẳng `onHand` (không qua `reserved`) nên `available` đổi theo, phải sync Ecom. Khớp bảng tổng kết trong `db/05-xuat-kho-va-noi-bo.md`: "StockCount | ADJUST ± | ✅ (nếu available đổi)".
8. **Không có `CANCELLED` trong lần này** — ERD có liệt kê nhưng không thuộc scope size M của issue; để ngoài phạm vi, làm task riêng nếu cần.
9. **Không tự tạo `Lot` hay `InventoryStock` mới lúc generate** — phiếu chỉ phản ánh tồn đã có ghi nhận tại thời điểm tạo. Vị trí/lô "ma" phát hiện lúc đếm thực tế (COUNTER thấy hàng ở vị trí không có trong phiếu) không thuộc luồng chính này.

## Kiến trúc

Module mới `apps/wms/src/stock-count/`, đặt cạnh `goods-issue`/`print-job`, import `StockModule` + `WarehouseModule`.

```
apps/wms/src/stock-count/
  schemas/stock-count.schema.ts
  dto/stock-count.dto.ts     (request: CreateStockCountDto, CountStockCountItemDto, ApproveStockCountDto, QueryStockCountDto; response: StockCountResponseDto)
  stock-count.repository.ts
  stock-count.service.ts
  stock-count.controller.ts
  stock-count.module.ts
```

Đăng ký `StockCountModule` vào `AppModule`. Không có consumer — module này không nghe event nào.

### Schema: `StockCount`

Chứng từ giao dịch — hủy bằng `status`, KHÔNG soft-delete.

```ts
export enum StockCountStatus {
  DRAFT = 'DRAFT',
  IN_PROGRESS = 'IN_PROGRESS',
  COMPLETED = 'COMPLETED',
  APPROVED = 'APPROVED',
}

@Schema({ _id: false })
class StockCountItem {
  itemId: Types.ObjectId;     // required — WarehouseItem
  sku: string;                 // required — denormalized, để hiển thị
  shelfId: Types.ObjectId;    // required
  lotId: Types.ObjectId | null; // null nếu item không isPerishable
  systemQty: number;           // required, min 0 — copy từ InventoryStock lúc tạo phiếu
  actualQty: number | null;    // null = COUNTER chưa đếm dòng này
  delta: number | null;        // = actualQty - systemQty, tính khi COUNTER nhập
  reason: string | null;       // COUNTER ghi khi nhập (tuỳ chọn) hoặc rỗng
}

@Schema({ collection: 'stock_counts', timestamps: true })
export class StockCount {
  warehouseId: Types.ObjectId;  // required
  zoneId: Types.ObjectId | null; // null = toàn kho
  status: StockCountStatus;      // default DRAFT
  note?: string;
  createdBy: Types.ObjectId;     // MANAGER tạo phiếu
  countedBy?: Types.ObjectId;    // COUNTER — set khi nhập dòng đầu tiên
  approvedBy?: Types.ObjectId;   // MANAGER — set khi approve
  approveReason?: string;        // lý do chung ghi lúc duyệt
  items: StockCountItem[];       // required
}
```

Index: `{ warehouseId: 1, status: 1 }`, `{ status: 1 }`.

> Không có unique index theo `warehouseId`/`zoneId` — một kho/zone có thể có nhiều phiếu kiểm theo thời gian (không giống `GoodsIssue`/`PrintJob` vốn 1-1 với `orderId`).

### DTO

**Request:**
- `CreateStockCountDto`: `{ warehouseId: string; zoneId?: string; note?: string }`
- `CountStockCountItemDto` (body của `POST /:id/items/:itemId/count`): `{ shelfId: string; lotId?: string; actualQty: number; reason?: string }`
- `ApproveStockCountDto`: `{ reason?: string }`
- `QueryStockCountDto`: `{ status?: StockCountStatus; warehouseId?: string; page?: number; limit?: number }`

**Response:** `StockCountResponseDto` (+ nested `StockCountItemResponseDto`) theo đúng convention `@Expose()` + `plainToInstance`.

### Service — luồng chi tiết

**1. Tạo phiếu** — `createStockCount(dto, actorId)`
- Validate `warehouseId` tồn tại (qua `WarehouseRepository`); nếu có `zoneId`, validate thuộc `warehouseId` đó (qua `findZoneById`, so `zone.warehouseId`).
- Nếu có `zoneId`: gọi `warehouseRepo.findShelfIdsByZone(zoneId)` lấy danh sách `shelfId` thuộc zone, rồi `stockRepo.findInventoryByScope(warehouseId, shelfIds)`. Nếu không có `zoneId`: gọi `findInventoryByScope(warehouseId)` (không kèm `shelfIds` → lấy toàn kho). Chữ ký thống nhất: `findInventoryByScope(warehouseId: Types.ObjectId, shelfIds?: Types.ObjectId[])` (xem mục "StockRepository" bên dưới).
- Với mỗi `InventoryStock` tìm được, tạo 1 `StockCountItem` với `systemQty = quantity`, `actualQty = null`, `delta = null`.
- Nếu không có dòng nào (phạm vi trống) → `AppException('STOCK_COUNT_EMPTY_SCOPE')`, không tạo phiếu rỗng.
- `status = DRAFT`, `createdBy = actorId`.

**2. COUNTER nhập đếm** — `countItem(id, itemId, dto, actorId)`
- Tìm phiếu; nếu không tồn tại → `STOCK_COUNT_NOT_FOUND`.
- Nếu `status = APPROVED` → `STOCK_COUNT_ALREADY_APPROVED` (không cho sửa sau khi đã duyệt).
- Tìm đúng dòng khớp `itemId` + `dto.shelfId` + `dto.lotId ?? null` → không khớp → `STOCK_COUNT_ITEM_MISMATCH`.
- Set `actualQty = dto.actualQty`, `delta = actualQty - systemQty`, `reason = dto.reason ?? null`.
- Nếu đây là lần nhập đầu tiên của phiếu (status đang `DRAFT`) → set `status = IN_PROGRESS`, `countedBy = actorId`.
- Sau khi update, kiểm tra: mọi dòng đã có `actualQty !== null` → set `status = COMPLETED`.
- Không cần transaction Mongo (chưa đụng tới `InventoryStock`/`StockBalance` thật) — chỉ update field trong mảng `items` của chính `StockCount`, dùng `$elemMatch` như `GoodsIssueRepository.decrementRemainingQty`.

**3. MANAGER duyệt** — `approveStockCount(id, dto, actorId)`
- Tìm phiếu; `status !== COMPLETED` → `STOCK_COUNT_NOT_COMPLETED`.
- Trong 1 `stockTransactionHelper.withStockTransaction`, với mỗi dòng có `delta !== 0`:
  - `stockRepo.upsertInventory(itemId, warehouseId, shelfId, lotId, delta, session)` — cộng dồn delta (không set tuyệt đối, để tái dùng helper `$inc` sẵn có; vì `actualQty` đã tính đúng bằng `systemQty + delta` nên kết quả tương đương set = actualQty, miễn `InventoryStock` không bị thay đổi bởi giao dịch khác song song trong lúc phiếu đang mở — chấp nhận được vì UC-06 giả định không có xuất/nhập chồng lên trong lúc kiểm).
  - `stockRepo.upsertBalance(itemId, warehouseId, delta, 0, 0, session)` — `onHand += delta`, `reserved`/`expired` không đổi.
  - `stockRepo.insertMovement({ itemId, warehouseId, shelfId, lotId, type: MovementType.ADJUST, quantity: delta, refType: 'stock_count', refId: stockCountId, createdBy: actorId }, session)`.
  - `repo.setApproved(id, actorId, dto.reason, session)` set `status = APPROVED`, `approvedBy`, `approveReason`.
- Sau khi transaction commit, với mỗi dòng có `delta !== 0`, bắn `stock.changed` `{ sku, delta }` lên `QUEUES.STOCK` (`jobId: stock_count:${id}:${sku}` để idempotent nếu retry).
- Nếu không có dòng nào lệch (`delta === 0` hết) → vẫn set `APPROVED` nhưng bỏ qua transaction/movement/event (không có gì để ghi).

**4. List/Detail** — `listStockCounts(query)`, `getStockCount(id)` — pattern giống `GoodsIssueService`.

### `MovementType.ADJUST` đã tồn tại sẵn

`apps/wms/src/stock/schemas/stock-movement.schema.ts` đã có `ADJUST` trong enum `MovementType` — không cần thêm.

### `StockRepository` — method cần bổ sung

- `findInventoryByScope(warehouseId: Types.ObjectId, shelfIds?: Types.ObjectId[]): Promise<InventoryStockDocument[]>` — nếu `shelfIds` truyền vào thì lọc `shelfId: { $in: shelfIds }`, không thì chỉ lọc `warehouseId`.
- `upsertInventory`/`upsertBalance`/`insertMovement` đã có sẵn (dùng lại y hệt `GoodsIssueService`/`PrintJobService`).

### `WarehouseRepository` — method cần bổ sung

`Shelf` không có `zoneId` denormalized (chỉ có `rackId` + `warehouseId`, xem `shelf.schema.ts`) — phải join 2 tầng `Shelf.rackId → Rack.zoneId`. Thêm method:

- `findShelfIdsByZone(zoneId: string): Promise<Types.ObjectId[]>` — lấy mọi `Rack` thuộc `zoneId` (`findRacksByZone` đã có sẵn) → lấy mọi `Shelf` thuộc các `rackId` đó (`findShelvesByRack` đã có sẵn, gọi lặp hoặc mở rộng thành `findShelvesByRacks(rackIds: string[])` nhận mảng) → trả về danh sách `shelfId`.

### Error codes mới (`WMS_ERRORS`)

```
STOCK_COUNT_NOT_FOUND          404  Không tìm thấy phiếu kiểm kho
STOCK_COUNT_EMPTY_SCOPE        400  Không có tồn kho nào trong phạm vi đã chọn
STOCK_COUNT_ITEM_MISMATCH      400  Vị trí/lô không thuộc phiếu kiểm kho này
STOCK_COUNT_ALREADY_APPROVED   409  Phiếu đã duyệt, không thể sửa
STOCK_COUNT_NOT_COMPLETED      409  Phiếu chưa đếm xong, không thể duyệt
```

### Routes & roles

| Method | Path | Roles | Mô tả |
|---|---|---|---|
| POST | `/stock-counts` | MANAGER, ADMIN | Tạo phiếu kiểm kho (auto-generate dòng) |
| GET | `/stock-counts` | MANAGER, COUNTER, ADMIN | Danh sách phiếu |
| GET | `/stock-counts/:id` | MANAGER, COUNTER, ADMIN | Chi tiết phiếu + báo cáo chênh lệch |
| POST | `/stock-counts/:id/items/:itemId/count` | COUNTER, ADMIN | Nhập số đếm thực cho 1 dòng |
| POST | `/stock-counts/:id/approve` | MANAGER, ADMIN | Duyệt điều chỉnh cho cả phiếu |

## Testing

- **Schema spec**: validate enum, default status, sub-document shape (giống `print-job.schema.spec.ts`).
- **Repository spec**: `findInventoryByScope` (có/không zoneId), `setApproved`, update dòng qua `$elemMatch`.
- **Service spec** (trọng tâm):
  - Tạo phiếu: đúng số dòng generate từ `InventoryStock`, đúng `systemQty`; phạm vi trống → throw `STOCK_COUNT_EMPTY_SCOPE`.
  - Đếm dòng đầu tiên → `DRAFT → IN_PROGRESS`, set `countedBy`.
  - Đếm hết mọi dòng → tự `COMPLETED`.
  - Đếm khi đã `APPROVED` → throw.
  - Duyệt khi chưa `COMPLETED` → throw `STOCK_COUNT_NOT_COMPLETED`.
  - Duyệt với dòng lệch dương/âm → đúng `InventoryStock`/`StockBalance.onHand` sau cùng, đúng `StockMovement.quantity` (dấu đúng theo delta), đúng số lần bắn `stock.changed`.
  - Duyệt với mọi dòng `delta = 0` → không có movement/event nào, vẫn set `APPROVED`.
  - **Acceptance criteria trực tiếp**: đếm lệch +N/−N → sau duyệt `onHand` khớp `actualQty`; chưa duyệt → tồn chưa đổi (assert `InventoryStock`/`StockBalance` không đổi ngay sau bước `countItem`).

## Ngoài phạm vi (không làm trong task này)

- Status `CANCELLED`.
- Phát hiện "hàng lạ" tại vị trí không có trong `InventoryStock` lúc tạo phiếu.
- Duyệt/reject từng dòng riêng lẻ (chỉ có 1 action approve cho cả phiếu).
- Tự tạo `Lot` mới khi đếm ra lô chưa từng có trong hệ thống.
