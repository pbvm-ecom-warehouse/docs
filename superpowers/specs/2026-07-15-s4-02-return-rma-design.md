# S4-02: UC-09 Hoàn hàng (Return / RMA) — Design

**Nguồn:** [warehouse/use-cases.md#UC-09](../../warehouse/use-cases.md), [warehouse/data-model.md](../../warehouse/data-model.md), [order/workflow.md#WF-E05](../../order/workflow.md), [planning/issues/S4-02-return-rma.md](../../planning/issues/S4-02-return-rma.md), spec liền trước [2026-07-14-s4-01-scrap-note-design.md](./2026-07-14-s4-01-scrap-note-design.md)

## Bối cảnh

UC-09 nhận hàng khách trả về kho (RMA) sau khi đã giao thành công. Ecommerce đã có sẵn `OrderService.returnOrder()` (`apps/ecommerce/src/order/order.service.ts:270`) bắn `order.returned` kèm `{ orderId, items: [{sku, quantity}] }` lên `QUEUES.ORDER` — nhưng **WMS hiện chưa có consumer nào lắng nghe event này**. Nhiệm vụ của task này là: nhận event đó, để RECEIVER kiểm tra tình trạng từng dòng, và ghi tồn đúng — hàng tốt nhập lại kho, hàng hỏng đẩy sang hủy (UC-08, module `scrap-note` đã có từ S4-01).

RMA từng phần theo `orderId` cụ thể; không xử lý hoàn theo `shipment.returned` (giao thất bại hẳn) trong task này — event đó là chiều ngược (WMS→Ecom), không liên quan input của module này.

## Phạm vi & quyết định thiết kế đã chốt

1. **Tự động sinh `GoodsReturn` DRAFT khi nhận `order.returned`** — không bắt RECEIVER gõ lại tay `orderId`/`sku`/`quantity` từ đơn gốc. Khớp use-case ("Trigger: `order.returned`... hoặc lập tay") — event là đường chính, tạo tay là đường phụ cho các nguồn ngoài Ecommerce (hàng lỗi NCC trả trực tiếp tại kho, v.v.).
2. **`warehouseId` bỏ trống ở bước DRAFT, RECEIVER gán khi inspect** — `OrderReturnedPayload` không kèm kho nhận trả, và hệ thống có nhiều kho nên không đoán được kho nào sẽ vật lý nhận lại hàng. `GoodsReturn.warehouseId` là optional cho tới khi `INSPECTED`.
3. **`sku → itemId` resolve ở consumer bằng `StockRepository.findItemBySku`** (đã có sẵn, dùng lại y hệt cách `goods-issue.service.ts`/`print-job.service.ts` resolve sku). Dòng nào không tìm thấy item theo sku → bỏ qua dòng đó, log warning, không throw (event đã xảy ra ở Ecom, không thể reject); các dòng còn lại vẫn tạo bình thường.
4. **2 bước tách biệt: `inspect` rồi `confirm`** — khớp 4 trạng thái đã liệt kê trong use-case (`DRAFT → INSPECTED → RESTOCKED` / `CANCELLED`). `inspect` chỉ gán `condition`/`shelfId`/`lotId` cho từng dòng và set `warehouseId`, **chưa đụng tồn kho thật** — cho phép RECEIVER rà soát/sửa lại trước khi chốt. `confirm` mới thực sự ghi tồn, không thể sửa dòng sau khi đã `confirm`.
5. **Hàng DAMAGED cũng phải "nhập kho tạm rồi hủy ngay" trong cùng bước `confirm`** — vì `ScrapNote.approveScrapNote()` (S4-01) giả định tồn đã tồn tại sẵn trong `InventoryStock`/`onHand` trước khi trừ. Hàng DAMAGED từ RMA vừa về tới kho, **chưa từng** được cộng vào tồn. Do đó `confirm()` với dòng DAMAGED: (a) cộng tạm `InventoryStock += qty`, `StockBalance.onHand += qty` + ghi `StockMovement RETURN_IN` tại đúng `shelfId` RECEIVER chỉ định lúc inspect (thường là shelf staging), rồi (b) gọi luôn `ScrapNoteService` tạo + approve 1 `ScrapNote` cho đúng dòng đó (cùng transaction về mặt nghiệp vụ — xem mục 7). Số sách nhất quán: nhập bao nhiêu, hủy đúng bấy nhiêu, có đầy đủ 2 `StockMovement` (`RETURN_IN` rồi `SCRAP`) làm audit trail.
6. **Không bắn `stock.changed` cho phần DAMAGED ở bất kỳ bước nào** — hàng hỏng chưa từng bán được nên `available` không được tăng lúc nhập tạm, và cũng không được giảm lúc scrap (nếu giảm sẽ trừ vào phần chưa từng cộng → `available` sai âm giả). Cụ thể:
   - Bước nhập tạm (`RETURN_IN` cho dòng DAMAGED): **không** bắn `stock.changed(+)`.
   - Bước scrap dòng đó: **không** bắn `stock.changed(-)` — cần thay đổi `ScrapNote` để hỗ trợ trường hợp này (xem mục 8).
   - Ngược lại, dòng GOOD: nhập lại kho là hàng **thật sự** bán được → **có** bắn `stock.changed(+qty)` sau khi transaction commit.
7. **Ranh giới transaction**: `confirm()` chạy 1 `stockTransactionHelper.withStockTransaction` bao trọn tất cả các thao tác tồn kho của mọi dòng (GOOD: `InventoryStock+`/`onHand+`/`RETURN_IN`; DAMAGED: `InventoryStock+`/`onHand+`/`RETURN_IN` rồi ngay `InventoryStock-`/`onHand-`/`SCRAP`) + tạo document `ScrapNote` (đã `APPROVED` ngay, không ở trạng thái `DRAFT` chờ duyệt riêng — xem mục 9) + set `GoodsReturn.status = RESTOCKED`. Sau khi commit mới bắn các `stock.changed(+)` cho dòng GOOD (pattern giống `ScrapNoteService.approveScrapNote`: đổi tồn trong transaction, publish event sau khi transaction thành công).
8. **Thêm cờ `skipAvailableSync` vào `ScrapNoteItem`** (default `false`) — khi `GoodsReturnService` gọi tạo `ScrapNote` cho dòng DAMAGED, set cờ này `true` trên dòng đó. `ScrapNoteService.approveScrapNote()` sửa điều kiện bắn `stock.changed`: bỏ qua dòng nếu `line.lotId` **hoặc** `line.skipAvailableSync` (trước đây chỉ check `line.lotId`). Đây là thay đổi tối thiểu, không đổi hành vi UC-08 gốc (cờ mặc định `false`, dòng Scrap tạo thủ công qua `POST /scrap-notes` không bao giờ set cờ này).
9. **`ScrapNote` sinh từ GoodsReturn được tạo và duyệt (APPROVED) ngay lập tức trong cùng thao tác `confirm()`** — không dừng ở `DRAFT` chờ MANAGER duyệt riêng. Lý do: RECEIVER đã tự kiểm tra và phân loại DAMAGED lúc `inspect` (bước đó **là** sự xác nhận nghiệp vụ cho việc hủy hàng chưa từng nhập kho); bắt MANAGER duyệt thêm 1 lần nữa cho hàng chưa từng có giá trị tồn thật là thừa. Field `reason` của `ScrapNoteItem` set cố định `'Hàng hoàn trả bị hỏng (RMA)'`. `ScrapNote.createdBy` = `approvedBy` = actor gọi `confirm()`.
10. **Hàng `isPerishable` bắt buộc có `lotId` hợp lệ mới được nhập lại (GOOD)** — khớp use-case bước 5 ("hàng `isPerishable` cần lô + hạn còn hợp lệ mới được nhập lại"). Tại bước `inspect`, nếu `item.isPerishable` và dòng `condition = GOOD` mà thiếu `lotId` → lỗi `GOODS_RETURN_ITEM_ISPERISHABLE_NO_LOT`. Không validate hạn dùng (`expiryDate`) tự động trong task này — RECEIVER tự chọn đúng lô còn hạn bằng nghiệp vụ ngoài hệ thống (nhất quán với quyết định "không xây cron EXPIRED" của S4-01); nếu chọn nhầm lô đã hết hạn, hệ thống không chặn (chấp nhận rủi ro nhỏ, ngoài phạm vi).
11. **Không hỗ trợ hoàn từng phần theo dòng khác `quantity` gốc của đơn** — số lượng mỗi dòng GoodsReturn cố định theo `OrderReturnedPayload.items` (khi tự sinh) hoặc theo input `POST /goods-returns` (khi tạo tay); không có API tách 1 dòng thành nhiều dòng theo tình trạng khác nhau (vd 3 cái trong 1 dòng, 2 tốt + 1 hỏng). RECEIVER inspect **cả dòng** là 1 `condition` duy nhất. Khớp giới hạn đã ghi trong `S4-02-return-rma.md`: "RMA từng phần ngoài phạm vi".
12. **1 API `inspect` cho toàn bộ phiếu** (không phải từng dòng riêng lẻ) — RECEIVER gửi mảng đầy đủ `{ itemId, condition, shelfId, lotId? }` cho mọi dòng trong 1 request, giống cách `ScrapNote` nhận toàn bộ `items` trong 1 lần tạo. Đơn giản hoá, tránh trạng thái nửa-vời (1 số dòng đã inspect, số khác chưa).
13. **Cho phép huỷ phiếu (`CANCELLED`)** ở trạng thái `DRAFT` hoặc `INSPECTED` — chưa `confirm` thì chưa đụng tồn kho thật, huỷ an toàn. Không cho huỷ sau khi đã `RESTOCKED`.

## Kiến trúc

Module mới `apps/wms/src/goods-return/`, đặt cạnh `scrap-note/`, import `StockModule` + `WarehouseModule` + `ScrapNoteModule` (để gọi tạo+duyệt Scrap cho dòng DAMAGED) + tự đăng ký consumer cho `QUEUES.ORDER`.

```
apps/wms/src/goods-return/
  schemas/goods-return.schema.ts
  dto/goods-return.dto.ts       (request: CreateGoodsReturnDto, InspectGoodsReturnDto, QueryGoodsReturnDto; response: GoodsReturnResponseDto)
  goods-return.repository.ts
  goods-return.service.ts
  goods-return.controller.ts
  order-returned.consumer.ts    (Processor QUEUES.ORDER, event ORDER_RETURNED)
  goods-return.module.ts
```

Đăng ký `GoodsReturnModule` vào `AppModule`, sau `ScrapNoteModule`.

> `QUEUES.ORDER` hiện đã được `GoodsIssueModule` (`order-ready.consumer.ts`, event `ORDER_READY_TO_FULFILL`) đăng ký `BullModule.registerQueue`. `GoodsReturnModule` tự `registerQueue` thêm lần nữa cho cùng queue (NestJS/BullMQ cho phép nhiều module cùng đăng ký 1 queue) — Processor mới lắng nghe cùng queue nhưng `switch (job.name)` khác event nên không xung đột.

### Schema: `GoodsReturn`

Chứng từ giao dịch — hủy bằng `status`, KHÔNG soft-delete.

```ts
export enum GoodsReturnStatus {
  DRAFT = 'DRAFT',
  INSPECTED = 'INSPECTED',
  RESTOCKED = 'RESTOCKED',
  CANCELLED = 'CANCELLED',
}

export enum GoodsReturnItemCondition {
  GOOD = 'GOOD',
  DAMAGED = 'DAMAGED',
}

@Schema({ _id: false })
class GoodsReturnItem {
  itemId: Types.ObjectId;                     // required
  sku: string;                                 // required — denormalized, hiển thị
  quantity: number;                             // required, min 1
  condition: GoodsReturnItemCondition | null;   // null cho tới khi inspect
  shelfId: Types.ObjectId | null;               // null cho tới khi inspect — vị trí nhập lại (GOOD) hoặc nhập tạm (DAMAGED)
  lotId: Types.ObjectId | null;                 // bắt buộc nếu item.isPerishable && condition=GOOD
  scrapNoteId: Types.ObjectId | null;           // set sau confirm nếu condition=DAMAGED
}

@Schema({ collection: 'goods_returns', timestamps: true })
export class GoodsReturn {
  orderId?: string;              // đơn gốc bên Ecommerce (string — KHÔNG populate xuyên app); optional khi tạo tay không gắn đơn cụ thể
  warehouseId: Types.ObjectId | null; // null ở DRAFT — RECEIVER gán khi inspect
  status: GoodsReturnStatus;     // default DRAFT
  note?: string;
  createdBy: Types.ObjectId | null; // null nếu tự sinh từ event (chưa có actor); set actor khi inspect
  items: GoodsReturnItem[];      // required
}
```

Index: `{ orderId: 1 }` (tra theo đơn gốc), `{ warehouseId: 1, status: 1 }`, `{ status: 1 }`.

> `createdBy` nullable — khác `ScrapNote` (luôn có `createdBy` vì tạo tay). Ở đây phiếu có thể được hệ thống tự sinh từ event mà chưa có actor con người nào — set giá trị thật khi RECEIVER thao tác `inspect` lần đầu (coi như "nhận việc").

### Đổi `ScrapNoteItem` (S4-01) — thêm cờ `skipAvailableSync`

```ts
@Schema({ _id: false })
class ScrapNoteItem {
  // ... các field hiện có (itemId, sku, shelfId, lotId, quantity, reason) giữ nguyên
  skipAvailableSync: boolean; // default false — true khi ScrapNote này sinh từ GoodsReturn (hàng DAMAGED chưa từng vào available)
}
```

`ScrapNoteService.approveScrapNote()` sửa điều kiện publish `stock.changed`:

```ts
for (const line of scrapNote.items) {
  if (line.lotId || line.skipAvailableSync) continue; // bỏ qua cả 2 trường hợp
  // bắn stock.changed(-quantity)
}
```

### DTO

**Request:**
- `CreateGoodsReturnDto`: `{ orderId?: string; note?: string; items: CreateGoodsReturnItemDto[] }`
  - `CreateGoodsReturnItemDto`: `{ itemId: string; quantity: number }` — chỉ dùng khi tạo tay (không qua event); `condition`/`shelfId`/`lotId` set sau ở bước inspect.
- `InspectGoodsReturnDto`: `{ warehouseId: string; items: InspectGoodsReturnItemDto[] }`
  - `InspectGoodsReturnItemDto`: `{ itemId: string; condition: GoodsReturnItemCondition; shelfId: string; lotId?: string }`
- `QueryGoodsReturnDto`: `{ status?: GoodsReturnStatus; warehouseId?: string; orderId?: string; page?: number; limit?: number }`

**Response:** `GoodsReturnResponseDto` (+ nested `GoodsReturnItemResponseDto`) theo convention `@Expose()` + `plainToInstance`.

### Consumer — `order-returned.consumer.ts`

```
@Processor(QUEUES.ORDER)
class OrderReturnedConsumer extends WorkerHost {
  process(job):
    switch job.name:
      case ORDER_RETURNED:
        goodsReturnService.createFromOrderReturned(data.orderId, data.items)
      default: logger.warn — không throw (đã có OrderReadyConsumer xử lý ORDER_READY_TO_FULFILL trên cùng queue)
}
```

`createFromOrderReturned(orderId, items)`:
- Idempotency: kiểm tra đã tồn tại `GoodsReturn` với `orderId` này chưa (`findByOrderId`) — nếu có rồi thì bỏ qua, log warning (chống retry BullMQ tạo trùng phiếu).
- Với mỗi `{sku, quantity}`: `stockRepo.findItemBySku(sku)` → không tìm thấy → log warning, bỏ qua dòng này (không throw, event đã xảy ra ở Ecom).
- Tạo `GoodsReturn{status: DRAFT, orderId, warehouseId: null, createdBy: null, items: [...]}` với các dòng resolve được.
- Nếu **không có dòng nào** resolve được (toàn bộ sku lạ) → vẫn tạo phiếu rỗng `items: []`? **Không** — bỏ qua, chỉ log error, không tạo phiếu rỗng vô nghĩa.

### Service — luồng chi tiết

**1. Tạo phiếu tay** — `createGoodsReturn(dto, actorId)`
- Với mỗi dòng: `WarehouseItem` tồn tại theo `itemId` (`StockRepository.findItemById`) → không → `STOCK_ITEM_NOT_FOUND`.
- Tạo `GoodsReturn{status: DRAFT, orderId: dto.orderId, warehouseId: null, createdBy: actorId, items: [...]}` (mỗi dòng `condition/shelfId/lotId/scrapNoteId = null`).

**2. RECEIVER kiểm tra** — `inspectGoodsReturn(id, dto, actorId)`
- Tìm phiếu; không có → `GOODS_RETURN_NOT_FOUND`. `status !== DRAFT` → `GOODS_RETURN_ALREADY_DECIDED` (dùng chung 1 code cho mọi trạng thái không hợp lệ để inspect, giống cách `SCRAP_NOTE_ALREADY_DECIDED` dùng chung cho APPROVED/REJECTED).
- Validate `warehouseId` tồn tại (`WarehouseRepository.findWarehouseById`) → không → `WAREHOUSE_NOT_FOUND`.
- `dto.items` phải khớp đầy đủ (cùng số dòng, cùng `itemId`) với `GoodsReturn.items` hiện có — thiếu dòng nào → `GOODS_RETURN_ITEM_NOT_FOUND`.
- Với mỗi dòng: `Shelf` tồn tại (`WarehouseRepository.findShelfById`) → không → `SHELF_NOT_FOUND` (cross-cutting code có sẵn). Nếu `item.isPerishable && condition === GOOD && !lotId` → `GOODS_RETURN_ITEM_ISPERISHABLE_NO_LOT`.
- Set `warehouseId`, cập nhật từng dòng `condition/shelfId/lotId`, `status = INSPECTED`. Chưa đụng tồn kho.

**3. RECEIVER xác nhận** — `confirmGoodsReturn(id, actorId)`
- Tìm phiếu; `status !== INSPECTED` → `GOODS_RETURN_NOT_INSPECTED`.
- Trong 1 `stockTransactionHelper.withStockTransaction`, với **mỗi dòng**:
  - `stockRepo.upsertInventory(itemId, warehouseId, shelfId, lotId, +quantity, session)`
  - `stockRepo.upsertBalance(itemId, warehouseId, +quantity, 0, 0, session)` — `onHand += quantity`.
  - `stockRepo.insertMovement({ ..., type: RETURN_IN, quantity: +quantity, refType: 'goods_return', refId, createdBy: actorId }, session)`.
  - Nếu `condition === DAMAGED`: ngay sau đó gọi `scrapNoteService` (thêm method nội bộ nhận `session` — xem ghi chú dưới) để trừ lại đúng số lượng vừa cộng tại đúng `shelfId`/`lotId`, ghi `StockMovement SCRAP`, tạo `ScrapNote{status: APPROVED, createdBy: actorId, approvedBy: actorId, items: [{ itemId, sku, shelfId, lotId, quantity, reason: 'Hàng hoàn trả bị hỏng (RMA)', skipAvailableSync: true }]}` trong cùng `session`; lưu `scrapNoteId` vào dòng `GoodsReturnItem` tương ứng.
  - Nếu `condition === GOOD`: gom vào danh sách để bắn `stock.changed(+quantity)` sau khi commit.
  - `repo.setRestocked(id, session)` set `status = RESTOCKED`.
- Sau khi transaction commit: bắn `stock.changed({sku, delta: +quantity})` cho **từng dòng GOOD** (`jobId: goods_return:${id}:${sku}` để idempotent). Dòng DAMAGED không bắn gì.

> **Ghi chú kỹ thuật quan trọng**: `ScrapNoteService.approveScrapNote()` hiện tại tự tìm phiếu theo `id` rồi mới chạy transaction riêng của nó — không nhận `session` từ ngoài truyền vào, và tạo `ScrapNote` qua `ScrapNoteRepository.createScrapNote()` (luôn `status: DRAFT`). Vì `confirmGoodsReturn` cần cả tạo-và-duyệt trong **cùng transaction** của chính nó, `GoodsReturnModule` cần 1 trong 2 cách:
> - (a) Thêm method mới `ScrapNoteRepository.createApprovedScrapNote(...)` chuyên dụng, nhận `session`, tạo thẳng document `status: APPROVED` (bỏ qua bước DRAFT) — dùng riêng cho luồng RMA, không đổi API `ScrapNoteService` hiện có.
> - (b) `GoodsReturnService` tự gọi trực tiếp `StockRepository` (`upsertInventory`/`upsertBalance`/`insertMovement`) để trừ tồn + tự tạo `ScrapNote` document qua `ScrapNoteRepository` với `status: APPROVED` ngay, không qua `ScrapNoteService.approveScrapNote()`.
>
> Chọn **(a)**: thêm `ScrapNoteRepository.createApprovedScrapNote(warehouseId, createdBy, lines, session)` — tránh trùng lặp logic trừ tồn (dùng chung `StockRepository` helpers vẫn qua service layer `ScrapNoteService.createApprovedScrapNoteForReturn(...)` gọi cả `StockRepository` lẫn `ScrapNoteRepository` trong `session` được truyền vào). `ScrapNoteModule` export thêm method này bên cạnh method cũ; `GoodsReturnModule` import `ScrapNoteModule`.

**4. Huỷ phiếu** — `cancelGoodsReturn(id, actorId)`
- Tìm phiếu; `status === RESTOCKED` → `GOODS_RETURN_ALREADY_DECIDED`. `status === CANCELLED` → cùng lỗi.
- Set `status = CANCELLED`. Không đụng tồn kho.

**5. List/Detail** — `listGoodsReturns(query)`, `getGoodsReturn(id)` — pattern giống `ScrapNoteService`.

### `MovementType.RETURN_IN` — cần thêm mới

`apps/wms/src/stock/schemas/stock-movement.schema.ts` **chưa có** `RETURN_IN` trong enum `MovementType` (hiện có: `RECEIVE, PUTAWAY, ISSUE, ADJUST, SCRAP, PRINT_CONSUME, PRINT_OUTPUT`). Thêm `RETURN_IN = 'RETURN_IN'`.

### Repository methods cần dùng lại (đã có sẵn)

- `StockRepository.findItemById`, `findItemBySku`, `upsertInventory`, `upsertBalance`, `insertMovement`.
- `WarehouseRepository.findWarehouseById`, `findShelfById`.
- `StockTransactionHelper.withStockTransaction`.

### Repository methods mới cần thêm

- `GoodsReturnRepository`: `createGoodsReturn`, `findByOrderId` (idempotency check ở consumer), `findById`, `findAll`, `setInspected`, `setRestocked`, `setCancelled`.
- `ScrapNoteRepository.createApprovedScrapNote(warehouseId, createdBy, lines, session)` — tạo thẳng `status: APPROVED`, `approvedBy = createdBy` (không qua DRAFT).

### Error codes mới (`WMS_ERRORS`)

```
GOODS_RETURN_NOT_FOUND                  404  Không tìm thấy phiếu hoàn hàng
GOODS_RETURN_ALREADY_DECIDED            409  Phiếu đã xử lý xong hoặc đã huỷ, không thể thao tác lại
GOODS_RETURN_ITEM_NOT_FOUND             404  Dòng hàng không tồn tại trong phiếu hoàn
GOODS_RETURN_NOT_INSPECTED              409  Phiếu chưa được kiểm tra tình trạng, không thể xác nhận
GOODS_RETURN_ITEM_ISPERISHABLE_NO_LOT   400  Mặt hàng có hạn sử dụng phải chọn lô khi nhập lại hàng tốt
```

> `STOCK_ITEM_NOT_FOUND`, `WAREHOUSE_NOT_FOUND`, `SHELF_NOT_FOUND` đã có sẵn — dùng lại, không tạo trùng.

### Routes & roles

| Method | Path | Roles | Mô tả |
|---|---|---|---|
| POST | `/goods-returns` | RECEIVER, ADMIN | Tạo phiếu hoàn thủ công (không qua event) |
| GET | `/goods-returns` | RECEIVER, MANAGER, ADMIN | Danh sách phiếu |
| GET | `/goods-returns/:id` | RECEIVER, MANAGER, ADMIN | Chi tiết phiếu |
| POST | `/goods-returns/:id/inspect` | RECEIVER, ADMIN | Gán kho + phân loại GOOD/DAMAGED từng dòng |
| POST | `/goods-returns/:id/confirm` | RECEIVER, ADMIN | Xác nhận — nhập lại hàng tốt, nhập tạm+hủy hàng hỏng |
| POST | `/goods-returns/:id/cancel` | RECEIVER, ADMIN | Huỷ phiếu (chỉ khi DRAFT/INSPECTED) |

## Testing

- **Schema spec**: validate enum (`GoodsReturnStatus`, `GoodsReturnItemCondition`), default status, sub-document shape, `ScrapNoteItem.skipAvailableSync` default `false`.
- **Repository spec**: `createGoodsReturn`, `findByOrderId`, `setInspected`, `setRestocked`, `setCancelled`, `findAll`; `ScrapNoteRepository.createApprovedScrapNote`.
- **Consumer spec**: `ORDER_RETURNED` → tạo đúng `GoodsReturn` DRAFT resolve sku→itemId; sku không tìm thấy → bỏ qua dòng, không throw; `orderId` đã tồn tại phiếu → bỏ qua, không tạo trùng (idempotency); event lạ → log warn, không throw.
- **Service spec** (trọng tâm):
  - Inspect: phiếu không tồn tại/không phải DRAFT → throw đúng code.
  - Inspect: item `isPerishable`, `condition=GOOD`, thiếu `lotId` → throw `GOODS_RETURN_ITEM_ISPERISHABLE_NO_LOT`.
  - Inspect: item `isPerishable`, `condition=DAMAGED`, thiếu `lotId` → **không** throw (chỉ bắt buộc lotId cho GOOD).
  - Inspect hợp lệ → `warehouseId` set đúng, từng dòng có `condition/shelfId/lotId`, `status = INSPECTED`.
  - Confirm: phiếu không phải INSPECTED → throw `GOODS_RETURN_NOT_INSPECTED`.
  - Confirm dòng GOOD → `InventoryStock +=`, `onHand +=`, `StockMovement RETURN_IN` dấu dương, **có** bắn `stock.changed(+)`.
  - Confirm dòng DAMAGED → `InventoryStock`/`onHand` **không đổi ròng** sau cả 2 bước (cộng rồi trừ cùng số lượng), có **2** `StockMovement` (`RETURN_IN` dương rồi `SCRAP` âm cùng quantity), tạo 1 `ScrapNote` `status=APPROVED` với `skipAvailableSync=true`, **không** bắn `stock.changed` ở bất kỳ bước nào cho dòng này.
  - Confirm phiếu mix GOOD+DAMAGED → đúng số lần bắn `stock.changed` (chỉ dòng GOOD), đúng số `ScrapNote` tạo (chỉ dòng DAMAGED), `status = RESTOCKED`.
  - Cancel: `status = RESTOCKED` hoặc đã `CANCELLED` → throw. Cancel từ DRAFT/INSPECTED hợp lệ → `status = CANCELLED`, không có `StockMovement`/`stock.changed` nào.
  - **`ScrapNoteService.approveScrapNote` (regression S4-01)**: dòng `skipAvailableSync=true` (dù không có `lotId`) → **không** bắn `stock.changed` — xác nhận thay đổi điều kiện không phá luồng UC-08 gốc (dòng thường `skipAvailableSync=false` mặc định vẫn bắn như cũ khi không có `lotId`).
  - **Acceptance criteria trực tiếp** (khớp `S4-02-return-rma.md`): hàng tái nhập → `onHand` tăng đúng, có `StockMovement RETURN_IN`; hàng hỏng → sinh đề xuất scrap, không cộng tồn khả dụng (`available` ròng không đổi).

## Ngoài phạm vi (không làm trong task này)

- RMA từng phần trong 1 dòng (tách 1 `quantity` gốc thành nhiều tình trạng khác nhau).
- Validate tự động hạn dùng (`expiryDate`) của lô khi nhập lại GOOD — RECEIVER tự chọn đúng lô còn hạn.
- Xử lý `shipment.returned` (giao thất bại hẳn, chiều WMS→Ecom) — không phải input của module này.
- Duyệt lại (MANAGER approve riêng) cho `ScrapNote` sinh từ RMA — tự động APPROVED ngay khi RECEIVER confirm.
- Sửa dòng / thêm dòng sau khi phiếu đã `INSPECTED` hoặc `RESTOCKED`.
