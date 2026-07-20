# Design: Cron xử lý lô hết hạn thật (`ExpiredLotScanService`)

- Issue: [#7](https://github.com/pbvm-ecom-warehouse/be-wms-ecom/issues/7) — "Thiếu cron xử lý lô hết hạn thật (STOCK_EXPIRED chưa từng được phát)"
- Ngày: 2026-07-20

## Bối cảnh

`EVENTS.STOCK_EXPIRED` (WMS → Ecom) đã được khai báo trong `libs/events/src/events.ts` với payload `StockExpiredPayload { sku, delta }`, và consumer bên Ecom (`apps/ecommerce/src/catalog/stock.consumer.ts`) đã xử lý chung nhánh với `STOCK_CHANGED`. Nhưng **chưa có producer nào phát event này** — không có cơ chế tự động nào chuyển `Lot.status` sang `EXPIRED` khi qua `expiryDate`.

Hệ quả: `StockBalance.expired` không bao giờ tự tăng do hết hạn thật (chỉ tăng/giảm qua `ScrapNoteService.approveScrapNote` khi có người phát hiện thủ công), nên `available = onHand - reserved - expired` vẫn tính cả hàng đã hết hạn là khả dụng — sai lệch tồn hiển thị bên Ecom, có thể bán được hàng hết hạn.

Đã có sẵn để tham khảo pattern: `apps/wms/src/stock/near-expiry-scan.service.ts` — cron 06:00 hằng ngày quét lô **sắp** hết hạn, phát `stock.near_expiry` (cảnh báo trước, không đụng tồn).

## Phát hiện quan trọng khi đọc code hiện có (khác với comment trong `lot.schema.ts`)

Comment tại `apps/wms/src/stock/schemas/lot.schema.ts:11-12` viết:

> "Hàng hết hạn: consumer chạy cron đặt status = EXPIRED, bắn stock.expired event, StockBalance.expired += qty, StockBalance.onHand -= qty."

Nhưng đối chiếu với cách `available` được tính xuyên suốt codebase (`stock.service.ts`, `stock.repository.ts`, `report.service.ts`):

```
available = onHand - reserved - expired
```

Và cách `ScrapNoteService.approveScrapNote` xử lý dòng scrap có `lotId` (nghĩa là "hủy vì hết hạn"):

```ts
// onHand -= quantity  (luôn luôn)
const expiredDelta = line.lotId ? -line.quantity : 0; // expired -= quantity (CHỈ khi có lotId)
```

Comment tại đó giải thích rõ: *"trừ thêm StockBalance.expired cho dòng có lotId (hủy vì hết hạn — available không đổi, hàng vốn đã ngoài available)"*.

Điều này chỉ **nhất quán** nếu tại thời điểm lô chuyển `EXPIRED`, cron **chỉ** tăng `expired` (không đụng `onHand`/`InventoryStock`) — tức hàng vẫn nằm vật lý trên kệ (chưa ai dọn), chỉ không còn được tính vào `available` nữa. Khi có người dọn thật (ScrapNote thủ công), lúc đó mới thực sự trừ `onHand` (và trừ lại `expired` tương ứng để `available` không đổi lần nữa — vì đã trừ 1 lần lúc cron chạy rồi).

Nếu cron làm đúng theo comment cũ (vừa trừ `onHand` vừa cộng `expired`) thì `available` sẽ giảm **2 lần** cho cùng 1 lượng hàng, và `InventoryStock` (vẫn còn quantity trên shelf) sẽ lệch với `StockBalance.onHand` đã bị trừ dù chưa ai di chuyển hàng vật lý.

**Quyết định**: implement theo đúng công thức `available` và pattern `ScrapNoteService` hiện có (nguồn sự thật là code, theo `architecture.md`), **không** theo văn bản comment cũ trong `lot.schema.ts` — sẽ sửa lại comment đó cho khớp.

## Phạm vi

### Trong phạm vi

1. `ExpiredLotScanService` — cron hằng ngày quét `Lot` có `status = ACTIVE AND expiryDate < now`.
2. Với mỗi lô, gom `InventoryStock` theo `lotId` (quantity > 0), group theo `warehouseId` (1 lô có thể nằm rải rác nhiều kho/shelf).
3. Với mỗi `(itemId, warehouseId, qty)`: `StockBalance.expired += qty` (dùng `StockRepository.upsertBalance`, không đụng `onHand`/`InventoryStock`/`StockMovement`).
4. Set `Lot.status = EXPIRED`.
5. Sau khi transaction commit: phát 1 job `stock.expired` mỗi sku, `delta = -(tổng qty mọi kho của lô đó)`, jobId deterministic để idempotent qua retry.
6. Lô đã hết `InventoryStock` (quantity=0 khắp nơi — vd đã bán/scrap hết trước khi hết hạn): vẫn set `EXPIRED`, không update balance, không phát event.
7. Sửa comment sai trong `lot.schema.ts`.
8. Unit test theo style `near-expiry-scan.service.spec.ts`.

### Ngoài phạm vi (giữ nguyên như hiện tại)

- **Không** tự động tạo `ScrapNote` — dọn hàng vật lý (trừ thật `onHand`/`InventoryStock`) vẫn là thao tác thủ công của COUNTER/RECEIVER đề xuất + MANAGER duyệt, như UC-08 hiện có. Lý do: cron chỉ đánh dấu "không còn khả dụng", chưa di chuyển hàng vật lý — tạo ScrapNote APPROVED ở bước này sẽ ngầm định hàng đã được dọn, sai với thực tế.
- **Không** ghi `StockMovement` — sổ cái này chỉ ghi biến động vật lý (nhập/xuất/chuyển), việc chuyển trạng thái expired không di chuyển hàng nên không tạo bút toán.
- **Không** đổi cơ chế `STOCK_NEAR_EXPIRY` hiện có.

## Thiết kế chi tiết

### File mới: `apps/wms/src/stock/expired-lot-scan.service.ts`

Cấu trúc song song với `NearExpiryScanService`:

```ts
@Injectable()
export class ExpiredLotScanService {
  constructor(
    @InjectModel(Lot.name) private readonly lotModel: Model<Lot>,
    private readonly stockRepo: StockRepository,
    private readonly stockTransactionHelper: StockTransactionHelper,
    @InjectQueue(QUEUES.STOCK) private readonly stockQueue: Queue,
  ) {}

  @Cron('0 7 * * *') // sau near-expiry scan (06:00), tránh trùng giờ
  async scanExpiredLots(): Promise<void> { ... }
}
```

**Bước 1 — tìm lô hết hạn**:

```ts
const now = new Date();
const expiredLots = await this.lotModel
  .find({ status: LotStatus.ACTIVE, expiryDate: { $lt: now } })
  .exec();
```

**Bước 2 — với mỗi lô, gom InventoryStock theo warehouse** (dùng aggregate hoặc `StockRepository` method mới `sumInventoryByLot(lotId)` trả về `{ itemId, warehouseId, sku, qty }[]`).

**Bước 3 — transaction**: với mỗi lô, trong `withStockTransaction`, loop qua các nhóm warehouse, gọi `upsertBalance(itemId, warehouseId, 0, 0, +qty, session)`. Sau đó `lotModel.updateOne({_id: lot._id}, {status: EXPIRED}, {session})`.

**Bước 4 — emit sau commit**: `stockQueue.add(EVENTS.STOCK_EXPIRED, {sku, delta: -totalQty}, {jobId: `lot_expire:${lot._id}:${sku}`})`.

**Bước 5 — lô không còn tồn**: nếu bước 2 trả về mảng rỗng, vẫn set `EXPIRED` (transaction đơn giản chỉ update status), không có gì để emit.

### Thay đổi phụ

- `StockRepository`: thêm method đọc tổng `InventoryStock.quantity` theo `lotId`, group theo `warehouseId`, kèm `itemId`/sku qua lookup `warehouse_items` (tương tự pipeline aggregate đã có trong `near-expiry-scan.service.ts`).
- `stock.module.ts`: đăng ký `ExpiredLotScanService` làm provider (đã có sẵn `Lot`, `InventoryStock` model + `StockRepository` + `StockTransactionHelper` + queue `STOCK` trong module này).
- `lot.schema.ts`: sửa comment dòng 11-12 cho khớp thiết kế thật (chỉ tăng `expired`, không đụng `onHand`).

### Idempotency

- Job `stock.expired` dùng `jobId = lot_expire:<lotId>:<sku>` — nếu cron chạy lại (retry/lỗi giữa chừng) cho cùng lô, BullMQ tự chặn job trùng, khớp pattern `emitStockChanged`.
- Vòng quét chỉ nhắm `status: ACTIVE` — lô đã `EXPIRED` từ lần chạy trước sẽ không bị match lại, nên kể cả nếu balance đã update nhưng job event lỡ chưa gửi (crash giữa bước 3 và 4) thì lần chạy sau **sẽ không quét lại lô đó nữa** (đã EXPIRED). Chấp nhận rủi ro nhỏ này (giống thiết kế hiện có của `NearExpiryScanService` — không dùng outbox pattern), vì transaction Mongo đảm bảo balance+status commit atomic cùng lúc; chỉ job BullMQ có thể lỡ nếu process crash ngay sau transaction — coi là chấp nhận được theo quy mô dự án hiện tại (như các cron khác đã có).

## Test plan

Unit test `expired-lot-scan.service.spec.ts`, mock model/repo/queue:

1. 1 lô, tồn tại ở 1 kho → `upsertBalance` gọi 1 lần với `expiredDelta = qty`, 1 job `stock.expired` với `delta = -qty`, `jobId` đúng format.
2. 1 lô, tồn rải rác 2 kho → `upsertBalance` gọi 2 lần (mỗi kho), nhưng chỉ 1 job `stock.expired` với `delta` = tổng âm của cả 2 kho.
3. Lô không còn `InventoryStock` nào (đã bán/scrap hết) → `Lot.status` vẫn set `EXPIRED`, không gọi `upsertBalance`, không phát job.
4. Không có lô nào hết hạn → không làm gì.
5. `$match` đúng `status: ACTIVE` + `expiryDate: { $lt: now }`.

## Câu hỏi đã chốt với chủ dự án

- **Không** tự động tạo ScrapNote ở bước cron này — giữ nguyên luồng thủ công hiện có cho việc dọn hàng vật lý.
- Cron chỉ điều chỉnh `StockBalance.expired`, không đụng `onHand`/`InventoryStock`/`StockMovement` — sửa lại theo đúng công thức `available` thay vì theo comment cũ (có mâu thuẫn) trong `lot.schema.ts`.
