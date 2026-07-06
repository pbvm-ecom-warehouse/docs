# S2-06: Hạ tầng event BullMQ/Redis + phát stock.changed — Design

**Sprint:** 2 · **Size:** M · **Depends-on:** S1-04
**Issue:** `docs/planning/issues/S2-06-event-infra.md`

## Bối cảnh

Ticket S2-06 mô tả như thể hạ tầng event còn chưa có gì. Kiểm tra code thực tế cho thấy **phần lớn checklist đã hoàn thành từ trước** (qua các task S1-04/S2-03 và công đoạn dựng Ecommerce):

| Checklist trong ticket | Trạng thái thật |
|---|---|
| Cấu hình BullMQ + Redis trong libs/common | ✅ Đã có — `libs/events/src/events.module.ts` + `config/redis.config.ts` (`EventsModule`, không phải `libs/common` như ticket ghi — theo đúng kiến trúc `.claude/rules/events.md`) |
| `EventPublisher` service phát event chuẩn | ✅ Đã có — `StockService.emitStockChanged`/`publishAvailableForItem` (`apps/wms/src/stock/stock.service.ts`) |
| Gắn publisher vào biến động onHand/available | ✅ Đã có — `GoodsReceiptNoteService.confirmGoodsReceiptNote` gọi `publishAvailableForItem` sau khi cộng tồn 2 lớp |
| Hằng tên event trong libs/shared-types | ✅ Đã có — `libs/events/src/events.ts` (`QUEUES`, `EVENTS`, `EventPayloadMap`, không phải `libs/shared-types` như ticket ghi) |
| **Idempotency key cho event** | ❌ **Chưa có** — đây là phần việc thật của task này |

Theo đúng nguyên tắc "code là nguồn sự thật" (`.claude/rules/README.md`), spec này chỉ mô tả phần còn thiếu thật sự: **idempotency key phía producer**.

## Vấn đề cụ thể

`StockService.emitStockChanged(sku, delta)` gọi `stockQueue.add(EVENTS.STOCK_CHANGED, payload)` **không truyền `jobId`** → BullMQ tự sinh id ngẫu nhiên mỗi lần gọi. Hệ quả: nếu `emitStockChanged`/`publishAvailableForItem` bị gọi 2 lần cho **cùng một biến động nghiệp vụ thật** (vd retry ở tầng trên do lỗi mạng, hoặc lỗi logic khiến vòng lặp publish chạy 2 lần), BullMQ tạo ra 2 job riêng biệt, không job nào trùng job kia → cả hai đều được xử lý → Ecom cộng dồn `availableQty` 2 lần cho cùng 1 biến động — sai số liệu tồn.

Phía consumer (`apps/ecommerce/src/catalog/stock.consumer.ts`) đã có phòng thủ qua `applyStockDeltaOnce(job.id, ...)` (unique index trên `jobId`, bắt lỗi 11000). Nhưng vì `job.id` hiện là giá trị BullMQ tự sinh (không deterministic theo nghiệp vụ), phòng thủ này **chỉ chặn được retry đúng 1 job BullMQ đã tồn tại** (BullMQ tự retry theo `attempts`), **không chặn được** 2 lần gọi `.add()` độc lập cho cùng 1 biến động — vì 2 lần gọi đó sinh ra 2 `job.id` khác nhau, cả hai đều "mới" với `applyStockDeltaOnce`.

## Giải pháp: `jobId` deterministic theo nguồn gốc nghiệp vụ

Dùng lại đúng quy ước `refType`/`refId` đã có trên `StockMovement` (`apps/wms/src/stock/schemas/stock-movement.schema.ts`) — mọi biến động tồn đã có sẵn 1 chứng từ gốc (GRN, phiếu kiểm kho, phiếu chuyển kho...). Ghép `refType:refId:sku` làm `jobId` khi gọi `stockQueue.add()`.

`.add()` với `jobId` trùng job **còn tồn tại trong queue** (chưa bị dọn qua `removeOnComplete`/`removeOnFail`) là no-op — BullMQ tự chặn tạo job trùng, không cần code gì thêm ở consumer. Đây là tầng phòng thủ **trước** tầng `applyStockDeltaOnce` đã có (defense-in-depth, giữ nguyên không đổi).

### Thay đổi signature — `apps/wms/src/stock/stock.service.ts`

```ts
async emitStockChanged(
  sku: string,
  delta: number,
  refType: string,
  refId: Types.ObjectId | string,
): Promise<void> {
  const payload: StockChangedPayload = { sku, delta };
  const jobId = `${refType}:${refId.toString()}:${sku}`;
  await this.stockQueue.add(EVENTS.STOCK_CHANGED, payload, { jobId });
  this.logger.log(`stock.changed → sku=${sku} delta=${delta} jobId=${jobId}`);
}

async publishAvailableForItem(
  itemId: string,
  delta: number,
  refType: string,
  refId: Types.ObjectId | string,
): Promise<void> {
  const item = await this.stockRepo.findSkuById(itemId);
  if (!item) return;
  await this.emitStockChanged(item.sku, delta, refType, refId);
}
```

`refType`/`refId` là tham số **bắt buộc**, không optional — một event tồn kho không truy vết được nguồn gốc chính là lỗ hổng đang sửa; không thêm nhánh "không có refType thì bỏ qua idempotency".

### Cập nhật caller duy nhất hiện có — `goods-receipt-note.service.ts:244`

```ts
await this.stockService.publishAvailableForItem(
  itemId,
  totalBaseQty,
  'grn',
  grn._id,
);
```

`refType: 'grn'` khớp đúng giá trị đã dùng trên `StockMovement.refType` cho cùng nghiệp vụ GRN (nhất quán đặt tên xuyên suốt).

## Không đổi

- `libs/events/src/events.ts` — `QUEUES`, `EVENTS`, `StockChangedPayload`, `EventPayloadMap`: đã đúng, không sửa.
- `EventsModule` (BullMQ + Redis config, `defaultJobOptions` retry/backoff): đã đúng, không sửa.
- `apps/ecommerce/src/catalog/stock.consumer.ts` + `CatalogRepository.applyStockDeltaOnce`: logic giữ nguyên hoàn toàn — vẫn nhận `job.id` như cũ, chỉ khác là giá trị `job.id` giờ deterministic thay vì ngẫu nhiên. Không cần sửa dòng nào bên Ecommerce.
- `HealthController` (health-check Redis ping qua `queue.client`): không liên quan, không đổi.

## Bất biến cần giữ

- Payload event (`{ sku, delta }`) không đổi — hợp đồng giữa 2 app giữ nguyên, chỉ thêm option `jobId` khi `.add()`, không phải thay đổi payload.
- Producer vẫn là app sở hữu nghiệp vụ (WMS); consumer vẫn tự idempotent qua `applyStockDeltaOnce` — không xoá tầng phòng thủ đó.
- Không transaction xuyên DB, không đọc chéo `ecom_db` — thay đổi này thuần túy nội bộ WMS (cách gọi `.add()`) + 1 dòng sửa ở GRN caller.

## Testing

- `stock.service.spec.ts` (hiện chưa có test nào cho `emitStockChanged`/`publishAvailableForItem` — bổ sung mới, không sửa test cũ):
  - `emitStockChanged` gọi `queue.add(EVENTS.STOCK_CHANGED, {sku, delta}, {jobId: 'grn:<refId>:<sku>'})` đúng format.
  - `publishAvailableForItem` tra đúng sku qua `findSkuById` rồi forward `refType`/`refId` xuống `emitStockChanged` không đổi.
  - `publishAvailableForItem` trả về sớm (không gọi `emitStockChanged`) khi `findSkuById` trả `null`.
- `goods-receipt-note.service.spec.ts` — cập nhật 3 assertion hiện có (dòng ~300, ~445, ~521) từ `toHaveBeenCalledWith(itemId, delta)` sang `toHaveBeenCalledWith(itemId, delta, 'grn', grn._id)` (hoặc giá trị `_id` cụ thể theo từng test case) — đây là sửa test theo signature mới, không phải test hành vi mới.

## File sẽ thay đổi

- `apps/wms/src/stock/stock.service.ts` — sửa signature 2 method.
- `apps/wms/src/stock/stock.service.spec.ts` — thêm test mới cho 2 method (hiện chưa có).
- `apps/wms/src/goods-receipt-note/goods-receipt-note.service.ts` — sửa 1 call site (dòng 244).
- `apps/wms/src/goods-receipt-note/goods-receipt-note.service.spec.ts` — cập nhật 3 assertion đã có theo signature mới.
