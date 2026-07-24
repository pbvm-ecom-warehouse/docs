# S1-04: Warehouse Item Create Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Đóng gap "không có API tạo mới WarehouseItem" bằng cách thêm `POST /api/wms/stock/items`, và chặn `PurchaseOrder.createPurchaseOrder` nhận `itemId` không tồn tại/đã bị soft-delete.

**Architecture:** Thêm controller đầu tiên cho `StockModule` (hiện chỉ có service/repository, không HTTP layer) theo đúng pattern `purchase-order.controller.ts` (`@UseGuards(JwtAuthGuard, RolesGuard)`, `@CurrentUser('sub')`, `plainToInstance` + `TO_OPTS`). Thêm 2 method mới vào `StockRepository`/`StockService` để tạo item + check trùng sku. Thêm validate itemId vào `PurchaseOrderService.createPurchaseOrder` bằng cách import `StockModule` vào `PurchaseOrderModule` và inject `StockRepository`.

**Tech Stack:** NestJS, Mongoose (`@nestjs/mongoose`), `class-validator`/`class-transformer`, Jest.

## Global Constraints

- Service **không** được throw NestJS exception thô (`NotFoundException`, `ConflictException`...) — chỉ `AppException('CODE')` từ `@app/common`.
- Response DTO dùng `@Expose()` + `plainToInstance(..., { excludeExtraneousValues: true })`; field `_id` map ra `id` bằng `@Transform`.
- Mọi field enum trong DTO phải có `enum: XxxEnum` trong `@ApiProperty`.
- Mọi `@Roles(...)` phải ghi `— [ROLE1, ROLE2]` vào `@ApiOperation({ summary })`.
- Cấm `any` — kể cả implicit any từ destructuring; `@Transform` callback phải type rõ `obj`.
- Giữ comment tiếng Việt theo phong cách hiện có trong mỗi file.
- Danh mục lỗi domain WMS nằm ở `apps/wms/src/common/error-codes.ts` (`WMS_ERRORS`), không thêm vào `libs/common`.

---

## File Structure

- Modify: `apps/wms/src/stock/stock.repository.ts` — thêm `findItemBySku`, `createItem`.
- Modify: `apps/wms/src/stock/stock.repository.spec.ts` — test 2 method mới.
- Modify: `apps/wms/src/stock/stock.service.ts` — thêm `createWarehouseItem`.
- Create: `apps/wms/src/stock/stock.service.spec.ts` — test toàn bộ `StockService` (chưa có file này).
- Create: `apps/wms/src/stock/dto/create-warehouse-item.dto.ts` — request DTO + nested `AltUnitDto`/`ItemAttributeDto`.
- Create: `apps/wms/src/stock/dto/warehouse-item.response.dto.ts` — response DTO + nested response DTO.
- Create: `apps/wms/src/stock/stock.controller.ts` — `POST /stock/items`.
- Modify: `apps/wms/src/stock/stock.module.ts` — đăng ký `StockController`.
- Modify: `apps/wms/src/common/error-codes.ts` — thêm `STOCK_ITEM_SKU_CONFLICT`.
- Modify: `apps/wms/src/purchase-order/purchase-order.service.ts` — validate itemId trong `createPurchaseOrder`.
- Modify: `apps/wms/src/purchase-order/purchase-order.service.spec.ts` — test validate mới.
- Modify: `apps/wms/src/purchase-order/purchase-order.module.ts` — import `StockModule`.

---

### Task 1: Error code mới `STOCK_ITEM_SKU_CONFLICT`

**Files:**
- Modify: `apps/wms/src/common/error-codes.ts`

**Interfaces:**
- Produces: `WMS_ERRORS.STOCK_ITEM_SKU_CONFLICT` — dùng bởi Task 3 (`StockService.createWarehouseItem`).

- [ ] **Step 1: Thêm error code vào catalog**

Trong `apps/wms/src/common/error-codes.ts`, thêm entry mới vào object `WMS_ERRORS` (ngay sau `STOCK_ITEM_NOT_FOUND`):

```ts
  STOCK_ITEM_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy mặt hàng trong kho',
  },
  STOCK_ITEM_SKU_CONFLICT: {
    status: HttpStatus.CONFLICT,
    message: 'SKU đã tồn tại trong hệ thống',
  },
```

- [ ] **Step 2: Build để kiểm tra type-check**

Run: `pnpm build`
Expected: build thành công, không lỗi TypeScript.

- [ ] **Step 3: Commit**

```bash
git add apps/wms/src/common/error-codes.ts
git commit -m "feat(wms/stock): thêm error code STOCK_ITEM_SKU_CONFLICT"
```

---

### Task 2: `StockRepository.findItemBySku` + `createItem`

**Files:**
- Modify: `apps/wms/src/stock/stock.repository.ts`
- Modify: `apps/wms/src/stock/stock.repository.spec.ts`

**Interfaces:**
- Consumes: `WarehouseItem` schema hiện có (`sku`, `barcode`, `altBarcodes`, `name`, `type`, `unit`, `altUnits`, `attributes`, `isPerishable`, `nearExpiryDays`) từ `apps/wms/src/stock/schemas/warehouse-item.schema.ts`.
- Produces:
  - `findItemBySku(sku: string): Promise<WarehouseItem | null>` (lean object) — dùng bởi Task 3.
  - `createItem(data: CreateWarehouseItemData, createdBy: Types.ObjectId): Promise<WarehouseItemDocument>` — dùng bởi Task 3. `CreateWarehouseItemData` = `{ sku: string; barcode？: string; altBarcodes?: string[]; name: string; type: ItemType; unit: string; altUnits?: {unit:string;factor:number}[]; attributes?: {name:string;value:string;code:string}[]; isPerishable?: boolean; nearExpiryDays?: number }`.

- [ ] **Step 1: Viết test thất bại cho `findItemBySku`**

Thêm vào `apps/wms/src/stock/stock.repository.spec.ts`, sau block `describe('findItemByBarcode', ...)`:

```ts
  describe('findItemBySku', () => {
    it('gọi findOne với sku và trả về item', async () => {
      warehouseItemModel.exec.mockResolvedValueOnce({ sku: 'SKU-1' });
      const result = await repo.findItemBySku('SKU-1');
      expect(warehouseItemModel.findOne).toHaveBeenCalledWith({
        sku: 'SKU-1',
      });
      expect(result).toEqual({ sku: 'SKU-1' });
    });

    it('trả về null khi không tìm thấy', async () => {
      warehouseItemModel.exec.mockResolvedValueOnce(null);
      const result = await repo.findItemBySku('SKU-X');
      expect(result).toBeNull();
    });
  });

  describe('createItem', () => {
    it('gọi create với data + createdBy, isActive mặc định true', async () => {
      const createdBy = new Types.ObjectId();
      const data = {
        sku: 'SKU-1',
        name: 'Ly nhựa 500ml',
        type: 'CUP_BLANK' as const,
        unit: 'cái',
      };
      const mockDoc = { _id: new Types.ObjectId(), ...data };
      warehouseItemModel.create.mockResolvedValueOnce([mockDoc]);
      const result = await repo.createItem(data, createdBy);
      expect(warehouseItemModel.create).toHaveBeenCalledWith([
        { ...data, createdBy, isActive: true },
      ]);
      expect(result).toBe(mockDoc);
    });
  });
```

- [ ] **Step 2: Chạy test để xác nhận fail**

Run: `pnpm test -- stock.repository.spec.ts`
Expected: FAIL — `repo.findItemBySku is not a function`, `repo.createItem is not a function`.

- [ ] **Step 3: Implement `findItemBySku` và `createItem` trong repository**

Trong `apps/wms/src/stock/stock.repository.ts`, thêm import `ItemType` và type export:

```ts
import { ItemType, WarehouseItem, WarehouseItemDocument } from './schemas/warehouse-item.schema';
```

(Sửa lại dòng import hiện có `import { WarehouseItem } from './schemas/warehouse-item.schema';` thành dòng trên.)

Thêm type mới ngay dưới `InsertMovementData`:

```ts
export type CreateWarehouseItemData = {
  sku: string;
  barcode?: string;
  altBarcodes?: string[];
  name: string;
  type: ItemType;
  unit: string;
  altUnits?: { unit: string; factor: number }[];
  attributes?: { name: string; value: string; code: string }[];
  isPerishable?: boolean;
  nearExpiryDays?: number;
};
```

Thêm 2 method vào cuối class `StockRepository` (trước dấu `}` đóng class):

```ts
  /** Tra WarehouseItem theo sku — dùng khi tạo mới để chặn trùng sku (kể cả đã soft-delete). */
  findItemBySku(sku: string) {
    return this.itemModel.findOne({ sku }).lean().exec();
  }

  /** Tạo mới WarehouseItem (master data). isActive mặc định true. */
  async createItem(
    data: CreateWarehouseItemData,
    createdBy: Types.ObjectId,
  ): Promise<WarehouseItemDocument> {
    const [doc] = await this.itemModel.create([
      { ...data, createdBy, isActive: true },
    ]);
    return doc;
  }
```

- [ ] **Step 4: Chạy test để xác nhận pass**

Run: `pnpm test -- stock.repository.spec.ts`
Expected: PASS — toàn bộ test trong file, bao gồm 4 test mới.

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/stock.repository.ts apps/wms/src/stock/stock.repository.spec.ts
git commit -m "feat(wms/stock): thêm findItemBySku + createItem vào StockRepository"
```

---

### Task 3: `StockService.createWarehouseItem`

**Files:**
- Modify: `apps/wms/src/stock/stock.service.ts`
- Create: `apps/wms/src/stock/stock.service.spec.ts`

**Interfaces:**
- Consumes: `StockRepository.findItemBySku`, `StockRepository.createItem`, `CreateWarehouseItemData` (Task 2); `AppException` từ `@app/common`.
- Produces: `StockService.createWarehouseItem(data: CreateWarehouseItemData, actorId: string): Promise<WarehouseItemDocument>` — dùng bởi Task 5 (controller).

- [ ] **Step 1: Viết test thất bại**

Tạo file mới `apps/wms/src/stock/stock.service.spec.ts`:

```ts
import { Types } from 'mongoose';
import { StockService } from './stock.service';

const makeRepo = () => ({
  findSkuById: jest.fn(),
  findItemBySku: jest.fn(),
  createItem: jest.fn(),
});

const makeQueue = () => ({
  add: jest.fn(),
});

describe('StockService', () => {
  let svc: StockService;
  let repo: ReturnType<typeof makeRepo>;
  let queue: ReturnType<typeof makeQueue>;

  beforeEach(() => {
    repo = makeRepo();
    queue = makeQueue();
    svc = new StockService(repo as never, queue as never);
  });

  describe('createWarehouseItem', () => {
    const actorId = new Types.ObjectId().toString();
    const dto = {
      sku: 'SKU-1',
      name: 'Ly nhựa 500ml',
      type: 'CUP_BLANK' as const,
      unit: 'cái',
    };

    it('throw STOCK_ITEM_SKU_CONFLICT khi sku đã tồn tại', async () => {
      repo.findItemBySku.mockResolvedValue({ sku: 'SKU-1' });
      await expect(
        svc.createWarehouseItem(dto, actorId),
      ).rejects.toMatchObject({ code: 'STOCK_ITEM_SKU_CONFLICT' });
      expect(repo.createItem).not.toHaveBeenCalled();
    });

    it('throw STOCK_ITEM_SKU_CONFLICT khi sku trùng với bản ghi đã soft-delete', async () => {
      repo.findItemBySku.mockResolvedValue({
        sku: 'SKU-1',
        deletedAt: new Date(),
      });
      await expect(
        svc.createWarehouseItem(dto, actorId),
      ).rejects.toMatchObject({ code: 'STOCK_ITEM_SKU_CONFLICT' });
    });

    it('tạo item mới khi sku chưa tồn tại', async () => {
      repo.findItemBySku.mockResolvedValue(null);
      const mockDoc = { _id: new Types.ObjectId(), ...dto };
      repo.createItem.mockResolvedValue(mockDoc);

      const result = await svc.createWarehouseItem(dto, actorId);

      expect(repo.createItem).toHaveBeenCalledWith(
        dto,
        new Types.ObjectId(actorId),
      );
      expect(result).toBe(mockDoc);
    });
  });
});
```

- [ ] **Step 2: Chạy test để xác nhận fail**

Run: `pnpm test -- stock.service.spec.ts`
Expected: FAIL — `svc.createWarehouseItem is not a function`.

- [ ] **Step 3: Implement `createWarehouseItem` trong service**

Trong `apps/wms/src/stock/stock.service.ts`, thêm import ở đầu file:

```ts
import { AppException } from '@app/common';
import { Types } from 'mongoose';
import type { CreateWarehouseItemData } from './stock.repository';
import type { WarehouseItemDocument } from './schemas/warehouse-item.schema';
```

Thêm method vào cuối class `StockService` (sau `publishAvailableForItem`):

```ts
  /** Tạo WarehouseItem mới. Chặn trùng sku kể cả với bản ghi đã soft-delete. */
  async createWarehouseItem(
    data: CreateWarehouseItemData,
    actorId: string,
  ): Promise<WarehouseItemDocument> {
    const existing = await this.stockRepo.findItemBySku(data.sku);
    if (existing) {
      throw new AppException('STOCK_ITEM_SKU_CONFLICT');
    }
    return this.stockRepo.createItem(data, new Types.ObjectId(actorId));
  }
```

- [ ] **Step 4: Chạy test để xác nhận pass**

Run: `pnpm test -- stock.service.spec.ts`
Expected: PASS — 3 test.

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/stock.service.ts apps/wms/src/stock/stock.service.spec.ts
git commit -m "feat(wms/stock): thêm StockService.createWarehouseItem"
```

---

### Task 4: DTO request/response cho tạo WarehouseItem

**Files:**
- Create: `apps/wms/src/stock/dto/create-warehouse-item.dto.ts`
- Create: `apps/wms/src/stock/dto/warehouse-item.response.dto.ts`

**Interfaces:**
- Consumes: `ItemType` enum từ `apps/wms/src/stock/schemas/warehouse-item.schema.ts`.
- Produces: `CreateWarehouseItemDto`, `AltUnitDto`, `ItemAttributeDto` (request); `WarehouseItemResponseDto`, `AltUnitResponseDto`, `ItemAttributeResponseDto` (response) — dùng bởi Task 5 (controller).

- [ ] **Step 1: Tạo request DTO**

Tạo `apps/wms/src/stock/dto/create-warehouse-item.dto.ts`:

```ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  IsArray,
  IsBoolean,
  IsEnum,
  IsInt,
  IsOptional,
  IsString,
  Min,
  MinLength,
  ValidateNested,
} from 'class-validator';
import { ItemType } from '../schemas/warehouse-item.schema';

export class AltUnitDto {
  @ApiProperty({ example: 'thùng' })
  @IsString()
  @MinLength(1)
  unit!: string;

  @ApiProperty({ example: 24, description: '1 altUnit = factor * đơn vị cơ sở' })
  @IsInt()
  @Min(1)
  factor!: number;
}

export class ItemAttributeDto {
  @ApiProperty({ example: 'Màu' })
  @IsString()
  @MinLength(1)
  name!: string;

  @ApiProperty({ example: 'Đỏ' })
  @IsString()
  @MinLength(1)
  value!: string;

  @ApiProperty({ example: 'COLOR' })
  @IsString()
  @MinLength(1)
  code!: string;
}

export class CreateWarehouseItemDto {
  @ApiProperty({ example: 'CUP-500ML-RED' })
  @IsString()
  @MinLength(1)
  sku!: string;

  @ApiPropertyOptional({ example: '8938501234567' })
  @IsOptional()
  @IsString()
  barcode?: string;

  @ApiPropertyOptional({ type: [String], example: ['8938501234567'] })
  @IsOptional()
  @IsArray()
  @IsString({ each: true })
  altBarcodes?: string[];

  @ApiProperty({ example: 'Ly nhựa 500ml' })
  @IsString()
  @MinLength(1)
  name!: string;

  @ApiProperty({ enum: ItemType, example: ItemType.CUP_BLANK })
  @IsEnum(ItemType)
  type!: ItemType;

  @ApiProperty({ example: 'cái' })
  @IsString()
  @MinLength(1)
  unit!: string;

  @ApiPropertyOptional({ type: [AltUnitDto] })
  @IsOptional()
  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => AltUnitDto)
  altUnits?: AltUnitDto[];

  @ApiPropertyOptional({ type: [ItemAttributeDto] })
  @IsOptional()
  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => ItemAttributeDto)
  attributes?: ItemAttributeDto[];

  @ApiPropertyOptional({ example: false })
  @IsOptional()
  @IsBoolean()
  isPerishable?: boolean;

  @ApiPropertyOptional({ example: 7 })
  @IsOptional()
  @IsInt()
  @Min(0)
  nearExpiryDays?: number;
}
```

- [ ] **Step 2: Tạo response DTO**

Tạo `apps/wms/src/stock/dto/warehouse-item.response.dto.ts`:

```ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Expose, Transform, Type } from 'class-transformer';
import { Types } from 'mongoose';
import { ItemType } from '../schemas/warehouse-item.schema';

export class AltUnitResponseDto {
  @Expose()
  @ApiProperty()
  unit!: string;

  @Expose()
  @ApiProperty()
  factor!: number;
}

export class ItemAttributeResponseDto {
  @Expose()
  @ApiProperty()
  name!: string;

  @Expose()
  @ApiProperty()
  value!: string;

  @Expose()
  @ApiProperty()
  code!: string;
}

export class WarehouseItemResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) =>
    obj._id?.toString(),
  )
  @ApiProperty()
  id!: string;

  @Expose()
  @ApiProperty()
  sku!: string;

  @Expose()
  @ApiPropertyOptional()
  barcode?: string;

  @Expose()
  @ApiProperty({ type: [String] })
  altBarcodes!: string[];

  @Expose()
  @ApiProperty()
  name!: string;

  @Expose()
  @ApiProperty({ enum: ItemType })
  type!: ItemType;

  @Expose()
  @ApiProperty()
  unit!: string;

  @Expose()
  @Type(() => AltUnitResponseDto)
  @ApiProperty({ type: [AltUnitResponseDto] })
  altUnits!: AltUnitResponseDto[];

  @Expose()
  @Type(() => ItemAttributeResponseDto)
  @ApiProperty({ type: [ItemAttributeResponseDto] })
  attributes!: ItemAttributeResponseDto[];

  @Expose()
  @ApiProperty()
  isPerishable!: boolean;

  @Expose()
  @ApiPropertyOptional()
  nearExpiryDays?: number;

  @Expose()
  @ApiProperty()
  isActive!: boolean;

  @Expose()
  @ApiProperty()
  createdAt!: Date;

  @Expose()
  @ApiProperty()
  updatedAt!: Date;
}
```

- [ ] **Step 3: Build để kiểm tra type-check**

Run: `pnpm build`
Expected: build thành công, không lỗi TypeScript/ESLint (`no-explicit-any` không vi phạm vì không dùng `any`).

- [ ] **Step 4: Commit**

```bash
git add apps/wms/src/stock/dto/create-warehouse-item.dto.ts apps/wms/src/stock/dto/warehouse-item.response.dto.ts
git commit -m "feat(wms/stock): thêm DTO request/response cho tạo WarehouseItem"
```

---

### Task 5: `StockController` — `POST /stock/items`

**Files:**
- Create: `apps/wms/src/stock/stock.controller.ts`
- Modify: `apps/wms/src/stock/stock.module.ts`

**Interfaces:**
- Consumes: `StockService.createWarehouseItem` (Task 3), `CreateWarehouseItemDto`/`WarehouseItemResponseDto` (Task 4), `JwtAuthGuard`/`RolesGuard`/`Roles`/`CurrentUser`/`WmsRole` từ `@app/auth`.
- Produces: `POST /api/wms/stock/items` — route thật, không có task nào sau phụ thuộc vào nó về mặt code.

- [ ] **Step 1: Tạo controller**

Tạo `apps/wms/src/stock/stock.controller.ts`:

```ts
// apps/wms/src/stock/stock.controller.ts
import { Body, Controller, Post, UseGuards } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiCreatedResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  CurrentUser,
  JwtAuthGuard,
  Roles,
  RolesGuard,
  WmsRole,
} from '@app/auth';
import { plainToInstance } from 'class-transformer';
import { StockService } from './stock.service';
import { CreateWarehouseItemDto } from './dto/create-warehouse-item.dto';
import { WarehouseItemResponseDto } from './dto/warehouse-item.response.dto';

const TO_OPTS = { excludeExtraneousValues: true } as const;

@ApiTags('stock')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard, RolesGuard)
@Controller('stock/items')
export class StockController {
  constructor(private readonly svc: StockService) {}

  @Post()
  @Roles(WmsRole.ADMIN, WmsRole.MANAGER)
  @ApiOperation({ summary: 'Tạo mặt hàng kho mới — [ADMIN, MANAGER]' })
  @ApiCreatedResponse({ type: WarehouseItemResponseDto })
  async create(
    @Body() dto: CreateWarehouseItemDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<WarehouseItemResponseDto> {
    const doc = await this.svc.createWarehouseItem(dto, actorId);
    return plainToInstance(WarehouseItemResponseDto, doc.toObject(), TO_OPTS);
  }
}
```

- [ ] **Step 2: Đăng ký controller vào module**

Trong `apps/wms/src/stock/stock.module.ts`, thêm import:

```ts
import { StockController } from './stock.controller';
```

Sửa decorator `@Module` thêm `controllers`:

```ts
@Module({
  imports: [
    BullModule.registerQueue({ name: QUEUES.STOCK }),
    MongooseModule.forFeature([
      { name: WarehouseItem.name, schema: WarehouseItemSchema },
      { name: StockBalance.name, schema: StockBalanceSchema },
      { name: InventoryStock.name, schema: InventoryStockSchema },
      { name: Lot.name, schema: LotSchema },
      { name: StockMovement.name, schema: StockMovementSchema },
    ]),
  ],
  controllers: [StockController],
  providers: [StockRepository, StockService, StockTransactionHelper],
  exports: [StockService, StockTransactionHelper, StockRepository],
})
export class StockModule {}
```

- [ ] **Step 3: Build để kiểm tra type-check**

Run: `pnpm build`
Expected: build thành công.

- [ ] **Step 4: Chạy toàn bộ test suite của app wms để xác nhận không có regressive**

Run: `pnpm test -- apps/wms`
Expected: PASS — toàn bộ test trong `apps/wms`.

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/stock.controller.ts apps/wms/src/stock/stock.module.ts
git commit -m "feat(wms/stock): thêm endpoint POST /stock/items tạo WarehouseItem"
```

---

### Task 6: Validate `itemId` trong `PurchaseOrderService.createPurchaseOrder`

**Files:**
- Modify: `apps/wms/src/purchase-order/purchase-order.service.ts`
- Modify: `apps/wms/src/purchase-order/purchase-order.service.spec.ts`
- Modify: `apps/wms/src/purchase-order/purchase-order.module.ts`

**Interfaces:**
- Consumes: `StockRepository.findItemById(itemId: string): Promise<(WarehouseItem & { deletedAt?: Date | null }) | null>` (đã tồn tại, không đổi signature).
- Produces: `createPurchaseOrder` throw `AppException('STOCK_ITEM_NOT_FOUND')` khi item không hợp lệ — không có task nào sau phụ thuộc.

- [ ] **Step 1: Import `StockModule` vào `PurchaseOrderModule`**

Trong `apps/wms/src/purchase-order/purchase-order.module.ts`, thêm import và đưa vào `imports`:

```ts
import { StockModule } from '../stock/stock.module';
```

```ts
@Module({
  imports: [
    MongooseModule.forFeature([
      { name: PurchaseOrder.name, schema: PurchaseOrderSchema },
    ]),
    SupplierModule, // assertSupplierActive + getSupplierItemByItemId
    WarehouseModule, // getWarehouse
    StockModule, // findItemById — validate itemId tồn tại khi tạo PO
  ],
  providers: [PurchaseOrderRepository, PurchaseOrderService],
  controllers: [PurchaseOrderController],
  exports: [PurchaseOrderService], // GRN (S2-03) cần applyReceivedQty + getPurchaseOrder
})
export class PurchaseOrderModule {}
```

- [ ] **Step 2: Viết test thất bại**

Trong `apps/wms/src/purchase-order/purchase-order.service.spec.ts`, thêm `stockRepo` vào các factory và constructor ở đầu file. Thay toàn bộ block từ dòng 1 đến dòng 44 (`describe('createPurchaseOrder', ...)`  chưa mở) bằng:

```ts
import { PurchaseOrderService } from './purchase-order.service';

const makeRepo = () => ({
  createPurchaseOrder: jest.fn(),
  findPurchaseOrderById: jest.fn(),
  findPurchaseOrders: jest.fn(),
  countByPoNumberPrefix: jest.fn(),
  findPurchaseOrderByIdWithSession: jest.fn(),
  applyReceivedQtyAndStatus: jest.fn(),
});

const makeSupplierService = () => ({
  assertSupplierActive: jest.fn(),
  getSupplierItemByItemId: jest.fn(),
});

const makeWarehouseService = () => ({
  getWarehouse: jest.fn(),
});

const makeStockRepo = () => ({
  findItemById: jest.fn(),
});

describe('PurchaseOrderService', () => {
  let svc: PurchaseOrderService;
  let repo: ReturnType<typeof makeRepo>;
  let supplierSvc: ReturnType<typeof makeSupplierService>;
  let warehouseSvc: ReturnType<typeof makeWarehouseService>;
  let stockRepo: ReturnType<typeof makeStockRepo>;
  const actorId = 'actor123';
  const supplierId = 'sup001';
  const warehouseId = 'wh001';
  const itemId = 'item001';

  beforeEach(() => {
    repo = makeRepo();
    supplierSvc = makeSupplierService();
    warehouseSvc = makeWarehouseService();
    stockRepo = makeStockRepo();
    svc = new PurchaseOrderService(
      repo as never,
      supplierSvc as never,
      warehouseSvc as never,
      stockRepo as never,
    );
    repo.countByPoNumberPrefix.mockResolvedValue(0);
    warehouseSvc.getWarehouse.mockResolvedValue({ _id: warehouseId });
    supplierSvc.assertSupplierActive.mockResolvedValue(undefined);
    stockRepo.findItemById.mockResolvedValue({ _id: itemId, deletedAt: null });
  });
```

Đây là thay thế toàn bộ phần khai báo `describe('PurchaseOrderService', ...)` cho tới hết `beforeEach` (dòng 1-44 hiện tại). Phần còn lại của file (`describe('createPurchaseOrder', ...)` trở xuống) giữ nguyên, **trừ** việc thêm 2 test case mới ngay sau test `'throw WAREHOUSE_NOT_FOUND khi kho không tồn tại'` (dòng 65-74 hiện tại):

```ts
    it('throw STOCK_ITEM_NOT_FOUND khi itemId không tồn tại', async () => {
      stockRepo.findItemById.mockResolvedValue(null);
      await expect(
        svc.createPurchaseOrder(baseDto as never, actorId),
      ).rejects.toMatchObject({ code: 'STOCK_ITEM_NOT_FOUND' });
      expect(repo.createPurchaseOrder).not.toHaveBeenCalled();
    });

    it('throw STOCK_ITEM_NOT_FOUND khi item đã bị soft-delete', async () => {
      stockRepo.findItemById.mockResolvedValue({
        _id: itemId,
        deletedAt: new Date(),
      });
      await expect(
        svc.createPurchaseOrder(baseDto as never, actorId),
      ).rejects.toMatchObject({ code: 'STOCK_ITEM_NOT_FOUND' });
    });
```

- [ ] **Step 3: Chạy test để xác nhận fail**

Run: `pnpm test -- purchase-order.service.spec.ts`
Expected: FAIL — constructor nhận sai số tham số (`PurchaseOrderService` chưa nhận `stockRepo`), và 2 test mới fail vì validate chưa tồn tại.

- [ ] **Step 4: Implement validate trong service**

Trong `apps/wms/src/purchase-order/purchase-order.service.ts`, sửa import:

```ts
import { StockRepository } from '../stock/stock.repository';
```

Sửa constructor:

```ts
  constructor(
    private readonly repo: PurchaseOrderRepository,
    private readonly supplierService: SupplierService,
    private readonly warehouseService: WarehouseService,
    private readonly stockRepo: StockRepository,
  ) {}
```

Trong `createPurchaseOrder`, ngay đầu vòng lặp `for (const item of dto.items)`, thêm validate trước khi xử lý giá:

```ts
    const resolvedItems: ResolvedPurchaseOrderItem[] = [];
    for (const item of dto.items) {
      // Item phải tồn tại và chưa bị soft-delete — chặn PO tham chiếu SKU "ma"
      const warehouseItem = await this.stockRepo.findItemById(item.itemId);
      if (!warehouseItem || warehouseItem.deletedAt) {
        throw new AppException('STOCK_ITEM_NOT_FOUND');
      }

      let unitPrice = item.unitPrice;
      // ... phần còn lại giữ nguyên
```

(Giữ nguyên toàn bộ logic `unitPrice`/`supplierItem` phía sau, chỉ chèn thêm đoạn validate ở đầu vòng lặp.)

- [ ] **Step 5: Cập nhật `PurchaseOrderModule` provider wiring không cần đổi thêm**

`StockRepository` đã được export qua `StockModule` (`exports: [StockService, StockTransactionHelper, StockRepository]` — xác nhận ở Task 5 Step 2), và `StockModule` đã được import ở Step 1. NestJS DI sẽ tự inject.

- [ ] **Step 6: Chạy test để xác nhận pass**

Run: `pnpm test -- purchase-order.service.spec.ts`
Expected: PASS — toàn bộ test trong file, bao gồm 2 test mới.

- [ ] **Step 7: Chạy toàn bộ test suite + build để xác nhận không regressive**

Run: `pnpm test -- apps/wms && pnpm build`
Expected: PASS toàn bộ, build thành công.

- [ ] **Step 8: Commit**

```bash
git add apps/wms/src/purchase-order/purchase-order.service.ts apps/wms/src/purchase-order/purchase-order.service.spec.ts apps/wms/src/purchase-order/purchase-order.module.ts
git commit -m "fix(wms/purchase-order): chặn tạo PO khi itemId không tồn tại hoặc đã soft-delete"
```

---

## Post-plan verification

- [ ] Run: `pnpm lint` — Expected: 0 lỗi ESLint (đặc biệt `@typescript-eslint/no-explicit-any`, `@typescript-eslint/no-unsafe-member-access`).
- [ ] Run: `pnpm test` — Expected: toàn bộ test suite pass (không chỉ `apps/wms`).
- [ ] Run: `pnpm build` — Expected: build tất cả app thành công.
- [ ] Thủ công: `pnpm start:wms`, mở Swagger (`/api/wms/docs` hoặc path Swagger hiện có), xác nhận `POST /stock/items` xuất hiện với đúng roles `[ADMIN, MANAGER]` trong summary và `enum: ItemType` hiển thị dropdown cho field `type`.
