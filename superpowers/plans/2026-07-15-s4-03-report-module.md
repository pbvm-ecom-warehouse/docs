# S4-03: Module Report — tồn & hiệu suất kho (read-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained, read-only `report` module in `apps/wms` exposing 3 endpoints — tồn theo SKU+kho, tồn theo lô (kèm cảnh báo hết hạn), hiệu suất nhập/xuất/điều chỉnh theo khoảng ngày — for `MANAGER`/`ADMIN`, backed by Mongoose aggregation over existing `stock_balances`/`inventory_stocks`/`stock_movements`/`lots`/`warehouse_items`/`warehouses` collections.

**Architecture:** New module `apps/wms/src/report/` with no persisted schema of its own — `ReportRepository` directly injects 4 existing Mongoose models (`WarehouseItem`, `StockBalance`, `InventoryStock`, `StockMovement`) via its own `MongooseModule.forFeature([...])` (safe to re-register the same model name+schema across modules — `@nestjs/mongoose` reuses `connection.models[name]` if already compiled) and runs aggregation pipelines; `Lot`/`Warehouse` are only touched via `$lookup` by raw collection name. `ReportService` shapes raw aggregation rows into response DTOs (computes `available`, `expiryFlag`, default date ranges) so that logic is unit-testable without Mongo. `ReportController` is the first WMS controller to adopt the `PaginatedResult`/`OffsetPaginationQuery`/`buildOffsetMeta` standard from `@app/common` (existing infrastructure, previously unused anywhere in `apps/wms`).

**Tech Stack:** NestJS (monorepo mode), `@nestjs/mongoose` (Mongoose aggregation pipelines), `class-validator`/`class-transformer` DTOs, Jest for tests.

## Global Constraints

- Schema/DTO comments in Vietnamese explaining *why*, matching existing style.
- No `AppException`/domain error codes needed — this module has no state-changing logic, only input validation (handled automatically by the global `ValidationPipe`).
- Response DTOs use `@Expose()` + `plainToInstance(..., { excludeExtraneousValues: true })`; controller never returns a raw aggregation row or Mongoose document.
- No `any` anywhere — explicit types on every function, no implicit `any` from destructuring.
- Every `@Roles(...)` endpoint must have `— [ROLE1, ROLE2]` appended to its `@ApiOperation({ summary })`. All 3 endpoints here use `@Roles(WmsRole.ADMIN, WmsRole.MANAGER)`.
- Every enum field in a DTO needs `enum: XxxEnum` in its `@ApiProperty`.
- No new collection, no new schema file — this module only reads existing collections.
- `GET /reports/stock` and `GET /reports/stock/lots` are paginated using `OffsetPaginationQuery` (query DTO base class), `PaginatedResult`, `buildOffsetMeta` — all from `@app/common`. `GET /reports/performance` is **not** paginated (fixed-size result, one row per `MovementType`).
- `warehouseId`/`sku` filters are plain optional `$match` criteria — no FK-existence validation. `warehouseId` still needs `@IsMongoId()` so a malformed id 400s via `ValidationPipe` instead of throwing an unhandled Mongoose `CastError`. `sku` filter is **exact match**, not partial search.
- If `sku` is provided but doesn't resolve to any `WarehouseItem`, the endpoint returns an empty result **without** querying the underlying report collection: `{ data: [], total: 0 }` for the two paginated endpoints, a **fully zero-filled `MovementType` array** for `GET /reports/performance` (never an empty array — FE should always see every movement type).
- Lot "sắp hết hạn" threshold: `item.nearExpiryDays ?? 7` (per-item field already on `WarehouseItem`, previously unused by any code — this module is its first consumer).
- `GET /reports/performance`: `dateFrom`/`dateTo` optional; if omitted, `dateTo` defaults to now and `dateFrom` defaults to `dateTo - 30 days`. Response is always the full `MovementType` enum (8 rows), including rows with `totalQuantity: 0, movementCount: 0` for types with no matching movements in range.
- Collection names referenced by string in `$lookup`: `'warehouse_items'` (`WarehouseItem`), `'warehouses'` (`Warehouse`), `'lots'` (`Lot`).

---

## File Structure

```
apps/wms/src/report/
  dto/
    query-stock-report.dto.ts
    query-stock-report.dto.spec.ts
    query-lot-report.dto.ts
    query-lot-report.dto.spec.ts
    query-performance-report.dto.ts
    query-performance-report.dto.spec.ts
    report.response.dto.ts
  report.repository.ts
  report.repository.spec.ts
  report.service.ts
  report.service.spec.ts
  report.controller.ts
  report.module.ts
```

Modified files:
- `apps/wms/src/app.module.ts` — register `ReportModule`.

No changes to any existing schema, repository, or module outside `app.module.ts`.

---

### Task 1: Query DTOs + Response DTOs

**Files:**
- Create: `apps/wms/src/report/dto/query-stock-report.dto.ts`
- Test: `apps/wms/src/report/dto/query-stock-report.dto.spec.ts`
- Create: `apps/wms/src/report/dto/query-lot-report.dto.ts`
- Test: `apps/wms/src/report/dto/query-lot-report.dto.spec.ts`
- Create: `apps/wms/src/report/dto/query-performance-report.dto.ts`
- Test: `apps/wms/src/report/dto/query-performance-report.dto.spec.ts`
- Create: `apps/wms/src/report/dto/report.response.dto.ts`

**Interfaces:**
- Consumes: `OffsetPaginationQuery` from `@app/common`; `LotStatus` from `../../stock/schemas/lot.schema`; `MovementType` from `../../stock/schemas/stock-movement.schema`.
- Produces: `QueryStockReportDto`, `QueryLotReportDto`, `QueryPerformanceReportDto` (request DTOs); `ExpiryFlag` type, `StockReportItemDto`, `LotReportItemDto`, `PerformanceReportItemDto` (response DTOs) — all consumed by Tasks 5-8.

- [ ] **Step 1: Write the failing test for `QueryStockReportDto`**

```ts
// apps/wms/src/report/dto/query-stock-report.dto.spec.ts
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { QueryStockReportDto } from './query-stock-report.dto';

describe('QueryStockReportDto', () => {
  it('page/limit mặc định 1/20 khi không truyền field nào', () => {
    const dto = plainToInstance(QueryStockReportDto, {});
    expect(dto.page).toBe(1);
    expect(dto.limit).toBe(20);
  });

  it('không truyền warehouseId/sku vẫn hợp lệ (cả 2 đều optional)', async () => {
    const dto = plainToInstance(QueryStockReportDto, {});
    const errors = await validate(dto);
    expect(errors).toHaveLength(0);
  });

  it('warehouseId sai định dạng ObjectId → validation error', async () => {
    const dto = plainToInstance(QueryStockReportDto, {
      warehouseId: 'khong-phai-object-id',
    });
    const errors = await validate(dto);
    expect(errors.some((e) => e.property === 'warehouseId')).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- query-stock-report.dto`
Expected: FAIL — `Cannot find module './query-stock-report.dto'`.

- [ ] **Step 3: Implement `QueryStockReportDto`**

```ts
// apps/wms/src/report/dto/query-stock-report.dto.ts
import { ApiPropertyOptional } from '@nestjs/swagger';
import { IsMongoId, IsOptional, IsString } from 'class-validator';
import { OffsetPaginationQuery } from '@app/common';

export class QueryStockReportDto extends OffsetPaginationQuery {
  @ApiPropertyOptional({ description: 'Lọc theo kho' })
  @IsOptional()
  @IsMongoId()
  warehouseId?: string;

  @ApiPropertyOptional({ description: 'Lọc theo sku (khớp chính xác)' })
  @IsOptional()
  @IsString()
  sku?: string;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- query-stock-report.dto`
Expected: PASS, 3 tests.

- [ ] **Step 5: Write the failing test for `QueryLotReportDto`**

```ts
// apps/wms/src/report/dto/query-lot-report.dto.spec.ts
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { QueryLotReportDto } from './query-lot-report.dto';

describe('QueryLotReportDto', () => {
  it('page/limit mặc định 1/20', () => {
    const dto = plainToInstance(QueryLotReportDto, {});
    expect(dto.page).toBe(1);
    expect(dto.limit).toBe(20);
  });

  it('status không thuộc LotStatus → validation error', async () => {
    const dto = plainToInstance(QueryLotReportDto, { status: 'KHONG_HOP_LE' });
    const errors = await validate(dto);
    expect(errors.some((e) => e.property === 'status')).toBe(true);
  });

  it('status hợp lệ (ACTIVE/EXPIRED) → không lỗi', async () => {
    const dto = plainToInstance(QueryLotReportDto, { status: 'ACTIVE' });
    const errors = await validate(dto);
    expect(errors).toHaveLength(0);
  });
});
```

- [ ] **Step 6: Run test to verify it fails**

Run: `pnpm test -- query-lot-report.dto`
Expected: FAIL — `Cannot find module './query-lot-report.dto'`.

- [ ] **Step 7: Implement `QueryLotReportDto`**

```ts
// apps/wms/src/report/dto/query-lot-report.dto.ts
import { ApiPropertyOptional } from '@nestjs/swagger';
import { IsEnum, IsMongoId, IsOptional, IsString } from 'class-validator';
import { OffsetPaginationQuery } from '@app/common';
import { LotStatus } from '../../stock/schemas/lot.schema';

export class QueryLotReportDto extends OffsetPaginationQuery {
  @ApiPropertyOptional({ description: 'Lọc theo kho' })
  @IsOptional()
  @IsMongoId()
  warehouseId?: string;

  @ApiPropertyOptional({ description: 'Lọc theo sku (khớp chính xác)' })
  @IsOptional()
  @IsString()
  sku?: string;

  @ApiPropertyOptional({ enum: LotStatus })
  @IsOptional()
  @IsEnum(LotStatus)
  status?: LotStatus;
}
```

- [ ] **Step 8: Run test to verify it passes**

Run: `pnpm test -- query-lot-report.dto`
Expected: PASS, 3 tests.

- [ ] **Step 9: Write the failing test for `QueryPerformanceReportDto`**

```ts
// apps/wms/src/report/dto/query-performance-report.dto.spec.ts
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { QueryPerformanceReportDto } from './query-performance-report.dto';

describe('QueryPerformanceReportDto', () => {
  it('không truyền field nào vẫn hợp lệ (tất cả đều optional)', async () => {
    const dto = plainToInstance(QueryPerformanceReportDto, {});
    const errors = await validate(dto);
    expect(errors).toHaveLength(0);
  });

  it('dateFrom sai định dạng ISO date → validation error', async () => {
    const dto = plainToInstance(QueryPerformanceReportDto, {
      dateFrom: 'khong-phai-ngay',
    });
    const errors = await validate(dto);
    expect(errors.some((e) => e.property === 'dateFrom')).toBe(true);
  });

  it('dateFrom/dateTo hợp lệ (ISO string) → không lỗi', async () => {
    const dto = plainToInstance(QueryPerformanceReportDto, {
      dateFrom: '2026-06-01T00:00:00.000Z',
      dateTo: '2026-07-01T00:00:00.000Z',
    });
    const errors = await validate(dto);
    expect(errors).toHaveLength(0);
  });
});
```

- [ ] **Step 10: Run test to verify it fails**

Run: `pnpm test -- query-performance-report.dto`
Expected: FAIL — `Cannot find module './query-performance-report.dto'`.

- [ ] **Step 11: Implement `QueryPerformanceReportDto`**

```ts
// apps/wms/src/report/dto/query-performance-report.dto.ts
import { ApiPropertyOptional } from '@nestjs/swagger';
import { IsDateString, IsMongoId, IsOptional, IsString } from 'class-validator';

export class QueryPerformanceReportDto {
  @ApiPropertyOptional({
    description: 'ISO date bắt đầu, mặc định 30 ngày trước nếu bỏ trống',
  })
  @IsOptional()
  @IsDateString()
  dateFrom?: string;

  @ApiPropertyOptional({
    description: 'ISO date kết thúc, mặc định thời điểm hiện tại nếu bỏ trống',
  })
  @IsOptional()
  @IsDateString()
  dateTo?: string;

  @ApiPropertyOptional({ description: 'Lọc theo kho' })
  @IsOptional()
  @IsMongoId()
  warehouseId?: string;

  @ApiPropertyOptional({ description: 'Lọc theo sku (khớp chính xác)' })
  @IsOptional()
  @IsString()
  sku?: string;
}
```

- [ ] **Step 12: Run test to verify it passes**

Run: `pnpm test -- query-performance-report.dto`
Expected: PASS, 3 tests.

- [ ] **Step 13: Write the response DTOs (no dedicated spec — pure declarative shape, matches convention: response DTOs in this codebase don't get spec files)**

```ts
// apps/wms/src/report/dto/report.response.dto.ts
import { ApiProperty } from '@nestjs/swagger';
import { Expose } from 'class-transformer';
import { LotStatus } from '../../stock/schemas/lot.schema';
import { MovementType } from '../../stock/schemas/stock-movement.schema';

export type ExpiryFlag = 'ok' | 'expiringSoon' | 'expired';

export class StockReportItemDto {
  @Expose()
  @ApiProperty()
  sku!: string;

  @Expose()
  @ApiProperty()
  itemName!: string;

  @Expose()
  @ApiProperty()
  warehouseId!: string;

  @Expose()
  @ApiProperty()
  warehouseName!: string;

  @Expose()
  @ApiProperty()
  onHand!: number;

  @Expose()
  @ApiProperty()
  reserved!: number;

  @Expose()
  @ApiProperty()
  expired!: number;

  @Expose()
  @ApiProperty()
  available!: number;
}

export class LotReportItemDto {
  @Expose()
  @ApiProperty()
  sku!: string;

  @Expose()
  @ApiProperty()
  itemName!: string;

  @Expose()
  @ApiProperty()
  lotNumber!: string;

  @Expose()
  @ApiProperty()
  expiryDate!: Date;

  @Expose()
  @ApiProperty()
  warehouseId!: string;

  @Expose()
  @ApiProperty()
  warehouseName!: string;

  @Expose()
  @ApiProperty()
  quantity!: number;

  @Expose()
  @ApiProperty({ enum: LotStatus })
  status!: LotStatus;

  @Expose()
  @ApiProperty({ enum: ['ok', 'expiringSoon', 'expired'] })
  expiryFlag!: ExpiryFlag;
}

export class PerformanceReportItemDto {
  @Expose()
  @ApiProperty({ enum: MovementType })
  type!: MovementType;

  @Expose()
  @ApiProperty()
  totalQuantity!: number;

  @Expose()
  @ApiProperty()
  movementCount!: number;
}
```

- [ ] **Step 14: Run typecheck to verify everything compiles**

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json`
Expected: no errors.

- [ ] **Step 15: Commit**

```bash
git add apps/wms/src/report/dto
git commit -m "feat(wms/report): thêm query + response DTO cho S4-03"
```

---

### Task 2: `ReportRepository` — sku resolver + stock report aggregation

**Files:**
- Create: `apps/wms/src/report/report.repository.ts`
- Test: `apps/wms/src/report/report.repository.spec.ts`

**Interfaces:**
- Consumes: `WarehouseItem` from `../stock/schemas/warehouse-item.schema`; `StockBalance` from `../stock/schemas/stock-balance.schema`; `InventoryStock` from `../stock/schemas/inventory-stock.schema`; `StockMovement` from `../stock/schemas/stock-movement.schema`.
- Produces: `ItemFilter` type (`{ warehouseId?: Types.ObjectId; itemId?: Types.ObjectId }`), `ItemSkuLookup` type (`{ _id: Types.ObjectId; nearExpiryDays?: number }`), `RawStockReportRow` type, `ReportRepository.findItemIdBySku(sku: string): Promise<ItemSkuLookup | null>`, `ReportRepository.aggregateStockReport(filter: ItemFilter, page: number, limit: number): Promise<{ data: RawStockReportRow[]; total: number }>` — all consumed by Task 5 (`ReportService.getStockReport`) and reused as the base pattern for Tasks 3-4.

- [ ] **Step 1: Write the failing test**

```ts
// apps/wms/src/report/report.repository.spec.ts
import { Types } from 'mongoose';
import { ReportRepository } from './report.repository';

describe('ReportRepository', () => {
  let repo: ReportRepository;
  let warehouseItemModel: { findOne: jest.Mock };
  let stockBalanceModel: { aggregate: jest.Mock };
  let inventoryStockModel: { aggregate: jest.Mock };
  let stockMovementModel: { aggregate: jest.Mock };

  const itemId = new Types.ObjectId();
  const warehouseId = new Types.ObjectId();

  beforeEach(() => {
    warehouseItemModel = { findOne: jest.fn() };
    stockBalanceModel = { aggregate: jest.fn() };
    inventoryStockModel = { aggregate: jest.fn() };
    stockMovementModel = { aggregate: jest.fn() };
    repo = new ReportRepository(
      warehouseItemModel as never,
      stockBalanceModel as never,
      inventoryStockModel as never,
      stockMovementModel as never,
    );
  });

  describe('findItemIdBySku', () => {
    it('trả về _id + nearExpiryDays khi tìm thấy sku', async () => {
      warehouseItemModel.findOne.mockReturnValue({
        select: jest.fn().mockReturnThis(),
        lean: jest.fn().mockReturnThis(),
        exec: jest.fn().mockResolvedValue({ _id: itemId, nearExpiryDays: 3 }),
      });

      const result = await repo.findItemIdBySku('SKU-1');

      expect(warehouseItemModel.findOne).toHaveBeenCalledWith({ sku: 'SKU-1' });
      expect(result).toEqual({ _id: itemId, nearExpiryDays: 3 });
    });

    it('trả về null khi không tìm thấy', async () => {
      warehouseItemModel.findOne.mockReturnValue({
        select: jest.fn().mockReturnThis(),
        lean: jest.fn().mockReturnThis(),
        exec: jest.fn().mockResolvedValue(null),
      });

      const result = await repo.findItemIdBySku('SKU-X');

      expect(result).toBeNull();
    });
  });

  describe('aggregateStockReport', () => {
    it('dựng đúng $match theo warehouseId+itemId, $skip/$limit theo trang, đếm total', async () => {
      const rows = [
        {
          itemId,
          warehouseId,
          onHand: 10,
          reserved: 2,
          expired: 1,
          item: { sku: 'SKU-1', name: 'Item 1' },
          warehouse: { name: 'Kho A' },
        },
      ];
      stockBalanceModel.aggregate
        .mockReturnValueOnce({ exec: jest.fn().mockResolvedValue(rows) })
        .mockReturnValueOnce({ exec: jest.fn().mockResolvedValue([{ total: 1 }]) });

      const result = await repo.aggregateStockReport({ warehouseId, itemId }, 1, 20);

      expect(result).toEqual({ data: rows, total: 1 });
      const dataPipeline = stockBalanceModel.aggregate.mock.calls[0][0] as Record<
        string,
        unknown
      >[];
      expect(dataPipeline[0]).toEqual({ $match: { warehouseId, itemId } });
      expect(dataPipeline).toContainEqual({ $skip: 0 });
      expect(dataPipeline).toContainEqual({ $limit: 20 });
      const countPipeline = stockBalanceModel.aggregate.mock.calls[1][0] as Record<
        string,
        unknown
      >[];
      expect(countPipeline).toContainEqual({ $count: 'total' });
    });

    it('total = 0 khi $count trả mảng rỗng, $skip tính đúng theo trang 2', async () => {
      stockBalanceModel.aggregate
        .mockReturnValueOnce({ exec: jest.fn().mockResolvedValue([]) })
        .mockReturnValueOnce({ exec: jest.fn().mockResolvedValue([]) });

      const result = await repo.aggregateStockReport({}, 2, 20);

      expect(result).toEqual({ data: [], total: 0 });
      const dataPipeline = stockBalanceModel.aggregate.mock.calls[0][0] as Record<
        string,
        unknown
      >[];
      expect(dataPipeline[0]).toEqual({ $match: {} });
      expect(dataPipeline).toContainEqual({ $skip: 20 });
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- report.repository`
Expected: FAIL — `Cannot find module './report.repository'`.

- [ ] **Step 3: Implement `ReportRepository`**

```ts
// apps/wms/src/report/report.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, PipelineStage, Types } from 'mongoose';
import { WarehouseItem } from '../stock/schemas/warehouse-item.schema';
import { StockBalance } from '../stock/schemas/stock-balance.schema';
import { InventoryStock } from '../stock/schemas/inventory-stock.schema';
import { StockMovement } from '../stock/schemas/stock-movement.schema';

export interface ItemFilter {
  warehouseId?: Types.ObjectId;
  itemId?: Types.ObjectId;
}

export interface ItemSkuLookup {
  _id: Types.ObjectId;
  nearExpiryDays?: number;
}

export interface RawStockReportRow {
  itemId: Types.ObjectId;
  warehouseId: Types.ObjectId;
  onHand: number;
  reserved: number;
  expired: number;
  item: { sku: string; name: string };
  warehouse: { name: string };
}

@Injectable()
export class ReportRepository {
  constructor(
    @InjectModel(WarehouseItem.name)
    private readonly warehouseItemModel: Model<WarehouseItem>,
    @InjectModel(StockBalance.name)
    private readonly stockBalanceModel: Model<StockBalance>,
    @InjectModel(InventoryStock.name)
    private readonly inventoryStockModel: Model<InventoryStock>,
    @InjectModel(StockMovement.name)
    private readonly stockMovementModel: Model<StockMovement>,
  ) {}

  /** Resolve sku → itemId (+ nearExpiryDays cho báo cáo lô) — dùng chung cho filter sku ở cả 3 báo cáo. */
  findItemIdBySku(sku: string): Promise<ItemSkuLookup | null> {
    return this.warehouseItemModel
      .findOne({ sku })
      .select('_id nearExpiryDays')
      .lean<ItemSkuLookup>()
      .exec();
  }

  async aggregateStockReport(
    filter: ItemFilter,
    page: number,
    limit: number,
  ): Promise<{ data: RawStockReportRow[]; total: number }> {
    const match: Record<string, unknown> = {};
    if (filter.warehouseId) match.warehouseId = filter.warehouseId;
    if (filter.itemId) match.itemId = filter.itemId;

    const basePipeline: PipelineStage[] = [
      { $match: match },
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
        $lookup: {
          from: 'warehouses',
          localField: 'warehouseId',
          foreignField: '_id',
          as: 'warehouse',
        },
      },
      { $unwind: '$warehouse' },
      { $sort: { 'item.sku': 1 } },
    ];

    const [data, totalResult] = await Promise.all([
      this.stockBalanceModel
        .aggregate<RawStockReportRow>([
          ...basePipeline,
          { $skip: (page - 1) * limit },
          { $limit: limit },
        ])
        .exec(),
      this.stockBalanceModel
        .aggregate<{ total: number }>([...basePipeline, { $count: 'total' }])
        .exec(),
    ]);

    return { data, total: totalResult[0]?.total ?? 0 };
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- report.repository`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/report/report.repository.ts apps/wms/src/report/report.repository.spec.ts
git commit -m "feat(wms/report): thêm ReportRepository (sku resolver + stock report) cho S4-03"
```

---

### Task 3: `ReportRepository` — lot report aggregation

**Files:**
- Modify: `apps/wms/src/report/report.repository.ts`
- Modify: `apps/wms/src/report/report.repository.spec.ts`

**Interfaces:**
- Consumes: `LotStatus` from `../stock/schemas/lot.schema`; `ItemFilter` (Task 2).
- Produces: `LotItemFilter` type (`ItemFilter & { status?: LotStatus }`), `RawLotReportRow` type, `ReportRepository.aggregateLotReport(filter: LotItemFilter, page: number, limit: number): Promise<{ data: RawLotReportRow[]; total: number }>` — consumed by Task 6 (`ReportService.getLotReport`).

- [ ] **Step 1: Add the failing test — new `describe('aggregateLotReport', ...)` block**

Add to `apps/wms/src/report/report.repository.spec.ts`, add `import { LotStatus } from '../stock/schemas/lot.schema';` at the top, and add this block inside the existing top-level `describe('ReportRepository', ...)`, after the `aggregateStockReport` block:

```ts
  describe('aggregateLotReport', () => {
    it('lọc lotId != null, group theo lotId+warehouseId, lookup lot/item/warehouse', async () => {
      const lotId = new Types.ObjectId();
      const rows = [
        {
          _id: { lotId, warehouseId },
          itemId,
          quantity: 5,
          lot: {
            lotNumber: 'LOT-1',
            expiryDate: new Date('2026-08-01'),
            status: LotStatus.ACTIVE,
          },
          item: { sku: 'SKU-1', name: 'Item 1', nearExpiryDays: 3 },
          warehouse: { name: 'Kho A' },
        },
      ];
      inventoryStockModel.aggregate
        .mockReturnValueOnce({ exec: jest.fn().mockResolvedValue(rows) })
        .mockReturnValueOnce({ exec: jest.fn().mockResolvedValue([{ total: 1 }]) });

      const result = await repo.aggregateLotReport({ warehouseId, itemId }, 1, 20);

      expect(result).toEqual({ data: rows, total: 1 });
      const dataPipeline = inventoryStockModel.aggregate.mock.calls[0][0] as Record<
        string,
        unknown
      >[];
      expect(dataPipeline[0]).toEqual({
        $match: { lotId: { $ne: null }, warehouseId, itemId },
      });
      expect(dataPipeline).toContainEqual({ $skip: 0 });
      expect(dataPipeline).toContainEqual({ $limit: 20 });
    });

    it('có status filter → thêm $match lot.status sau bước lookup', async () => {
      inventoryStockModel.aggregate
        .mockReturnValueOnce({ exec: jest.fn().mockResolvedValue([]) })
        .mockReturnValueOnce({ exec: jest.fn().mockResolvedValue([]) });

      await repo.aggregateLotReport({ status: LotStatus.EXPIRED }, 1, 20);

      const dataPipeline = inventoryStockModel.aggregate.mock.calls[0][0] as Record<
        string,
        unknown
      >[];
      expect(dataPipeline).toContainEqual({
        $match: { 'lot.status': LotStatus.EXPIRED },
      });
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- report.repository`
Expected: FAIL — `repo.aggregateLotReport is not a function`.

- [ ] **Step 3: Implement `aggregateLotReport`**

In `apps/wms/src/report/report.repository.ts`, add `import { LotStatus } from '../stock/schemas/lot.schema';` to the imports, add these two exported interfaces after `RawStockReportRow`:

```ts
export interface LotItemFilter extends ItemFilter {
  status?: LotStatus;
}

export interface RawLotReportRow {
  _id: { lotId: Types.ObjectId; warehouseId: Types.ObjectId };
  itemId: Types.ObjectId;
  quantity: number;
  lot: { lotNumber: string; expiryDate: Date; status: LotStatus };
  item: { sku: string; name: string; nearExpiryDays?: number };
  warehouse: { name: string };
}
```

Add this method to the `ReportRepository` class, after `aggregateStockReport`:

```ts
  async aggregateLotReport(
    filter: LotItemFilter,
    page: number,
    limit: number,
  ): Promise<{ data: RawLotReportRow[]; total: number }> {
    const match: Record<string, unknown> = { lotId: { $ne: null } };
    if (filter.warehouseId) match.warehouseId = filter.warehouseId;
    if (filter.itemId) match.itemId = filter.itemId;

    const basePipeline: PipelineStage[] = [
      { $match: match },
      {
        $group: {
          _id: { lotId: '$lotId', warehouseId: '$warehouseId' },
          itemId: { $first: '$itemId' },
          quantity: { $sum: '$quantity' },
        },
      },
      {
        $lookup: {
          from: 'lots',
          localField: '_id.lotId',
          foreignField: '_id',
          as: 'lot',
        },
      },
      { $unwind: '$lot' },
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
        $lookup: {
          from: 'warehouses',
          localField: '_id.warehouseId',
          foreignField: '_id',
          as: 'warehouse',
        },
      },
      { $unwind: '$warehouse' },
    ];
    if (filter.status) {
      basePipeline.push({ $match: { 'lot.status': filter.status } });
    }
    basePipeline.push({ $sort: { 'lot.expiryDate': 1 } });

    const [data, totalResult] = await Promise.all([
      this.inventoryStockModel
        .aggregate<RawLotReportRow>([
          ...basePipeline,
          { $skip: (page - 1) * limit },
          { $limit: limit },
        ])
        .exec(),
      this.inventoryStockModel
        .aggregate<{ total: number }>([...basePipeline, { $count: 'total' }])
        .exec(),
    ]);

    return { data, total: totalResult[0]?.total ?? 0 };
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- report.repository`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/report/report.repository.ts apps/wms/src/report/report.repository.spec.ts
git commit -m "feat(wms/report): thêm aggregateLotReport cho S4-03"
```

---

### Task 4: `ReportRepository` — performance report aggregation

**Files:**
- Modify: `apps/wms/src/report/report.repository.ts`
- Modify: `apps/wms/src/report/report.repository.spec.ts`

**Interfaces:**
- Consumes: `MovementType` from `../stock/schemas/stock-movement.schema`; `ItemFilter` (Task 2).
- Produces: `PerformanceFilter` type (`ItemFilter & { dateFrom: Date; dateTo: Date }`), `RawPerformanceRow` type, `ReportRepository.aggregatePerformanceReport(filter: PerformanceFilter): Promise<RawPerformanceRow[]>` — consumed by Task 7 (`ReportService.getPerformanceReport`).

- [ ] **Step 1: Add the failing test**

Add to `apps/wms/src/report/report.repository.spec.ts`, add `import { MovementType } from '../stock/schemas/stock-movement.schema';` at the top, and add this block after `aggregateLotReport`:

```ts
  describe('aggregatePerformanceReport', () => {
    it('$match theo createdAt range + filter, $group theo type', async () => {
      const dateFrom = new Date('2026-06-01');
      const dateTo = new Date('2026-07-01');
      const rows = [
        { _id: MovementType.RECEIVE, totalQuantity: 100, movementCount: 4 },
      ];
      stockMovementModel.aggregate.mockReturnValue({
        exec: jest.fn().mockResolvedValue(rows),
      });

      const result = await repo.aggregatePerformanceReport({
        dateFrom,
        dateTo,
        warehouseId,
        itemId,
      });

      expect(result).toEqual(rows);
      const pipeline = stockMovementModel.aggregate.mock.calls[0][0] as Record<
        string,
        unknown
      >[];
      expect(pipeline[0]).toEqual({
        $match: {
          createdAt: { $gte: dateFrom, $lte: dateTo },
          warehouseId,
          itemId,
        },
      });
      expect(pipeline[1]).toEqual({
        $group: {
          _id: '$type',
          totalQuantity: { $sum: '$quantity' },
          movementCount: { $sum: 1 },
        },
      });
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- report.repository`
Expected: FAIL — `repo.aggregatePerformanceReport is not a function`.

- [ ] **Step 3: Implement `aggregatePerformanceReport`**

In `apps/wms/src/report/report.repository.ts`, add these two exported interfaces after `RawLotReportRow`:

```ts
export interface PerformanceFilter extends ItemFilter {
  dateFrom: Date;
  dateTo: Date;
}

export interface RawPerformanceRow {
  _id: string;
  totalQuantity: number;
  movementCount: number;
}
```

Add this method to the `ReportRepository` class, after `aggregateLotReport`:

```ts
  aggregatePerformanceReport(
    filter: PerformanceFilter,
  ): Promise<RawPerformanceRow[]> {
    const match: Record<string, unknown> = {
      createdAt: { $gte: filter.dateFrom, $lte: filter.dateTo },
    };
    if (filter.warehouseId) match.warehouseId = filter.warehouseId;
    if (filter.itemId) match.itemId = filter.itemId;

    return this.stockMovementModel
      .aggregate<RawPerformanceRow>([
        { $match: match },
        {
          $group: {
            _id: '$type',
            totalQuantity: { $sum: '$quantity' },
            movementCount: { $sum: 1 },
          },
        },
      ])
      .exec();
  }
```

`_id` is typed `string` here (not `MovementType`) because Mongoose's aggregate typings don't narrow `$group._id` — `ReportService` (Task 7) will compare it against `MovementType` enum values, which are themselves strings.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- report.repository`
Expected: PASS, 7 tests.

- [ ] **Step 5: Run typecheck**

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/report/report.repository.ts apps/wms/src/report/report.repository.spec.ts
git commit -m "feat(wms/report): thêm aggregatePerformanceReport cho S4-03"
```

---

### Task 5: `ReportService` — stock report

**Files:**
- Create: `apps/wms/src/report/report.service.ts`
- Test: `apps/wms/src/report/report.service.spec.ts`

**Interfaces:**
- Consumes: `ReportRepository`, `ItemFilter`, `RawStockReportRow` (Task 2); `QueryStockReportDto` (Task 1); `StockReportItemDto` (Task 1).
- Produces: `ReportService.getStockReport(query: QueryStockReportDto): Promise<{ data: StockReportItemDto[]; total: number }>` — consumed by Task 8 (`ReportController`).

- [ ] **Step 1: Write the failing test**

```ts
// apps/wms/src/report/report.service.spec.ts
import { Types } from 'mongoose';
import { ReportService } from './report.service';

describe('ReportService', () => {
  let svc: ReportService;
  let repo: {
    findItemIdBySku: jest.Mock;
    aggregateStockReport: jest.Mock;
    aggregateLotReport: jest.Mock;
    aggregatePerformanceReport: jest.Mock;
  };

  const itemId = new Types.ObjectId();
  const warehouseId = new Types.ObjectId();

  beforeEach(() => {
    repo = {
      findItemIdBySku: jest.fn(),
      aggregateStockReport: jest.fn(),
      aggregateLotReport: jest.fn(),
      aggregatePerformanceReport: jest.fn(),
    };
    svc = new ReportService(repo as never);
  });

  describe('getStockReport', () => {
    it('tính available = onHand - reserved - expired', async () => {
      repo.aggregateStockReport.mockResolvedValue({
        data: [
          {
            itemId,
            warehouseId,
            onHand: 10,
            reserved: 3,
            expired: 1,
            item: { sku: 'SKU-1', name: 'Item 1' },
            warehouse: { name: 'Kho A' },
          },
        ],
        total: 1,
      });

      const result = await svc.getStockReport({ page: 1, limit: 20 });

      expect(result.data[0]).toEqual({
        sku: 'SKU-1',
        itemName: 'Item 1',
        warehouseId: warehouseId.toString(),
        warehouseName: 'Kho A',
        onHand: 10,
        reserved: 3,
        expired: 1,
        available: 6,
      });
      expect(repo.aggregateStockReport).toHaveBeenCalledWith({}, 1, 20);
    });

    it('sku không khớp WarehouseItem nào → trả rỗng, không gọi aggregateStockReport', async () => {
      repo.findItemIdBySku.mockResolvedValue(null);

      const result = await svc.getStockReport({ sku: 'SKU-X', page: 1, limit: 20 });

      expect(result).toEqual({ data: [], total: 0 });
      expect(repo.aggregateStockReport).not.toHaveBeenCalled();
    });

    it('sku khớp → resolve itemId rồi truyền vào filter', async () => {
      repo.findItemIdBySku.mockResolvedValue({ _id: itemId });
      repo.aggregateStockReport.mockResolvedValue({ data: [], total: 0 });

      await svc.getStockReport({ sku: 'SKU-1', page: 1, limit: 20 });

      expect(repo.aggregateStockReport).toHaveBeenCalledWith({ itemId }, 1, 20);
    });

    it('warehouseId truyền vào filter dạng ObjectId', async () => {
      repo.aggregateStockReport.mockResolvedValue({ data: [], total: 0 });

      await svc.getStockReport({
        warehouseId: warehouseId.toString(),
        page: 1,
        limit: 20,
      });

      expect(repo.aggregateStockReport).toHaveBeenCalledWith(
        { warehouseId: expect.any(Types.ObjectId) },
        1,
        20,
      );
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- report.service`
Expected: FAIL — `Cannot find module './report.service'`.

- [ ] **Step 3: Implement `ReportService.getStockReport`**

```ts
// apps/wms/src/report/report.service.ts
import { Injectable } from '@nestjs/common';
import { Types } from 'mongoose';
import { ReportRepository, ItemFilter } from './report.repository';
import { QueryStockReportDto } from './dto/query-stock-report.dto';
import { StockReportItemDto } from './dto/report.response.dto';

@Injectable()
export class ReportService {
  constructor(private readonly repo: ReportRepository) {}

  async getStockReport(
    query: QueryStockReportDto,
  ): Promise<{ data: StockReportItemDto[]; total: number }> {
    const filter: ItemFilter = {};
    if (query.warehouseId) {
      filter.warehouseId = new Types.ObjectId(query.warehouseId);
    }
    if (query.sku) {
      const item = await this.repo.findItemIdBySku(query.sku);
      if (!item) return { data: [], total: 0 };
      filter.itemId = item._id;
    }

    const { data, total } = await this.repo.aggregateStockReport(
      filter,
      query.page,
      query.limit,
    );

    return {
      data: data.map((row) => ({
        sku: row.item.sku,
        itemName: row.item.name,
        warehouseId: row.warehouseId.toString(),
        warehouseName: row.warehouse.name,
        onHand: row.onHand,
        reserved: row.reserved,
        expired: row.expired,
        available: row.onHand - row.reserved - row.expired,
      })),
      total,
    };
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- report.service`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/report/report.service.ts apps/wms/src/report/report.service.spec.ts
git commit -m "feat(wms/report): thêm ReportService.getStockReport cho S4-03"
```

---

### Task 6: `ReportService` — lot report

**Files:**
- Modify: `apps/wms/src/report/report.service.ts`
- Modify: `apps/wms/src/report/report.service.spec.ts`

**Interfaces:**
- Consumes: `LotItemFilter`, `RawLotReportRow` (Task 3); `QueryLotReportDto` (Task 1); `LotReportItemDto`, `ExpiryFlag` (Task 1); `LotStatus` from `../stock/schemas/lot.schema`.
- Produces: `ReportService.getLotReport(query: QueryLotReportDto): Promise<{ data: LotReportItemDto[]; total: number }>` — consumed by Task 8 (`ReportController`).

- [ ] **Step 1: Add the failing test**

Add to `apps/wms/src/report/report.service.spec.ts`, add `import { LotStatus } from '../stock/schemas/lot.schema';` at the top, and add this block after the `getStockReport` block:

```ts
  describe('getLotReport', () => {
    const now = new Date('2026-07-15T00:00:00.000Z');

    beforeEach(() => {
      jest.useFakeTimers().setSystemTime(now);
    });

    afterEach(() => {
      jest.useRealTimers();
    });

    it('status EXPIRED → expiryFlag "expired" bất kể expiryDate', async () => {
      repo.aggregateLotReport.mockResolvedValue({
        data: [
          {
            _id: { lotId: new Types.ObjectId(), warehouseId },
            itemId,
            quantity: 5,
            lot: {
              lotNumber: 'LOT-1',
              expiryDate: new Date('2027-01-01'),
              status: LotStatus.EXPIRED,
            },
            item: { sku: 'SKU-1', name: 'Item 1' },
            warehouse: { name: 'Kho A' },
          },
        ],
        total: 1,
      });

      const result = await svc.getLotReport({ page: 1, limit: 20 });

      expect(result.data[0].expiryFlag).toBe('expired');
    });

    it('expiryDate đã qua nhưng status vẫn ACTIVE (cron chưa chạy) → "expired"', async () => {
      repo.aggregateLotReport.mockResolvedValue({
        data: [
          {
            _id: { lotId: new Types.ObjectId(), warehouseId },
            itemId,
            quantity: 5,
            lot: {
              lotNumber: 'LOT-1',
              expiryDate: new Date('2026-07-01'),
              status: LotStatus.ACTIVE,
            },
            item: { sku: 'SKU-1', name: 'Item 1' },
            warehouse: { name: 'Kho A' },
          },
        ],
        total: 1,
      });

      const result = await svc.getLotReport({ page: 1, limit: 20 });

      expect(result.data[0].expiryFlag).toBe('expired');
    });

    it('expiryDate trong ngưỡng nearExpiryDays riêng của item → "expiringSoon"', async () => {
      repo.aggregateLotReport.mockResolvedValue({
        data: [
          {
            _id: { lotId: new Types.ObjectId(), warehouseId },
            itemId,
            quantity: 5,
            lot: {
              lotNumber: 'LOT-1',
              expiryDate: new Date('2026-07-17T00:00:00.000Z'), // +2 ngày
              status: LotStatus.ACTIVE,
            },
            item: { sku: 'SKU-1', name: 'Item 1', nearExpiryDays: 3 },
            warehouse: { name: 'Kho A' },
          },
        ],
        total: 1,
      });

      const result = await svc.getLotReport({ page: 1, limit: 20 });

      expect(result.data[0].expiryFlag).toBe('expiringSoon');
    });

    it('item không set nearExpiryDays → fallback 7 ngày', async () => {
      repo.aggregateLotReport.mockResolvedValue({
        data: [
          {
            _id: { lotId: new Types.ObjectId(), warehouseId },
            itemId,
            quantity: 5,
            lot: {
              lotNumber: 'LOT-1',
              expiryDate: new Date('2026-07-20T00:00:00.000Z'), // +5 ngày, trong 7 ngày mặc định
              status: LotStatus.ACTIVE,
            },
            item: { sku: 'SKU-1', name: 'Item 1' },
            warehouse: { name: 'Kho A' },
          },
        ],
        total: 1,
      });

      const result = await svc.getLotReport({ page: 1, limit: 20 });

      expect(result.data[0].expiryFlag).toBe('expiringSoon');
    });

    it('expiryDate ngoài ngưỡng → "ok"', async () => {
      repo.aggregateLotReport.mockResolvedValue({
        data: [
          {
            _id: { lotId: new Types.ObjectId(), warehouseId },
            itemId,
            quantity: 5,
            lot: {
              lotNumber: 'LOT-1',
              expiryDate: new Date('2026-09-01T00:00:00.000Z'),
              status: LotStatus.ACTIVE,
            },
            item: { sku: 'SKU-1', name: 'Item 1' },
            warehouse: { name: 'Kho A' },
          },
        ],
        total: 1,
      });

      const result = await svc.getLotReport({ page: 1, limit: 20 });

      expect(result.data[0].expiryFlag).toBe('ok');
    });

    it('sku không khớp → trả rỗng, không gọi aggregateLotReport', async () => {
      repo.findItemIdBySku.mockResolvedValue(null);

      const result = await svc.getLotReport({ sku: 'SKU-X', page: 1, limit: 20 });

      expect(result).toEqual({ data: [], total: 0 });
      expect(repo.aggregateLotReport).not.toHaveBeenCalled();
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- report.service`
Expected: FAIL — `svc.getLotReport is not a function`.

- [ ] **Step 3: Implement `ReportService.getLotReport`**

In `apps/wms/src/report/report.service.ts`, replace the top-of-file imports with:

```ts
import { Injectable } from '@nestjs/common';
import { Types } from 'mongoose';
import { LotStatus } from '../stock/schemas/lot.schema';
import { ItemFilter, LotItemFilter, ReportRepository } from './report.repository';
import { QueryStockReportDto } from './dto/query-stock-report.dto';
import { QueryLotReportDto } from './dto/query-lot-report.dto';
import {
  ExpiryFlag,
  LotReportItemDto,
  StockReportItemDto,
} from './dto/report.response.dto';

const DEFAULT_NEAR_EXPIRY_DAYS = 7;
const MS_PER_DAY = 24 * 60 * 60 * 1000;
```

Add this method to the `ReportService` class, after `getStockReport`:

```ts
  async getLotReport(
    query: QueryLotReportDto,
  ): Promise<{ data: LotReportItemDto[]; total: number }> {
    const filter: LotItemFilter = {};
    if (query.warehouseId) {
      filter.warehouseId = new Types.ObjectId(query.warehouseId);
    }
    if (query.status) filter.status = query.status;
    if (query.sku) {
      const item = await this.repo.findItemIdBySku(query.sku);
      if (!item) return { data: [], total: 0 };
      filter.itemId = item._id;
    }

    const { data, total } = await this.repo.aggregateLotReport(
      filter,
      query.page,
      query.limit,
    );

    const now = new Date();
    return {
      data: data.map((row) => {
        const nearExpiryDays = row.item.nearExpiryDays ?? DEFAULT_NEAR_EXPIRY_DAYS;
        const warningThreshold = new Date(now.getTime() + nearExpiryDays * MS_PER_DAY);
        let expiryFlag: ExpiryFlag;
        if (row.lot.status === LotStatus.EXPIRED || row.lot.expiryDate < now) {
          expiryFlag = 'expired';
        } else if (row.lot.expiryDate <= warningThreshold) {
          expiryFlag = 'expiringSoon';
        } else {
          expiryFlag = 'ok';
        }
        return {
          sku: row.item.sku,
          itemName: row.item.name,
          lotNumber: row.lot.lotNumber,
          expiryDate: row.lot.expiryDate,
          warehouseId: row._id.warehouseId.toString(),
          warehouseName: row.warehouse.name,
          quantity: row.quantity,
          status: row.lot.status,
          expiryFlag,
        };
      }),
      total,
    };
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- report.service`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/report/report.service.ts apps/wms/src/report/report.service.spec.ts
git commit -m "feat(wms/report): thêm ReportService.getLotReport cho S4-03"
```

---

### Task 7: `ReportService` — performance report

**Files:**
- Modify: `apps/wms/src/report/report.service.ts`
- Modify: `apps/wms/src/report/report.service.spec.ts`

**Interfaces:**
- Consumes: `PerformanceFilter`, `RawPerformanceRow` (Task 4); `QueryPerformanceReportDto` (Task 1); `PerformanceReportItemDto` (Task 1); `MovementType` from `../stock/schemas/stock-movement.schema`.
- Produces: `ReportService.getPerformanceReport(query: QueryPerformanceReportDto): Promise<PerformanceReportItemDto[]>` — consumed by Task 8 (`ReportController`).

- [ ] **Step 1: Add the failing test**

Add to `apps/wms/src/report/report.service.spec.ts`, add `import { MovementType } from '../stock/schemas/stock-movement.schema';` at the top, and add this block after `getLotReport`:

```ts
  describe('getPerformanceReport', () => {
    it('mặc định dateFrom = dateTo - 30 ngày khi không truyền', async () => {
      repo.aggregatePerformanceReport.mockResolvedValue([]);

      await svc.getPerformanceReport({});

      const calledWith = repo.aggregatePerformanceReport.mock.calls[0][0] as {
        dateFrom: Date;
        dateTo: Date;
      };
      const diffDays =
        (calledWith.dateTo.getTime() - calledWith.dateFrom.getTime()) /
        (24 * 60 * 60 * 1000);
      expect(diffDays).toBeCloseTo(30, 5);
    });

    it('trả đủ mọi MovementType, loại không có dữ liệu → totalQuantity=0, movementCount=0', async () => {
      repo.aggregatePerformanceReport.mockResolvedValue([
        { _id: MovementType.RECEIVE, totalQuantity: 50, movementCount: 2 },
      ]);

      const result = await svc.getPerformanceReport({});

      expect(result).toHaveLength(Object.values(MovementType).length);
      expect(result.find((r) => r.type === MovementType.RECEIVE)).toEqual({
        type: MovementType.RECEIVE,
        totalQuantity: 50,
        movementCount: 2,
      });
      expect(result.find((r) => r.type === MovementType.ISSUE)).toEqual({
        type: MovementType.ISSUE,
        totalQuantity: 0,
        movementCount: 0,
      });
    });

    it('sku không khớp WarehouseItem nào → trả đủ MovementType với số 0, không gọi aggregatePerformanceReport', async () => {
      repo.findItemIdBySku.mockResolvedValue(null);

      const result = await svc.getPerformanceReport({ sku: 'SKU-X' });

      expect(result).toHaveLength(Object.values(MovementType).length);
      expect(
        result.every((r) => r.totalQuantity === 0 && r.movementCount === 0),
      ).toBe(true);
      expect(repo.aggregatePerformanceReport).not.toHaveBeenCalled();
    });

    it('dateFrom/dateTo truyền vào được parse đúng và forward xuống repository', async () => {
      repo.aggregatePerformanceReport.mockResolvedValue([]);

      await svc.getPerformanceReport({
        dateFrom: '2026-06-01T00:00:00.000Z',
        dateTo: '2026-07-01T00:00:00.000Z',
      });

      expect(repo.aggregatePerformanceReport).toHaveBeenCalledWith({
        dateFrom: new Date('2026-06-01T00:00:00.000Z'),
        dateTo: new Date('2026-07-01T00:00:00.000Z'),
      });
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- report.service`
Expected: FAIL — `svc.getPerformanceReport is not a function`.

- [ ] **Step 3: Implement `ReportService.getPerformanceReport`**

In `apps/wms/src/report/report.service.ts`, replace the top-of-file imports and constants with:

```ts
import { Injectable } from '@nestjs/common';
import { Types } from 'mongoose';
import { LotStatus } from '../stock/schemas/lot.schema';
import { MovementType } from '../stock/schemas/stock-movement.schema';
import {
  ItemFilter,
  LotItemFilter,
  PerformanceFilter,
  ReportRepository,
} from './report.repository';
import { QueryStockReportDto } from './dto/query-stock-report.dto';
import { QueryLotReportDto } from './dto/query-lot-report.dto';
import { QueryPerformanceReportDto } from './dto/query-performance-report.dto';
import {
  ExpiryFlag,
  LotReportItemDto,
  PerformanceReportItemDto,
  StockReportItemDto,
} from './dto/report.response.dto';

const DEFAULT_NEAR_EXPIRY_DAYS = 7;
const MS_PER_DAY = 24 * 60 * 60 * 1000;
const DEFAULT_PERFORMANCE_RANGE_DAYS = 30;
```

Add this method to the `ReportService` class, after `getLotReport`:

```ts
  async getPerformanceReport(
    query: QueryPerformanceReportDto,
  ): Promise<PerformanceReportItemDto[]> {
    const dateTo = query.dateTo ? new Date(query.dateTo) : new Date();
    const dateFrom = query.dateFrom
      ? new Date(query.dateFrom)
      : new Date(dateTo.getTime() - DEFAULT_PERFORMANCE_RANGE_DAYS * MS_PER_DAY);

    const filter: PerformanceFilter = { dateFrom, dateTo };
    if (query.warehouseId) {
      filter.warehouseId = new Types.ObjectId(query.warehouseId);
    }

    const zeroFilled = (): PerformanceReportItemDto[] =>
      Object.values(MovementType).map((type) => ({
        type,
        totalQuantity: 0,
        movementCount: 0,
      }));

    if (query.sku) {
      const item = await this.repo.findItemIdBySku(query.sku);
      if (!item) return zeroFilled();
      filter.itemId = item._id;
    }

    const rows = await this.repo.aggregatePerformanceReport(filter);
    const rowByType = new Map(rows.map((r) => [r._id, r]));
    return Object.values(MovementType).map((type) => {
      const row = rowByType.get(type);
      return {
        type,
        totalQuantity: row?.totalQuantity ?? 0,
        movementCount: row?.movementCount ?? 0,
      };
    });
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm test -- report.service`
Expected: PASS, 14 tests.

- [ ] **Step 5: Run full test suite + typecheck for regressions**

Run: `pnpm test -- report`
Expected: PASS, all report tests (DTOs + repository + service).

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/report/report.service.ts apps/wms/src/report/report.service.spec.ts
git commit -m "feat(wms/report): thêm ReportService.getPerformanceReport cho S4-03"
```

---

### Task 8: `ReportController` + `ReportModule` + `AppModule` registration

**Files:**
- Create: `apps/wms/src/report/report.controller.ts`
- Create: `apps/wms/src/report/report.module.ts`
- Modify: `apps/wms/src/app.module.ts`

**Interfaces:**
- Consumes: `ReportService` (Tasks 5-7); `PaginatedResult`, `buildOffsetMeta` from `@app/common`; `JwtAuthGuard`, `Roles`, `RolesGuard`, `WmsRole` from `@app/auth`; all 3 query DTOs and all 3 response DTOs (Task 1).
- Produces: `ReportController` (routes `GET /reports/stock`, `GET /reports/stock/lots`, `GET /reports/performance`), `ReportModule`.

- [ ] **Step 1: Write the controller**

```ts
// apps/wms/src/report/report.controller.ts
import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import { JwtAuthGuard, Roles, RolesGuard, WmsRole } from '@app/auth';
import { buildOffsetMeta, PaginatedResult } from '@app/common';
import { plainToInstance } from 'class-transformer';
import { ReportService } from './report.service';
import { QueryStockReportDto } from './dto/query-stock-report.dto';
import { QueryLotReportDto } from './dto/query-lot-report.dto';
import { QueryPerformanceReportDto } from './dto/query-performance-report.dto';
import {
  LotReportItemDto,
  PerformanceReportItemDto,
  StockReportItemDto,
} from './dto/report.response.dto';

const TO_OPTS = { excludeExtraneousValues: true } as const;

@ApiTags('reports')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard, RolesGuard)
@Controller('reports')
export class ReportController {
  constructor(private readonly svc: ReportService) {}

  @Get('stock')
  @Roles(WmsRole.ADMIN, WmsRole.MANAGER)
  @ApiOperation({
    summary: 'Báo cáo tồn kho theo SKU + kho — [ADMIN, MANAGER]',
  })
  @ApiOkResponse({ type: [StockReportItemDto] })
  async getStockReport(
    @Query() query: QueryStockReportDto,
  ): Promise<PaginatedResult<StockReportItemDto>> {
    const { data, total } = await this.svc.getStockReport(query);
    const items = plainToInstance(StockReportItemDto, data, TO_OPTS);
    return new PaginatedResult(
      items,
      buildOffsetMeta(items.length, query.page, query.limit, total),
    );
  }

  @Get('stock/lots')
  @Roles(WmsRole.ADMIN, WmsRole.MANAGER)
  @ApiOperation({
    summary:
      'Báo cáo tồn theo lô — kèm cảnh báo sắp/đã hết hạn — [ADMIN, MANAGER]',
  })
  @ApiOkResponse({ type: [LotReportItemDto] })
  async getLotReport(
    @Query() query: QueryLotReportDto,
  ): Promise<PaginatedResult<LotReportItemDto>> {
    const { data, total } = await this.svc.getLotReport(query);
    const items = plainToInstance(LotReportItemDto, data, TO_OPTS);
    return new PaginatedResult(
      items,
      buildOffsetMeta(items.length, query.page, query.limit, total),
    );
  }

  @Get('performance')
  @Roles(WmsRole.ADMIN, WmsRole.MANAGER)
  @ApiOperation({
    summary:
      'Báo cáo hiệu suất nhập/xuất/điều chỉnh theo khoảng ngày — [ADMIN, MANAGER]',
  })
  @ApiOkResponse({ type: [PerformanceReportItemDto] })
  async getPerformanceReport(
    @Query() query: QueryPerformanceReportDto,
  ): Promise<PerformanceReportItemDto[]> {
    const data = await this.svc.getPerformanceReport(query);
    return plainToInstance(PerformanceReportItemDto, data, TO_OPTS);
  }
}
```

- [ ] **Step 2: Write the module**

```ts
// apps/wms/src/report/report.module.ts
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import {
  WarehouseItem,
  WarehouseItemSchema,
} from '../stock/schemas/warehouse-item.schema';
import {
  StockBalance,
  StockBalanceSchema,
} from '../stock/schemas/stock-balance.schema';
import {
  InventoryStock,
  InventoryStockSchema,
} from '../stock/schemas/inventory-stock.schema';
import {
  StockMovement,
  StockMovementSchema,
} from '../stock/schemas/stock-movement.schema';
import { ReportRepository } from './report.repository';
import { ReportService } from './report.service';
import { ReportController } from './report.controller';

@Module({
  imports: [
    // Đăng ký lại 4 model đã tồn tại trong StockModule — an toàn vì
    // @nestjs/mongoose tái dùng connection.models[name] nếu đã compile,
    // không đọc chéo DB (vẫn cùng 1 connection wms_db). Không cần Lot/Warehouse
    // ở đây vì 2 collection đó chỉ được $lookup bằng tên thô trong pipeline.
    MongooseModule.forFeature([
      { name: WarehouseItem.name, schema: WarehouseItemSchema },
      { name: StockBalance.name, schema: StockBalanceSchema },
      { name: InventoryStock.name, schema: InventoryStockSchema },
      { name: StockMovement.name, schema: StockMovementSchema },
    ]),
  ],
  providers: [ReportRepository, ReportService],
  controllers: [ReportController],
})
export class ReportModule {}
```

- [ ] **Step 3: Register `ReportModule` in `AppModule`**

In `apps/wms/src/app.module.ts`, add the import after the `GoodsReturnModule` import:

```ts
import { GoodsReturnModule } from './goods-return/goods-return.module';
import { ReportModule } from './report/report.module';
```

Add the module to the `imports` array, after `GoodsReturnModule`:

```ts
    GoodsReturnModule, // UC-09: nhận order.returned, sinh GoodsReturn, RECEIVER inspect/confirm/cancel
    ReportModule, // S4-03: báo cáo tồn (theo SKU+kho, theo lô) + hiệu suất kho, read-only — [ADMIN, MANAGER]
```

- [ ] **Step 4: Run full test suite for regressions**

Run: `pnpm test`
Expected: PASS, all existing tests plus the new `report` tests, no failures.

- [ ] **Step 5: Run typecheck**

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json`
Expected: no errors.

- [ ] **Step 6: Run lint on the new module**

Run: `pnpm exec eslint 'apps/wms/src/report/**/*.ts' apps/wms/src/app.module.ts`
Expected: no issues.

- [ ] **Step 7: Run the build**

Run: `pnpm exec nest build wms`
Expected: builds successfully.

- [ ] **Step 8: Commit**

```bash
git add apps/wms/src/report/report.controller.ts apps/wms/src/report/report.module.ts apps/wms/src/app.module.ts
git commit -m "feat(wms/report): thêm controller + module, đăng ký vào AppModule cho S4-03"
```

---

### Task 9: End-to-end manual verification

**Files:** none (verification only).

- [ ] **Step 1: Start the WMS app**

Run: `pnpm start:wms`
Expected: app boots without errors, logs show routes mounted under `api/wms`, including `reports/stock`, `reports/stock/lots`, `reports/performance`.

- [ ] **Step 2: Confirm MongoDB is reachable**

Run: `mongosh --eval "db.adminCommand('ping')"` (or check your Atlas/local instance is reachable). Unlike UC-09's transaction-heavy flow, this module's aggregation queries **do not** require a replica set — a standalone MongoDB is sufficient. If unavailable in your environment, note this explicitly rather than claiming the flow was verified.

- [ ] **Step 3: Seed minimal data**

Using existing dev data or manual inserts: 1 `Warehouse`, 1 `WarehouseItem` (`sku: "SKU-TEST-1"`, `isPerishable: true`, `nearExpiryDays: 3`), 1 `StockBalance` row (`onHand: 20, reserved: 5, expired: 0`), 1 `Lot` (`lotNumber: "LOT-1"`, `expiryDate` 2 days from now, `status: "ACTIVE"`), 1 `InventoryStock` row referencing that lot (`quantity: 20`), a few `StockMovement` rows (`type: "RECEIVE"`, `type: "ISSUE"`) dated within the last 30 days.

- [ ] **Step 4: Exercise `GET /reports/stock`**

`GET /api/wms/reports/stock?warehouseId=<id>` as `MANAGER`/`ADMIN`-authenticated user.
Expect: `data` contains 1 row for `SKU-TEST-1` with `onHand: 20, reserved: 5, expired: 0, available: 15`, matching the seeded `StockBalance`. `meta.pagination` present with `type: "offset"`.
Try `?sku=SKU-DOES-NOT-EXIST` → expect `data: []`, `meta.pagination.totalItems: 0`.
Try as a `PICKER`-authenticated user → expect `403`.

- [ ] **Step 5: Exercise `GET /reports/stock/lots`**

`GET /api/wms/reports/stock/lots?warehouseId=<id>`.
Expect: 1 row for `LOT-1` with `quantity: 20`, `expiryFlag: "expiringSoon"` (seeded 2 days out, item's `nearExpiryDays: 3`).
Try `?status=EXPIRED` → expect `data: []` (seeded lot is `ACTIVE`).

- [ ] **Step 6: Exercise `GET /reports/performance`**

`GET /api/wms/reports/performance?warehouseId=<id>` (no date range → defaults to last 30 days).
Expect: response array has exactly 8 rows (one per `MovementType`), `RECEIVE` and `ISSUE` rows have non-zero `movementCount` matching the seeded movements, other types show `totalQuantity: 0, movementCount: 0`.
Cross-check: `db.stock_movements.countDocuments({ warehouseId: ObjectId("<id>"), type: "RECEIVE" })` in `mongosh` matches the `movementCount` for `RECEIVE` in the response.

Expected: every step matches. Report any mismatch before considering the task done. If MongoDB is not available in your environment to run this live, say so explicitly instead of claiming success — automated test coverage (Tasks 1-8) is still meaningful evidence on its own if live verification isn't possible.

- [ ] **Step 7: Stop the app**

Ctrl+C or kill the process started in Step 1.

---

## Self-Review Notes (already applied above)

- **Spec coverage:** all 9 design decisions from `docs/superpowers/specs/2026-07-15-s4-03-report-module-design.md` map to tasks: stock report grouped by SKU+warehouse from `StockBalance` (Tasks 2, 5), performance report aggregated (not time-series) per `MovementType` over a date range (Tasks 4, 7), `PaginatedResult`/`OffsetPaginationQuery`/`buildOffsetMeta` adoption (Task 8), `nearExpiryDays ?? 7` threshold (Task 6), performance endpoint unpaginated (Task 8's `getPerformanceReport` returns a plain array, not `PaginatedResult`), 30-day default date range (Task 7), no FK-existence validation but `@IsMongoId` on `warehouseId` (Task 1), no `AppException` needed (no task adds one), 4-model `forFeature` registration instead of importing `StockModule`/`WarehouseModule` (Task 8).
- **Placeholder scan:** no TBD/TODO anywhere; every code block is complete, including the full aggregation pipelines and the full DTO/service/controller bodies.
- **Type consistency:** `ReportRepository` method names/signatures defined in Tasks 2-4 (`findItemIdBySku`, `aggregateStockReport`, `aggregateLotReport`, `aggregatePerformanceReport`, and their exact parameter/return types `ItemFilter`, `ItemSkuLookup`, `RawStockReportRow`, `LotItemFilter`, `RawLotReportRow`, `PerformanceFilter`, `RawPerformanceRow`) are consumed identically by `ReportService` in Tasks 5-7 and by the mocks in `report.service.spec.ts`. `ReportService` method names (`getStockReport`, `getLotReport`, `getPerformanceReport`) match exactly what `ReportController` calls in Task 8. DTO class names from Task 1 (`QueryStockReportDto`, `QueryLotReportDto`, `QueryPerformanceReportDto`, `StockReportItemDto`, `LotReportItemDto`, `PerformanceReportItemDto`, `ExpiryFlag`) are used identically across Tasks 5-8 with no drift.
