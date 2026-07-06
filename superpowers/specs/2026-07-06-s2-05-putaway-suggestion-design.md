# S2-05: Thuật toán gợi ý vị trí put-away — Design

**Sprint:** 2 · **Size:** M · **Depends-on:** S2-04 (Put-away)
**Issue:** `docs/planning/issues/S2-05-putaway-suggestion.md`
**Thuật toán chuẩn:** `docs/warehouse/workflow.md` WF-01 § "Gợi ý vị trí put-away"
**Spec nghiệp vụ trước đó (docs-only):** `docs/superpowers/specs/2026-06-08-shelf-putaway-recommendation-design.md`

## Bối cảnh

UC-03 (S2-04, đã xong) để RECEIVER tự chọn shelf rồi quét xác nhận — hệ không gợi ý nên đặt vào đâu. S2-05 thêm 1 endpoint **advisory, read-only**: cho `sku` + `qty` + `warehouseId`, trả về danh sách shelf phù hợp nhất theo thể tích còn trống. RECEIVER vẫn quét SKU + shelf để xác nhận như cũ (`PUT /putaway-tasks/:id/confirm-line` không đổi); gợi ý không cưỡng chế, được đặt khác.

Pass trước (2026-06-08) chỉ cập nhật tài liệu (`data-model.md`/`use-cases.md`/`workflow.md`) và thêm field kích thước vào `Shelf` (đã có trong code: `innerDepth/innerWidth/innerHeight/fillFactor`). **`WarehouseItem` chưa có field kích thước** và **chưa có code thuật toán/endpoint nào** — đây là toàn bộ phạm vi của task này.

## Data model — thay đổi

### `WarehouseItem` — thêm field (tất cả optional)

| Field | Type | Mô tả |
|---|---|---|
| `depth` | Number | Chiều sâu 1 đơn vị cơ sở (cm) |
| `width` | Number | Chiều rộng 1 đơn vị cơ sở (cm) |
| `height` | Number | Chiều cao 1 đơn vị cơ sở (cm) |

`unitVolume = depth × width × height` — dẫn xuất, không lưu field riêng, tính trong service khi cần. Thiếu bất kỳ chiều nào → coi như "chưa khai kích thước" (không tính unitVolume).

Cập nhật kèm: `CreateWarehouseItemDto` (3 field optional, `@IsNumber() @Min(0)`), `WarehouseItemResponseDto` (expose 3 field).

### `Shelf` — không đổi

Đã có `innerDepth/innerWidth/innerHeight/fillFactor` từ trước (S2-04 pass). `usableVolume = innerDepth × innerWidth × innerHeight` — dẫn xuất tương tự.

### Không thêm field `occupied` ở đâu cả

Occupied volume luôn tính động từ `InventoryStock` hiện có — bất biến giữ nguyên từ spec gốc.

## Thuật toán (`PutAwaySuggestionService.suggest(sku, qty, warehouseId)`)

Input: `sku` (string), `qty` (number > 0), `warehouseId` (string).

1. **Tra item:** `StockRepository.findItemBySku(sku)`. Không thấy → `AppException('PUTAWAY_ITEM_NOT_FOUND')` (lỗi thật — input sai, không phải trạng thái advisory).
2. **Kiểm tra kích thước item:** thiếu `depth`/`width`/`height` bất kỳ → trả `{ suggestions: [], warning: 'ITEM_NO_DIMENSIONS' }`, HTTP 200 (không throw — đây là trạng thái dữ liệu bình thường, advisory).
3. **Liệt kê shelf ứng viên:** `WarehouseRepository.findShelvesByWarehouse(warehouseId)` (method mới) — lọc `warehouseId`, `isStaging: false`, `deletedAt: null`, và **đã khai đủ 3 chiều** (shelf thiếu kích thước bị loại ngay ở query, không suy diễn).
4. **Ràng buộc 3 chiều (cho xoay 90°):** với mỗi shelf ứng viên, sắp giảm dần bộ 3 `[depth,width,height]` của item và của shelf, yêu cầu `item[i] ≤ shelf[i]` với mọi `i ∈ {0,1,2}`. Trượt → loại.
5. Nếu không còn shelf nào sau bước 4 → `{ suggestions: [], warning: 'NO_SHELF_FITS' }`, HTTP 200.
6. **Occupied volume:** `StockRepository.findOccupiedVolumeByWarehouse(warehouseId)` (method mới, 1 aggregate cho toàn bộ shelf ứng viên, không N+1) — group `InventoryStock` theo `shelfId`, `$lookup` sang `warehouse_items` lấy `depth/width/height` của từng dòng để tính `Σ(quantity × unitVolume)`. Dòng `InventoryStock` có item thiếu kích thước bị bỏ qua khi cộng occupied (không chặn tính toán chỉ vì 1 SKU khác trên cùng shelf chưa khai kích thước — log cảnh báo, không throw).
7. Với mỗi shelf còn lại: `free = usableVolume × (shelf.fillFactor ?? defaultFillFactor) − occupied`; `capacity = floor(free / item.unitVolume)`. Loại shelf có `capacity < 1`.
8. Không còn shelf nào sau bước 7 → `{ suggestions: [], warning: 'NO_SHELF_FITS' }`.
9. **Xếp hạng:**
   - Ưu tiên 1: shelf đã có `InventoryStock` của cùng `itemId` **và** `capacity ≥ qty` → xếp trước, sắp theo `capacity` giảm dần nếu nhiều shelf cùng thỏa.
   - Ưu tiên 2: trong các shelf còn lại có `capacity ≥ qty`, chọn best-fit — `free` nhỏ nhất trước.
   - Nếu có candidate ở ưu tiên 1 hoặc 2 → trả về (không cần combo).
10. **Không shelf đơn nào đủ `qty`:** gộp nhiều shelf — sắp `capacity` giảm dần, lấy lần lượt tới khi tổng ≥ `qty` (greedy). Trả về tổ hợp đã chọn kèm capacity từng shelf.
    - Nếu tổng capacity của **toàn bộ** shelf ứng viên vẫn `< qty` → trả tổ hợp best-effort (toàn bộ shelf khả dụng) kèm `warning: 'INSUFFICIENT_CAPACITY'`.

### Output

```jsonc
{
  "suggestions": [
    { "shelfCode": "A1-2", "capacity": 30 },
    { "shelfCode": "A1-3", "capacity": 20 }
  ],
  "warning": null // hoặc "ITEM_NO_DIMENSIONS" | "NO_SHELF_FITS" | "INSUFFICIENT_CAPACITY"
}
```

`suggestions` rỗng khi có `warning`. Nhiều phần tử = tổ hợp nhiều shelf (chỉ xảy ra ở bước 10); 1 phần tử = shelf đơn đủ chứa.

## fillFactor mặc định hệ thống

Env var `PUTAWAY_DEFAULT_FILL_FACTOR` (số 0–1, mặc định `0.75` nếu không set), đọc qua `ConfigService` trong `PutAwaySuggestionService`. Dùng khi `shelf.fillFactor === null`. Thêm vào `.env.example` + schema validate Zod hiện có của app WMS (xem `env-validation-zod` — validate optional, có default).

## Module & file structure

Module **mới**, tách khỏi `put-away/` (advisory/read-only, không transaction, không đụng `InventoryStock`/`StockMovement` — khác hẳn lifecycle của `confirm-line`):

```
apps/wms/src/put-away-suggestion/
  dto/
    put-away-suggestion.dto.ts   # QueryPutAwaySuggestionDto, PutAwaySuggestionResponseDto, PutAwaySuggestionItemDto
  put-away-suggestion.service.ts
  put-away-suggestion.controller.ts
  put-away-suggestion.module.ts
```

`PutAwaySuggestionModule` imports `StockModule` (dùng `StockRepository`), `WarehouseModule` (dùng `WarehouseRepository`). Không cần export gì (chỉ có 1 endpoint tiêu thụ nội bộ qua HTTP).

## Thay đổi phụ trong code hiện có

- **`WarehouseItem` schema + `CreateWarehouseItemDto` + `WarehouseItemResponseDto`**: thêm `depth?`, `width?`, `height?`.
- **`StockRepository`**: thêm `findOccupiedVolumeByWarehouse(warehouseId: Types.ObjectId)` — Mongoose aggregate trên `InventoryStock`: `$match warehouseId` → `$lookup warehouse_items` theo `itemId` → tính `unitVolume` (bỏ dòng thiếu kích thước) → `$group` theo `shelfId`, `$sum(quantity * unitVolume)`. Trả `Map<shelfId, occupiedVolume>` hoặc mảng `{shelfId, occupied}`.
- **`WarehouseRepository`**: thêm `findShelvesByWarehouse(warehouseId: string)` — lọc `warehouseId`, `isStaging: false`, `deletedAt: null`, `innerDepth/innerWidth/innerHeight` đều tồn tại (`$exists: true, $ne: null`).

## Error codes

Không thêm code mới. `PUTAWAY_ITEM_NOT_FOUND` (đã có từ S2-04) dùng lại cho sku không tồn tại. Mọi trạng thái "không gợi ý được" đi qua field `warning` trong response 200, không phải exception.

## Roles & routing

- `GET /putaway/suggestions` — roles `RECEIVER, MANAGER, ADMIN` (cùng nhóm được xem `putaway-tasks`, vì đây là bước tham khảo trước khi RECEIVER thao tác thật).
- Prefix `api/wms` giữ nguyên. Query params: `sku` (string, required), `qty` (number, required, `@Min(1)`), `warehouseId` (string, required, Mongo ObjectId).
- Swagger: `@ApiOperation({ summary: 'Gợi ý vị trí put-away theo thể tích — [RECEIVER, MANAGER, ADMIN]' })`, `@ApiOkResponse({ type: PutAwaySuggestionResponseDto })`.

## Bất biến cần giữ

- Occupied/free/capacity **luôn dẫn xuất động** từ `InventoryStock` + `WarehouseItem` hiện tại — không thêm field lưu trạng thái chiếm dụng phải đồng bộ.
- Gợi ý là **advisory** — không đổi luồng/transaction của `confirm-line` (S2-04), không chặn RECEIVER đặt khác gợi ý.
- Không có khái niệm ràng buộc tương thích hazmat/cold-storage/fragile (không tồn tại trong hệ) — chỉ xét thể tích + 3 chiều hình học.
- Liên kết xuyên app vẫn chỉ qua `sku`; tính năng này hoàn toàn nội bộ WMS, không phát/nhận event nào.

## Testing

- Unit `put-away-suggestion.service.spec.ts`:
  - Item không tồn tại → `AppException('PUTAWAY_ITEM_NOT_FOUND')`.
  - Item thiếu kích thước → `warning: 'ITEM_NO_DIMENSIONS'`, `suggestions: []`.
  - Item quá to (trượt ràng buộc 3 chiều ở mọi shelf) → `warning: 'NO_SHELF_FITS'`.
  - Shelf đã chứa cùng SKU + đủ `qty` → xếp hạng đầu, đúng trước shelf trống hoàn toàn dù shelf trống có `free` nhỏ hơn.
  - Best-fit: 2 shelf cùng đủ `qty`, không cùng SKU → chọn shelf `free` nhỏ hơn.
  - Không shelf đơn đủ `qty` → trả tổ hợp nhiều shelf, tổng `capacity` ≥ `qty`.
  - Tổng capacity toàn kho vẫn `< qty` → `warning: 'INSUFFICIENT_CAPACITY'` kèm tổ hợp best-effort.
  - Shelf thiếu kích thước → không xuất hiện trong candidate list.
  - `InventoryStock` có item khác thiếu kích thước trên cùng shelf → không throw, occupied bỏ qua dòng đó (log warn).
- Unit `stock.repository.spec.ts`: `findOccupiedVolumeByWarehouse` tính đúng tổng nhiều SKU/lot trên cùng shelf; bỏ qua item thiếu kích thước.
- Unit `warehouse.repository.spec.ts`: `findShelvesByWarehouse` loại đúng staging/deleted/thiếu kích thước.
- Test schema: `warehouse-item.schema.spec.ts` — field mới optional, không phá test hiện có.
