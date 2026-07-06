# S2-05: Thuật toán gợi ý vị trí put-away — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Thêm endpoint advisory `GET /putaway/suggestions?sku=&qty=&warehouseId=` trả về danh sách shelf phù hợp nhất để RECEIVER đặt hàng put-away, dựa trên thể tích còn trống và ràng buộc kích thước 3 chiều.

**Architecture:** Module mới `apps/wms/src/put-away-suggestion/` (đọc-only, không transaction) dùng lại `StockRepository` (WarehouseItem + InventoryStock) và `WarehouseRepository` (Shelf) đã có. Thêm 3 field kích thước vào `WarehouseItem`, thêm 2 method truy vấn mới (1 ở mỗi repository), phần còn lại là thuật toán thuần trong service.

**Tech Stack:** NestJS, Mongoose (aggregate pipeline cho occupied volume), class-validator/class-transformer cho DTO, Jest cho unit test.

## Global Constraints

- Repo tài liệu: `docs/superpowers/specs/2026-07-06-s2-05-putaway-suggestion-design.md` — nguồn chuẩn cho hành vi; `docs/warehouse/workflow.md` WF-01 là thuật toán gốc.
- **Cấm `any`** — mọi type phải rõ ràng (`.claude/rules/dto-conventions.md`).
- Service **PHẢI dùng `AppException`** từ `@app/common`, không throw NestJS exception thô (`.claude/rules/error-handling.md`).
- DTO response dùng `@Expose()` + `plainToInstance(..., { excludeExtraneousValues: true })`; enum trong DTO phải khai `enum:` trong `@ApiProperty` (`.claude/rules/dto-conventions.md`).
- `@Roles(...)` phải ghi vào `@ApiOperation({ summary: '... — [ROLE1, ROLE2]' })`.
- Occupied/free/capacity luôn **dẫn xuất động**, không lưu field trạng thái chiếm dụng.
- Đây là tính năng **advisory** — không đổi luồng/transaction của `confirm-line` (S2-04).
- Không thêm error code mới cho các trạng thái "không gợi ý được" — dùng field `warning` trong response 200 OK. Chỉ sku không tồn tại mới throw (`PUTAWAY_ITEM_NOT_FOUND`, đã có sẵn).
- Test theo pattern hiện có trong `put-away.service.spec.ts`: constructor injection thủ công + mock factory `jest.fn()`, không dùng `Test.createTestingModule`.

---

### Task 1: Thêm field kích thước vào `WarehouseItem`

**Files:**
- Modify: `apps/wms/src/stock/schemas/warehouse-item.schema.ts`
- Modify: `apps/wms/src/stock/dto/create-warehouse-item.dto.ts`
- Modify: `apps/wms/src/stock/dto/warehouse-item.response.dto.ts`
- Modify: `apps/wms/src/stock/stock.repository.ts` (`CreateWarehouseItemData` type)
- Test: `apps/wms/src/stock/schemas/warehouse-item.schema.spec.ts`

**Interfaces:**
- Produces: `WarehouseItem.depth?: number`, `WarehouseItem.width?: number`, `WarehouseItem.height?: number` (tất cả optional, cm) — Task 3 (occupied volume aggregate) và Task 4 (thuật toán) đọc 3 field này để tính `unitVolume = depth * width * height`.

- [ ] **Step 1: Đọc test schema hiện có để nắm pattern**

Đọc `apps/wms/src/stock/schemas/warehouse-item.schema.spec.ts` để biết cách test hiện tại dựng document (dùng `new WarehouseItemModel(...)` hoặc validate thuần schema). Không cần code ở bước này — chỉ xác nhận cách viết test mới cho nhất quán.

- [ ] **Step 2: Viết test cho 3 field mới (thất bại trước)**

Thêm vào cuối `apps/wms/src/stock/schemas/warehouse-item.schema.spec.ts`:

```typescript
describe('kích thước (depth/width/height)', () => {
  it('cho phép tạo item không khai kích thước (optional)', () => {
    const doc = new WarehouseItemModel({
      sku: 'SKU-NO-DIM',
      name: 'Không khai kích thước',
      type: ItemType.MATERIAL,
      unit: 'cái',
    });
    const err = doc.validateSync();
    expect(err).toBeUndefined();
    expect(doc.depth).toBeUndefined();
    expect(doc.width).toBeUndefined();
    expect(doc.height).toBeUndefined();
  });

  it('lưu đúng depth/width/height khi khai đủ', () => {
    const doc = new WarehouseItemModel({
      sku: 'SKU-DIM',
      name: 'Có khai kích thước',
      type: ItemType.MATERIAL,
      unit: 'cái',
      depth: 10,
      width: 20,
      height: 5,
    });
    expect(doc.depth).toBe(10);
    expect(doc.width).toBe(20);
    expect(doc.height).toBe(5);
  });
});
```

Điều chỉnh import `WarehouseItemModel`/`ItemType` theo đúng cách file spec hiện tại đã import (giữ nguyên style, chỉ thêm block `describe` mới).

- [ ] **Step 3: Chạy test, xác nhận fail**

Run: `pnpm test -- warehouse-item.schema.spec.ts`
Expected: FAIL — `doc.depth`/`doc.width`/`doc.height` là `undefined` khi test kỳ vọng giá trị số (test thứ 2 fail vì schema chưa có field).

- [ ] **Step 4: Thêm 3 field vào schema**

Trong `apps/wms/src/stock/schemas/warehouse-item.schema.ts`, thêm sau field `nearExpiryDays` (trước `isActive`):

```typescript
  /** Chiều sâu 1 đơn vị cơ sở (cm) — dùng tính unitVolume cho gợi ý put-away */
  @Prop({ type: Number })
  depth?: number;

  /** Chiều rộng 1 đơn vị cơ sở (cm) */
  @Prop({ type: Number })
  width?: number;

  /** Chiều cao 1 đơn vị cơ sở (cm) */
  @Prop({ type: Number })
  height?: number;
```

- [ ] **Step 5: Chạy lại test, xác nhận pass**

Run: `pnpm test -- warehouse-item.schema.spec.ts`
Expected: PASS toàn bộ file (test cũ + 2 test mới).

- [ ] **Step 6: Thêm field vào `CreateWarehouseItemDto`**

Trong `apps/wms/src/stock/dto/create-warehouse-item.dto.ts`, thêm sau field `nearExpiryDays` (cuối class, trước dấu `}`):

```typescript
  @ApiPropertyOptional({ example: 10, description: 'Chiều sâu 1 đơn vị cơ sở (cm)' })
  @IsOptional()
  @IsNumber()
  @Min(0)
  depth?: number;

  @ApiPropertyOptional({ example: 8, description: 'Chiều rộng 1 đơn vị cơ sở (cm)' })
  @IsOptional()
  @IsNumber()
  @Min(0)
  width?: number;

  @ApiPropertyOptional({ example: 12, description: 'Chiều cao 1 đơn vị cơ sở (cm)' })
  @IsOptional()
  @IsNumber()
  @Min(0)
  height?: number;
```

Thêm `IsNumber` vào import `class-validator` ở đầu file (danh sách import hiện có: `IsArray, IsBoolean, IsEnum, IsInt, IsOptional, IsString, Min, MinLength, ValidateNested`).

- [ ] **Step 7: Thêm field vào `WarehouseItemResponseDto`**

Trong `apps/wms/src/stock/dto/warehouse-item.response.dto.ts`, thêm sau field `nearExpiryDays` (trước `isActive`):

```typescript
  @Expose()
  @ApiPropertyOptional()
  depth?: number;

  @Expose()
  @ApiPropertyOptional()
  width?: number;

  @Expose()
  @ApiPropertyOptional()
  height?: number;
```

- [ ] **Step 8: Thêm field vào `CreateWarehouseItemData` type trong `StockRepository`**

Trong `apps/wms/src/stock/stock.repository.ts`, sửa type `CreateWarehouseItemData` (dòng 32-43) — thêm 3 field optional sau `nearExpiryDays?: number;`:

```typescript
  depth?: number;
  width?: number;
  height?: number;
```

- [ ] **Step 9: Build để xác nhận không lỗi type**

Run: `pnpm build`
Expected: build thành công, không lỗi TypeScript (vì `createItem` dùng spread `...data` nên field mới tự đi qua, không cần sửa gì thêm trong `createItem`).

- [ ] **Step 10: Chạy toàn bộ test stock module**

Run: `pnpm test -- apps/wms/src/stock`
Expected: PASS toàn bộ (không phá test `create-warehouse-item`/`stock.service` hiện có vì field mới đều optional).

- [ ] **Step 11: Commit**

```bash
git add apps/wms/src/stock/schemas/warehouse-item.schema.ts apps/wms/src/stock/schemas/warehouse-item.schema.spec.ts apps/wms/src/stock/dto/create-warehouse-item.dto.ts apps/wms/src/stock/dto/warehouse-item.response.dto.ts apps/wms/src/stock/stock.repository.ts
git commit -m "feat(wms/stock): thêm depth/width/height vào WarehouseItem cho gợi ý put-away"
```

---

### Task 2: `WarehouseRepository.findShelvesByWarehouse` — liệt kê shelf ứng viên

**Files:**
- Modify: `apps/wms/src/warehouse/warehouse.repository.ts`
- Test: `apps/wms/src/warehouse/warehouse.repository.spec.ts`

**Interfaces:**
- Consumes: `Shelf` schema hiện có (`warehouseId`, `isStaging`, `deletedAt`, `innerDepth/innerWidth/innerHeight`) — không đổi.
- Produces: `WarehouseRepository.findShelvesByWarehouse(warehouseId: string): Promise<ShelfDocument[]>` — Task 4 (suggestion service) gọi method này để lấy danh sách shelf ứng viên (đã lọc non-staging, non-deleted, đã khai đủ 3 chiều).

- [ ] **Step 1: Đọc test hiện có để nắm pattern mock Model**

Đọc `apps/wms/src/warehouse/warehouse.repository.spec.ts` (phần test `findShelvesByRack` hoặc `findShelfByCode`) để copy đúng cách mock `shelfModel.find()`/`.findOne()` (thường là `jest.fn().mockReturnValue({ exec: ... })` hoặc mock chain `.sort().exec()`).

- [ ] **Step 2: Viết test thất bại cho `findShelvesByWarehouse`**

Thêm vào `apps/wms/src/warehouse/warehouse.repository.spec.ts`, trong block `describe` của Shelf (cạnh test `findShelvesByRack`):

```typescript
describe('findShelvesByWarehouse', () => {
  it('lọc đúng warehouseId, isStaging=false, deletedAt=null, đã khai đủ 3 chiều', async () => {
    const warehouseId = new Types.ObjectId().toString();
    const execMock = jest.fn().mockResolvedValue([]);
    const sortMock = jest.fn().mockReturnValue({ exec: execMock });
    shelfModel.find = jest.fn().mockReturnValue({ sort: sortMock });

    await repo.findShelvesByWarehouse(warehouseId);

    expect(shelfModel.find).toHaveBeenCalledWith({
      warehouseId: new Types.ObjectId(warehouseId),
      isStaging: false,
      deletedAt: null,
      innerDepth: { $exists: true, $ne: null },
      innerWidth: { $exists: true, $ne: null },
      innerHeight: { $exists: true, $ne: null },
    });
  });
});
```

Điều chỉnh biến `shelfModel`/`repo` theo đúng tên đã khai trong `beforeEach` của file spec hiện tại (kiểm tra top file để lấy tên chính xác).

- [ ] **Step 3: Chạy test, xác nhận fail**

Run: `pnpm test -- warehouse.repository.spec.ts -t findShelvesByWarehouse`
Expected: FAIL — `repo.findShelvesByWarehouse is not a function`.

- [ ] **Step 4: Thêm method vào `WarehouseRepository`**

Trong `apps/wms/src/warehouse/warehouse.repository.ts`, thêm ngay sau `findShelvesByRack` (dòng 221-226):

```typescript
  /** Liệt kê shelf ứng viên cho gợi ý put-away: non-staging, chưa xoá, đã khai đủ 3 chiều. */
  async findShelvesByWarehouse(warehouseId: string): Promise<ShelfDocument[]> {
    return this.shelfModel
      .find({
        warehouseId: new Types.ObjectId(warehouseId),
        isStaging: false,
        deletedAt: null,
        innerDepth: { $exists: true, $ne: null },
        innerWidth: { $exists: true, $ne: null },
        innerHeight: { $exists: true, $ne: null },
      })
      .sort({ code: 1 })
      .exec();
  }
```

- [ ] **Step 5: Chạy lại test, xác nhận pass**

Run: `pnpm test -- warehouse.repository.spec.ts`
Expected: PASS toàn bộ file.

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/warehouse/warehouse.repository.ts apps/wms/src/warehouse/warehouse.repository.spec.ts
git commit -m "feat(wms/warehouse): thêm findShelvesByWarehouse liệt kê shelf ứng viên put-away"
```

---

### Task 3: `StockRepository.findOccupiedVolumeByWarehouse` — aggregate thể tích đã chiếm theo shelf

**Files:**
- Modify: `apps/wms/src/stock/stock.repository.ts`
- Test: `apps/wms/src/stock/stock.repository.spec.ts`

**Interfaces:**
- Consumes: `InventoryStock` (`itemId`, `warehouseId`, `shelfId`, `quantity`), `WarehouseItem` (`depth/width/height` từ Task 1).
- Produces: `StockRepository.findOccupiedVolumeByWarehouse(warehouseId: Types.ObjectId): Promise<Map<string, number>>` — key là `shelfId.toString()`, value là tổng thể tích đã chiếm (cm³). Shelf không có `InventoryStock` nào thì không xuất hiện trong Map (Task 4 tự coi `occupied = 0` khi `.get(shelfId)` trả `undefined`).

- [ ] **Step 1: Đọc test hiện có để nắm pattern mock aggregate**

Đọc phần đầu `apps/wms/src/stock/stock.repository.spec.ts` để lấy tên biến mock model (`inventoryModel`, `itemModel`...) và cách mock method dạng promise thường (`.exec()`). Vì đây là lần đầu dùng `.aggregate()` trong repo này, sẽ mock trực tiếp `inventoryModel.aggregate = jest.fn().mockResolvedValue([...])` (Mongoose `aggregate()` trả về `Aggregate` — khi không gọi thêm `.exec()` mà `await` trực tiếp thì cứ mock resolved value là đủ, xem step tiếp).

- [ ] **Step 2: Viết test thất bại cho `findOccupiedVolumeByWarehouse`**

Thêm vào `apps/wms/src/stock/stock.repository.spec.ts`:

```typescript
describe('findOccupiedVolumeByWarehouse', () => {
  it('gọi aggregate với pipeline lookup warehouse_items và group theo shelfId', async () => {
    const warehouseId = new Types.ObjectId();
    inventoryModel.aggregate = jest.fn().mockResolvedValue([
      { shelfId: 'shelf-a', occupied: 240 },
      { shelfId: 'shelf-b', occupied: 0 },
    ]);

    const result = await repo.findOccupiedVolumeByWarehouse(warehouseId);

    expect(inventoryModel.aggregate).toHaveBeenCalledTimes(1);
    expect(result.get('shelf-a')).toBe(240);
    expect(result.get('shelf-b')).toBe(0);
    expect(result.has('shelf-c')).toBe(false);
  });
});
```

Điều chỉnh tên biến `inventoryModel`/`repo` theo đúng cách file spec hiện tại đã khai (kiểm tra `beforeEach`/khởi tạo `new StockRepository(...)` ở đầu file).

- [ ] **Step 3: Chạy test, xác nhận fail**

Run: `pnpm test -- stock.repository.spec.ts -t findOccupiedVolumeByWarehouse`
Expected: FAIL — `repo.findOccupiedVolumeByWarehouse is not a function`.

- [ ] **Step 4: Thêm method vào `StockRepository`**

Trong `apps/wms/src/stock/stock.repository.ts`, thêm vào cuối class (sau `createItem`, trước dấu `}` đóng class ở dòng 191):

```typescript
  /**
   * Tính thể tích đã chiếm (cm³) của mọi shelf trong 1 kho, group theo shelfId,
   * tổng hợp Σ(quantity × unitVolume) trên mọi SKU/lô của shelf đó. Dòng
   * InventoryStock có item thiếu depth/width/height bị loại khỏi tổng (không
   * throw) — occupied chỉ tính trên item đã khai đủ kích thước.
   */
  async findOccupiedVolumeByWarehouse(
    warehouseId: Types.ObjectId,
  ): Promise<Map<string, number>> {
    const rows = await this.inventoryModel.aggregate<{
      shelfId: string;
      occupied: number;
    }>([
      { $match: { warehouseId } },
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
        $match: {
          'item.depth': { $exists: true, $ne: null },
          'item.width': { $exists: true, $ne: null },
          'item.height': { $exists: true, $ne: null },
        },
      },
      {
        $group: {
          _id: '$shelfId',
          occupied: {
            $sum: {
              $multiply: [
                '$quantity',
                { $multiply: ['$item.depth', '$item.width', '$item.height'] },
              ],
            },
          },
        },
      },
      { $project: { _id: 0, shelfId: { $toString: '$_id' }, occupied: 1 } },
    ]);

    return new Map(rows.map((r) => [r.shelfId, r.occupied]));
  }
```

- [ ] **Step 5: Chạy lại test, xác nhận pass**

Run: `pnpm test -- stock.repository.spec.ts`
Expected: PASS toàn bộ file.

- [ ] **Step 6: Build để xác nhận type aggregate hợp lệ**

Run: `pnpm build`
Expected: build thành công, không lỗi TypeScript ở pipeline aggregate.

- [ ] **Step 7: Commit**

```bash
git add apps/wms/src/stock/stock.repository.ts apps/wms/src/stock/stock.repository.spec.ts
git commit -m "feat(wms/stock): thêm findOccupiedVolumeByWarehouse tính thể tích đã chiếm theo shelf"
```

---

### Task 4: `PutAwaySuggestionService` — thuật toán gợi ý (fit 3 chiều + xếp hạng + fallback tổ hợp)

**Files:**
- Create: `apps/wms/src/put-away-suggestion/put-away-suggestion.service.ts`
- Create: `apps/wms/src/put-away-suggestion/dto/put-away-suggestion.dto.ts`
- Test: `apps/wms/src/put-away-suggestion/put-away-suggestion.service.spec.ts`

**Interfaces:**
- Consumes:
  - `StockRepository.findItemBySku(sku: string): Promise<WarehouseItem | null>` (đã có, trả về `.lean()` object).
  - `StockRepository.findOccupiedVolumeByWarehouse(warehouseId: Types.ObjectId): Promise<Map<string, number>>` (Task 3).
  - `WarehouseRepository.findShelvesByWarehouse(warehouseId: string): Promise<ShelfDocument[]>` (Task 2).
  - `ConfigService.get<number>('PUTAWAY_DEFAULT_FILL_FACTOR')`.
- Produces: `PutAwaySuggestionService.suggest(sku: string, qty: number, warehouseId: string): Promise<PutAwaySuggestionResult>` với:
  ```typescript
  export interface PutAwaySuggestionItem {
    shelfCode: string;
    capacity: number;
  }
  export type PutAwaySuggestionWarning =
    | 'ITEM_NO_DIMENSIONS'
    | 'NO_SHELF_FITS'
    | 'INSUFFICIENT_CAPACITY'
    | null;
  export interface PutAwaySuggestionResult {
    suggestions: PutAwaySuggestionItem[];
    warning: PutAwaySuggestionWarning;
  }
  ```
  Task 5 (controller) gọi `suggest(...)` và trả thẳng kết quả qua response DTO.

- [ ] **Step 1: Tạo DTO trước (không cần test — pure declaration)**

Tạo `apps/wms/src/put-away-suggestion/dto/put-away-suggestion.dto.ts`:

```typescript
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Expose } from 'class-transformer';
import { IsInt, IsMongoId, IsString, Min, MinLength } from 'class-validator';

export class QueryPutAwaySuggestionDto {
  @ApiProperty({ example: 'CUP-500ML-RED' })
  @IsString()
  @MinLength(1)
  sku!: string;

  @ApiProperty({ example: 50 })
  @IsInt()
  @Min(1)
  qty!: number;

  @ApiProperty({ example: '60d5ec49f1b2c72b3c8e4f01' })
  @IsMongoId()
  warehouseId!: string;
}

export class PutAwaySuggestionItemDto {
  @Expose()
  @ApiProperty()
  shelfCode!: string;

  @Expose()
  @ApiProperty()
  capacity!: number;
}

export class PutAwaySuggestionResponseDto {
  @Expose()
  @ApiProperty({ type: [PutAwaySuggestionItemDto] })
  suggestions!: PutAwaySuggestionItemDto[];

  @Expose()
  @ApiPropertyOptional({
    enum: ['ITEM_NO_DIMENSIONS', 'NO_SHELF_FITS', 'INSUFFICIENT_CAPACITY'],
    nullable: true,
    description: 'null nếu có gợi ý hợp lệ, ngược lại giải thích lý do không gợi ý được',
  })
  warning!: string | null;
}
```

`qty` nhận từ query string — NestJS `ValidationPipe` toàn cục của app đã bật `transform: true` nên `@IsInt()` áp được sau khi ép kiểu tự động (theo đúng cách các `Query*Dto` khác trong repo, vd `QueryPutAwayTaskDto`, xử lý number qua query).

- [ ] **Step 2: Đọc test `put-away.service.spec.ts` để copy pattern mock**

Đã đọc ở bước brainstorming — pattern: `makeXxxRepo()` factory trả object `jest.fn()` cho từng method, `beforeEach` khởi tạo lại, constructor injection thủ công `new Service(mockA as never, mockB as never, ...)`.

- [ ] **Step 3: Viết test thất bại — case sku không tồn tại**

Tạo `apps/wms/src/put-away-suggestion/put-away-suggestion.service.spec.ts`:

```typescript
import { Types } from 'mongoose';
import { PutAwaySuggestionService } from './put-away-suggestion.service';

const makeStockRepo = () => ({
  findItemBySku: jest.fn(),
  findOccupiedVolumeByWarehouse: jest.fn(),
});

const makeWarehouseRepo = () => ({
  findShelvesByWarehouse: jest.fn(),
});

const makeConfigService = (fillFactor = 0.75) => ({
  get: jest.fn().mockReturnValue(fillFactor),
});

describe('PutAwaySuggestionService', () => {
  let svc: PutAwaySuggestionService;
  let stockRepo: ReturnType<typeof makeStockRepo>;
  let warehouseRepo: ReturnType<typeof makeWarehouseRepo>;
  let configService: ReturnType<typeof makeConfigService>;

  const warehouseId = new Types.ObjectId().toString();

  beforeEach(() => {
    stockRepo = makeStockRepo();
    warehouseRepo = makeWarehouseRepo();
    configService = makeConfigService();
    svc = new PutAwaySuggestionService(
      stockRepo as never,
      warehouseRepo as never,
      configService as never,
    );
  });

  it('throw PUTAWAY_ITEM_NOT_FOUND khi sku không tồn tại', async () => {
    stockRepo.findItemBySku.mockResolvedValue(null);
    await expect(svc.suggest('SKU-X', 10, warehouseId)).rejects.toMatchObject({
      code: 'PUTAWAY_ITEM_NOT_FOUND',
    });
  });
});
```

Nếu `AppException` không expose field `code` trực tiếp (kiểm tra `libs/common/src/errors/app.exception.ts` hoặc tương đương lúc code thật), đổi assertion sang cách các test khác trong repo đang dùng để kiểm tra mã lỗi (vd `expect(...).rejects.toThrow(AppException)` kèm kiểm tra `.getStatus()`/`.code` theo đúng API thật của class này — xem cách `put-away.service.spec.ts` test throw để copy y hệt).

- [ ] **Step 4: Chạy test, xác nhận fail**

Run: `pnpm test -- put-away-suggestion.service.spec.ts`
Expected: FAIL — module `./put-away-suggestion.service` không tồn tại.

- [ ] **Step 5: Viết khung service + case sku not found + case item thiếu kích thước**

Tạo `apps/wms/src/put-away-suggestion/put-away-suggestion.service.ts`:

```typescript
import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Types } from 'mongoose';
import { AppException } from '@app/common';
import { StockRepository } from '../stock/stock.repository';
import { WarehouseRepository } from '../warehouse/warehouse.repository';
import type { ShelfDocument } from '../warehouse/schemas/shelf.schema';

export interface PutAwaySuggestionItem {
  shelfCode: string;
  capacity: number;
}

export type PutAwaySuggestionWarning =
  | 'ITEM_NO_DIMENSIONS'
  | 'NO_SHELF_FITS'
  | 'INSUFFICIENT_CAPACITY'
  | null;

export interface PutAwaySuggestionResult {
  suggestions: PutAwaySuggestionItem[];
  warning: PutAwaySuggestionWarning;
}

interface Candidate {
  shelf: ShelfDocument;
  capacity: number;
  free: number;
  hasSameSku: boolean;
}

const DEFAULT_FILL_FACTOR = 0.75;

@Injectable()
export class PutAwaySuggestionService {
  constructor(
    private readonly stockRepo: StockRepository,
    private readonly warehouseRepo: WarehouseRepository,
    private readonly configService: ConfigService,
  ) {}

  async suggest(
    sku: string,
    qty: number,
    warehouseId: string,
  ): Promise<PutAwaySuggestionResult> {
    const item = await this.stockRepo.findItemBySku(sku);
    if (!item) throw new AppException('PUTAWAY_ITEM_NOT_FOUND');

    if (!item.depth || !item.width || !item.height) {
      return { suggestions: [], warning: 'ITEM_NO_DIMENSIONS' };
    }
    const unitVolume = item.depth * item.width * item.height;
    const itemDims = [item.depth, item.width, item.height].sort(
      (a, b) => b - a,
    );

    const shelves =
      await this.warehouseRepo.findShelvesByWarehouse(warehouseId);
    const fittingShelves = shelves.filter((s) =>
      this.fits(itemDims, s),
    );
    if (fittingShelves.length === 0) {
      return { suggestions: [], warning: 'NO_SHELF_FITS' };
    }

    const occupiedByShelf = await this.stockRepo.findOccupiedVolumeByWarehouse(
      new Types.ObjectId(warehouseId),
    );
    const defaultFillFactor =
      this.configService.get<number>('PUTAWAY_DEFAULT_FILL_FACTOR') ??
      DEFAULT_FILL_FACTOR;

    const candidates: Candidate[] = [];
    for (const shelf of fittingShelves) {
      const usableVolume =
        (shelf.innerDepth ?? 0) *
        (shelf.innerWidth ?? 0) *
        (shelf.innerHeight ?? 0);
      const fillFactor = shelf.fillFactor ?? defaultFillFactor;
      const occupied = occupiedByShelf.get(shelf._id.toString()) ?? 0;
      const free = usableVolume * fillFactor - occupied;
      const capacity = Math.floor(free / unitVolume);
      if (capacity < 1) continue;
      candidates.push({
        shelf,
        capacity,
        free,
        hasSameSku: occupiedByShelf.has(shelf._id.toString()) && occupied > 0,
      });
    }

    if (candidates.length === 0) {
      return { suggestions: [], warning: 'NO_SHELF_FITS' };
    }

    const single = this.rankSingleShelf(candidates, qty, item._id.toString());
    if (single) {
      return { suggestions: [single], warning: null };
    }

    return this.combineShelves(candidates, qty);
  }

  private fits(itemDimsDesc: number[], shelf: ShelfDocument): boolean {
    const shelfDims = [
      shelf.innerDepth ?? 0,
      shelf.innerWidth ?? 0,
      shelf.innerHeight ?? 0,
    ].sort((a, b) => b - a);
    return itemDimsDesc.every((d, i) => d <= shelfDims[i]);
  }

  private rankSingleShelf(
    candidates: Candidate[],
    qty: number,
    _itemId: string,
  ): PutAwaySuggestionItem | null {
    const sufficient = candidates.filter((c) => c.capacity >= qty);
    if (sufficient.length === 0) return null;

    const sameSku = sufficient
      .filter((c) => c.hasSameSku)
      .sort((a, b) => b.capacity - a.capacity);
    if (sameSku.length > 0) {
      return {
        shelfCode: sameSku[0].shelf.code,
        capacity: sameSku[0].capacity,
      };
    }

    const bestFit = [...sufficient].sort((a, b) => a.free - b.free);
    return { shelfCode: bestFit[0].shelf.code, capacity: bestFit[0].capacity };
  }

  private combineShelves(
    candidates: Candidate[],
    qty: number,
  ): PutAwaySuggestionResult {
    const sorted = [...candidates].sort((a, b) => b.capacity - a.capacity);
    const chosen: PutAwaySuggestionItem[] = [];
    let covered = 0;
    for (const c of sorted) {
      if (covered >= qty) break;
      chosen.push({ shelfCode: c.shelf.code, capacity: c.capacity });
      covered += c.capacity;
    }
    const warning: PutAwaySuggestionWarning =
      covered >= qty ? null : 'INSUFFICIENT_CAPACITY';
    return { suggestions: chosen, warning };
  }
}
```

- [ ] **Step 6: Chạy test, xác nhận pass case sku not found**

Run: `pnpm test -- put-away-suggestion.service.spec.ts`
Expected: PASS.

- [ ] **Step 7: Viết test case item thiếu kích thước**

Thêm vào file spec:

```typescript
it('trả warning ITEM_NO_DIMENSIONS khi item thiếu depth/width/height', async () => {
  stockRepo.findItemBySku.mockResolvedValue({
    _id: new Types.ObjectId(),
    depth: undefined,
    width: 10,
    height: 10,
  });
  const result = await svc.suggest('SKU-X', 10, warehouseId);
  expect(result).toEqual({ suggestions: [], warning: 'ITEM_NO_DIMENSIONS' });
});
```

- [ ] **Step 8: Chạy test, xác nhận pass**

Run: `pnpm test -- put-away-suggestion.service.spec.ts`
Expected: PASS.

- [ ] **Step 9: Viết test case không shelf nào lọt ràng buộc 3 chiều**

```typescript
it('trả warning NO_SHELF_FITS khi hàng vượt mọi shelf', async () => {
  const itemId = new Types.ObjectId();
  stockRepo.findItemBySku.mockResolvedValue({
    _id: itemId,
    depth: 200,
    width: 200,
    height: 200,
  });
  warehouseRepo.findShelvesByWarehouse.mockResolvedValue([
    {
      _id: new Types.ObjectId(),
      code: 'A1-1',
      innerDepth: 50,
      innerWidth: 50,
      innerHeight: 50,
      fillFactor: null,
    },
  ]);

  const result = await svc.suggest('SKU-BIG', 5, warehouseId);
  expect(result).toEqual({ suggestions: [], warning: 'NO_SHELF_FITS' });
});
```

- [ ] **Step 10: Chạy test, xác nhận pass**

Run: `pnpm test -- put-away-suggestion.service.spec.ts`
Expected: PASS.

- [ ] **Step 11: Viết test case shelf đã chứa cùng SKU được ưu tiên**

```typescript
it('ưu tiên shelf đã chứa cùng SKU dù shelf khác trống hơn', async () => {
  const itemId = new Types.ObjectId();
  stockRepo.findItemBySku.mockResolvedValue({
    _id: itemId,
    depth: 10,
    width: 10,
    height: 10,
  });
  const shelfSameSku = {
    _id: new Types.ObjectId(),
    code: 'A1-1',
    innerDepth: 100,
    innerWidth: 100,
    innerHeight: 100,
    fillFactor: null,
  };
  const shelfEmpty = {
    _id: new Types.ObjectId(),
    code: 'A1-2',
    innerDepth: 100,
    innerWidth: 100,
    innerHeight: 100,
    fillFactor: null,
  };
  warehouseRepo.findShelvesByWarehouse.mockResolvedValue([
    shelfSameSku,
    shelfEmpty,
  ]);
  // shelfSameSku đã chiếm 1 chút thể tích (bởi chính SKU này) — vẫn còn đủ chỗ.
  stockRepo.findOccupiedVolumeByWarehouse.mockResolvedValue(
    new Map([[shelfSameSku._id.toString(), 1000]]),
  );

  const result = await svc.suggest('SKU-A', 10, warehouseId);

  expect(result.warning).toBeNull();
  expect(result.suggestions).toHaveLength(1);
  expect(result.suggestions[0].shelfCode).toBe('A1-1');
});
```

- [ ] **Step 12: Chạy test, xác nhận pass**

Run: `pnpm test -- put-away-suggestion.service.spec.ts`
Expected: PASS. Nếu fail vì logic `hasSameSku` hiện tại chỉ biết "shelf có occupied > 0" chứ không phân biệt occupied đó có phải cùng SKU hay không — đây là giới hạn thật của thiết kế (aggregate ở Task 3 gộp mọi SKU vào 1 con số occupied per shelf, không tách theo SKU). Xử lý: sửa `findOccupiedVolumeByWarehouse` cách dùng — thay vì chỉ cần "có occupied", cần biết "shelf có InventoryStock của **chính itemId này**". Quay lại Task 3, thêm 1 method riêng biệt `StockRepository.findShelfIdsWithItem(itemId, warehouseId): Promise<Set<string>>` (query đơn giản `distinct('shelfId', {itemId, warehouseId})`), rồi dùng kết quả đó để set `hasSameSku` chính xác thay vì suy diễn từ occupied > 0. Cập nhật lại `PutAwaySuggestionService.suggest` để gọi thêm method này song song với `findOccupiedVolumeByWarehouse`, và cập nhật test Step 5 tương ứng (thêm mock `findShelfIdsWithItem`).

- [ ] **Step 13: Viết test case best-fit giữa 2 shelf không cùng SKU**

```typescript
it('best-fit: chọn shelf free nhỏ nhất trong các shelf đủ chứa', async () => {
  const itemId = new Types.ObjectId();
  stockRepo.findItemBySku.mockResolvedValue({
    _id: itemId,
    depth: 10,
    width: 10,
    height: 10, // unitVolume = 1000
  });
  const shelfLoose = {
    _id: new Types.ObjectId(),
    code: 'A1-1',
    innerDepth: 100,
    innerWidth: 100,
    innerHeight: 100, // usableVolume = 1_000_000
    fillFactor: 1,
  };
  const shelfTight = {
    _id: new Types.ObjectId(),
    code: 'A1-2',
    innerDepth: 50,
    innerWidth: 50,
    innerHeight: 50, // usableVolume = 125_000
    fillFactor: 1,
  };
  warehouseRepo.findShelvesByWarehouse.mockResolvedValue([
    shelfLoose,
    shelfTight,
  ]);
  stockRepo.findOccupiedVolumeByWarehouse.mockResolvedValue(new Map());
  stockRepo.findShelfIdsWithItem.mockResolvedValue(new Set());

  // qty=10 → cần capacity >= 10 (10 * 1000 = 10_000 cm³).
  // shelfLoose free=1_000_000 → capacity 1000. shelfTight free=125_000 → capacity 125.
  // Cả 2 đủ chứa qty=10 → chọn free nhỏ nhất = shelfTight.
  const result = await svc.suggest('SKU-A', 10, warehouseId);

  expect(result.warning).toBeNull();
  expect(result.suggestions[0].shelfCode).toBe('A1-2');
});
```

- [ ] **Step 14: Chạy test, xác nhận pass**

Run: `pnpm test -- put-away-suggestion.service.spec.ts`
Expected: PASS.

- [ ] **Step 15: Viết test case fallback tổ hợp nhiều shelf**

```typescript
it('trả tổ hợp nhiều shelf khi không shelf đơn nào đủ qty', async () => {
  const itemId = new Types.ObjectId();
  stockRepo.findItemBySku.mockResolvedValue({
    _id: itemId,
    depth: 10,
    width: 10,
    height: 10, // unitVolume = 1000
  });
  const shelfA = {
    _id: new Types.ObjectId(),
    code: 'A1-1',
    innerDepth: 100,
    innerWidth: 100,
    innerHeight: 3, // usableVolume = 30_000 → capacity 30
    fillFactor: 1,
  };
  const shelfB = {
    _id: new Types.ObjectId(),
    code: 'A1-2',
    innerDepth: 100,
    innerWidth: 100,
    innerHeight: 2, // usableVolume = 20_000 → capacity 20
    fillFactor: 1,
  };
  warehouseRepo.findShelvesByWarehouse.mockResolvedValue([shelfA, shelfB]);
  stockRepo.findOccupiedVolumeByWarehouse.mockResolvedValue(new Map());
  stockRepo.findShelfIdsWithItem.mockResolvedValue(new Set());

  // qty=45: không shelf đơn nào đủ (30 và 20 đều < 45), tổng 50 >= 45.
  const result = await svc.suggest('SKU-A', 45, warehouseId);

  expect(result.warning).toBeNull();
  expect(result.suggestions).toEqual([
    { shelfCode: 'A1-1', capacity: 30 },
    { shelfCode: 'A1-2', capacity: 20 },
  ]);
});

it('trả warning INSUFFICIENT_CAPACITY khi tổng capacity vẫn không đủ qty', async () => {
  const itemId = new Types.ObjectId();
  stockRepo.findItemBySku.mockResolvedValue({
    _id: itemId,
    depth: 10,
    width: 10,
    height: 10,
  });
  const shelfA = {
    _id: new Types.ObjectId(),
    code: 'A1-1',
    innerDepth: 100,
    innerWidth: 100,
    innerHeight: 3,
    fillFactor: 1,
  };
  warehouseRepo.findShelvesByWarehouse.mockResolvedValue([shelfA]);
  stockRepo.findOccupiedVolumeByWarehouse.mockResolvedValue(new Map());
  stockRepo.findShelfIdsWithItem.mockResolvedValue(new Set());

  const result = await svc.suggest('SKU-A', 999, warehouseId);

  expect(result.warning).toBe('INSUFFICIENT_CAPACITY');
  expect(result.suggestions).toEqual([{ shelfCode: 'A1-1', capacity: 30 }]);
});
```

- [ ] **Step 16: Chạy test, xác nhận pass**

Run: `pnpm test -- put-away-suggestion.service.spec.ts`
Expected: PASS toàn bộ file.

- [ ] **Step 17: Build để xác nhận không lỗi type**

Run: `pnpm build`
Expected: build thành công.

- [ ] **Step 18: Commit**

```bash
git add apps/wms/src/put-away-suggestion/
git commit -m "feat(wms/put-away-suggestion): thêm thuật toán gợi ý vị trí put-away theo thể tích"
```

---

### Task 5: `StockRepository.findShelfIdsWithItem` — bổ sung cho SKU-affinity ranking

**Files:**
- Modify: `apps/wms/src/stock/stock.repository.ts`
- Test: `apps/wms/src/stock/stock.repository.spec.ts`

**Interfaces:**
- Produces: `StockRepository.findShelfIdsWithItem(itemId: Types.ObjectId, warehouseId: Types.ObjectId): Promise<Set<string>>` — Task 4 dùng để xác định `hasSameSku` chính xác (thay vì suy diễn từ occupied > 0, vốn gộp mọi SKU).

> Task này lẽ ra nên làm trước Task 4 Step 12, nhưng đặt ở đây để tách rõ "thêm data access" khỏi "sửa thuật toán dùng nó" — làm theo đúng thứ tự Task 4 → phát hiện thiếu ở Step 12 → quay lại làm Task 5 → rồi hoàn thiện Task 4 Step 13-16 như plan đã viết ở trên (thứ tự triển khai thực tế: 4.1-4.11, rồi 5 toàn bộ, rồi 4.12-4.18).

- [ ] **Step 1: Viết test thất bại**

Thêm vào `apps/wms/src/stock/stock.repository.spec.ts`:

```typescript
describe('findShelfIdsWithItem', () => {
  it('trả về Set các shelfId có InventoryStock của itemId trong kho', async () => {
    const itemId = new Types.ObjectId();
    const warehouseId = new Types.ObjectId();
    const shelfA = new Types.ObjectId();
    inventoryModel.distinct = jest
      .fn()
      .mockReturnValue({ exec: jest.fn().mockResolvedValue([shelfA]) });

    const result = await repo.findShelfIdsWithItem(itemId, warehouseId);

    expect(inventoryModel.distinct).toHaveBeenCalledWith('shelfId', {
      itemId,
      warehouseId,
      quantity: { $gt: 0 },
    });
    expect(result.has(shelfA.toString())).toBe(true);
  });
});
```

- [ ] **Step 2: Chạy test, xác nhận fail**

Run: `pnpm test -- stock.repository.spec.ts -t findShelfIdsWithItem`
Expected: FAIL — `repo.findShelfIdsWithItem is not a function`.

- [ ] **Step 3: Thêm method vào `StockRepository`**

Thêm vào cuối class (sau `findOccupiedVolumeByWarehouse` từ Task 3):

```typescript
  /** Danh sách shelf đã có tồn (>0) của 1 item trong kho — dùng xếp hạng ưu tiên SKU-affinity khi gợi ý put-away. */
  async findShelfIdsWithItem(
    itemId: Types.ObjectId,
    warehouseId: Types.ObjectId,
  ): Promise<Set<string>> {
    const shelfIds = await this.inventoryModel
      .distinct('shelfId', { itemId, warehouseId, quantity: { $gt: 0 } })
      .exec();
    return new Set(shelfIds.map((id: Types.ObjectId) => id.toString()));
  }
```

- [ ] **Step 4: Chạy lại test, xác nhận pass**

Run: `pnpm test -- stock.repository.spec.ts`
Expected: PASS toàn bộ file.

- [ ] **Step 5: Cập nhật `PutAwaySuggestionService` dùng method mới thay vì suy diễn occupied>0**

Trong `apps/wms/src/put-away-suggestion/put-away-suggestion.service.ts`, sửa phần gọi song song trong `suggest()` (ngay sau đoạn gọi `findOccupiedVolumeByWarehouse`):

```typescript
    const [occupiedByShelf, shelfIdsWithSameSku] = await Promise.all([
      this.stockRepo.findOccupiedVolumeByWarehouse(
        new Types.ObjectId(warehouseId),
      ),
      this.stockRepo.findShelfIdsWithItem(
        item._id,
        new Types.ObjectId(warehouseId),
      ),
    ]);
```

Xoá dòng gọi `findOccupiedVolumeByWarehouse` riêng lẻ trước đó, và sửa dòng gán `hasSameSku` trong vòng lặp:

```typescript
      hasSameSku: shelfIdsWithSameSku.has(shelf._id.toString()),
```

(thay cho `hasSameSku: occupiedByShelf.has(...) && occupied > 0`).

- [ ] **Step 6: Cập nhật mock trong `put-away-suggestion.service.spec.ts`**

Thêm `findShelfIdsWithItem: jest.fn()` vào `makeStockRepo()` ở đầu file, và trong mỗi test đã viết ở Task 4 (Step 11, 13, 15) thêm dòng `stockRepo.findShelfIdsWithItem.mockResolvedValue(new Set([shelfSameSku._id.toString()]))` (cho test SKU-affinity) hoặc `.mockResolvedValue(new Set())` (cho các test còn lại, đã có sẵn trong code mẫu ở Task 4).

- [ ] **Step 7: Chạy toàn bộ test put-away-suggestion + stock**

Run: `pnpm test -- put-away-suggestion.service.spec.ts stock.repository.spec.ts`
Expected: PASS toàn bộ.

- [ ] **Step 8: Build để xác nhận không lỗi type**

Run: `pnpm build`
Expected: build thành công.

- [ ] **Step 9: Commit**

```bash
git add apps/wms/src/stock/stock.repository.ts apps/wms/src/stock/stock.repository.spec.ts apps/wms/src/put-away-suggestion/put-away-suggestion.service.ts apps/wms/src/put-away-suggestion/put-away-suggestion.service.spec.ts
git commit -m "fix(wms/put-away-suggestion): dùng findShelfIdsWithItem thay vì suy diễn occupied>0 cho SKU-affinity"
```

---

### Task 6: `PutAwaySuggestionController` + `PutAwaySuggestionModule` — nối endpoint HTTP

**Files:**
- Create: `apps/wms/src/put-away-suggestion/put-away-suggestion.controller.ts`
- Create: `apps/wms/src/put-away-suggestion/put-away-suggestion.module.ts`
- Modify: `apps/wms/src/app.module.ts` (import module mới)

**Interfaces:**
- Consumes: `PutAwaySuggestionService.suggest(sku, qty, warehouseId)` (Task 4/5), `QueryPutAwaySuggestionDto`/`PutAwaySuggestionResponseDto` (Task 4).
- Produces: `GET /api/wms/putaway/suggestions?sku=&qty=&warehouseId=` — endpoint HTTP cuối cùng người dùng gọi.

- [ ] **Step 1: Tạo controller**

Tạo `apps/wms/src/put-away-suggestion/put-away-suggestion.controller.ts`:

```typescript
import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import { JwtAuthGuard, Roles, RolesGuard, WmsRole } from '@app/auth';
import { plainToInstance } from 'class-transformer';
import { PutAwaySuggestionService } from './put-away-suggestion.service';
import {
  PutAwaySuggestionResponseDto,
  QueryPutAwaySuggestionDto,
} from './dto/put-away-suggestion.dto';

const TO_OPTS = { excludeExtraneousValues: true } as const;

@ApiTags('put-away-suggestion')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard, RolesGuard)
@Controller('putaway/suggestions')
export class PutAwaySuggestionController {
  constructor(private readonly svc: PutAwaySuggestionService) {}

  @Get()
  @Roles(WmsRole.RECEIVER, WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({
    summary:
      'Gợi ý vị trí put-away theo thể tích (advisory) — [RECEIVER, MANAGER, ADMIN]',
  })
  @ApiOkResponse({ type: PutAwaySuggestionResponseDto })
  async suggest(
    @Query() query: QueryPutAwaySuggestionDto,
  ): Promise<PutAwaySuggestionResponseDto> {
    const result = await this.svc.suggest(
      query.sku,
      query.qty,
      query.warehouseId,
    );
    return plainToInstance(PutAwaySuggestionResponseDto, result, TO_OPTS);
  }
}
```

- [ ] **Step 2: Tạo module**

Tạo `apps/wms/src/put-away-suggestion/put-away-suggestion.module.ts`:

```typescript
import { Module } from '@nestjs/common';
import { PutAwaySuggestionController } from './put-away-suggestion.controller';
import { PutAwaySuggestionService } from './put-away-suggestion.service';
import { StockModule } from '../stock/stock.module';
import { WarehouseModule } from '../warehouse/warehouse.module';

@Module({
  imports: [
    StockModule, // StockRepository: findItemBySku, findOccupiedVolumeByWarehouse, findShelfIdsWithItem
    WarehouseModule, // WarehouseRepository: findShelvesByWarehouse
  ],
  controllers: [PutAwaySuggestionController],
  providers: [PutAwaySuggestionService],
})
export class PutAwaySuggestionModule {}
```

- [ ] **Step 3: Import module vào `AppModule`**

Đọc `apps/wms/src/app.module.ts`, tìm dòng import `PutAwayModule` (đã có sẵn từ S2-04) và thêm ngay cạnh:

```typescript
import { PutAwaySuggestionModule } from './put-away-suggestion/put-away-suggestion.module';
```

Thêm `PutAwaySuggestionModule` vào mảng `imports` của `@Module({...})`, cùng chỗ với `PutAwayModule`.

- [ ] **Step 4: Build toàn bộ app WMS**

Run: `pnpm build`
Expected: build thành công, không lỗi resolve module/DI.

- [ ] **Step 5: Chạy toàn bộ test suite của app WMS**

Run: `pnpm test -- apps/wms`
Expected: PASS toàn bộ (không phá bất kỳ test hiện có nào).

- [ ] **Step 6: Khởi động app, gọi thử endpoint bằng tay (smoke test)**

Run: `pnpm start:wms` (chạy nền hoặc terminal riêng), sau đó dùng Swagger UI tại `http://localhost:3001/api/docs` (hoặc endpoint Swagger đã cấu hình trong `main.ts`) để:
1. Login lấy JWT (role RECEIVER/MANAGER/ADMIN).
2. Gọi `GET /api/wms/putaway/suggestions?sku=<sku có thật trong DB dev>&qty=5&warehouseId=<id kho thật>`.
3. Xác nhận response có shape `{ suggestions: [...], warning: null | string }`.

Nếu DB dev chưa có item nào khai `depth/width/height`, tạo thử 1 item qua `POST /api/wms/stock/items` với 3 field mới, rồi gọi lại suggestions để thấy `warning: 'ITEM_NO_DIMENSIONS'` chuyển thành có `suggestions` sau khi khai đủ kích thước và có shelf phù hợp.

- [ ] **Step 7: Commit**

```bash
git add apps/wms/src/put-away-suggestion/put-away-suggestion.controller.ts apps/wms/src/put-away-suggestion/put-away-suggestion.module.ts apps/wms/src/app.module.ts
git commit -m "feat(wms/put-away-suggestion): expose GET /putaway/suggestions endpoint"
```

---

### Task 7: `PUTAWAY_DEFAULT_FILL_FACTOR` env var + validate Zod

**Files:**
- Modify: `apps/wms/src/config/env.validation.ts`
- Modify: `.env.example`

**Interfaces:**
- Produces: `process.env.PUTAWAY_DEFAULT_FILL_FACTOR` — đọc qua `ConfigService.get<number>('PUTAWAY_DEFAULT_FILL_FACTOR')` trong `PutAwaySuggestionService` (Task 4), mặc định `0.75` nếu không set.

- [ ] **Step 1: Thêm field vào Zod schema**

Trong `apps/wms/src/config/env.validation.ts`, thêm vào `envSchema` (ngay trước `WMS_PORT`):

```typescript
  // Fill factor mặc định khi Shelf.fillFactor = null — dùng cho gợi ý put-away (S2-05).
  PUTAWAY_DEFAULT_FILL_FACTOR: z.coerce
    .number()
    .min(0)
    .max(1)
    .default(0.75),
```

- [ ] **Step 2: Thêm vào `.env.example`**

Trong `.env.example`, thêm sau block `# ---- Ports ----` (hoặc tạo block mới `# ---- Put-away suggestion ----` trước phần VNPay):

```
# ---- Put-away suggestion (S2-05) ----
# Hệ số lấp đầy mặc định khi Shelf.fillFactor không khai (0–1).
PUTAWAY_DEFAULT_FILL_FACTOR=0.75
```

- [ ] **Step 3: Build để xác nhận Zod schema hợp lệ**

Run: `pnpm build`
Expected: build thành công.

- [ ] **Step 4: Khởi động app để xác nhận env validate qua**

Run: `pnpm start:wms` (nếu `.env` local chưa có `PUTAWAY_DEFAULT_FILL_FACTOR`, xác nhận app vẫn khởi động bình thường nhờ `.default(0.75)` trong Zod schema — không cần set thủ công).
Expected: app khởi động không lỗi "Biến môi trường không hợp lệ".

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/config/env.validation.ts .env.example
git commit -m "feat(wms/config): thêm PUTAWAY_DEFAULT_FILL_FACTOR cho gợi ý put-away"
```

---

## Self-Review (đã chạy trước khi giao plan)

**1. Spec coverage:**
- 3 field kích thước `WarehouseItem` → Task 1. ✓
- Ràng buộc 3 chiều (xoay 90°) → Task 4 `fits()`. ✓
- Occupied động từ `InventoryStock` → Task 3. ✓
- Free/capacity theo `fillFactor` → Task 4 `suggest()`. ✓
- Xếp hạng SKU-affinity → best-fit → Task 4 + Task 5 (`findShelfIdsWithItem`). ✓
- Fallback tổ hợp nhiều shelf + `INSUFFICIENT_CAPACITY` → Task 4 `combineShelves()`. ✓
- `GET /putaway/suggestions?sku=&qty=&warehouseId=` → Task 6. ✓
- Item/shelf thiếu kích thước → bỏ qua/warning → Task 4 (`ITEM_NO_DIMENSIONS`), Task 2 (loại shelf thiếu kích thước ở query). ✓
- `fillFactor` mặc định hệ thống qua env → Task 7. ✓
- Roles RECEIVER/MANAGER/ADMIN + Swagger summary → Task 6. ✓

**2. Placeholder scan:** Không còn "TBD"/"tương tự Task N" — mọi step có code đầy đủ. Task 5 ghi chú rõ thứ tự triển khai thực tế (phát sinh giữa chừng Task 4) thay vì giả vờ đã biết trước — đây là quyết định thiết kế thật (aggregate Task 3 gộp mọi SKU nên cần method riêng để tách SKU-affinity), không phải placeholder.

**3. Type consistency:** `PutAwaySuggestionResult`/`PutAwaySuggestionItem`/`PutAwaySuggestionWarning` dùng nhất quán Task 4 → Task 6 (response DTO). `findShelvesByWarehouse` (Task 2), `findOccupiedVolumeByWarehouse` + `findShelfIdsWithItem` (Task 3, 5) dùng đúng tên/signature ở Task 4/5 nơi gọi. `CreateWarehouseItemData` (Task 1) không được `PutAwaySuggestionService` dùng trực tiếp — chỉ `WarehouseItem` document (qua `findItemBySku`, đã `.lean()`) — khớp với cách Task 4 truy cập `item.depth/width/height` (plain object, không phải Mongoose document methods).
