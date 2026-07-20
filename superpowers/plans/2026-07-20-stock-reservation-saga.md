# Saga Giữ Tồn Kho (Stock Reservation) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement WMS-side handling of the checkout stock-reservation saga so `STOCK_RESERVE_REQUESTED` from Ecommerce actually reserves inventory, responds with `STOCK_RESERVED`/`STOCK_RESERVE_FAILED`, and `ORDER_CANCELLED` releases the reservation — closing the oversell gap described in GitHub issue #3.

**Architecture:** New `apps/wms/src/reservation/` module with a `ReservationConsumer` (`@Processor(QUEUES.ORDER)`) and `ReservationService`. Reserve uses an atomic `findOneAndUpdate` with `$expr` per SKU inside a Mongo transaction (via existing `StockTransactionHelper`) to avoid oversell races; idempotency and audit trail ride on new `StockMovement` types `RESERVE`/`RELEASE`. Ecommerce side needs no changes — it already produces `STOCK_RESERVE_REQUESTED`/`ORDER_CANCELLED` and consumes `STOCK_RESERVED`/`STOCK_RESERVE_FAILED`.

**Tech Stack:** NestJS, `@nestjs/bullmq` (BullMQ worker), Mongoose (transactions require replica set — already required by `StockTransactionHelper` for GRN/Issue/Count), Jest.

## Global Constraints

- No cross-DB reads/transactions — this plan touches only `wms_db` (Mongoose) and event payloads already defined in `libs/events/src/events.ts`. No changes to that file.
- Services throw `AppException` from `@app/common`/`WMS_ERRORS`, never raw Nest exceptions (`.claude/rules/error-handling.md`). Consumers themselves don't throw for expected "no match" cases — they log and return (see `GoodsIssueService.createFromOrderReady` pattern) so BullMQ doesn't retry on unrecoverable business conditions.
- No `any` anywhere; every `@Transform`/callback param is typed (`.claude/rules/dto-conventions.md`).
- Collection/queue names, audit field groups, and event payload shapes are already fixed by existing code — do not rename or restructure them.
- 1 order = 1 `fulfillWarehouseId` (no split-warehouse reservation) — out of scope per design doc.
- Do not touch `GoodsIssue` cancellation logic — if a `GoodsIssue` already exists for the order, release logs a warning and stops (out of scope per design doc).

---

## File Structure

| File | Responsibility |
|---|---|
| `apps/wms/src/stock/schemas/stock-movement.schema.ts` (modify) | Add `RESERVE`, `RELEASE` to `MovementType` enum |
| `apps/wms/src/stock/stock.repository.ts` (modify) | Add `reserveIfAvailable` (atomic check-and-increment), `findMovementsByRef` (read RESERVE movements for a refId), `findMovementByRefAndType` (idempotency check) |
| `apps/wms/src/warehouse/warehouse.repository.ts` (modify) | Add `findAllActiveWarehouses` reusing existing soft-delete + `isActive` filter, sorted with a given warehouse id first |
| `apps/wms/src/reservation/reservation.constants.ts` (create) | `SYSTEM_ACTOR_ID` constant |
| `apps/wms/src/reservation/reservation.service.ts` (create) | `reserveForOrder`, `releaseForOrder` |
| `apps/wms/src/reservation/reservation.service.spec.ts` (create) | Unit tests |
| `apps/wms/src/reservation/reservation.consumer.ts` (create) | `@Processor(QUEUES.ORDER)`, dispatches `STOCK_RESERVE_REQUESTED` / `ORDER_CANCELLED` |
| `apps/wms/src/reservation/reservation.module.ts` (create) | Wires everything, imports `StockModule`, `WarehouseModule`, `GoodsIssueModule` |
| `apps/wms/src/app.module.ts` (modify) | Register `ReservationModule` |
| `apps/wms/src/common/error-codes.ts` (modify) | none needed — no new HTTP-facing error codes (this is event-driven, not a controller) |
| `docs/overview/main-flow.md` (modify) | Correct reserve description from "atomic cross-DB transaction" to the async saga |

---

## Task 1: Add RESERVE/RELEASE movement types

**Files:**
- Modify: `apps/wms/src/stock/schemas/stock-movement.schema.ts:4-13`
- Test: `apps/wms/src/stock/schemas/stock-movement.schema.spec.ts`

**Interfaces:**
- Produces: `MovementType.RESERVE`, `MovementType.RELEASE` — used by Task 3 (`ReservationService`).

- [ ] **Step 1: Read the existing schema spec to match conventions**

Run: `sed -n '1,40p' apps/wms/src/stock/schemas/stock-movement.schema.spec.ts`

- [ ] **Step 2: Write the failing test**

Add to `apps/wms/src/stock/schemas/stock-movement.schema.spec.ts` (inside the existing `describe` block, alongside other `MovementType` assertions):

```ts
  it('bao gồm RESERVE và RELEASE trong MovementType', () => {
    expect(MovementType.RESERVE).toBe('RESERVE');
    expect(MovementType.RELEASE).toBe('RELEASE');
  });
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pnpm test -- stock-movement.schema.spec.ts`
Expected: FAIL — `MovementType.RESERVE` is `undefined`.

- [ ] **Step 4: Update the enum**

In `apps/wms/src/stock/schemas/stock-movement.schema.ts`, change:

```ts
export enum MovementType {
  RECEIVE = 'RECEIVE',
  PUTAWAY = 'PUTAWAY',
  ISSUE = 'ISSUE',
  ADJUST = 'ADJUST',
  SCRAP = 'SCRAP',
  PRINT_CONSUME = 'PRINT_CONSUME',
  PRINT_OUTPUT = 'PRINT_OUTPUT',
  RETURN_IN = 'RETURN_IN',
}
```

to:

```ts
export enum MovementType {
  RECEIVE = 'RECEIVE',
  PUTAWAY = 'PUTAWAY',
  ISSUE = 'ISSUE',
  ADJUST = 'ADJUST',
  SCRAP = 'SCRAP',
  PRINT_CONSUME = 'PRINT_CONSUME',
  PRINT_OUTPUT = 'PRINT_OUTPUT',
  RETURN_IN = 'RETURN_IN',
  RESERVE = 'RESERVE',
  RELEASE = 'RELEASE',
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pnpm test -- stock-movement.schema.spec.ts`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/stock/schemas/stock-movement.schema.ts apps/wms/src/stock/schemas/stock-movement.schema.spec.ts
git commit -m "feat(wms/stock): thêm MovementType RESERVE/RELEASE cho saga giữ tồn"
```

---

## Task 2: Repository support — atomic reserve, movement lookups, active warehouses

**Files:**
- Modify: `apps/wms/src/stock/stock.repository.ts` (add 3 methods)
- Modify: `apps/wms/src/warehouse/warehouse.repository.ts` (add 1 method)
- Test: `apps/wms/src/stock/stock.repository.spec.ts`
- Test: `apps/wms/src/warehouse/warehouse.repository.spec.ts`

**Interfaces:**
- Consumes: `StockBalance` model (already injected in `StockRepository`), `StockMovement` model (already injected).
- Produces (for Task 3):
  - `StockRepository.reserveIfAvailable(itemId: Types.ObjectId, warehouseId: Types.ObjectId, quantity: number, session: ClientSession): Promise<boolean>` — `true` if reserved, `false` if insufficient available stock.
  - `StockRepository.findMovementsByRef(refType: string, refId: Types.ObjectId): Promise<StockMovementDocument[]>`
  - `StockRepository.hasMovementForRef(refType: string, refId: Types.ObjectId): Promise<boolean>`
  - `WarehouseRepository.findAllActiveWarehouseIds(): Promise<Types.ObjectId[]>` — active (`isActive: true`, not soft-deleted) warehouses, in `createdAt` order (existing sort in `findAllWarehouses`).

- [ ] **Step 1: Write the failing tests for the 3 new `StockRepository` methods**

This codebase's repository specs use plain Jest mock objects for Mongoose models (chainable `.mockReturnThis()` stubs), NOT a real database — check the existing pattern first:

Run: `sed -n '1,60p' apps/wms/src/stock/stock.repository.spec.ts`

Add `MovementType` to the existing import line (`import { StockMovement } from './schemas/stock-movement.schema';` becomes `import { MovementType, StockMovement } from './schemas/stock-movement.schema';`), then add these `describe` blocks after the existing `insertMovement` block:

```ts
describe('reserveIfAvailable', () => {
  it('gọi findOneAndUpdate với $expr đúng và trả về true khi có kết quả', async () => {
    balanceModel.exec.mockResolvedValueOnce({ reserved: 4 });
    const mockSession = {} as never;

    const result = await repo.reserveIfAvailable(
      itemId,
      warehouseId,
      4,
      mockSession,
    );

    expect(result).toBe(true);
    expect(balanceModel.findOneAndUpdate).toHaveBeenCalledWith(
      {
        itemId,
        warehouseId,
        $expr: {
          $gte: [{ $subtract: ['$onHand', '$reserved', '$expired'] }, 4],
        },
      },
      { $inc: { reserved: 4 } },
      { new: true, session: mockSession },
    );
  });

  it('trả về false khi findOneAndUpdate không tìm thấy document khớp (available không đủ)', async () => {
    balanceModel.exec.mockResolvedValueOnce(null);
    const result = await repo.reserveIfAvailable(
      itemId,
      warehouseId,
      100,
      {} as never,
    );
    expect(result).toBe(false);
  });
});

describe('hasMovementForRef', () => {
  it('trả về true khi countDocuments > 0', async () => {
    movementModel.countDocuments = jest.fn().mockReturnThis();
    movementModel.exec.mockResolvedValueOnce(1);
    const refId = new Types.ObjectId();

    const result = await repo.hasMovementForRef('reservation', refId);

    expect(result).toBe(true);
    expect(movementModel.countDocuments).toHaveBeenCalledWith({
      refType: 'reservation',
      refId,
    });
  });

  it('trả về false khi countDocuments = 0', async () => {
    movementModel.countDocuments = jest.fn().mockReturnThis();
    movementModel.exec.mockResolvedValueOnce(0);
    const result = await repo.hasMovementForRef(
      'reservation',
      new Types.ObjectId(),
    );
    expect(result).toBe(false);
  });
});

describe('findMovementsByRef', () => {
  it('gọi find với refType+refId và trả về danh sách movement', async () => {
    movementModel.find = jest.fn().mockReturnThis();
    const refId = new Types.ObjectId();
    const rows = [
      {
        itemId,
        warehouseId,
        quantity: 3,
        type: MovementType.RESERVE,
      },
    ];
    movementModel.exec.mockResolvedValueOnce(rows);

    const result = await repo.findMovementsByRef('reservation', refId);

    expect(result).toBe(rows);
    expect(movementModel.find).toHaveBeenCalledWith({
      refType: 'reservation',
      refId,
    });
  });
});
```

Note: `movementModel.countDocuments` and `movementModel.find` are not in the shared `makeModel()` factory (only `findById`/`findOne`/`findOneAndUpdate`/`create`/`select`/`lean`/`exec` are), so each test assigns them directly with `jest.fn().mockReturnThis()` before use, matching how other spec files in this repo add one-off chainable mocks not present in the base factory.

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test -- stock.repository.spec.ts`
Expected: FAIL — `repo.reserveIfAvailable is not a function`, `repo.hasMovementForRef is not a function`, `repo.findMovementsByRef is not a function`.

- [ ] **Step 3: Implement the three `StockRepository` methods**

In `apps/wms/src/stock/stock.repository.ts`, add after `upsertBalance` (around line 167):

```ts
  /**
   * Atomic check-and-reserve: tăng reserved CHỈ KHI available (onHand-reserved-expired)
   * còn đủ quantity, trong 1 query duy nhất — tránh race condition khi 2 đơn
   * checkout cùng lúc cùng sku (không tách "đọc rồi ghi").
   */
  async reserveIfAvailable(
    itemId: Types.ObjectId,
    warehouseId: Types.ObjectId,
    quantity: number,
    session: ClientSession,
  ): Promise<boolean> {
    const updated = await this.balanceModel
      .findOneAndUpdate(
        {
          itemId,
          warehouseId,
          $expr: {
            $gte: [
              { $subtract: ['$onHand', '$reserved', '$expired'] },
              quantity,
            ],
          },
        },
        { $inc: { reserved: quantity } },
        { new: true, session },
      )
      .exec();
    return updated !== null;
  }

  /** Có ít nhất 1 movement cho refType+refId chưa — dùng làm khóa idempotency. */
  async hasMovementForRef(
    refType: string,
    refId: Types.ObjectId,
  ): Promise<boolean> {
    const count = await this.movementModel
      .countDocuments({ refType, refId })
      .exec();
    return count > 0;
  }

  /** Toàn bộ movement của 1 refType+refId — dùng để đọc lại đã reserve gì lúc release. */
  findMovementsByRef(
    refType: string,
    refId: Types.ObjectId,
  ): Promise<StockMovementDocument[]> {
    return this.movementModel.find({ refType, refId }).exec();
  }
```

`ClientSession` is already imported in this file (used by other methods). No new imports needed beyond what's already there.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm test -- stock.repository.spec.ts`
Expected: PASS

- [ ] **Step 5: Write the failing test for `findAllActiveWarehouseIds`**

This spec file (`apps/wms/src/warehouse/warehouse.repository.spec.ts`) currently constructs the `Warehouse` model inline via `{ provide: getModelToken(Warehouse.name), useValue: makeModel() }` without capturing it in a variable (only `rackModel`/`shelfModel` are captured — see lines 24-37). Capture it too so the new test can control its mock:

Change:
```ts
        { provide: getModelToken(Warehouse.name), useValue: makeModel() },
```
to:
```ts
        { provide: getModelToken(Warehouse.name), useValue: warehouseModel },
```

And declare `let warehouseModel: ReturnType<typeof makeModel>;` alongside the existing `let rackModel...`/`let shelfModel...` declarations, assigning `warehouseModel = makeModel();` in `beforeEach` alongside the other two.

Then add this `describe` block:

```ts
describe('findAllActiveWarehouseIds', () => {
  it('lọc isActive=true, chưa soft-delete, sort theo createdAt asc, chỉ lấy _id', async () => {
    const ids = [new Types.ObjectId(), new Types.ObjectId()];
    warehouseModel.select = jest.fn().mockReturnThis();
    warehouseModel.lean = jest.fn().mockReturnThis();
    warehouseModel.exec.mockResolvedValueOnce([{ _id: ids[0] }, { _id: ids[1] }]);

    const result = await repo.findAllActiveWarehouseIds();

    expect(result).toEqual(ids);
    expect(warehouseModel.find).toHaveBeenCalledWith({
      deletedAt: null,
      isActive: true,
    });
    expect(warehouseModel.sort).toHaveBeenCalledWith({ createdAt: 1 });
  });
});
```

(`warehouseModel.select`/`.lean` are assigned directly since the shared `makeModel()` factory in this file doesn't include them — same reasoning as the `stock.repository.spec.ts` changes in Step 1.)

- [ ] **Step 6: Run test to verify it fails**

Run: `pnpm test -- warehouse.repository.spec.ts`
Expected: FAIL — `repo.findAllActiveWarehouseIds is not a function`.

- [ ] **Step 7: Implement `findAllActiveWarehouseIds`**

In `apps/wms/src/warehouse/warehouse.repository.ts`, add after `findAllWarehouses` (around line 43):

```ts
  /** Id của mọi kho active (isActive=true, chưa soft-delete) — dùng khi ReservationService chọn kho ứng viên. */
  async findAllActiveWarehouseIds(): Promise<Types.ObjectId[]> {
    const rows = await this.warehouseModel
      .find({ ...SOFT_DELETE_FILTER, isActive: true })
      .select('_id')
      .sort({ createdAt: 1 })
      .lean()
      .exec();
    return rows.map((r) => r._id as Types.ObjectId);
  }
```

- [ ] **Step 8: Run test to verify it passes**

Run: `pnpm test -- warehouse.repository.spec.ts`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add apps/wms/src/stock/stock.repository.ts apps/wms/src/stock/stock.repository.spec.ts apps/wms/src/warehouse/warehouse.repository.ts apps/wms/src/warehouse/warehouse.repository.spec.ts
git commit -m "feat(wms): thêm reserveIfAvailable atomic check + tra cứu movement/kho active"
```

---

## Task 3: `ReservationService` — reserve + release logic

**Files:**
- Create: `apps/wms/src/reservation/reservation.constants.ts`
- Create: `apps/wms/src/reservation/reservation.service.ts`
- Test: `apps/wms/src/reservation/reservation.service.spec.ts`

**Interfaces:**
- Consumes:
  - `StockRepository.reserveIfAvailable(itemId, warehouseId, quantity, session)` (Task 2)
  - `StockRepository.hasMovementForRef(refType, refId)` (Task 2)
  - `StockRepository.findMovementsByRef(refType, refId)` (Task 2)
  - `StockRepository.findItemBySku(sku): Promise<{_id, sku, ...} | null>` (existing)
  - `StockRepository.upsertBalance(itemId, warehouseId, onHandDelta, reservedDelta, expiredDelta, session)` (existing)
  - `StockRepository.insertMovement(data, session)` (existing)
  - `WarehouseRepository.findAllActiveWarehouseIds()` (Task 2)
  - `WarehouseRepository.findStagingShelfByWarehouse(warehouseId: string): Promise<ShelfDocument | null>` (existing — used as the required `shelfId` placeholder on RESERVE/RELEASE movements, since reservation has no physical shelf)
  - `StockTransactionHelper.withStockTransaction(fn)` (existing)
  - `GoodsIssueRepository.findByOrderId(orderId: string): Promise<GoodsIssueDocument | null>` (existing)
  - `EVENTS.STOCK_RESERVED`, `EVENTS.STOCK_RESERVE_FAILED` published on `QUEUES.ORDER` (matches Ecom's `ReserveConsumer`, which is `@Processor(QUEUES.ORDER)`).
- Produces (for Task 4 — `ReservationConsumer`):
  - `ReservationService.reserveForOrder(orderId: string, items: { sku: string; quantity: number }[], preferWarehouse?: string): Promise<void>`
  - `ReservationService.releaseForOrder(orderId: string): Promise<void>`

**Note on `shelfId` for RESERVE/RELEASE movements:** `StockMovement.shelfId` is a required field, but reservation only touches the aggregate `StockBalance` (no specific shelf). Use the warehouse's staging shelf (`WarehouseRepository.findStagingShelfByWarehouse`) as the placeholder, matching how GRN uses staging shelf for warehouse-level (not shelf-level) receiving. If no staging shelf exists for the chosen warehouse, treat that warehouse as ineligible (skip to next candidate) — this can't happen in practice since every seeded warehouse has one staging shelf, but keeps the method total.

- [ ] **Step 1: Create the SYSTEM actor constant**

Create `apps/wms/src/reservation/reservation.constants.ts`:

```ts
import { Types } from 'mongoose';

/**
 * Actor giả cho các StockMovement tự sinh từ event (không có nhân viên WMS
 * nào thao tác trực tiếp — checkout/hủy đơn khởi phát từ khách hàng bên Ecom).
 */
export const SYSTEM_ACTOR_ID = new Types.ObjectId('000000000000000000000000');
```

- [ ] **Step 2: Read GoodsIssueRepository export to confirm import path**

Run: `grep -n "export class GoodsIssueRepository" apps/wms/src/goods-issue/goods-issue.repository.ts`
Expected: confirms `GoodsIssueRepository` is exported from `apps/wms/src/goods-issue/goods-issue.repository.ts`.

- [ ] **Step 3: Write failing tests for `reserveForOrder`**

This codebase's service specs use plain Jest mocks for every collaborator (repositories, transaction helper, queue) — no real database, no NestJS testing module. Follow `apps/wms/src/goods-issue/goods-issue.service.spec.ts` exactly (already read in Task 3 setup above: `makeRepo()`, `makeStockRepo()`, `makeTxHelper()`, `makeQueue()` factories, service constructed directly via `new XService(...)`).

Create `apps/wms/src/reservation/reservation.service.spec.ts`:

```ts
import { Types } from 'mongoose';
import { EVENTS } from '@app/events';
import { ReservationService } from './reservation.service';
import { MovementType } from '../stock/schemas/stock-movement.schema';

const makeStockRepo = () => ({
  hasMovementForRef: jest.fn(),
  findMovementsByRef: jest.fn(),
  findItemBySku: jest.fn(),
  reserveIfAvailable: jest.fn(),
  upsertBalance: jest.fn(),
  insertMovement: jest.fn(),
});

const makeWarehouseRepo = () => ({
  findAllActiveWarehouseIds: jest.fn(),
  findStagingShelfByWarehouse: jest.fn(),
});

const makeGoodsIssueRepo = () => ({
  findByOrderId: jest.fn(),
});

const makeTxHelper = () => ({
  withStockTransaction: jest.fn(
    (fn: (session: unknown) => unknown) => fn({}),
  ),
});

const makeQueue = () => ({
  add: jest.fn(),
});

describe('ReservationService', () => {
  let svc: ReservationService;
  let stockRepo: ReturnType<typeof makeStockRepo>;
  let warehouseRepo: ReturnType<typeof makeWarehouseRepo>;
  let goodsIssueRepo: ReturnType<typeof makeGoodsIssueRepo>;
  let txHelper: ReturnType<typeof makeTxHelper>;
  let queue: ReturnType<typeof makeQueue>;

  const orderId = new Types.ObjectId().toString();
  const warehouseA = new Types.ObjectId();
  const warehouseB = new Types.ObjectId();
  const stagingShelfA = { _id: new Types.ObjectId() };
  const stagingShelfB = { _id: new Types.ObjectId() };
  const itemA = new Types.ObjectId();
  const itemB = new Types.ObjectId();

  beforeEach(() => {
    stockRepo = makeStockRepo();
    warehouseRepo = makeWarehouseRepo();
    goodsIssueRepo = makeGoodsIssueRepo();
    txHelper = makeTxHelper();
    queue = makeQueue();
    svc = new ReservationService(
      stockRepo as never,
      txHelper as never,
      warehouseRepo as never,
      goodsIssueRepo as never,
      queue as never,
    );
  });

  describe('reserveForOrder', () => {
    it('reserve thành công khi kho ứng viên đủ tồn cho mọi sku, phát STOCK_RESERVED', async () => {
      stockRepo.hasMovementForRef.mockResolvedValue(false);
      stockRepo.findItemBySku.mockResolvedValueOnce({ _id: itemA, sku: 'SKU-A' });
      warehouseRepo.findAllActiveWarehouseIds.mockResolvedValue([warehouseA]);
      warehouseRepo.findStagingShelfByWarehouse.mockResolvedValue(stagingShelfA);
      stockRepo.reserveIfAvailable.mockResolvedValue(true);

      await svc.reserveForOrder(orderId, [{ sku: 'SKU-A', quantity: 4 }], 'CENTRAL');

      expect(stockRepo.reserveIfAvailable).toHaveBeenCalledWith(
        itemA,
        warehouseA,
        4,
        expect.anything(),
      );
      expect(stockRepo.insertMovement).toHaveBeenCalledWith(
        expect.objectContaining({
          itemId: itemA,
          warehouseId: warehouseA,
          shelfId: stagingShelfA._id,
          type: MovementType.RESERVE,
          quantity: 4,
          refType: 'reservation',
        }),
        expect.anything(),
      );
      expect(queue.add).toHaveBeenCalledWith(
        EVENTS.STOCK_RESERVED,
        { orderId, fulfillWarehouseId: warehouseA.toString() },
        { jobId: `reservation:${orderId}` },
      );
    });

    it('kho đầu tiên thiếu 1 sku, kho thứ 2 đủ toàn bộ → chọn kho thứ 2', async () => {
      stockRepo.hasMovementForRef.mockResolvedValue(false);
      stockRepo.findItemBySku.mockImplementation((sku: string) =>
        Promise.resolve(
          sku === 'SKU-A' ? { _id: itemA, sku: 'SKU-A' } : { _id: itemB, sku: 'SKU-B' },
        ),
      );
      warehouseRepo.findAllActiveWarehouseIds.mockResolvedValue([warehouseA, warehouseB]);
      warehouseRepo.findStagingShelfByWarehouse.mockImplementation((id: string) =>
        Promise.resolve(id === warehouseA.toString() ? stagingShelfA : stagingShelfB),
      );
      // warehouseA: SKU-A đủ, SKU-B thiếu → transaction abort ở SKU-B
      // warehouseB: cả 2 đủ
      stockRepo.reserveIfAvailable.mockImplementation(
        (itemId: Types.ObjectId, warehouseId: Types.ObjectId) => {
          if (warehouseId === warehouseA && itemId === itemB) return Promise.resolve(false);
          return Promise.resolve(true);
        },
      );

      await svc.reserveForOrder(
        orderId,
        [{ sku: 'SKU-A', quantity: 2 }, { sku: 'SKU-B', quantity: 2 }],
        'CENTRAL',
      );

      expect(queue.add).toHaveBeenCalledWith(
        EVENTS.STOCK_RESERVED,
        { orderId, fulfillWarehouseId: warehouseB.toString() },
        { jobId: `reservation:${orderId}` },
      );
    });

    it('không kho nào đủ toàn bộ đơn → phát STOCK_RESERVE_FAILED với đúng failedSkus', async () => {
      stockRepo.hasMovementForRef.mockResolvedValue(false);
      stockRepo.findItemBySku.mockResolvedValue({ _id: itemA, sku: 'SKU-1' });
      warehouseRepo.findAllActiveWarehouseIds.mockResolvedValue([warehouseA]);
      warehouseRepo.findStagingShelfByWarehouse.mockResolvedValue(stagingShelfA);
      stockRepo.reserveIfAvailable.mockResolvedValue(false);

      await svc.reserveForOrder(orderId, [{ sku: 'SKU-1', quantity: 5 }], 'CENTRAL');

      expect(queue.add).toHaveBeenCalledWith(
        EVENTS.STOCK_RESERVE_FAILED,
        expect.objectContaining({ orderId, failedSkus: ['SKU-1'] }),
        { jobId: `reservation-failed:${orderId}` },
      );
    });

    it('sku không tồn tại trong WarehouseItem → góp vào failedSkus, không throw, không gọi reserveIfAvailable', async () => {
      stockRepo.hasMovementForRef.mockResolvedValue(false);
      stockRepo.findItemBySku.mockResolvedValue(null);
      warehouseRepo.findAllActiveWarehouseIds.mockResolvedValue([warehouseA]);
      warehouseRepo.findStagingShelfByWarehouse.mockResolvedValue(stagingShelfA);

      await expect(
        svc.reserveForOrder(orderId, [{ sku: 'SKU-KHONG-TON-TAI', quantity: 1 }], 'CENTRAL'),
      ).resolves.not.toThrow();

      expect(stockRepo.reserveIfAvailable).not.toHaveBeenCalled();
      expect(queue.add).toHaveBeenCalledWith(
        EVENTS.STOCK_RESERVE_FAILED,
        expect.objectContaining({ orderId, failedSkus: ['SKU-KHONG-TON-TAI'] }),
        { jobId: `reservation-failed:${orderId}` },
      );
    });

    it('đơn đã có movement reservation (retry) → bỏ qua, không gọi reserveIfAvailable', async () => {
      stockRepo.hasMovementForRef.mockResolvedValue(true);

      await svc.reserveForOrder(orderId, [{ sku: 'SKU-1', quantity: 3 }], 'CENTRAL');

      expect(stockRepo.reserveIfAvailable).not.toHaveBeenCalled();
      expect(queue.add).not.toHaveBeenCalled();
    });
  });
});
```

- [ ] **Step 4: Run test to verify it fails**

Run: `pnpm test -- reservation.service.spec.ts`
Expected: FAIL — `Cannot find module './reservation.service'`.

- [ ] **Step 5: Implement `ReservationService.reserveForOrder`**

Create `apps/wms/src/reservation/reservation.service.ts`:

```ts
import { InjectQueue } from '@nestjs/bullmq';
import { Injectable, Logger } from '@nestjs/common';
import {
  EVENTS,
  QUEUES,
  type StockReservedPayload,
  type StockReserveFailedPayload,
} from '@app/events';
import { Queue } from 'bullmq';
import { Types } from 'mongoose';
import { StockRepository } from '../stock/stock.repository';
import { StockTransactionHelper } from '../stock/helpers/with-stock-transaction.helper';
import { WarehouseRepository } from '../warehouse/warehouse.repository';
import { GoodsIssueRepository } from '../goods-issue/goods-issue.repository';
import { MovementType } from '../stock/schemas/stock-movement.schema';
import { SYSTEM_ACTOR_ID } from './reservation.constants';

interface ReserveItem {
  sku: string;
  quantity: number;
}

const REF_TYPE_RESERVE = 'reservation';
const REF_TYPE_RELEASE = 'reservation_release';

@Injectable()
export class ReservationService {
  private readonly logger = new Logger(ReservationService.name);

  constructor(
    private readonly stockRepo: StockRepository,
    private readonly stockTransactionHelper: StockTransactionHelper,
    private readonly warehouseRepo: WarehouseRepository,
    private readonly goodsIssueRepo: GoodsIssueRepository,
    @InjectQueue(QUEUES.ORDER) private readonly orderQueue: Queue,
  ) {}

  /**
   * Xử lý STOCK_RESERVE_REQUESTED. Idempotent theo orderId (kiểm tra đã có
   * movement 'reservation' chưa). Chọn 1 kho duy nhất đủ tồn cho TOÀN BỘ sku
   * trong đơn (ưu tiên preferWarehouse), atomic theo từng sku trong 1
   * transaction — nếu 1 sku không đủ ở kho đang thử, transaction abort và
   * toàn bộ reserve tạm thời trong kho đó tự rollback, chuyển sang kho khác.
   */
  async reserveForOrder(
    orderId: string,
    items: ReserveItem[],
    preferWarehouse?: string,
  ): Promise<void> {
    const alreadyReserved = await this.stockRepo.hasMovementForRef(
      REF_TYPE_RESERVE,
      new Types.ObjectId(orderId),
    );
    if (alreadyReserved) {
      this.logger.warn(
        `Đơn ${orderId} đã được reserve trước đó → bỏ qua (idempotent).`,
      );
      return;
    }

    const resolvedItems: { itemId: Types.ObjectId; sku: string; quantity: number }[] = [];
    const missingSkus: string[] = [];
    for (const item of items) {
      const warehouseItem = await this.stockRepo.findItemBySku(item.sku);
      if (!warehouseItem) {
        missingSkus.push(item.sku);
        continue;
      }
      resolvedItems.push({
        itemId: warehouseItem._id,
        sku: item.sku,
        quantity: item.quantity,
      });
    }

    // preferWarehouse không dùng để chọn kho: payload hiện gửi chuỗi tượng
    // trưng (vd 'CENTRAL') nhưng Warehouse schema không có code/slug nào để
    // đối chiếu — tham số vẫn được nhận để khớp StockReserveRequestedPayload,
    // nhưng bị bỏ qua. Thử lần lượt mọi kho active theo thứ tự createdAt asc.
    void preferWarehouse;
    const candidateIds = await this.warehouseRepo.findAllActiveWarehouseIds();

    for (const warehouseId of candidateIds) {
      const stagingShelf =
        await this.warehouseRepo.findStagingShelfByWarehouse(warehouseId.toString());
      if (!stagingShelf) continue; // kho không có staging shelf → bỏ qua ứng viên này

      const reservedHere = await this.tryReserveAllAtWarehouse(
        orderId,
        resolvedItems,
        warehouseId,
        stagingShelf._id,
      );
      if (reservedHere) {
        await this.emitReserved(orderId, warehouseId);
        return;
      }
    }

    await this.emitReserveFailed(
      orderId,
      missingSkus.length > 0
        ? `Sku không tồn tại: ${missingSkus.join(', ')}`
        : 'Không kho nào đủ tồn cho toàn bộ đơn hàng',
      missingSkus.length > 0 ? missingSkus : resolvedItems.map((i) => i.sku),
    );
  }

  private async tryReserveAllAtWarehouse(
    orderId: string,
    items: { itemId: Types.ObjectId; sku: string; quantity: number }[],
    warehouseId: Types.ObjectId,
    stagingShelfId: Types.ObjectId,
  ): Promise<boolean> {
    let allReserved = true;
    try {
      await this.stockTransactionHelper.withStockTransaction(async (session) => {
        for (const item of items) {
          const ok = await this.stockRepo.reserveIfAvailable(
            item.itemId,
            warehouseId,
            item.quantity,
            session,
          );
          if (!ok) {
            allReserved = false;
            throw new Error('INSUFFICIENT_STOCK'); // abort transaction, rollback mọi $inc trước đó
          }
          await this.stockRepo.insertMovement(
            {
              itemId: item.itemId,
              warehouseId,
              shelfId: stagingShelfId,
              lotId: null,
              type: MovementType.RESERVE,
              quantity: item.quantity,
              refType: REF_TYPE_RESERVE,
              refId: new Types.ObjectId(orderId),
              createdBy: SYSTEM_ACTOR_ID,
            },
            session,
          );
        }
      });
    } catch (err) {
      if (err instanceof Error && err.message === 'INSUFFICIENT_STOCK') {
        return false;
      }
      throw err;
    }
    return allReserved;
  }

  private async emitReserved(orderId: string, warehouseId: Types.ObjectId): Promise<void> {
    const payload: StockReservedPayload = {
      orderId,
      fulfillWarehouseId: warehouseId.toString(),
    };
    await this.orderQueue.add(EVENTS.STOCK_RESERVED, payload, {
      jobId: `reservation:${orderId}`,
    });
    this.logger.log(`stock.reserved → orderId=${orderId} warehouseId=${warehouseId.toString()}`);
  }

  private async emitReserveFailed(
    orderId: string,
    reason: string,
    failedSkus: string[],
  ): Promise<void> {
    const payload: StockReserveFailedPayload = { orderId, reason, failedSkus };
    await this.orderQueue.add(EVENTS.STOCK_RESERVE_FAILED, payload, {
      jobId: `reservation-failed:${orderId}`,
    });
    this.logger.warn(`stock.reserve_failed → orderId=${orderId} reason=${reason}`);
  }

  /**
   * Xử lý ORDER_CANCELLED — giải phóng reserved đã giữ lúc checkout.
   * Idempotent: bỏ qua nếu chưa từng reserve, hoặc đã release trước đó.
   * Bỏ qua (log warning) nếu GoodsIssue đã tồn tại cho đơn — không tự động
   * hủy GoodsIssue (ngoài phạm vi).
   */
  async releaseForOrder(orderId: string): Promise<void> {
    const orderObjectId = new Types.ObjectId(orderId);

    const alreadyReleased = await this.stockRepo.hasMovementForRef(
      REF_TYPE_RELEASE,
      orderObjectId,
    );
    if (alreadyReleased) {
      this.logger.warn(`Đơn ${orderId} đã được release trước đó → bỏ qua (idempotent).`);
      return;
    }

    const reserveMovements = await this.stockRepo.findMovementsByRef(
      REF_TYPE_RESERVE,
      orderObjectId,
    );
    if (reserveMovements.length === 0) {
      this.logger.warn(`Đơn ${orderId} chưa từng được reserve → không có gì để release.`);
      return;
    }

    const existingGoodsIssue = await this.goodsIssueRepo.findByOrderId(orderId);
    if (existingGoodsIssue) {
      this.logger.warn(
        `Đơn ${orderId} đã có GoodsIssue (${existingGoodsIssue._id.toString()}) → không tự động release, cần xử lý thủ công.`,
      );
      return;
    }

    await this.stockTransactionHelper.withStockTransaction(async (session) => {
      for (const movement of reserveMovements) {
        await this.stockRepo.upsertBalance(
          movement.itemId,
          movement.warehouseId,
          0,
          -movement.quantity,
          0,
          session,
        );
        await this.stockRepo.insertMovement(
          {
            itemId: movement.itemId,
            warehouseId: movement.warehouseId,
            shelfId: movement.shelfId,
            lotId: null,
            type: MovementType.RELEASE,
            quantity: -movement.quantity,
            refType: REF_TYPE_RELEASE,
            refId: orderObjectId,
            createdBy: SYSTEM_ACTOR_ID,
          },
          session,
        );
      }
    });

    this.logger.log(`stock.release → orderId=${orderId} (${reserveMovements.length} dòng)`);
  }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `pnpm test -- reservation.service.spec.ts`
Expected: PASS (all 5 `reserveForOrder` tests from Step 3)

- [ ] **Step 7: Add failing tests for `releaseForOrder`**

Append to `apps/wms/src/reservation/reservation.service.spec.ts`, inside the outer `describe('ReservationService', ...)` block, as a sibling to `describe('reserveForOrder', ...)`:

```ts
  describe('releaseForOrder', () => {
    const reserveMovement = {
      itemId: itemA,
      warehouseId: warehouseA,
      shelfId: stagingShelfA._id,
      quantity: 4,
      type: MovementType.RESERVE,
    };

    it('giải phóng đúng reserved cho đơn đã reserve, chưa có GoodsIssue', async () => {
      stockRepo.hasMovementForRef.mockResolvedValue(false); // chưa có RELEASE trước đó
      stockRepo.findMovementsByRef.mockResolvedValue([reserveMovement]);
      goodsIssueRepo.findByOrderId.mockResolvedValue(null);

      await svc.releaseForOrder(orderId);

      expect(stockRepo.upsertBalance).toHaveBeenCalledWith(
        itemA,
        warehouseA,
        0,
        -4,
        0,
        expect.anything(),
      );
      expect(stockRepo.insertMovement).toHaveBeenCalledWith(
        expect.objectContaining({
          itemId: itemA,
          warehouseId: warehouseA,
          type: MovementType.RELEASE,
          quantity: -4,
          refType: 'reservation_release',
        }),
        expect.anything(),
      );
    });

    it('không có movement RESERVE nào (chưa từng reserve) → bỏ qua, không gọi upsertBalance', async () => {
      stockRepo.hasMovementForRef.mockResolvedValue(false);
      stockRepo.findMovementsByRef.mockResolvedValue([]);

      await expect(svc.releaseForOrder(orderId)).resolves.not.toThrow();

      expect(stockRepo.upsertBalance).not.toHaveBeenCalled();
    });

    it('đã có RELEASE trước đó (retry) → bỏ qua, không trừ reserved lần 2', async () => {
      stockRepo.hasMovementForRef.mockResolvedValue(true);

      await svc.releaseForOrder(orderId);

      expect(stockRepo.findMovementsByRef).not.toHaveBeenCalled();
      expect(stockRepo.upsertBalance).not.toHaveBeenCalled();
    });

    it('đã có GoodsIssue cho đơn → không release, không đổi reserved', async () => {
      stockRepo.hasMovementForRef.mockResolvedValue(false);
      stockRepo.findMovementsByRef.mockResolvedValue([reserveMovement]);
      goodsIssueRepo.findByOrderId.mockResolvedValue({ _id: new Types.ObjectId() });

      await svc.releaseForOrder(orderId);

      expect(stockRepo.upsertBalance).not.toHaveBeenCalled();
    });
  });
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `pnpm test -- reservation.service.spec.ts`
Expected: PASS

- [ ] **Step 9: Full file sanity check**

Run: `pnpm test -- reservation.service.spec.ts --verbose`
Expected: all tests in the file PASS (`reserveForOrder`: 5 cases, `releaseForOrder`: 4 cases = 9 total).

- [ ] **Step 10: Commit**

```bash
git add apps/wms/src/reservation/reservation.constants.ts apps/wms/src/reservation/reservation.service.ts apps/wms/src/reservation/reservation.service.spec.ts
git commit -m "feat(wms/reservation): ReservationService — reserve/release tồn kho theo saga checkout"
```

---

## Task 4: `ReservationConsumer` + `ReservationModule`, wire into `AppModule`

**Files:**
- Create: `apps/wms/src/reservation/reservation.consumer.ts`
- Create: `apps/wms/src/reservation/reservation.module.ts`
- Modify: `apps/wms/src/app.module.ts`
- Modify: `apps/wms/src/goods-issue/goods-issue.module.ts` (export `GoodsIssueRepository` for reuse)

**Interfaces:**
- Consumes: `ReservationService.reserveForOrder`, `ReservationService.releaseForOrder` (Task 3).
- Produces: nothing further downstream — this is the top of the WMS reservation stack.

- [ ] **Step 1: Check whether `GoodsIssueModule` exports `GoodsIssueRepository`**

Run: `grep -n "exports:" apps/wms/src/goods-issue/goods-issue.module.ts`
Expected: `exports: [GoodsIssueService]` only — `GoodsIssueRepository` is not exported.

- [ ] **Step 2: Export `GoodsIssueRepository` from `GoodsIssueModule`**

In `apps/wms/src/goods-issue/goods-issue.module.ts`, change:

```ts
  exports: [GoodsIssueService],
```

to:

```ts
  exports: [GoodsIssueService, GoodsIssueRepository],
```

(`GoodsIssueRepository` is already imported and provided in this file — only the exports array changes.)

- [ ] **Step 3: Write the consumer**

Create `apps/wms/src/reservation/reservation.consumer.ts`:

```ts
import { Processor, WorkerHost } from '@nestjs/bullmq';
import { Logger } from '@nestjs/common';
import { Job } from 'bullmq';
import {
  EVENTS,
  QUEUES,
  type StockReserveRequestedPayload,
  type OrderCancelledPayload,
} from '@app/events';
import { ReservationService } from './reservation.service';

/**
 * Consumer nhận 2 nhánh của saga giữ tồn kho checkout:
 *   - STOCK_RESERVE_REQUESTED (Ecom→WMS) → giữ tồn, phản hồi STOCK_RESERVED/FAILED.
 *   - ORDER_CANCELLED (Ecom→WMS) → giải phóng tồn đã giữ (nếu có).
 * Cùng QUEUES.ORDER với OrderReadyConsumer/OrderReturnedConsumer — mỗi
 * Processor tự switch(job.name), không xung đột.
 */
@Processor(QUEUES.ORDER)
export class ReservationConsumer extends WorkerHost {
  private readonly logger = new Logger(ReservationConsumer.name);

  constructor(private readonly reservationService: ReservationService) {
    super();
  }

  async process(job: Job): Promise<void> {
    switch (job.name) {
      case EVENTS.STOCK_RESERVE_REQUESTED: {
        const data = job.data as StockReserveRequestedPayload;
        this.logger.log(`Nhận stock.reserve_requested cho đơn ${data.orderId}.`);
        await this.reservationService.reserveForOrder(
          data.orderId,
          data.items,
          data.preferWarehouse,
        );
        break;
      }
      case EVENTS.ORDER_CANCELLED: {
        const data = job.data as OrderCancelledPayload;
        this.logger.log(`Nhận order.cancelled cho đơn ${data.orderId} → giải phóng tồn.`);
        await this.reservationService.releaseForOrder(data.orderId);
        break;
      }
      default:
      // Job khác trên order-queue (order.ready_to_fulfill, order.returned, auto.cancel...)
      // thuộc consumer khác — bỏ qua không warn để tránh log nhiễu trùng lặp.
    }
  }
}
```

Note: unlike `OrderReadyConsumer`/`OrderReturnedConsumer` (which `logger.warn` on unrecognized jobs), this consumer intentionally does **not** warn on the `default` case — `QUEUES.ORDER` carries `order.ready_to_fulfill`, `order.returned`, and `auto.cancel` jobs that other consumers already handle (and already warn on their own unrecognized jobs). Warning here too would double-log every job not meant for this consumer.

- [ ] **Step 4: Write the module**

Create `apps/wms/src/reservation/reservation.module.ts`:

```ts
import { BullModule } from '@nestjs/bullmq';
import { Module } from '@nestjs/common';
import { QUEUES } from '@app/events';
import { ReservationService } from './reservation.service';
import { ReservationConsumer } from './reservation.consumer';
import { StockModule } from '../stock/stock.module';
import { WarehouseModule } from '../warehouse/warehouse.module';
import { GoodsIssueModule } from '../goods-issue/goods-issue.module';

@Module({
  imports: [
    // ORDER: consume stock.reserve_requested + order.cancelled
    BullModule.registerQueue({ name: QUEUES.ORDER }),
    StockModule, // StockRepository + StockTransactionHelper
    WarehouseModule, // findAllActiveWarehouseIds + findStagingShelfByWarehouse
    GoodsIssueModule, // GoodsIssueRepository — kiểm tra GoodsIssue tồn tại trước khi release
  ],
  providers: [ReservationService, ReservationConsumer],
  exports: [ReservationService],
})
export class ReservationModule {}
```

- [ ] **Step 5: Register `ReservationModule` in `AppModule`**

Run: `grep -n "GoodsIssueModule" apps/wms/src/app.module.ts` to find the import + module list location.

In `apps/wms/src/app.module.ts`, add the import alongside the other domain module imports:

```ts
import { GoodsIssueModule } from './goods-issue/goods-issue.module';
```
becomes
```ts
import { GoodsIssueModule } from './goods-issue/goods-issue.module';
import { ReservationModule } from './reservation/reservation.module';
```

And add `ReservationModule` to the `imports` array in the same position (near `GoodsIssueModule`, since it's part of the order-fulfillment flow):

```ts
    GoodsIssueModule,
```
becomes
```ts
    GoodsIssueModule,
    ReservationModule,
```

- [ ] **Step 6: Build to verify wiring compiles**

Run: `pnpm build wms`
Expected: build succeeds with no errors (no circular dependency between `ReservationModule` and `GoodsIssueModule` — `ReservationModule` imports `GoodsIssueModule`, and `GoodsIssueModule` does not import `ReservationModule` back).

- [ ] **Step 7: Run full WMS test suite to check nothing broke**

Run: `pnpm test -- apps/wms`
Expected: PASS — all existing WMS tests plus the new reservation tests.

- [ ] **Step 8: Commit**

```bash
git add apps/wms/src/reservation/reservation.consumer.ts apps/wms/src/reservation/reservation.module.ts apps/wms/src/app.module.ts apps/wms/src/goods-issue/goods-issue.module.ts
git commit -m "feat(wms/reservation): nối ReservationConsumer + ReservationModule vào AppModule"
```

---

## Task 5: End-to-end manual verification + docs correction

**Files:**
- Modify: `docs/overview/main-flow.md` (correct the reserve description)
- No new test files — this task is manual verification + a docs fix.

- [ ] **Step 1: Start Redis and both apps locally**

Run: `redis-server --daemonize yes` (skip if already running)
Run: `pnpm start:wms` in one terminal, `pnpm start:ecom` in another. Confirm both boot without errors (watch for `Nest application successfully started`).

- [ ] **Step 2: Manually drive a COD checkout through the saga**

Using the WMS Swagger UI or seed data, ensure at least one `WarehouseItem` has `StockBalance.onHand > 0` in an active warehouse whose staging shelf exists (seed script `apps/wms/src/seed` already creates this — confirm via `pnpm start:wms` logs or a `db.stock_balances.find()` query).

Via the Ecommerce API (Swagger at `/api/shop`), call checkout (`POST /api/shop/orders/checkout` or equivalent — check `apps/ecommerce/src/order/order.controller.ts` for the exact route) with `paymentMethod: COD` for that SKU.

- [ ] **Step 3: Verify the order reaches CONFIRMED**

Run: query the order by id via the Ecommerce API (`GET /api/shop/orders/:id`).
Expected: within a few seconds, `orderStatus` transitions from `PLACED` to `CONFIRMED`, `fulfillmentStatus` to `READY_TO_PICK`, and `fulfillWarehouseId` is populated — proving `STOCK_RESERVED` round-tripped successfully.

- [ ] **Step 4: Verify `StockBalance.reserved` increased in WMS**

Query `stock_balances` for that item/warehouse in `wms_db` (via `mongosh` or the WMS Swagger `GET /api/wms/stock/items/:id`).
Expected: `reserved` increased by the checkout quantity, `onHand` unchanged.

- [ ] **Step 5: Cancel the order and verify release**

Call the cancel endpoint (check `apps/ecommerce/src/order/order.controller.ts` for the route, e.g. `POST /api/shop/orders/:id/cancel`).
Expected: `orderStatus` becomes `CANCELLED`. Re-query `stock_balances` — `reserved` should drop back to its pre-checkout value.

- [ ] **Step 6: Verify the insufficient-stock path**

Repeat checkout with a quantity greater than any warehouse's available stock for a SKU.
Expected: order transitions to `CANCELLED` automatically (via `ReserveConsumer.handleReserveFailed`), and the cart is restored (check via `GET /api/shop/cart`).

- [ ] **Step 7: Fix the main-flow.md description**

Run: `grep -n "transaction atomic xuyên 2 DB\|atomic xuyên" /home/hoaiphuong/code/wms-ecom/docs/overview/main-flow.md`

Read the matched lines (around line 40 and line 96 per the design doc) and replace the "reserve = atomic cross-DB transaction" description with a short paragraph describing the actual saga:

```
Reserve tồn kho lúc checkout là SAGA BẤT ĐỒNG BỘ qua event (không transaction xuyên
2 DB): Ecom phát stock.reserve_requested → WMS giữ tồn (reserved += qty trong
stock_balances, atomic theo từng sku) → WMS phản hồi stock.reserved (đủ tồn) hoặc
stock.reserve_failed (thiếu tồn, Ecom tự hủy đơn). Hủy đơn sau khi đã reserve →
Ecom phát order.cancelled → WMS giải phóng reserved tương ứng. Xem
.claude/rules/architecture.md.
```

Apply this edit at both locations found by the grep above, adapting surrounding sentence structure to read naturally in context.

- [ ] **Step 8: Commit the docs fix**

```bash
cd /home/hoaiphuong/code/wms-ecom/docs
git add overview/main-flow.md
git commit -m "docs(main-flow): sửa mô tả reserve tồn kho từ transaction xuyên DB sang saga event"
cd /home/hoaiphuong/code/wms-ecom/be
```

---

## Self-Review Notes

- **Spec coverage:** All 4 saga steps (reserve requested → reserved/failed → cancel → release) map to Task 3+4. Atomic check-and-reserve (`$expr`/`$inc`) → Task 2 Step 3. Idempotency for both reserve and release → Task 3 (dedicated retry tests in both `reserveForOrder` and `releaseForOrder` describe blocks). GoodsIssue guard on release → Task 3 Step 7 ("đã có GoodsIssue" test). `main-flow.md` correction → Task 5. Out-of-scope items (GoodsIssue auto-cancel, split-warehouse, `STOCK_RELEASE_REQUESTED`) are explicitly not implemented anywhere in this plan.
- **shelfId placeholder:** resolved via staging shelf reuse (same pattern as GRN) — flagged explicitly in Task 3 since it's a deviation from a null-shelf assumption a reader might otherwise make.
- **createdBy for system-generated movements:** resolved via `SYSTEM_ACTOR_ID` constant per user decision — no schema change needed, so `StockMovement`'s required `createdBy` stays intact for every other domain that relies on it.
- **preferWarehouse gap (found during planning, resolved with user):** `StockReserveRequestedPayload.preferWarehouse` carries a hardcoded literal (`'CENTRAL'`) from `checkout.service.ts`, but `Warehouse` schema has no `code`/slug field to resolve it against — so it cannot actually select a specific warehouse. Per user decision, the parameter is accepted (to match the existing payload shape) but ignored; `reserveForOrder` tries every active warehouse in `createdAt` order instead. Both the spec doc and this plan were updated to reflect this — no task implements warehouse-code-based preference. Documented as a candidate follow-up (adding a real `code` field) outside this plan's scope.
- **Test convention correction (found during planning):** an earlier draft of Task 2/3 tests used `mongodb-memory-server`, which is not a dependency of this repo and not the pattern any existing spec file uses. All specs here were rewritten to match the actual codebase convention — plain Jest mock objects for Mongoose models/repositories (see `stock.repository.spec.ts`, `goods-issue.service.spec.ts`) — confirmed by reading those files before finalizing this plan.
- **Type consistency check:** `ReservationService.reserveForOrder(orderId: string, items: {sku, quantity}[], preferWarehouse?: string)` signature is identical between Task 3 (definition) and Task 4 (consumer call site). `StockRepository.reserveIfAvailable` return type (`boolean`) is consistent between Task 2 (definition) and Task 3 (usage, both real implementation and mock). `MovementType.RESERVE`/`RELEASE` used consistently in Task 1 (definition), Task 2 (test fixtures), and Task 3 (service + tests). Constructor parameter order in `ReservationService` (Task 3 Step 5: `stockRepo, stockTransactionHelper, warehouseRepo, goodsIssueRepo, orderQueue`) matches the order used to construct it in tests (Task 3 Step 3) and matches how `ReservationConsumer` only depends on `ReservationService` itself (Task 4), not on any of its constructor args directly.
