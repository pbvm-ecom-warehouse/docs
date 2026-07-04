# S2-04: UC-03 Put-away — chuyển staging→shelf thật — Design

**Sprint:** 2 · **Size:** L · **Depends-on:** S2-03 (GRN)
**Issue:** `docs/planning/issues/S2-04-putaway.md`

## Bối cảnh

Sau khi GRN `CONFIRMED` (S2-03), hàng đã cộng tồn 2 lớp và nằm ở shelf **staging**. UC-03 chuyển hàng từ staging sang shelf thật mà RECEIVER quét xác nhận. Bất biến quan trọng nhất: **chỉ đổi lớp vị trí** (`InventoryStock`) — `StockBalance.onHand` **không đổi**, nên **không** publish `stock.changed` sang Ecommerce.

S2-05 (thuật toán gợi ý vị trí, advisory) là issue riêng, **không nằm trong scope** của thiết kế này.

## Data model

Dùng lại field đã định nghĩa ở `docs/warehouse/data-model.md`, với **một lệch có chủ đích**: bỏ field `PutAwayItem.shelfId`.

### PutAwayTask (chứng từ giao dịch — `timestamps: true`, không soft-delete)

| Field | Type | Mô tả |
|---|---|---|
| `_id` | ObjectId | |
| `grnId` | ObjectId | GRN nguồn |
| `warehouseId` | ObjectId | |
| `status` | Enum | `PENDING` / `COMPLETED` |
| `items` | PutAwayItem[] | Sub-document, giống cách `GoodsReceiptItem` nằm trong `GoodsReceiptNote` |
| `createdBy` | ObjectId | RECEIVER (lấy từ actor xác nhận GRN) |

### PutAwayItem (sub-document, không audit riêng)

| Field | Type | Mô tả |
|---|---|---|
| `itemId` | ObjectId | WarehouseItem |
| `lotId` | ObjectId \| null | Lô (null nếu item không `isPerishable`) |
| `quantity` | Number | Số lượng cần xếp ban đầu (= `baseQty` của dòng GRN tương ứng) |
| `remainingQty` | Number | Còn lại chưa xếp — khởi tạo = `quantity`, giảm dần mỗi lần quét xác nhận |

**Lệch so với `data-model.md`:** bỏ field `shelfId` trên `PutAwayItem`. Lý do: 1 dòng GRN có thể được tách xếp vào **nhiều shelf** (quét nhiều lần — xem mục "Xác nhận từng dòng"), nên "shelf đích" không còn là 1 giá trị cố định gắn trên item. Vị trí thực tế đã xếp tra qua `StockMovement` (`type: PUTAWAY`, `refType: 'put_away_task'`, `refId: putAwayTaskId`) hoặc `InventoryStock` hiện tại — tránh lưu trùng một dữ liệu dễ lệch (chỉ giữ được "shelf cuối cùng" nếu để `shelfId` cứng).

**Mapping 1-1 với dòng GRN:** mỗi dòng `resolvedLines` trong GRN (mỗi lô/mỗi item riêng) sinh đúng 1 `PutAwayItem` — không gộp theo `itemId` như bước cộng tồn, để khớp tự nhiên với `InventoryStock` đang nằm ở staging theo `(itemId, lotId)` của từng lô đã nhận.

Task `COMPLETED` khi **mọi** `PutAwayItem.remainingQty = 0`.

## Luồng nghiệp vụ

### A. Khởi tạo — tự động khi GRN CONFIRMED

Trong `GoodsReceiptNoteService.confirmGoodsReceiptNote()`, **cùng transaction Mongo hiện có** (`withStockTransaction`), ngay sau vòng lặp cộng tồn 2 lớp và trước `repo.updateStatusConfirmed`:

```
await this.putAwayService.createTaskFromGrn(
  grn._id, grn.warehouseId, resolvedLines, actorId, session,
);
```

`PutAwayModule` export `PutAwayService`; `GoodsReceiptNoteModule` import `PutAwayModule` (giống cách nó đã import `StockModule`/`WarehouseModule`).

`createTaskFromGrn` tạo 1 `PutAwayTask{status: PENDING}` với `items` = map trực tiếp từ `resolvedLines`: `{ itemId, lotId, quantity: baseQty, remainingQty: baseQty }`.

Nếu transaction rollback (lỗi giữa chừng), task không được tạo — nhất quán với việc GRN cũng chưa `CONFIRMED`, giữ đúng tính atomic đã có.

### B. Xác nhận từng dòng (RECEIVER quét)

`POST /putaway-tasks/:taskId/confirm-line`

Request body (barcode thô — backend tự resolve, đúng nghiệp vụ quét thật):
```jsonc
{
  "itemBarcode": "CUP-PLA-500-RED",
  "shelfCode": "A1-2",
  "quantity": 20,
  "lotId": "664f..."   // optional, bắt buộc nếu item isPerishable / task có dòng phân biệt theo lô
}
```

Xử lý (1 Mongo transaction/lần quét, độc lập với các lần quét khác):

1. Tra `WarehouseItem` theo `barcode`/`altBarcodes` (hàm mới `StockRepository.findItemByBarcode`) → không thấy → `AppException('PUTAWAY_ITEM_NOT_FOUND')`.
2. Tra `Shelf` theo `code` (`WarehouseRepository.findShelfByCode`, đã có sẵn) → không thấy → `AppException('PUTAWAY_SHELF_NOT_FOUND')`. Nếu `shelf.isStaging === true` → `AppException('PUTAWAY_SHELF_IS_STAGING')` (không cho "xếp" ngược lại staging).
3. Tìm `PutAwayItem` trong task khớp `(itemId, lotId)` → không thấy → `AppException('PUTAWAY_ITEM_MISMATCH')` (quét nhầm SKU hoặc lô không thuộc GRN này).
4. `quantity` gửi lên > `remainingQty` hiện tại của dòng đó → `AppException('PUTAWAY_QTY_EXCEEDS')`. **Không ghi gì** khi rơi vào bước 1–4 (reject toàn bộ request, không phải partial write).
5. Hợp lệ → trong transaction:
   - `stockRepo.upsertInventory(itemId, warehouseId, stagingShelfId, lotId, -quantity)` — trừ staging.
   - `stockRepo.upsertInventory(itemId, warehouseId, shelfId, lotId, +quantity)` — cộng shelf đích.
   - 2 `insertMovement` cùng `refId = putAwayTaskId`, `refType: 'put_away_task'`, `type: PUTAWAY`, lệch dấu (đúng quy ước "giao dịch đổi chỗ sinh 2 bút toán" — xem `data-model.md` § StockMovement).
   - `$inc` `remainingQty -= quantity` trên đúng `PutAwayItem` con trong task.
   - Nếu sau đó mọi `PutAwayItem` của task có `remainingQty = 0` → `PutAwayTask.status = COMPLETED`.
6. **Không** gọi `upsertBalance` (StockBalance.onHand không đổi). **Không** publish `stock.changed` — bất biến cốt lõi của UC-03.

**Idempotency:** không cần cờ idempotency riêng. Nếu client retry đúng request đã thành công, `remainingQty` đã bị trừ ở lần trước nên lần 2 tự nhiên vượt `remainingQty` còn lại (hoặc bằng 0) → bị chặn ở bước 4. Đây là điểm khác GRN (guard theo status tổng thể ở đầu hàm) — ở đây mỗi lần quét là 1 thao tác nhỏ, tự-idempotent qua state `remainingQty`.

### C. Truy vấn

- `GET /putaway-tasks?warehouseId=&status=` — danh sách việc cần làm cho RECEIVER (phân trang theo convention `page`/`limit` chung).
- `GET /putaway-tasks/:id` — chi tiết task kèm `items[]` (mỗi item có `remainingQty` để FE biết còn bao nhiêu cần xếp).

## Module & file structure

```
apps/wms/src/put-away/
  schemas/
    put-away-task.schema.ts       # PutAwayTask + sub-schema PutAwayItem
  dto/
    put-away.dto.ts               # ConfirmPutAwayLineDto, QueryPutAwayTaskDto,
                                   # PutAwayTaskResponseDto, PutAwayItemResponseDto
  put-away.repository.ts
  put-away.service.ts
  put-away.controller.ts
  put-away.module.ts
```

`PutAwayItem` là sub-document trong `PutAwayTask` (không phải collection riêng) — giống cách `GoodsReceiptItem` nằm trong `GoodsReceiptNote`; luôn truy cập cùng cha, không cần audit riêng theo đúng bảng "Quy ước Audit" (`.claude/rules/data-and-mongoose.md`).

## Error codes mới (`apps/wms/src/common/error-codes.ts` → `WMS_ERRORS`)

```
PUTAWAY_TASK_NOT_FOUND
PUTAWAY_ITEM_NOT_FOUND       // barcode không khớp WarehouseItem nào
PUTAWAY_SHELF_NOT_FOUND      // shelf code không khớp
PUTAWAY_SHELF_IS_STAGING     // không được xếp ngược lại staging
PUTAWAY_ITEM_MISMATCH        // item/lot quét không khớp dòng nào trong task
PUTAWAY_QTY_EXCEEDS          // quantity > remainingQty còn lại
```

## Roles & routing

- `RECEIVER, ADMIN` cho mọi endpoint (`confirm-line`, `list`, `get`) — đúng actor UC-03.
- Prefix `api/wms` (giữ nguyên convention), controller path `putaway-tasks`.
- Swagger: `@ApiOperation({ summary: '... — [RECEIVER, ADMIN]' })` theo `.claude/rules/dto-conventions.md`; response DTO dùng `@Expose()` + `plainToInstance(..., { excludeExtraneousValues: true })`.

## Thay đổi phụ trong code hiện có

- **`StockRepository`**: thêm `findItemByBarcode(barcode: string)` — query `$or: [{ barcode }, { altBarcodes: barcode }]` trên `WarehouseItem` (chưa tồn tại, cần bổ sung — hiện chỉ có `findItemById`/`findSkuById`).
- **`GoodsReceiptNoteService.confirmGoodsReceiptNote`**: thêm 1 lời gọi `putAwayService.createTaskFromGrn(...)` trong transaction hiện có, không đổi luồng cộng tồn 2 lớp đã có.
- **`GoodsReceiptNoteModule`**: import `PutAwayModule`.

## Testing

- Unit `put-away.service.spec.ts`: guard mismatch/exceeds/staging-target, cộng dồn `remainingQty`, chuyển `COMPLETED` khi hết mọi dòng.
- Unit `put-away.repository.spec.ts`: upsertInventory 2 chiều đúng dấu, insertMovement đúng `refType/refId`.
- Test tích hợp GRN: `confirmGoodsReceiptNote` sinh đúng số `PutAwayItem` map theo lô, không phá vỡ test multi-lot hiện có (`goods-receipt-note.service.spec.ts`).
- Test tách nhiều shelf: 1 `PutAwayItem` quét 2 lần (2 shelf khác nhau, tổng = `quantity` ban đầu) → 2 movement, `remainingQty` về 0 đúng ở lần cuối.
