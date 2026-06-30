# S2-01: Supplier + SupplierItem Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Xây dựng module Supplier trong WMS app — CRUD NCC, quản lý trạng thái (ACTIVE/INACTIVE/BLACKLIST), danh mục giá (SupplierItem 1 NCC/SKU), và guard chặn tạo PO khi NCC không ACTIVE.

**Architecture:** Module Supplier nằm trong `apps/wms/src/supplier/`, sở hữu 2 collection: `suppliers` (master data → soft-delete) và `supplier_items` (bảng giá → không xóa cứng, toggle `isActive`). Guard PO (UC-S04) được expose dưới dạng `SupplierService.assertSupplierActive(supplierId)` để module PO gọi khi cần — hiện không có module PO, nên trong sprint này ta viết service method + unit test, chưa integrate vào controller PO.

**Tech Stack:** NestJS, `@nestjs/mongoose` + Mongoose, `class-validator`, `class-transformer`, `@nestjs/swagger`, `@app/common` (AppException), `@app/auth` (JwtAuthGuard, RolesGuard, WmsRole), Jest (unit, model via `makeModel` pattern từ stock.repository.spec.ts).

## Global Constraints

- Không `any` — vi phạm ESLint `@typescript-eslint/no-explicit-any` build fail.
- Comment tiếng Việt (ngắn, giải thích *vì sao*).
- Mỗi `@Roles(...)` → ghi `— [ROLE1, ROLE2]` vào `@ApiOperation({ summary })`.
- `_id` → map ra `id` (string) bằng `@Transform` trong ResponseDto.
- `plainToInstance(..., { excludeExtraneousValues: true })` trong controller.
- `@Schema({ timestamps: true })` cho master data; audit: `createdBy`, `updatedBy`, `deletedAt`.
- `SupplierItem` là bảng "bảng giá" (không phải master data thuần) → `timestamps: true` nhưng chỉ `updatedAt` quan trọng; không soft-delete, toggle `isActive = false`.
- Collection name snake_case: `suppliers`, `supplier_items`.
- Import lib qua `@app/*` alias.
- Test pattern: mock model với `makeModel` helper (xem `stock.repository.spec.ts`).
- Run tests: `pnpm test` (tất cả `.spec.ts` trong `apps/` và `libs/`).
- Build check: `pnpm build` (hoặc `nest build wms`).

---

## File Structure

```
apps/wms/src/supplier/
  schemas/
    supplier.schema.ts          ← Supplier entity + SupplierStatus enum
    supplier.schema.spec.ts     ← Schema shape tests
    supplier-item.schema.ts     ← SupplierItem entity
    supplier-item.schema.spec.ts← Schema shape tests
  dto/
    supplier.dto.ts             ← Create/Update/Query/Response DTO cho Supplier
    supplier-item.dto.ts        ← Create/Update/Response DTO cho SupplierItem
  supplier.repository.ts        ← Mongoose queries cho Supplier + SupplierItem
  supplier.repository.spec.ts   ← Unit test với mock models
  supplier.service.ts           ← Business logic (CRUD + status transitions + guard)
  supplier.service.spec.ts      ← Unit test với mock repository
  supplier.controller.ts        ← REST endpoints (prefix: supplier)
  supplier.module.ts            ← NestJS module wiring

apps/wms/src/common/error-codes.ts  ← thêm SUPPLIER_* codes
apps/wms/src/app.module.ts          ← import SupplierModule
```

---

## Task 1: Supplier Schema + SupplierItem Schema

**Files:**
- Create: `apps/wms/src/supplier/schemas/supplier.schema.ts`
- Create: `apps/wms/src/supplier/schemas/supplier.schema.spec.ts`
- Create: `apps/wms/src/supplier/schemas/supplier-item.schema.ts`
- Create: `apps/wms/src/supplier/schemas/supplier-item.schema.spec.ts`

**Interfaces:**
- Produces:
  - `enum SupplierStatus { ACTIVE = 'ACTIVE', INACTIVE = 'INACTIVE', BLACKLIST = 'BLACKLIST' }`
  - `class Supplier` — field: `code, name, contactName, phone, email, address, taxCode, status, note, createdBy, updatedBy, deletedAt`
  - `type SupplierDocument = HydratedDocument<Supplier>`
  - `const SupplierSchema`
  - `class SupplierItem` — field: `itemId, supplierId, supplierItemCode, purchasePrice, leadTimeDays, minOrderQty, isActive`
  - `type SupplierItemDocument = HydratedDocument<SupplierItem>`
  - `const SupplierItemSchema`

- [ ] **Bước 1: Tạo supplier.schema.spec.ts (test trước)**

```typescript
// apps/wms/src/supplier/schemas/supplier.schema.spec.ts
import { SupplierStatus, SupplierSchema } from './supplier.schema';

describe('Supplier schema', () => {
  it('SupplierStatus enum có đủ 3 giá trị', () => {
    expect(Object.values(SupplierStatus)).toEqual([
      'ACTIVE',
      'INACTIVE',
      'BLACKLIST',
    ]);
  });

  it('schema có đủ field cần thiết', () => {
    const paths = SupplierSchema.paths;
    expect(paths['code']).toBeDefined();
    expect(paths['name']).toBeDefined();
    expect(paths['status']).toBeDefined();
    expect(paths['deletedAt']).toBeDefined();
    expect(paths['createdBy']).toBeDefined();
    expect(paths['updatedBy']).toBeDefined();
  });

  it('field code có unique index', () => {
    const codeSchema = SupplierSchema.path('code') as { options?: { unique?: boolean } };
    expect(codeSchema.options?.unique).toBe(true);
  });
});
```

- [ ] **Bước 2: Chạy test — phải FAIL vì file chưa tồn tại**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm test -- --testPathPattern="supplier.schema.spec" --no-coverage
```

Expected: FAIL — "Cannot find module './supplier.schema'"

- [ ] **Bước 3: Tạo supplier.schema.ts**

```typescript
// apps/wms/src/supplier/schemas/supplier.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

export enum SupplierStatus {
  ACTIVE = 'ACTIVE',
  INACTIVE = 'INACTIVE',
  BLACKLIST = 'BLACKLIST',
}

/** Master data nhà cung cấp — soft-delete, audit đầy đủ */
@Schema({ collection: 'suppliers', timestamps: true })
export class Supplier {
  @Prop({ required: true, unique: true })
  code!: string;

  @Prop({ required: true })
  name!: string;

  @Prop()
  contactName?: string;

  @Prop()
  phone?: string;

  @Prop()
  email?: string;

  @Prop()
  address?: string;

  @Prop()
  taxCode?: string;

  @Prop({ enum: SupplierStatus, default: SupplierStatus.ACTIVE })
  status!: SupplierStatus;

  @Prop()
  note?: string;

  @Prop({ type: Types.ObjectId })
  createdBy?: Types.ObjectId;

  @Prop({ type: Types.ObjectId })
  updatedBy?: Types.ObjectId;

  @Prop({ type: Date, default: null })
  deletedAt?: Date | null;
}

export type SupplierDocument = HydratedDocument<Supplier>;
export const SupplierSchema = SchemaFactory.createForClass(Supplier);
SupplierSchema.index({ deletedAt: 1 });
```

- [ ] **Bước 4: Tạo supplier-item.schema.spec.ts (test trước)**

```typescript
// apps/wms/src/supplier/schemas/supplier-item.schema.spec.ts
import { SupplierItemSchema } from './supplier-item.schema';

describe('SupplierItem schema', () => {
  it('schema có đủ field cần thiết', () => {
    const paths = SupplierItemSchema.paths;
    expect(paths['itemId']).toBeDefined();
    expect(paths['supplierId']).toBeDefined();
    expect(paths['purchasePrice']).toBeDefined();
    expect(paths['leadTimeDays']).toBeDefined();
    expect(paths['minOrderQty']).toBeDefined();
    expect(paths['isActive']).toBeDefined();
  });

  it('itemId có unique index (1 SKU ↔ 1 NCC chính)', () => {
    const itemIdPath = SupplierItemSchema.path('itemId') as { options?: { unique?: boolean } };
    expect(itemIdPath.options?.unique).toBe(true);
  });
});
```

- [ ] **Bước 5: Tạo supplier-item.schema.ts**

```typescript
// apps/wms/src/supplier/schemas/supplier-item.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, SchemaTypes, Types } from 'mongoose';

/**
 * Danh mục giá: 1 SKU ↔ 1 NCC chính (unique itemId).
 * Không soft-delete — toggle isActive khi hết hiệu lực báo giá.
 * updatedAt tự update qua timestamps.
 */
@Schema({ collection: 'supplier_items', timestamps: { createdAt: false, updatedAt: true } })
export class SupplierItem {
  /** WarehouseItem._id — unique: 1 SKU chỉ có 1 NCC chính */
  @Prop({ type: SchemaTypes.ObjectId, required: true, unique: true })
  itemId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  supplierId!: Types.ObjectId;

  /** Mã hàng phía NCC để đối chiếu khi đặt hàng */
  @Prop()
  supplierItemCode?: string;

  /** Giá nhập gợi ý (sửa tay được khi tạo PO) */
  @Prop({ type: Number, required: true, min: 0 })
  purchasePrice!: number;

  /** Số ngày giao dự kiến */
  @Prop({ type: Number, min: 0 })
  leadTimeDays?: number;

  /** Số lượng đặt tối thiểu (MOQ) */
  @Prop({ type: Number, min: 0 })
  minOrderQty?: number;

  /** false = báo giá hết hiệu lực, không gợi ý khi tạo PO */
  @Prop({ default: true })
  isActive!: boolean;
}

export type SupplierItemDocument = HydratedDocument<SupplierItem>;
export const SupplierItemSchema = SchemaFactory.createForClass(SupplierItem);
```

- [ ] **Bước 6: Chạy test — phải PASS**

```bash
pnpm test -- --testPathPattern="supplier\.(schema|item\.schema)\.spec" --no-coverage
```

Expected: PASS (4 tests)

- [ ] **Bước 7: Commit**

```bash
git add apps/wms/src/supplier/schemas/
git commit -m "feat(wms/supplier): thêm Supplier + SupplierItem schema với enum SupplierStatus"
```

---

## Task 2: Error codes cho Supplier domain

**Files:**
- Modify: `apps/wms/src/common/error-codes.ts`

**Interfaces:**
- Produces: thêm các key `SUPPLIER_NOT_FOUND`, `SUPPLIER_CODE_EXISTS`, `SUPPLIER_BLACKLISTED`, `SUPPLIER_NOT_ACTIVE`, `SUPPLIER_ITEM_NOT_FOUND`, `SUPPLIER_ITEM_SKU_EXISTS` vào `WMS_ERRORS`

- [ ] **Bước 1: Đọc file hiện tại**

Mở `apps/wms/src/common/error-codes.ts` — kiểm tra pattern `HttpStatus` đang dùng.

- [ ] **Bước 2: Thêm SUPPLIER_* error codes**

Thêm vào `WMS_ERRORS` (sau `LOT_NOT_FOUND`):

```typescript
  SUPPLIER_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy nhà cung cấp',
  },
  SUPPLIER_CODE_EXISTS: {
    status: HttpStatus.CONFLICT,
    message: 'Mã nhà cung cấp đã tồn tại',
  },
  SUPPLIER_BLACKLISTED: {
    status: HttpStatus.FORBIDDEN,
    message: 'Nhà cung cấp đang bị blacklist — chỉ ADMIN mới gỡ được',
  },
  SUPPLIER_NOT_ACTIVE: {
    status: HttpStatus.FORBIDDEN,
    message: 'Nhà cung cấp không ở trạng thái ACTIVE — không thể xác nhận PO',
  },
  SUPPLIER_ITEM_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy thông tin giá của SKU này',
  },
  SUPPLIER_ITEM_SKU_EXISTS: {
    status: HttpStatus.CONFLICT,
    message: 'SKU này đã có NCC chính — cập nhật thay vì tạo mới',
  },
```

- [ ] **Bước 3: Build check (không cần test riêng — kiểm tra TypeScript compile)**

```bash
pnpm build 2>&1 | tail -5
```

Expected: 0 errors (hoặc chỉ lỗi không liên quan đến file này)

- [ ] **Bước 4: Commit**

```bash
git add apps/wms/src/common/error-codes.ts
git commit -m "feat(wms/supplier): thêm SUPPLIER_* error codes vào WMS_ERRORS"
```

---

## Task 3: DTOs (Request + Response)

**Files:**
- Create: `apps/wms/src/supplier/dto/supplier.dto.ts`
- Create: `apps/wms/src/supplier/dto/supplier-item.dto.ts`

**Interfaces:**
- Produces (supplier.dto.ts):
  - `class CreateSupplierDto` — `code, name, contactName?, phone?, email?, address?, taxCode?, note?`
  - `class UpdateSupplierDto extends PartialType(CreateSupplierDto)` (không có `code` trong update — spec: code đã dùng trong PO thì không đổi; ta xử lý ở service)
  - `class ChangeSupplierStatusDto` — `status: SupplierStatus`
  - `class QuerySupplierDto` — `status?, search?, page?, limit?`
  - `class SupplierResponseDto` — `id, code, name, contactName, phone, email, address, taxCode, status, note, createdAt, updatedAt`

- Produces (supplier-item.dto.ts):
  - `class CreateSupplierItemDto` — `itemId, supplierId, supplierItemCode?, purchasePrice, leadTimeDays?, minOrderQty?`
  - `class UpdateSupplierItemDto` — `supplierId?, supplierItemCode?, purchasePrice?, leadTimeDays?, minOrderQty?, isActive?`
  - `class SupplierItemResponseDto` — `id, itemId, supplierId, supplierItemCode, purchasePrice, leadTimeDays, minOrderQty, isActive, updatedAt`

- [ ] **Bước 1: Tạo supplier.dto.ts**

```typescript
// apps/wms/src/supplier/dto/supplier.dto.ts
import { ApiProperty, ApiPropertyOptional, PartialType } from '@nestjs/swagger';
import { Expose, Transform } from 'class-transformer';
import {
  IsEnum,
  IsOptional,
  IsString,
  MinLength,
  IsInt,
  Min,
  Max,
} from 'class-validator';
import { Types } from 'mongoose';
import { SupplierStatus } from '../schemas/supplier.schema';

export class CreateSupplierDto {
  @ApiProperty({ example: 'NCC-001', description: 'Mã NCC — unique, không đổi sau khi có PO' })
  @IsString()
  @MinLength(1)
  code!: string;

  @ApiProperty({ example: 'Công ty TNHH ABC' })
  @IsString()
  @MinLength(1)
  name!: string;

  @ApiPropertyOptional({ example: 'Nguyễn Văn A' })
  @IsOptional()
  @IsString()
  contactName?: string;

  @ApiPropertyOptional({ example: '0901234567' })
  @IsOptional()
  @IsString()
  phone?: string;

  @ApiPropertyOptional({ example: 'contact@abc.com' })
  @IsOptional()
  @IsString()
  email?: string;

  @ApiPropertyOptional({ example: '123 Lê Văn Lương, Q7' })
  @IsOptional()
  @IsString()
  address?: string;

  @ApiPropertyOptional({ example: '0300123456' })
  @IsOptional()
  @IsString()
  taxCode?: string;

  @ApiPropertyOptional({ example: 'Ưu tiên đặt hàng quý 1' })
  @IsOptional()
  @IsString()
  note?: string;
}

export class UpdateSupplierDto extends PartialType(CreateSupplierDto) {}

export class ChangeSupplierStatusDto {
  @ApiProperty({ enum: SupplierStatus, example: SupplierStatus.INACTIVE })
  @IsEnum(SupplierStatus)
  status!: SupplierStatus;
}

export class QuerySupplierDto {
  @ApiPropertyOptional({ enum: SupplierStatus })
  @IsOptional()
  @IsEnum(SupplierStatus)
  status?: SupplierStatus;

  @ApiPropertyOptional({ description: 'Tìm theo name hoặc code' })
  @IsOptional()
  @IsString()
  search?: string;

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

export class SupplierResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) => obj._id?.toString())
  @ApiProperty()
  id!: string;

  @Expose()
  @ApiProperty()
  code!: string;

  @Expose()
  @ApiProperty()
  name!: string;

  @Expose()
  @ApiPropertyOptional()
  contactName?: string;

  @Expose()
  @ApiPropertyOptional()
  phone?: string;

  @Expose()
  @ApiPropertyOptional()
  email?: string;

  @Expose()
  @ApiPropertyOptional()
  address?: string;

  @Expose()
  @ApiPropertyOptional()
  taxCode?: string;

  @Expose()
  @ApiProperty({ enum: SupplierStatus })
  status!: SupplierStatus;

  @Expose()
  @ApiPropertyOptional()
  note?: string;

  @Expose()
  @ApiProperty()
  createdAt!: Date;

  @Expose()
  @ApiProperty()
  updatedAt!: Date;
}
```

- [ ] **Bước 2: Tạo supplier-item.dto.ts**

```typescript
// apps/wms/src/supplier/dto/supplier-item.dto.ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Expose, Transform } from 'class-transformer';
import {
  IsBoolean,
  IsMongoId,
  IsNumber,
  IsOptional,
  IsString,
  Min,
} from 'class-validator';
import { Types } from 'mongoose';

export class CreateSupplierItemDto {
  @ApiProperty({ description: 'WarehouseItem._id (ObjectId)', example: '665f...' })
  @IsMongoId()
  itemId!: string;

  @ApiProperty({ description: 'Supplier._id (ObjectId)', example: '665f...' })
  @IsMongoId()
  supplierId!: string;

  @ApiPropertyOptional({ description: 'Mã hàng phía NCC để đối chiếu khi đặt hàng' })
  @IsOptional()
  @IsString()
  supplierItemCode?: string;

  @ApiProperty({ example: 15000, description: 'Giá nhập gợi ý (VND)' })
  @IsNumber()
  @Min(0)
  purchasePrice!: number;

  @ApiPropertyOptional({ example: 7, description: 'Số ngày giao dự kiến' })
  @IsOptional()
  @IsNumber()
  @Min(0)
  leadTimeDays?: number;

  @ApiPropertyOptional({ example: 100, description: 'Số lượng đặt tối thiểu (MOQ)' })
  @IsOptional()
  @IsNumber()
  @Min(0)
  minOrderQty?: number;
}

export class UpdateSupplierItemDto {
  @ApiPropertyOptional({ description: 'Đổi NCC chính cho SKU này' })
  @IsOptional()
  @IsMongoId()
  supplierId?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  supplierItemCode?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsNumber()
  @Min(0)
  purchasePrice?: number;

  @ApiPropertyOptional()
  @IsOptional()
  @IsNumber()
  @Min(0)
  leadTimeDays?: number;

  @ApiPropertyOptional()
  @IsOptional()
  @IsNumber()
  @Min(0)
  minOrderQty?: number;

  @ApiPropertyOptional({ description: 'false = hết hiệu lực báo giá' })
  @IsOptional()
  @IsBoolean()
  isActive?: boolean;
}

export class SupplierItemResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) => obj._id?.toString())
  @ApiProperty()
  id!: string;

  @Expose()
  @Transform(({ obj }: { obj: { itemId?: Types.ObjectId } }) => obj.itemId?.toString())
  @ApiProperty()
  itemId!: string;

  @Expose()
  @Transform(({ obj }: { obj: { supplierId?: Types.ObjectId } }) => obj.supplierId?.toString())
  @ApiProperty()
  supplierId!: string;

  @Expose()
  @ApiPropertyOptional()
  supplierItemCode?: string;

  @Expose()
  @ApiProperty()
  purchasePrice!: number;

  @Expose()
  @ApiPropertyOptional()
  leadTimeDays?: number;

  @Expose()
  @ApiPropertyOptional()
  minOrderQty?: number;

  @Expose()
  @ApiProperty()
  isActive!: boolean;

  @Expose()
  @ApiProperty()
  updatedAt!: Date;
}
```

- [ ] **Bước 3: Build check**

```bash
pnpm build 2>&1 | grep -i error | head -20
```

Expected: 0 TypeScript errors mới liên quan đến supplier DTO.

- [ ] **Bước 4: Commit**

```bash
git add apps/wms/src/supplier/dto/
git commit -m "feat(wms/supplier): thêm DTO Supplier + SupplierItem (request/response)"
```

---

## Task 4: SupplierRepository

**Files:**
- Create: `apps/wms/src/supplier/supplier.repository.ts`
- Create: `apps/wms/src/supplier/supplier.repository.spec.ts`

**Interfaces:**
- Consumes: `Supplier`, `SupplierDocument`, `SupplierSchema`, `SupplierStatus`, `SupplierItem`, `SupplierItemDocument`, `SupplierItemSchema`, `CreateSupplierDto`, `UpdateSupplierDto`, `QuerySupplierDto`, `CreateSupplierItemDto`, `UpdateSupplierItemDto`
- Produces:
  - `SupplierRepository` với methods:
    - `createSupplier(dto, actorId): Promise<SupplierDocument>`
    - `findSupplierById(id): Promise<SupplierDocument | null>`
    - `findSupplierByCode(code): Promise<SupplierDocument | null>`
    - `findSuppliers(query): Promise<{ data: SupplierDocument[]; total: number }>`
    - `updateSupplier(id, dto, actorId): Promise<SupplierDocument | null>`
    - `changeSupplierStatus(id, status, actorId): Promise<SupplierDocument | null>`
    - `softDeleteSupplier(id, actorId): Promise<boolean>`
    - `createSupplierItem(dto): Promise<SupplierItemDocument>`
    - `findSupplierItemById(id): Promise<SupplierItemDocument | null>`
    - `findSupplierItemByItemId(itemId): Promise<SupplierItemDocument | null>`
    - `findSupplierItemsBySupplierId(supplierId): Promise<SupplierItemDocument[]>`
    - `updateSupplierItem(id, dto): Promise<SupplierItemDocument | null>`

- [ ] **Bước 1: Tạo supplier.repository.spec.ts (test trước)**

```typescript
// apps/wms/src/supplier/supplier.repository.spec.ts
import { getModelToken } from '@nestjs/mongoose';
import { Test } from '@nestjs/testing';
import { Types } from 'mongoose';
import { SupplierRepository } from './supplier.repository';
import { Supplier } from './schemas/supplier.schema';
import { SupplierItem } from './schemas/supplier-item.schema';
import { SupplierStatus } from './schemas/supplier.schema';

const makeModel = (overrides: Record<string, jest.Mock> = {}) => ({
  findOne: jest.fn().mockReturnThis(),
  find: jest.fn().mockReturnThis(),
  findOneAndUpdate: jest.fn().mockReturnThis(),
  countDocuments: jest.fn().mockReturnThis(),
  create: jest.fn(),
  updateOne: jest.fn().mockReturnThis(),
  sort: jest.fn().mockReturnThis(),
  skip: jest.fn().mockReturnThis(),
  limit: jest.fn().mockReturnThis(),
  exec: jest.fn(),
  ...overrides,
});

describe('SupplierRepository', () => {
  let repo: SupplierRepository;
  let supplierModel: ReturnType<typeof makeModel>;
  let supplierItemModel: ReturnType<typeof makeModel>;
  const actorId = new Types.ObjectId().toString();
  const supplierId = new Types.ObjectId().toString();
  const itemId = new Types.ObjectId().toString();

  beforeEach(async () => {
    supplierModel = makeModel();
    supplierItemModel = makeModel();

    const module = await Test.createTestingModule({
      providers: [
        SupplierRepository,
        { provide: getModelToken(Supplier.name), useValue: supplierModel },
        { provide: getModelToken(SupplierItem.name), useValue: supplierItemModel },
      ],
    }).compile();

    repo = module.get(SupplierRepository);
    jest.clearAllMocks();
  });

  describe('findSupplierByCode', () => {
    it('gọi findOne với code và deletedAt:null', async () => {
      supplierModel.exec.mockResolvedValue(null);
      await repo.findSupplierByCode('NCC-001');
      expect(supplierModel.findOne).toHaveBeenCalledWith({
        code: 'NCC-001',
        deletedAt: null,
      });
    });
  });

  describe('changeSupplierStatus', () => {
    it('gọi findOneAndUpdate với status mới và updatedBy', async () => {
      const fakeDoc = { status: SupplierStatus.INACTIVE };
      supplierModel.exec.mockResolvedValue(fakeDoc);
      const result = await repo.changeSupplierStatus(
        supplierId,
        SupplierStatus.INACTIVE,
        actorId,
      );
      expect(supplierModel.findOneAndUpdate).toHaveBeenCalledWith(
        { _id: supplierId, deletedAt: null },
        {
          status: SupplierStatus.INACTIVE,
          updatedBy: expect.any(Types.ObjectId),
        },
        { new: true },
      );
      expect(result).toEqual(fakeDoc);
    });
  });

  describe('findSupplierItemByItemId', () => {
    it('gọi findOne với itemId ObjectId', async () => {
      supplierItemModel.exec.mockResolvedValue(null);
      await repo.findSupplierItemByItemId(itemId);
      expect(supplierItemModel.findOne).toHaveBeenCalledWith({
        itemId: expect.any(Types.ObjectId),
      });
    });
  });

  describe('softDeleteSupplier', () => {
    it('trả về true khi modifiedCount > 0', async () => {
      supplierModel.exec.mockResolvedValue({ modifiedCount: 1 });
      const result = await repo.softDeleteSupplier(supplierId, actorId);
      expect(result).toBe(true);
    });

    it('trả về false khi không tìm thấy', async () => {
      supplierModel.exec.mockResolvedValue({ modifiedCount: 0 });
      const result = await repo.softDeleteSupplier(supplierId, actorId);
      expect(result).toBe(false);
    });
  });
});
```

- [ ] **Bước 2: Chạy test — phải FAIL**

```bash
pnpm test -- --testPathPattern="supplier.repository.spec" --no-coverage
```

Expected: FAIL — "Cannot find module './supplier.repository'"

- [ ] **Bước 3: Tạo supplier.repository.ts**

```typescript
// apps/wms/src/supplier/supplier.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import { Supplier, SupplierDocument, SupplierStatus } from './schemas/supplier.schema';
import { SupplierItem, SupplierItemDocument } from './schemas/supplier-item.schema';
import type { CreateSupplierDto, UpdateSupplierDto, QuerySupplierDto } from './dto/supplier.dto';
import type { CreateSupplierItemDto, UpdateSupplierItemDto } from './dto/supplier-item.dto';

const SOFT_DELETE_FILTER = { deletedAt: null } as const;

@Injectable()
export class SupplierRepository {
  constructor(
    @InjectModel(Supplier.name)
    private readonly supplierModel: Model<SupplierDocument>,
    @InjectModel(SupplierItem.name)
    private readonly supplierItemModel: Model<SupplierItemDocument>,
  ) {}

  // ─── Supplier ─────────────────────────────────────────────────────────────

  async createSupplier(dto: CreateSupplierDto, actorId: string): Promise<SupplierDocument> {
    return this.supplierModel.create({
      ...dto,
      createdBy: new Types.ObjectId(actorId),
      updatedBy: new Types.ObjectId(actorId),
    });
  }

  async findSupplierById(id: string): Promise<SupplierDocument | null> {
    return this.supplierModel.findOne({ _id: id, ...SOFT_DELETE_FILTER }).exec();
  }

  async findSupplierByCode(code: string): Promise<SupplierDocument | null> {
    return this.supplierModel.findOne({ code, ...SOFT_DELETE_FILTER }).exec();
  }

  async findSuppliers(
    query: QuerySupplierDto,
  ): Promise<{ data: SupplierDocument[]; total: number }> {
    const page = query.page ?? 1;
    const limit = query.limit ?? 20;
    const filter: Record<string, unknown> = { ...SOFT_DELETE_FILTER };

    if (query.status) filter['status'] = query.status;
    if (query.search) {
      filter['$or'] = [
        { name: { $regex: query.search, $options: 'i' } },
        { code: { $regex: query.search, $options: 'i' } },
      ];
    }

    const [data, total] = await Promise.all([
      this.supplierModel
        .find(filter)
        .sort({ code: 1 })
        .skip((page - 1) * limit)
        .limit(limit)
        .exec(),
      this.supplierModel.countDocuments(filter).exec(),
    ]);
    return { data, total };
  }

  async updateSupplier(
    id: string,
    dto: UpdateSupplierDto,
    actorId: string,
  ): Promise<SupplierDocument | null> {
    return this.supplierModel
      .findOneAndUpdate(
        { _id: id, ...SOFT_DELETE_FILTER },
        { ...dto, updatedBy: new Types.ObjectId(actorId) },
        { new: true },
      )
      .exec();
  }

  async changeSupplierStatus(
    id: string,
    status: SupplierStatus,
    actorId: string,
  ): Promise<SupplierDocument | null> {
    return this.supplierModel
      .findOneAndUpdate(
        { _id: id, ...SOFT_DELETE_FILTER },
        { status, updatedBy: new Types.ObjectId(actorId) },
        { new: true },
      )
      .exec();
  }

  async softDeleteSupplier(id: string, actorId: string): Promise<boolean> {
    const res = await this.supplierModel
      .updateOne(
        { _id: id, ...SOFT_DELETE_FILTER },
        { deletedAt: new Date(), updatedBy: new Types.ObjectId(actorId) },
      )
      .exec();
    return res.modifiedCount > 0;
  }

  // ─── SupplierItem ─────────────────────────────────────────────────────────

  async createSupplierItem(dto: CreateSupplierItemDto): Promise<SupplierItemDocument> {
    return this.supplierItemModel.create({
      ...dto,
      itemId: new Types.ObjectId(dto.itemId),
      supplierId: new Types.ObjectId(dto.supplierId),
    });
  }

  async findSupplierItemById(id: string): Promise<SupplierItemDocument | null> {
    return this.supplierItemModel.findOne({ _id: id }).exec();
  }

  async findSupplierItemByItemId(itemId: string): Promise<SupplierItemDocument | null> {
    return this.supplierItemModel
      .findOne({ itemId: new Types.ObjectId(itemId) })
      .exec();
  }

  async findSupplierItemsBySupplierId(supplierId: string): Promise<SupplierItemDocument[]> {
    return this.supplierItemModel
      .find({ supplierId: new Types.ObjectId(supplierId) })
      .sort({ updatedAt: -1 })
      .exec();
  }

  async updateSupplierItem(
    id: string,
    dto: UpdateSupplierItemDto,
  ): Promise<SupplierItemDocument | null> {
    const update: Record<string, unknown> = { ...dto };
    if (dto.supplierId) update['supplierId'] = new Types.ObjectId(dto.supplierId);
    return this.supplierItemModel
      .findOneAndUpdate({ _id: id }, update, { new: true })
      .exec();
  }
}
```

- [ ] **Bước 4: Chạy test — phải PASS**

```bash
pnpm test -- --testPathPattern="supplier.repository.spec" --no-coverage
```

Expected: PASS (5 tests)

- [ ] **Bước 5: Commit**

```bash
git add apps/wms/src/supplier/supplier.repository.ts apps/wms/src/supplier/supplier.repository.spec.ts
git commit -m "feat(wms/supplier): thêm SupplierRepository (Supplier + SupplierItem)"
```

---

## Task 5: SupplierService

**Files:**
- Create: `apps/wms/src/supplier/supplier.service.ts`
- Create: `apps/wms/src/supplier/supplier.service.spec.ts`

**Interfaces:**
- Consumes: `SupplierRepository`, `AppException`, `SupplierStatus`, tất cả DTO
- Produces: `SupplierService` với public methods:
  - `createSupplier(dto, actorId): Promise<SupplierDocument>`
  - `listSuppliers(query): Promise<{ data: SupplierDocument[]; total: number }>`
  - `getSupplier(id): Promise<SupplierDocument>`
  - `updateSupplier(id, dto, actorId): Promise<SupplierDocument>`
  - `changeStatus(id, dto, actorId): Promise<SupplierDocument>` — kiểm tra transition rules
  - `deleteSupplier(id, actorId): Promise<void>`
  - `upsertSupplierItem(dto): Promise<SupplierItemDocument>` — create nếu chưa có SKU, update nếu đã có
  - `getSupplierItem(id): Promise<SupplierItemDocument>`
  - `getSupplierItemByItemId(itemId): Promise<SupplierItemDocument>`
  - `updateSupplierItem(id, dto): Promise<SupplierItemDocument>`
  - `assertSupplierActive(supplierId): Promise<void>` — guard PO: throw nếu NCC không ACTIVE

- [ ] **Bước 1: Tạo supplier.service.spec.ts (test trước)**

```typescript
// apps/wms/src/supplier/supplier.service.spec.ts
import { AppException } from '@app/common';
import { SupplierService } from './supplier.service';
import { SupplierStatus } from './schemas/supplier.schema';

const makeRepo = () => ({
  createSupplier: jest.fn(),
  findSupplierById: jest.fn(),
  findSupplierByCode: jest.fn(),
  findSuppliers: jest.fn(),
  updateSupplier: jest.fn(),
  changeSupplierStatus: jest.fn(),
  softDeleteSupplier: jest.fn(),
  createSupplierItem: jest.fn(),
  findSupplierItemById: jest.fn(),
  findSupplierItemByItemId: jest.fn(),
  findSupplierItemsBySupplierId: jest.fn(),
  updateSupplierItem: jest.fn(),
});

describe('SupplierService', () => {
  let svc: SupplierService;
  let repo: ReturnType<typeof makeRepo>;
  const actorId = 'actor123';
  const supplierId = 'sup001';
  const itemId = 'item001';

  beforeEach(() => {
    repo = makeRepo();
    svc = new SupplierService(repo as never);
  });

  // ─── createSupplier ───────────────────────────────────────────────────────

  describe('createSupplier', () => {
    it('throw SUPPLIER_CODE_EXISTS khi code đã tồn tại', async () => {
      repo.findSupplierByCode.mockResolvedValue({ code: 'NCC-001' });
      await expect(
        svc.createSupplier({ code: 'NCC-001', name: 'Test' }, actorId),
      ).rejects.toMatchObject({ errorCode: 'SUPPLIER_CODE_EXISTS' });
    });

    it('tạo NCC mới khi code chưa tồn tại', async () => {
      repo.findSupplierByCode.mockResolvedValue(null);
      repo.createSupplier.mockResolvedValue({ code: 'NCC-001' });
      await svc.createSupplier({ code: 'NCC-001', name: 'Test' }, actorId);
      expect(repo.createSupplier).toHaveBeenCalledWith(
        { code: 'NCC-001', name: 'Test' },
        actorId,
      );
    });
  });

  // ─── changeStatus ─────────────────────────────────────────────────────────

  describe('changeStatus — BLACKLIST → ACTIVE chỉ ADMIN', () => {
    const blacklistedDoc = { status: SupplierStatus.BLACKLIST };

    it('MANAGER không thể gỡ BLACKLIST', async () => {
      repo.findSupplierById.mockResolvedValue(blacklistedDoc);
      await expect(
        svc.changeStatus(
          supplierId,
          { status: SupplierStatus.ACTIVE },
          actorId,
          ['MANAGER'],
        ),
      ).rejects.toMatchObject({ errorCode: 'SUPPLIER_BLACKLISTED' });
    });

    it('ADMIN có thể gỡ BLACKLIST', async () => {
      repo.findSupplierById.mockResolvedValue(blacklistedDoc);
      repo.changeSupplierStatus.mockResolvedValue({ status: SupplierStatus.ACTIVE });
      await expect(
        svc.changeStatus(
          supplierId,
          { status: SupplierStatus.ACTIVE },
          actorId,
          ['ADMIN'],
        ),
      ).resolves.toBeDefined();
    });
  });

  // ─── assertSupplierActive (guard PO) ─────────────────────────────────────

  describe('assertSupplierActive', () => {
    it('throw SUPPLIER_NOT_FOUND khi không tìm thấy NCC', async () => {
      repo.findSupplierById.mockResolvedValue(null);
      await expect(svc.assertSupplierActive(supplierId)).rejects.toMatchObject({
        errorCode: 'SUPPLIER_NOT_FOUND',
      });
    });

    it('throw SUPPLIER_NOT_ACTIVE khi status INACTIVE', async () => {
      repo.findSupplierById.mockResolvedValue({ status: SupplierStatus.INACTIVE });
      await expect(svc.assertSupplierActive(supplierId)).rejects.toMatchObject({
        errorCode: 'SUPPLIER_NOT_ACTIVE',
      });
    });

    it('throw SUPPLIER_NOT_ACTIVE khi status BLACKLIST', async () => {
      repo.findSupplierById.mockResolvedValue({ status: SupplierStatus.BLACKLIST });
      await expect(svc.assertSupplierActive(supplierId)).rejects.toMatchObject({
        errorCode: 'SUPPLIER_NOT_ACTIVE',
      });
    });

    it('không throw khi status ACTIVE', async () => {
      repo.findSupplierById.mockResolvedValue({ status: SupplierStatus.ACTIVE });
      await expect(svc.assertSupplierActive(supplierId)).resolves.toBeUndefined();
    });
  });

  // ─── upsertSupplierItem ───────────────────────────────────────────────────

  describe('upsertSupplierItem', () => {
    const dto = {
      itemId,
      supplierId,
      purchasePrice: 10000,
    };

    it('tạo mới khi SKU chưa có NCC chính', async () => {
      repo.findSupplierItemByItemId.mockResolvedValue(null);
      repo.createSupplierItem.mockResolvedValue({ itemId });
      await svc.upsertSupplierItem(dto);
      expect(repo.createSupplierItem).toHaveBeenCalledWith(dto);
    });

    it('update khi SKU đã có NCC chính', async () => {
      const existing = { _id: { toString: () => 'existingId' }, itemId };
      repo.findSupplierItemByItemId.mockResolvedValue(existing);
      repo.updateSupplierItem.mockResolvedValue({ itemId });
      await svc.upsertSupplierItem(dto);
      expect(repo.updateSupplierItem).toHaveBeenCalledWith('existingId', dto);
    });
  });
});
```

- [ ] **Bước 2: Chạy test — phải FAIL**

```bash
pnpm test -- --testPathPattern="supplier.service.spec" --no-coverage
```

Expected: FAIL — "Cannot find module './supplier.service'"

- [ ] **Bước 3: Tạo supplier.service.ts**

```typescript
// apps/wms/src/supplier/supplier.service.ts
import { Injectable } from '@nestjs/common';
import { AppException } from '@app/common';
import { SupplierRepository } from './supplier.repository';
import { SupplierStatus } from './schemas/supplier.schema';
import type { SupplierDocument } from './schemas/supplier.schema';
import type { SupplierItemDocument } from './schemas/supplier-item.schema';
import type { CreateSupplierDto, UpdateSupplierDto, ChangeSupplierStatusDto, QuerySupplierDto } from './dto/supplier.dto';
import type { CreateSupplierItemDto, UpdateSupplierItemDto } from './dto/supplier-item.dto';
import { WmsRole } from '@app/auth';

@Injectable()
export class SupplierService {
  constructor(private readonly repo: SupplierRepository) {}

  // ─── Supplier ─────────────────────────────────────────────────────────────

  async createSupplier(dto: CreateSupplierDto, actorId: string): Promise<SupplierDocument> {
    const existing = await this.repo.findSupplierByCode(dto.code);
    if (existing) throw new AppException('SUPPLIER_CODE_EXISTS');
    return this.repo.createSupplier(dto, actorId);
  }

  async listSuppliers(query: QuerySupplierDto): Promise<{ data: SupplierDocument[]; total: number }> {
    return this.repo.findSuppliers(query);
  }

  async getSupplier(id: string): Promise<SupplierDocument> {
    const doc = await this.repo.findSupplierById(id);
    if (!doc) throw new AppException('SUPPLIER_NOT_FOUND');
    return doc;
  }

  async updateSupplier(id: string, dto: UpdateSupplierDto, actorId: string): Promise<SupplierDocument> {
    const doc = await this.repo.updateSupplier(id, dto, actorId);
    if (!doc) throw new AppException('SUPPLIER_NOT_FOUND');
    return doc;
  }

  /**
   * Đổi trạng thái NCC. Quy tắc: gỡ BLACKLIST → ACTIVE chỉ ADMIN mới làm được.
   * roles = mảng role hiện tại của actor (lấy từ JWT payload).
   */
  async changeStatus(
    id: string,
    dto: ChangeSupplierStatusDto,
    actorId: string,
    roles: string[],
  ): Promise<SupplierDocument> {
    const supplier = await this.repo.findSupplierById(id);
    if (!supplier) throw new AppException('SUPPLIER_NOT_FOUND');

    // gỡ blacklist chỉ ADMIN
    if (
      supplier.status === SupplierStatus.BLACKLIST &&
      dto.status !== SupplierStatus.BLACKLIST &&
      !roles.includes(WmsRole.ADMIN)
    ) {
      throw new AppException('SUPPLIER_BLACKLISTED');
    }

    const doc = await this.repo.changeSupplierStatus(id, dto.status, actorId);
    if (!doc) throw new AppException('SUPPLIER_NOT_FOUND');
    return doc;
  }

  async deleteSupplier(id: string, actorId: string): Promise<void> {
    const deleted = await this.repo.softDeleteSupplier(id, actorId);
    if (!deleted) throw new AppException('SUPPLIER_NOT_FOUND');
  }

  // ─── SupplierItem ─────────────────────────────────────────────────────────

  /**
   * Tạo nếu SKU chưa có NCC chính, cập nhật nếu đã có.
   * Spec: 1 SKU ↔ 1 dòng SupplierItem.
   */
  async upsertSupplierItem(dto: CreateSupplierItemDto): Promise<SupplierItemDocument> {
    const existing = await this.repo.findSupplierItemByItemId(dto.itemId);
    if (!existing) {
      return this.repo.createSupplierItem(dto);
    }
    const updated = await this.repo.updateSupplierItem(existing._id.toString(), dto);
    if (!updated) throw new AppException('SUPPLIER_ITEM_NOT_FOUND');
    return updated;
  }

  async getSupplierItem(id: string): Promise<SupplierItemDocument> {
    const doc = await this.repo.findSupplierItemById(id);
    if (!doc) throw new AppException('SUPPLIER_ITEM_NOT_FOUND');
    return doc;
  }

  async getSupplierItemByItemId(itemId: string): Promise<SupplierItemDocument> {
    const doc = await this.repo.findSupplierItemByItemId(itemId);
    if (!doc) throw new AppException('SUPPLIER_ITEM_NOT_FOUND');
    return doc;
  }

  async updateSupplierItem(id: string, dto: UpdateSupplierItemDto): Promise<SupplierItemDocument> {
    const doc = await this.repo.updateSupplierItem(id, dto);
    if (!doc) throw new AppException('SUPPLIER_ITEM_NOT_FOUND');
    return doc;
  }

  /**
   * Guard cho PO: chặn xác nhận PO khi NCC không ACTIVE.
   * Module PO gọi method này tại bước DRAFT → CONFIRMED.
   */
  async assertSupplierActive(supplierId: string): Promise<void> {
    const supplier = await this.repo.findSupplierById(supplierId);
    if (!supplier) throw new AppException('SUPPLIER_NOT_FOUND');
    if (supplier.status !== SupplierStatus.ACTIVE) {
      throw new AppException('SUPPLIER_NOT_ACTIVE');
    }
  }
}
```

- [ ] **Bước 4: Chạy test — phải PASS**

```bash
pnpm test -- --testPathPattern="supplier.service.spec" --no-coverage
```

Expected: PASS (8 tests)

- [ ] **Bước 5: Commit**

```bash
git add apps/wms/src/supplier/supplier.service.ts apps/wms/src/supplier/supplier.service.spec.ts
git commit -m "feat(wms/supplier): thêm SupplierService (CRUD + status guard + assertSupplierActive)"
```

---

## Task 6: SupplierController + SupplierModule + wire vào AppModule

**Files:**
- Create: `apps/wms/src/supplier/supplier.controller.ts`
- Create: `apps/wms/src/supplier/supplier.module.ts`
- Modify: `apps/wms/src/app.module.ts`

**Interfaces:**
- Consumes: `SupplierService`, tất cả DTO, `JwtAuthGuard`, `RolesGuard`, `WmsRole`, `CurrentUser`
- Produces: REST endpoints tại prefix `supplier` (dưới global prefix `api/wms`):
  - `POST /supplier` — tạo NCC [MANAGER, ADMIN]
  - `GET /supplier` — danh sách NCC [MANAGER, ADMIN]
  - `GET /supplier/:id` — chi tiết NCC [MANAGER, ADMIN]
  - `PATCH /supplier/:id` — cập nhật thông tin NCC [MANAGER, ADMIN]
  - `PATCH /supplier/:id/status` — đổi trạng thái [MANAGER, ADMIN]
  - `DELETE /supplier/:id` — soft-delete [ADMIN]
  - `POST /supplier/items` — upsert danh mục giá SKU [MANAGER, ADMIN]
  - `GET /supplier/items/by-item/:itemId` — tra giá theo SKU [MANAGER, ADMIN]
  - `GET /supplier/items/:id` — chi tiết SupplierItem [MANAGER, ADMIN]
  - `PATCH /supplier/items/:id` — cập nhật SupplierItem [MANAGER, ADMIN]

- [ ] **Bước 1: Tạo supplier.controller.ts**

```typescript
// apps/wms/src/supplier/supplier.controller.ts
import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiCreatedResponse,
  ApiNoContentResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import { CurrentUser, JwtAuthGuard, Roles, RolesGuard, WmsRole } from '@app/auth';
import { plainToInstance } from 'class-transformer';
import { SupplierService } from './supplier.service';
import {
  ChangeSupplierStatusDto,
  CreateSupplierDto,
  QuerySupplierDto,
  SupplierResponseDto,
  UpdateSupplierDto,
} from './dto/supplier.dto';
import {
  CreateSupplierItemDto,
  SupplierItemResponseDto,
  UpdateSupplierItemDto,
} from './dto/supplier-item.dto';

const TO_OPTS = { excludeExtraneousValues: true } as const;

@ApiTags('supplier')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard, RolesGuard)
@Controller('supplier')
export class SupplierController {
  constructor(private readonly svc: SupplierService) {}

  // ─── Static sub-routes trước param routes ────────────────────────────────

  @Post('items')
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Upsert danh mục giá SKU — [MANAGER, ADMIN]' })
  @ApiCreatedResponse({ type: SupplierItemResponseDto })
  async upsertSupplierItem(
    @Body() dto: CreateSupplierItemDto,
  ): Promise<SupplierItemResponseDto> {
    const doc = await this.svc.upsertSupplierItem(dto);
    return plainToInstance(SupplierItemResponseDto, doc.toObject(), TO_OPTS);
  }

  @Get('items/by-item/:itemId')
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Tra giá NCC theo itemId (SKU) — [MANAGER, ADMIN]' })
  @ApiOkResponse({ type: SupplierItemResponseDto })
  async getSupplierItemByItemId(
    @Param('itemId') itemId: string,
  ): Promise<SupplierItemResponseDto> {
    const doc = await this.svc.getSupplierItemByItemId(itemId);
    return plainToInstance(SupplierItemResponseDto, doc.toObject(), TO_OPTS);
  }

  @Get('items/:id')
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Chi tiết SupplierItem — [MANAGER, ADMIN]' })
  @ApiOkResponse({ type: SupplierItemResponseDto })
  async getSupplierItem(@Param('id') id: string): Promise<SupplierItemResponseDto> {
    const doc = await this.svc.getSupplierItem(id);
    return plainToInstance(SupplierItemResponseDto, doc.toObject(), TO_OPTS);
  }

  @Patch('items/:id')
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Cập nhật SupplierItem — [MANAGER, ADMIN]' })
  @ApiOkResponse({ type: SupplierItemResponseDto })
  async updateSupplierItem(
    @Param('id') id: string,
    @Body() dto: UpdateSupplierItemDto,
  ): Promise<SupplierItemResponseDto> {
    const doc = await this.svc.updateSupplierItem(id, dto);
    return plainToInstance(SupplierItemResponseDto, doc.toObject(), TO_OPTS);
  }

  // ─── Supplier routes ──────────────────────────────────────────────────────

  @Post()
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Tạo nhà cung cấp — [MANAGER, ADMIN]' })
  @ApiCreatedResponse({ type: SupplierResponseDto })
  async createSupplier(
    @Body() dto: CreateSupplierDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<SupplierResponseDto> {
    const doc = await this.svc.createSupplier(dto, actorId);
    return plainToInstance(SupplierResponseDto, doc.toObject(), TO_OPTS);
  }

  @Get()
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Danh sách NCC — [MANAGER, ADMIN]' })
  @ApiOkResponse({ type: [SupplierResponseDto] })
  async listSuppliers(@Query() query: QuerySupplierDto): Promise<{
    data: SupplierResponseDto[];
    total: number;
    page: number;
    limit: number;
  }> {
    const { data, total } = await this.svc.listSuppliers(query);
    return {
      data: plainToInstance(
        SupplierResponseDto,
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
  @ApiOperation({ summary: 'Chi tiết NCC — [MANAGER, ADMIN]' })
  @ApiOkResponse({ type: SupplierResponseDto })
  async getSupplier(@Param('id') id: string): Promise<SupplierResponseDto> {
    const doc = await this.svc.getSupplier(id);
    return plainToInstance(SupplierResponseDto, doc.toObject(), TO_OPTS);
  }

  @Patch(':id')
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Cập nhật thông tin NCC — [MANAGER, ADMIN]' })
  @ApiOkResponse({ type: SupplierResponseDto })
  async updateSupplier(
    @Param('id') id: string,
    @Body() dto: UpdateSupplierDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<SupplierResponseDto> {
    const doc = await this.svc.updateSupplier(id, dto, actorId);
    return plainToInstance(SupplierResponseDto, doc.toObject(), TO_OPTS);
  }

  @Patch(':id/status')
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Đổi trạng thái NCC — [MANAGER, ADMIN] (gỡ BLACKLIST: chỉ ADMIN)' })
  @ApiOkResponse({ type: SupplierResponseDto })
  async changeStatus(
    @Param('id') id: string,
    @Body() dto: ChangeSupplierStatusDto,
    @CurrentUser('sub') actorId: string,
    @CurrentUser('roles') roles: string[],
  ): Promise<SupplierResponseDto> {
    const doc = await this.svc.changeStatus(id, dto, actorId, roles);
    return plainToInstance(SupplierResponseDto, doc.toObject(), TO_OPTS);
  }

  @Delete(':id')
  @Roles(WmsRole.ADMIN)
  @HttpCode(HttpStatus.NO_CONTENT)
  @ApiOperation({ summary: 'Xoá NCC (soft-delete) — [ADMIN]' })
  @ApiNoContentResponse()
  async deleteSupplier(
    @Param('id') id: string,
    @CurrentUser('sub') actorId: string,
  ): Promise<void> {
    await this.svc.deleteSupplier(id, actorId);
  }
}
```

- [ ] **Bước 2: Tạo supplier.module.ts**

```typescript
// apps/wms/src/supplier/supplier.module.ts
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { Supplier, SupplierSchema } from './schemas/supplier.schema';
import { SupplierItem, SupplierItemSchema } from './schemas/supplier-item.schema';
import { SupplierRepository } from './supplier.repository';
import { SupplierService } from './supplier.service';
import { SupplierController } from './supplier.controller';

@Module({
  imports: [
    MongooseModule.forFeature([
      { name: Supplier.name, schema: SupplierSchema },
      { name: SupplierItem.name, schema: SupplierItemSchema },
    ]),
  ],
  providers: [SupplierRepository, SupplierService],
  controllers: [SupplierController],
  exports: [SupplierService], // module PO dùng assertSupplierActive khi xác nhận PO
})
export class SupplierModule {}
```

- [ ] **Bước 3: Import SupplierModule vào AppModule**

Mở `apps/wms/src/app.module.ts`, thêm import:

```typescript
import { SupplierModule } from './supplier/supplier.module';
```

Thêm `SupplierModule` vào mảng `imports` (sau `WarehouseModule`):

```typescript
SupplierModule, // CRUD NCC + bảng giá SupplierItem
```

- [ ] **Bước 4: Build toàn bộ WMS app**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
nest build wms 2>&1 | tail -20
```

Expected: Build succeeded, không có TypeScript errors.

Nếu có lỗi: đọc error message, sửa type, chạy lại.

- [ ] **Bước 5: Chạy toàn bộ test suite**

```bash
pnpm test -- --no-coverage 2>&1 | tail -30
```

Expected: Tất cả test PASS (không có FAIL mới so với trước sprint).

- [ ] **Bước 6: Commit**

```bash
git add apps/wms/src/supplier/supplier.controller.ts \
        apps/wms/src/supplier/supplier.module.ts \
        apps/wms/src/app.module.ts
git commit -m "feat(wms/supplier): wire SupplierController + SupplierModule vào AppModule"
```

---

## Self-Review

### 1. Spec coverage

| Yêu cầu spec | Task thực hiện |
|---|---|
| UC-S01 CRUD NCC | Task 4 (repo) + Task 5 (service) + Task 6 (controller POST/GET/PATCH/DELETE) |
| UC-S02 Trạng thái ACTIVE/INACTIVE/BLACKLIST | Task 1 (enum) + Task 5 `changeStatus` + Task 6 `PATCH :id/status` |
| UC-S02 gỡ BLACKLIST chỉ ADMIN | Task 5 `changeStatus` kiểm tra roles + test MANAGER bị chặn / ADMIN qua được |
| UC-S03 Danh mục giá 1 NCC/SKU | Task 1 `SupplierItem` unique `itemId` + Task 5 `upsertSupplierItem` |
| UC-S04 Gợi ý NCC + guard PO | Task 5 `assertSupplierActive` + `getSupplierItemByItemId` + Task 6 `GET items/by-item/:itemId` |
| Audit master data | Task 1 `Supplier` schema: `createdBy`, `updatedBy`, `deletedAt`, `timestamps:true` |
| Soft-delete NCC | Task 4 `softDeleteSupplier` + Task 5 `deleteSupplier` + Task 6 `DELETE :id` |
| SupplierItem không soft-delete, toggle isActive | Task 1 schema không có `deletedAt` + Task 5 `updateSupplierItem(dto)` với `isActive` |
| Error codes ổn định | Task 2 `WMS_ERRORS` |
| Swagger roles trong summary | Task 6 mọi `@ApiOperation` đều có `— [ROLE1, ROLE2]` |

### 2. Placeholder scan
Không có placeholder — mọi step có code đầy đủ.

### 3. Type consistency
- `SupplierStatus` export từ `supplier.schema.ts`, import trong `supplier.dto.ts`, `supplier.repository.ts`, `supplier.service.ts` — nhất quán.
- Method signatures repo → service → controller nhất quán (repo `changeSupplierStatus`, service `changeStatus` gọi repo.`changeSupplierStatus`).
- `assertSupplierActive(supplierId: string): Promise<void>` — định nghĩa Task 5, không thay đổi ở Task 6.
