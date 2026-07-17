# S4-04: Notification consumer (stock.low, stock.near_expiry) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** WMS phát `stock.low` (khi `available < minQuantity` sau biến động tồn) và `stock.near_expiry` (cron quét lô sắp hết hạn hằng ngày); `apps/notification` consume 2 event này, gửi email (Resend) + push (FCM) tới MANAGER kho.

**Architecture:** Thêm field `minQuantity?` vào `WarehouseItem` (optional, giống `nearExpiryDays`). `StockService.checkAndEmitStockLow(itemId, warehouseId)` tự đọc lại balance mới nhất từ DB (không nhận qua tham số) rồi so ngưỡng — gọi ở **6 service nghiệp vụ** đã có `upsertBalance`, luôn **sau khi** transaction Mongo commit. `NearExpiryScanService` mới (`@Cron('0 6 * * *')`) quét `Lot` ACTIVE sắp hết hạn, phát 1 job/lô. Cả 2 event đi qua `QUEUES.NOTIFICATION` đã có sẵn (dùng chung với UC-N01/N02), **không** dùng deterministic `jobId` — mỗi lần gọi đều tạo job mới (quyết định: không dedup). `NotificationConsumer` thay case placeholder hiện tại bằng xử lý thật: email + FCM, graceful degradation nếu thiếu provider.

**Tech Stack:** NestJS (monorepo mode), `@nestjs/mongoose`, `@nestjs/bullmq` (BullMQ/Redis), `@nestjs/schedule` (mới), `@react-email/components`, Jest.

## Global Constraints

- Design đầy đủ: `docs/superpowers/specs/2026-07-17-s4-04-notification-consumer-design.md`. Đọc trước khi bắt đầu nếu cần thêm ngữ cảnh — plan này đã trích các phần cần thiết.
- **Không dedup** cho `stock.low`/`stock.near_expiry` — KHÔNG truyền `jobId` khi `queue.add(...)` (khác với `emitStockChanged`/`publishAvailableForItem` vốn dùng `jobId` xác định). Mỗi lần điều kiện đúng đều emit job mới.
- `checkAndEmitStockLow` **luôn gọi sau khi transaction Mongo đã commit** — BullMQ không tham gia transaction (quy ước có sẵn, xem `goods-receipt-note.service.ts` dòng có comment "Ngoài transaction — BullMQ không tham gia Mongo transaction").
- `checkAndEmitStockLow(itemId, warehouseId)` tự đọc lại `StockBalance` mới nhất bằng `StockRepository.findBalanceByItemAndWarehouse` (đã tồn tại) — KHÔNG nhận balance qua tham số. Điều này tự động đúng cho ca `GoodsReturn` dòng DAMAGED (2 lệnh `upsertBalance` bù nhau trong cùng transaction) mà không cần đổi return type của `ScrapNoteService.createApprovedScrapNoteForReturn`.
- `WarehouseItem.minQuantity`: optional, không default, `@IsInt() @Min(0)` — đúng khuôn `nearExpiryDays`.
- Không thêm `AppException`/error code mới — các thay đổi không phải luồng HTTP throw lỗi nghiệp vụ.
- Consumer giữ nguyên nguyên tắc graceful degradation: thiếu `EmailService`/`FirebaseService` → `logger.warn`, không throw.
- Comment tiếng Việt giải thích *vì sao* ở mọi điểm quyết định không hiển nhiên (đặc biệt: vì sao không dedup, vì sao đọc lại balance thay vì nhận qua tham số).
- Không sửa case `EVENTS.PAYMENT_SUCCESS` trong `notification.consumer.ts` — ngoài scope S4-04 (issue doc chỉ nói `stock.low`/`stock.near_expiry`).
- Không tự sửa việc 5/6 service (`goods-return`, `print-job`, `scrap-note`, `stock-count`, `goods-issue`) hiện chưa phát `stock.changed` sang Ecommerce — gap có từ trước, ngoài scope.
- TypeScript strict — không `any`.

---

## File Structure

```
apps/wms/src/stock/
  schemas/warehouse-item.schema.ts         [sửa: +minQuantity]
  schemas/warehouse-item.schema.spec.ts    [sửa: +test minQuantity]
  dto/create-warehouse-item.dto.ts         [sửa: +minQuantity validator]
  dto/create-warehouse-item.dto.spec.ts    [mới]
  dto/warehouse-item.response.dto.ts       [sửa: +minQuantity expose]
  stock.repository.ts                      [sửa: +findSkuAndMinQuantityById, +CreateWarehouseItemData.minQuantity]
  stock.repository.spec.ts                 [sửa: +test findSkuAndMinQuantityById]
  stock.service.ts                         [sửa: +checkAndEmitStockLow, +inject QUEUES.NOTIFICATION]
  stock.service.spec.ts                    [sửa: +test checkAndEmitStockLow]
  stock.module.ts                          [sửa: +registerQueue NOTIFICATION, +NearExpiryScanService provider]
  near-expiry-scan.service.ts              [mới]
  near-expiry-scan.service.spec.ts         [mới]

apps/wms/src/goods-receipt-note/goods-receipt-note.service.ts       [sửa: wiring]
apps/wms/src/goods-receipt-note/goods-receipt-note.service.spec.ts  [sửa: +test]
apps/wms/src/goods-issue/goods-issue.service.ts                     [sửa: wiring]
apps/wms/src/goods-issue/goods-issue.service.spec.ts                [sửa: +test]
apps/wms/src/stock-count/stock-count.service.ts                     [sửa: wiring]
apps/wms/src/stock-count/stock-count.service.spec.ts                [sửa: +test]
apps/wms/src/scrap-note/scrap-note.service.ts                       [sửa: wiring]
apps/wms/src/scrap-note/scrap-note.service.spec.ts                  [sửa: +test]
apps/wms/src/goods-return/goods-return.service.ts                   [sửa: wiring]
apps/wms/src/goods-return/goods-return.service.spec.ts               [sửa: +test]
apps/wms/src/print-job/print-job.service.ts                         [sửa: wiring x3]
apps/wms/src/print-job/print-job.service.spec.ts                    [sửa: +test]
apps/wms/src/app.module.ts                                          [sửa: +ScheduleModule.forRoot()]
package.json                                                        [sửa: +@nestjs/schedule]

apps/notification/src/config/env.validation.ts                      [sửa: +WAREHOUSE_ALERT_EMAIL]
apps/notification/src/email/templates/stock-low-alert.tsx           [mới]
apps/notification/src/email/templates/stock-near-expiry.tsx         [mới]
apps/notification/src/email/templates/templates.spec.ts             [sửa: +test 2 template mới]
apps/notification/src/notification.consumer.ts                      [sửa: case STOCK_LOW/STOCK_NEAR_EXPIRY thật]
apps/notification/src/notification.consumer.spec.ts                 [sửa: +constructor args, +test 2 case mới]
```

No changes to any other existing file.

---

### Task 1: `WarehouseItem.minQuantity`

**Files:**
- Modify: `apps/wms/src/stock/schemas/warehouse-item.schema.ts`
- Modify: `apps/wms/src/stock/schemas/warehouse-item.schema.spec.ts`
- Modify: `apps/wms/src/stock/dto/create-warehouse-item.dto.ts`
- Create: `apps/wms/src/stock/dto/create-warehouse-item.dto.spec.ts`
- Modify: `apps/wms/src/stock/dto/warehouse-item.response.dto.ts`
- Modify: `apps/wms/src/stock/stock.repository.ts` (chỉ đổi type `CreateWarehouseItemData`, không đổi logic)

**Interfaces:**
- Produces: `WarehouseItem.minQuantity?: number`, `CreateWarehouseItemDto.minQuantity?: number` (và tự có trên `UpdateWarehouseItemDto` vì là `PartialType(OmitType(CreateWarehouseItemDto, ['sku']))`), `WarehouseItemResponseDto.minQuantity?: number`, `CreateWarehouseItemData.minQuantity?: number` — tất cả dùng bởi Task 2 (`StockRepository.findSkuAndMinQuantityById`).

- [ ] **Step 1: Write the failing test cho schema**

Thêm vào `apps/wms/src/stock/schemas/warehouse-item.schema.spec.ts`, sau block `describe('kích thước (depth/width/height)', ...)`:

```ts
describe('minQuantity (ngưỡng cảnh báo stock.low)', () => {
  it('cho phép tạo item không khai minQuantity (optional, không cảnh báo)', () => {
    const doc = new WarehouseItemModel({
      sku: 'SKU-NO-MINQTY',
      name: 'Không khai ngưỡng',
      type: ItemType.MATERIAL,
      unit: 'cái',
    });
    const err = doc.validateSync();
    expect(err).toBeUndefined();
    expect(doc.minQuantity).toBeUndefined();
  });

  it('lưu đúng minQuantity khi khai', () => {
    const doc = new WarehouseItemModel({
      sku: 'SKU-MINQTY',
      name: 'Có khai ngưỡng',
      type: ItemType.MATERIAL,
      unit: 'cái',
      minQuantity: 10,
    });
    expect(doc.minQuantity).toBe(10);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- warehouse-item.schema`
Expected: FAIL — `Property 'minQuantity' does not exist` (typecheck) hoặc `doc.minQuantity` là `undefined` cho cả 2 test (test thứ 2 fail vì field chưa tồn tại trong schema nên Mongoose bỏ qua giá trị truyền vào).

- [ ] **Step 3: Thêm field vào schema**

Trong `apps/wms/src/stock/schemas/warehouse-item.schema.ts`, thêm ngay dưới `nearExpiryDays`:

```ts
  /** Ngưỡng tối thiểu — available (= onHand-reserved-expired) < minQuantity thì WMS phát
   * stock.low cho MANAGER. undefined = item này không bao giờ cảnh báo thấp tồn. */
  @Prop({ type: Number })
  minQuantity?: number;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- warehouse-item.schema`
Expected: PASS.

- [ ] **Step 5: Write the failing test cho `CreateWarehouseItemDto`**

Tạo `apps/wms/src/stock/dto/create-warehouse-item.dto.spec.ts`:

```ts
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { CreateWarehouseItemDto } from './create-warehouse-item.dto';
import { ItemType } from '../schemas/warehouse-item.schema';

const BASE = {
  sku: 'SKU-1',
  name: 'Item 1',
  type: ItemType.MATERIAL,
  unit: 'cái',
};

describe('CreateWarehouseItemDto — minQuantity', () => {
  it('không truyền minQuantity vẫn hợp lệ (optional)', async () => {
    const dto = plainToInstance(CreateWarehouseItemDto, { ...BASE });
    const errors = await validate(dto);
    expect(errors).toHaveLength(0);
  });

  it('minQuantity âm → validation error', async () => {
    const dto = plainToInstance(CreateWarehouseItemDto, {
      ...BASE,
      minQuantity: -1,
    });
    const errors = await validate(dto);
    expect(errors.some((e) => e.property === 'minQuantity')).toBe(true);
  });

  it('minQuantity hợp lệ (số nguyên không âm) → không lỗi', async () => {
    const dto = plainToInstance(CreateWarehouseItemDto, {
      ...BASE,
      minQuantity: 10,
    });
    const errors = await validate(dto);
    expect(errors).toHaveLength(0);
  });
});
```

- [ ] **Step 6: Run test to verify it fails**

Run: `pnpm test -- create-warehouse-item.dto`
Expected: FAIL — test thứ 2 (`minQuantity: -1`) không có lỗi vì field chưa được validate (bị `forbidNonWhitelisted`/`whitelist` của `ValidationPipe` loại ở tầng HTTP thật, nhưng gọi `validate()` trực tiếp ở unit test thì field lạ chỉ bị bỏ qua, không lỗi) — assert `errors.some(...)` sẽ là `false` khi field chưa được khai trong DTO.

- [ ] **Step 7: Thêm field vào DTO**

Trong `apps/wms/src/stock/dto/create-warehouse-item.dto.ts`, thêm vào `CreateWarehouseItemDto` ngay sau `nearExpiryDays`:

```ts
  @ApiPropertyOptional({
    example: 10,
    description:
      'Ngưỡng tối thiểu — available dưới ngưỡng này thì phát cảnh báo stock.low',
  })
  @IsOptional()
  @IsInt()
  @Min(0)
  minQuantity?: number;
```

- [ ] **Step 8: Run test to verify it passes**

Run: `pnpm test -- create-warehouse-item.dto`
Expected: PASS, 3 tests.

- [ ] **Step 9: Thêm field vào Response DTO (không cần spec riêng — theo quy ước response DTO trong repo)**

Trong `apps/wms/src/stock/dto/warehouse-item.response.dto.ts`, thêm vào `WarehouseItemResponseDto` ngay sau `nearExpiryDays`:

```ts
  @Expose()
  @ApiPropertyOptional()
  minQuantity?: number;
```

- [ ] **Step 10: Thêm field vào `CreateWarehouseItemData` (repository type — không đổi logic)**

Trong `apps/wms/src/stock/stock.repository.ts`, thêm vào type `CreateWarehouseItemData` ngay sau `nearExpiryDays?: number;`:

```ts
  minQuantity?: number;
```

`createItem`/`updateItem` đã spread `{ ...data, ... }` generic nên KHÔNG cần sửa logic — field tự được lưu.

- [ ] **Step 11: Run full stock test suite + typecheck**

Run: `pnpm test -- apps/wms/src/stock`
Expected: PASS toàn bộ (bao gồm test cũ, không regressions).

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json`
Expected: no errors.

- [ ] **Step 12: Commit**

```bash
git add apps/wms/src/stock/schemas/warehouse-item.schema.ts apps/wms/src/stock/schemas/warehouse-item.schema.spec.ts apps/wms/src/stock/dto/create-warehouse-item.dto.ts apps/wms/src/stock/dto/create-warehouse-item.dto.spec.ts apps/wms/src/stock/dto/warehouse-item.response.dto.ts apps/wms/src/stock/stock.repository.ts
git commit -m "feat(wms/stock): thêm minQuantity trên WarehouseItem cho S4-04"
```

---

### Task 2: `StockRepository.findSkuAndMinQuantityById` + `StockService.checkAndEmitStockLow`

**Files:**
- Modify: `apps/wms/src/stock/stock.repository.ts`
- Modify: `apps/wms/src/stock/stock.repository.spec.ts`
- Modify: `apps/wms/src/stock/stock.service.ts`
- Modify: `apps/wms/src/stock/stock.service.spec.ts`
- Modify: `apps/wms/src/stock/stock.module.ts`

**Interfaces:**
- Consumes: `StockRepository.findBalanceByItemAndWarehouse` (đã có sẵn, không đổi); `EVENTS.STOCK_LOW`, `StockLowPayload` từ `@app/events` (đã có sẵn).
- Produces: `StockRepository.findSkuAndMinQuantityById(itemId: Types.ObjectId): Promise<{ sku: string; minQuantity?: number } | null>`, `StockService.checkAndEmitStockLow(itemId: Types.ObjectId, warehouseId: Types.ObjectId): Promise<void>` — dùng bởi Task 3-8 (6 service nghiệp vụ).

- [ ] **Step 1: Write the failing test cho `findSkuAndMinQuantityById`**

Thêm vào `apps/wms/src/stock/stock.repository.spec.ts` (tìm `describe('StockRepository', ...)` hiện có, thêm block mới bên trong):

```ts
  describe('findSkuAndMinQuantityById', () => {
    it('trả về sku + minQuantity khi tìm thấy item', async () => {
      const itemId = new Types.ObjectId();
      itemModel.findById.mockReturnValue({
        select: jest.fn().mockReturnThis(),
        lean: jest.fn().mockReturnThis(),
        exec: jest.fn().mockResolvedValue({ sku: 'SKU-1', minQuantity: 5 }),
      });

      const result = await repo.findSkuAndMinQuantityById(itemId);

      expect(itemModel.findById).toHaveBeenCalledWith(itemId);
      expect(result).toEqual({ sku: 'SKU-1', minQuantity: 5 });
    });

    it('trả về null khi không tìm thấy', async () => {
      const itemId = new Types.ObjectId();
      itemModel.findById.mockReturnValue({
        select: jest.fn().mockReturnThis(),
        lean: jest.fn().mockReturnThis(),
        exec: jest.fn().mockResolvedValue(null),
      });

      const result = await repo.findSkuAndMinQuantityById(itemId);

      expect(result).toBeNull();
    });
  });
```

> Nếu file spec hiện tại chưa có biến mock `itemModel` theo đúng tên này, dùng lại đúng tên biến mock `WarehouseItem` model đã tồn tại trong file (kiểm tra phần `beforeEach`/constructor của `StockRepository` trong spec hiện có trước khi thêm — các test khác trong file (vd `findItemById`) đã dùng cùng 1 mock model, tái dùng chính xác biến đó).

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- stock.repository`
Expected: FAIL — `repo.findSkuAndMinQuantityById is not a function`.

- [ ] **Step 3: Implement `findSkuAndMinQuantityById`**

Trong `apps/wms/src/stock/stock.repository.ts`, thêm method vào class `StockRepository`, ngay sau `findSkuById`:

```ts
  /** Sku + ngưỡng cảnh báo thấp tồn — dùng bởi StockService.checkAndEmitStockLow. */
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

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- stock.repository`
Expected: PASS.

- [ ] **Step 5: Write the failing test cho `checkAndEmitStockLow`**

Thêm vào `apps/wms/src/stock/stock.service.spec.ts` (tìm setup hiện có của `StockService` trong `beforeEach`, thêm mock method cho `stockRepo.findSkuAndMinQuantityById`, `stockRepo.findBalanceByItemAndWarehouse`, và 1 queue mock thứ 2 cho `QUEUES.NOTIFICATION` — xem constructor mới ở Step 7):

```ts
  describe('checkAndEmitStockLow', () => {
    const itemId = new Types.ObjectId();
    const warehouseId = new Types.ObjectId();

    it('minQuantity không set → không emit', async () => {
      stockRepo.findSkuAndMinQuantityById.mockResolvedValue({
        sku: 'SKU-1',
        minQuantity: undefined,
      });

      await svc.checkAndEmitStockLow(itemId, warehouseId);

      expect(stockRepo.findBalanceByItemAndWarehouse).not.toHaveBeenCalled();
      expect(notificationQueue.add).not.toHaveBeenCalled();
    });

    it('không tìm thấy item → không emit', async () => {
      stockRepo.findSkuAndMinQuantityById.mockResolvedValue(null);

      await svc.checkAndEmitStockLow(itemId, warehouseId);

      expect(notificationQueue.add).not.toHaveBeenCalled();
    });

    it('available ≥ minQuantity → không emit', async () => {
      stockRepo.findSkuAndMinQuantityById.mockResolvedValue({
        sku: 'SKU-1',
        minQuantity: 5,
      });
      stockRepo.findBalanceByItemAndWarehouse.mockResolvedValue({
        onHand: 10,
        reserved: 0,
        expired: 0,
      });

      await svc.checkAndEmitStockLow(itemId, warehouseId);

      expect(notificationQueue.add).not.toHaveBeenCalled();
    });

    it('available < minQuantity → emit stock.low KHÔNG kèm jobId (không dedup)', async () => {
      stockRepo.findSkuAndMinQuantityById.mockResolvedValue({
        sku: 'SKU-1',
        minQuantity: 5,
      });
      stockRepo.findBalanceByItemAndWarehouse.mockResolvedValue({
        onHand: 3,
        reserved: 1,
        expired: 0,
      });

      await svc.checkAndEmitStockLow(itemId, warehouseId);

      expect(notificationQueue.add).toHaveBeenCalledWith(
        EVENTS.STOCK_LOW,
        {
          sku: 'SKU-1',
          warehouseId: warehouseId.toString(),
          available: 2,
          minQuantity: 5,
        },
      );
      // không truyền option thứ 3 ({ jobId }) — khớp quyết định "không dedup"
      expect(notificationQueue.add.mock.calls[0]).toHaveLength(2);
    });

    it('không tìm thấy StockBalance cho (item,warehouse) → không emit', async () => {
      stockRepo.findSkuAndMinQuantityById.mockResolvedValue({
        sku: 'SKU-1',
        minQuantity: 5,
      });
      stockRepo.findBalanceByItemAndWarehouse.mockResolvedValue(null);

      await svc.checkAndEmitStockLow(itemId, warehouseId);

      expect(notificationQueue.add).not.toHaveBeenCalled();
    });
  });
```

- [ ] **Step 6: Run test to verify it fails**

Run: `pnpm test -- stock.service`
Expected: FAIL — `svc.checkAndEmitStockLow is not a function` (và constructor mismatch nếu `notificationQueue`/`stockRepo.findSkuAndMinQuantityById` chưa khai trong mock — sửa mock trước theo Step 7 rồi mới chạy lại nếu cần).

- [ ] **Step 7: Implement `checkAndEmitStockLow` + inject `QUEUES.NOTIFICATION`**

Trong `apps/wms/src/stock/stock.service.ts`, sửa import + constructor:

```ts
import { InjectQueue } from '@nestjs/bullmq';
import { Injectable, Logger } from '@nestjs/common';
import {
  EVENTS,
  QUEUES,
  type StockChangedPayload,
  type StockLowPayload,
} from '@app/events';
import { AppException } from '@app/common';
import { Queue } from 'bullmq';
import { Types } from 'mongoose';
import { StockRepository } from './stock.repository';
import type { CreateWarehouseItemData } from './stock.repository';
import type { WarehouseItemDocument } from './schemas/warehouse-item.schema';
import type { QueryWarehouseItemDto } from './dto/query-warehouse-item.dto';
import type { UpdateWarehouseItemDto } from './dto/create-warehouse-item.dto';

@Injectable()
export class StockService {
  private readonly logger = new Logger(StockService.name);

  constructor(
    private readonly stockRepo: StockRepository,
    @InjectQueue(QUEUES.STOCK) private readonly stockQueue: Queue,
    @InjectQueue(QUEUES.NOTIFICATION)
    private readonly notificationQueue: Queue,
  ) {}
```

Thêm method vào class `StockService`, sau `publishAvailableForItem`:

```ts
  /**
   * Kiểm tra available HIỆN TẠI (đọc lại DB, KHÔNG nhận balance qua tham số) sau
   * biến động, phát stock.low nếu dưới ngưỡng minQuantity. PHẢI gọi SAU KHI
   * transaction Mongo đã commit — BullMQ không tham gia transaction. Đọc lại (thay
   * vì dùng giá trị upsertBalance trả về ngay trong transaction) để luôn đúng với
   * trạng thái CUỐI CÙNG khi 1 (item,warehouse) bị chạm nhiều lần trong cùng
   * transaction (vd GoodsReturn dòng DAMAGED: RETURN_IN rồi SCRAP bù ngay sau).
   * KHÔNG dùng jobId khi add job — mỗi lần gọi đều phải tạo job mới (quyết định:
   * không dedup, chấp nhận báo lại nếu tồn thấp kéo dài qua nhiều biến động).
   */
  async checkAndEmitStockLow(
    itemId: Types.ObjectId,
    warehouseId: Types.ObjectId,
  ): Promise<void> {
    const item = await this.stockRepo.findSkuAndMinQuantityById(itemId);
    if (!item || item.minQuantity == null) return;

    const balance = await this.stockRepo.findBalanceByItemAndWarehouse(
      itemId,
      warehouseId,
    );
    if (!balance) return;

    const available = balance.onHand - balance.reserved - balance.expired;
    if (available >= item.minQuantity) return;

    const payload: StockLowPayload = {
      sku: item.sku,
      warehouseId: warehouseId.toString(),
      available,
      minQuantity: item.minQuantity,
    };
    await this.notificationQueue.add(EVENTS.STOCK_LOW, payload);
    this.logger.log(
      `stock.low → sku=${item.sku} warehouseId=${warehouseId.toString()} available=${available} minQuantity=${item.minQuantity}`,
    );
  }
```

Cập nhật `beforeEach` trong `stock.service.spec.ts` để constructor mới có 3 tham số — thêm mock `stockRepo.findSkuAndMinQuantityById`/`stockRepo.findBalanceByItemAndWarehouse` và biến `notificationQueue`:

```ts
    stockRepo = {
      // ...giữ nguyên các mock cũ...
      findSkuAndMinQuantityById: jest.fn(),
      findBalanceByItemAndWarehouse: jest.fn(),
    };
    stockQueue = { add: jest.fn() };
    notificationQueue = { add: jest.fn() };
    svc = new StockService(
      stockRepo as never,
      stockQueue as never,
      notificationQueue as never,
    );
```

(Điều chỉnh đúng theo cấu trúc `beforeEach` hiện có trong file — chỉ thêm 2 mock method + 1 biến queue mới, không xóa mock cũ.)

- [ ] **Step 8: Run test to verify it passes**

Run: `pnpm test -- stock.service`
Expected: PASS, tất cả test cũ + 5 test mới.

- [ ] **Step 9: Đăng ký `QUEUES.NOTIFICATION` trong `StockModule`**

Trong `apps/wms/src/stock/stock.module.ts`, sửa import + `imports`:

```ts
import { BullModule } from '@nestjs/bullmq';
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { QUEUES } from '@app/events';
// ...giữ nguyên các import schema...

@Module({
  imports: [
    BullModule.registerQueue(
      { name: QUEUES.STOCK },
      { name: QUEUES.NOTIFICATION }, // S4-04: StockService.checkAndEmitStockLow → stock.low
    ),
    MongooseModule.forFeature([
      // ...giữ nguyên...
    ]),
  ],
  controllers: [StockController],
  providers: [StockRepository, StockService, StockTransactionHelper],
  exports: [StockService, StockTransactionHelper, StockRepository],
})
export class StockModule {}
```

- [ ] **Step 10: Run full test suite + typecheck + build**

Run: `pnpm test`
Expected: PASS toàn bộ, không regressions.

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json`
Expected: no errors.

Run: `pnpm exec nest build wms`
Expected: builds successfully (xác nhận `StockModule` khởi tạo được với 2 queue).

- [ ] **Step 11: Commit**

```bash
git add apps/wms/src/stock/stock.repository.ts apps/wms/src/stock/stock.repository.spec.ts apps/wms/src/stock/stock.service.ts apps/wms/src/stock/stock.service.spec.ts apps/wms/src/stock/stock.module.ts
git commit -m "feat(wms/stock): thêm StockService.checkAndEmitStockLow cho S4-04"
```

---

### Task 3: Wiring `checkAndEmitStockLow` vào `goods-receipt-note.service.ts`

**Files:**
- Modify: `apps/wms/src/goods-receipt-note/goods-receipt-note.service.ts`
- Modify: `apps/wms/src/goods-receipt-note/goods-receipt-note.service.spec.ts`

**Interfaces:**
- Consumes: `StockService.checkAndEmitStockLow` (Task 2) — `GoodsReceiptNoteService` đã inject `StockService` sẵn (dùng cho `publishAvailableForItem`).

- [ ] **Step 1: Write the failing test**

Tìm test hiện có cho `confirmGoodsReceiptNote` trong `goods-receipt-note.service.spec.ts` (đã có mock `stockService.publishAvailableForItem`). Thêm assertion vào ĐÚNG test "xác nhận GRN thành công" (hoặc thêm 1 `it` mới nếu file test theo từng hành vi riêng):

```ts
  it('confirmGoodsReceiptNote gọi checkAndEmitStockLow cho mỗi item đã cộng tồn', async () => {
    // Dùng lại setup/mock đã có trong test "xác nhận GRN" hiện tại của file —
    // sau khi gọi confirmGoodsReceiptNote(...), assert thêm:
    expect(stockService.checkAndEmitStockLow).toHaveBeenCalledWith(
      expect.any(Types.ObjectId),
      expect.any(Types.ObjectId),
    );
  });
```

> Vì file test hiện tại có setup phức tạp (nhiều mock repo/warehouse/putAway), hãy đặt assertion này NGAY SAU lệnh gọi `confirmGoodsReceiptNote` trong test case đã tồn tại kiểm tra luồng confirm thành công — không viết lại toàn bộ setup. Thêm mock method `checkAndEmitStockLow: jest.fn()` vào object mock `stockService` trong `beforeEach` nếu mock đó chưa có field này (kiểm tra file thật trước khi sửa — mock `stockService` hiện tại chỉ có `publishAvailableForItem`).

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- goods-receipt-note.service`
Expected: FAIL — `stockService.checkAndEmitStockLow` chưa được gọi (hoặc mock chưa có method → TypeError, tuỳ cách viết mock).

- [ ] **Step 3: Implement wiring**

Trong `apps/wms/src/goods-receipt-note/goods-receipt-note.service.ts`, sửa `confirmGoodsReceiptNote`: khai báo map trước transaction, set trong transaction, loop sau transaction (cạnh loop `publishAvailableForItem` đã có):

```ts
  async confirmGoodsReceiptNote(
    id: string,
    actorId: string,
  ): Promise<GoodsReceiptNoteDocument> {
    const grn = await this.repo.findGoodsReceiptNoteById(id);
    if (!grn) throw new AppException('GRN_NOT_FOUND');
    if (grn.status !== GoodsReceiptNoteStatus.DRAFT) {
      throw new AppException('GRN_INVALID_STATUS_TRANSITION');
    }

    const po = await this.purchaseOrderService.getPurchaseOrder(
      grn.purchaseOrderId.toString(),
    );

    const baseQtyByItem = new Map<string, number>();
    const resolvedLines: {
      itemId: string;
      sku: string;
      baseQty: number;
      lotNumber?: string;
      expiryDate?: Date;
    }[] = [];

    for (const line of grn.items) {
      const warehouseItem = await this.stockRepo.findItemById(
        line.itemId.toString(),
      );
      const factor =
        warehouseItem?.altUnits?.find((u) => u.unit === line.unit)?.factor ?? 1;
      const baseQty = line.actualQty * factor;
      const key = line.itemId.toString();
      baseQtyByItem.set(key, (baseQtyByItem.get(key) ?? 0) + baseQty);
      resolvedLines.push({
        itemId: key,
        sku: line.sku,
        baseQty,
        lotNumber: line.lotNumber,
        expiryDate: line.expiryDate,
      });
    }

    for (const [itemId, totalBaseQty] of baseQtyByItem) {
      const poItem = po.items.find((i) => i.itemId.toString() === itemId);
      if (!poItem) throw new AppException('GRN_ITEM_NOT_IN_PO');
      if (poItem.receivedQty + totalBaseQty > poItem.expectedQty) {
        throw new AppException('GRN_QTY_EXCEEDS_PO');
      }
    }

    const stagingShelf = await this.warehouseService.findStagingShelf(
      grn.warehouseId.toString(),
    );

    // S4-04: cặp (item,warehouse) đã chạm upsertBalance trong transaction — dùng
    // để checkAndEmitStockLow SAU KHI commit. warehouseId luôn = grn.warehouseId
    // (1 GRN chỉ nhận vào 1 kho) nhưng vẫn key theo cả 2 cho rõ nghĩa/nhất quán
    // với các service khác.
    const touchedBalances = new Map<
      string,
      { itemId: Types.ObjectId; warehouseId: Types.ObjectId }
    >();

    await this.stockTransactionHelper.withStockTransaction(async (session) => {
      const putAwayLines: {
        itemId: string;
        lotId: Types.ObjectId | null;
        quantity: number;
      }[] = [];

      for (const line of resolvedLines) {
        const itemObjectId = new Types.ObjectId(line.itemId);
        const warehouseObjectId = new Types.ObjectId(
          grn.warehouseId.toString(),
        );

        let lotId: Types.ObjectId | null = null;
        if (line.lotNumber && line.expiryDate) {
          const existingLot = await this.stockRepo.findActiveLotByNumber(
            itemObjectId,
            line.lotNumber,
            session,
          );
          const lot =
            existingLot ??
            (await this.stockRepo.createLot(
              {
                itemId: itemObjectId,
                lotNumber: line.lotNumber,
                expiryDate: line.expiryDate,
                receivedDate: new Date(),
              },
              session,
            ));
          lotId = lot._id;
        }

        putAwayLines.push({
          itemId: line.itemId,
          lotId,
          quantity: line.baseQty,
        });

        await this.stockRepo.upsertBalance(
          itemObjectId,
          warehouseObjectId,
          line.baseQty,
          0,
          0,
          session,
        );
        touchedBalances.set(`${line.itemId}:${grn.warehouseId.toString()}`, {
          itemId: itemObjectId,
          warehouseId: warehouseObjectId,
        });
        await this.stockRepo.upsertInventory(
          itemObjectId,
          warehouseObjectId,
          stagingShelf._id,
          lotId,
          line.baseQty,
          session,
        );
        await this.stockRepo.insertMovement(
          {
            itemId: itemObjectId,
            warehouseId: warehouseObjectId,
            shelfId: stagingShelf._id,
            lotId,
            type: MovementType.RECEIVE,
            quantity: line.baseQty,
            refType: 'grn',
            refId: grn._id,
            createdBy: new Types.ObjectId(actorId),
          },
          session,
        );
        await this.purchaseOrderService.applyReceivedQty(
          grn.purchaseOrderId.toString(),
          line.itemId,
          line.baseQty,
          session,
        );
      }

      await this.putAwayService.createTaskFromGrn(
        grn._id,
        new Types.ObjectId(grn.warehouseId.toString()),
        putAwayLines,
        actorId,
        session,
      );

      await this.repo.updateStatusConfirmed(id, actorId, session);
    });

    // Ngoài transaction — BullMQ không tham gia Mongo transaction
    for (const [itemId, totalBaseQty] of baseQtyByItem) {
      await this.stockService.publishAvailableForItem(
        itemId,
        totalBaseQty,
        'grn',
        grn._id,
      );
    }
    for (const { itemId, warehouseId } of touchedBalances.values()) {
      await this.stockService.checkAndEmitStockLow(itemId, warehouseId);
    }

    const confirmed = await this.repo.findGoodsReceiptNoteById(id);
    if (!confirmed) throw new AppException('GRN_NOT_FOUND');
    return confirmed;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- goods-receipt-note.service`
Expected: PASS.

- [ ] **Step 5: Run full test suite + typecheck**

Run: `pnpm test`
Expected: PASS, không regressions.

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/goods-receipt-note/goods-receipt-note.service.ts apps/wms/src/goods-receipt-note/goods-receipt-note.service.spec.ts
git commit -m "feat(wms/goods-receipt-note): wiring checkAndEmitStockLow cho S4-04"
```

---

### Task 4: Wiring vào `goods-issue.service.ts`

**Files:**
- Modify: `apps/wms/src/goods-issue/goods-issue.service.ts`
- Modify: `apps/wms/src/goods-issue/goods-issue.service.spec.ts`

**Interfaces:**
- Consumes: `StockService.checkAndEmitStockLow` (Task 2). `GoodsIssueService` CHƯA inject `StockService` — cần thêm vào constructor (module `GoodsIssueModule` đã `imports: [StockModule]` nên `StockService` sẵn có để inject).

- [ ] **Step 1: Write the failing test**

Trong `goods-issue.service.spec.ts`, thêm mock `stockService` vào `beforeEach` và constructor call:

```ts
const makeStockService = () => ({
  checkAndEmitStockLow: jest.fn(),
});
```

Trong `beforeEach`, thêm `stockService = makeStockService();` và thêm `stockService as never` vào lời gọi `new GoodsIssueService(...)` — vị trí tham số theo đúng thứ tự constructor mới ở Step 3 (sau `stockRepo`).

Thêm test mới trong `describe('confirmLine', ...)` (hoặc block tương đương đang test method này):

```ts
  it('confirmLine gọi checkAndEmitStockLow(item._id, gi.warehouseId) sau khi transaction commit', async () => {
    // Setup giống test "xác nhận dòng thành công" hiện có của confirmLine —
    // repo.findById trả gi hợp lệ, stockRepo.findItemByBarcode trả item,
    // warehouseRepo.findShelfByCode trả shelf cùng warehouseId, stockRepo.findInventory
    // trả đủ tồn, repo.markConfirmedIfAllDone trả false.
    await svc.confirmLine(giId, dto, actorId);

    expect(stockService.checkAndEmitStockLow).toHaveBeenCalledWith(
      itemId,
      warehouseId,
    );
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- goods-issue.service`
Expected: FAIL — constructor arity mismatch hoặc `checkAndEmitStockLow` chưa được gọi.

- [ ] **Step 3: Implement wiring**

Trong `apps/wms/src/goods-issue/goods-issue.service.ts`, thêm import + constructor:

```ts
import { StockService } from '../stock/stock.service';
```

```ts
  constructor(
    private readonly repo: GoodsIssueRepository,
    private readonly stockRepo: StockRepository,
    private readonly stockService: StockService,
    private readonly warehouseRepo: WarehouseRepository,
    private readonly stockTransactionHelper: StockTransactionHelper,
    @InjectQueue(QUEUES.SHIPMENT) private readonly shipmentQueue: Queue,
  ) {}
```

Sửa `confirmLine`:

```ts
  async confirmLine(
    id: string,
    dto: ConfirmGoodsIssueLineDto,
    actorId: string,
  ): Promise<GoodsIssueDocument> {
    const gi = await this.repo.findById(id);
    if (!gi) throw new AppException('GOODS_ISSUE_NOT_FOUND');

    const item = await this.stockRepo.findItemByBarcode(dto.itemBarcode);
    if (!item) throw new AppException('GOODS_ISSUE_ITEM_NOT_FOUND');

    const shelf = await this.warehouseRepo.findShelfByCode(dto.shelfCode);
    if (!shelf) throw new AppException('GOODS_ISSUE_SHELF_NOT_FOUND');
    if (shelf.warehouseId.toString() !== gi.warehouseId.toString()) {
      throw new AppException('GOODS_ISSUE_SHELF_NOT_FOUND');
    }

    const line = gi.items.find(
      (i) => i.itemId.toString() === item._id.toString(),
    );
    if (!line) throw new AppException('GOODS_ISSUE_ITEM_MISMATCH');
    if (dto.quantity > line.remainingQty) {
      throw new AppException('GOODS_ISSUE_QTY_EXCEEDS');
    }

    const lotId = dto.lotId ? new Types.ObjectId(dto.lotId) : null;
    const inventory = await this.stockRepo.findInventory(
      item._id,
      gi.warehouseId,
      shelf._id,
      lotId,
    );
    if (!inventory || inventory.quantity < dto.quantity) {
      throw new AppException('STOCK_INSUFFICIENT');
    }

    let justConfirmed = false;
    await this.stockTransactionHelper.withStockTransaction(async (session) => {
      await this.stockRepo.upsertInventory(
        item._id,
        gi.warehouseId,
        shelf._id,
        lotId,
        -dto.quantity,
        session,
      );
      await this.stockRepo.upsertBalance(
        item._id,
        gi.warehouseId,
        -dto.quantity,
        -dto.quantity,
        0,
        session,
      );
      await this.stockRepo.insertMovement(
        {
          itemId: item._id,
          warehouseId: gi.warehouseId,
          shelfId: shelf._id,
          lotId,
          type: MovementType.ISSUE,
          quantity: -dto.quantity,
          refType: 'goods_issue',
          refId: gi._id,
          createdBy: new Types.ObjectId(actorId),
        },
        session,
      );
      await this.repo.decrementRemainingQty(
        id,
        item._id,
        dto.quantity,
        session,
      );
      justConfirmed = await this.repo.markConfirmedIfAllDone(id, session);
    });

    // S4-04: kiểm tra ngưỡng thấp tồn — sau khi transaction commit.
    await this.stockService.checkAndEmitStockLow(item._id, gi.warehouseId);

    const updated = await this.repo.findById(id);
    if (!updated) throw new AppException('GOODS_ISSUE_NOT_FOUND');

    if (justConfirmed) {
      await this.emitGoodsIssued(gi.orderId, id);
    }

    return updated;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- goods-issue.service`
Expected: PASS.

- [ ] **Step 5: Run full test suite + typecheck**

Run: `pnpm test`
Expected: PASS, không regressions.

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/goods-issue/goods-issue.service.ts apps/wms/src/goods-issue/goods-issue.service.spec.ts
git commit -m "feat(wms/goods-issue): wiring checkAndEmitStockLow cho S4-04"
```

---

### Task 5: Wiring vào `stock-count.service.ts`

**Files:**
- Modify: `apps/wms/src/stock-count/stock-count.service.ts`
- Modify: `apps/wms/src/stock-count/stock-count.service.spec.ts`

**Interfaces:**
- Consumes: `StockService.checkAndEmitStockLow` (Task 2). Cần thêm `StockService` vào constructor (kiểm tra file thật: nếu `StockCountService` đã inject `StockService` cho mục đích khác thì chỉ tái dùng, không thêm tham số trùng — đọc constructor hiện tại trước khi sửa).

- [ ] **Step 1: Write the failing test**

Trong `stock-count.service.spec.ts`, thêm mock `stockService = { checkAndEmitStockLow: jest.fn() }` vào `beforeEach` + constructor call (đúng vị trí tham số theo Step 3). Thêm test trong block đang test `approveStockCount`:

```ts
  it('approveStockCount gọi checkAndEmitStockLow cho mỗi dòng có delta ≠ 0', async () => {
    // Setup giống test "duyệt phiếu kiểm kho thành công" hiện có — stockCount có
    // 2 dòng changedLines (delta khác 0), 1 dòng delta=0/null (bị filter, không tính).
    await svc.approveStockCount(id, dto, actorId);

    expect(stockService.checkAndEmitStockLow).toHaveBeenCalledTimes(2);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- stock-count.service`
Expected: FAIL.

- [ ] **Step 3: Implement wiring**

Trong `apps/wms/src/stock-count/stock-count.service.ts`, thêm import `StockService` (nếu chưa có) và tham số constructor, rồi sửa `approveStockCount`:

```ts
import { StockService } from '../stock/stock.service';
```

```ts
  constructor(
    private readonly repo: StockCountRepository,
    private readonly stockRepo: StockRepository,
    private readonly stockService: StockService,
    private readonly stockTransactionHelper: StockTransactionHelper,
    // ...giữ nguyên các tham số khác đã có...
  ) {}
```

> Đọc constructor thật trước khi sửa — chỉ thêm `stockService` vào đúng vị trí, giữ nguyên mọi tham số khác theo thứ tự hiện tại của file.

```ts
  async approveStockCount(
    id: string,
    dto: ApproveStockCountDto,
    actorId: string,
  ): Promise<StockCountDocument> {
    const stockCount = await this.repo.findById(id);
    if (!stockCount) throw new AppException('STOCK_COUNT_NOT_FOUND');
    if (stockCount.status !== StockCountStatus.COMPLETED) {
      throw new AppException('STOCK_COUNT_NOT_COMPLETED');
    }

    const changedLines = stockCount.items.filter(
      (i) => i.delta !== null && i.delta !== 0,
    );

    await this.stockTransactionHelper.withStockTransaction(async (session) => {
      for (const line of changedLines) {
        const delta = line.delta!;
        await this.stockRepo.upsertInventory(
          line.itemId,
          stockCount.warehouseId,
          line.shelfId,
          line.lotId,
          delta,
          session,
        );
        await this.stockRepo.upsertBalance(
          line.itemId,
          stockCount.warehouseId,
          delta,
          0,
          0,
          session,
        );
        await this.stockRepo.insertMovement(
          {
            itemId: line.itemId,
            warehouseId: stockCount.warehouseId,
            shelfId: line.shelfId,
            lotId: line.lotId,
            type: MovementType.ADJUST,
            quantity: delta,
            refType: 'stock_count',
            refId: stockCount._id,
            createdBy: new Types.ObjectId(actorId),
          },
          session,
        );
      }
      await this.repo.setApproved(
        id,
        new Types.ObjectId(actorId),
        dto.reason,
        session,
      );
    });

    // S4-04: kiểm tra ngưỡng thấp tồn cho mỗi dòng đã điều chỉnh — sau khi commit.
    for (const line of changedLines) {
      await this.stockService.checkAndEmitStockLow(
        line.itemId,
        stockCount.warehouseId,
      );
    }

    // ...giữ nguyên phần còn lại của method (đọc + trả về stockCount đã cập nhật,
    // và bất kỳ logic stock.changed đã có sẵn nếu tồn tại — kiểm tra file thật)...
  }
```

> Đọc phần **sau** khối `withStockTransaction` trong file thật trước khi sửa — chỉ chèn thêm loop `checkAndEmitStockLow` NGAY SAU transaction (trước hoặc sau logic hiện có khác đều được, miễn là sau transaction), không xóa/đổi code đã có.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- stock-count.service`
Expected: PASS.

- [ ] **Step 5: Run full test suite + typecheck**

Run: `pnpm test`
Expected: PASS, không regressions.

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/stock-count/stock-count.service.ts apps/wms/src/stock-count/stock-count.service.spec.ts
git commit -m "feat(wms/stock-count): wiring checkAndEmitStockLow cho S4-04"
```

---

### Task 6: Wiring vào `scrap-note.service.ts`

**Files:**
- Modify: `apps/wms/src/scrap-note/scrap-note.service.ts`
- Modify: `apps/wms/src/scrap-note/scrap-note.service.spec.ts`

**Interfaces:**
- Consumes: `StockService.checkAndEmitStockLow` (Task 2). Chỉ wiring cho `approveScrapNote` (phiếu MANAGER tự duyệt) — **KHÔNG** đổi `createApprovedScrapNoteForReturn` (được gọi từ `GoodsReturnService`, wiring cho path đó nằm ở Task 7 theo đúng design: `checkAndEmitStockLow` đọc lại balance nên tự đúng, không cần đổi return type của method này).

- [ ] **Step 1: Write the failing test**

Trong `scrap-note.service.spec.ts`, thêm mock `stockService = { checkAndEmitStockLow: jest.fn() }` + constructor. Thêm test trong block `approveScrapNote`:

```ts
  it('approveScrapNote gọi checkAndEmitStockLow cho mỗi dòng đã trừ tồn', async () => {
    // Setup giống test "duyệt phiếu scrap thành công" hiện có — scrapNote có 2 dòng.
    await svc.approveScrapNote(id, actorId);

    expect(stockService.checkAndEmitStockLow).toHaveBeenCalledTimes(2);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- scrap-note.service`
Expected: FAIL.

- [ ] **Step 3: Implement wiring**

Trong `apps/wms/src/scrap-note/scrap-note.service.ts`, thêm import + constructor:

```ts
import { StockService } from '../stock/stock.service';
```

```ts
  constructor(
    private readonly repo: ScrapNoteRepository,
    private readonly stockRepo: StockRepository,
    private readonly stockService: StockService,
    private readonly warehouseRepo: WarehouseRepository,
    private readonly stockTransactionHelper: StockTransactionHelper,
    @InjectQueue(QUEUES.STOCK) private readonly stockQueue: Queue,
  ) {}
```

Sửa `approveScrapNote`:

```ts
  async approveScrapNote(
    id: string,
    actorId: string,
  ): Promise<ScrapNoteDocument> {
    const scrapNote = await this.repo.findById(id);
    if (!scrapNote) throw new AppException('SCRAP_NOTE_NOT_FOUND');
    if (scrapNote.status !== ScrapNoteStatus.DRAFT) {
      throw new AppException('SCRAP_NOTE_ALREADY_DECIDED');
    }

    await this.stockTransactionHelper.withStockTransaction(async (session) => {
      for (const line of scrapNote.items) {
        await this.stockRepo.upsertInventory(
          line.itemId,
          scrapNote.warehouseId,
          line.shelfId,
          line.lotId,
          -line.quantity,
          session,
        );
        const expiredDelta = line.lotId ? -line.quantity : 0;
        await this.stockRepo.upsertBalance(
          line.itemId,
          scrapNote.warehouseId,
          -line.quantity,
          0,
          expiredDelta,
          session,
        );
        await this.stockRepo.insertMovement(
          {
            itemId: line.itemId,
            warehouseId: scrapNote.warehouseId,
            shelfId: line.shelfId,
            lotId: line.lotId,
            type: MovementType.SCRAP,
            quantity: -line.quantity,
            refType: 'scrap_note',
            refId: scrapNote._id,
            createdBy: new Types.ObjectId(actorId),
          },
          session,
        );
      }
      await this.repo.setApproved(id, new Types.ObjectId(actorId), session);
    });

    for (const line of scrapNote.items) {
      if (line.lotId || line.skipAvailableSync) continue;
      const payload: StockChangedPayload = {
        sku: line.sku,
        delta: -line.quantity,
      };
      const jobId = `scrap_note:${id}:${line.sku}`;
      await this.stockQueue.add(EVENTS.STOCK_CHANGED, payload, { jobId });
    }

    // S4-04: kiểm tra ngưỡng thấp tồn cho MỌI dòng (bao gồm cả lotId/skipAvailableSync
    // — khác với vòng lặp stock.changed phía trên, vì stock.low quan tâm available
    // sau MỌI biến động onHand, không chỉ dòng ảnh hưởng available đã sync Ecom).
    for (const line of scrapNote.items) {
      await this.stockService.checkAndEmitStockLow(
        line.itemId,
        scrapNote.warehouseId,
      );
    }

    const updated = await this.repo.findById(id);
    if (!updated) throw new AppException('SCRAP_NOTE_NOT_FOUND');
    return updated;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- scrap-note.service`
Expected: PASS.

- [ ] **Step 5: Run full test suite + typecheck**

Run: `pnpm test`
Expected: PASS, không regressions.

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/scrap-note/scrap-note.service.ts apps/wms/src/scrap-note/scrap-note.service.spec.ts
git commit -m "feat(wms/scrap-note): wiring checkAndEmitStockLow cho S4-04"
```

---

### Task 7: Wiring vào `goods-return.service.ts`

**Files:**
- Modify: `apps/wms/src/goods-return/goods-return.service.ts`
- Modify: `apps/wms/src/goods-return/goods-return.service.spec.ts`

**Interfaces:**
- Consumes: `StockService.checkAndEmitStockLow` (Task 2). Đây là ca đặc biệt trong design: dòng DAMAGED có 2 lệnh `upsertBalance` bù nhau trong CÙNG transaction (1 ở đây, 1 bên trong `ScrapNoteService.createApprovedScrapNoteForReturn`) — vì `checkAndEmitStockLow` tự đọc lại balance sau commit, chỉ cần set map entry 1 LẦN tại điểm gọi `upsertBalance` đầu tiên trong `confirmGoodsReturn` cho MỌI dòng (GOOD và DAMAGED), không cần biết/đổi gì bên trong `ScrapNoteService`.

- [ ] **Step 1: Write the failing test**

Trong `goods-return.service.spec.ts`, thêm mock `stockService = { checkAndEmitStockLow: jest.fn() }` + constructor. Thêm test trong block `confirmGoodsReturn`:

```ts
  it('confirmGoodsReturn gọi checkAndEmitStockLow cho mỗi dòng (cả GOOD và DAMAGED)', async () => {
    // Setup giống test "confirm goods return thành công" hiện có — goodsReturn có
    // 1 dòng GOOD + 1 dòng DAMAGED.
    await svc.confirmGoodsReturn(id, actorId);

    expect(stockService.checkAndEmitStockLow).toHaveBeenCalledTimes(2);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- goods-return.service`
Expected: FAIL.

- [ ] **Step 3: Implement wiring**

Trong `apps/wms/src/goods-return/goods-return.service.ts`, thêm import + constructor:

```ts
import { StockService } from '../stock/stock.service';
```

```ts
  constructor(
    private readonly repo: GoodsReturnRepository,
    private readonly stockRepo: StockRepository,
    private readonly stockService: StockService,
    private readonly warehouseRepo: WarehouseRepository,
    private readonly scrapNoteService: ScrapNoteService,
    private readonly stockTransactionHelper: StockTransactionHelper,
    @InjectQueue(QUEUES.STOCK) private readonly stockQueue: Queue,
  ) {}
```

Sửa `confirmGoodsReturn`:

```ts
  async confirmGoodsReturn(
    id: string,
    actorId: string,
  ): Promise<GoodsReturnDocument> {
    const goodsReturn = await this.repo.findById(id);
    if (!goodsReturn) throw new AppException('GOODS_RETURN_NOT_FOUND');
    if (goodsReturn.status !== GoodsReturnStatus.INSPECTED) {
      throw new AppException('GOODS_RETURN_NOT_INSPECTED');
    }

    const actorObjectId = new Types.ObjectId(actorId);
    const goodLines: { sku: string; quantity: number }[] = [];
    const scrapNoteIdByItemId = new Map<string, Types.ObjectId>();
    // S4-04: mọi dòng (GOOD và DAMAGED) đều chạm upsertBalance ở dưới — dòng DAMAGED
    // còn bị ScrapNoteService bù trừ ngay sau trong CÙNG transaction, nhưng vì
    // checkAndEmitStockLow đọc lại balance sau commit nên chỉ cần set map 1 lần ở
    // đây, không cần biết chi tiết bên trong ScrapNoteService.
    const touchedBalances = new Map<
      string,
      { itemId: Types.ObjectId; warehouseId: Types.ObjectId }
    >();

    await this.stockTransactionHelper.withStockTransaction(async (session) => {
      for (const line of goodsReturn.items) {
        if (!line.shelfId) continue; // đã inspect nên luôn có shelfId — guard cho type-safety

        await this.stockRepo.upsertInventory(
          line.itemId,
          goodsReturn.warehouseId!,
          line.shelfId,
          line.lotId,
          line.quantity,
          session,
        );
        await this.stockRepo.upsertBalance(
          line.itemId,
          goodsReturn.warehouseId!,
          line.quantity,
          0,
          0,
          session,
        );
        touchedBalances.set(
          `${line.itemId.toString()}:${goodsReturn.warehouseId!.toString()}`,
          { itemId: line.itemId, warehouseId: goodsReturn.warehouseId! },
        );
        await this.stockRepo.insertMovement(
          {
            itemId: line.itemId,
            warehouseId: goodsReturn.warehouseId!,
            shelfId: line.shelfId,
            lotId: line.lotId,
            type: MovementType.RETURN_IN,
            quantity: line.quantity,
            refType: 'goods_return',
            refId: goodsReturn._id,
            createdBy: actorObjectId,
          },
          session,
        );

        if (line.condition === GoodsReturnItemCondition.DAMAGED) {
          const scrapNoteId =
            await this.scrapNoteService.createApprovedScrapNoteForReturn({
              warehouseId: goodsReturn.warehouseId!,
              itemId: line.itemId,
              sku: line.sku,
              shelfId: line.shelfId,
              lotId: line.lotId,
              quantity: line.quantity,
              actorId: actorObjectId,
              session,
            });
          scrapNoteIdByItemId.set(line.itemId.toString(), scrapNoteId);
        } else {
          goodLines.push({ sku: line.sku, quantity: line.quantity });
        }
      }

      await this.repo.setRestocked(id, scrapNoteIdByItemId, session);
    });

    for (const line of goodLines) {
      const payload: StockChangedPayload = {
        sku: line.sku,
        delta: line.quantity,
      };
      const jobId = `goods_return:${id}:${line.sku}`;
      await this.stockQueue.add(EVENTS.STOCK_CHANGED, payload, { jobId });
    }
    for (const { itemId, warehouseId } of touchedBalances.values()) {
      await this.stockService.checkAndEmitStockLow(itemId, warehouseId);
    }

    const updated = await this.repo.findById(id);
    if (!updated) throw new AppException('GOODS_RETURN_NOT_FOUND');
    return updated;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- goods-return.service`
Expected: PASS.

- [ ] **Step 5: Run full test suite + typecheck**

Run: `pnpm test`
Expected: PASS, không regressions.

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/goods-return/goods-return.service.ts apps/wms/src/goods-return/goods-return.service.spec.ts
git commit -m "feat(wms/goods-return): wiring checkAndEmitStockLow cho S4-04"
```

---

### Task 8: Wiring vào `print-job.service.ts` (3 điểm gọi)

**Files:**
- Modify: `apps/wms/src/print-job/print-job.service.ts`
- Modify: `apps/wms/src/print-job/print-job.service.spec.ts`

**Interfaces:**
- Consumes: `StockService.checkAndEmitStockLow` (Task 2). 3 điểm: `createFromPrintRequested` (reserve CUP_BLANK, có thể nhiều dòng — dùng map), `consumeItem` (1 dòng), `completeItem` (1 dòng).

- [ ] **Step 1: Write the failing test**

Trong `print-job.service.spec.ts`, thêm mock `stockService = { checkAndEmitStockLow: jest.fn() }` + constructor. Thêm 3 test (1 mỗi method) trong các block tương ứng:

```ts
  it('createFromPrintRequested gọi checkAndEmitStockLow cho mỗi dòng đã reserve (reservedQty > 0)', async () => {
    // Setup giống test "tạo PrintJob thành công" hiện có — 2 item, cả 2 đều
    // reservedQty > 0.
    await svc.createFromPrintRequested(orderId, warehouseId, items);

    expect(stockService.checkAndEmitStockLow).toHaveBeenCalledTimes(2);
  });

  it('consumeItem gọi checkAndEmitStockLow(item._id, job.warehouseId) sau khi commit', async () => {
    // Setup giống test "consume thành công" hiện có.
    await svc.consumeItem(id, inputItemId, dto, actorId);

    expect(stockService.checkAndEmitStockLow).toHaveBeenCalledWith(
      itemId,
      warehouseId,
    );
  });

  it('completeItem gọi checkAndEmitStockLow(line.outputItemId, job.warehouseId) sau khi commit', async () => {
    // Setup giống test "complete thành công" hiện có.
    await svc.completeItem(id, inputItemId, dto, actorId);

    expect(stockService.checkAndEmitStockLow).toHaveBeenCalledWith(
      outputItemId,
      warehouseId,
    );
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- print-job.service`
Expected: FAIL.

- [ ] **Step 3: Implement wiring**

Trong `apps/wms/src/print-job/print-job.service.ts`, thêm import + constructor:

```ts
import { StockService } from '../stock/stock.service';
```

```ts
  constructor(
    private readonly repo: PrintJobRepository,
    private readonly stockRepo: StockRepository,
    private readonly stockService: StockService,
    private readonly warehouseRepo: WarehouseRepository,
    private readonly stockTransactionHelper: StockTransactionHelper,
    @InjectQueue(QUEUES.STOCK) private readonly stockQueue: Queue,
    @InjectQueue(QUEUES.SHIPMENT) private readonly shipmentQueue: Queue,
  ) {}
```

Sửa `createFromPrintRequested` — thêm map + loop sau transaction:

```ts
    // Reserve CUP_BLANK (upsertBalance) + tạo PrintJob phải atomic...
    const touchedBalances = new Map<
      string,
      { itemId: Types.ObjectId; warehouseId: Types.ObjectId }
    >();
    await this.stockTransactionHelper.withStockTransaction(async (session) => {
      for (const line of lines) {
        if (line.reservedQty > 0) {
          await this.stockRepo.upsertBalance(
            line.inputItemId,
            whId,
            0,
            line.reservedQty,
            0,
            session,
          );
          touchedBalances.set(`${line.inputItemId.toString()}:${whId.toString()}`, {
            itemId: line.inputItemId,
            warehouseId: whId,
          });
        }
      }
      await this.repo.createPrintJob(orderId, whId, lines, session);
    });

    for (const line of lines) {
      if (line.reservedQty > 0) {
        await this.publishBlankStockChanged(
          line.inputItemId,
          -line.reservedQty,
          orderId,
        );
      }
    }
    for (const { itemId, warehouseId } of touchedBalances.values()) {
      await this.stockService.checkAndEmitStockLow(itemId, warehouseId);
    }
  }
```

Sửa `consumeItem` — hoist biến trước transaction, gọi sau:

```ts
  async consumeItem(
    id: string,
    inputItemId: string,
    dto: ConsumePrintJobItemDto,
    actorId: string,
  ): Promise<PrintJobDocument> {
    const job = await this.repo.findById(id);
    if (!job) throw new AppException('PRINT_JOB_NOT_FOUND');

    const item = await this.stockRepo.findItemByBarcode(dto.itemBarcode);
    if (!item) throw new AppException('PRINT_JOB_ITEM_NOT_FOUND');

    const shelf = await this.warehouseRepo.findShelfByCode(dto.shelfCode);
    if (!shelf) throw new AppException('PRINT_JOB_SHELF_NOT_FOUND');
    if (shelf.warehouseId.toString() !== job.warehouseId.toString()) {
      throw new AppException('PRINT_JOB_SHELF_NOT_FOUND');
    }

    const line = job.items.find(
      (i) =>
        i.inputItemId.toString() === item._id.toString() &&
        i.inputItemId.toString() === inputItemId,
    );
    if (!line) throw new AppException('PRINT_JOB_ITEM_MISMATCH');
    if (dto.quantity > line.remainingQty) {
      throw new AppException('PRINT_JOB_QTY_EXCEEDS');
    }

    const inventory = await this.stockRepo.findInventory(
      item._id,
      job.warehouseId,
      shelf._id,
      null,
    );
    if (!inventory || inventory.quantity < dto.quantity) {
      throw new AppException('STOCK_INSUFFICIENT');
    }

    await this.stockTransactionHelper.withStockTransaction(async (session) => {
      await this.stockRepo.upsertInventory(
        item._id,
        job.warehouseId,
        shelf._id,
        null,
        -dto.quantity,
        session,
      );
      await this.stockRepo.upsertBalance(
        item._id,
        job.warehouseId,
        -dto.quantity,
        -dto.quantity,
        0,
        session,
      );
      await this.stockRepo.insertMovement(
        {
          itemId: item._id,
          warehouseId: job.warehouseId,
          shelfId: shelf._id,
          lotId: null,
          type: MovementType.PRINT_CONSUME,
          quantity: -dto.quantity,
          refType: 'print_job',
          refId: job._id,
          createdBy: new Types.ObjectId(actorId),
        },
        session,
      );
      await this.repo.decrementRemainingQty(
        id,
        item._id,
        dto.quantity,
        session,
      );
      await this.repo.markLineConsumedIfDone(id, item._id, session);
    });

    // S4-04: kiểm tra ngưỡng thấp tồn — sau khi transaction commit.
    await this.stockService.checkAndEmitStockLow(item._id, job.warehouseId);

    const updated = await this.repo.findById(id);
    if (!updated) throw new AppException('PRINT_JOB_NOT_FOUND');
    return updated;
  }
```

Sửa `completeItem`:

```ts
  async completeItem(
    id: string,
    inputItemId: string,
    dto: CompletePrintJobItemDto,
    actorId: string,
  ): Promise<PrintJobDocument> {
    const job = await this.repo.findById(id);
    if (!job) throw new AppException('PRINT_JOB_NOT_FOUND');

    const line = job.items.find(
      (i) => i.inputItemId.toString() === inputItemId,
    );
    if (!line) throw new AppException('PRINT_JOB_ITEM_MISMATCH');
    if (line.remainingQty > 0) {
      throw new AppException('PRINT_JOB_ITEM_NOT_CONSUMED');
    }
    if (line.lineStatus === PrintJobLineStatus.COMPLETED) {
      throw new AppException('PRINT_JOB_ITEM_ALREADY_COMPLETED');
    }

    const shelf = await this.warehouseRepo.findShelfByCode(dto.shelfCode);
    if (!shelf) throw new AppException('PRINT_JOB_SHELF_NOT_FOUND');
    if (shelf.warehouseId.toString() !== job.warehouseId.toString()) {
      throw new AppException('PRINT_JOB_SHELF_NOT_FOUND');
    }
    if (dto.quantity !== line.reservedQty) {
      throw new AppException('PRINT_JOB_QTY_EXCEEDS');
    }

    let allDone = false;
    await this.stockTransactionHelper.withStockTransaction(async (session) => {
      await this.stockRepo.upsertInventory(
        line.outputItemId,
        job.warehouseId,
        shelf._id,
        null,
        dto.quantity,
        session,
      );
      await this.stockRepo.upsertBalance(
        line.outputItemId,
        job.warehouseId,
        dto.quantity,
        dto.quantity,
        0,
        session,
      );
      await this.stockRepo.insertMovement(
        {
          itemId: line.outputItemId,
          warehouseId: job.warehouseId,
          shelfId: shelf._id,
          lotId: null,
          type: MovementType.PRINT_OUTPUT,
          quantity: dto.quantity,
          refType: 'print_job',
          refId: job._id,
          createdBy: new Types.ObjectId(actorId),
        },
        session,
      );
      const result = await this.repo.markLineCompleted(
        id,
        line.inputItemId,
        session,
      );
      allDone = result.allDone;
      if (allDone) {
        await this.repo.markJobCompleted(
          id,
          new Types.ObjectId(actorId),
          session,
        );
      }
    });

    // S4-04: kiểm tra ngưỡng thấp tồn — sau khi transaction commit.
    await this.stockService.checkAndEmitStockLow(
      line.outputItemId,
      job.warehouseId,
    );

    const updated = await this.repo.findById(id);
    if (!updated) throw new AppException('PRINT_JOB_NOT_FOUND');

    if (allDone) {
      await this.emitPrintCompleted(job.orderId, id);
    }

    return updated;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- print-job.service`
Expected: PASS.

- [ ] **Step 5: Run full test suite + typecheck**

Run: `pnpm test`
Expected: PASS, không regressions.

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/print-job/print-job.service.ts apps/wms/src/print-job/print-job.service.spec.ts
git commit -m "feat(wms/print-job): wiring checkAndEmitStockLow cho S4-04"
```

---

### Task 9: `NearExpiryScanService` (cron `stock.near_expiry`)

**Files:**
- Modify: `package.json` (thêm dependency)
- Create: `apps/wms/src/stock/near-expiry-scan.service.ts`
- Create: `apps/wms/src/stock/near-expiry-scan.service.spec.ts`
- Modify: `apps/wms/src/stock/stock.module.ts`
- Modify: `apps/wms/src/app.module.ts`

**Interfaces:**
- Consumes: `Lot`, `LotStatus` từ `../stock/schemas/lot.schema` (đã có); `EVENTS.STOCK_NEAR_EXPIRY`, `StockNearExpiryPayload` từ `@app/events` (đã có).
- Produces: `NearExpiryScanService.scanNearExpiryLots(): Promise<void>` — chạy tự động qua `@Cron`, không có consumer nào khác trong plan này gọi trực tiếp (chỉ test gọi trực tiếp để verify logic).

- [ ] **Step 1: Cài dependency**

Run: `pnpm add @nestjs/schedule`
Expected: `package.json` có thêm `"@nestjs/schedule": "^..."` trong `dependencies`.

- [ ] **Step 2: Write the failing test**

Tạo `apps/wms/src/stock/near-expiry-scan.service.spec.ts`:

```ts
import { Types } from 'mongoose';
import { NearExpiryScanService } from './near-expiry-scan.service';

describe('NearExpiryScanService', () => {
  let svc: NearExpiryScanService;
  let lotModel: { aggregate: jest.Mock };
  let notificationQueue: { add: jest.Mock };

  beforeEach(() => {
    lotModel = { aggregate: jest.fn() };
    notificationQueue = { add: jest.fn() };
    svc = new NearExpiryScanService(
      lotModel as never,
      notificationQueue as never,
    );
  });

  describe('scanNearExpiryLots', () => {
    it('phát 1 job stock.near_expiry cho mỗi lô tìm được, KHÔNG kèm jobId', async () => {
      lotModel.aggregate.mockReturnValue({
        exec: jest.fn().mockResolvedValue([
          {
            lotNumber: 'LOT-1',
            expiryDate: new Date('2026-07-20T00:00:00.000Z'),
            sku: 'SKU-1',
          },
          {
            lotNumber: 'LOT-2',
            expiryDate: new Date('2026-07-21T00:00:00.000Z'),
            sku: 'SKU-2',
          },
        ]),
      });

      await svc.scanNearExpiryLots();

      expect(notificationQueue.add).toHaveBeenCalledTimes(2);
      expect(notificationQueue.add).toHaveBeenNthCalledWith(1, 'stock.near_expiry', {
        sku: 'SKU-1',
        lotNumber: 'LOT-1',
        expiryDate: '2026-07-20T00:00:00.000Z',
      });
      // không truyền jobId — khớp quyết định "không dedup"
      expect(notificationQueue.add.mock.calls[0]).toHaveLength(2);
    });

    it('không có lô nào sắp hết hạn → không emit gì', async () => {
      lotModel.aggregate.mockReturnValue({ exec: jest.fn().mockResolvedValue([]) });

      await svc.scanNearExpiryLots();

      expect(notificationQueue.add).not.toHaveBeenCalled();
    });

    it('$match theo status ACTIVE, $expr lte expiryDate/threshold', async () => {
      lotModel.aggregate.mockReturnValue({ exec: jest.fn().mockResolvedValue([]) });

      await svc.scanNearExpiryLots();

      const pipeline = lotModel.aggregate.mock.calls[0][0] as Record<
        string,
        unknown
      >[];
      expect(pipeline[0]).toEqual({ $match: { status: 'ACTIVE' } });
      const lastMatch = pipeline.find(
        (stage) =>
          typeof stage.$match === 'object' &&
          stage.$match !== null &&
          '$expr' in (stage.$match as Record<string, unknown>),
      );
      expect(lastMatch).toBeDefined();
    });
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pnpm test -- near-expiry-scan.service`
Expected: FAIL — `Cannot find module './near-expiry-scan.service'`.

- [ ] **Step 4: Implement `NearExpiryScanService`**

Tạo `apps/wms/src/stock/near-expiry-scan.service.ts`:

```ts
import { InjectQueue } from '@nestjs/bullmq';
import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { InjectModel } from '@nestjs/mongoose';
import { EVENTS, QUEUES, type StockNearExpiryPayload } from '@app/events';
import { Queue } from 'bullmq';
import { Model, PipelineStage } from 'mongoose';
import { Lot, LotStatus } from './schemas/lot.schema';

interface NearExpiryRow {
  lotNumber: string;
  expiryDate: Date;
  sku: string;
}

const MS_PER_DAY = 24 * 60 * 60 * 1000;
const DEFAULT_NEAR_EXPIRY_DAYS = 7;

/**
 * Cron quét hằng ngày (06:00) mọi Lot ACTIVE có expiryDate trong ngưỡng
 * item.nearExpiryDays (fallback 7 ngày), phát stock.near_expiry cho MỖI lô —
 * KHÔNG dedup (theo quyết định thiết kế: chấp nhận báo lại mỗi ngày cho tới khi
 * lô được xử lý, không cần lưu bảng "đã báo"). Aggregation trực tiếp trên Lot
 * (không qua InventoryStock) vì chỉ cần sku+lotNumber+expiryDate để soạn thông
 * báo, không cần vị trí/số lượng.
 */
@Injectable()
export class NearExpiryScanService {
  private readonly logger = new Logger(NearExpiryScanService.name);

  constructor(
    @InjectModel(Lot.name) private readonly lotModel: Model<Lot>,
    @InjectQueue(QUEUES.NOTIFICATION)
    private readonly notificationQueue: Queue,
  ) {}

  @Cron('0 6 * * *')
  async scanNearExpiryLots(): Promise<void> {
    const now = new Date();
    const pipeline: PipelineStage[] = [
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
          thresholdDate: {
            $add: [
              now,
              {
                $multiply: [
                  { $ifNull: ['$item.nearExpiryDays', DEFAULT_NEAR_EXPIRY_DAYS] },
                  MS_PER_DAY,
                ],
              },
            ],
          },
        },
      },
      { $match: { $expr: { $lte: ['$expiryDate', '$thresholdDate'] } } },
      {
        $project: {
          _id: 0,
          lotNumber: 1,
          expiryDate: 1,
          sku: '$item.sku',
        },
      },
    ];

    const rows = await this.lotModel.aggregate<NearExpiryRow>(pipeline).exec();

    for (const row of rows) {
      const payload: StockNearExpiryPayload = {
        sku: row.sku,
        lotNumber: row.lotNumber,
        expiryDate: row.expiryDate.toISOString(),
      };
      await this.notificationQueue.add(EVENTS.STOCK_NEAR_EXPIRY, payload);
    }
    this.logger.log(`Quét lot sắp hết hạn: ${rows.length} lô cần cảnh báo.`);
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pnpm test -- near-expiry-scan.service`
Expected: PASS, 3 tests.

- [ ] **Step 6: Đăng ký provider trong `StockModule`**

Trong `apps/wms/src/stock/stock.module.ts`, thêm import + provider:

```ts
import { NearExpiryScanService } from './near-expiry-scan.service';
```

```ts
  providers: [
    StockRepository,
    StockService,
    StockTransactionHelper,
    NearExpiryScanService, // S4-04: cron 06:00 quét lot sắp hết hạn → stock.near_expiry
  ],
```

(`Lot`/`LotSchema` đã có sẵn trong `MongooseModule.forFeature` của module này — không cần thêm.)

- [ ] **Step 7: Bật `ScheduleModule` trong `AppModule`**

Trong `apps/wms/src/app.module.ts`, thêm import + vào `imports` (đặt cạnh `EventsModule`):

```ts
import { ScheduleModule } from '@nestjs/schedule';
```

```ts
    EventsModule, // BullMQ + Redis
    ScheduleModule.forRoot(), // S4-04: cron NearExpiryScanService (06:00 quét lot sắp hết hạn)
```

- [ ] **Step 8: Run full test suite + typecheck + build**

Run: `pnpm test`
Expected: PASS, không regressions.

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json`
Expected: no errors.

Run: `pnpm exec nest build wms`
Expected: builds successfully.

- [ ] **Step 9: Commit**

```bash
git add package.json pnpm-lock.yaml apps/wms/src/stock/near-expiry-scan.service.ts apps/wms/src/stock/near-expiry-scan.service.spec.ts apps/wms/src/stock/stock.module.ts apps/wms/src/app.module.ts
git commit -m "feat(wms/stock): thêm NearExpiryScanService (cron stock.near_expiry) cho S4-04"
```

---

### Task 10: Notification — `WAREHOUSE_ALERT_EMAIL` env

**Files:**
- Modify: `apps/notification/src/config/env.validation.ts`

**Interfaces:**
- Produces: env var `WAREHOUSE_ALERT_EMAIL` (optional) — dùng bởi Task 13 (`NotificationConsumer`).

Env validation không có spec file riêng trong repo này (kiểm tra — nếu không có file `.spec.ts` cho `env.validation.ts`, đây là task không-TDD, chỉ sửa trực tiếp).

- [ ] **Step 1: Thêm field vào schema**

Trong `apps/notification/src/config/env.validation.ts`, thêm vào `envSchema` ngay sau `RESEND_FROM`:

```ts
  // Email nhận cảnh báo kho (UC-N04 stock.low, UC-N05 stock.near_expiry). Không set
  // → email cảnh báo tắt mềm, chỉ còn FCM (nếu có) hoặc log warn nếu cả 2 tắt.
  WAREHOUSE_ALERT_EMAIL: z.string().email().optional(),
```

- [ ] **Step 2: Run typecheck**

Run: `pnpm exec tsc --noEmit -p apps/notification/tsconfig.app.json`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add apps/notification/src/config/env.validation.ts
git commit -m "feat(wms/notification): thêm env WAREHOUSE_ALERT_EMAIL cho S4-04"
```

---

### Task 11: Template `StockLowAlertEmail`

**Files:**
- Create: `apps/notification/src/email/templates/stock-low-alert.tsx`
- Modify: `apps/notification/src/email/templates/templates.spec.ts`

**Interfaces:**
- Produces: `StockLowAlertEmail(props: { sku: string; warehouseId: string; available: number; minQuantity: number }): ReactElement` — dùng bởi Task 13.

- [ ] **Step 1: Write the failing test**

Đọc `apps/notification/src/email/templates/templates.spec.ts` hiện có để lấy đúng pattern test (render bằng `@react-email/render` hoặc kiểm tra `ReactElement` không throw — theo cách file đang test `VerifyEmail`/`ResetPasswordEmail`/`GoogleWelcomeEmail`). Thêm block mới theo ĐÚNG pattern đó:

```ts
describe('StockLowAlertEmail', () => {
  it('render không throw với props hợp lệ', () => {
    expect(() =>
      StockLowAlertEmail({
        sku: 'SKU-1',
        warehouseId: 'wh-1',
        available: 2,
        minQuantity: 10,
      }),
    ).not.toThrow();
  });
});
```

> Thêm `import { StockLowAlertEmail } from './stock-low-alert';` vào đầu file. Nếu file test dùng `render()` từ `@react-email/render` để kiểm tra output HTML chứa text cụ thể (kiểm tra file thật trước khi viết), viết test theo đúng cách đó thay vì chỉ check "not.toThrow" — giữ nhất quán với 3 template đã có.

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- templates.spec`
Expected: FAIL — `Cannot find module './stock-low-alert'`.

- [ ] **Step 3: Implement template**

Tạo `apps/notification/src/email/templates/stock-low-alert.tsx` (copy cấu trúc từ `verify-email.tsx`, đổi màu accent + nội dung):

```tsx
import { ReactElement } from 'react';
import {
  Body,
  Container,
  Head,
  Hr,
  Html,
  Link,
  Preview,
  Section,
  Text,
} from '@react-email/components';

const INK = '#0F172A';
const ACCENT = '#D97706';
const ACCENT_LIGHT = '#FEF3C7';
const SLATE = '#64748B';
const SURFACE = '#F8FAFC';
const BORDER = '#E2E8F0';
const WHITE = '#FFFFFF';

const SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif";

interface StockLowAlertProps {
  sku: string;
  warehouseId: string;
  available: number;
  minQuantity: number;
}

// Cảnh báo tồn kho thấp (UC-N04) — MANAGER nhận khi available < minQuantity.
export function StockLowAlertEmail({
  sku,
  warehouseId,
  available,
  minQuantity,
}: StockLowAlertProps): ReactElement {
  const percent =
    minQuantity > 0 ? Math.round((available / minQuantity) * 100) : 0;

  return (
    <Html lang="vi">
      <Head />
      <Preview>Tồn kho thấp — SKU {sku}: còn {available}/{minQuantity}</Preview>
      <Body
        style={{
          backgroundColor: SURFACE,
          fontFamily: SANS,
          margin: '0',
          padding: '32px 16px',
        }}
      >
        <Container
          style={{
            maxWidth: '480px',
            margin: '0 auto',
            backgroundColor: WHITE,
            borderRadius: '12px',
            border: `1px solid ${BORDER}`,
            overflow: 'hidden',
          }}
        >
          <Section style={{ padding: '20px 32px 16px' }}>
            <Text
              style={{
                margin: '0',
                fontSize: '16px',
                fontWeight: '700',
                color: INK,
                fontFamily: SANS,
              }}
            >
              <span style={{ color: ACCENT, marginRight: '6px' }}>●</span>
              MateStock
            </Text>
          </Section>

          <Hr style={{ borderColor: BORDER, margin: '0' }} />

          <Section style={{ padding: '28px 32px 24px' }}>
            <Text
              style={{
                color: ACCENT,
                fontSize: '11px',
                fontWeight: '600',
                letterSpacing: '1.2px',
                textTransform: 'uppercase',
                margin: '0 0 12px',
                fontFamily: SANS,
              }}
            >
              ⚠️ Tồn kho thấp
            </Text>
            <Text
              style={{
                color: INK,
                fontSize: '22px',
                fontWeight: '700',
                margin: '0 0 6px',
                fontFamily: SANS,
                letterSpacing: '-0.3px',
              }}
            >
              SKU: {sku}
            </Text>
            <Text
              style={{
                color: SLATE,
                fontSize: '14px',
                lineHeight: '1.6',
                margin: '0 0 20px',
                fontFamily: SANS,
              }}
            >
              Kho <strong style={{ color: INK }}>{warehouseId}</strong> đang có
              tồn dưới ngưỡng tối thiểu.
            </Text>

            <table
              cellPadding="0"
              cellSpacing="0"
              style={{
                width: '100%',
                borderCollapse: 'collapse',
                backgroundColor: ACCENT_LIGHT,
                borderRadius: '8px',
              }}
            >
              <tbody>
                <tr>
                  <td style={{ padding: '16px 20px' }}>
                    <Text
                      style={{
                        color: INK,
                        fontSize: '28px',
                        fontWeight: '700',
                        margin: '0',
                        fontFamily: SANS,
                      }}
                    >
                      {available} / {minQuantity}
                    </Text>
                    <Text
                      style={{
                        color: SLATE,
                        fontSize: '12px',
                        margin: '4px 0 0',
                        fontFamily: SANS,
                      }}
                    >
                      Còn {percent}% so với ngưỡng tối thiểu
                    </Text>
                  </td>
                </tr>
              </tbody>
            </table>
          </Section>

          <Hr style={{ borderColor: BORDER, margin: '0' }} />

          <Section
            style={{ padding: '16px 32px 24px', backgroundColor: SURFACE }}
          >
            <Text
              style={{
                color: '#94A3B8',
                fontSize: '11px',
                margin: '0',
                fontFamily: SANS,
              }}
            >
              © {new Date().getFullYear()} MateStock ·{' '}
              <Link
                href="mailto:support@hoaiphuong.io.vn"
                style={{ color: ACCENT, textDecoration: 'none' }}
              >
                Liên hệ hỗ trợ
              </Link>
            </Text>
          </Section>
        </Container>
      </Body>
    </Html>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- templates.spec`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/notification/src/email/templates/stock-low-alert.tsx apps/notification/src/email/templates/templates.spec.ts
git commit -m "feat(wms/notification): thêm template StockLowAlertEmail cho S4-04"
```

---

### Task 12: Template `StockNearExpiryEmail`

**Files:**
- Create: `apps/notification/src/email/templates/stock-near-expiry.tsx`
- Modify: `apps/notification/src/email/templates/templates.spec.ts`

**Interfaces:**
- Produces: `StockNearExpiryEmail(props: { sku: string; lotNumber: string; expiryDate: string }): ReactElement` — dùng bởi Task 13.

- [ ] **Step 1: Write the failing test**

Thêm vào `templates.spec.ts` (cùng file Task 11 đã sửa):

```ts
describe('StockNearExpiryEmail', () => {
  it('render không throw với props hợp lệ', () => {
    expect(() =>
      StockNearExpiryEmail({
        sku: 'SKU-1',
        lotNumber: 'LOT-1',
        expiryDate: '2026-07-20T00:00:00.000Z',
      }),
    ).not.toThrow();
  });
});
```

> Thêm `import { StockNearExpiryEmail } from './stock-near-expiry';` vào đầu file.

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- templates.spec`
Expected: FAIL — `Cannot find module './stock-near-expiry'`.

- [ ] **Step 3: Implement template**

Tạo `apps/notification/src/email/templates/stock-near-expiry.tsx`:

```tsx
import { ReactElement } from 'react';
import {
  Body,
  Container,
  Head,
  Hr,
  Html,
  Link,
  Preview,
  Section,
  Text,
} from '@react-email/components';

const INK = '#0F172A';
const ACCENT = '#DC2626';
const ACCENT_LIGHT = '#FEE2E2';
const SLATE = '#64748B';
const SURFACE = '#F8FAFC';
const BORDER = '#E2E8F0';
const WHITE = '#FFFFFF';

const SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif";
const MS_PER_DAY = 24 * 60 * 60 * 1000;

interface StockNearExpiryProps {
  sku: string;
  lotNumber: string;
  expiryDate: string; // ISO 8601
}

// Cảnh báo lô hàng sắp hết hạn (UC-N05) — MANAGER nhận theo cron quét hằng ngày.
export function StockNearExpiryEmail({
  sku,
  lotNumber,
  expiryDate,
}: StockNearExpiryProps): ReactElement {
  const expiry = new Date(expiryDate);
  const formatted = new Intl.DateTimeFormat('vi-VN', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
  }).format(expiry);
  const daysLeft = Math.ceil((expiry.getTime() - Date.now()) / MS_PER_DAY);

  return (
    <Html lang="vi">
      <Head />
      <Preview>
        Lô {lotNumber} (SKU {sku}) hết hạn {formatted}
      </Preview>
      <Body
        style={{
          backgroundColor: SURFACE,
          fontFamily: SANS,
          margin: '0',
          padding: '32px 16px',
        }}
      >
        <Container
          style={{
            maxWidth: '480px',
            margin: '0 auto',
            backgroundColor: WHITE,
            borderRadius: '12px',
            border: `1px solid ${BORDER}`,
            overflow: 'hidden',
          }}
        >
          <Section style={{ padding: '20px 32px 16px' }}>
            <Text
              style={{
                margin: '0',
                fontSize: '16px',
                fontWeight: '700',
                color: INK,
                fontFamily: SANS,
              }}
            >
              <span style={{ color: ACCENT, marginRight: '6px' }}>●</span>
              MateStock
            </Text>
          </Section>

          <Hr style={{ borderColor: BORDER, margin: '0' }} />

          <Section style={{ padding: '28px 32px 24px' }}>
            <Text
              style={{
                color: ACCENT,
                fontSize: '11px',
                fontWeight: '600',
                letterSpacing: '1.2px',
                textTransform: 'uppercase',
                margin: '0 0 12px',
                fontFamily: SANS,
              }}
            >
              ⏰ Hàng sắp hết hạn
            </Text>
            <Text
              style={{
                color: INK,
                fontSize: '22px',
                fontWeight: '700',
                margin: '0 0 6px',
                fontFamily: SANS,
                letterSpacing: '-0.3px',
              }}
            >
              SKU: {sku} — Lô {lotNumber}
            </Text>

            <table
              cellPadding="0"
              cellSpacing="0"
              style={{
                width: '100%',
                borderCollapse: 'collapse',
                backgroundColor: ACCENT_LIGHT,
                borderRadius: '8px',
                marginTop: '12px',
              }}
            >
              <tbody>
                <tr>
                  <td style={{ padding: '16px 20px' }}>
                    <Text
                      style={{
                        color: INK,
                        fontSize: '20px',
                        fontWeight: '700',
                        margin: '0',
                        fontFamily: SANS,
                      }}
                    >
                      Hết hạn: {formatted}
                    </Text>
                    <Text
                      style={{
                        color: SLATE,
                        fontSize: '12px',
                        margin: '4px 0 0',
                        fontFamily: SANS,
                      }}
                    >
                      {daysLeft >= 0
                        ? `Còn ${daysLeft} ngày`
                        : `Đã quá hạn ${Math.abs(daysLeft)} ngày`}
                    </Text>
                  </td>
                </tr>
              </tbody>
            </table>
          </Section>

          <Hr style={{ borderColor: BORDER, margin: '0' }} />

          <Section
            style={{ padding: '16px 32px 24px', backgroundColor: SURFACE }}
          >
            <Text
              style={{
                color: '#94A3B8',
                fontSize: '11px',
                margin: '0',
                fontFamily: SANS,
              }}
            >
              © {new Date().getFullYear()} MateStock ·{' '}
              <Link
                href="mailto:support@hoaiphuong.io.vn"
                style={{ color: ACCENT, textDecoration: 'none' }}
              >
                Liên hệ hỗ trợ
              </Link>
            </Text>
          </Section>
        </Container>
      </Body>
    </Html>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- templates.spec`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/notification/src/email/templates/stock-near-expiry.tsx apps/notification/src/email/templates/templates.spec.ts
git commit -m "feat(wms/notification): thêm template StockNearExpiryEmail cho S4-04"
```

---

### Task 13: `NotificationConsumer` — xử lý thật `stock.low`/`stock.near_expiry`

**Files:**
- Modify: `apps/notification/src/notification.consumer.ts`
- Modify: `apps/notification/src/notification.consumer.spec.ts`

**Interfaces:**
- Consumes: `EmailService` (đã có), `FirebaseService` (đã có, `apps/notification/src/firebase/firebase.service.ts` — `isEnabled(): boolean`, `getMessaging(): Messaging`), `ConfigService` từ `@nestjs/config`, `StockLowAlertEmail` (Task 11), `StockNearExpiryEmail` (Task 12), `StockLowPayload`/`StockNearExpiryPayload` từ `@app/events` (đã có).

- [ ] **Step 1: Write the failing test**

Sửa `apps/notification/src/notification.consumer.spec.ts` — cập nhật `make()` để có `firebase` + `config` mock, thêm test cho 2 case mới:

```ts
import { EVENTS } from '@app/events';
import { NotificationConsumer } from './notification.consumer';

describe('NotificationConsumer', () => {
  function make(opts?: { alertEmail?: string; firebaseEnabled?: boolean }) {
    const email = {
      send: jest.fn().mockResolvedValue(undefined),
      isEnabled: jest.fn().mockReturnValue(true),
    };
    const messaging = { send: jest.fn().mockResolvedValue('msg-1') };
    const firebase = {
      isEnabled: jest.fn().mockReturnValue(opts?.firebaseEnabled ?? true),
      getMessaging: jest.fn().mockReturnValue(messaging),
    };
    const config = {
      get: jest.fn().mockReturnValue(opts?.alertEmail ?? 'manager@x.com'),
    };
    const consumer = new NotificationConsumer(
      email as never,
      firebase as never,
      config as never,
    );
    return { consumer, email, firebase, messaging, config };
  }

  it('verify_requested → gửi email verify với idempotencyKey = job.id', async () => {
    const { consumer, email } = make();
    await consumer.process({
      id: 'job-1',
      name: EVENTS.CUSTOMER_VERIFY_REQUESTED,
      data: { customerId: 'c1', email: 'x@y.com', code: '123456' },
    } as never);
    expect(email.send).toHaveBeenCalledWith(
      expect.objectContaining({ to: 'x@y.com', idempotencyKey: 'job-1' }),
    );
  });

  it('job lạ → không gửi email', async () => {
    const { consumer, email } = make();
    await consumer.process({ id: 'j', name: 'unknown.event', data: {} } as never);
    expect(email.send).not.toHaveBeenCalled();
  });

  describe('stock.low', () => {
    const payload = {
      sku: 'SKU-1',
      warehouseId: 'wh-1',
      available: 2,
      minQuantity: 10,
    };

    it('cả email + firebase bật → gửi cả 2', async () => {
      const { consumer, email, firebase, messaging } = make();
      await consumer.process({ id: 'j1', name: EVENTS.STOCK_LOW, data: payload } as never);

      expect(email.send).toHaveBeenCalledWith(
        expect.objectContaining({ to: 'manager@x.com', idempotencyKey: 'j1' }),
      );
      expect(messaging.send).toHaveBeenCalledWith(
        expect.objectContaining({ topic: 'stock_alert_wh-1' }),
      );
    });

    it('email tắt (isEnabled=false) → không gửi email, vẫn gửi firebase', async () => {
      const { consumer, email, messaging } = make();
      email.isEnabled.mockReturnValue(false);

      await consumer.process({ id: 'j2', name: EVENTS.STOCK_LOW, data: payload } as never);

      expect(email.send).not.toHaveBeenCalled();
      expect(messaging.send).toHaveBeenCalled();
    });

    it('cả 2 tắt → không throw, không gửi gì', async () => {
      const { consumer, email, messaging } = make({ firebaseEnabled: false });
      email.isEnabled.mockReturnValue(false);

      await expect(
        consumer.process({ id: 'j3', name: EVENTS.STOCK_LOW, data: payload } as never),
      ).resolves.toBeUndefined();
      expect(email.send).not.toHaveBeenCalled();
      expect(messaging.send).not.toHaveBeenCalled();
    });

    it('không có WAREHOUSE_ALERT_EMAIL → không gửi email dù isEnabled=true', async () => {
      const { consumer, email } = make({ alertEmail: undefined });

      await consumer.process({ id: 'j4', name: EVENTS.STOCK_LOW, data: payload } as never);

      expect(email.send).not.toHaveBeenCalled();
    });
  });

  describe('stock.near_expiry', () => {
    const payload = {
      sku: 'SKU-1',
      lotNumber: 'LOT-1',
      expiryDate: '2026-07-20T00:00:00.000Z',
    };

    it('cả email + firebase bật → gửi cả 2, topic = stock_alert_expiry', async () => {
      const { consumer, email, messaging } = make();
      await consumer.process({
        id: 'j5',
        name: EVENTS.STOCK_NEAR_EXPIRY,
        data: payload,
      } as never);

      expect(email.send).toHaveBeenCalledWith(
        expect.objectContaining({ to: 'manager@x.com', idempotencyKey: 'j5' }),
      );
      expect(messaging.send).toHaveBeenCalledWith(
        expect.objectContaining({ topic: 'stock_alert_expiry' }),
      );
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- notification.consumer`
Expected: FAIL — constructor arity mismatch (`NotificationConsumer` hiện chỉ nhận 1 tham số).

- [ ] **Step 3: Implement**

Sửa `apps/notification/src/notification.consumer.ts`:

```ts
import { Processor, WorkerHost } from '@nestjs/bullmq';
import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  EVENTS,
  QUEUES,
  type CustomerEmailActionPayload,
  type CustomerGoogleRegisteredPayload,
  type StockLowPayload,
  type StockNearExpiryPayload,
} from '@app/events';
import { Job } from 'bullmq';
import { EmailService } from './email/email.service';
import { FirebaseService } from './firebase/firebase.service';
import { VerifyEmail } from './email/templates/verify-email';
import { ResetPasswordEmail } from './email/templates/reset-password';
import { GoogleWelcomeEmail } from './email/templates/google-welcome';
import { StockLowAlertEmail } from './email/templates/stock-low-alert';
import { StockNearExpiryEmail } from './email/templates/stock-near-expiry';

function toEmailPayload(raw: unknown): CustomerEmailActionPayload {
  return raw as CustomerEmailActionPayload;
}

/**
 * CONSUMER thông báo: verify/reset → gửi email OTP qua Resend; stock.low/
 * stock.near_expiry (S4-04) → email + FCM push cho MANAGER kho, graceful
 * degradation nếu thiếu provider. Consumer THUẦN: không phát event, không DB.
 * idempotencyKey = job.id chống gửi trùng (chỉ có ý nghĩa với Resend — BullMQ
 * job.id KHÔNG deterministic cho stock.low/stock.near_expiry vì producer không
 * truyền jobId, nên mỗi job vẫn có id riêng do BullMQ tự sinh).
 */
@Processor(QUEUES.NOTIFICATION)
export class NotificationConsumer extends WorkerHost {
  private readonly logger = new Logger(NotificationConsumer.name);

  constructor(
    private readonly email: EmailService,
    private readonly firebase: FirebaseService,
    private readonly config: ConfigService,
  ) {
    super();
  }

  async process(job: Job): Promise<void> {
    const key = job.id ?? `${job.name}:${Date.now()}`;
    switch (job.name) {
      case EVENTS.CUSTOMER_VERIFY_REQUESTED: {
        const { email, code } = toEmailPayload(job.data);
        await this.email.send({
          to: email,
          subject: 'Mã xác minh email',

          react: VerifyEmail({ code }),
          idempotencyKey: key,
        });
        break;
      }
      case EVENTS.CUSTOMER_PASSWORD_RESET_REQUESTED: {
        const { email, code } = toEmailPayload(job.data);
        await this.email.send({
          to: email,
          subject: 'Mã đặt lại mật khẩu',

          react: ResetPasswordEmail({ code }),
          idempotencyKey: key,
        });
        break;
      }
      case EVENTS.CUSTOMER_GOOGLE_REGISTERED: {
        const { email, password } = job.data as CustomerGoogleRegisteredPayload;
        await this.email.send({
          to: email,
          subject: 'Chào mừng bạn đến với MateStock — Mật khẩu tài khoản của bạn',

          react: GoogleWelcomeEmail({ password: password ?? '' }),
          idempotencyKey: key,
        });
        break;
      }
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
          this.logger.warn(
            `stock.low cho ${payload.sku} — không có provider nào bật.`,
          );
        }
        break;
      }
      case EVENTS.STOCK_NEAR_EXPIRY: {
        const payload = job.data as StockNearExpiryPayload;
        const alertEmail = this.config.get<string>('WAREHOUSE_ALERT_EMAIL');
        let sent = false;
        if (this.email.isEnabled() && alertEmail) {
          await this.email.send({
            to: alertEmail,
            subject: `⏰ Lô hàng sắp hết hạn — SKU: ${payload.sku}`,
            react: StockNearExpiryEmail(payload),
            idempotencyKey: key,
          });
          sent = true;
        }
        if (this.firebase.isEnabled()) {
          await this.firebase.getMessaging().send({
            topic: 'stock_alert_expiry',
            notification: {
              title: `Hàng sắp hết hạn — ${payload.sku}`,
              body: `Lô ${payload.lotNumber} hết hạn ${payload.expiryDate}`,
            },
            data: {
              sku: payload.sku,
              lotNumber: payload.lotNumber,
              expiryDate: payload.expiryDate,
            },
          });
          sent = true;
        }
        if (!sent) {
          this.logger.warn(
            `stock.near_expiry cho ${payload.sku} lô ${payload.lotNumber} — không có provider nào bật.`,
          );
        }
        break;
      }
      case EVENTS.PAYMENT_SUCCESS:
        // TODO: producer chưa build — tạm log để xác nhận đã nhận event. Ngoài scope S4-04.
        this.logger.log(`📨 ${job.name} → ${JSON.stringify(job.data)}`);
        break;
      default:
        this.logger.warn(`Bỏ qua job lạ trên notification-queue: ${job.name}`);
    }
  }
}
```

Sửa `apps/notification/src/notification.module.ts` — thêm `FirebaseModule` nếu chưa import (kiểm tra file thật: đã có `FirebaseModule` trong `imports` theo nội dung đọc trước đó ở phase thiết kế — nếu đúng thì KHÔNG cần sửa file này).

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- notification.consumer`
Expected: PASS, tất cả test cũ + mới.

- [ ] **Step 5: Run full notification test suite + typecheck + build**

Run: `pnpm test -- apps/notification`
Expected: PASS toàn bộ.

Run: `pnpm exec tsc --noEmit -p apps/notification/tsconfig.app.json`
Expected: no errors.

Run: `pnpm exec nest build notification`
Expected: builds successfully.

- [ ] **Step 6: Commit**

```bash
git add apps/notification/src/notification.consumer.ts apps/notification/src/notification.consumer.spec.ts
git commit -m "feat(wms/notification): xử lý stock.low/stock.near_expiry trong NotificationConsumer cho S4-04"
```

---

### Task 14: End-to-end manual verification

**Files:** none (verification only).

- [ ] **Step 1: Run full test suite + lint + build cả 2 app**

Run: `pnpm test`
Expected: PASS toàn bộ, không regressions (bao gồm mọi test từ Task 1-13).

Run: `pnpm lint`
Expected: 0 lỗi.

Run: `pnpm exec nest build wms && pnpm exec nest build notification`
Expected: cả 2 build thành công.

- [ ] **Step 2: Start cả 2 app**

Run: `pnpm start:wms` (terminal 1), `pnpm start:notification` (terminal 2).
Expected: cả 2 app boot không lỗi. Log WMS xác nhận `ScheduleModule`/cron đã đăng ký (Nest log "Cron" hoặc route mapping bình thường, không crash).

- [ ] **Step 3: Xác nhận Redis reachable**

Nếu Redis không có trong môi trường (giống các task trước trong session) — ghi rõ KHÔNG verify được BullMQ job thật, thay vào đó dựa vào test suite (Task 1-13) làm evidence.

- [ ] **Step 4: Set `minQuantity` cho 1 WarehouseItem qua API sẵn có**

`PATCH /api/wms/stock/items/:id` với body `{ "minQuantity": 10 }` (MANAGER/ADMIN token).
Expect: response có `minQuantity: 10`.

- [ ] **Step 5: Kích hoạt 1 luồng làm giảm available xuống dưới ngưỡng**

Ví dụ: `PATCH` confirm 1 `GoodsIssue` line khiến `available` của item đó < `minQuantity` đã set.
Expect (nếu Redis reachable): job `stock.low` xuất hiện trên `notification-queue`; log `apps/notification` có dòng xử lý case `STOCK_LOW` (hoặc email/FCM log nếu provider bật).

- [ ] **Step 6: Kích hoạt cron thủ công (không đợi 06:00 thật)**

Trong `apps/wms`, tạm gọi trực tiếp `NearExpiryScanService.scanNearExpiryLots()` qua 1 script/REPL nếu môi trường cho phép, HOẶC ghi nhận: cron logic đã có unit test đầy đủ (Task 9) — live verification của phần này chấp nhận dựa vào test suite nếu không tiện expose 1 endpoint thủ công (KHÔNG tạo endpoint debug mới ngoài scope plan).

- [ ] **Step 7: Stop cả 2 app**

Ctrl+C hoặc kill process ở cả 2 terminal.

Expected: ghi nhận rõ phần nào verify được sống (live), phần nào chỉ dựa vào test suite (nếu môi trường thiếu Redis/credentials) — theo đúng tinh thần các lần verification trước trong session (S4-02 Task 10, S4-03 Task 9).

---

## Self-Review Notes (đã áp dụng trong plan trên)

- **Spec coverage:** mọi quyết định trong design doc (không dedup cả 2 event, `minQuantity` optional không default, cron 06:00, `checkAndEmitStockLow` đọc lại balance) đều map vào task cụ thể (Task 1-2 data/logic lõi, Task 3-8 wiring 6 service, Task 9 cron, Task 10-13 phía notification, Task 14 verification).
- **Placeholder scan:** không còn TBD/TODO nào ngoài dòng comment `// TODO: producer chưa build` giữ nguyên cho `PAYMENT_SUCCESS` (đúng ý — ngoài scope, không phải placeholder của plan này).
- **Type consistency:** `checkAndEmitStockLow(itemId: Types.ObjectId, warehouseId: Types.ObjectId): Promise<void>` dùng nhất quán ở Task 2 (định nghĩa) và Task 3-8 (gọi) — không lệch tên/tham số. `StockLowPayload`/`StockNearExpiryPayload` dùng đúng field name đã khai trong `libs/events/src/events.ts` (không đổi). `NearExpiryScanService.scanNearExpiryLots()` — tên nhất quán giữa Task 9's implementation và spec.
