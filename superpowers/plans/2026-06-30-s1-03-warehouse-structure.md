# S1-03: Warehouse Structure (Kho/Zone/Rack/Shelf) + CRUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tạo đầy đủ schema Mongoose cho cấu trúc kho (Warehouse → Zone → Rack → Shelf) cùng CRUD API cho MANAGER, đủ để Sprint 2 (GRN, Put-away) tham chiếu `shelfId`/`warehouseId`.

**Architecture:** Module mới `warehouse` trong `apps/wms/src/warehouse/` — schema, repository, service, controller, dto theo đúng pattern domain hiện có (xem `apps/wms/src/auth/`). Mỗi entity một file schema riêng. Soft-delete (`deletedAt`) cho cả 4 entity vì đây là master data. Kết nối DB qua `MongooseModule.forFeature` đã có sẵn từ `DatabaseModule.forApp('WMS_DATABASE_URL')` trong `AppModule`.

**Tech Stack:** NestJS, `@nestjs/mongoose`, Mongoose, `class-validator`, `class-transformer`, `@nestjs/swagger`, `@app/auth` (JwtAuthGuard/RolesGuard/WmsRole), `@app/common` (AppException).

## Global Constraints

- Import lib qua `@app/auth`, `@app/common`, `@app/database` — không import chéo apps.
- Tên collection snake_case cũ: `@Schema({ collection: 'warehouses', timestamps: true })`.
- Audit master data: `createdBy`, `updatedBy`, `deletedAt` — soft-delete, filter `deletedAt: null`.
- Không dùng `any` — mọi type phải tường minh.
- `@Transform` callback phải type `obj` theo shape thật: `({ obj }: { obj: { _id?: Types.ObjectId } })`.
- Response DTO dùng `@Expose()` + `plainToInstance(..., { excludeExtraneousValues: true })`.
- `@ApiOperation({ summary: '...' })` phải ghi `— [ROLE]` cho mọi endpoint có `@Roles(...)`.
- Mọi enum field trong DTO phải có `@ApiProperty({ enum: XxxEnum })`.
- Service throw `AppException` (từ `@app/common`) — không throw NestJS exception thô.
- Prefix route: WMS = `api/wms` (đã set global trong `main.ts`), controller prefix = `warehouse`.
- `ADMIN` bypass mọi role — `RolesGuard` đã xử lý, chỉ cần khai `@Roles(WmsRole.MANAGER)`.

---

## File Structure

```
apps/wms/src/warehouse/
  schemas/
    warehouse.schema.ts          ← Warehouse entity + type
    zone.schema.ts               ← Zone entity + type
    rack.schema.ts               ← Rack entity + type
    shelf.schema.ts              ← Shelf entity + type
  dto/
    warehouse.dto.ts             ← Create/Update/Response DTO cho Warehouse
    zone.dto.ts                  ← Create/Update/Response DTO cho Zone
    rack.dto.ts                  ← Create/Update/Response DTO cho Rack
    shelf.dto.ts                 ← Create/Update/Response DTO cho Shelf
  warehouse.repository.ts        ← Query Mongoose cho cả 4 entity
  warehouse.service.ts           ← Business logic CRUD
  warehouse.controller.ts        ← REST endpoints
  warehouse.module.ts            ← Module declaration
apps/wms/src/common/error-codes.ts   ← Thêm WMS_ERRORS cho warehouse
apps/wms/src/app.module.ts           ← Import WarehouseModule
```

---

## Task 1: 4 Mongoose Schemas

**Files:**
- Create: `apps/wms/src/warehouse/schemas/warehouse.schema.ts`
- Create: `apps/wms/src/warehouse/schemas/zone.schema.ts`
- Create: `apps/wms/src/warehouse/schemas/rack.schema.ts`
- Create: `apps/wms/src/warehouse/schemas/shelf.schema.ts`

**Interfaces:**
- Produces:
  - `Warehouse`, `WarehouseDocument`, `WarehouseSchema`
  - `Zone`, `ZoneDocument`, `ZoneSchema`
  - `Rack`, `RackDocument`, `RackSchema`
  - `Shelf`, `ShelfDocument`, `ShelfSchema`

- [ ] **Step 1: Tạo warehouse.schema.ts**

```typescript
// apps/wms/src/warehouse/schemas/warehouse.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

@Schema({ collection: 'warehouses', timestamps: true })
export class Warehouse {
  @Prop({ required: true })
  name!: string;

  @Prop({ required: true })
  address!: string;

  @Prop({ default: true })
  isActive!: boolean;

  // audit master data
  @Prop({ type: Types.ObjectId })
  createdBy?: Types.ObjectId;

  @Prop({ type: Types.ObjectId })
  updatedBy?: Types.ObjectId;

  @Prop({ type: Date, default: null })
  deletedAt?: Date | null;
}

export type WarehouseDocument = HydratedDocument<Warehouse>;
export const WarehouseSchema = SchemaFactory.createForClass(Warehouse);
// index hỗ trợ soft-delete filter
WarehouseSchema.index({ deletedAt: 1 });
```

- [ ] **Step 2: Tạo zone.schema.ts**

```typescript
// apps/wms/src/warehouse/schemas/zone.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, SchemaTypes, Types } from 'mongoose';

@Schema({ collection: 'zones', timestamps: true })
export class Zone {
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

  @Prop({ required: true })
  name!: string;

  @Prop({ required: true })
  code!: string;

  @Prop({ type: Types.ObjectId })
  createdBy?: Types.ObjectId;

  @Prop({ type: Types.ObjectId })
  updatedBy?: Types.ObjectId;

  @Prop({ type: Date, default: null })
  deletedAt?: Date | null;
}

export type ZoneDocument = HydratedDocument<Zone>;
export const ZoneSchema = SchemaFactory.createForClass(Zone);
ZoneSchema.index({ warehouseId: 1, deletedAt: 1 });
ZoneSchema.index({ warehouseId: 1, code: 1 }, { unique: true, partialFilterExpression: { deletedAt: null } });
```

- [ ] **Step 3: Tạo rack.schema.ts**

```typescript
// apps/wms/src/warehouse/schemas/rack.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, SchemaTypes, Types } from 'mongoose';

@Schema({ collection: 'racks', timestamps: true })
export class Rack {
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  zoneId!: Types.ObjectId;

  @Prop({ required: true })
  name!: string;

  @Prop({ required: true })
  code!: string;

  @Prop({ type: Types.ObjectId })
  createdBy?: Types.ObjectId;

  @Prop({ type: Types.ObjectId })
  updatedBy?: Types.ObjectId;

  @Prop({ type: Date, default: null })
  deletedAt?: Date | null;
}

export type RackDocument = HydratedDocument<Rack>;
export const RackSchema = SchemaFactory.createForClass(Rack);
RackSchema.index({ zoneId: 1, deletedAt: 1 });
RackSchema.index({ zoneId: 1, code: 1 }, { unique: true, partialFilterExpression: { deletedAt: null } });
```

- [ ] **Step 4: Tạo shelf.schema.ts**

```typescript
// apps/wms/src/warehouse/schemas/shelf.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, SchemaTypes, Types } from 'mongoose';

@Schema({ collection: 'shelves', timestamps: true })
export class Shelf {
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  rackId!: Types.ObjectId;

  @Prop({ required: true })
  level!: number;

  /** Giá trị barcode vị trí — dán tem ở mỗi shelf, quét khi put-away/pick */
  @Prop({ required: true, unique: true })
  code!: string;

  @Prop()
  innerDepth?: number;

  @Prop()
  innerWidth?: number;

  @Prop()
  innerHeight?: number;

  /** Override fill factor mặc định hệ thống (0–1). null = dùng mặc định */
  @Prop({ type: Number, default: null })
  fillFactor?: number | null;

  /** true = shelf "khu nhận hàng" (staging), nơi hàng nằm tạm sau GRN */
  @Prop({ default: false })
  isStaging!: boolean;

  @Prop({ type: Types.ObjectId })
  createdBy?: Types.ObjectId;

  @Prop({ type: Types.ObjectId })
  updatedBy?: Types.ObjectId;

  @Prop({ type: Date, default: null })
  deletedAt?: Date | null;
}

export type ShelfDocument = HydratedDocument<Shelf>;
export const ShelfSchema = SchemaFactory.createForClass(Shelf);
ShelfSchema.index({ rackId: 1, deletedAt: 1 });
// code là barcode vị trí — unique toàn hệ thống khi chưa xoá
ShelfSchema.index({ code: 1 }, { unique: true, partialFilterExpression: { deletedAt: null } });
```

- [ ] **Step 5: Commit schemas**

```bash
git add apps/wms/src/warehouse/schemas/
git commit -m "feat(wms): add Warehouse/Zone/Rack/Shelf Mongoose schemas (S1-03)"
```

---

## Task 2: DTOs (Request + Response)

**Files:**
- Create: `apps/wms/src/warehouse/dto/warehouse.dto.ts`
- Create: `apps/wms/src/warehouse/dto/zone.dto.ts`
- Create: `apps/wms/src/warehouse/dto/rack.dto.ts`
- Create: `apps/wms/src/warehouse/dto/shelf.dto.ts`

**Interfaces:**
- Consumes: `Types.ObjectId` từ mongoose
- Produces:
  - `CreateWarehouseDto`, `UpdateWarehouseDto`, `WarehouseResponseDto`
  - `CreateZoneDto`, `UpdateZoneDto`, `ZoneResponseDto`
  - `CreateRackDto`, `UpdateRackDto`, `RackResponseDto`
  - `CreateShelfDto`, `UpdateShelfDto`, `ShelfResponseDto`

- [ ] **Step 1: Tạo warehouse.dto.ts**

```typescript
// apps/wms/src/warehouse/dto/warehouse.dto.ts
import { ApiProperty, ApiPropertyOptional, PartialType } from '@nestjs/swagger';
import { Expose, Transform } from 'class-transformer';
import { IsBoolean, IsOptional, IsString, MinLength } from 'class-validator';
import { Types } from 'mongoose';

export class CreateWarehouseDto {
  @ApiProperty({ example: 'Kho trung tâm' })
  @IsString()
  @MinLength(1)
  name!: string;

  @ApiProperty({ example: '123 Nguyễn Văn Linh, Q7, TP.HCM' })
  @IsString()
  @MinLength(1)
  address!: string;

  @ApiPropertyOptional({ default: true })
  @IsOptional()
  @IsBoolean()
  isActive?: boolean;
}

export class UpdateWarehouseDto extends PartialType(CreateWarehouseDto) {}

export class WarehouseResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) => obj._id?.toString())
  @ApiProperty()
  id!: string;

  @Expose()
  @ApiProperty()
  name!: string;

  @Expose()
  @ApiProperty()
  address!: string;

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

- [ ] **Step 2: Tạo zone.dto.ts**

```typescript
// apps/wms/src/warehouse/dto/zone.dto.ts
import { ApiProperty, PartialType } from '@nestjs/swagger';
import { Expose, Transform } from 'class-transformer';
import { IsMongoId, IsString, MinLength } from 'class-validator';
import { Types } from 'mongoose';

export class CreateZoneDto {
  @ApiProperty({ example: '60d5ec49f1b2c72b3c8e4f01' })
  @IsMongoId()
  warehouseId!: string;

  @ApiProperty({ example: 'Khu A' })
  @IsString()
  @MinLength(1)
  name!: string;

  @ApiProperty({ example: 'A' })
  @IsString()
  @MinLength(1)
  code!: string;
}

export class UpdateZoneDto extends PartialType(CreateZoneDto) {}

export class ZoneResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) => obj._id?.toString())
  @ApiProperty()
  id!: string;

  @Expose()
  @Transform(({ obj }: { obj: { warehouseId?: Types.ObjectId } }) => obj.warehouseId?.toString())
  @ApiProperty()
  warehouseId!: string;

  @Expose()
  @ApiProperty()
  name!: string;

  @Expose()
  @ApiProperty()
  code!: string;

  @Expose()
  @ApiProperty()
  createdAt!: Date;

  @Expose()
  @ApiProperty()
  updatedAt!: Date;
}
```

- [ ] **Step 3: Tạo rack.dto.ts**

```typescript
// apps/wms/src/warehouse/dto/rack.dto.ts
import { ApiProperty, PartialType } from '@nestjs/swagger';
import { Expose, Transform } from 'class-transformer';
import { IsMongoId, IsString, MinLength } from 'class-validator';
import { Types } from 'mongoose';

export class CreateRackDto {
  @ApiProperty({ example: '60d5ec49f1b2c72b3c8e4f02' })
  @IsMongoId()
  zoneId!: string;

  @ApiProperty({ example: 'Kệ A1' })
  @IsString()
  @MinLength(1)
  name!: string;

  @ApiProperty({ example: 'A1' })
  @IsString()
  @MinLength(1)
  code!: string;
}

export class UpdateRackDto extends PartialType(CreateRackDto) {}

export class RackResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) => obj._id?.toString())
  @ApiProperty()
  id!: string;

  @Expose()
  @Transform(({ obj }: { obj: { zoneId?: Types.ObjectId } }) => obj.zoneId?.toString())
  @ApiProperty()
  zoneId!: string;

  @Expose()
  @ApiProperty()
  name!: string;

  @Expose()
  @ApiProperty()
  code!: string;

  @Expose()
  @ApiProperty()
  createdAt!: Date;

  @Expose()
  @ApiProperty()
  updatedAt!: Date;
}
```

- [ ] **Step 4: Tạo shelf.dto.ts**

```typescript
// apps/wms/src/warehouse/dto/shelf.dto.ts
import { ApiProperty, ApiPropertyOptional, PartialType } from '@nestjs/swagger';
import { Expose, Transform } from 'class-transformer';
import {
  IsBoolean,
  IsInt,
  IsMongoId,
  IsNumber,
  IsOptional,
  IsString,
  Max,
  Min,
  MinLength,
} from 'class-validator';
import { Types } from 'mongoose';

export class CreateShelfDto {
  @ApiProperty({ example: '60d5ec49f1b2c72b3c8e4f03' })
  @IsMongoId()
  rackId!: string;

  @ApiProperty({ example: 1, description: 'Số tầng (1, 2, 3...)' })
  @IsInt()
  @Min(1)
  level!: number;

  @ApiProperty({ example: 'A1-T1', description: 'Mã barcode vị trí — dán tem tại shelf' })
  @IsString()
  @MinLength(1)
  code!: string;

  @ApiPropertyOptional({ example: 120, description: 'Chiều sâu lòng tầng (cm)' })
  @IsOptional()
  @IsNumber()
  @Min(1)
  innerDepth?: number;

  @ApiPropertyOptional({ example: 80 })
  @IsOptional()
  @IsNumber()
  @Min(1)
  innerWidth?: number;

  @ApiPropertyOptional({ example: 50 })
  @IsOptional()
  @IsNumber()
  @Min(1)
  innerHeight?: number;

  @ApiPropertyOptional({ example: 0.8, description: 'Override fill factor (0–1). Bỏ trống = dùng mặc định hệ thống' })
  @IsOptional()
  @IsNumber()
  @Min(0)
  @Max(1)
  fillFactor?: number;

  @ApiPropertyOptional({ default: false, description: 'true = shelf staging (khu nhận hàng tạm)' })
  @IsOptional()
  @IsBoolean()
  isStaging?: boolean;
}

export class UpdateShelfDto extends PartialType(CreateShelfDto) {}

export class ShelfResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) => obj._id?.toString())
  @ApiProperty()
  id!: string;

  @Expose()
  @Transform(({ obj }: { obj: { rackId?: Types.ObjectId } }) => obj.rackId?.toString())
  @ApiProperty()
  rackId!: string;

  @Expose()
  @ApiProperty()
  level!: number;

  @Expose()
  @ApiProperty()
  code!: string;

  @Expose()
  @ApiPropertyOptional()
  innerDepth?: number;

  @Expose()
  @ApiPropertyOptional()
  innerWidth?: number;

  @Expose()
  @ApiPropertyOptional()
  innerHeight?: number;

  @Expose()
  @ApiPropertyOptional()
  fillFactor?: number | null;

  @Expose()
  @ApiProperty()
  isStaging!: boolean;

  @Expose()
  @ApiProperty()
  createdAt!: Date;

  @Expose()
  @ApiProperty()
  updatedAt!: Date;
}
```

- [ ] **Step 5: Commit DTOs**

```bash
git add apps/wms/src/warehouse/dto/
git commit -m "feat(wms): add Warehouse/Zone/Rack/Shelf DTOs (S1-03)"
```

---

## Task 3: Error Codes + Repository

**Files:**
- Modify: `apps/wms/src/common/error-codes.ts`
- Create: `apps/wms/src/warehouse/warehouse.repository.ts`

**Interfaces:**
- Consumes:
  - `Warehouse`, `WarehouseDocument`, `WarehouseSchema` từ Task 1
  - `Zone`, `ZoneDocument`, `ZoneSchema` từ Task 1
  - `Rack`, `RackDocument`, `RackSchema` từ Task 1
  - `Shelf`, `ShelfDocument`, `ShelfSchema` từ Task 1
- Produces: `WarehouseRepository` với các method:
  - `createWarehouse(data, actorId): Promise<WarehouseDocument>`
  - `findAllWarehouses(): Promise<WarehouseDocument[]>`
  - `findWarehouseById(id): Promise<WarehouseDocument | null>`
  - `updateWarehouse(id, data, actorId): Promise<WarehouseDocument | null>`
  - `softDeleteWarehouse(id, actorId): Promise<boolean>`
  - `createZone(data, actorId): Promise<ZoneDocument>`
  - `findZonesByWarehouse(warehouseId): Promise<ZoneDocument[]>`
  - `findZoneById(id): Promise<ZoneDocument | null>`
  - `updateZone(id, data, actorId): Promise<ZoneDocument | null>`
  - `softDeleteZone(id, actorId): Promise<boolean>`
  - `createRack(data, actorId): Promise<RackDocument>`
  - `findRacksByZone(zoneId): Promise<RackDocument[]>`
  - `findRackById(id): Promise<RackDocument | null>`
  - `updateRack(id, data, actorId): Promise<RackDocument | null>`
  - `softDeleteRack(id, actorId): Promise<boolean>`
  - `createShelf(data, actorId): Promise<ShelfDocument>`
  - `findShelvesByRack(rackId): Promise<ShelfDocument[]>`
  - `findShelfById(id): Promise<ShelfDocument | null>`
  - `findShelfByCode(code): Promise<ShelfDocument | null>`
  - `updateShelf(id, data, actorId): Promise<ShelfDocument | null>`
  - `softDeleteShelf(id, actorId): Promise<boolean>`

- [ ] **Step 1: Thêm error codes vào error-codes.ts**

```typescript
// apps/wms/src/common/error-codes.ts
import { HttpStatus, type HttpStatus as HttpStatusType } from '@nestjs/common';

export const WMS_ERRORS = {
  // Warehouse
  WAREHOUSE_NOT_FOUND:    { status: HttpStatus.NOT_FOUND,  message: 'Không tìm thấy kho' },
  WAREHOUSE_CODE_EXISTS:  { status: HttpStatus.CONFLICT,   message: 'Mã khu vực đã tồn tại trong kho này' },
  // Zone
  ZONE_NOT_FOUND:         { status: HttpStatus.NOT_FOUND,  message: 'Không tìm thấy khu vực' },
  ZONE_CODE_EXISTS:       { status: HttpStatus.CONFLICT,   message: 'Mã khu vực đã tồn tại trong kho này' },
  // Rack
  RACK_NOT_FOUND:         { status: HttpStatus.NOT_FOUND,  message: 'Không tìm thấy kệ' },
  RACK_CODE_EXISTS:       { status: HttpStatus.CONFLICT,   message: 'Mã kệ đã tồn tại trong zone này' },
  // Shelf
  SHELF_NOT_FOUND:        { status: HttpStatus.NOT_FOUND,  message: 'Không tìm thấy tầng kệ' },
  SHELF_CODE_EXISTS:      { status: HttpStatus.CONFLICT,   message: 'Mã barcode tầng đã tồn tại' },
} as const satisfies Record<string, { status: HttpStatusType; message: string }>;

export type WmsErrorCode = keyof typeof WMS_ERRORS;
```

- [ ] **Step 2: Tạo warehouse.repository.ts**

```typescript
// apps/wms/src/warehouse/warehouse.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import { Warehouse, WarehouseDocument } from './schemas/warehouse.schema';
import { Zone, ZoneDocument } from './schemas/zone.schema';
import { Rack, RackDocument } from './schemas/rack.schema';
import { Shelf, ShelfDocument } from './schemas/shelf.schema';
import { CreateWarehouseDto, UpdateWarehouseDto } from './dto/warehouse.dto';
import { CreateZoneDto, UpdateZoneDto } from './dto/zone.dto';
import { CreateRackDto, UpdateRackDto } from './dto/rack.dto';
import { CreateShelfDto, UpdateShelfDto } from './dto/shelf.dto';

const SOFT_DELETE_FILTER = { deletedAt: null } as const;

@Injectable()
export class WarehouseRepository {
  constructor(
    @InjectModel(Warehouse.name) private readonly warehouseModel: Model<WarehouseDocument>,
    @InjectModel(Zone.name) private readonly zoneModel: Model<ZoneDocument>,
    @InjectModel(Rack.name) private readonly rackModel: Model<RackDocument>,
    @InjectModel(Shelf.name) private readonly shelfModel: Model<ShelfDocument>,
  ) {}

  // ─── Warehouse ────────────────────────────────────────────────────────────

  async createWarehouse(dto: CreateWarehouseDto, actorId: string): Promise<WarehouseDocument> {
    return this.warehouseModel.create({
      ...dto,
      createdBy: new Types.ObjectId(actorId),
      updatedBy: new Types.ObjectId(actorId),
    });
  }

  async findAllWarehouses(): Promise<WarehouseDocument[]> {
    return this.warehouseModel.find(SOFT_DELETE_FILTER).sort({ createdAt: 1 }).exec();
  }

  async findWarehouseById(id: string): Promise<WarehouseDocument | null> {
    return this.warehouseModel.findOne({ _id: id, ...SOFT_DELETE_FILTER }).exec();
  }

  async updateWarehouse(
    id: string,
    dto: UpdateWarehouseDto,
    actorId: string,
  ): Promise<WarehouseDocument | null> {
    return this.warehouseModel
      .findOneAndUpdate(
        { _id: id, ...SOFT_DELETE_FILTER },
        { ...dto, updatedBy: new Types.ObjectId(actorId) },
        { new: true },
      )
      .exec();
  }

  async softDeleteWarehouse(id: string, actorId: string): Promise<boolean> {
    const res = await this.warehouseModel
      .updateOne(
        { _id: id, ...SOFT_DELETE_FILTER },
        { deletedAt: new Date(), updatedBy: new Types.ObjectId(actorId) },
      )
      .exec();
    return res.modifiedCount > 0;
  }

  // ─── Zone ─────────────────────────────────────────────────────────────────

  async createZone(dto: CreateZoneDto, actorId: string): Promise<ZoneDocument> {
    return this.zoneModel.create({
      ...dto,
      warehouseId: new Types.ObjectId(dto.warehouseId),
      createdBy: new Types.ObjectId(actorId),
      updatedBy: new Types.ObjectId(actorId),
    });
  }

  async findZonesByWarehouse(warehouseId: string): Promise<ZoneDocument[]> {
    return this.zoneModel
      .find({ warehouseId: new Types.ObjectId(warehouseId), ...SOFT_DELETE_FILTER })
      .sort({ code: 1 })
      .exec();
  }

  async findZoneById(id: string): Promise<ZoneDocument | null> {
    return this.zoneModel.findOne({ _id: id, ...SOFT_DELETE_FILTER }).exec();
  }

  async findZoneByCode(warehouseId: string, code: string): Promise<ZoneDocument | null> {
    return this.zoneModel
      .findOne({ warehouseId: new Types.ObjectId(warehouseId), code, ...SOFT_DELETE_FILTER })
      .exec();
  }

  async updateZone(id: string, dto: UpdateZoneDto, actorId: string): Promise<ZoneDocument | null> {
    const update: Record<string, unknown> = { ...dto, updatedBy: new Types.ObjectId(actorId) };
    if (dto.warehouseId) update['warehouseId'] = new Types.ObjectId(dto.warehouseId);
    return this.zoneModel
      .findOneAndUpdate({ _id: id, ...SOFT_DELETE_FILTER }, update, { new: true })
      .exec();
  }

  async softDeleteZone(id: string, actorId: string): Promise<boolean> {
    const res = await this.zoneModel
      .updateOne(
        { _id: id, ...SOFT_DELETE_FILTER },
        { deletedAt: new Date(), updatedBy: new Types.ObjectId(actorId) },
      )
      .exec();
    return res.modifiedCount > 0;
  }

  // ─── Rack ─────────────────────────────────────────────────────────────────

  async createRack(dto: CreateRackDto, actorId: string): Promise<RackDocument> {
    return this.rackModel.create({
      ...dto,
      zoneId: new Types.ObjectId(dto.zoneId),
      createdBy: new Types.ObjectId(actorId),
      updatedBy: new Types.ObjectId(actorId),
    });
  }

  async findRacksByZone(zoneId: string): Promise<RackDocument[]> {
    return this.rackModel
      .find({ zoneId: new Types.ObjectId(zoneId), ...SOFT_DELETE_FILTER })
      .sort({ code: 1 })
      .exec();
  }

  async findRackById(id: string): Promise<RackDocument | null> {
    return this.rackModel.findOne({ _id: id, ...SOFT_DELETE_FILTER }).exec();
  }

  async findRackByCode(zoneId: string, code: string): Promise<RackDocument | null> {
    return this.rackModel
      .findOne({ zoneId: new Types.ObjectId(zoneId), code, ...SOFT_DELETE_FILTER })
      .exec();
  }

  async updateRack(id: string, dto: UpdateRackDto, actorId: string): Promise<RackDocument | null> {
    const update: Record<string, unknown> = { ...dto, updatedBy: new Types.ObjectId(actorId) };
    if (dto.zoneId) update['zoneId'] = new Types.ObjectId(dto.zoneId);
    return this.rackModel
      .findOneAndUpdate({ _id: id, ...SOFT_DELETE_FILTER }, update, { new: true })
      .exec();
  }

  async softDeleteRack(id: string, actorId: string): Promise<boolean> {
    const res = await this.rackModel
      .updateOne(
        { _id: id, ...SOFT_DELETE_FILTER },
        { deletedAt: new Date(), updatedBy: new Types.ObjectId(actorId) },
      )
      .exec();
    return res.modifiedCount > 0;
  }

  // ─── Shelf ────────────────────────────────────────────────────────────────

  async createShelf(dto: CreateShelfDto, actorId: string): Promise<ShelfDocument> {
    return this.shelfModel.create({
      ...dto,
      rackId: new Types.ObjectId(dto.rackId),
      createdBy: new Types.ObjectId(actorId),
      updatedBy: new Types.ObjectId(actorId),
    });
  }

  async findShelvesByRack(rackId: string): Promise<ShelfDocument[]> {
    return this.shelfModel
      .find({ rackId: new Types.ObjectId(rackId), ...SOFT_DELETE_FILTER })
      .sort({ level: 1 })
      .exec();
  }

  async findShelfById(id: string): Promise<ShelfDocument | null> {
    return this.shelfModel.findOne({ _id: id, ...SOFT_DELETE_FILTER }).exec();
  }

  async findShelfByCode(code: string): Promise<ShelfDocument | null> {
    return this.shelfModel.findOne({ code, ...SOFT_DELETE_FILTER }).exec();
  }

  async updateShelf(id: string, dto: UpdateShelfDto, actorId: string): Promise<ShelfDocument | null> {
    const update: Record<string, unknown> = { ...dto, updatedBy: new Types.ObjectId(actorId) };
    if (dto.rackId) update['rackId'] = new Types.ObjectId(dto.rackId);
    return this.shelfModel
      .findOneAndUpdate({ _id: id, ...SOFT_DELETE_FILTER }, update, { new: true })
      .exec();
  }

  async softDeleteShelf(id: string, actorId: string): Promise<boolean> {
    const res = await this.shelfModel
      .updateOne(
        { _id: id, ...SOFT_DELETE_FILTER },
        { deletedAt: new Date(), updatedBy: new Types.ObjectId(actorId) },
      )
      .exec();
    return res.modifiedCount > 0;
  }
}
```

- [ ] **Step 3: Commit error codes + repository**

```bash
git add apps/wms/src/common/error-codes.ts apps/wms/src/warehouse/warehouse.repository.ts
git commit -m "feat(wms): add warehouse error codes and repository (S1-03)"
```

---

## Task 4: Service

**Files:**
- Create: `apps/wms/src/warehouse/warehouse.service.ts`

**Interfaces:**
- Consumes:
  - `WarehouseRepository` từ Task 3 (tất cả method)
  - `AppException` từ `@app/common`
  - `WMS_ERRORS` từ `apps/wms/src/common/error-codes.ts`
  - DTOs từ Task 2
- Produces: `WarehouseService` với các method public:
  - `createWarehouse(dto: CreateWarehouseDto, actorId: string): Promise<WarehouseDocument>`
  - `listWarehouses(): Promise<WarehouseDocument[]>`
  - `getWarehouse(id: string): Promise<WarehouseDocument>`
  - `updateWarehouse(id: string, dto: UpdateWarehouseDto, actorId: string): Promise<WarehouseDocument>`
  - `deleteWarehouse(id: string, actorId: string): Promise<void>`
  - `createZone(dto: CreateZoneDto, actorId: string): Promise<ZoneDocument>`
  - `listZones(warehouseId: string): Promise<ZoneDocument[]>`
  - `getZone(id: string): Promise<ZoneDocument>`
  - `updateZone(id: string, dto: UpdateZoneDto, actorId: string): Promise<ZoneDocument>`
  - `deleteZone(id: string, actorId: string): Promise<void>`
  - `createRack(dto: CreateRackDto, actorId: string): Promise<RackDocument>`
  - `listRacks(zoneId: string): Promise<RackDocument[]>`
  - `getRack(id: string): Promise<RackDocument>`
  - `updateRack(id: string, dto: UpdateRackDto, actorId: string): Promise<RackDocument>`
  - `deleteRack(id: string, actorId: string): Promise<void>`
  - `createShelf(dto: CreateShelfDto, actorId: string): Promise<ShelfDocument>`
  - `listShelves(rackId: string): Promise<ShelfDocument[]>`
  - `getShelf(id: string): Promise<ShelfDocument>`
  - `updateShelf(id: string, dto: UpdateShelfDto, actorId: string): Promise<ShelfDocument>`
  - `deleteShelf(id: string, actorId: string): Promise<void>`

- [ ] **Step 1: Tạo warehouse.service.ts**

```typescript
// apps/wms/src/warehouse/warehouse.service.ts
import { Injectable } from '@nestjs/common';
import { AppException } from '@app/common';
import { WarehouseRepository } from './warehouse.repository';
import { WMS_ERRORS } from '../common/error-codes';
import type { WarehouseDocument } from './schemas/warehouse.schema';
import type { ZoneDocument } from './schemas/zone.schema';
import type { RackDocument } from './schemas/rack.schema';
import type { ShelfDocument } from './schemas/shelf.schema';
import type { CreateWarehouseDto, UpdateWarehouseDto } from './dto/warehouse.dto';
import type { CreateZoneDto, UpdateZoneDto } from './dto/zone.dto';
import type { CreateRackDto, UpdateRackDto } from './dto/rack.dto';
import type { CreateShelfDto, UpdateShelfDto } from './dto/shelf.dto';

@Injectable()
export class WarehouseService {
  constructor(private readonly repo: WarehouseRepository) {}

  // ─── Warehouse ────────────────────────────────────────────────────────────

  async createWarehouse(dto: CreateWarehouseDto, actorId: string): Promise<WarehouseDocument> {
    return this.repo.createWarehouse(dto, actorId);
  }

  async listWarehouses(): Promise<WarehouseDocument[]> {
    return this.repo.findAllWarehouses();
  }

  async getWarehouse(id: string): Promise<WarehouseDocument> {
    const doc = await this.repo.findWarehouseById(id);
    if (!doc) throw new AppException('WAREHOUSE_NOT_FOUND');
    return doc;
  }

  async updateWarehouse(
    id: string,
    dto: UpdateWarehouseDto,
    actorId: string,
  ): Promise<WarehouseDocument> {
    const doc = await this.repo.updateWarehouse(id, dto, actorId);
    if (!doc) throw new AppException('WAREHOUSE_NOT_FOUND');
    return doc;
  }

  async deleteWarehouse(id: string, actorId: string): Promise<void> {
    const deleted = await this.repo.softDeleteWarehouse(id, actorId);
    if (!deleted) throw new AppException('WAREHOUSE_NOT_FOUND');
  }

  // ─── Zone ─────────────────────────────────────────────────────────────────

  async createZone(dto: CreateZoneDto, actorId: string): Promise<ZoneDocument> {
    // kiểm tra warehouse tồn tại
    const warehouse = await this.repo.findWarehouseById(dto.warehouseId);
    if (!warehouse) throw new AppException('WAREHOUSE_NOT_FOUND');
    // kiểm tra code unique trong warehouse
    const existing = await this.repo.findZoneByCode(dto.warehouseId, dto.code);
    if (existing) throw new AppException('ZONE_CODE_EXISTS');
    return this.repo.createZone(dto, actorId);
  }

  async listZones(warehouseId: string): Promise<ZoneDocument[]> {
    return this.repo.findZonesByWarehouse(warehouseId);
  }

  async getZone(id: string): Promise<ZoneDocument> {
    const doc = await this.repo.findZoneById(id);
    if (!doc) throw new AppException('ZONE_NOT_FOUND');
    return doc;
  }

  async updateZone(id: string, dto: UpdateZoneDto, actorId: string): Promise<ZoneDocument> {
    // nếu đổi code → kiểm tra unique trong warehouse
    if (dto.code) {
      const zone = await this.repo.findZoneById(id);
      if (!zone) throw new AppException('ZONE_NOT_FOUND');
      const warehouseId = dto.warehouseId ?? zone.warehouseId.toString();
      const existing = await this.repo.findZoneByCode(warehouseId, dto.code);
      if (existing && existing._id.toString() !== id) throw new AppException('ZONE_CODE_EXISTS');
    }
    const doc = await this.repo.updateZone(id, dto, actorId);
    if (!doc) throw new AppException('ZONE_NOT_FOUND');
    return doc;
  }

  async deleteZone(id: string, actorId: string): Promise<void> {
    const deleted = await this.repo.softDeleteZone(id, actorId);
    if (!deleted) throw new AppException('ZONE_NOT_FOUND');
  }

  // ─── Rack ─────────────────────────────────────────────────────────────────

  async createRack(dto: CreateRackDto, actorId: string): Promise<RackDocument> {
    const zone = await this.repo.findZoneById(dto.zoneId);
    if (!zone) throw new AppException('ZONE_NOT_FOUND');
    const existing = await this.repo.findRackByCode(dto.zoneId, dto.code);
    if (existing) throw new AppException('RACK_CODE_EXISTS');
    return this.repo.createRack(dto, actorId);
  }

  async listRacks(zoneId: string): Promise<RackDocument[]> {
    return this.repo.findRacksByZone(zoneId);
  }

  async getRack(id: string): Promise<RackDocument> {
    const doc = await this.repo.findRackById(id);
    if (!doc) throw new AppException('RACK_NOT_FOUND');
    return doc;
  }

  async updateRack(id: string, dto: UpdateRackDto, actorId: string): Promise<RackDocument> {
    if (dto.code) {
      const rack = await this.repo.findRackById(id);
      if (!rack) throw new AppException('RACK_NOT_FOUND');
      const zoneId = dto.zoneId ?? rack.zoneId.toString();
      const existing = await this.repo.findRackByCode(zoneId, dto.code);
      if (existing && existing._id.toString() !== id) throw new AppException('RACK_CODE_EXISTS');
    }
    const doc = await this.repo.updateRack(id, dto, actorId);
    if (!doc) throw new AppException('RACK_NOT_FOUND');
    return doc;
  }

  async deleteRack(id: string, actorId: string): Promise<void> {
    const deleted = await this.repo.softDeleteRack(id, actorId);
    if (!deleted) throw new AppException('RACK_NOT_FOUND');
  }

  // ─── Shelf ────────────────────────────────────────────────────────────────

  async createShelf(dto: CreateShelfDto, actorId: string): Promise<ShelfDocument> {
    const rack = await this.repo.findRackById(dto.rackId);
    if (!rack) throw new AppException('RACK_NOT_FOUND');
    const existing = await this.repo.findShelfByCode(dto.code);
    if (existing) throw new AppException('SHELF_CODE_EXISTS');
    return this.repo.createShelf(dto, actorId);
  }

  async listShelves(rackId: string): Promise<ShelfDocument[]> {
    return this.repo.findShelvesByRack(rackId);
  }

  async getShelf(id: string): Promise<ShelfDocument> {
    const doc = await this.repo.findShelfById(id);
    if (!doc) throw new AppException('SHELF_NOT_FOUND');
    return doc;
  }

  async updateShelf(id: string, dto: UpdateShelfDto, actorId: string): Promise<ShelfDocument> {
    if (dto.code) {
      const existing = await this.repo.findShelfByCode(dto.code);
      if (existing && existing._id.toString() !== id) throw new AppException('SHELF_CODE_EXISTS');
    }
    const doc = await this.repo.updateShelf(id, dto, actorId);
    if (!doc) throw new AppException('SHELF_NOT_FOUND');
    return doc;
  }

  async deleteShelf(id: string, actorId: string): Promise<void> {
    const deleted = await this.repo.softDeleteShelf(id, actorId);
    if (!deleted) throw new AppException('SHELF_NOT_FOUND');
  }
}
```

- [ ] **Step 2: Commit service**

```bash
git add apps/wms/src/warehouse/warehouse.service.ts
git commit -m "feat(wms): add WarehouseService with CRUD + validation (S1-03)"
```

---

## Task 5: Controller + Module + AppModule wiring

**Files:**
- Create: `apps/wms/src/warehouse/warehouse.controller.ts`
- Create: `apps/wms/src/warehouse/warehouse.module.ts`
- Modify: `apps/wms/src/app.module.ts`

**Interfaces:**
- Consumes:
  - `WarehouseService` từ Task 4 (tất cả method)
  - `CurrentUser`, `JwtAuthGuard`, `Roles`, `RolesGuard`, `WmsRole` từ `@app/auth`
  - `plainToInstance` từ `class-transformer`
  - Response DTOs từ Task 2
- Produces: REST endpoints dưới prefix `warehouse`:

| Method | Path | Role | Mô tả |
|---|---|---|---|
| POST | /warehouse | MANAGER | Tạo kho |
| GET | /warehouse | MANAGER | Danh sách kho |
| GET | /warehouse/:id | MANAGER | Chi tiết kho |
| PATCH | /warehouse/:id | MANAGER | Cập nhật kho |
| DELETE | /warehouse/:id | MANAGER | Xoá kho (soft) |
| POST | /warehouse/zones | MANAGER | Tạo zone |
| GET | /warehouse/zones?warehouseId=... | MANAGER | Danh sách zone |
| GET | /warehouse/zones/:id | MANAGER | Chi tiết zone |
| PATCH | /warehouse/zones/:id | MANAGER | Cập nhật zone |
| DELETE | /warehouse/zones/:id | MANAGER | Xoá zone (soft) |
| POST | /warehouse/racks | MANAGER | Tạo rack |
| GET | /warehouse/racks?zoneId=... | MANAGER | Danh sách rack |
| GET | /warehouse/racks/:id | MANAGER | Chi tiết rack |
| PATCH | /warehouse/racks/:id | MANAGER | Cập nhật rack |
| DELETE | /warehouse/racks/:id | MANAGER | Xoá rack (soft) |
| POST | /warehouse/shelves | MANAGER | Tạo shelf |
| GET | /warehouse/shelves?rackId=... | MANAGER | Danh sách shelf |
| GET | /warehouse/shelves/:id | MANAGER | Chi tiết shelf |
| PATCH | /warehouse/shelves/:id | MANAGER | Cập nhật shelf |
| DELETE | /warehouse/shelves/:id | MANAGER | Xoá shelf (soft) |

- [ ] **Step 1: Tạo warehouse.controller.ts**

```typescript
// apps/wms/src/warehouse/warehouse.controller.ts
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
  ApiQuery,
  ApiTags,
} from '@nestjs/swagger';
import { CurrentUser, JwtAuthGuard, Roles, RolesGuard, WmsRole } from '@app/auth';
import { plainToInstance } from 'class-transformer';
import { WarehouseService } from './warehouse.service';
import { CreateWarehouseDto, UpdateWarehouseDto, WarehouseResponseDto } from './dto/warehouse.dto';
import { CreateZoneDto, UpdateZoneDto, ZoneResponseDto } from './dto/zone.dto';
import { CreateRackDto, UpdateRackDto, RackResponseDto } from './dto/rack.dto';
import { CreateShelfDto, UpdateShelfDto, ShelfResponseDto } from './dto/shelf.dto';

const TO_INSTANCE_OPTS = { excludeExtraneousValues: true } as const;

@ApiTags('warehouse')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard, RolesGuard)
@Controller('warehouse')
export class WarehouseController {
  constructor(private readonly svc: WarehouseService) {}

  // ─── Warehouse ────────────────────────────────────────────────────────────

  @Post()
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Tạo kho — [MANAGER]' })
  @ApiCreatedResponse({ type: WarehouseResponseDto })
  async createWarehouse(
    @Body() dto: CreateWarehouseDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<WarehouseResponseDto> {
    const doc = await this.svc.createWarehouse(dto, actorId);
    return plainToInstance(WarehouseResponseDto, doc.toObject(), TO_INSTANCE_OPTS);
  }

  @Get()
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Danh sách kho — [MANAGER]' })
  @ApiOkResponse({ type: [WarehouseResponseDto] })
  async listWarehouses(): Promise<WarehouseResponseDto[]> {
    const docs = await this.svc.listWarehouses();
    return plainToInstance(WarehouseResponseDto, docs.map((d) => d.toObject()), TO_INSTANCE_OPTS);
  }

  @Get(':id')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Chi tiết kho — [MANAGER]' })
  @ApiOkResponse({ type: WarehouseResponseDto })
  async getWarehouse(@Param('id') id: string): Promise<WarehouseResponseDto> {
    const doc = await this.svc.getWarehouse(id);
    return plainToInstance(WarehouseResponseDto, doc.toObject(), TO_INSTANCE_OPTS);
  }

  @Patch(':id')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Cập nhật kho — [MANAGER]' })
  @ApiOkResponse({ type: WarehouseResponseDto })
  async updateWarehouse(
    @Param('id') id: string,
    @Body() dto: UpdateWarehouseDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<WarehouseResponseDto> {
    const doc = await this.svc.updateWarehouse(id, dto, actorId);
    return plainToInstance(WarehouseResponseDto, doc.toObject(), TO_INSTANCE_OPTS);
  }

  @Delete(':id')
  @Roles(WmsRole.MANAGER)
  @HttpCode(HttpStatus.NO_CONTENT)
  @ApiOperation({ summary: 'Xoá kho (soft-delete) — [MANAGER]' })
  @ApiNoContentResponse()
  async deleteWarehouse(
    @Param('id') id: string,
    @CurrentUser('sub') actorId: string,
  ): Promise<void> {
    await this.svc.deleteWarehouse(id, actorId);
  }

  // ─── Zone ─────────────────────────────────────────────────────────────────

  @Post('zones')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Tạo khu vực (zone) — [MANAGER]' })
  @ApiCreatedResponse({ type: ZoneResponseDto })
  async createZone(
    @Body() dto: CreateZoneDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<ZoneResponseDto> {
    const doc = await this.svc.createZone(dto, actorId);
    return plainToInstance(ZoneResponseDto, doc.toObject(), TO_INSTANCE_OPTS);
  }

  @Get('zones')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Danh sách zone theo kho — [MANAGER]' })
  @ApiQuery({ name: 'warehouseId', required: true })
  @ApiOkResponse({ type: [ZoneResponseDto] })
  async listZones(@Query('warehouseId') warehouseId: string): Promise<ZoneResponseDto[]> {
    const docs = await this.svc.listZones(warehouseId);
    return plainToInstance(ZoneResponseDto, docs.map((d) => d.toObject()), TO_INSTANCE_OPTS);
  }

  @Get('zones/:id')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Chi tiết zone — [MANAGER]' })
  @ApiOkResponse({ type: ZoneResponseDto })
  async getZone(@Param('id') id: string): Promise<ZoneResponseDto> {
    const doc = await this.svc.getZone(id);
    return plainToInstance(ZoneResponseDto, doc.toObject(), TO_INSTANCE_OPTS);
  }

  @Patch('zones/:id')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Cập nhật zone — [MANAGER]' })
  @ApiOkResponse({ type: ZoneResponseDto })
  async updateZone(
    @Param('id') id: string,
    @Body() dto: UpdateZoneDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<ZoneResponseDto> {
    const doc = await this.svc.updateZone(id, dto, actorId);
    return plainToInstance(ZoneResponseDto, doc.toObject(), TO_INSTANCE_OPTS);
  }

  @Delete('zones/:id')
  @Roles(WmsRole.MANAGER)
  @HttpCode(HttpStatus.NO_CONTENT)
  @ApiOperation({ summary: 'Xoá zone (soft-delete) — [MANAGER]' })
  @ApiNoContentResponse()
  async deleteZone(
    @Param('id') id: string,
    @CurrentUser('sub') actorId: string,
  ): Promise<void> {
    await this.svc.deleteZone(id, actorId);
  }

  // ─── Rack ─────────────────────────────────────────────────────────────────

  @Post('racks')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Tạo kệ (rack) — [MANAGER]' })
  @ApiCreatedResponse({ type: RackResponseDto })
  async createRack(
    @Body() dto: CreateRackDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<RackResponseDto> {
    const doc = await this.svc.createRack(dto, actorId);
    return plainToInstance(RackResponseDto, doc.toObject(), TO_INSTANCE_OPTS);
  }

  @Get('racks')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Danh sách rack theo zone — [MANAGER]' })
  @ApiQuery({ name: 'zoneId', required: true })
  @ApiOkResponse({ type: [RackResponseDto] })
  async listRacks(@Query('zoneId') zoneId: string): Promise<RackResponseDto[]> {
    const docs = await this.svc.listRacks(zoneId);
    return plainToInstance(RackResponseDto, docs.map((d) => d.toObject()), TO_INSTANCE_OPTS);
  }

  @Get('racks/:id')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Chi tiết rack — [MANAGER]' })
  @ApiOkResponse({ type: RackResponseDto })
  async getRack(@Param('id') id: string): Promise<RackResponseDto> {
    const doc = await this.svc.getRack(id);
    return plainToInstance(RackResponseDto, doc.toObject(), TO_INSTANCE_OPTS);
  }

  @Patch('racks/:id')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Cập nhật rack — [MANAGER]' })
  @ApiOkResponse({ type: RackResponseDto })
  async updateRack(
    @Param('id') id: string,
    @Body() dto: UpdateRackDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<RackResponseDto> {
    const doc = await this.svc.updateRack(id, dto, actorId);
    return plainToInstance(RackResponseDto, doc.toObject(), TO_INSTANCE_OPTS);
  }

  @Delete('racks/:id')
  @Roles(WmsRole.MANAGER)
  @HttpCode(HttpStatus.NO_CONTENT)
  @ApiOperation({ summary: 'Xoá rack (soft-delete) — [MANAGER]' })
  @ApiNoContentResponse()
  async deleteRack(
    @Param('id') id: string,
    @CurrentUser('sub') actorId: string,
  ): Promise<void> {
    await this.svc.deleteRack(id, actorId);
  }

  // ─── Shelf ────────────────────────────────────────────────────────────────

  @Post('shelves')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Tạo tầng kệ (shelf) — [MANAGER]' })
  @ApiCreatedResponse({ type: ShelfResponseDto })
  async createShelf(
    @Body() dto: CreateShelfDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<ShelfResponseDto> {
    const doc = await this.svc.createShelf(dto, actorId);
    return plainToInstance(ShelfResponseDto, doc.toObject(), TO_INSTANCE_OPTS);
  }

  @Get('shelves')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Danh sách shelf theo rack — [MANAGER]' })
  @ApiQuery({ name: 'rackId', required: true })
  @ApiOkResponse({ type: [ShelfResponseDto] })
  async listShelves(@Query('rackId') rackId: string): Promise<ShelfResponseDto[]> {
    const docs = await this.svc.listShelves(rackId);
    return plainToInstance(ShelfResponseDto, docs.map((d) => d.toObject()), TO_INSTANCE_OPTS);
  }

  @Get('shelves/:id')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Chi tiết shelf — [MANAGER]' })
  @ApiOkResponse({ type: ShelfResponseDto })
  async getShelf(@Param('id') id: string): Promise<ShelfResponseDto> {
    const doc = await this.svc.getShelf(id);
    return plainToInstance(ShelfResponseDto, doc.toObject(), TO_INSTANCE_OPTS);
  }

  @Patch('shelves/:id')
  @Roles(WmsRole.MANAGER)
  @ApiOperation({ summary: 'Cập nhật shelf — [MANAGER]' })
  @ApiOkResponse({ type: ShelfResponseDto })
  async updateShelf(
    @Param('id') id: string,
    @Body() dto: UpdateShelfDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<ShelfResponseDto> {
    const doc = await this.svc.updateShelf(id, dto, actorId);
    return plainToInstance(ShelfResponseDto, doc.toObject(), TO_INSTANCE_OPTS);
  }

  @Delete('shelves/:id')
  @Roles(WmsRole.MANAGER)
  @HttpCode(HttpStatus.NO_CONTENT)
  @ApiOperation({ summary: 'Xoá shelf (soft-delete) — [MANAGER]' })
  @ApiNoContentResponse()
  async deleteShelf(
    @Param('id') id: string,
    @CurrentUser('sub') actorId: string,
  ): Promise<void> {
    await this.svc.deleteShelf(id, actorId);
  }
}
```

- [ ] **Step 2: Tạo warehouse.module.ts**

```typescript
// apps/wms/src/warehouse/warehouse.module.ts
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { Warehouse, WarehouseSchema } from './schemas/warehouse.schema';
import { Zone, ZoneSchema } from './schemas/zone.schema';
import { Rack, RackSchema } from './schemas/rack.schema';
import { Shelf, ShelfSchema } from './schemas/shelf.schema';
import { WarehouseRepository } from './warehouse.repository';
import { WarehouseService } from './warehouse.service';
import { WarehouseController } from './warehouse.controller';

@Module({
  imports: [
    MongooseModule.forFeature([
      { name: Warehouse.name, schema: WarehouseSchema },
      { name: Zone.name, schema: ZoneSchema },
      { name: Rack.name, schema: RackSchema },
      { name: Shelf.name, schema: ShelfSchema },
    ]),
  ],
  providers: [WarehouseRepository, WarehouseService],
  controllers: [WarehouseController],
  exports: [WarehouseService],
})
export class WarehouseModule {}
```

- [ ] **Step 3: Thêm WarehouseModule vào app.module.ts**

Thêm import vào `apps/wms/src/app.module.ts`:

```typescript
// Thêm vào imports array (sau StockModule):
import { WarehouseModule } from './warehouse/warehouse.module';

// Trong @Module({ imports: [...] }):
WarehouseModule, // CRUD cấu trúc kho: Warehouse/Zone/Rack/Shelf
```

- [ ] **Step 4: Build kiểm tra type error**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm build wms 2>&1 | tail -30
```

Expected: build thành công, không có lỗi TypeScript.

- [ ] **Step 5: Commit controller + module + wiring**

```bash
git add apps/wms/src/warehouse/warehouse.controller.ts \
        apps/wms/src/warehouse/warehouse.module.ts \
        apps/wms/src/app.module.ts
git commit -m "feat(wms): add WarehouseController, WarehouseModule, wire into AppModule (S1-03)"
```

---

## Task 6: Smoke Test qua Swagger

> Không có unit test tự động cho task này — dự án chưa có test runner setup. Smoke test thủ công qua Swagger UI để xác nhận endpoints hoạt động end-to-end.

- [ ] **Step 1: Chạy WMS**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm start:wms
```

Expected: server start không crash, log thấy `Mapped {/api/wms/warehouse, POST}`.

- [ ] **Step 2: Đăng nhập lấy token**

Gọi `POST /api/wms/auth/login` với ADMIN credentials → lấy `accessToken`.

- [ ] **Step 3: Smoke test CRUD Warehouse**

Dùng Swagger UI tại `http://localhost:3001/api/wms/docs` (hoặc port tương ứng):

1. `POST /api/wms/warehouse` body `{ "name": "Kho trung tâm", "address": "123 Test" }` → expect 201, có `id`.
2. `GET /api/wms/warehouse` → expect 200, array có 1 item.
3. `GET /api/wms/warehouse/:id` → expect 200.
4. `PATCH /api/wms/warehouse/:id` body `{ "address": "456 Updated" }` → expect 200, `address` đổi.
5. `DELETE /api/wms/warehouse/:id` → expect 204.
6. `GET /api/wms/warehouse/:id` sau delete → expect 404 `WAREHOUSE_NOT_FOUND`.

- [ ] **Step 4: Smoke test Zone → Rack → Shelf (happy path)**

1. Tạo lại 1 Warehouse → lấy `warehouseId`.
2. `POST /api/wms/warehouse/zones` body `{ "warehouseId": "...", "name": "Khu A", "code": "A" }` → 201.
3. `POST /api/wms/warehouse/zones` body cùng `warehouseId` + `code: "A"` → expect 409 `ZONE_CODE_EXISTS`.
4. `GET /api/wms/warehouse/zones?warehouseId=...` → 200, 1 item.
5. Tạo Rack với `zoneId` vừa tạo → 201.
6. Tạo Shelf với `rackId` vừa tạo, `code: "A1-T1"` → 201.
7. Tạo Shelf thứ 2 với cùng `code: "A1-T1"` → expect 409 `SHELF_CODE_EXISTS`.

- [ ] **Step 5: Final commit nếu cần fix**

Nếu có fix nhỏ từ smoke test:

```bash
git add -p
git commit -m "fix(wms): smoke test fixes for warehouse CRUD (S1-03)"
```

---

## Self-Review

**Spec coverage:**
- ✅ Warehouse schema (name, address, isActive, audit)
- ✅ Zone schema (warehouseId, name, code, unique code per warehouse)
- ✅ Rack schema (zoneId, name, code, unique code per zone)
- ✅ Shelf schema (rackId, level, code barcode unique, kích thước, fillFactor, isStaging)
- ✅ Soft-delete + `deletedAt` filter cho cả 4
- ✅ CRUD đầy đủ 20 endpoints cho MANAGER
- ✅ Validation parent tồn tại khi tạo con (Zone → Warehouse, Rack → Zone, Shelf → Rack)
- ✅ Unique check code (Zone trong Warehouse, Rack trong Zone, Shelf code toàn hệ thống)
- ✅ AppException thay vì throw NestJS thô
- ✅ `@ApiOperation` ghi role, `@Expose()` + `plainToInstance`
- ✅ `createdBy`/`updatedBy` từ JWT `actorId`
- ✅ `WarehouseModule` export `WarehouseService` cho Sprint 2 dùng

**Placeholder scan:** Không có TBD/TODO/placeholder.

**Type consistency:** Tất cả method trong service/repository dùng đúng kiểu DTO và Document từ Task 1-2. `actorId` là `string` xuyên suốt.
