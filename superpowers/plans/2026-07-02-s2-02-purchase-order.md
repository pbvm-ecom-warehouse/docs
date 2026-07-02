# S2-02: UC-01 Purchase Order Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Thêm module `purchase-order` vào `apps/wms`: tạo PO (validate NCC active, warehouse tồn tại, giá tự điền từ SupplierItem) và xem PO (list + detail).

**Architecture:** Module NestJS mới `apps/wms/src/purchase-order/` theo đúng cấu trúc `supplier/` (schema → repository → service → controller → module). `PurchaseOrderModule` import `SupplierModule` (dùng `assertSupplierActive` + `getSupplierItemByItemId`) và `WarehouseModule` (dùng `getWarehouse`) làm dependency — không đọc chéo DB, chỉ gọi service đã export.

**Tech Stack:** NestJS, Mongoose (`@nestjs/mongoose`), class-validator/class-transformer, Jest.

## Global Constraints

- Service dùng `AppException` từ `@app/common` — không throw NestJS exception thô. Mã lỗi mới đặt trong `libs/common/src/errors/error-codes.ts` (`ERROR_CATALOG`), **KHÔNG** đặt trong `apps/wms/src/common/error-codes.ts` (`WMS_ERRORS`) — `AppException` chỉ fallback status/message từ `ERROR_CATALOG` (xem memory `coding-mistakes-log` mục 2026-07-02).
- Response DTO dùng `@Expose()` + `plainToInstance(..., { excludeExtraneousValues: true })`; `_id` → `id` qua `@Transform`.
- Mọi `@Roles(...)` phải ghi `— [ROLE1, ROLE2]` vào `@ApiOperation summary`. Mọi field enum trong DTO phải có `enum:` trong `@ApiProperty`.
- Cấm `any` kể cả implicit. `@Transform` callback phải type rõ `obj`.
- Chứng từ giao dịch (PurchaseOrder là 1 loại) dùng `@Schema({ timestamps: true })`, KHÔNG soft-delete, hủy bằng `status`.
- Bảng dòng `*Item` (PurchaseOrderItem) không mang audit riêng.
- Comment tiếng Việt giải thích *vì sao*, không giải thích *cái gì*.
- Route base path cuối cùng: `api/wms/purchase-orders` (global prefix `api/wms` đã set ở `main.ts`).

---

### Task 1: Schema `PurchaseOrder` + `PurchaseOrderItem`

**Files:**
- Create: `apps/wms/src/purchase-order/schemas/purchase-order.schema.ts`
- Test: `apps/wms/src/purchase-order/schemas/purchase-order.schema.spec.ts`

**Interfaces:**
- Produces: `PurchaseOrderStatus` enum (`DRAFT`, `CONFIRMED`, `SENT`, `PARTIALLY_RECEIVED`, `COMPLETED`, `CANCELLED`), `PurchaseOrder` class, `PurchaseOrderDocument` type, `PurchaseOrderSchema`, `PurchaseOrderItem` class (sub-document).

- [ ] **Step 1: Viết schema**

```ts
// apps/wms/src/purchase-order/schemas/purchase-order.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

export enum PurchaseOrderStatus {
  DRAFT = 'DRAFT',
  CONFIRMED = 'CONFIRMED',
  SENT = 'SENT',
  PARTIALLY_RECEIVED = 'PARTIALLY_RECEIVED',
  COMPLETED = 'COMPLETED',
  CANCELLED = 'CANCELLED',
}

/** Sub-document: 1 dòng hàng đặt trong PO. Không audit riêng — kế thừa từ PO cha. */
@Schema({ _id: false })
export class PurchaseOrderItem {
  /** WarehouseItem._id */
  @Prop({ type: Types.ObjectId, required: true })
  itemId!: Types.ObjectId;

  /** Denormalized từ WarehouseItem.sku — hiển thị nhanh không cần join */
  @Prop({ required: true })
  sku!: string;

  @Prop({ type: Number, required: true, min: 0 })
  expectedQty!: number;

  /** Đơn vị đặt — có thể là đơn vị phụ (vd "thùng") của WarehouseItem */
  @Prop({ required: true })
  unit!: string;

  /** Giá đặt — mặc định gợi ý từ SupplierItem.purchasePrice, sửa tay được */
  @Prop({ type: Number, required: true, min: 0 })
  unitPrice!: number;
}
const PurchaseOrderItemSchema = SchemaFactory.createForClass(PurchaseOrderItem);

/**
 * Đơn đặt hàng gửi NCC (UC-01). Chứng từ giao dịch — hủy bằng status, KHÔNG soft-delete.
 */
@Schema({ collection: 'purchase_orders', timestamps: true })
export class PurchaseOrder {
  @Prop({ required: true, unique: true })
  poNumber!: string;

  @Prop({ type: Types.ObjectId, required: true })
  supplierId!: Types.ObjectId;

  /** Kho sẽ nhận hàng */
  @Prop({ type: Types.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

  @Prop({ enum: PurchaseOrderStatus, default: PurchaseOrderStatus.CONFIRMED })
  status!: PurchaseOrderStatus;

  @Prop({ type: Date, default: Date.now })
  orderDate!: Date;

  @Prop({ type: Date })
  expectedDate?: Date;

  @Prop()
  note?: string;

  @Prop({ type: [PurchaseOrderItemSchema], required: true })
  items!: PurchaseOrderItem[];

  @Prop({ type: Types.ObjectId })
  createdBy?: Types.ObjectId;
}

export type PurchaseOrderDocument = HydratedDocument<PurchaseOrder>;
export const PurchaseOrderSchema = SchemaFactory.createForClass(PurchaseOrder);
PurchaseOrderSchema.index({ supplierId: 1 });
PurchaseOrderSchema.index({ status: 1 });
```

- [ ] **Step 2: Viết test schema**

```ts
// apps/wms/src/purchase-order/schemas/purchase-order.schema.spec.ts
import { PurchaseOrderStatus, PurchaseOrderSchema } from './purchase-order.schema';

describe('PurchaseOrder schema', () => {
  it('PurchaseOrderStatus enum có đủ 6 giá trị', () => {
    expect(Object.values(PurchaseOrderStatus)).toEqual([
      'DRAFT',
      'CONFIRMED',
      'SENT',
      'PARTIALLY_RECEIVED',
      'COMPLETED',
      'CANCELLED',
    ]);
  });

  it('schema có đủ field cần thiết', () => {
    const paths = PurchaseOrderSchema.paths;
    expect(paths['poNumber']).toBeDefined();
    expect(paths['supplierId']).toBeDefined();
    expect(paths['warehouseId']).toBeDefined();
    expect(paths['status']).toBeDefined();
    expect(paths['items']).toBeDefined();
    expect(paths['createdBy']).toBeDefined();
  });

  it('field poNumber có unique index', () => {
    const poNumberSchema = PurchaseOrderSchema.path('poNumber') as {
      options?: { unique?: boolean };
    };
    expect(poNumberSchema.options?.unique).toBe(true);
  });

  it('status mặc định CONFIRMED', () => {
    const statusSchema = PurchaseOrderSchema.path('status') as {
      options?: { default?: PurchaseOrderStatus };
    };
    expect(statusSchema.options?.default).toBe(PurchaseOrderStatus.CONFIRMED);
  });
});
```

- [ ] **Step 3: Chạy test**

Run: `pnpm test -- purchase-order.schema.spec.ts`
Expected: PASS (4 tests)

- [ ] **Step 4: Commit**

```bash
git add apps/wms/src/purchase-order/schemas/purchase-order.schema.ts apps/wms/src/purchase-order/schemas/purchase-order.schema.spec.ts
git commit -m "feat(wms/purchase-order): thêm schema PurchaseOrder + PurchaseOrderItem"
```

---

### Task 2: Error codes mới trong `ERROR_CATALOG`

**Files:**
- Modify: `libs/common/src/errors/error-codes.ts`

**Interfaces:**
- Produces: `ERROR_CATALOG.PO_PRICE_MISSING`, `ERROR_CATALOG.PO_NOT_FOUND` — dùng ở Task 3.

- [ ] **Step 1: Thêm 2 code vào cuối `ERROR_CATALOG`**

Mở `libs/common/src/errors/error-codes.ts`, thêm nhóm mới ngay sau nhóm `WMS — Supplier` (trước dòng `} as const;`):

```ts
  // ── WMS — Purchase Order ────────────────────────────────────────────────
  PO_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy đơn đặt hàng',
  },
  PO_PRICE_MISSING: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Thiếu đơn giá — SKU chưa có báo giá NCC, cần nhập tay',
  },
```

- [ ] **Step 2: Kiểm tra build không vỡ**

Run: `pnpm build`
Expected: build thành công, không lỗi TypeScript.

- [ ] **Step 3: Commit**

```bash
git add libs/common/src/errors/error-codes.ts
git commit -m "feat(common/errors): thêm PO_NOT_FOUND, PO_PRICE_MISSING vào ERROR_CATALOG"
```

---

### Task 3: DTO request/response

**Files:**
- Create: `apps/wms/src/purchase-order/dto/purchase-order.dto.ts`

**Interfaces:**
- Consumes: `PurchaseOrderStatus` (Task 1)
- Produces: `CreatePurchaseOrderItemDto`, `CreatePurchaseOrderDto`, `QueryPurchaseOrderDto`, `PurchaseOrderItemResponseDto`, `PurchaseOrderResponseDto` — dùng ở Task 4 (service) và Task 6 (controller).

- [ ] **Step 1: Viết DTO**

```ts
// apps/wms/src/purchase-order/dto/purchase-order.dto.ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Expose, Transform, Type } from 'class-transformer';
import {
  ArrayMinSize,
  IsArray,
  IsEnum,
  IsInt,
  IsMongoId,
  IsNumber,
  IsOptional,
  IsString,
  Max,
  Min,
  MinLength,
  ValidateNested,
} from 'class-validator';
import { Types } from 'mongoose';
import { PurchaseOrderStatus } from '../schemas/purchase-order.schema';

export class CreatePurchaseOrderItemDto {
  @ApiProperty({ description: 'WarehouseItem._id (ObjectId)', example: '665f...' })
  @IsMongoId()
  itemId!: string;

  @ApiProperty({ example: 'SKU-001' })
  @IsString()
  @MinLength(1)
  sku!: string;

  @ApiProperty({ example: 100 })
  @IsNumber()
  @Min(0)
  expectedQty!: number;

  @ApiProperty({ example: 'cái' })
  @IsString()
  @MinLength(1)
  unit!: string;

  @ApiPropertyOptional({
    example: 15000,
    description: 'Để trống → tự điền từ SupplierItem.purchasePrice',
  })
  @IsOptional()
  @IsNumber()
  @Min(0)
  unitPrice?: number;
}

export class CreatePurchaseOrderDto {
  @ApiProperty({ description: 'Supplier._id (ObjectId)', example: '665f...' })
  @IsMongoId()
  supplierId!: string;

  @ApiProperty({ description: 'Warehouse._id (ObjectId)', example: '665f...' })
  @IsMongoId()
  warehouseId!: string;

  @ApiPropertyOptional({ description: 'Ngày dự kiến nhận hàng' })
  @IsOptional()
  @IsString()
  expectedDate?: string;

  @ApiPropertyOptional({ example: 'Đặt gấp cho đợt khuyến mãi' })
  @IsOptional()
  @IsString()
  note?: string;

  @ApiProperty({ type: [CreatePurchaseOrderItemDto] })
  @IsArray()
  @ArrayMinSize(1)
  @ValidateNested({ each: true })
  @Type(() => CreatePurchaseOrderItemDto)
  items!: CreatePurchaseOrderItemDto[];
}

export class QueryPurchaseOrderDto {
  @ApiPropertyOptional({ enum: PurchaseOrderStatus })
  @IsOptional()
  @IsEnum(PurchaseOrderStatus)
  status?: PurchaseOrderStatus;

  @ApiPropertyOptional({ description: 'Lọc theo NCC' })
  @IsOptional()
  @IsMongoId()
  supplierId?: string;

  @ApiPropertyOptional({ default: 1, minimum: 1 })
  @IsOptional()
  @IsInt()
  @Min(1)
  page?: number;

  @ApiPropertyOptional({ default: 20, minimum: 1, maximum: 100 })
  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;
}

export class PurchaseOrderItemResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { itemId?: Types.ObjectId } }) => obj.itemId?.toString())
  @ApiProperty()
  itemId!: string;

  @Expose()
  @ApiProperty()
  sku!: string;

  @Expose()
  @ApiProperty()
  expectedQty!: number;

  @Expose()
  @ApiProperty()
  unit!: string;

  @Expose()
  @ApiProperty()
  unitPrice!: number;
}

export class PurchaseOrderResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) => obj._id?.toString())
  @ApiProperty()
  id!: string;

  @Expose()
  @ApiProperty()
  poNumber!: string;

  @Expose()
  @Transform(({ obj }: { obj: { supplierId?: Types.ObjectId } }) => obj.supplierId?.toString())
  @ApiProperty()
  supplierId!: string;

  @Expose()
  @Transform(({ obj }: { obj: { warehouseId?: Types.ObjectId } }) => obj.warehouseId?.toString())
  @ApiProperty()
  warehouseId!: string;

  @Expose()
  @ApiProperty({ enum: PurchaseOrderStatus })
  status!: PurchaseOrderStatus;

  @Expose()
  @ApiProperty()
  orderDate!: Date;

  @Expose()
  @ApiPropertyOptional()
  expectedDate?: Date;

  @Expose()
  @ApiPropertyOptional()
  note?: string;

  @Expose()
  @Type(() => PurchaseOrderItemResponseDto)
  @ApiProperty({ type: [PurchaseOrderItemResponseDto] })
  items!: PurchaseOrderItemResponseDto[];

  @Expose()
  @ApiProperty()
  createdAt!: Date;

  @Expose()
  @ApiProperty()
  updatedAt!: Date;
}
```

- [ ] **Step 2: Kiểm tra build**

Run: `pnpm build`
Expected: build thành công.

- [ ] **Step 3: Commit**

```bash
git add apps/wms/src/purchase-order/dto/purchase-order.dto.ts
git commit -m "feat(wms/purchase-order): thêm DTO Create/Query/Response cho PurchaseOrder"
```

---

### Task 4: `PurchaseOrderRepository`

**Files:**
- Create: `apps/wms/src/purchase-order/purchase-order.repository.ts`
- Test: `apps/wms/src/purchase-order/purchase-order.repository.spec.ts`

**Interfaces:**
- Consumes: `PurchaseOrder`, `PurchaseOrderDocument`, `PurchaseOrderStatus` (Task 1); `CreatePurchaseOrderDto`, `QueryPurchaseOrderDto` (Task 3).
- Produces: `PurchaseOrderRepository` với methods:
  - `createPurchaseOrder(dto: CreatePurchaseOrderDto, poNumber: string, resolvedItems: { itemId: string; sku: string; expectedQty: number; unit: string; unitPrice: number }[], actorId: string): Promise<PurchaseOrderDocument>`
  - `findPurchaseOrderById(id: string): Promise<PurchaseOrderDocument | null>`
  - `findPurchaseOrders(query: QueryPurchaseOrderDto): Promise<{ data: PurchaseOrderDocument[]; total: number }>`
  - `countByPoNumberPrefix(prefix: string): Promise<number>` — hỗ trợ sinh `poNumber` tuần tự trong ngày.

- [ ] **Step 1: Viết test trước (repository)**

```ts
// apps/wms/src/purchase-order/purchase-order.repository.spec.ts
import { getModelToken } from '@nestjs/mongoose';
import { Test } from '@nestjs/testing';
import { Types } from 'mongoose';
import { PurchaseOrderRepository } from './purchase-order.repository';
import { PurchaseOrder, PurchaseOrderStatus } from './schemas/purchase-order.schema';

const makeModel = (overrides: Record<string, jest.Mock> = {}) => ({
  findOne: jest.fn().mockReturnThis(),
  find: jest.fn().mockReturnThis(),
  countDocuments: jest.fn().mockReturnThis(),
  create: jest.fn(),
  sort: jest.fn().mockReturnThis(),
  skip: jest.fn().mockReturnThis(),
  limit: jest.fn().mockReturnThis(),
  exec: jest.fn(),
  ...overrides,
});

describe('PurchaseOrderRepository', () => {
  let repo: PurchaseOrderRepository;
  let model: ReturnType<typeof makeModel>;
  const actorId = new Types.ObjectId().toString();
  const supplierId = new Types.ObjectId().toString();
  const warehouseId = new Types.ObjectId().toString();
  const itemId = new Types.ObjectId().toString();

  beforeEach(async () => {
    model = makeModel();
    const module = await Test.createTestingModule({
      providers: [
        PurchaseOrderRepository,
        { provide: getModelToken(PurchaseOrder.name), useValue: model },
      ],
    }).compile();
    repo = module.get(PurchaseOrderRepository);
    jest.clearAllMocks();
  });

  describe('createPurchaseOrder', () => {
    it('tạo PO với poNumber, status CONFIRMED, items đã resolve giá', async () => {
      model.create.mockResolvedValue({ poNumber: 'PO-20260702-0001' });
      const dto = {
        supplierId,
        warehouseId,
        items: [{ itemId, sku: 'SKU-1', expectedQty: 10, unit: 'cái' }],
      };
      const resolvedItems = [
        { itemId, sku: 'SKU-1', expectedQty: 10, unit: 'cái', unitPrice: 5000 },
      ];
      await repo.createPurchaseOrder(dto as never, 'PO-20260702-0001', resolvedItems, actorId);
      expect(model.create).toHaveBeenCalledWith(
        expect.objectContaining({
          poNumber: 'PO-20260702-0001',
          status: PurchaseOrderStatus.CONFIRMED,
          items: resolvedItems,
        }),
      );
    });
  });

  describe('findPurchaseOrderById', () => {
    it('gọi findOne với _id', async () => {
      model.exec.mockResolvedValue(null);
      await repo.findPurchaseOrderById('po1');
      expect(model.findOne).toHaveBeenCalledWith({ _id: 'po1' });
    });
  });

  describe('findPurchaseOrders', () => {
    it('lọc theo status và supplierId, phân trang mặc định page=1 limit=20', async () => {
      model.exec.mockResolvedValueOnce([]).mockResolvedValueOnce(0);
      await repo.findPurchaseOrders({ status: PurchaseOrderStatus.CONFIRMED, supplierId });
      expect(model.find).toHaveBeenCalledWith({
        status: PurchaseOrderStatus.CONFIRMED,
        supplierId: new Types.ObjectId(supplierId),
      });
      expect(model.skip).toHaveBeenCalledWith(0);
      expect(model.limit).toHaveBeenCalledWith(20);
    });
  });

  describe('countByPoNumberPrefix', () => {
    it('đếm PO theo prefix ngày', async () => {
      model.exec.mockResolvedValue(3);
      const count = await repo.countByPoNumberPrefix('PO-20260702');
      expect(model.countDocuments).toHaveBeenCalledWith({
        poNumber: { $regex: '^PO-20260702' },
      });
      expect(count).toBe(3);
    });
  });
});
```

- [ ] **Step 2: Chạy test, xác nhận fail**

Run: `pnpm test -- purchase-order.repository.spec.ts`
Expected: FAIL — `Cannot find module './purchase-order.repository'`

- [ ] **Step 3: Viết implementation**

```ts
// apps/wms/src/purchase-order/purchase-order.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import {
  PurchaseOrder,
  PurchaseOrderDocument,
  PurchaseOrderStatus,
} from './schemas/purchase-order.schema';
import type { CreatePurchaseOrderDto, QueryPurchaseOrderDto } from './dto/purchase-order.dto';

export interface ResolvedPurchaseOrderItem {
  itemId: string;
  sku: string;
  expectedQty: number;
  unit: string;
  unitPrice: number;
}

@Injectable()
export class PurchaseOrderRepository {
  constructor(
    @InjectModel(PurchaseOrder.name)
    private readonly model: Model<PurchaseOrderDocument>,
  ) {}

  async createPurchaseOrder(
    dto: CreatePurchaseOrderDto,
    poNumber: string,
    resolvedItems: ResolvedPurchaseOrderItem[],
    actorId: string,
  ): Promise<PurchaseOrderDocument> {
    return this.model.create({
      poNumber,
      supplierId: new Types.ObjectId(dto.supplierId),
      warehouseId: new Types.ObjectId(dto.warehouseId),
      status: PurchaseOrderStatus.CONFIRMED,
      expectedDate: dto.expectedDate ? new Date(dto.expectedDate) : undefined,
      note: dto.note,
      // itemId giữ nguyên string — Mongoose tự cast sang ObjectId theo schema khi lưu
      items: resolvedItems,
      createdBy: new Types.ObjectId(actorId),
    });
  }

  async findPurchaseOrderById(id: string): Promise<PurchaseOrderDocument | null> {
    return this.model.findOne({ _id: id }).exec();
  }

  async findPurchaseOrders(
    query: QueryPurchaseOrderDto,
  ): Promise<{ data: PurchaseOrderDocument[]; total: number }> {
    const page = query.page ?? 1;
    const limit = query.limit ?? 20;
    const filter: Record<string, unknown> = {};
    if (query.status) filter['status'] = query.status;
    if (query.supplierId) filter['supplierId'] = new Types.ObjectId(query.supplierId);

    const [data, total] = await Promise.all([
      this.model
        .find(filter)
        .sort({ createdAt: -1 })
        .skip((page - 1) * limit)
        .limit(limit)
        .exec(),
      this.model.countDocuments(filter).exec(),
    ]);
    return { data, total };
  }

  /** Đếm số PO đã tạo trong ngày (theo prefix poNumber) — dùng sinh số thứ tự. */
  async countByPoNumberPrefix(prefix: string): Promise<number> {
    return this.model.countDocuments({ poNumber: { $regex: `^${prefix}` } }).exec();
  }
}
```

- [ ] **Step 4: Chạy test, xác nhận pass**

Run: `pnpm test -- purchase-order.repository.spec.ts`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/purchase-order/purchase-order.repository.ts apps/wms/src/purchase-order/purchase-order.repository.spec.ts
git commit -m "feat(wms/purchase-order): thêm PurchaseOrderRepository"
```

---

### Task 5: `PurchaseOrderService`

**Files:**
- Create: `apps/wms/src/purchase-order/purchase-order.service.ts`
- Test: `apps/wms/src/purchase-order/purchase-order.service.spec.ts`

**Interfaces:**
- Consumes:
  - `PurchaseOrderRepository` (Task 4): `createPurchaseOrder`, `findPurchaseOrderById`, `findPurchaseOrders`, `countByPoNumberPrefix`.
  - `SupplierService` (đã có, `apps/wms/src/supplier/supplier.service.ts`): `assertSupplierActive(supplierId: string): Promise<void>`, `getSupplierItemByItemId(itemId: string): Promise<SupplierItemDocument>` (ném `AppException('SUPPLIER_ITEM_NOT_FOUND')` nếu không tồn tại — import kiểu `SupplierItemDocument` từ `../supplier/schemas/supplier-item.schema`).
  - `WarehouseService` (đã có, `apps/wms/src/warehouse/warehouse.service.ts`): `getWarehouse(id: string): Promise<WarehouseDocument>` (ném `AppException('WAREHOUSE_NOT_FOUND')` nếu không tồn tại).
  - `AppException` từ `@app/common`.
- Produces: `PurchaseOrderService` với methods:
  - `createPurchaseOrder(dto: CreatePurchaseOrderDto, actorId: string): Promise<PurchaseOrderDocument>`
  - `listPurchaseOrders(query: QueryPurchaseOrderDto): Promise<{ data: PurchaseOrderDocument[]; total: number }>`
  - `getPurchaseOrder(id: string): Promise<PurchaseOrderDocument>`

- [ ] **Step 1: Viết test trước (service)**

```ts
// apps/wms/src/purchase-order/purchase-order.service.spec.ts
import { PurchaseOrderService } from './purchase-order.service';

const makeRepo = () => ({
  createPurchaseOrder: jest.fn(),
  findPurchaseOrderById: jest.fn(),
  findPurchaseOrders: jest.fn(),
  countByPoNumberPrefix: jest.fn(),
});

const makeSupplierService = () => ({
  assertSupplierActive: jest.fn(),
  getSupplierItemByItemId: jest.fn(),
});

const makeWarehouseService = () => ({
  getWarehouse: jest.fn(),
});

describe('PurchaseOrderService', () => {
  let svc: PurchaseOrderService;
  let repo: ReturnType<typeof makeRepo>;
  let supplierSvc: ReturnType<typeof makeSupplierService>;
  let warehouseSvc: ReturnType<typeof makeWarehouseService>;
  const actorId = 'actor123';
  const supplierId = 'sup001';
  const warehouseId = 'wh001';
  const itemId = 'item001';

  beforeEach(() => {
    repo = makeRepo();
    supplierSvc = makeSupplierService();
    warehouseSvc = makeWarehouseService();
    svc = new PurchaseOrderService(repo as never, supplierSvc as never, warehouseSvc as never);
    repo.countByPoNumberPrefix.mockResolvedValue(0);
    warehouseSvc.getWarehouse.mockResolvedValue({ _id: warehouseId });
    supplierSvc.assertSupplierActive.mockResolvedValue(undefined);
  });

  describe('createPurchaseOrder', () => {
    const baseDto = {
      supplierId,
      warehouseId,
      items: [{ itemId, sku: 'SKU-1', expectedQty: 10, unit: 'cái' }],
    };

    it('throw SUPPLIER_NOT_ACTIVE khi NCC blacklist/inactive', async () => {
      supplierSvc.assertSupplierActive.mockRejectedValue({ code: 'SUPPLIER_NOT_ACTIVE' });
      await expect(svc.createPurchaseOrder(baseDto as never, actorId)).rejects.toMatchObject({
        code: 'SUPPLIER_NOT_ACTIVE',
      });
      expect(warehouseSvc.getWarehouse).not.toHaveBeenCalled();
    });

    it('throw WAREHOUSE_NOT_FOUND khi kho không tồn tại', async () => {
      warehouseSvc.getWarehouse.mockRejectedValue({ code: 'WAREHOUSE_NOT_FOUND' });
      await expect(svc.createPurchaseOrder(baseDto as never, actorId)).rejects.toMatchObject({
        code: 'WAREHOUSE_NOT_FOUND',
      });
    });

    it('tự điền unitPrice từ SupplierItem khi item để trống giá', async () => {
      supplierSvc.getSupplierItemByItemId.mockResolvedValue({ purchasePrice: 7000 });
      repo.createPurchaseOrder.mockResolvedValue({ poNumber: 'PO-X' });
      await svc.createPurchaseOrder(baseDto as never, actorId);
      expect(repo.createPurchaseOrder).toHaveBeenCalledWith(
        baseDto,
        expect.any(String),
        [{ itemId, sku: 'SKU-1', expectedQty: 10, unit: 'cái', unitPrice: 7000 }],
        actorId,
      );
    });

    it('giữ nguyên unitPrice nếu user đã nhập tay', async () => {
      const dtoWithPrice = {
        ...baseDto,
        items: [{ itemId, sku: 'SKU-1', expectedQty: 10, unit: 'cái', unitPrice: 9999 }],
      };
      repo.createPurchaseOrder.mockResolvedValue({ poNumber: 'PO-X' });
      await svc.createPurchaseOrder(dtoWithPrice as never, actorId);
      expect(supplierSvc.getSupplierItemByItemId).not.toHaveBeenCalled();
      expect(repo.createPurchaseOrder).toHaveBeenCalledWith(
        dtoWithPrice,
        expect.any(String),
        [{ itemId, sku: 'SKU-1', expectedQty: 10, unit: 'cái', unitPrice: 9999 }],
        actorId,
      );
    });

    it('throw PO_PRICE_MISSING khi thiếu giá và SKU chưa có SupplierItem', async () => {
      supplierSvc.getSupplierItemByItemId.mockRejectedValue({ code: 'SUPPLIER_ITEM_NOT_FOUND' });
      await expect(svc.createPurchaseOrder(baseDto as never, actorId)).rejects.toMatchObject({
        code: 'PO_PRICE_MISSING',
      });
    });

    it('sinh poNumber theo format PO-YYYYMMDD-xxxx', async () => {
      repo.countByPoNumberPrefix.mockResolvedValue(4);
      supplierSvc.getSupplierItemByItemId.mockResolvedValue({ purchasePrice: 1000 });
      repo.createPurchaseOrder.mockResolvedValue({ poNumber: 'PO-X' });
      await svc.createPurchaseOrder(baseDto as never, actorId);
      const poNumberArg = repo.createPurchaseOrder.mock.calls[0][1] as string;
      expect(poNumberArg).toMatch(/^PO-\d{8}-0005$/);
    });
  });

  describe('getPurchaseOrder', () => {
    it('throw PO_NOT_FOUND khi không tìm thấy', async () => {
      repo.findPurchaseOrderById.mockResolvedValue(null);
      await expect(svc.getPurchaseOrder('po1')).rejects.toMatchObject({
        code: 'PO_NOT_FOUND',
      });
    });

    it('trả về PO khi tìm thấy', async () => {
      repo.findPurchaseOrderById.mockResolvedValue({ poNumber: 'PO-X' });
      await expect(svc.getPurchaseOrder('po1')).resolves.toEqual({ poNumber: 'PO-X' });
    });
  });

  describe('listPurchaseOrders', () => {
    it('gọi repo.findPurchaseOrders với query nguyên vẹn', async () => {
      repo.findPurchaseOrders.mockResolvedValue({ data: [], total: 0 });
      await svc.listPurchaseOrders({ page: 2, limit: 10 });
      expect(repo.findPurchaseOrders).toHaveBeenCalledWith({ page: 2, limit: 10 });
    });
  });
});
```

- [ ] **Step 2: Chạy test, xác nhận fail**

Run: `pnpm test -- purchase-order.service.spec.ts`
Expected: FAIL — `Cannot find module './purchase-order.service'`

- [ ] **Step 3: Viết implementation**

```ts
// apps/wms/src/purchase-order/purchase-order.service.ts
import { Injectable } from '@nestjs/common';
import { AppException } from '@app/common';
import {
  PurchaseOrderRepository,
  ResolvedPurchaseOrderItem,
} from './purchase-order.repository';
import { SupplierService } from '../supplier/supplier.service';
import { WarehouseService } from '../warehouse/warehouse.service';
import type { PurchaseOrderDocument } from './schemas/purchase-order.schema';
import type {
  CreatePurchaseOrderDto,
  QueryPurchaseOrderDto,
} from './dto/purchase-order.dto';

@Injectable()
export class PurchaseOrderService {
  constructor(
    private readonly repo: PurchaseOrderRepository,
    private readonly supplierService: SupplierService,
    private readonly warehouseService: WarehouseService,
  ) {}

  async createPurchaseOrder(
    dto: CreatePurchaseOrderDto,
    actorId: string,
  ): Promise<PurchaseOrderDocument> {
    // Chặn NCC blacklist/inactive trước khi làm gì khác
    await this.supplierService.assertSupplierActive(dto.supplierId);
    // Kho nhận hàng phải tồn tại
    await this.warehouseService.getWarehouse(dto.warehouseId);

    const resolvedItems: ResolvedPurchaseOrderItem[] = [];
    for (const item of dto.items) {
      let unitPrice = item.unitPrice;
      if (unitPrice === undefined) {
        // Giá để trống → tra bảng giá NCC; SKU chưa từng khai giá thì từ chối luôn PO
        try {
          const supplierItem = await this.supplierService.getSupplierItemByItemId(
            item.itemId,
          );
          unitPrice = supplierItem.purchasePrice;
        } catch {
          throw new AppException('PO_PRICE_MISSING');
        }
      }
      resolvedItems.push({
        itemId: item.itemId,
        sku: item.sku,
        expectedQty: item.expectedQty,
        unit: item.unit,
        unitPrice,
      });
    }

    const poNumber = await this.generatePoNumber();
    return this.repo.createPurchaseOrder(dto, poNumber, resolvedItems, actorId);
  }

  async listPurchaseOrders(
    query: QueryPurchaseOrderDto,
  ): Promise<{ data: PurchaseOrderDocument[]; total: number }> {
    return this.repo.findPurchaseOrders(query);
  }

  async getPurchaseOrder(id: string): Promise<PurchaseOrderDocument> {
    const doc = await this.repo.findPurchaseOrderById(id);
    if (!doc) throw new AppException('PO_NOT_FOUND');
    return doc;
  }

  /** Sinh mã PO dạng PO-YYYYMMDD-xxxx, số thứ tự reset theo ngày. */
  private async generatePoNumber(): Promise<string> {
    const now = new Date();
    const y = now.getFullYear();
    const m = String(now.getMonth() + 1).padStart(2, '0');
    const d = String(now.getDate()).padStart(2, '0');
    const prefix = `PO-${y}${m}${d}`;
    const count = await this.repo.countByPoNumberPrefix(prefix);
    const seq = String(count + 1).padStart(4, '0');
    return `${prefix}-${seq}`;
  }
}
```

- [ ] **Step 4: Chạy test, xác nhận pass**

Run: `pnpm test -- purchase-order.service.spec.ts`
Expected: PASS (10 tests)

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/purchase-order/purchase-order.service.ts apps/wms/src/purchase-order/purchase-order.service.spec.ts
git commit -m "feat(wms/purchase-order): thêm PurchaseOrderService (validate NCC/kho, gợi ý giá)"
```

---

### Task 6: `PurchaseOrderController` + `PurchaseOrderModule` + wire vào `AppModule`

**Files:**
- Create: `apps/wms/src/purchase-order/purchase-order.controller.ts`
- Create: `apps/wms/src/purchase-order/purchase-order.module.ts`
- Modify: `apps/wms/src/app.module.ts`

**Interfaces:**
- Consumes: `PurchaseOrderService` (Task 5); DTO từ Task 3; `SupplierModule` (export `SupplierService`), `WarehouseModule` (export `WarehouseService`) — cả hai đã tồn tại và export sẵn.

- [ ] **Step 1: Viết controller**

```ts
// apps/wms/src/purchase-order/purchase-order.controller.ts
import { Body, Controller, Get, Param, Post, Query, UseGuards } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiCreatedResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import { CurrentUser, JwtAuthGuard, Roles, RolesGuard, WmsRole } from '@app/auth';
import { plainToInstance } from 'class-transformer';
import { PurchaseOrderService } from './purchase-order.service';
import {
  CreatePurchaseOrderDto,
  PurchaseOrderResponseDto,
  QueryPurchaseOrderDto,
} from './dto/purchase-order.dto';

const TO_OPTS = { excludeExtraneousValues: true } as const;

@ApiTags('purchase-order')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard, RolesGuard)
@Controller('purchase-orders')
export class PurchaseOrderController {
  constructor(private readonly svc: PurchaseOrderService) {}

  @Post()
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Tạo đơn đặt hàng NCC (PO) — [MANAGER, ADMIN]' })
  @ApiCreatedResponse({ type: PurchaseOrderResponseDto })
  async createPurchaseOrder(
    @Body() dto: CreatePurchaseOrderDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<PurchaseOrderResponseDto> {
    const doc = await this.svc.createPurchaseOrder(dto, actorId);
    return plainToInstance(PurchaseOrderResponseDto, doc.toObject(), TO_OPTS);
  }

  @Get()
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Danh sách PO — [MANAGER, ADMIN]' })
  @ApiOkResponse({ type: [PurchaseOrderResponseDto] })
  async listPurchaseOrders(@Query() query: QueryPurchaseOrderDto): Promise<{
    data: PurchaseOrderResponseDto[];
    total: number;
    page: number;
    limit: number;
  }> {
    const { data, total } = await this.svc.listPurchaseOrders(query);
    return {
      data: plainToInstance(
        PurchaseOrderResponseDto,
        data.map((d) => d.toObject()),
        TO_OPTS,
      ),
      total,
      page: query.page ?? 1,
      limit: query.limit ?? 20,
    };
  }

  @Get(':id')
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Chi tiết PO — [MANAGER, ADMIN]' })
  @ApiOkResponse({ type: PurchaseOrderResponseDto })
  async getPurchaseOrder(@Param('id') id: string): Promise<PurchaseOrderResponseDto> {
    const doc = await this.svc.getPurchaseOrder(id);
    return plainToInstance(PurchaseOrderResponseDto, doc.toObject(), TO_OPTS);
  }
}
```

- [ ] **Step 2: Viết module**

```ts
// apps/wms/src/purchase-order/purchase-order.module.ts
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { PurchaseOrder, PurchaseOrderSchema } from './schemas/purchase-order.schema';
import { PurchaseOrderRepository } from './purchase-order.repository';
import { PurchaseOrderService } from './purchase-order.service';
import { PurchaseOrderController } from './purchase-order.controller';
import { SupplierModule } from '../supplier/supplier.module';
import { WarehouseModule } from '../warehouse/warehouse.module';

@Module({
  imports: [
    MongooseModule.forFeature([
      { name: PurchaseOrder.name, schema: PurchaseOrderSchema },
    ]),
    SupplierModule, // assertSupplierActive + getSupplierItemByItemId
    WarehouseModule, // getWarehouse
  ],
  providers: [PurchaseOrderRepository, PurchaseOrderService],
  controllers: [PurchaseOrderController],
})
export class PurchaseOrderModule {}
```

- [ ] **Step 3: Wire vào `AppModule`**

Trong `apps/wms/src/app.module.ts`, thêm import:

```ts
import { PurchaseOrderModule } from './purchase-order/purchase-order.module';
```

Và thêm `PurchaseOrderModule` vào mảng `imports`, ngay sau `SupplierModule`:

```ts
    SupplierModule, // CRUD NCC + bảng giá SupplierItem
    PurchaseOrderModule, // UC-01: tạo/xem PO — dùng SupplierModule + WarehouseModule
```

- [ ] **Step 4: Build toàn bộ, xác nhận không lỗi**

Run: `pnpm build`
Expected: build thành công, không lỗi TypeScript/circular dependency.

- [ ] **Step 5: Chạy toàn bộ test suite của module mới**

Run: `pnpm test -- purchase-order`
Expected: PASS (toàn bộ test schema + repository + service, tổng ~19 tests)

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/purchase-order/purchase-order.controller.ts apps/wms/src/purchase-order/purchase-order.module.ts apps/wms/src/app.module.ts
git commit -m "feat(wms/purchase-order): wire PurchaseOrderController + PurchaseOrderModule vào AppModule"
```

---

### Task 7: Lint + full test suite + kiểm tra thủ công qua Swagger

**Files:** không tạo file mới — bước xác minh cuối.

- [ ] **Step 1: Chạy lint**

Run: `pnpm lint`
Expected: 0 lỗi (cảnh báo `any`/unsafe-member-access phải bằng 0 vì ESLint rule chặn).

- [ ] **Step 2: Chạy toàn bộ test suite WMS**

Run: `pnpm test`
Expected: tất cả test pass, không có suite nào bị fail do thay đổi này.

- [ ] **Step 3: Khởi động WMS, kiểm tra Swagger**

Run: `pnpm start:wms`

Mở `http://localhost:3001/api/wms/docs`, xác nhận:
- Tag `purchase-order` xuất hiện với 3 endpoint: `POST /purchase-orders`, `GET /purchase-orders`, `GET /purchase-orders/{id}`.
- `@ApiOperation summary` của cả 3 endpoint hiển thị đúng `[MANAGER, ADMIN]`.
- Field `status` trong response schema hiển thị dropdown 6 giá trị enum.

- [ ] **Step 4: Test thủ công luồng tạo PO qua Swagger UI (nếu có Mongo local chạy)**

Gọi `POST /api/wms/purchase-orders` với JWT MANAGER, body thiếu `unitPrice` cho 1 item chưa có `SupplierItem` → xác nhận trả về lỗi `PO_PRICE_MISSING` status 400. Với NCC blacklist → xác nhận trả `SUPPLIER_NOT_ACTIVE` status 403.

- [ ] **Step 5: Dừng server**

Dừng tiến trình `pnpm start:wms` (Ctrl+C hoặc kill process).

---

## Ngoài phạm vi plan này (đã chốt trong spec)

- API confirm/send PO, API hủy PO (`CANCELLED`).
- Field/method chuẩn bị cho GRN (`receivedQty`, `applyReceivedQty`) — S2-03 tự thiết kế.
- Quy đổi đơn vị phụ → cơ sở (`baseQty = qty × factor`) — chỉ cần ở GRN.
