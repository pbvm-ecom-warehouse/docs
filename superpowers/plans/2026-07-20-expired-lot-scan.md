# Expired-Lot Cron (`ExpiredLotScanService`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a daily cron in WMS that flips truly-expired `Lot`s to `EXPIRED`, adjusts `StockBalance.expired` so `available` correctly excludes them, and emits `stock.expired` to sync Ecom — closing the gap described in [issue #7](https://github.com/pbvm-ecom-warehouse/be-wms-ecom/issues/7).

**Architecture:** New `ExpiredLotScanService` (cron, pattern copied from `NearExpiryScanService`) queries `Lot` where `status=ACTIVE AND expiryDate < now`, sums `InventoryStock` per `(lot, warehouse)` via a new `StockRepository` aggregate method, increments `StockBalance.expired` per warehouse inside a Mongo transaction, flips lot status, then emits one deterministic `stock.expired` BullMQ job per SKU with the total delta across warehouses.

**Tech Stack:** NestJS (`@nestjs/schedule` `@Cron`, `@nestjs/mongoose`, `@nestjs/bullmq`), Mongoose aggregation pipelines, BullMQ, Jest.

## Global Constraints

- Cron does **not** touch `onHand`, `InventoryStock`, or `StockMovement` — only `StockBalance.expired` (see design spec `docs/superpowers/specs/2026-07-20-expired-lot-scan-design.md` for why: `available = onHand - reserved - expired`, and `ScrapNoteService.approveScrapNote` already assumes expired-flagging happened before physical scrap).
- No ScrapNote is auto-created by this cron — physical disposal stays a manual COUNTER/RECEIVER → MANAGER flow (UC-08), unchanged.
- BullMQ job for `stock.expired` MUST use a deterministic `jobId` (`lot_expire:<lotId>:<sku>`) so retries don't double-count Ecom's `availableQty`.
- Comment in `apps/wms/src/stock/schemas/lot.schema.ts:11-12` is factually wrong (says cron subtracts `onHand`) and must be corrected to match this design.
- Follow existing Vietnamese-comment style, `@app/events` payload contract (`StockExpiredPayload` already exists, no changes needed there), and `StockRepository`/`StockTransactionHelper` patterns already used by `ScrapNoteService`.
- No `AppException`/HTTP surface involved — this is a cron with no controller, so `.claude/rules/error-handling.md` does not apply here.

---

### Task 1: `StockRepository.sumInventoryByLot` — aggregate InventoryStock per warehouse for a lot

**Files:**
- Modify: `apps/wms/src/stock/stock.repository.ts` (add method near `findInventoryByScope`, after existing lot-related methods)
- Test: `apps/wms/src/stock/stock.repository.spec.ts` (add describe block)

**Interfaces:**
- Consumes: `this.inventoryModel` (already injected in `StockRepository` constructor, `InventoryStock` model).
- Produces: `sumInventoryByLot(lotId: Types.ObjectId): Promise<{ itemId: Types.ObjectId; warehouseId: Types.ObjectId; sku: string; qty: number }[]>` — used by Task 3 (`ExpiredLotScanService`).

- [ ] **Step 1: Write the failing test**

Add to `apps/wms/src/stock/stock.repository.spec.ts`, inside the existing `describe('StockRepository', ...)` block (reuse the file's existing `itemId`, `warehouseId` constants and `makeModel` helper — read the top of the file first to match its exact `beforeEach`/module-init pattern before inserting):

```ts
describe('sumInventoryByLot', () => {
  it('gộp quantity theo warehouseId, join sku từ warehouse_items', async () => {
    const lotId = new Types.ObjectId();
    const aggregateResult = [
      { itemId, warehouseId, sku: 'SKU-1', qty: 5 },
    ];
    inventoryModel.aggregate = jest.fn().mockReturnValue({
      exec: jest.fn().mockResolvedValue(aggregateResult),
    });

    const rows = await repo.sumInventoryByLot(lotId);

    expect(rows).toEqual(aggregateResult);
    const pipeline = (inventoryModel.aggregate as jest.Mock).mock
      .calls[0][0] as Record<string, unknown>[];
    expect(pipeline[0]).toEqual({
      $match: { lotId, quantity: { $gt: 0 } },
    });
  });
});
```

The file's `inventoryModel` (from the existing `beforeEach`, built via `getModelToken(InventoryStock.name)` + `makeModel()`) doesn't need any shared setup change — the test above assigns `inventoryModel.aggregate` directly, matching how `near-expiry-scan.service.spec.ts` mocks `lotModel.aggregate`. Insert the new `describe('sumInventoryByLot', ...)` block as a sibling to the file's other `describe` blocks, inside the outer `describe('StockRepository', ...)`.

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- stock.repository.spec.ts -t "sumInventoryByLot"`
Expected: FAIL — `repo.sumInventoryByLot is not a function`

- [ ] **Step 3: Write minimal implementation**

Add to `apps/wms/src/stock/stock.repository.ts`, in the `StockRepository` class (near `findAvailableStockForPick`, since it's the other lot-aware aggregate):

```ts
export interface LotInventorySummary {
  itemId: Types.ObjectId;
  warehouseId: Types.ObjectId;
  sku: string;
  qty: number;
}
```

Add this interface near the top of the file alongside `PickSuggestion`. Then add the method to the class:

```ts
  /**
   * Tổng InventoryStock.quantity của 1 lô, group theo warehouseId — dùng bởi
   * ExpiredLotScanService để cộng dồn StockBalance.expired đúng cho từng kho
   * (1 lô có thể nằm rải rác nhiều kho/shelf).
   */
  async sumInventoryByLot(
    lotId: Types.ObjectId,
  ): Promise<LotInventorySummary[]> {
    const pipeline: PipelineStage[] = [
      { $match: { lotId, quantity: { $gt: 0 } } },
      {
        $group: {
          _id: { itemId: '$itemId', warehouseId: '$warehouseId' },
          qty: { $sum: '$quantity' },
        },
      },
      {
        $lookup: {
          from: 'warehouse_items',
          localField: '_id.itemId',
          foreignField: '_id',
          as: 'item',
        },
      },
      { $unwind: '$item' },
      {
        $project: {
          _id: 0,
          itemId: '$_id.itemId',
          warehouseId: '$_id.warehouseId',
          sku: '$item.sku',
          qty: 1,
        },
      },
    ];
    return this.inventoryModel
      .aggregate<LotInventorySummary>(pipeline)
      .exec();
  }
```

`PipelineStage` is already imported in this file — check the top of `stock.repository.ts`; if not present, add `PipelineStage` to the existing `import { ClientSession, Model, Types } from 'mongoose';` line.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- stock.repository.spec.ts -t "sumInventoryByLot"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/stock.repository.ts apps/wms/src/stock/stock.repository.spec.ts
git commit -m "feat(stock): add sumInventoryByLot aggregate for expired-lot cron"
```

---

### Task 2: Fix incorrect comment in `lot.schema.ts`

**Files:**
- Modify: `apps/wms/src/stock/schemas/lot.schema.ts:9-13`

**Interfaces:**
- Consumes: nothing (comment-only change).
- Produces: nothing (no behavior).

- [ ] **Step 1: Edit the comment**

Replace:

```ts
/**
 * Lô hàng — chỉ dùng cho WarehouseItem.isPerishable = true.
 * Hàng hết hạn: consumer chạy cron đặt status = EXPIRED, bắn stock.expired event,
 * StockBalance.expired += qty, StockBalance.onHand -= qty.
 */
```

with:

```ts
/**
 * Lô hàng — chỉ dùng cho WarehouseItem.isPerishable = true.
 * Hàng hết hạn: ExpiredLotScanService (cron) đặt status = EXPIRED, CHỈ tăng
 * StockBalance.expired (KHÔNG đụng onHand/InventoryStock — hàng vẫn nằm vật
 * lý trên kệ), rồi bắn stock.expired event. available = onHand-reserved-expired
 * giảm đúng 1 lần. Dọn hàng vật lý thật (trừ onHand) vẫn là ScrapNote thủ công
 * (UC-08) — xem ScrapNoteService.approveScrapNote (dòng có lotId trừ lại
 * expired để available không đổi lần 2).
 */
```

- [ ] **Step 2: Commit**

```bash
git add apps/wms/src/stock/schemas/lot.schema.ts
git commit -m "docs(stock): fix incorrect expired-lot comment in lot.schema.ts"
```

---

### Task 3: `ExpiredLotScanService` — cron core logic

**Files:**
- Create: `apps/wms/src/stock/expired-lot-scan.service.ts`
- Test: `apps/wms/src/stock/expired-lot-scan.service.spec.ts`

**Interfaces:**
- Consumes:
  - `StockRepository.sumInventoryByLot(lotId: Types.ObjectId): Promise<LotInventorySummary[]>` (Task 1)
  - `StockRepository.upsertBalance(itemId, warehouseId, onHandDelta, reservedDelta, expiredDelta, session?): Promise<StockBalanceDocument | null>` (existing, `apps/wms/src/stock/stock.repository.ts`)
  - `StockTransactionHelper.withStockTransaction<T>(fn: (session: ClientSession) => Promise<T>): Promise<T>` (existing, `apps/wms/src/stock/helpers/with-stock-transaction.helper.ts`)
  - `Lot` model (`@InjectModel(Lot.name)`), `LotStatus.ACTIVE` / `LotStatus.EXPIRED` (existing, `./schemas/lot.schema.ts`)
  - `EVENTS.STOCK_EXPIRED`, `QUEUES.STOCK`, `StockExpiredPayload` (existing, `@app/events`)
- Produces: `ExpiredLotScanService.scanExpiredLots(): Promise<void>` — public method invoked by `@Cron('0 7 * * *')`, also called directly in tests.

- [ ] **Step 1: Write the failing test — single lot, single warehouse**

Create `apps/wms/src/stock/expired-lot-scan.service.spec.ts`:

```ts
import { Types } from 'mongoose';
import { ExpiredLotScanService } from './expired-lot-scan.service';
import { LotStatus } from './schemas/lot.schema';

describe('ExpiredLotScanService', () => {
  let svc: ExpiredLotScanService;
  let lotModel: { find: jest.Mock; updateOne: jest.Mock };
  let stockRepo: { sumInventoryByLot: jest.Mock; upsertBalance: jest.Mock };
  let stockTransactionHelper: { withStockTransaction: jest.Mock };
  let stockQueue: { add: jest.Mock };

  const lotId = new Types.ObjectId();
  const itemId = new Types.ObjectId();
  const warehouseId = new Types.ObjectId();

  beforeEach(() => {
    lotModel = {
      find: jest.fn().mockReturnValue({ exec: jest.fn() }),
      updateOne: jest.fn().mockReturnValue({ exec: jest.fn() }),
    };
    stockRepo = {
      sumInventoryByLot: jest.fn(),
      upsertBalance: jest.fn(),
    };
    stockTransactionHelper = {
      withStockTransaction: jest
        .fn()
        .mockImplementation(async (fn: (session: unknown) => unknown) =>
          fn({}),
        ),
    };
    stockQueue = { add: jest.fn() };

    svc = new ExpiredLotScanService(
      lotModel as never,
      stockRepo as never,
      stockTransactionHelper as never,
      stockQueue as never,
    );
  });

  describe('scanExpiredLots', () => {
    it('1 lô hết hạn, tồn ở 1 kho → tăng expired 1 lần, phát 1 job stock.expired', async () => {
      lotModel.find.mockReturnValue({
        exec: jest.fn().mockResolvedValue([{ _id: lotId }]),
      });
      stockRepo.sumInventoryByLot.mockResolvedValue([
        { itemId, warehouseId, sku: 'SKU-1', qty: 5 },
      ]);

      await svc.scanExpiredLots();

      expect(stockRepo.upsertBalance).toHaveBeenCalledWith(
        itemId,
        warehouseId,
        0,
        0,
        5,
        {},
      );
      expect(lotModel.updateOne).toHaveBeenCalledWith(
        { _id: lotId },
        { status: LotStatus.EXPIRED },
        { session: {} },
      );
      expect(stockQueue.add).toHaveBeenCalledTimes(1);
      expect(stockQueue.add).toHaveBeenCalledWith(
        'stock.expired',
        { sku: 'SKU-1', delta: -5 },
        { jobId: `lot_expire:${lotId.toString()}:SKU-1` },
      );
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- expired-lot-scan.service.spec.ts`
Expected: FAIL — cannot find module `./expired-lot-scan.service`

- [ ] **Step 3: Write minimal implementation**

Create `apps/wms/src/stock/expired-lot-scan.service.ts`:

```ts
import { InjectQueue } from '@nestjs/bullmq';
import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { InjectModel } from '@nestjs/mongoose';
import { EVENTS, QUEUES, type StockExpiredPayload } from '@app/events';
import { Queue } from 'bullmq';
import { Model } from 'mongoose';
import { StockRepository } from './stock.repository';
import { StockTransactionHelper } from './helpers/with-stock-transaction.helper';
import { Lot, LotStatus } from './schemas/lot.schema';

/**
 * Cron quét hằng ngày (07:00, sau NearExpiryScanService 06:00) mọi Lot ACTIVE
 * đã qua expiryDate. CHỈ tăng StockBalance.expired (KHÔNG đụng onHand/
 * InventoryStock/StockMovement — hàng vẫn nằm vật lý trên kệ, chưa ai dọn),
 * rồi set Lot.status = EXPIRED và phát stock.expired. Dọn hàng vật lý thật
 * vẫn là ScrapNote thủ công (UC-08) — xem ScrapNoteService.approveScrapNote.
 * available = onHand-reserved-expired giảm đúng 1 lần qua bước này.
 */
@Injectable()
export class ExpiredLotScanService {
  private readonly logger = new Logger(ExpiredLotScanService.name);

  constructor(
    @InjectModel(Lot.name) private readonly lotModel: Model<Lot>,
    private readonly stockRepo: StockRepository,
    private readonly stockTransactionHelper: StockTransactionHelper,
    @InjectQueue(QUEUES.STOCK) private readonly stockQueue: Queue,
  ) {}

  @Cron('0 7 * * *')
  async scanExpiredLots(): Promise<void> {
    const now = new Date();
    const expiredLots = await this.lotModel
      .find({ status: LotStatus.ACTIVE, expiryDate: { $lt: now } })
      .exec();

    let lotsProcessed = 0;
    let eventsEmitted = 0;

    for (const lot of expiredLots) {
      const rows = await this.stockRepo.sumInventoryByLot(lot._id);

      await this.stockTransactionHelper.withStockTransaction(
        async (session) => {
          for (const row of rows) {
            await this.stockRepo.upsertBalance(
              row.itemId,
              row.warehouseId,
              0,
              0,
              row.qty,
              session,
            );
          }
          await this.lotModel
            .updateOne(
              { _id: lot._id },
              { status: LotStatus.EXPIRED },
              { session },
            )
            .exec();
        },
      );

      if (rows.length > 0) {
        const bySku = new Map<string, number>();
        for (const row of rows) {
          bySku.set(row.sku, (bySku.get(row.sku) ?? 0) + row.qty);
        }
        for (const [sku, totalQty] of bySku) {
          const payload: StockExpiredPayload = { sku, delta: -totalQty };
          const jobId = `lot_expire:${lot._id.toString()}:${sku}`;
          await this.stockQueue.add(EVENTS.STOCK_EXPIRED, payload, { jobId });
          eventsEmitted += 1;
        }
      }
      lotsProcessed += 1;
    }

    this.logger.log(
      `Quét lot hết hạn: ${lotsProcessed} lô xử lý, ${eventsEmitted} job stock.expired đã phát.`,
    );
  }
}
```

Note: `sku` is unique per `WarehouseItem` (see `.claude/rules/data-and-mongoose.md`), and a single `Lot` belongs to exactly one `itemId` (`lot.schema.ts`), so grouping by `sku` within one lot's rows is equivalent to grouping by `itemId` — the `bySku` map will always collapse to exactly one entry per lot in practice, but is written generically in case `sumInventoryByLot` rows ever span differing items (defensive, matches how `sku` is the actual cross-app sync key per `architecture.md`).

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- expired-lot-scan.service.spec.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/expired-lot-scan.service.ts apps/wms/src/stock/expired-lot-scan.service.spec.ts
git commit -m "feat(stock): add ExpiredLotScanService cron — flip expired lots, sync stock.expired"
```

---

### Task 4: Additional test cases — multi-warehouse lot, depleted lot, no expired lots

**Files:**
- Modify: `apps/wms/src/stock/expired-lot-scan.service.spec.ts` (extend Task 3's test file)

**Interfaces:**
- Consumes: same `ExpiredLotScanService` from Task 3, no new production interfaces.
- Produces: nothing new — pure test coverage.

- [ ] **Step 1: Write the failing tests**

Add these `it` blocks inside the existing `describe('scanExpiredLots', ...)` in `apps/wms/src/stock/expired-lot-scan.service.spec.ts`:

```ts
    it('1 lô hết hạn, tồn rải rác 2 kho → tăng expired 2 lần, chỉ 1 job stock.expired với delta tổng', async () => {
      const warehouseId2 = new Types.ObjectId();
      lotModel.find.mockReturnValue({
        exec: jest.fn().mockResolvedValue([{ _id: lotId }]),
      });
      stockRepo.sumInventoryByLot.mockResolvedValue([
        { itemId, warehouseId, sku: 'SKU-1', qty: 5 },
        { itemId, warehouseId: warehouseId2, sku: 'SKU-1', qty: 3 },
      ]);

      await svc.scanExpiredLots();

      expect(stockRepo.upsertBalance).toHaveBeenCalledTimes(2);
      expect(stockRepo.upsertBalance).toHaveBeenNthCalledWith(
        1,
        itemId,
        warehouseId,
        0,
        0,
        5,
        {},
      );
      expect(stockRepo.upsertBalance).toHaveBeenNthCalledWith(
        2,
        itemId,
        warehouseId2,
        0,
        0,
        3,
        {},
      );
      expect(stockQueue.add).toHaveBeenCalledTimes(1);
      expect(stockQueue.add).toHaveBeenCalledWith(
        'stock.expired',
        { sku: 'SKU-1', delta: -8 },
        { jobId: `lot_expire:${lotId.toString()}:SKU-1` },
      );
    });

    it('lô hết hạn nhưng đã hết InventoryStock (đã bán/scrap hết) → chỉ set EXPIRED, không update balance, không phát event', async () => {
      lotModel.find.mockReturnValue({
        exec: jest.fn().mockResolvedValue([{ _id: lotId }]),
      });
      stockRepo.sumInventoryByLot.mockResolvedValue([]);

      await svc.scanExpiredLots();

      expect(stockRepo.upsertBalance).not.toHaveBeenCalled();
      expect(lotModel.updateOne).toHaveBeenCalledWith(
        { _id: lotId },
        { status: LotStatus.EXPIRED },
        { session: {} },
      );
      expect(stockQueue.add).not.toHaveBeenCalled();
    });

    it('không có lô nào hết hạn → không làm gì', async () => {
      lotModel.find.mockReturnValue({
        exec: jest.fn().mockResolvedValue([]),
      });

      await svc.scanExpiredLots();

      expect(stockRepo.sumInventoryByLot).not.toHaveBeenCalled();
      expect(stockRepo.upsertBalance).not.toHaveBeenCalled();
      expect(stockQueue.add).not.toHaveBeenCalled();
    });

    it('$match theo status ACTIVE và expiryDate < now', async () => {
      lotModel.find.mockReturnValue({
        exec: jest.fn().mockResolvedValue([]),
      });

      await svc.scanExpiredLots();

      const filter = lotModel.find.mock.calls[0][0] as {
        status: string;
        expiryDate: { $lt: Date };
      };
      expect(filter.status).toBe(LotStatus.ACTIVE);
      expect(filter.expiryDate.$lt).toBeInstanceOf(Date);
    });
```

- [ ] **Step 2: Run tests to verify they fail or pass appropriately**

Run: `pnpm test -- expired-lot-scan.service.spec.ts`
Expected: All PASS (Task 3's implementation already handles these cases — this task is pure coverage confirming that). If any fail, it reveals a gap in Task 3's implementation; fix `expired-lot-scan.service.ts` to match, re-run.

- [ ] **Step 3: Run full test suite for the file**

Run: `pnpm test -- expired-lot-scan.service.spec.ts`
Expected: PASS, 6 tests total (1 from Task 3 + 5 from this task... actually 4 new + 1 existing = 5; recount: Task 3 has 1 test, this task adds 4 — total 5 tests, all PASS)

- [ ] **Step 4: Commit**

```bash
git add apps/wms/src/stock/expired-lot-scan.service.spec.ts
git commit -m "test(stock): cover multi-warehouse, depleted-lot, no-op cases for ExpiredLotScanService"
```

---

### Task 5: Wire `ExpiredLotScanService` into `StockModule`

**Files:**
- Modify: `apps/wms/src/stock/stock.module.ts`

**Interfaces:**
- Consumes: `ExpiredLotScanService` (Task 3), already-registered `Lot` schema, `StockRepository`, `StockTransactionHelper`, `QUEUES.STOCK` queue (all already present in this module per current file content).
- Produces: `ExpiredLotScanService` available for Nest DI / `@Cron` registration at app bootstrap.

- [ ] **Step 1: Edit `stock.module.ts`**

Current relevant content (verify against the file before editing — it may have shifted since this plan was written):

```ts
import { NearExpiryScanService } from './near-expiry-scan.service';
...
  providers: [
    StockRepository,
    StockService,
    StockTransactionHelper,
    NearExpiryScanService, // S4-04: cron 06:00 quét lot sắp hết hạn → stock.near_expiry
  ],
```

Change to:

```ts
import { ExpiredLotScanService } from './expired-lot-scan.service';
import { NearExpiryScanService } from './near-expiry-scan.service';
...
  providers: [
    StockRepository,
    StockService,
    StockTransactionHelper,
    NearExpiryScanService, // S4-04: cron 06:00 quét lot sắp hết hạn → stock.near_expiry
    ExpiredLotScanService, // cron 07:00 quét lot ĐÃ hết hạn → tăng expired + stock.expired (issue #7)
  ],
```

Add the `ExpiredLotScanService` import alphabetically-adjacent to `NearExpiryScanService`'s import line (matches existing import ordering in the file — check exact current ordering before inserting).

- [ ] **Step 2: Verify the app still builds**

Run: `pnpm build`
Expected: exits 0, no TypeScript errors (confirms DI wiring — `Lot`, `InventoryStock`, `StockRepository`, `StockTransactionHelper`, `QUEUES.STOCK` are all already provided/imported by this module, so no other changes should be needed).

- [ ] **Step 3: Commit**

```bash
git add apps/wms/src/stock/stock.module.ts
git commit -m "feat(stock): register ExpiredLotScanService in StockModule"
```

---

### Task 6: Full verification pass

**Files:** none (verification only)

**Interfaces:** none

- [ ] **Step 1: Run full lint**

Run: `pnpm lint`
Expected: exits 0, no errors (in particular: no `any`, no unused imports — check `LotInventorySummary` and `PipelineStage` imports are actually used).

- [ ] **Step 2: Run full test suite**

Run: `pnpm test`
Expected: all tests pass, including the new `stock.repository.spec.ts` additions (Task 1) and `expired-lot-scan.service.spec.ts` (Tasks 3-4).

- [ ] **Step 3: Run full build**

Run: `pnpm build`
Expected: exits 0.

- [ ] **Step 4: Manual sanity check (optional, requires local Mongo replica set + Redis running)**

If the user has a local dev environment running (`pnpm start:wms` with `mongod --replSet rs0` and Redis up):
1. Manually insert a test `Lot` document with `status: 'ACTIVE'` and `expiryDate` in the past, linked to an existing `WarehouseItem` with `isPerishable: true` and at least one `InventoryStock` row with `quantity > 0` and matching `lotId`.
2. Manually invoke `scanExpiredLots()` (e.g. via a temporary debug endpoint, or wait for the 07:00 cron, or temporarily change the cron expression to run sooner for the test).
3. Confirm: `Lot.status` flipped to `EXPIRED`, `StockBalance.expired` incremented by the InventoryStock quantity for that item/warehouse, `onHand` and `InventoryStock.quantity` unchanged, and a `stock.expired` job appeared on the `stock-queue` (check via Redis/BullMQ dashboard if available) or that Ecom's `ProductVariant.availableQty` for the matching SKU dropped by the expected amount.

This step is optional/manual since it requires infra not guaranteed to be running in the plan-execution environment — skip if unavailable, note it as unverified in the final report.
