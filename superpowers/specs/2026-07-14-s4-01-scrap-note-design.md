# S4-01: UC-08 Hủy hàng hết hạn/hỏng (Scrap) — Design

**Nguồn:** [warehouse/use-cases.md#UC-08](../../warehouse/use-cases.md), [db/05-xuat-kho-va-noi-bo.md](../../db/05-xuat-kho-va-noi-bo.md), [overview/erd.dbml](../../overview/erd.dbml)

## Bối cảnh

UC-08 xử lý việc ghi giảm tồn hợp thức cho hàng không còn bán được — hoặc vì **hết hạn** (lô perishable quá `expiryDate`) hoặc vì **hỏng/vỡ/ẩm mốc** (phát hiện thủ công, không phân biệt perishable hay không). COUNTER/RECEIVER đề xuất, MANAGER duyệt hoặc từ chối. Duyệt xong ghi `StockMovement` loại `SCRAP` — không bao giờ sửa thẳng `onHand`.

**Phát hiện quan trọng trong lúc khảo sát code (khác với mô tả trong `lot.schema.ts`/`erd.dbml`):** Docs mô tả cơ chế "cron tự động quét Lot hết hạn → set `status=EXPIRED` → bắn `stock.expired` → `StockBalance.expired += qty`". **Cơ chế cron này chưa được implement ở đâu cả** — không có `@Cron`/`CronExpression` nào trong `apps/wms/src`, không có producer nào bắn `stock.expired`. Do đó **task này KHÔNG bao gồm việc xây cron đó** — chỉ xây quy trình đề xuất/duyệt Scrap. Nếu MANAGER muốn hủy hàng hết hạn, phải tự chọn đúng `lotId` đã biết là hết hạn (qua nghiệp vụ ngoài hệ thống hoặc kiểm tra `expiryDate` thủ công) khi tạo phiếu — hệ thống không tự liệt kê lô hết hạn.

## Phạm vi & quyết định thiết kế đã chốt

1. **Không xây cron tự động EXPIRED** — xem phần Bối cảnh. `Lot.status` transition (ACTIVE→EXPIRED) và event `stock.expired` để ngoài phạm vi, làm task riêng sau nếu cần.
2. **1 phiếu Scrap = nhiều dòng** (mảng `items`, giống `GoodsIssue`/`PrintJob`/`StockCount`) — khớp ERD (`scrap_note_items` là bảng con riêng của `scrap_notes`). Không phải 1 dòng/1 phiếu.
3. **Người đề xuất chỉ định `shelfId` rõ ràng khi tạo dòng** — không để hệ thống tự tìm/gộp vị trí. Khớp field `shelfId` trong ERD `scrap_note_items`, và cần thiết vì cả hàng không-perishable cũng phải biết chính xác hủy ở đâu để trừ đúng `InventoryStock`.
4. **1 API tạo cả phiếu kèm toàn bộ dòng cùng lúc** (`POST /scrap-notes` với body chứa mảng `items`) — không tạo phiếu rỗng rồi thêm dòng dần. Khác `StockCount` (phải auto-generate dòng từ hệ thống), ở đây COUNTER/RECEIVER biết ngay từ đầu cần hủy những gì.
5. **1 action APPROVE hoặc REJECT cho cả phiếu** — không duyệt/từ chối từng dòng riêng lẻ. Khớp bảng trạng thái đơn giản trong `use-cases.md` (`DRAFT → APPROVED` / `REJECTED`, không có trạng thái mức-dòng).
6. **Phân biệt "hết hạn" vs "hỏng" bằng có/không `lotId` trên dòng** — dòng có `lotId` (item `isPerishable`) coi là hủy vì hết hạn: `StockBalance.expired −=` cùng lúc với `onHand −=` (available không đổi — hàng hết hạn vốn đã ngoài available). Dòng không có `lotId` coi là hủy vì hỏng/vỡ (không phân biệt hết hạn): chỉ `onHand −=`, không đụng `expired` (hàng này đang **trong** available trước khi hủy).
7. **Bắn `stock.changed` có điều kiện theo mục 6** — đây là điểm suy luận từ định nghĩa `available = onHand − reserved − expired`, không phải chép nguyên văn docs (docs viết chung chung "ScrapNote không bao giờ bắn stock.changed", nhưng điều đó chỉ đúng khi Scrap dùng cho hàng hết hạn). Quyết định đã chốt:
   - Dòng **có `lotId`** (hết hạn) → **KHÔNG** bắn `stock.changed` (khớp bảng tổng kết `db/05-xuat-kho-va-noi-bo.md`: "ScrapNote | SCRAP − | giảm | ❌").
   - Dòng **không có `lotId`** (hỏng, không hết hạn) → **CÓ** bắn `stock.changed` (`delta` âm) — vì `available` giảm thật sự, phải sync Ecom, nếu không Ecom sẽ hiển thị tồn cao hơn thực tế kho.
8. **Validate tồn đủ lúc tạo phiếu (DRAFT)** — kiểm tra `InventoryStock(item, warehouse, shelf, lot)` đủ `quantity` đề xuất tại đúng vị trí chỉ định, chặn tạo dòng vượt tồn thật. Không kiểm tra lại lúc duyệt (giả định giữa lúc đề xuất và duyệt không có biến động khác tại đúng vị trí đó — nếu có, `upsertInventory`/`upsertBalance` vẫn atomic nhưng có thể ra số âm; chấp nhận rủi ro nhỏ này vì ngoài scope, giống cách `StockCount` không lock giữa count và approve).
9. **`isPerishable` bắt buộc có `lotId`** — nếu `WarehouseItem.isPerishable = true` mà dòng thiếu `lotId` → từ chối tạo phiếu (`SCRAP_NOTE_ITEM_ISPERISHABLE_NO_LOT`). Khớp rule chung của hệ thống (mọi thao tác trên item perishable phải có lô).
10. **Không tích hợp UC-09 (GoodsReturn) trong task này** — `use-cases.md` nói "hàng DAMAGED → chuyển sang UC-08 Scrap", nhưng module `GoodsReturn` chưa tồn tại trong code. Scrap đứng độc lập; UC-09 (khi làm sau) sẽ tự gọi vào Scrap.
11. **Không cho sửa dòng sau khi tạo phiếu** — phiếu DRAFT chỉ chờ APPROVE/REJECT, không có API sửa items.

## Kiến trúc

Module mới `apps/wms/src/scrap-note/`, đặt cạnh `stock-count`/`goods-issue`, import `StockModule` + `WarehouseModule`.

```
apps/wms/src/scrap-note/
  schemas/scrap-note.schema.ts
  dto/scrap-note.dto.ts        (request: CreateScrapNoteDto, RejectScrapNoteDto, QueryScrapNoteDto; response: ScrapNoteResponseDto)
  scrap-note.repository.ts
  scrap-note.service.ts
  scrap-note.controller.ts
  scrap-note.module.ts
```

Đăng ký `ScrapNoteModule` vào `AppModule`. Không có consumer — module này không nghe event nào.

### Schema: `ScrapNote`

Chứng từ giao dịch — hủy bằng `status`, KHÔNG soft-delete.

```ts
export enum ScrapNoteStatus {
  DRAFT = 'DRAFT',
  APPROVED = 'APPROVED',
  REJECTED = 'REJECTED',
}

@Schema({ _id: false })
class ScrapNoteItem {
  itemId: Types.ObjectId;      // required
  sku: string;                  // required — denormalized, hiển thị
  shelfId: Types.ObjectId;     // required — vị trí xuất khi duyệt
  lotId: Types.ObjectId | null; // null nếu item không isPerishable — có giá trị = coi là "hết hạn"
  quantity: number;             // required, min 0
  reason: string;               // required — hết hạn/vỡ/ẩm mốc/khác, tự do nhập
}

@Schema({ collection: 'scrap_notes', timestamps: true })
export class ScrapNote {
  warehouseId: Types.ObjectId;   // required
  status: ScrapNoteStatus;       // default DRAFT
  note?: string;
  createdBy: Types.ObjectId;     // required — COUNTER/RECEIVER đề xuất
  approvedBy?: Types.ObjectId;   // MANAGER — set khi approve hoặc reject
  rejectReason?: string;         // bắt buộc khi REJECTED
  items: ScrapNoteItem[];        // required
}
```

Index: `{ warehouseId: 1, status: 1 }`, `{ status: 1 }`.

> Không unique index theo `warehouseId` — 1 kho có thể có nhiều phiếu Scrap theo thời gian (không giống `GoodsIssue`/`PrintJob` vốn 1-1 với `orderId`).

### DTO

**Request:**
- `CreateScrapNoteDto`: `{ warehouseId: string; note?: string; items: CreateScrapNoteItemDto[] }`
  - `CreateScrapNoteItemDto`: `{ itemId: string; lotId?: string; shelfId: string; quantity: number; reason: string }`
- `RejectScrapNoteDto`: `{ rejectReason: string }` (bắt buộc — lý do từ chối)
- `QueryScrapNoteDto`: `{ status?: ScrapNoteStatus; warehouseId?: string; page?: number; limit?: number }`

**Response:** `ScrapNoteResponseDto` (+ nested `ScrapNoteItemResponseDto`) theo convention `@Expose()` + `plainToInstance`.

### Service — luồng chi tiết

**1. Tạo phiếu** — `createScrapNote(dto, actorId)`
- Validate `warehouseId` tồn tại (`WarehouseRepository.findWarehouseById`).
- Với mỗi dòng trong `dto.items`:
  - `WarehouseItem` tồn tại theo `itemId` (`StockRepository.findItemById`) → nếu không → `STOCK_ITEM_NOT_FOUND` (code có sẵn).
  - Nếu `item.isPerishable` mà thiếu `dto item.lotId` → `SCRAP_NOTE_ITEM_ISPERISHABLE_NO_LOT`.
  - `Shelf` tồn tại theo `shelfId` (`WarehouseRepository.findShelfById`) → không → lỗi shelf not found (dùng code cross-cutting có sẵn nếu có, hoặc thêm `SCRAP_NOTE_SHELF_NOT_FOUND`).
  - `InventoryStock(itemId, warehouseId, shelfId, lotId)` đủ `quantity` → không đủ → `SCRAP_NOTE_QTY_EXCEEDS`.
- Build `lines` với `sku` denormalized từ `WarehouseItem.sku`.
- Tạo `ScrapNote{status: DRAFT}` với toàn bộ dòng qua `repo.createScrapNote(...)`. Không đụng tồn kho ở bước này.

**2. MANAGER duyệt** — `approveScrapNote(id, actorId)`
- Tìm phiếu; `status !== DRAFT` → `SCRAP_NOTE_ALREADY_DECIDED`.
- Trong 1 `stockTransactionHelper.withStockTransaction`, với **mỗi dòng**:
  - `stockRepo.upsertInventory(itemId, warehouseId, shelfId, lotId, -quantity, session)`
  - Nếu `line.lotId` (hết hạn): `stockRepo.upsertBalance(itemId, warehouseId, -quantity, 0, -quantity, session)` — `onHand -= quantity`, `expired -= quantity`, `reserved` không đổi.
  - Nếu `line.lotId === null` (hỏng, không hết hạn): `stockRepo.upsertBalance(itemId, warehouseId, -quantity, 0, 0, session)` — chỉ `onHand -= quantity`.
  - `stockRepo.insertMovement({ itemId, warehouseId, shelfId, lotId, type: MovementType.SCRAP, quantity: -quantity, refType: 'scrap_note', refId: scrapNote._id, createdBy: actorId }, session)`.
  - `repo.setApproved(id, actorId, session)` set `status = APPROVED`, `approvedBy`.
- Sau khi transaction commit, với **mỗi dòng có `lotId === null`** (hàng hỏng, available đổi thật), bắn `stock.changed` `{ sku: line.sku, delta: -line.quantity }` lên `QUEUES.STOCK` (`jobId: scrap_note:${id}:${sku}` để idempotent). Dòng có `lotId` (hết hạn) **không** bắn.

**3. MANAGER từ chối** — `rejectScrapNote(id, dto, actorId)`
- Tìm phiếu; `status !== DRAFT` → `SCRAP_NOTE_ALREADY_DECIDED`.
- Set `status = REJECTED`, `approvedBy = actorId`, `rejectReason = dto.rejectReason`. Không đụng tồn kho.

**4. List/Detail** — `listScrapNotes(query)`, `getScrapNote(id)` — pattern giống `StockCountService`.

### `MovementType.SCRAP` đã tồn tại sẵn

`apps/wms/src/stock/schemas/stock-movement.schema.ts` đã có `SCRAP` trong enum `MovementType` — không cần thêm.

### Repository methods cần dùng lại (đã có sẵn, không cần thêm)

- `StockRepository.findItemById`, `findInventory`, `upsertInventory`, `upsertBalance`, `insertMovement` — dùng y hệt các module trước.
- `WarehouseRepository.findWarehouseById`, `findShelfById`.

### Error codes mới (`WMS_ERRORS`)

```
SCRAP_NOTE_NOT_FOUND               404  Không tìm thấy phiếu hủy hàng
SCRAP_NOTE_ITEM_ISPERISHABLE_NO_LOT 400 Mặt hàng có hạn sử dụng phải chọn lô khi đề xuất hủy
SCRAP_NOTE_SHELF_NOT_FOUND         404  Không tìm thấy vị trí đã chọn
SCRAP_NOTE_QTY_EXCEEDS             400  Số lượng đề xuất hủy vượt quá tồn thật tại vị trí này
SCRAP_NOTE_ALREADY_DECIDED         409  Phiếu đã được duyệt hoặc từ chối, không thể xử lý lại
```

> `STOCK_ITEM_NOT_FOUND` đã có sẵn trong `WMS_ERRORS` — dùng lại, không tạo trùng.

### Routes & roles

| Method | Path | Roles | Mô tả |
|---|---|---|---|
| POST | `/scrap-notes` | COUNTER, RECEIVER, ADMIN | Tạo phiếu đề xuất hủy (kèm toàn bộ dòng) |
| GET | `/scrap-notes` | COUNTER, RECEIVER, MANAGER, ADMIN | Danh sách phiếu |
| GET | `/scrap-notes/:id` | COUNTER, RECEIVER, MANAGER, ADMIN | Chi tiết phiếu |
| POST | `/scrap-notes/:id/approve` | MANAGER, ADMIN | Duyệt — trừ tồn thật, ghi SCRAP movement |
| POST | `/scrap-notes/:id/reject` | MANAGER, ADMIN | Từ chối — không đụng tồn kho |

## Testing

- **Schema spec**: validate enum, default status, sub-document shape (giống `stock-count.schema.spec.ts`).
- **Repository spec**: `createScrapNote`, `setApproved`, `setRejected`, `findAll`.
- **Service spec** (trọng tâm):
  - Tạo phiếu: item `isPerishable` thiếu `lotId` → throw `SCRAP_NOTE_ITEM_ISPERISHABLE_NO_LOT`.
  - Tạo phiếu: tồn không đủ tại vị trí chỉ định → throw `SCRAP_NOTE_QTY_EXCEEDS`.
  - Tạo phiếu hợp lệ nhiều dòng (mix có/không `lotId`) → đúng `sku` denormalized, đúng `status = DRAFT`.
  - Duyệt phiếu không phải `DRAFT` → throw `SCRAP_NOTE_ALREADY_DECIDED`.
  - Duyệt dòng có `lotId` → đúng `InventoryStock -=`, `onHand -=`, `expired -=`, **không** bắn `stock.changed`.
  - Duyệt dòng không có `lotId` → đúng `InventoryStock -=`, `onHand -=`, **`expired` không đổi**, **có** bắn `stock.changed` với `delta` âm đúng số lượng.
  - Duyệt phiếu nhiều dòng mix cả 2 loại → đúng số lần bắn event (chỉ dòng không-lotId).
  - Từ chối phiếu không phải `DRAFT` → throw.
  - Từ chối hợp lệ → `status = REJECTED`, `rejectReason` lưu đúng, không có `StockMovement`/`stock.changed` nào được tạo.
  - **Acceptance criteria trực tiếp**: duyệt xong → `onHand` giảm đúng số lượng hủy, có `StockMovement SCRAP` đúng dấu; từ chối → tồn không đổi.

## Ngoài phạm vi (không làm trong task này)

- Cron tự động quét Lot hết hạn (`ACTIVE → EXPIRED`) và bắn `stock.expired`.
- Tích hợp với UC-09 GoodsReturn (module chưa tồn tại).
- Duyệt/từ chối từng dòng riêng lẻ.
- Sửa dòng sau khi phiếu đã tạo (DRAFT).
