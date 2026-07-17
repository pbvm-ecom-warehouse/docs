# S4-04: Notification consumer (stock.low, stock.near_expiry) — Design

## Bối cảnh

Theo `docs/planning/issues/S4-04-notification-consumer.md` và `docs/notification/*.md` (đã thiết kế trước, chưa code). Scope: WMS phát 2 event cảnh báo (`stock.low`, `stock.near_expiry`) khi tồn xuống thấp / lô sắp hết hạn; `apps/notification` consume và gửi email (Resend) + push (FCM) tới MANAGER. **Không bao gồm** `payment.success` (UC-N03) — issue doc S4-04 chỉ nói `stock.low`/`stock.near_expiry`.

`libs/events/src/events.ts` đã khai báo sẵn `STOCK_LOW`/`STOCK_NEAR_EXPIRY` + `StockLowPayload`/`StockNearExpiryPayload` + `EventPayloadMap` — không cần sửa. `notification.consumer.ts` hiện có case placeholder log tạm cho 2 event này ("TODO: producer chưa build") — S4-04 thay bằng xử lý thật.

## Quyết định thiết kế (đã chốt với người dùng)

1. **`stock.low` — không dedup.** Emit **mỗi lần** `available < minQuantity` sau biến động tồn (không track transition ≥→<). Đơn giản, không cần lưu state, khớp nguyên tắc "Notification không DB". Trade-off: có thể lặp cảnh báo nếu tồn thấp kéo dài qua nhiều biến động — chấp nhận được vì mục tiêu là nhắc nhở.
2. **`minQuantity` — optional, không default.** Field mới trên `WarehouseItem`, giống `nearExpiryDays`. `undefined` = item đó không bao giờ cảnh báo thấp tồn. MANAGER tự set cho SKU cần theo dõi qua API PATCH đã có.
3. **`stock.near_expiry` — cron 1 lần/ngày (06:00), không dedup.** Cùng lý do với (1): lô nằm trong ngưỡng sẽ được báo lại mỗi ngày cho tới khi được xử lý (xuất hết / chuyển status). Không cần bảng "đã báo".

## Kiến trúc tổng quan

```
WMS (producer)                                    Notification (consumer)
───────────────                                    ────────────────────────
StockService.checkAndEmitStockLow()  ──stock.low──▶  NotificationConsumer
  (gọi sau khi 6 service nghiệp vụ                       │
   upsertBalance, NGOÀI transaction)                     ├─ EmailService → WAREHOUSE_ALERT_EMAIL
                                                          └─ FirebaseService → topic stock_alert_{warehouseId}
NearExpiryScanService (@Cron 0 6 * * *) ─stock.near_expiry─▶  (cùng consumer)
  quét Lot ACTIVE sắp hết hạn                             ├─ EmailService
                                                          └─ FirebaseService → topic stock_alert_expiry
```

Cả 2 event dùng `QUEUES.NOTIFICATION` (`notification-queue`) — queue đã tồn tại, dùng chung với UC-N01/N02. WMS cần đăng ký thêm queue này (hiện `StockModule` chỉ có `QUEUES.STOCK`).

---

## Phần 1 — WMS: `minQuantity` trên `WarehouseItem`

**File:** `apps/wms/src/stock/schemas/warehouse-item.schema.ts`

Thêm ngay dưới `nearExpiryDays`:
```ts
/** Ngưỡng tối thiểu — available < minQuantity thì phát stock.low. undefined = không cảnh báo. */
@Prop({ type: Number })
minQuantity?: number;
```

**DTO** (`apps/wms/src/stock/dto/create-warehouse-item.dto.ts`): thêm field `minQuantity?: number` với `@IsOptional() @IsInt() @Min(0)` — theo đúng mẫu `nearExpiryDays`. `UpdateWarehouseItemDto` tự động có field này vì đã là `PartialType(OmitType(CreateWarehouseItemDto, ['sku']))`.

**Response DTO** (`apps/wms/src/stock/dto/warehouse-item.response.dto.ts`): thêm `@Expose() minQuantity?: number` cạnh `nearExpiryDays`.

**Repository type** (`apps/wms/src/stock/stock.repository.ts`): thêm `minQuantity?: number` vào `CreateWarehouseItemData` — `createItem`/`updateItem` đã spread generic nên không cần sửa logic, chỉ cần field có trong type. `UpdateWarehouseItemData` (đã là `Partial<Omit<CreateWarehouseItemData, 'sku'>>`) tự nhận field mới.

---

## Phần 2 — WMS: phát `stock.low` sau biến động tồn

**File mới/sửa:** `apps/wms/src/stock/stock.repository.ts`, `apps/wms/src/stock/stock.service.ts`, `apps/wms/src/stock/stock.module.ts`.

### `StockRepository`

```ts
findSkuAndMinQuantityById(
  itemId: Types.ObjectId,
): Promise<{ sku: string; minQuantity?: number } | null> {
  return this.itemModel
    .findById(itemId)
    .select('sku minQuantity')
    .lean<{ sku: string; minQuantity?: number }>()
    .exec();
}
```

### `StockService`

```ts
constructor(
  private readonly stockRepo: StockRepository,
  @InjectQueue(QUEUES.STOCK) private readonly stockQueue: Queue,
  @InjectQueue(QUEUES.NOTIFICATION) private readonly notificationQueue: Queue,
) {}

/** Kiểm tra available sau biến động, phát stock.low nếu dưới ngưỡng. Gọi SAU KHI
 * transaction Mongo đã commit — BullMQ không tham gia transaction (quy ước có sẵn). */
async checkAndEmitStockLow(
  itemId: Types.ObjectId,
  warehouseId: Types.ObjectId,
  balance: { onHand: number; reserved: number; expired: number },
): Promise<void> {
  const item = await this.stockRepo.findSkuAndMinQuantityById(itemId);
  if (!item || item.minQuantity == null) return;
  const available = balance.onHand - balance.reserved - balance.expired;
  if (available >= item.minQuantity) return;
  const payload: StockLowPayload = {
    sku: item.sku,
    warehouseId: warehouseId.toString(),
    available,
    minQuantity: item.minQuantity,
  };
  await this.notificationQueue.add(EVENTS.STOCK_LOW, payload);
}
```

Không dùng `jobId` deterministic ở đây (khác `emitStockChanged`) — theo quyết định (1), mỗi lần gọi PHẢI tạo job mới, không được BullMQ de-dup theo id.

### Wiring vào 6 service nghiệp vụ

`upsertBalance` đã trả về `StockBalanceDocument | null` với `{ new: true }` — có sẵn `onHand/reserved/expired` sau update, không cần query lại. Theo đúng quy ước "BullMQ ngoài transaction" (đã áp dụng ở `goods-receipt-note.service.ts:238`), mỗi service:

1. Khai báo 1 `Map<string, { itemId: Types.ObjectId; warehouseId: Types.ObjectId; balance: {...} }>` trước transaction (key = `` `${itemId}:${warehouseId}` ``, để nếu 1 lô nghiệp vụ chạm cùng 1 (item,warehouse) nhiều lần chỉ giữ bản mới nhất).
2. Trong transaction, sau mỗi `upsertBalance`, nếu trả về không null thì set vào map.
3. Sau khi `withStockTransaction(...)` resolve, loop map gọi `stockService.checkAndEmitStockLow(itemId, warehouseId, balance)`.

Áp dụng cho:
- `goods-return.service.ts` (dòng ~227)
- `print-job.service.ts` (3 điểm gọi: reserve CUP_BLANK, consume input, tạo output)
- `scrap-note.service.ts` (2 điểm gọi)
- `goods-receipt-note.service.ts` (đã có loop-sau-transaction cho `publishAvailableForItem` — thêm map tương tự, cùng vị trí)
- `stock-count.service.ts` (dòng ~203)
- `goods-issue.service.ts` (dòng ~159)

> Không sửa các service khác không gọi `upsertBalance` (put-away: theo quy ước "onHand/reserved cùng giảm → available không đổi → không bắn event", đúng cho cả stock.low).

`StockModule` cần thêm `BullModule.registerQueue({ name: QUEUES.NOTIFICATION })` vào `imports` để `StockService` inject được `notificationQueue`.

---

## Phần 3 — WMS: cron `stock.near_expiry`

**Dependency mới:** `@nestjs/schedule` (chưa dùng ở đâu trong repo — cần `pnpm add @nestjs/schedule`).

**`AppModule`:** thêm `ScheduleModule.forRoot()` vào imports.

**File mới:** `apps/wms/src/stock/near-expiry-scan.service.ts`

```ts
@Injectable()
export class NearExpiryScanService {
  private readonly logger = new Logger(NearExpiryScanService.name);

  constructor(
    @InjectModel(Lot.name) private readonly lotModel: Model<Lot>,
    @InjectQueue(QUEUES.NOTIFICATION) private readonly notificationQueue: Queue,
  ) {}

  @Cron('0 6 * * *')
  async scanNearExpiryLots(): Promise<void> {
    const now = new Date();
    const rows = await this.lotModel.aggregate<{
      lotNumber: string;
      expiryDate: Date;
      sku: string;
    }>([
      { $match: { status: LotStatus.ACTIVE } },
      {
        $lookup: {
          from: 'warehouse_items',
          localField: 'itemId',
          foreignField: '_id',
          as: 'item',
        },
      },
      { $unwind: '$item' },
      {
        $addFields: {
          threshold: {
            $add: [
              now,
              { $multiply: [{ $ifNull: ['$item.nearExpiryDays', 7] }, 86400000] },
            ],
          },
        },
      },
      { $match: { $expr: { $lte: ['$expiryDate', '$threshold'] } } },
      {
        $project: {
          lotNumber: 1,
          expiryDate: 1,
          sku: '$item.sku',
        },
      },
    ]).exec();

    for (const row of rows) {
      const payload: StockNearExpiryPayload = {
        sku: row.sku,
        lotNumber: row.lotNumber,
        expiryDate: row.expiryDate.toISOString(),
      };
      await this.notificationQueue.add(EVENTS.STOCK_NEAR_EXPIRY, payload);
    }
    this.logger.log(`Quét lot sắp hết hạn: ${rows.length} lot cần cảnh báo.`);
  }
}
```

> Aggregation trên `lotModel` trực tiếp (không qua `InventoryStock`) vì chỉ cần lô + sku, không cần vị trí/số lượng. Không lọc theo `quantity > 0` vì `Lot` không lưu quantity (nằm ở `InventoryStock`) — lô hết hàng thực tế thường đã chuyển status khỏi ACTIVE qua nghiệp vụ khác; nếu chưa, việc báo lại 1 lô đã hết cũng vô hại (MANAGER thấy không cần xử lý).

Đăng ký `NearExpiryScanService` làm provider trong `StockModule`, thêm `LotSchema` vào `MongooseModule.forFeature` của module đó nếu chưa có sẵn (kiểm tra lúc code — `Lot` có thể đã được đăng ký qua module khác dùng chung connection, xem rule `data-and-mongoose.md` về việc re-register model là an toàn).

---

## Phần 4 — Notification: xử lý `stock.low`/`stock.near_expiry`

**File sửa:** `apps/notification/src/notification.consumer.ts`

Constructor mở rộng: `constructor(private readonly email: EmailService, private readonly firebase: FirebaseService, private readonly config: ConfigService)`.

Thay case gộp hiện tại:
```ts
case EVENTS.STOCK_LOW: {
  const payload = job.data as StockLowPayload;
  const alertEmail = this.config.get<string>('WAREHOUSE_ALERT_EMAIL');
  let sent = false;
  if (this.email.isEnabled() && alertEmail) {
    await this.email.send({
      to: alertEmail,
      subject: `⚠️ Tồn kho thấp — SKU: ${payload.sku}`,
      react: StockLowAlertEmail(payload),
      idempotencyKey: key,
    });
    sent = true;
  }
  if (this.firebase.isEnabled()) {
    await this.firebase.getMessaging().send({
      topic: `stock_alert_${payload.warehouseId}`,
      notification: {
        title: `Tồn kho thấp — ${payload.sku}`,
        body: `Còn ${payload.available}/${payload.minQuantity}`,
      },
      data: {
        sku: payload.sku,
        warehouseId: payload.warehouseId,
        available: String(payload.available),
      },
    });
    sent = true;
  }
  if (!sent) {
    this.logger.warn(`stock.low cho ${payload.sku} — không có provider nào bật.`);
  }
  break;
}
case EVENTS.STOCK_NEAR_EXPIRY: {
  const payload = job.data as StockNearExpiryPayload;
  // tương tự STOCK_LOW: email tới alertEmail (nếu có) + FCM topic 'stock_alert_expiry'
  ...
}
```

`payment.success` giữ nguyên placeholder log — ngoài scope S4-04.

### Template mới

- `apps/notification/src/email/templates/stock-low-alert.tsx` — copy cấu trúc từ `verify-email.tsx` (Html/Head/Preview/Body/Container/Section/Hr pattern), màu accent `#D97706`. Props: `{ sku, warehouseId, available, minQuantity }`. Nội dung: SKU, kho, số hiện tại/ngưỡng, % còn lại (`Math.round((available / minQuantity) * 100)` — chỉ hiển thị nếu `minQuantity > 0`, tránh chia 0).
- `apps/notification/src/email/templates/stock-near-expiry.tsx` — cùng cấu trúc, màu `#DC2626`. Props: `{ sku, lotNumber, expiryDate }`. Hiển thị ngày format `dd/MM/yyyy` (dùng `Intl.DateTimeFormat('vi-VN')`, không thêm dependency mới) + số ngày còn lại (`Math.ceil((new Date(expiryDate).getTime() - Date.now()) / 86400000)`).

### Env

`apps/notification/src/config/env.validation.ts`: thêm `WAREHOUSE_ALERT_EMAIL: z.string().email().optional()`.

---

## File Structure (tổng hợp)

```
apps/wms/src/stock/
  schemas/warehouse-item.schema.ts     [sửa: +minQuantity]
  dto/create-warehouse-item.dto.ts     [sửa: +minQuantity validator]
  dto/warehouse-item.response.dto.ts   [sửa: +minQuantity expose]
  stock.repository.ts                  [sửa: +findSkuAndMinQuantityById, +CreateWarehouseItemData.minQuantity]
  stock.service.ts                     [sửa: +checkAndEmitStockLow, +inject QUEUES.NOTIFICATION]
  stock.module.ts                      [sửa: +registerQueue NOTIFICATION, +NearExpiryScanService provider]
  near-expiry-scan.service.ts          [mới]

apps/wms/src/goods-return/goods-return.service.ts       [sửa: wiring]
apps/wms/src/print-job/print-job.service.ts             [sửa: wiring x3]
apps/wms/src/scrap-note/scrap-note.service.ts           [sửa: wiring x2]
apps/wms/src/goods-receipt-note/goods-receipt-note.service.ts [sửa: wiring]
apps/wms/src/stock-count/stock-count.service.ts         [sửa: wiring]
apps/wms/src/goods-issue/goods-issue.service.ts          [sửa: wiring]
apps/wms/src/app.module.ts                              [sửa: +ScheduleModule.forRoot()]

apps/notification/src/notification.consumer.ts           [sửa: case STOCK_LOW/STOCK_NEAR_EXPIRY thật]
apps/notification/src/email/templates/stock-low-alert.tsx      [mới]
apps/notification/src/email/templates/stock-near-expiry.tsx    [mới]
apps/notification/src/config/env.validation.ts            [sửa: +WAREHOUSE_ALERT_EMAIL]
package.json                                              [sửa: +@nestjs/schedule dependency]
```

## Global Constraints

- Không transaction xuyên DB — cron/consumer đọc/viết trong đúng DB của app mình.
- BullMQ job cho `stock.low`/`stock.near_expiry` **không** dùng deterministic `jobId` (khác `stock.changed`) — theo quyết định "không dedup".
- Consumer giữ nguyên nguyên tắc graceful degradation: thiếu provider → log warn, không throw.
- Không thêm `AppException` mới — `NearExpiryScanService`/`checkAndEmitStockLow` không phải luồng HTTP, lỗi (nếu có) log qua `Logger`, không throw ra ngoài cron (BullMQ retry job add nếu lỗi mạng Redis, không phải throw nghiệp vụ).
- `WarehouseItem.minQuantity`: theo đúng khuôn `nearExpiryDays` — optional, `@IsInt() @Min(0)`, không đổi convention audit hiện có.
- Comment tiếng Việt giải thích *vì sao* ở mọi điểm quyết định không hiển nhiên (đặc biệt: vì sao không dedup, vì sao emit ngoài transaction).
- Test: mỗi file logic mới (`checkAndEmitStockLow`, `findSkuAndMinQuantityById`, `NearExpiryScanService.scanNearExpiryLots`, 2 case consumer mới) đều có unit test. 6 service wiring: test guard "khi minQuantity không set / available ≥ minQuantity → không gọi checkAndEmitStockLow-emit" đủ, không cần test lại toàn bộ luồng nghiệp vụ đã có.

## Rủi ro / việc ngoài scope (ghi nhận, không tự xử lý)

- 5/6 service (`goods-return`, `print-job`, `scrap-note`, `stock-count`, `goods-issue`) hiện **không** phát `stock.changed` sang Ecommerce sau `upsertBalance` — gap có từ trước, không thuộc S4-04, không tự sửa.
- Không dedup ở cả 2 event có thể gây nhiều email/push nếu tồn thấp/lô cận date kéo dài nhiều ngày — quyết định có chủ đích của người dùng, không phải thiếu sót.
