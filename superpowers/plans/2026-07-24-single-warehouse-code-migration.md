# Single-Warehouse Code Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the `Warehouse` entity and every `warehouseId` field from the WMS codebase, since the app now represents exactly one warehouse; simplify `ReservationService` to reserve directly against the single stock pool; and drop `fulfillWarehouseId`/`preferWarehouse` from the cross-app event contract and Ecommerce `Order`.

**Architecture:** Work bottom-up through the dependency graph: shared event contract first, then the location module (Zone/Rack/Shelf, renamed from `warehouse/`), then `stock` (Balance/Inventory/Movement + repository/service signatures), then `reservation`, then every document module that carries a `warehouseId` field (PO → GRN → PutAwayTask chain, GoodsIssue, GoodsReturn, ScrapNote, StockCount, PrintJob, User), then Ecommerce, then seed, then a full-repo grep sweep to catch anything missed.

**Tech Stack:** NestJS (monorepo mode), Mongoose (`@nestjs/mongoose`), BullMQ + Redis (`@app/events`), class-validator/class-transformer DTOs, Jest.

> **Addendum (discovered during execution, after Task 8):** `apps/wms/src/shipping/` has its own `Shipment.fulfillWarehouseId` field, independently sourced from `GoodsIssue.warehouseId` — this module was never surveyed and is not covered by Tasks 1-13 above. It broke (failed to compile) once Task 1 removed `OrderReadyToFulfillPayload.fulfillWarehouseId` and Task 8 removed `GoodsIssue.warehouseId`. Fixed as **Task 8b**, executed between Task 8 and Task 9 — same pattern as the other document-module tasks (drop the field from schema/DTO/service/repository/consumer, update tests). See `.superpowers/sdd/task-8b-brief.md` in the executing worktree for the exact brief.
>
> **Addendum 2 (discovered during execution, during Task 13's final sweep):** `apps/wms/src/report/` (stock/lot/performance reports) was also never surveyed and is not covered by Tasks 1-13. Worse than a compile break: `report.repository.ts`'s aggregation pipelines `$lookup` against the `warehouses` collection, which Task 2 deleted entirely — `$unwind` on a `$lookup` that never matches silently drops every row, meaning report endpoints would return empty results in production with no error. Fixed as **Task 13b**, executed after Task 13, before the final whole-branch review. See `.superpowers/sdd/task-13b-brief.md` in the executing worktree for the exact brief.

## Global Constraints

- Every service **must** throw `AppException('CODE')` from `@app/common` — never raw NestJS exceptions (see `.claude/rules/error-handling.md`).
- Response DTOs use `@Expose()` + `plainToInstance(..., { excludeExtraneousValues: true })`; `_id` always maps to `id` via `@Transform`.
- No `any` — every `@Transform` callback types `obj` explicitly (see `.claude/rules/dto-conventions.md`).
- Collection names stay snake_case via `@Schema({ collection: '...' })`; do not let Mongoose pluralize class names.
- Comments in Vietnamese, explaining *why* not *what*, matching existing style.
- Do **not** add a `DEFAULT_WAREHOUSE_ID` constant, singleton document, or any warehouse-shaped placeholder — the spec explicitly rules this out.
- This is a **dev-only** migration: no data-migration script. The final task wipes and reseeds the local dev DB.
- After every task: run `pnpm lint` and the affected `pnpm test` suite before moving on. Fix failures before continuing — do not accumulate broken tests across tasks.

---

### Task 1: Event contract — drop warehouse fields from `libs/events`

**Files:**
- Modify: `libs/events/src/events.ts`

**Interfaces:**
- Produces: `StockReserveRequestedPayload` (no `preferWarehouse`), `StockReservedPayload` (no `fulfillWarehouseId`), `OrderReadyToFulfillPayload` (no `fulfillWarehouseId`), `PrintRequestedPayload` (no `warehouseId`), `StockLowPayload` (no `warehouseId`) — every later task that imports these types relies on the trimmed shape.

- [ ] **Step 1: Edit `StockReserveRequestedPayload`**

In `libs/events/src/events.ts`, change:
```typescript
export interface StockReserveRequestedPayload {
  orderId: string;
  items: { sku: string; quantity: number }[];
  /** ưu tiên kho khi giữ tồn (vd 'CENTRAL'); WMS tự chọn kho có đủ available. */
  preferWarehouse?: string;
}
```
to:
```typescript
export interface StockReserveRequestedPayload {
  orderId: string;
  items: { sku: string; quantity: number }[];
}
```

- [ ] **Step 2: Edit `StockReservedPayload`**

Change:
```typescript
export interface StockReservedPayload {
  orderId: string;
  /** kho đã giữ tồn — Ecom lưu vào order.fulfillWarehouseId. */
  fulfillWarehouseId: string;
}
```
to:
```typescript
export interface StockReservedPayload {
  orderId: string;
}
```

- [ ] **Step 3: Edit `OrderReadyToFulfillPayload`**

Change:
```typescript
export interface OrderReadyToFulfillPayload {
  orderId: string;
  fulfillWarehouseId: string;
  items: { sku: string; quantity: number }[];
  shippingAddress: Record<string, unknown>;
  recipient: { name: string; phone: string };
  paymentMethod: 'COD' | 'ONLINE';
  codAmount?: number;
}
```
to:
```typescript
export interface OrderReadyToFulfillPayload {
  orderId: string;
  items: { sku: string; quantity: number }[];
  shippingAddress: Record<string, unknown>;
  recipient: { name: string; phone: string };
  paymentMethod: 'COD' | 'ONLINE';
  codAmount?: number;
}
```

- [ ] **Step 4: Edit `PrintRequestedPayload`**

Change:
```typescript
export interface PrintRequestedPayload {
  orderId: string;
  warehouseId: string;
  items: {
    sku: string;
    quantity: number;
    designFile?: string;
    blankSku?: string;
  }[];
}
```
to:
```typescript
export interface PrintRequestedPayload {
  orderId: string;
  items: {
    sku: string;
    quantity: number;
    designFile?: string;
    blankSku?: string;
  }[];
}
```

- [ ] **Step 5: Edit `StockLowPayload`**

Change:
```typescript
export interface StockLowPayload {
  sku: string;
  warehouseId: string;
  available: number;
  minQuantity: number;
}
```
to:
```typescript
export interface StockLowPayload {
  sku: string;
  available: number;
  minQuantity: number;
}
```

- [ ] **Step 6: Typecheck the lib in isolation**

Run: `pnpm exec tsc --noEmit -p libs/events/tsconfig.lib.json` (or `pnpm build` if there's no standalone lib tsconfig — check `libs/events/` for a `tsconfig.lib.json` first with `ls libs/events`)
Expected: fails, listing every call site across `apps/wms` and `apps/ecommerce` that still references the removed fields — this is expected; those are the call sites fixed in later tasks. Confirm the errors are ONLY about `preferWarehouse`/`fulfillWarehouseId`/`warehouseId` on these 5 payload types, nothing else.

- [ ] **Step 7: Commit**

```bash
git add libs/events/src/events.ts
git commit -m "feat(events): bỏ warehouseId/fulfillWarehouseId/preferWarehouse khỏi event contract (single-warehouse)"
```

---

### Task 2: Rename `warehouse/` module to `location/`, drop `Warehouse` entity

**Files:**
- Create: `apps/wms/src/location/schemas/zone.schema.ts` (moved from `warehouse/schemas/zone.schema.ts`, `warehouseId` field removed)
- Create: `apps/wms/src/location/schemas/rack.schema.ts` (moved verbatim, no `warehouseId`)
- Create: `apps/wms/src/location/schemas/shelf.schema.ts` (moved, `warehouseId` field removed, new unique staging index added)
- Create: `apps/wms/src/location/dto/zone.dto.ts` (moved, `warehouseId` removed from Create/Update/Response)
- Create: `apps/wms/src/location/dto/rack.dto.ts` (moved verbatim)
- Create: `apps/wms/src/location/dto/shelf.dto.ts` (moved, `warehouseId` removed from Response)
- Create: `apps/wms/src/location/location.repository.ts` (renamed from `WarehouseRepository`, Warehouse CRUD methods removed, remaining methods de-scoped)
- Create: `apps/wms/src/location/location.service.ts` (renamed from `WarehouseService`, Warehouse CRUD methods removed)
- Create: `apps/wms/src/location/location.controller.ts` (renamed from `WarehouseController`, Warehouse routes removed, Zone routes drop `warehouseId` query param)
- Create: `apps/wms/src/location/location.module.ts` (renamed from `WarehouseModule`)
- Delete: `apps/wms/src/warehouse/schemas/warehouse.schema.ts`
- Delete: `apps/wms/src/warehouse/dto/warehouse.dto.ts`
- Delete: `apps/wms/src/warehouse/warehouse.repository.ts`
- Delete: `apps/wms/src/warehouse/warehouse.service.ts`
- Delete: `apps/wms/src/warehouse/warehouse.controller.ts`
- Delete: `apps/wms/src/warehouse/warehouse.module.ts`
- Delete: entire `apps/wms/src/warehouse/` directory (old schemas/dto too, once copied)
- Modify: `libs/common/src/errors/error-codes.ts` (drop `WAREHOUSE_NOT_FOUND`, `WAREHOUSE_CODE_EXISTS`; fix `ZONE_CODE_EXISTS` message which currently says "trong kho này")
- Test: `apps/wms/src/location/location.service.spec.ts` (rewritten from `warehouse.service.spec.ts`, Warehouse tests removed)
- Test: `apps/wms/src/location/location.repository.spec.ts` (rewritten from `warehouse.repository.spec.ts`)

**Interfaces:**
- Consumes: nothing new from other tasks.
- Produces: `LocationRepository` with methods `findZonesByWarehouse` → **`findAllZones()`**, `findZoneById(id)`, `findZoneByCode(code)` (warehouseId param dropped), `createZone`, `updateZone`, `softDeleteZone`, `createRack`, `findRacksByZone`, `findRackById`, `findRackByCode`, `updateRack`, `softDeleteRack`, `createShelf(dto, actorId)` (drops the 3rd `warehouseId` param), `findShelvesByRack`, **`findShelves()`** (renamed from `findShelvesByWarehouse`, no param), `findShelfById`, `findShelfByCode`, `findShelfIdsByZone`, **`findStagingShelf()`** (renamed from `findStagingShelfByWarehouse`, no param), `updateShelf`, `softDeleteShelf`. `LocationService` exposes the same surface (`findStagingShelf()` no-arg, throws `GRN_STAGING_SHELF_NOT_FOUND`). Every later task importing `WarehouseModule`/`WarehouseService`/`WarehouseRepository` must switch to `LocationModule`/`LocationService`/`LocationRepository`.

- [ ] **Step 1: Create the new schemas directory with Zone (no warehouseId)**

Create `apps/wms/src/location/schemas/zone.schema.ts`:
```typescript
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

@Schema({ collection: 'zones', timestamps: true })
export class Zone {
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
ZoneSchema.index({ deletedAt: 1 });
ZoneSchema.index(
  { code: 1 },
  { unique: true, partialFilterExpression: { deletedAt: null } },
);
```

- [ ] **Step 2: Create Rack schema (unchanged, just moved)**

Create `apps/wms/src/location/schemas/rack.schema.ts` — identical content to `apps/wms/src/warehouse/schemas/rack.schema.ts`:
```typescript
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
RackSchema.index(
  { zoneId: 1, code: 1 },
  { unique: true, partialFilterExpression: { deletedAt: null } },
);
```

- [ ] **Step 3: Create Shelf schema (drop warehouseId, add staging uniqueness)**

Create `apps/wms/src/location/schemas/shelf.schema.ts`:
```typescript
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, SchemaTypes, Types } from 'mongoose';

@Schema({ collection: 'shelves', timestamps: true })
export class Shelf {
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  rackId!: Types.ObjectId;

  @Prop({ required: true })
  level!: number;

  /** Giá trị barcode vị trí — dán tem ở mỗi shelf, quét khi put-away/pick */
  @Prop({ required: true })
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
ShelfSchema.index(
  { code: 1 },
  { unique: true, partialFilterExpression: { deletedAt: null } },
);
// App = 1 kho duy nhất → tối đa 1 staging shelf toàn hệ thống (trước đây chỉ
// là quy ước ngầm scoped theo warehouseId, giờ siết thành ràng buộc DB thật).
ShelfSchema.index(
  { isStaging: 1 },
  { unique: true, partialFilterExpression: { isStaging: true, deletedAt: null } },
);
```

- [ ] **Step 4: Create Zone/Rack/Shelf DTOs**

Create `apps/wms/src/location/dto/zone.dto.ts`:
```typescript
import { ApiProperty, PartialType } from '@nestjs/swagger';
import { Expose, Transform } from 'class-transformer';
import { IsString, MinLength } from 'class-validator';
import { Types } from 'mongoose';

export class CreateZoneDto {
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
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) =>
    obj._id?.toString(),
  )
  @ApiProperty()
  id!: string;

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

Create `apps/wms/src/location/dto/rack.dto.ts` — identical to `apps/wms/src/warehouse/dto/rack.dto.ts` (no `warehouseId` in it already):
```typescript
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
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) =>
    obj._id?.toString(),
  )
  @ApiProperty()
  id!: string;

  @Expose()
  @Transform(({ obj }: { obj: { zoneId?: Types.ObjectId } }) =>
    obj.zoneId?.toString(),
  )
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

Create `apps/wms/src/location/dto/shelf.dto.ts` — same as `apps/wms/src/warehouse/dto/shelf.dto.ts` but drop the `warehouseId` field from `ShelfResponseDto`:
```typescript
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

  @ApiProperty({
    example: 'A1-T1',
    description: 'Mã barcode vị trí — dán tem tại shelf',
  })
  @IsString()
  @MinLength(1)
  code!: string;

  @ApiPropertyOptional({
    example: 120,
    description: 'Chiều sâu lòng tầng (cm)',
  })
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

  @ApiPropertyOptional({
    example: 0.8,
    description:
      'Override fill factor (0–1). Bỏ trống = dùng mặc định hệ thống',
  })
  @IsOptional()
  @IsNumber()
  @Min(0)
  @Max(1)
  fillFactor?: number;

  @ApiPropertyOptional({
    default: false,
    description: 'true = shelf staging (khu nhận hàng tạm)',
  })
  @IsOptional()
  @IsBoolean()
  isStaging?: boolean;
}

export class UpdateShelfDto extends PartialType(CreateShelfDto) {}

export class ShelfResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) =>
    obj._id?.toString(),
  )
  @ApiProperty()
  id!: string;

  @Expose()
  @Transform(({ obj }: { obj: { rackId?: Types.ObjectId } }) =>
    obj.rackId?.toString(),
  )
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

- [ ] **Step 5: Create `LocationRepository`**

Create `apps/wms/src/location/location.repository.ts`:
```typescript
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import { Zone, ZoneDocument } from './schemas/zone.schema';
import { Rack, RackDocument } from './schemas/rack.schema';
import { Shelf, ShelfDocument } from './schemas/shelf.schema';
import { CreateZoneDto, UpdateZoneDto } from './dto/zone.dto';
import { CreateRackDto, UpdateRackDto } from './dto/rack.dto';
import { CreateShelfDto, UpdateShelfDto } from './dto/shelf.dto';

const SOFT_DELETE_FILTER = { deletedAt: null } as const;

@Injectable()
export class LocationRepository {
  constructor(
    @InjectModel(Zone.name) private readonly zoneModel: Model<ZoneDocument>,
    @InjectModel(Rack.name) private readonly rackModel: Model<RackDocument>,
    @InjectModel(Shelf.name) private readonly shelfModel: Model<ShelfDocument>,
  ) {}

  // ─── Zone ─────────────────────────────────────────────────────────────────

  async createZone(dto: CreateZoneDto, actorId: string): Promise<ZoneDocument> {
    return this.zoneModel.create({
      ...dto,
      createdBy: new Types.ObjectId(actorId),
      updatedBy: new Types.ObjectId(actorId),
    });
  }

  async findAllZones(): Promise<ZoneDocument[]> {
    return this.zoneModel.find(SOFT_DELETE_FILTER).sort({ code: 1 }).exec();
  }

  async findZoneById(id: string): Promise<ZoneDocument | null> {
    return this.zoneModel.findOne({ _id: id, ...SOFT_DELETE_FILTER }).exec();
  }

  async findZoneByCode(code: string): Promise<ZoneDocument | null> {
    return this.zoneModel
      .findOne({ code, ...SOFT_DELETE_FILTER })
      .exec();
  }

  async updateZone(
    id: string,
    dto: UpdateZoneDto,
    actorId: string,
  ): Promise<ZoneDocument | null> {
    return this.zoneModel
      .findOneAndUpdate(
        { _id: id, ...SOFT_DELETE_FILTER },
        { ...dto, updatedBy: new Types.ObjectId(actorId) },
        { new: true },
      )
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

  async findRackByCode(
    zoneId: string,
    code: string,
  ): Promise<RackDocument | null> {
    return this.rackModel
      .findOne({
        zoneId: new Types.ObjectId(zoneId),
        code,
        ...SOFT_DELETE_FILTER,
      })
      .exec();
  }

  async updateRack(
    id: string,
    dto: UpdateRackDto,
    actorId: string,
  ): Promise<RackDocument | null> {
    const update: Record<string, unknown> = {
      ...dto,
      updatedBy: new Types.ObjectId(actorId),
    };
    if (dto.zoneId) update['zoneId'] = new Types.ObjectId(dto.zoneId);
    return this.rackModel
      .findOneAndUpdate({ _id: id, ...SOFT_DELETE_FILTER }, update, {
        new: true,
      })
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

  async createShelf(
    dto: CreateShelfDto,
    actorId: string,
  ): Promise<ShelfDocument> {
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

  /** Liệt kê shelf ứng viên cho gợi ý put-away: non-staging, chưa xoá, đã khai đủ 3 chiều. */
  async findShelves(): Promise<ShelfDocument[]> {
    return this.shelfModel
      .find({
        isStaging: false,
        deletedAt: null,
        innerDepth: { $exists: true, $ne: null },
        innerWidth: { $exists: true, $ne: null },
        innerHeight: { $exists: true, $ne: null },
      })
      .sort({ code: 1 })
      .exec();
  }

  async findShelfById(id: string): Promise<ShelfDocument | null> {
    return this.shelfModel.findOne({ _id: id, ...SOFT_DELETE_FILTER }).exec();
  }

  async findShelfByCode(code: string): Promise<ShelfDocument | null> {
    return this.shelfModel.findOne({ code, ...SOFT_DELETE_FILTER }).exec();
  }

  /**
   * Danh sách shelfId thuộc 1 zone — join 2 tầng Shelf.rackId → Rack.zoneId
   * (Shelf không denormalize zoneId trực tiếp). Dùng khi StockCountService
   * tạo phiếu giới hạn theo zone (UC-06).
   */
  async findShelfIdsByZone(zoneId: string): Promise<Types.ObjectId[]> {
    const racks = await this.findRacksByZone(zoneId);
    const rackIds = racks.map((r) => r._id.toString());
    const shelvesByRack = await Promise.all(
      rackIds.map((rackId) => this.findShelvesByRack(rackId)),
    );
    return shelvesByRack.flat().map((s) => s._id);
  }

  /** Tìm shelf staging (khu nhận hàng tạm) duy nhất toàn hệ thống — dùng khi GRN CONFIRMED cộng tồn. */
  async findStagingShelf(): Promise<ShelfDocument | null> {
    return this.shelfModel
      .findOne({ isStaging: true, deletedAt: null })
      .exec();
  }

  async updateShelf(
    id: string,
    dto: UpdateShelfDto,
    actorId: string,
  ): Promise<ShelfDocument | null> {
    const update: Record<string, unknown> = {
      ...dto,
      updatedBy: new Types.ObjectId(actorId),
    };
    if (dto.rackId) update['rackId'] = new Types.ObjectId(dto.rackId);
    return this.shelfModel
      .findOneAndUpdate({ _id: id, ...SOFT_DELETE_FILTER }, update, {
        new: true,
      })
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

- [ ] **Step 6: Create `LocationService`**

Create `apps/wms/src/location/location.service.ts`:
```typescript
import { Injectable } from '@nestjs/common';
import { AppException } from '@app/common';
import { LocationRepository } from './location.repository';
import type { ZoneDocument } from './schemas/zone.schema';
import type { RackDocument } from './schemas/rack.schema';
import type { ShelfDocument } from './schemas/shelf.schema';
import type { CreateZoneDto, UpdateZoneDto } from './dto/zone.dto';
import type { CreateRackDto, UpdateRackDto } from './dto/rack.dto';
import type { CreateShelfDto, UpdateShelfDto } from './dto/shelf.dto';

@Injectable()
export class LocationService {
  constructor(private readonly repo: LocationRepository) {}

  // ─── Zone ─────────────────────────────────────────────────────────────────

  async createZone(dto: CreateZoneDto, actorId: string): Promise<ZoneDocument> {
    const existing = await this.repo.findZoneByCode(dto.code);
    if (existing) throw new AppException('ZONE_CODE_EXISTS');
    return this.repo.createZone(dto, actorId);
  }

  async listZones(): Promise<ZoneDocument[]> {
    return this.repo.findAllZones();
  }

  async getZone(id: string): Promise<ZoneDocument> {
    const doc = await this.repo.findZoneById(id);
    if (!doc) throw new AppException('ZONE_NOT_FOUND');
    return doc;
  }

  async updateZone(
    id: string,
    dto: UpdateZoneDto,
    actorId: string,
  ): Promise<ZoneDocument> {
    if (dto.code) {
      const existing = await this.repo.findZoneByCode(dto.code);
      if (existing && existing._id.toString() !== id)
        throw new AppException('ZONE_CODE_EXISTS');
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

  async updateRack(
    id: string,
    dto: UpdateRackDto,
    actorId: string,
  ): Promise<RackDocument> {
    if (dto.code) {
      const rack = await this.repo.findRackById(id);
      if (!rack) throw new AppException('RACK_NOT_FOUND');
      const zoneId = dto.zoneId ?? rack.zoneId.toString();
      const existing = await this.repo.findRackByCode(zoneId, dto.code);
      if (existing && existing._id.toString() !== id)
        throw new AppException('RACK_CODE_EXISTS');
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

  async createShelf(
    dto: CreateShelfDto,
    actorId: string,
  ): Promise<ShelfDocument> {
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

  async updateShelf(
    id: string,
    dto: UpdateShelfDto,
    actorId: string,
  ): Promise<ShelfDocument> {
    if (dto.code) {
      const existing = await this.repo.findShelfByCode(dto.code);
      if (existing && existing._id.toString() !== id)
        throw new AppException('SHELF_CODE_EXISTS');
    }
    const doc = await this.repo.updateShelf(id, dto, actorId);
    if (!doc) throw new AppException('SHELF_NOT_FOUND');
    return doc;
  }

  async deleteShelf(id: string, actorId: string): Promise<void> {
    const deleted = await this.repo.softDeleteShelf(id, actorId);
    if (!deleted) throw new AppException('SHELF_NOT_FOUND');
  }

  /** GRN CONFIRMED cần shelf staging duy nhất — không có thì chặn confirm. */
  async findStagingShelf(): Promise<ShelfDocument> {
    const shelf = await this.repo.findStagingShelf();
    if (!shelf) throw new AppException('GRN_STAGING_SHELF_NOT_FOUND');
    return shelf;
  }
}
```

- [ ] **Step 7: Create `LocationController`**

Create `apps/wms/src/location/location.controller.ts` — same structure as `WarehouseController` minus every Warehouse route, and `listZones` drops the `warehouseId` query param:
```typescript
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
import {
  CurrentUser,
  JwtAuthGuard,
  Roles,
  RolesGuard,
  WmsRole,
} from '@app/auth';
import { plainToInstance } from 'class-transformer';
import { LocationService } from './location.service';
import { CreateZoneDto, UpdateZoneDto, ZoneResponseDto } from './dto/zone.dto';
import { CreateRackDto, UpdateRackDto, RackResponseDto } from './dto/rack.dto';
import {
  CreateShelfDto,
  UpdateShelfDto,
  ShelfResponseDto,
} from './dto/shelf.dto';

const TO_INSTANCE_OPTS = { excludeExtraneousValues: true } as const;

@ApiTags('location')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard, RolesGuard)
@Controller('location')
export class LocationController {
  constructor(private readonly svc: LocationService) {}

  // ─── Zone (static sub-routes phải đặt TRƯỚC `:id` để tránh NestJS shadow) ──

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
  @ApiOperation({ summary: 'Danh sách zone — [MANAGER]' })
  @ApiOkResponse({ type: [ZoneResponseDto] })
  async listZones(): Promise<ZoneResponseDto[]> {
    const docs = await this.svc.listZones();
    return plainToInstance(
      ZoneResponseDto,
      docs.map((d) => d.toObject()),
      TO_INSTANCE_OPTS,
    );
  }

  // ─── Rack (static sub-routes phải đặt TRƯỚC `:id`) ───────────────────────

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
    return plainToInstance(
      RackResponseDto,
      docs.map((d) => d.toObject()),
      TO_INSTANCE_OPTS,
    );
  }

  // ─── Shelf (static sub-routes phải đặt TRƯỚC `:id`) ──────────────────────

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
  async listShelves(
    @Query('rackId') rackId: string,
  ): Promise<ShelfResponseDto[]> {
    const docs = await this.svc.listShelves(rackId);
    return plainToInstance(
      ShelfResponseDto,
      docs.map((d) => d.toObject()),
      TO_INSTANCE_OPTS,
    );
  }

  // ─── Zone param routes ────────────────────────────────────────────────────

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

  // ─── Rack param routes ────────────────────────────────────────────────────

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

  // ─── Shelf param routes ───────────────────────────────────────────────────

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

- [ ] **Step 8: Create `LocationModule`**

Create `apps/wms/src/location/location.module.ts`:
```typescript
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { Zone, ZoneSchema } from './schemas/zone.schema';
import { Rack, RackSchema } from './schemas/rack.schema';
import { Shelf, ShelfSchema } from './schemas/shelf.schema';
import { LocationRepository } from './location.repository';
import { LocationService } from './location.service';
import { LocationController } from './location.controller';

@Module({
  imports: [
    MongooseModule.forFeature([
      { name: Zone.name, schema: ZoneSchema },
      { name: Rack.name, schema: RackSchema },
      { name: Shelf.name, schema: ShelfSchema },
    ]),
  ],
  providers: [LocationRepository, LocationService],
  controllers: [LocationController],
  // LocationRepository export riêng để PutAwayService gọi thẳng findShelfByCode
  // (trả về null khi không thấy) và tự throw PUTAWAY_SHELF_NOT_FOUND — tránh
  // code lỗi generic SHELF_NOT_FOUND của LocationService rò vào domain put-away.
  exports: [LocationService, LocationRepository],
})
export class LocationModule {}
```

- [ ] **Step 9: Delete the old `warehouse/` directory**

```bash
rm -rf apps/wms/src/warehouse
```

- [ ] **Step 10: Update `error-codes.ts`**

In `libs/common/src/errors/error-codes.ts`, remove `WAREHOUSE_NOT_FOUND` and `WAREHOUSE_CODE_EXISTS` entries and rename the section header. Change:
```typescript
  // ── WMS — Warehouse Structure ──────────────────────────────────────────────
  WAREHOUSE_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy kho',
  },
  WAREHOUSE_CODE_EXISTS: {
    status: HttpStatus.CONFLICT,
    message: 'Mã khu vực đã tồn tại trong kho này',
  },
  ZONE_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy khu vực',
  },
  ZONE_CODE_EXISTS: {
    status: HttpStatus.CONFLICT,
    message: 'Mã khu vực đã tồn tại trong kho này',
  },
```
to:
```typescript
  // ── WMS — Location Structure (Zone/Rack/Shelf) ──────────────────────────────
  ZONE_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy khu vực',
  },
  ZONE_CODE_EXISTS: {
    status: HttpStatus.CONFLICT,
    message: 'Mã khu vực đã tồn tại',
  },
```
(Leave `RACK_NOT_FOUND`, `RACK_CODE_EXISTS`, `SHELF_NOT_FOUND`, `SHELF_CODE_EXISTS` untouched — they're below this block.)

- [ ] **Step 11: Write `location.repository.spec.ts`**

Create `apps/wms/src/location/location.repository.spec.ts` — port every Zone/Rack/Shelf test case from the old `warehouse.repository.spec.ts` (read it first with the Read tool to get exact `Test.createTestingModule` mongoose-memory-server setup used elsewhere in this repo's repository specs — follow the same pattern as `apps/wms/src/stock/stock.repository.spec.ts` for boilerplate). Remove every `Warehouse`-specific test block. Add one new test:
```typescript
  describe('staging shelf uniqueness', () => {
    it('chặn tạo shelf staging thứ 2 khi đã có 1 shelf staging active', async () => {
      const rack = await repo.createRack(
        { zoneId: zoneId.toString(), name: 'R1', code: 'R1' },
        actorId,
      );
      await repo.createShelf(
        { rackId: rack._id.toString(), level: 1, code: 'S1', isStaging: true },
        actorId,
      );
      await expect(
        repo.createShelf(
          { rackId: rack._id.toString(), level: 2, code: 'S2', isStaging: true },
          actorId,
        ),
      ).rejects.toThrow(); // trùng partial unique index { isStaging: true, deletedAt: null }
    });
  });
```

- [ ] **Step 12: Write `location.service.spec.ts`**

Create `apps/wms/src/location/location.service.spec.ts` — port Zone/Rack/Shelf test cases from `warehouse.service.spec.ts`, drop Warehouse test blocks, update `findStagingShelf()` tests to call with no arguments.

- [ ] **Step 13: Run the location module's tests**

Run: `pnpm test -- apps/wms/src/location`
Expected: PASS, no reference to `Warehouse`/`warehouseId` remains in this directory.

- [ ] **Step 14: Commit**

```bash
git add apps/wms/src/location libs/common/src/errors/error-codes.ts
git rm -r apps/wms/src/warehouse
git commit -m "refactor(wms): đổi warehouse/ thành location/, xóa entity Warehouse, Zone là gốc cây vị trí"
```

---

### Task 3: Stock module — drop `warehouseId` from schemas/repository/service signatures

**Files:**
- Modify: `apps/wms/src/stock/schemas/stock-balance.schema.ts`
- Modify: `apps/wms/src/stock/schemas/inventory-stock.schema.ts`
- Modify: `apps/wms/src/stock/schemas/stock-movement.schema.ts`
- Modify: `apps/wms/src/stock/stock.repository.ts`
- Modify: `apps/wms/src/stock/stock.service.ts`
- Test: `apps/wms/src/stock/stock.repository.spec.ts`
- Test: `apps/wms/src/stock/stock.service.spec.ts`
- Test: `apps/wms/src/stock/schemas/stock-balance.schema.spec.ts`
- Test: `apps/wms/src/stock/schemas/inventory-stock.schema.spec.ts`
- Test: `apps/wms/src/stock/schemas/stock-movement.schema.spec.ts`

**Interfaces:**
- Consumes: nothing new.
- Produces: `StockRepository` methods with `warehouseId` param dropped: `findBalanceByItemAndWarehouse(itemId, session?)` → **`findBalance(itemId, session?)`**, `upsertBalance(itemId, onHandDelta, reservedDelta, expiredDelta, session?)`, `reserveIfAvailable(itemId, quantity, session)`, `findInventory(itemId, shelfId, lotId, session?)`, `upsertInventory(itemId, shelfId, lotId, deltaQty, session?)`, `findInventoryByScope(shelfIds?)`, `findOccupiedVolumeByWarehouse()` → **`findOccupiedVolume()`** (no param), `findShelfIdsWithItem(itemId)` (drops warehouseId), `findAvailableStockForPick(itemId, isPerishable)` (drops warehouseId). `InsertMovementData` type drops `warehouseId`. `StockService.checkAndEmitStockLow(itemId)` (drops warehouseId param). Every later task calling any of these methods must drop the `warehouseId` argument.

- [ ] **Step 1: Edit `StockBalance` schema**

In `apps/wms/src/stock/schemas/stock-balance.schema.ts`, remove the `warehouseId` prop and change the unique index. Replace:
```typescript
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  itemId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

  @Prop({ required: true, default: 0 })
  onHand!: number;
```
with:
```typescript
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  itemId!: Types.ObjectId;

  @Prop({ required: true, default: 0 })
  onHand!: number;
```
and replace:
```typescript
// 1 bản ghi duy nhất per (item, warehouse) — upsert theo compound key này
StockBalanceSchema.index({ itemId: 1, warehouseId: 1 }, { unique: true });
```
with:
```typescript
// 1 bản ghi duy nhất per item — upsert theo key này (app = 1 kho duy nhất)
StockBalanceSchema.index({ itemId: 1 }, { unique: true });
```

- [ ] **Step 2: Edit `InventoryStock` schema**

In `apps/wms/src/stock/schemas/inventory-stock.schema.ts`, remove `warehouseId` prop, update the compound unique index. Replace:
```typescript
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  itemId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  shelfId!: Types.ObjectId;
```
with:
```typescript
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  itemId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  shelfId!: Types.ObjectId;
```
and replace:
```typescript
// 1 bản ghi per (item, warehouse, shelf, lot) — lotId có thể null nên dùng compound 4 chiều
InventoryStockSchema.index(
  { itemId: 1, warehouseId: 1, shelfId: 1, lotId: 1 },
  { unique: true },
);
```
with:
```typescript
// 1 bản ghi per (item, shelf, lot) — lotId có thể null nên dùng compound 3 chiều
InventoryStockSchema.index(
  { itemId: 1, shelfId: 1, lotId: 1 },
  { unique: true },
);
```

- [ ] **Step 3: Edit `StockMovement` schema**

In `apps/wms/src/stock/schemas/stock-movement.schema.ts`, remove `warehouseId` prop and update the index. Replace:
```typescript
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  itemId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  shelfId!: Types.ObjectId;
```
with:
```typescript
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  itemId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  shelfId!: Types.ObjectId;
```
and replace:
```typescript
StockMovementSchema.index({ itemId: 1, warehouseId: 1, createdAt: -1 });
```
with:
```typescript
StockMovementSchema.index({ itemId: 1, createdAt: -1 });
```

- [ ] **Step 4: Edit `stock.repository.ts` — drop `warehouseId` from every signature**

In `apps/wms/src/stock/stock.repository.ts`:

Replace `InsertMovementData`:
```typescript
type InsertMovementData = {
  itemId: Types.ObjectId;
  warehouseId: Types.ObjectId;
  shelfId: Types.ObjectId;
  lotId: Types.ObjectId | null;
  type: MovementType;
  quantity: number;
  refType: string;
  refId: Types.ObjectId;
  createdBy: Types.ObjectId;
};
```
with:
```typescript
type InsertMovementData = {
  itemId: Types.ObjectId;
  shelfId: Types.ObjectId;
  lotId: Types.ObjectId | null;
  type: MovementType;
  quantity: number;
  refType: string;
  refId: Types.ObjectId;
  createdBy: Types.ObjectId;
};
```

Replace `LotInventorySummary`:
```typescript
export interface LotInventorySummary {
  itemId: Types.ObjectId;
  warehouseId: Types.ObjectId;
  sku: string;
  qty: number;
}
```
with:
```typescript
export interface LotInventorySummary {
  itemId: Types.ObjectId;
  sku: string;
  qty: number;
}
```

Replace `findBalanceByItemAndWarehouse`:
```typescript
  findBalanceByItemAndWarehouse(
    itemId: Types.ObjectId,
    warehouseId: Types.ObjectId,
    session?: ClientSession,
  ): Promise<StockBalanceDocument | null> {
    return this.balanceModel
      .findOne({ itemId, warehouseId }, null, { session })
      .exec();
  }
```
with:
```typescript
  findBalance(
    itemId: Types.ObjectId,
    session?: ClientSession,
  ): Promise<StockBalanceDocument | null> {
    return this.balanceModel.findOne({ itemId }, null, { session }).exec();
  }
```

Replace `upsertBalance`:
```typescript
  upsertBalance(
    itemId: Types.ObjectId,
    warehouseId: Types.ObjectId,
    onHandDelta: number,
    reservedDelta: number,
    expiredDelta: number,
    session?: ClientSession,
  ): Promise<StockBalanceDocument | null> {
    return this.balanceModel
      .findOneAndUpdate(
        { itemId, warehouseId },
        {
          $inc: {
            onHand: onHandDelta,
            reserved: reservedDelta,
            expired: expiredDelta,
          },
        },
        { upsert: true, new: true, session },
      )
      .exec();
  }
```
with:
```typescript
  upsertBalance(
    itemId: Types.ObjectId,
    onHandDelta: number,
    reservedDelta: number,
    expiredDelta: number,
    session?: ClientSession,
  ): Promise<StockBalanceDocument | null> {
    return this.balanceModel
      .findOneAndUpdate(
        { itemId },
        {
          $inc: {
            onHand: onHandDelta,
            reserved: reservedDelta,
            expired: expiredDelta,
          },
        },
        { upsert: true, new: true, session },
      )
      .exec();
  }
```

Replace `reserveIfAvailable`:
```typescript
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
```
with:
```typescript
  async reserveIfAvailable(
    itemId: Types.ObjectId,
    quantity: number,
    session: ClientSession,
  ): Promise<boolean> {
    const updated = await this.balanceModel
      .findOneAndUpdate(
        {
          itemId,
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
```

Replace `findInventory`:
```typescript
  findInventory(
    itemId: Types.ObjectId,
    warehouseId: Types.ObjectId,
    shelfId: Types.ObjectId,
    lotId: Types.ObjectId | null,
    session?: ClientSession,
  ): Promise<InventoryStockDocument | null> {
    return this.inventoryModel
      .findOne({ itemId, warehouseId, shelfId, lotId }, null, { session })
      .exec();
  }
```
with:
```typescript
  findInventory(
    itemId: Types.ObjectId,
    shelfId: Types.ObjectId,
    lotId: Types.ObjectId | null,
    session?: ClientSession,
  ): Promise<InventoryStockDocument | null> {
    return this.inventoryModel
      .findOne({ itemId, shelfId, lotId }, null, { session })
      .exec();
  }
```

Replace `upsertInventory`:
```typescript
  upsertInventory(
    itemId: Types.ObjectId,
    warehouseId: Types.ObjectId,
    shelfId: Types.ObjectId,
    lotId: Types.ObjectId | null,
    deltaQty: number,
    session?: ClientSession,
  ): Promise<InventoryStockDocument | null> {
    return this.inventoryModel
      .findOneAndUpdate(
        { itemId, warehouseId, shelfId, lotId },
        { $inc: { quantity: deltaQty } },
        { upsert: true, new: true, session },
      )
      .exec();
  }
```
with:
```typescript
  upsertInventory(
    itemId: Types.ObjectId,
    shelfId: Types.ObjectId,
    lotId: Types.ObjectId | null,
    deltaQty: number,
    session?: ClientSession,
  ): Promise<InventoryStockDocument | null> {
    return this.inventoryModel
      .findOneAndUpdate(
        { itemId, shelfId, lotId },
        { $inc: { quantity: deltaQty } },
        { upsert: true, new: true, session },
      )
      .exec();
  }
```

Replace `findInventoryByScope`:
```typescript
  findInventoryByScope(
    warehouseId: Types.ObjectId,
    shelfIds?: Types.ObjectId[],
  ): Promise<InventoryStockDocument[]> {
    const filter: Record<string, unknown> = { warehouseId };
    if (shelfIds) filter['shelfId'] = { $in: shelfIds };
    return this.inventoryModel.find(filter).exec();
  }
```
with:
```typescript
  findInventoryByScope(
    shelfIds?: Types.ObjectId[],
  ): Promise<InventoryStockDocument[]> {
    const filter: Record<string, unknown> = {};
    if (shelfIds) filter['shelfId'] = { $in: shelfIds };
    return this.inventoryModel.find(filter).exec();
  }
```

Replace `findOccupiedVolumeByWarehouse` (rename to `findOccupiedVolume`, drop the `$match` on `warehouseId`):
```typescript
  async findOccupiedVolumeByWarehouse(
    warehouseId: Types.ObjectId,
  ): Promise<Map<string, number>> {
    const rows = await this.inventoryModel.aggregate<{
      shelfId: string;
      occupied: number;
    }>([
      { $match: { warehouseId, quantity: { $gt: 0 } } },
```
with:
```typescript
  async findOccupiedVolume(): Promise<Map<string, number>> {
    const rows = await this.inventoryModel.aggregate<{
      shelfId: string;
      occupied: number;
    }>([
      { $match: { quantity: { $gt: 0 } } },
```
(leave the rest of the aggregation pipeline — `$lookup`, `$unwind`, `$group`, `$project` — untouched; update the doc comment above the method to drop the "per warehouse" framing, replacing "Tính thể tích đã chiếm (cm³) của mọi shelf trong 1 kho" with "Tính thể tích đã chiếm (cm³) của mọi shelf" and "Map trả về là warehouse-wide" with "Map trả về toàn hệ thống").

Replace `findShelfIdsWithItem`:
```typescript
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
with:
```typescript
  async findShelfIdsWithItem(itemId: Types.ObjectId): Promise<Set<string>> {
    const shelfIds = await this.inventoryModel
      .distinct('shelfId', { itemId, quantity: { $gt: 0 } })
      .exec();
    return new Set(shelfIds.map((id: Types.ObjectId) => id.toString()));
  }
```

Replace `findAvailableStockForPick` signature and its two `$match` stages:
```typescript
  async findAvailableStockForPick(
    itemId: Types.ObjectId,
    warehouseId: Types.ObjectId,
    isPerishable: boolean,
  ): Promise<PickSuggestion[]> {
```
with:
```typescript
  async findAvailableStockForPick(
    itemId: Types.ObjectId,
    isPerishable: boolean,
  ): Promise<PickSuggestion[]> {
```
and inside the method body, replace both occurrences of:
```typescript
            itemId,
            warehouseId,
            lotId: null,
```
and
```typescript
          itemId,
          warehouseId,
          quantity: { $gt: 0 },
          lotId: { $ne: null },
```
by deleting the `warehouseId,` line from each `$match` (find both `$match` blocks in the method — the non-perishable branch and the perishable branch — and drop `warehouseId,` from each).

Replace `sumInventoryByLot`'s aggregation `$group`/`$project` to drop `warehouseId`:
```typescript
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
```
with:
```typescript
      {
        $group: {
          _id: '$itemId',
          qty: { $sum: '$quantity' },
        },
      },
      {
        $lookup: {
          from: 'warehouse_items',
          localField: '_id',
          foreignField: '_id',
          as: 'item',
        },
      },
      { $unwind: '$item' },
      {
        $project: {
          _id: 0,
          itemId: '$_id',
          sku: '$item.sku',
          qty: 1,
        },
      },
```

- [ ] **Step 5: Edit `stock.service.ts` — `checkAndEmitStockLow`**

Replace:
```typescript
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
with:
```typescript
  async checkAndEmitStockLow(itemId: Types.ObjectId): Promise<void> {
    const item = await this.stockRepo.findSkuAndMinQuantityById(itemId);
    if (!item || item.minQuantity == null) return;

    const balance = await this.stockRepo.findBalance(itemId);
    if (!balance) return;

    const available = balance.onHand - balance.reserved - balance.expired;
    if (available >= item.minQuantity) return;

    const payload: StockLowPayload = {
      sku: item.sku,
      available,
      minQuantity: item.minQuantity,
    };
    await this.notificationQueue.add(EVENTS.STOCK_LOW, payload);
    this.logger.log(
      `stock.low → sku=${item.sku} available=${available} minQuantity=${item.minQuantity}`,
    );
  }
```
Also update the doc comment above this method — it currently reads "biến động phía WMS) sau" style text mentioning `1 (item,warehouse)` — replace "khi 1 (item,warehouse) bị chạm nhiều lần" with "khi 1 item bị chạm nhiều lần".

- [ ] **Step 6: Update the module doc comments mentioning per-warehouse aggregation**

In `stock.repository.ts`, the comment above `sumInventoryByLot` says "cộng dồn StockBalance.expired đúng cho từng kho (1 lô có thể nằm rải rác nhiều kho/shelf)" — update to "cộng dồn StockBalance.expired đúng (1 lô có thể nằm rải rác nhiều shelf)".

- [ ] **Step 7: Update `stock.repository.spec.ts` and `stock.service.spec.ts`**

Read both spec files, remove every `warehouseId` argument from mock calls and assertions matching the signature changes above (e.g. `stockRepo.upsertBalance(itemId, warehouseId, ...)` → `stockRepo.upsertBalance(itemId, ...)`; `stockRepo.reserveIfAvailable(itemId, warehouseId, qty, session)` → `stockRepo.reserveIfAvailable(itemId, qty, session)`; `checkAndEmitStockLow(itemId, warehouseId)` → `checkAndEmitStockLow(itemId)`). Update any fixture object literals that set `warehouseId` on `StockBalance`/`InventoryStock`/`StockMovement` test documents to drop that field.

- [ ] **Step 8: Update the 3 schema spec files**

In `stock-balance.schema.spec.ts`, `inventory-stock.schema.spec.ts`, `stock-movement.schema.spec.ts`, remove any assertion referencing the `warehouseId` field or the old compound unique index shape; update index-shape assertions to match the new indexes from Steps 1-3.

- [ ] **Step 9: Run stock module tests**

Run: `pnpm test -- apps/wms/src/stock`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add apps/wms/src/stock
git commit -m "refactor(stock): bỏ warehouseId khỏi StockBalance/InventoryStock/StockMovement + repository/service"
```

---

### Task 4: Reservation — simplify to single-pool reserve, no warehouse loop

**Files:**
- Modify: `apps/wms/src/reservation/reservation.service.ts`
- Modify: `apps/wms/src/reservation/reservation.consumer.ts`
- Modify: `apps/wms/src/reservation/reservation.module.ts`
- Test: `apps/wms/src/reservation/reservation.service.spec.ts`
- Test: `apps/wms/src/reservation/reservation.consumer.spec.ts`

**Interfaces:**
- Consumes: `LocationModule`/`LocationRepository.findStagingShelf()` (Task 2), `StockRepository.reserveIfAvailable(itemId, quantity, session)` / `upsertBalance(itemId, onHandDelta, reservedDelta, expiredDelta, session?)` / `insertMovement` without `warehouseId` (Task 3), `StockReservedPayload`/`StockReserveRequestedPayload` without warehouse fields (Task 1).
- Produces: `ReservationService.reserveForOrder(orderId, items)` (no `preferWarehouse` param), `releaseForOrder(orderId)` unchanged signature.

- [ ] **Step 1: Rewrite `reservation.service.ts`**

Replace the entire file content with:
```typescript
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
import { LocationRepository } from '../location/location.repository';
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
    private readonly locationRepo: LocationRepository,
    private readonly goodsIssueRepo: GoodsIssueRepository,
    @InjectQueue(QUEUES.ORDER_REPLY) private readonly orderReplyQueue: Queue,
  ) {}

  /**
   * Xử lý STOCK_RESERVE_REQUESTED. Idempotent theo orderId (kiểm tra đã có
   * movement 'reservation' chưa). App = 1 kho duy nhất nên reserve trực tiếp
   * trên pool tồn kho chung, atomic theo từng sku trong 1 transaction — nếu
   * 1 sku không đủ, transaction abort và toàn bộ reserve tạm thời tự rollback.
   */
  async reserveForOrder(
    orderId: string,
    items: ReserveItem[],
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

    const resolvedItems: {
      itemId: Types.ObjectId;
      sku: string;
      quantity: number;
    }[] = [];
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

    if (missingSkus.length > 0) {
      await this.emitReserveFailed(
        orderId,
        `Sku không tồn tại: ${missingSkus.join(', ')}`,
        missingSkus,
      );
      return;
    }

    const stagingShelf = await this.locationRepo.findStagingShelf();
    if (!stagingShelf) {
      await this.emitReserveFailed(
        orderId,
        'Hệ thống chưa cấu hình vị trí nhận hàng (staging)',
        resolvedItems.map((i) => i.sku),
      );
      return;
    }

    const reserved = await this.tryReserveAll(
      orderId,
      resolvedItems,
      stagingShelf._id,
    );
    if (reserved) {
      await this.emitReserved(orderId);
      return;
    }

    await this.emitReserveFailed(
      orderId,
      'Không đủ tồn cho toàn bộ đơn hàng',
      resolvedItems.map((i) => i.sku),
    );
  }

  private async tryReserveAll(
    orderId: string,
    items: { itemId: Types.ObjectId; sku: string; quantity: number }[],
    stagingShelfId: Types.ObjectId,
  ): Promise<boolean> {
    let allReserved = true;
    try {
      await this.stockTransactionHelper.withStockTransaction(
        async (session) => {
          for (const item of items) {
            const ok = await this.stockRepo.reserveIfAvailable(
              item.itemId,
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
        },
      );
    } catch (err) {
      if (err instanceof Error && err.message === 'INSUFFICIENT_STOCK') {
        return false;
      }
      throw err;
    }
    return allReserved;
  }

  private async emitReserved(orderId: string): Promise<void> {
    const payload: StockReservedPayload = { orderId };
    await this.orderReplyQueue.add(EVENTS.STOCK_RESERVED, payload, {
      jobId: `reservation:${orderId}`,
    });
    this.logger.log(`stock.reserved → orderId=${orderId}`);
  }

  private async emitReserveFailed(
    orderId: string,
    reason: string,
    failedSkus: string[],
  ): Promise<void> {
    const payload: StockReserveFailedPayload = { orderId, reason, failedSkus };
    await this.orderReplyQueue.add(EVENTS.STOCK_RESERVE_FAILED, payload, {
      jobId: `reservation-failed:${orderId}`,
    });
    this.logger.warn(
      `stock.reserve_failed → orderId=${orderId} reason=${reason}`,
    );
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
      this.logger.warn(
        `Đơn ${orderId} đã được release trước đó → bỏ qua (idempotent).`,
      );
      return;
    }

    const reserveMovements = await this.stockRepo.findMovementsByRef(
      REF_TYPE_RESERVE,
      orderObjectId,
    );
    if (reserveMovements.length === 0) {
      this.logger.warn(
        `Đơn ${orderId} chưa từng được reserve → không có gì để release.`,
      );
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
          0,
          -movement.quantity,
          0,
          session,
        );
        await this.stockRepo.insertMovement(
          {
            itemId: movement.itemId,
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

    this.logger.log(
      `stock.release → orderId=${orderId} (${reserveMovements.length} dòng)`,
    );
  }
}
```

- [ ] **Step 2: Update `reservation.consumer.ts`**

Change:
```typescript
        await this.reservationService.reserveForOrder(
          data.orderId,
          data.items,
          data.preferWarehouse,
        );
```
to:
```typescript
        await this.reservationService.reserveForOrder(
          data.orderId,
          data.items,
        );
```

- [ ] **Step 3: Update `reservation.module.ts`**

Change:
```typescript
import { WarehouseModule } from '../warehouse/warehouse.module';
```
to:
```typescript
import { LocationModule } from '../location/location.module';
```
and change:
```typescript
    StockModule, // StockRepository + StockTransactionHelper
    WarehouseModule, // findAllActiveWarehouseIds + findStagingShelfByWarehouse
    GoodsIssueModule, // GoodsIssueRepository — kiểm tra GoodsIssue tồn tại trước khi release
```
to:
```typescript
    StockModule, // StockRepository + StockTransactionHelper
    LocationModule, // findStagingShelf
    GoodsIssueModule, // GoodsIssueRepository — kiểm tra GoodsIssue tồn tại trước khi release
```

- [ ] **Step 4: Rewrite `reservation.service.spec.ts`**

Read the existing spec, then rewrite it dropping every multi-warehouse test case (candidate loop, `preferWarehouse` ignored, "thử kho tiếp theo") and replacing with single-pool equivalents:
```typescript
describe('ReservationService', () => {
  // ... existing setup, mock LocationRepository instead of WarehouseRepository,
  // mock locationRepo.findStagingShelf() to resolve a shelf doc directly (no id arg)

  describe('reserveForOrder', () => {
    it('reserve thành công khi đủ tồn — emit stock.reserved không kèm fulfillWarehouseId', async () => {
      // stockRepo.findItemBySku resolves item, locationRepo.findStagingShelf resolves shelf,
      // stockRepo.reserveIfAvailable resolves true
      await service.reserveForOrder('order1', [{ sku: 'SKU1', quantity: 5 }]);
      expect(orderReplyQueue.add).toHaveBeenCalledWith(
        EVENTS.STOCK_RESERVED,
        { orderId: 'order1' },
        expect.objectContaining({ jobId: 'reservation:order1' }),
      );
    });

    it('emit stock.reserve_failed khi thiếu tồn, không thử lại kho khác', async () => {
      // stockRepo.reserveIfAvailable resolves false
      await service.reserveForOrder('order2', [{ sku: 'SKU1', quantity: 999 }]);
      expect(orderReplyQueue.add).toHaveBeenCalledWith(
        EVENTS.STOCK_RESERVE_FAILED,
        expect.objectContaining({ reason: 'Không đủ tồn cho toàn bộ đơn hàng' }),
        expect.anything(),
      );
    });

    it('emit stock.reserve_failed khi không có staging shelf', async () => {
      // locationRepo.findStagingShelf resolves null
      await service.reserveForOrder('order3', [{ sku: 'SKU1', quantity: 1 }]);
      expect(orderReplyQueue.add).toHaveBeenCalledWith(
        EVENTS.STOCK_RESERVE_FAILED,
        expect.objectContaining({
          reason: 'Hệ thống chưa cấu hình vị trí nhận hàng (staging)',
        }),
        expect.anything(),
      );
    });

    it('idempotent — bỏ qua nếu đã reserve trước đó', async () => {
      // stockRepo.hasMovementForRef resolves true
      await service.reserveForOrder('order4', [{ sku: 'SKU1', quantity: 1 }]);
      expect(orderReplyQueue.add).not.toHaveBeenCalled();
    });
  });

  describe('releaseForOrder', () => {
    // port existing release tests, drop warehouseId from upsertBalance/insertMovement assertions
  });
});
```
Fill in the exact mock wiring by matching the existing spec's `Test.createTestingModule` provider-mocking style (read the file first).

- [ ] **Step 5: Update `reservation.consumer.spec.ts`**

Update the test that asserts `reserveForOrder` is called with `data.preferWarehouse` — remove the 3rd argument from the expectation:
```typescript
expect(reservationService.reserveForOrder).toHaveBeenCalledWith(
  data.orderId,
  data.items,
);
```

- [ ] **Step 6: Run reservation module tests**

Run: `pnpm test -- apps/wms/src/reservation`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/wms/src/reservation
git commit -m "refactor(reservation): bỏ vòng lặp chọn kho, reserve trực tiếp trên pool tồn kho duy nhất"
```

---

### Task 5: Purchase Order — drop `warehouseId`

**Files:**
- Modify: `apps/wms/src/purchase-order/schemas/purchase-order.schema.ts`
- Modify: `apps/wms/src/purchase-order/dto/purchase-order.dto.ts`
- Modify: `apps/wms/src/purchase-order/purchase-order.service.ts`
- Modify: `apps/wms/src/purchase-order/purchase-order.repository.ts`
- Modify: `apps/wms/src/purchase-order/purchase-order.module.ts`
- Test: `apps/wms/src/purchase-order/purchase-order.service.spec.ts`
- Test: `apps/wms/src/purchase-order/purchase-order.repository.spec.ts`
- Test: `apps/wms/src/purchase-order/schemas/purchase-order.schema.spec.ts`

**Interfaces:**
- Consumes: nothing new (no longer needs `LocationModule`/`WarehouseModule` at all — the only use was validating `dto.warehouseId` exists).
- Produces: `PurchaseOrderRepository.createPurchaseOrder(dto, poNumber, resolvedItems, actorId)` unchanged shape minus `warehouseId` from what it writes; `PurchaseOrder` schema and `PurchaseOrderResponseDto` without `warehouseId`. `GoodsReceiptNoteService` (Task 6) reads `po.warehouseId` today — after this task that field no longer exists, so Task 6 must stop reading it.

- [ ] **Step 1: Edit `purchase-order.schema.ts`**

Remove:
```typescript
  /** Kho sẽ nhận hàng */
  @Prop({ type: Types.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

```
(the blank line between `supplierId` and `status` stays balanced — just delete these 3 lines including the comment).

- [ ] **Step 2: Edit `purchase-order.dto.ts`**

Remove from `CreatePurchaseOrderDto`:
```typescript
  @ApiProperty({ description: 'Warehouse._id (ObjectId)', example: '665f...' })
  @IsMongoId()
  warehouseId!: string;

```
Remove from `PurchaseOrderResponseDto`:
```typescript
  @Expose()
  @Transform(({ obj }: { obj: { warehouseId?: Types.ObjectId } }) =>
    obj.warehouseId?.toString(),
  )
  @ApiProperty()
  warehouseId!: string;

```

- [ ] **Step 3: Edit `purchase-order.service.ts`**

Remove the `WarehouseService` dependency entirely. Change constructor:
```typescript
  constructor(
    private readonly repo: PurchaseOrderRepository,
    private readonly supplierService: SupplierService,
    private readonly warehouseService: WarehouseService,
    private readonly stockRepo: StockRepository,
  ) {}
```
to:
```typescript
  constructor(
    private readonly repo: PurchaseOrderRepository,
    private readonly supplierService: SupplierService,
    private readonly stockRepo: StockRepository,
  ) {}
```
Remove the import `import { WarehouseService } from '../warehouse/warehouse.service';`.

Remove this block from `createPurchaseOrder`:
```typescript
    // Kho nhận hàng phải tồn tại
    await this.warehouseService.getWarehouse(dto.warehouseId);

```

- [ ] **Step 4: Edit `purchase-order.repository.ts`**

Remove `warehouseId: new Types.ObjectId(dto.warehouseId),` from `createPurchaseOrder`'s `this.model.create({...})` call.

- [ ] **Step 5: Edit `purchase-order.module.ts`**

Remove `import { WarehouseModule } from '../warehouse/warehouse.module';` and remove `WarehouseModule, // getWarehouse` from the `imports` array.

- [ ] **Step 6: Update tests**

In `purchase-order.service.spec.ts`: remove the `WarehouseService` mock provider and any test asserting `warehouseService.getWarehouse` was called; remove `warehouseId` from every `CreatePurchaseOrderDto` fixture.
In `purchase-order.repository.spec.ts`: remove `warehouseId` from fixtures and assertions.
In `schemas/purchase-order.schema.spec.ts`: remove any validation test for the `warehouseId` required field.

- [ ] **Step 7: Run purchase-order tests**

Run: `pnpm test -- apps/wms/src/purchase-order`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/wms/src/purchase-order
git commit -m "refactor(purchase-order): bỏ warehouseId khỏi PurchaseOrder"
```

---

### Task 6: Goods Receipt Note — drop `warehouseId`, use single staging shelf

**Files:**
- Modify: `apps/wms/src/goods-receipt-note/schemas/goods-receipt-note.schema.ts`
- Modify: `apps/wms/src/goods-receipt-note/dto/goods-receipt-note.dto.ts`
- Modify: `apps/wms/src/goods-receipt-note/goods-receipt-note.service.ts`
- Modify: `apps/wms/src/goods-receipt-note/goods-receipt-note.repository.ts`
- Modify: `apps/wms/src/goods-receipt-note/goods-receipt-note.module.ts`
- Test: `apps/wms/src/goods-receipt-note/goods-receipt-note.service.spec.ts`
- Test: `apps/wms/src/goods-receipt-note/goods-receipt-note.repository.spec.ts`
- Test: `apps/wms/src/goods-receipt-note/schemas/goods-receipt-note.schema.spec.ts`

**Interfaces:**
- Consumes: `LocationModule`/`LocationService.findStagingShelf()` (Task 2, no-arg), `PurchaseOrderService` without `warehouseId` on its response (Task 5), `StockRepository.upsertBalance/upsertInventory/insertMovement` without `warehouseId` (Task 3), `PutAwayService.createTaskFromGrn` — **this task changes that call's signature too**, see Step 4 below and confirm against Task 7.
- Produces: `GoodsReceiptNoteRepository.createGoodsReceiptNote(purchaseOrderId, grnNumber, resolvedItems, actorId)` (drops the `warehouseId` positional param).

- [ ] **Step 1: Edit `goods-receipt-note.schema.ts`**

Remove:
```typescript
  /** Copy từ PO.warehouseId tại thời điểm tạo */
  @Prop({ type: Types.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

```

- [ ] **Step 2: Edit `goods-receipt-note.dto.ts`**

Remove from `GoodsReceiptNoteResponseDto`:
```typescript
  @Expose()
  @Transform(({ obj }: { obj: { warehouseId?: Types.ObjectId } }) =>
    obj.warehouseId?.toString(),
  )
  @ApiProperty()
  warehouseId!: string;

```

- [ ] **Step 3: Edit `goods-receipt-note.repository.ts`**

Change `createGoodsReceiptNote` signature — drop `warehouseId`:
```typescript
  async createGoodsReceiptNote(
    purchaseOrderId: string,
    warehouseId: string,
    grnNumber: string,
    resolvedItems: ResolvedGoodsReceiptNoteItem[],
    actorId: string,
  ): Promise<GoodsReceiptNoteDocument> {
    return this.model.create({
      grnNumber,
      purchaseOrderId: new Types.ObjectId(purchaseOrderId),
      warehouseId: new Types.ObjectId(warehouseId),
      status: GoodsReceiptNoteStatus.DRAFT,
```
to:
```typescript
  async createGoodsReceiptNote(
    purchaseOrderId: string,
    grnNumber: string,
    resolvedItems: ResolvedGoodsReceiptNoteItem[],
    actorId: string,
  ): Promise<GoodsReceiptNoteDocument> {
    return this.model.create({
      grnNumber,
      purchaseOrderId: new Types.ObjectId(purchaseOrderId),
      status: GoodsReceiptNoteStatus.DRAFT,
```

- [ ] **Step 4: Edit `goods-receipt-note.service.ts`**

Change the constructor — replace `WarehouseService` with `LocationService`:
```typescript
import { WarehouseService } from '../warehouse/warehouse.service';
```
to:
```typescript
import { LocationService } from '../location/location.service';
```
and:
```typescript
    private readonly warehouseService: WarehouseService,
```
to:
```typescript
    private readonly locationService: LocationService,
```

In `createGoodsReceiptNote`, change:
```typescript
    const grnNumber = await this.generateGrnNumber();
    return this.repo.createGoodsReceiptNote(
      dto.purchaseOrderId,
      po.warehouseId.toString(),
      grnNumber,
      resolvedItems,
      actorId,
    );
```
to:
```typescript
    const grnNumber = await this.generateGrnNumber();
    return this.repo.createGoodsReceiptNote(
      dto.purchaseOrderId,
      grnNumber,
      resolvedItems,
      actorId,
    );
```

In `confirmGoodsReceiptNote`, change:
```typescript
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
```
to:
```typescript
    const stagingShelf = await this.locationService.findStagingShelf();

    // S4-04: item đã chạm upsertBalance trong transaction — dùng để
    // checkAndEmitStockLow SAU KHI commit (đọc lại balance, không dedup trùng
    // trong 1 GRN vì baseQtyByItem đã gộp theo itemId).
    const touchedItemIds = new Set<string>();
```

Change the put-away line loop body — replace:
```typescript
      for (const line of resolvedLines) {
        const itemObjectId = new Types.ObjectId(line.itemId);
        const warehouseObjectId = new Types.ObjectId(
          grn.warehouseId.toString(),
        );

        let lotId: Types.ObjectId | null = null;
```
with:
```typescript
      for (const line of resolvedLines) {
        const itemObjectId = new Types.ObjectId(line.itemId);

        let lotId: Types.ObjectId | null = null;
```

Change:
```typescript
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
```
to:
```typescript
        await this.stockRepo.upsertBalance(
          itemObjectId,
          line.baseQty,
          0,
          0,
          session,
        );
        touchedItemIds.add(line.itemId);
        await this.stockRepo.upsertInventory(
          itemObjectId,
          stagingShelf._id,
          lotId,
          line.baseQty,
          session,
        );
        await this.stockRepo.insertMovement(
          {
            itemId: itemObjectId,
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
```

Change the `createTaskFromGrn` call — drop the warehouse arg:
```typescript
      await this.putAwayService.createTaskFromGrn(
        grn._id,
        new Types.ObjectId(grn.warehouseId.toString()),
        putAwayLines,
        actorId,
        session,
      );
```
to:
```typescript
      await this.putAwayService.createTaskFromGrn(
        grn._id,
        putAwayLines,
        actorId,
        session,
      );
```
(This depends on Task 7 also dropping `warehouseId` from `PutAwayService.createTaskFromGrn` — do Task 6 and Task 7 in the same working session, or temporarily leave a `// TODO Task 7` if executing tasks out of order across sessions; but per this plan's ordering, Task 7 comes right after, so both signatures will be consistent before either task's tests run.)

Change the post-transaction stock-low check loop:
```typescript
    for (const { itemId, warehouseId } of touchedBalances.values()) {
      await this.stockService.checkAndEmitStockLow(itemId, warehouseId);
    }
```
to:
```typescript
    for (const itemIdStr of touchedItemIds) {
      await this.stockService.checkAndEmitStockLow(
        new Types.ObjectId(itemIdStr),
      );
    }
```

- [ ] **Step 5: Edit `goods-receipt-note.module.ts`**

Change:
```typescript
import { WarehouseModule } from '../warehouse/warehouse.module';
```
to:
```typescript
import { LocationModule } from '../location/location.module';
```
and:
```typescript
    WarehouseModule, // findStagingShelf
```
to:
```typescript
    LocationModule, // findStagingShelf
```

- [ ] **Step 6: Update tests**

In `goods-receipt-note.service.spec.ts`: rename the `WarehouseService` mock to `LocationService`, change `findStagingShelf` mock calls to take no argument, remove `warehouseId` from every fixture (PO fixture, GRN fixture), update `createTaskFromGrn` assertion to the new 4-arg signature, update `checkAndEmitStockLow` assertion to the new 1-arg signature.
In `goods-receipt-note.repository.spec.ts`: update `createGoodsReceiptNote` calls to drop the `warehouseId` positional arg.
In `schemas/goods-receipt-note.schema.spec.ts`: remove any `warehouseId` required-field test.

- [ ] **Step 7: Run goods-receipt-note tests**

Run: `pnpm test -- apps/wms/src/goods-receipt-note`
Expected: FAIL is acceptable at this exact point only if `PutAwayService.createTaskFromGrn` hasn't been updated yet (Task 7) — if so, note the failure and proceed to Task 7 immediately before re-running. If Task 7 is already done, expect PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/wms/src/goods-receipt-note
git commit -m "refactor(grn): bỏ warehouseId khỏi GoodsReceiptNote, dùng staging shelf duy nhất"
```

---

### Task 7: Put-Away + Put-Away-Suggestion — drop `warehouseId`

**Files:**
- Modify: `apps/wms/src/put-away/schemas/put-away-task.schema.ts`
- Modify: `apps/wms/src/put-away/dto/put-away.dto.ts`
- Modify: `apps/wms/src/put-away/put-away.service.ts`
- Modify: `apps/wms/src/put-away/put-away.repository.ts`
- Modify: `apps/wms/src/put-away/put-away.module.ts`
- Modify: `apps/wms/src/put-away-suggestion/dto/put-away-suggestion.dto.ts`
- Modify: `apps/wms/src/put-away-suggestion/put-away-suggestion.service.ts`
- Modify: `apps/wms/src/put-away-suggestion/put-away-suggestion.controller.ts`
- Modify: `apps/wms/src/put-away-suggestion/put-away-suggestion.module.ts`
- Test: `apps/wms/src/put-away/put-away.service.spec.ts`
- Test: `apps/wms/src/put-away/put-away.repository.spec.ts`
- Test: `apps/wms/src/put-away/schemas/put-away-task.schema.spec.ts`
- Test: `apps/wms/src/put-away-suggestion/put-away-suggestion.service.spec.ts`

**Interfaces:**
- Consumes: `LocationRepository`/`LocationService` (Task 2), `StockRepository` signatures without `warehouseId` (Task 3).
- Produces: `PutAwayService.createTaskFromGrn(grnId, lines, actorId, session)` (drops `warehouseId` — **this is what Task 6 Step 4 depends on**), `PutAwayRepository.createTask(grnId, lines, actorId, session)`.

- [ ] **Step 1: Edit `put-away-task.schema.ts`**

Remove:
```typescript
  @Prop({ type: Types.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

```
and change:
```typescript
PutAwayTaskSchema.index({ warehouseId: 1, status: 1 });
```
to:
```typescript
PutAwayTaskSchema.index({ status: 1 });
```

- [ ] **Step 2: Edit `put-away.dto.ts`**

Remove from `QueryPutAwayTaskDto`:
```typescript
  @ApiPropertyOptional({ description: 'Lọc theo kho' })
  @IsOptional()
  @IsMongoId()
  warehouseId?: string;

```
Remove from `PutAwayTaskResponseDto`:
```typescript
  @Expose()
  @Transform(({ obj }: { obj: { warehouseId?: Types.ObjectId } }) =>
    obj.warehouseId?.toString(),
  )
  @ApiProperty()
  warehouseId!: string;

```

- [ ] **Step 3: Edit `put-away.repository.ts`**

Change `QueryPutAwayTaskInput`:
```typescript
export interface QueryPutAwayTaskInput {
  warehouseId?: string;
  status?: PutAwayTaskStatus;
  page?: number;
  limit?: number;
}
```
to:
```typescript
export interface QueryPutAwayTaskInput {
  status?: PutAwayTaskStatus;
  page?: number;
  limit?: number;
}
```

Change `createTask`:
```typescript
  async createTask(
    grnId: Types.ObjectId,
    warehouseId: Types.ObjectId,
    lines: CreatePutAwayLineInput[],
    actorId: string,
    session: ClientSession,
  ): Promise<PutAwayTaskDocument> {
    const [doc] = await this.model.create(
      [
        {
          grnId,
          warehouseId,
          status: PutAwayTaskStatus.PENDING,
```
to:
```typescript
  async createTask(
    grnId: Types.ObjectId,
    lines: CreatePutAwayLineInput[],
    actorId: string,
    session: ClientSession,
  ): Promise<PutAwayTaskDocument> {
    const [doc] = await this.model.create(
      [
        {
          grnId,
          status: PutAwayTaskStatus.PENDING,
```

In `findTasks`, remove:
```typescript
    if (query.warehouseId)
      filter['warehouseId'] = new Types.ObjectId(query.warehouseId);
```

- [ ] **Step 4: Edit `put-away.service.ts`**

Change the `WarehouseModule` imports to `LocationModule`:
```typescript
import { WarehouseRepository } from '../warehouse/warehouse.repository';
import { WarehouseService } from '../warehouse/warehouse.service';
```
to:
```typescript
import { LocationRepository } from '../location/location.repository';
import { LocationService } from '../location/location.service';
```
and constructor:
```typescript
    private readonly warehouseRepo: WarehouseRepository,
    private readonly warehouseService: WarehouseService,
```
to:
```typescript
    private readonly locationRepo: LocationRepository,
    private readonly locationService: LocationService,
```

Change `createTaskFromGrn`:
```typescript
  async createTaskFromGrn(
    grnId: Types.ObjectId,
    warehouseId: Types.ObjectId,
    lines: CreatePutAwayLineFromGrnInput[],
    actorId: string,
    session: ClientSession,
  ): Promise<PutAwayTaskDocument> {
    return this.repo.createTask(
      grnId,
      warehouseId,
      lines.map((l) => ({
        itemId: new Types.ObjectId(l.itemId),
        lotId: l.lotId,
        quantity: l.quantity,
      })),
      actorId,
      session,
    );
  }
```
to:
```typescript
  async createTaskFromGrn(
    grnId: Types.ObjectId,
    lines: CreatePutAwayLineFromGrnInput[],
    actorId: string,
    session: ClientSession,
  ): Promise<PutAwayTaskDocument> {
    return this.repo.createTask(
      grnId,
      lines.map((l) => ({
        itemId: new Types.ObjectId(l.itemId),
        lotId: l.lotId,
        quantity: l.quantity,
      })),
      actorId,
      session,
    );
  }
```

In `confirmLine`, change:
```typescript
    const shelf = await this.warehouseRepo.findShelfByCode(dto.shelfCode);
    if (!shelf) throw new AppException('PUTAWAY_SHELF_NOT_FOUND');
    // findShelfByCode tra theo code TOÀN CỤC (unique toàn hệ thống, không lọc
    // theo kho) — nếu RECEIVER quét nhầm 1 shelf hợp lệ nhưng thuộc kho khác
    // với task.warehouseId, phải chặn ở đây. Nếu không chặn, InventoryStock sẽ
    // được ghi với warehouseId=task.warehouseId nhưng shelfId thực tế thuộc kho
    // khác → dữ liệu tồn kho mâu thuẫn. Tái dùng PUTAWAY_SHELF_NOT_FOUND vì với
    // kho của task này, shelf đó coi như không hợp lệ/không tồn tại.
    if (shelf.warehouseId.toString() !== task.warehouseId.toString()) {
      throw new AppException('PUTAWAY_SHELF_NOT_FOUND');
    }
    if (shelf.isStaging) throw new AppException('PUTAWAY_SHELF_IS_STAGING');
```
to:
```typescript
    const shelf = await this.locationRepo.findShelfByCode(dto.shelfCode);
    if (!shelf) throw new AppException('PUTAWAY_SHELF_NOT_FOUND');
    if (shelf.isStaging) throw new AppException('PUTAWAY_SHELF_IS_STAGING');
```

Change:
```typescript
    const stagingShelf = await this.warehouseService.findStagingShelf(
      task.warehouseId.toString(),
    );
```
to:
```typescript
    const stagingShelf = await this.locationService.findStagingShelf();
```

In the transaction block, remove `task.warehouseId` from both `upsertInventory` calls and both `insertMovement` calls:
```typescript
      await this.stockRepo.upsertInventory(
        item._id,
        task.warehouseId,
        stagingShelf._id,
        lotId,
        -dto.quantity,
        session,
      );
      await this.stockRepo.upsertInventory(
        item._id,
        task.warehouseId,
        shelf._id,
        lotId,
        dto.quantity,
        session,
      );
      await this.stockRepo.insertMovement(
        {
          itemId: item._id,
          warehouseId: task.warehouseId,
          shelfId: stagingShelf._id,
          lotId,
          type: MovementType.PUTAWAY,
          quantity: -dto.quantity,
          refType: 'put_away_task',
          refId: task._id,
          createdBy: new Types.ObjectId(actorId),
        },
        session,
      );
      await this.stockRepo.insertMovement(
        {
          itemId: item._id,
          warehouseId: task.warehouseId,
          shelfId: shelf._id,
          lotId,
          type: MovementType.PUTAWAY,
          quantity: dto.quantity,
          refType: 'put_away_task',
          refId: task._id,
          createdBy: new Types.ObjectId(actorId),
        },
        session,
      );
```
to:
```typescript
      await this.stockRepo.upsertInventory(
        item._id,
        stagingShelf._id,
        lotId,
        -dto.quantity,
        session,
      );
      await this.stockRepo.upsertInventory(
        item._id,
        shelf._id,
        lotId,
        dto.quantity,
        session,
      );
      await this.stockRepo.insertMovement(
        {
          itemId: item._id,
          shelfId: stagingShelf._id,
          lotId,
          type: MovementType.PUTAWAY,
          quantity: -dto.quantity,
          refType: 'put_away_task',
          refId: task._id,
          createdBy: new Types.ObjectId(actorId),
        },
        session,
      );
      await this.stockRepo.insertMovement(
        {
          itemId: item._id,
          shelfId: shelf._id,
          lotId,
          type: MovementType.PUTAWAY,
          quantity: dto.quantity,
          refType: 'put_away_task',
          refId: task._id,
          createdBy: new Types.ObjectId(actorId),
        },
        session,
      );
```

- [ ] **Step 5: Edit `put-away.module.ts`**

Change `WarehouseModule` import/registration to `LocationModule` (same pattern as Task 6 Step 5).

- [ ] **Step 6: Edit `put-away-suggestion.dto.ts`**

Remove from `QueryPutAwaySuggestionDto`:
```typescript
  @ApiProperty({ example: '60d5ec49f1b2c72b3c8e4f01' })
  @IsMongoId()
  warehouseId!: string;

```
(Remove the now-unused `IsMongoId` import if nothing else in the file uses it — check remaining usages first; `sku`/`qty` use `IsString`/`IsInt`, so `IsMongoId` becomes unused and must be dropped from the import line.)

- [ ] **Step 7: Edit `put-away-suggestion.service.ts`**

Change the constructor — `WarehouseRepository` → `LocationRepository`:
```typescript
import { WarehouseRepository } from '../warehouse/warehouse.repository';
```
to:
```typescript
import { LocationRepository } from '../location/location.repository';
```
and:
```typescript
    private readonly warehouseRepo: WarehouseRepository,
```
to:
```typescript
    private readonly locationRepo: LocationRepository,
```

Change `suggest` signature and body:
```typescript
  async suggest(
    sku: string,
    qty: number,
    warehouseId: string,
  ): Promise<PutAwaySuggestionResult> {
```
to:
```typescript
  async suggest(sku: string, qty: number): Promise<PutAwaySuggestionResult> {
```

Change:
```typescript
    const shelves =
      await this.warehouseRepo.findShelvesByWarehouse(warehouseId);
```
to:
```typescript
    const shelves = await this.locationRepo.findShelves();
```

Change:
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
to:
```typescript
    const [occupiedByShelf, shelfIdsWithSameSku] = await Promise.all([
      this.stockRepo.findOccupiedVolume(),
      this.stockRepo.findShelfIdsWithItem(item._id),
    ]);
```
(`Types` import from `mongoose` may become unused if nothing else in the file uses `Types.ObjectId` — check before removing the import; `item._id` is already an `ObjectId` so no new usage is introduced.)

- [ ] **Step 8: Edit `put-away-suggestion.controller.ts`**

Change:
```typescript
    const result = await this.svc.suggest(
      query.sku,
      query.qty,
      query.warehouseId,
    );
```
to:
```typescript
    const result = await this.svc.suggest(query.sku, query.qty);
```

- [ ] **Step 9: Edit `put-away-suggestion.module.ts`**

Change `WarehouseModule` → `LocationModule` (same pattern as before).

- [ ] **Step 10: Update tests**

`put-away.service.spec.ts`: rename `WarehouseRepository`/`WarehouseService` mocks to `LocationRepository`/`LocationService`; update `createTaskFromGrn` calls to drop `warehouseId` (3 remaining args + session); update `findStagingShelf` mock to no-arg; remove the "shelf belongs to different warehouse" test case entirely (no longer applicable — there's only one warehouse); update `upsertInventory`/`insertMovement` assertions to drop `warehouseId`.

`put-away.repository.spec.ts`: update `createTask` calls to drop the `warehouseId` positional arg; remove `warehouseId` filter test from `findTasks`.

`schemas/put-away-task.schema.spec.ts`: remove `warehouseId` required-field test; update index assertion.

`put-away-suggestion.service.spec.ts`: update `suggest()` calls to 2 args; rename repo mock to `LocationRepository`; update `findShelves`/`findOccupiedVolume`/`findShelfIdsWithItem` mock names and call-argument assertions.

- [ ] **Step 11: Run put-away + put-away-suggestion tests**

Run: `pnpm test -- apps/wms/src/put-away apps/wms/src/put-away-suggestion`
Expected: PASS.

- [ ] **Step 12: Run goods-receipt-note tests again (unblocked by this task)**

Run: `pnpm test -- apps/wms/src/goods-receipt-note`
Expected: PASS (this was deferred at the end of Task 6 pending this task's `createTaskFromGrn` signature change).

- [ ] **Step 13: Commit**

```bash
git add apps/wms/src/put-away apps/wms/src/put-away-suggestion
git commit -m "refactor(put-away): bỏ warehouseId khỏi PutAwayTask + suggestion algorithm dùng toàn bộ shelf hệ thống"
```

---

### Task 8: Goods Issue — drop `warehouseId`

**Files:**
- Modify: `apps/wms/src/goods-issue/schemas/goods-issue.schema.ts`
- Modify: `apps/wms/src/goods-issue/dto/goods-issue.dto.ts`
- Modify: `apps/wms/src/goods-issue/goods-issue.service.ts`
- Modify: `apps/wms/src/goods-issue/goods-issue.repository.ts`
- Modify: `apps/wms/src/goods-issue/goods-issue.module.ts`
- Modify: `apps/wms/src/goods-issue/order-ready.consumer.ts`
- Test: `apps/wms/src/goods-issue/goods-issue.service.spec.ts`
- Test: `apps/wms/src/goods-issue/goods-issue.repository.spec.ts`
- Test: `apps/wms/src/goods-issue/order-ready.consumer.spec.ts`

**Interfaces:**
- Consumes: `OrderReadyToFulfillPayload` without `fulfillWarehouseId` (Task 1), `LocationRepository` (Task 2), `StockRepository` signatures without `warehouseId` (Task 3).
- Produces: `GoodsIssueService.createFromOrderReady(orderId, items, shippingAddress, recipient, paymentMethod, codAmount)` (drops the `warehouseId` positional param).

- [ ] **Step 1: Check `order-ready.consumer.ts` for how it calls `createFromOrderReady`**

Run: `grep -n "createFromOrderReady" apps/wms/src/goods-issue/order-ready.consumer.ts`
Read the surrounding lines to see exactly how `data.fulfillWarehouseId` (from `OrderReadyToFulfillPayload`) is currently passed through — this determines the exact edit in Step 6.

- [ ] **Step 2: Edit `goods-issue.schema.ts`**

Remove:
```typescript
  @Prop({ type: Types.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

```

- [ ] **Step 3: Edit `goods-issue.dto.ts`**

Remove from `GoodsIssueResponseDto`:
```typescript
  @Expose()
  @Transform(({ obj }: { obj: { warehouseId?: Types.ObjectId } }) =>
    obj.warehouseId?.toString(),
  )
  @ApiProperty()
  warehouseId!: string;

```

- [ ] **Step 4: Edit `goods-issue.repository.ts`**

Change `CreateGoodsIssueInput`:
```typescript
export interface CreateGoodsIssueInput {
  orderId: string;
  warehouseId: Types.ObjectId;
  lines: CreateGoodsIssueLineInput[];
```
to:
```typescript
export interface CreateGoodsIssueInput {
  orderId: string;
  lines: CreateGoodsIssueLineInput[];
```
In `createGoodsIssue`, remove `warehouseId: input.warehouseId,` from the created document.

- [ ] **Step 5: Edit `goods-issue.service.ts`**

Change `WarehouseRepository` → `LocationRepository`:
```typescript
import { WarehouseRepository } from '../warehouse/warehouse.repository';
```
to:
```typescript
import { LocationRepository } from '../location/location.repository';
```
and:
```typescript
    private readonly warehouseRepo: WarehouseRepository,
```
to:
```typescript
    private readonly locationRepo: LocationRepository,
```

Change `createFromOrderReady`:
```typescript
  async createFromOrderReady(
    orderId: string,
    warehouseId: string,
    items: OrderReadyItem[],
    shippingAddress: Record<string, unknown>,
    recipient: { name: string; phone: string },
    paymentMethod: 'COD' | 'ONLINE',
    codAmount: number,
  ): Promise<void> {
```
to:
```typescript
  async createFromOrderReady(
    orderId: string,
    items: OrderReadyItem[],
    shippingAddress: Record<string, unknown>,
    recipient: { name: string; phone: string },
    paymentMethod: 'COD' | 'ONLINE',
    codAmount: number,
  ): Promise<void> {
```

Change:
```typescript
    await this.repo.createGoodsIssue({
      orderId,
      warehouseId: new Types.ObjectId(warehouseId),
      lines,
```
to:
```typescript
    await this.repo.createGoodsIssue({
      orderId,
      lines,
```

In `getPickSuggestions`, change:
```typescript
    return this.stockRepo.findAvailableStockForPick(
      new Types.ObjectId(itemId),
      gi.warehouseId,
      isPerishable,
    );
```
to:
```typescript
    return this.stockRepo.findAvailableStockForPick(
      new Types.ObjectId(itemId),
      isPerishable,
    );
```

In `confirmLine`, change:
```typescript
    const shelf = await this.warehouseRepo.findShelfByCode(dto.shelfCode);
    if (!shelf) throw new AppException('GOODS_ISSUE_SHELF_NOT_FOUND');
    if (shelf.warehouseId.toString() !== gi.warehouseId.toString()) {
      throw new AppException('GOODS_ISSUE_SHELF_NOT_FOUND');
    }
```
to:
```typescript
    const shelf = await this.locationRepo.findShelfByCode(dto.shelfCode);
    if (!shelf) throw new AppException('GOODS_ISSUE_SHELF_NOT_FOUND');
```

Change:
```typescript
    const lotId = dto.lotId ? new Types.ObjectId(dto.lotId) : null;
    const inventory = await this.stockRepo.findInventory(
      item._id,
      gi.warehouseId,
      shelf._id,
      lotId,
    );
```
to:
```typescript
    const lotId = dto.lotId ? new Types.ObjectId(dto.lotId) : null;
    const inventory = await this.stockRepo.findInventory(
      item._id,
      shelf._id,
      lotId,
    );
```

In the transaction block, change:
```typescript
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
```
to:
```typescript
      await this.stockRepo.upsertInventory(
        item._id,
        shelf._id,
        lotId,
        -dto.quantity,
        session,
      );
      await this.stockRepo.upsertBalance(
        item._id,
        -dto.quantity,
        -dto.quantity,
        0,
        session,
      );
      await this.stockRepo.insertMovement(
        {
          itemId: item._id,
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
```

Change:
```typescript
    // S4-04: kiểm tra ngưỡng thấp tồn — sau khi transaction commit.
    await this.stockService.checkAndEmitStockLow(item._id, gi.warehouseId);
```
to:
```typescript
    // S4-04: kiểm tra ngưỡng thấp tồn — sau khi transaction commit.
    await this.stockService.checkAndEmitStockLow(item._id);
```

- [ ] **Step 6: Edit `order-ready.consumer.ts`**

Based on the exact call site found in Step 1, drop the `warehouseId`/`fulfillWarehouseId` argument passed to `createFromOrderReady`. The typical shape (adjust to match the real file):
```typescript
    await this.goodsIssueService.createFromOrderReady(
      data.orderId,
      data.fulfillWarehouseId,
      data.items,
      data.shippingAddress,
      data.recipient,
      data.paymentMethod,
      data.codAmount ?? 0,
    );
```
becomes:
```typescript
    await this.goodsIssueService.createFromOrderReady(
      data.orderId,
      data.items,
      data.shippingAddress,
      data.recipient,
      data.paymentMethod,
      data.codAmount ?? 0,
    );
```
This compiles cleanly against the Task 1 payload change (`OrderReadyToFulfillPayload` no longer has `fulfillWarehouseId`, so `data.fulfillWarehouseId` would already be a type error before this edit — confirming this file needed the fix).

- [ ] **Step 7: Edit `goods-issue.module.ts`**

Change `WarehouseModule` → `LocationModule` (same pattern as before).

- [ ] **Step 8: Update tests**

`goods-issue.service.spec.ts`: rename `WarehouseRepository` mock to `LocationRepository`; drop `warehouseId` from every `createFromOrderReady` call, `CreateGoodsIssueInput` fixture, and stock-repo call assertion; remove the "shelf belongs to different warehouse" test case (no longer applicable).
`goods-issue.repository.spec.ts`: drop `warehouseId` from `CreateGoodsIssueInput` fixtures and assertions.
`order-ready.consumer.spec.ts`: update the payload fixture to drop `fulfillWarehouseId`, update the `createFromOrderReady` call assertion to the new signature.

- [ ] **Step 9: Run goods-issue tests**

Run: `pnpm test -- apps/wms/src/goods-issue`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add apps/wms/src/goods-issue
git commit -m "refactor(goods-issue): bỏ warehouseId khỏi GoodsIssue"
```

---

### Task 9: Goods Return, Scrap Note, Stock Count — drop `warehouseId`

**Files:**
- Modify: `apps/wms/src/goods-return/schemas/goods-return.schema.ts`
- Modify: `apps/wms/src/goods-return/dto/goods-return.dto.ts`
- Modify: `apps/wms/src/goods-return/goods-return.service.ts`
- Modify: `apps/wms/src/goods-return/goods-return.repository.ts`
- Modify: `apps/wms/src/goods-return/goods-return.module.ts`
- Modify: `apps/wms/src/scrap-note/schemas/scrap-note.schema.ts`
- Modify: `apps/wms/src/scrap-note/dto/scrap-note.dto.ts`
- Modify: `apps/wms/src/scrap-note/scrap-note.service.ts`
- Modify: `apps/wms/src/scrap-note/scrap-note.repository.ts`
- Modify: `apps/wms/src/scrap-note/scrap-note.module.ts`
- Modify: `apps/wms/src/stock-count/schemas/stock-count.schema.ts`
- Modify: `apps/wms/src/stock-count/dto/stock-count.dto.ts`
- Modify: `apps/wms/src/stock-count/stock-count.service.ts`
- Modify: `apps/wms/src/stock-count/stock-count.repository.ts`
- Modify: `apps/wms/src/stock-count/stock-count.module.ts`
- Test: all corresponding `*.spec.ts` files for the 3 modules above

**Interfaces:**
- Consumes: `LocationRepository`/`LocationService` (Task 2), `StockRepository` signatures without `warehouseId` (Task 3).
- Produces: `GoodsReturnRepository.createGoodsReturn`/`setInspected` without `warehouseId`; `ScrapNoteService.createApprovedScrapNoteForReturn(params)` drops `warehouseId` from its params object — **`GoodsReturnService.confirmGoodsReturn` (same task) is the only caller, edited together below**; `StockCountRepository.createStockCount` drops `warehouseId`.

This task touches 3 modules with parallel structure. Do them in this order: **GoodsReturn → ScrapNote → StockCount**, because `GoodsReturnService` calls into `ScrapNoteService.createApprovedScrapNoteForReturn`.

- [ ] **Step 1: Edit `goods-return.schema.ts`**

Remove:
```typescript
  @Prop({ type: Types.ObjectId, default: null })
  warehouseId!: Types.ObjectId | null;

```
and remove:
```typescript
GoodsReturnSchema.index({ warehouseId: 1, status: 1 });
```
replace with:
```typescript
GoodsReturnSchema.index({ status: 1 });
```

- [ ] **Step 2: Edit `goods-return.dto.ts`**

Remove `warehouseId` from `InspectGoodsReturnDto`:
```typescript
  @IsMongoId()
  warehouseId!: string;

```
Remove `warehouseId` from `InspectGoodsReturnFormDto` (same shape).
Remove `warehouseId` from `QueryGoodsReturnDto`:
```typescript
  @IsOptional()
  @IsMongoId()
  warehouseId?: string;

```
Remove `warehouseId` from `GoodsReturnResponseDto`:
```typescript
  @Expose()
  @Transform(({ obj }: { obj: { warehouseId?: Types.ObjectId | null } }) =>
    obj.warehouseId ? obj.warehouseId.toString() : null,
  )
  @ApiPropertyOptional()
  warehouseId!: string | null;

```
(Read the file first to get the exact `@Transform` shape used for the nullable field — match it precisely before deleting.)

- [ ] **Step 3: Edit `goods-return.repository.ts`**

Remove `warehouseId?: Types.ObjectId;` from `QueryGoodsReturnInput`.
In `createGoodsReturn`, remove the line setting `warehouseId: null` on document creation.
In `findAll`, remove `if (query.warehouseId) filter['warehouseId'] = query.warehouseId;`.
Change `setInspected` signature — drop `warehouseId`:
```typescript
  setInspected(
    id: string,
    warehouseId: Types.ObjectId,
    ...
  )
```
to (drop the `warehouseId` param and its assignment `doc.warehouseId = warehouseId;` inside the method body — read the file first to see the remaining params so the edit is precise).

- [ ] **Step 4: Edit `goods-return.service.ts`**

Change `WarehouseService`/`WarehouseRepository` imports to `LocationService`/`LocationRepository` (whichever this file actually imports — confirm from the source read earlier; it uses `warehouse` lookups during `inspectGoodsReturn`).

In `inspectGoodsReturn`, remove the block that resolves `warehouseId = new Types.ObjectId(dto.warehouseId)` and looks up the warehouse; remove the `warehouseId` argument from the `repo.setInspected(id, warehouseId, ...)` call.

In `confirmGoodsReturn`, remove `goodsReturn.warehouseId!` from every call site: `upsertInventory`, `upsertBalance`, the `touchedBalances` map key/value (collapse to a `touchedItemIds: Set<string>` pattern matching Task 6's fix), `insertMovement`, and the call into `scrapNoteService.createApprovedScrapNoteForReturn({...})` (drop `warehouseId` from that params object literal).

- [ ] **Step 5: Edit `goods-return.module.ts`**

Change `WarehouseModule` → `LocationModule`.

- [ ] **Step 6: Edit `scrap-note.schema.ts`**

Remove:
```typescript
  @Prop({ type: Types.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

```
and change:
```typescript
ScrapNoteSchema.index({ warehouseId: 1, status: 1 });
```
to:
```typescript
ScrapNoteSchema.index({ status: 1 });
```

- [ ] **Step 7: Edit `scrap-note.dto.ts`**

Remove `warehouseId` from `CreateScrapNoteDto`, `CreateScrapNoteFormDto`, `QueryScrapNoteDto`, `ScrapNoteResponseDto` (same pattern as Step 2, all required/non-nullable here per the earlier survey).

- [ ] **Step 8: Edit `scrap-note.repository.ts`**

Remove `warehouseId?: Types.ObjectId;` from `QueryScrapNoteInput`.
Change `createScrapNote(warehouseId: Types.ObjectId, ...)` — drop the param and its use in the created document.
Change `createApprovedScrapNote(warehouseId: Types.ObjectId, ...)` — same.
Remove `if (query.warehouseId) filter['warehouseId'] = query.warehouseId;` from `findAll`.

- [ ] **Step 9: Edit `scrap-note.service.ts`**

Change `WarehouseService` import to `LocationService` if present (confirm from source — the survey showed `warehouseService.getWarehouse` style lookup on create). Remove the warehouse-lookup block in `createScrapNote`; drop `warehouseId` from the `stockRepo.findInventory(itemId, warehouseId, ...)` call (now `findInventory(itemId, shelfId, lotId)` per Task 3 — reorder/drop arguments to match); drop `warehouseId` from `repo.createScrapNote(warehouseId, ...)`.

In `approveScrapNote`, remove `scrapNote.warehouseId` from `upsertInventory`, `upsertBalance`, the touched-balances map (collapse to `Set<string>` of itemIds), `insertMovement`.

Change `createApprovedScrapNoteForReturn(params: { warehouseId: Types.ObjectId; ... })` — drop `warehouseId` from the params interface and every internal use (`repo.createApprovedScrapNote`, `stockRepo.upsertInventory`, `stockRepo.upsertBalance`, `stockRepo.insertMovement`).

- [ ] **Step 10: Edit `scrap-note.module.ts`**

Change `WarehouseModule` → `LocationModule`.

- [ ] **Step 11: Edit `stock-count.schema.ts`**

Remove:
```typescript
  @Prop({ type: Types.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

```
and change:
```typescript
StockCountSchema.index({ warehouseId: 1, status: 1 });
```
to:
```typescript
StockCountSchema.index({ status: 1 });
```
(`zoneId` stays on this schema — it's the optional scope filter, unaffected by this migration.)

- [ ] **Step 12: Edit `stock-count.dto.ts`**

Remove `warehouseId` from `CreateStockCountDto`:
```typescript
  @ApiProperty()
  @IsMongoId()
  warehouseId!: string;

```
(leave `zoneId?: string` untouched). Remove `warehouseId` from `QueryStockCountDto` and `StockCountResponseDto` (same pattern; `zoneId` stays on the response DTO too).

- [ ] **Step 13: Edit `stock-count.repository.ts`**

Remove `warehouseId?: Types.ObjectId;` from `QueryStockCountInput`.
Change `createStockCount(warehouseId: Types.ObjectId, zoneId: ..., ...)` — drop the `warehouseId` param and its use in the created document; keep `zoneId`.
Remove `if (query.warehouseId) filter['warehouseId'] = query.warehouseId;` from `findAll`.

- [ ] **Step 14: Edit `stock-count.service.ts`**

Change `WarehouseRepository` import to `LocationRepository`.

In `createStockCount`, remove:
```typescript
    const warehouseId = new Types.ObjectId(dto.warehouseId);
    const warehouse = await this.warehouseRepo.findWarehouseById(
      dto.warehouseId,
    );
    if (!warehouse) throw new AppException('WAREHOUSE_NOT_FOUND');

    let zoneId: Types.ObjectId | null = null;
    let shelfIds: Types.ObjectId[] | undefined;
    if (dto.zoneId) {
      const zone = await this.warehouseRepo.findZoneById(dto.zoneId);
      if (!zone || zone.warehouseId.toString() !== dto.warehouseId) {
        throw new AppException('ZONE_NOT_FOUND');
      }
      zoneId = new Types.ObjectId(dto.zoneId);
      shelfIds = await this.warehouseRepo.findShelfIdsByZone(dto.zoneId);
    }

    const inventory = await this.stockRepo.findInventoryByScope(
      warehouseId,
      shelfIds,
    );
```
with:
```typescript
    let zoneId: Types.ObjectId | null = null;
    let shelfIds: Types.ObjectId[] | undefined;
    if (dto.zoneId) {
      const zone = await this.locationRepo.findZoneById(dto.zoneId);
      if (!zone) {
        throw new AppException('ZONE_NOT_FOUND');
      }
      zoneId = new Types.ObjectId(dto.zoneId);
      shelfIds = await this.locationRepo.findShelfIdsByZone(dto.zoneId);
    }

    const inventory = await this.stockRepo.findInventoryByScope(shelfIds);
```
(The old code validated `zone.warehouseId.toString() !== dto.warehouseId` — with `Zone.warehouseId` gone per Task 2, `findZoneById` returning a doc at all is now sufficient validation that the zone exists; there's no cross-warehouse mismatch to check anymore.)

Later in the same method, remove the `dto.warehouseId` interpolation from the orphaned-item warning log — change `(warehouseId=${dto.warehouseId})` to remove that parenthetical entirely, e.g. `... không khớp WarehouseItem nào → bỏ qua dòng này khi tạo StockCount.`.

Change the `repo.createStockCount(warehouseId, zoneId, ...)` call to drop `warehouseId`:
```typescript
    return this.repo.createStockCount(
      warehouseId,
      zoneId,
      dto.note,
      new Types.ObjectId(actorId),
      lines,
    );
```
to:
```typescript
    return this.repo.createStockCount(
      zoneId,
      dto.note,
      new Types.ObjectId(actorId),
      lines,
    );
```

In `approveStockCount`, remove `stockCount.warehouseId` from `upsertInventory`, `upsertBalance`, the touched-balances map (collapse to `Set<string>`), `insertMovement`.

- [ ] **Step 15: Edit `stock-count.module.ts`**

Change `WarehouseModule` → `LocationModule`.

- [ ] **Step 16: Update all test files for the 3 modules**

For each of `goods-return`, `scrap-note`, `stock-count`: update `*.service.spec.ts`, `*.repository.spec.ts`, `schemas/*.schema.spec.ts` — remove `warehouseId` from every fixture, mock call, and assertion following the same patterns as Tasks 5-8. In `stock-count.service.spec.ts` specifically, update/remove the "zone belongs to different warehouse" test case (no longer applicable) and update the `createStockCount` repo-call assertion to the new 4-arg signature.

- [ ] **Step 17: Run tests for all 3 modules**

Run: `pnpm test -- apps/wms/src/goods-return apps/wms/src/scrap-note apps/wms/src/stock-count`
Expected: PASS.

- [ ] **Step 18: Commit**

```bash
git add apps/wms/src/goods-return apps/wms/src/scrap-note apps/wms/src/stock-count
git commit -m "refactor(goods-return,scrap-note,stock-count): bỏ warehouseId khỏi 3 module"
```

---

### Task 10: Print Job — drop `warehouseId`

**Files:**
- Modify: `apps/wms/src/print-job/schemas/print-job.schema.ts`
- Modify: `apps/wms/src/print-job/dto/print-job.dto.ts`
- Modify: `apps/wms/src/print-job/print-job.service.ts`
- Modify: `apps/wms/src/print-job/print-job.repository.ts`
- Modify: `apps/wms/src/print-job/print-job.module.ts`
- Test: `apps/wms/src/print-job/print-job.service.spec.ts`
- Test: `apps/wms/src/print-job/print-job.repository.spec.ts`
- Test: `apps/wms/src/print-job/print-job.consumer.spec.ts`

**Interfaces:**
- Consumes: `PrintRequestedPayload` without `warehouseId` (Task 1), `StockRepository` signatures without `warehouseId` (Task 3).
- Produces: `PrintJobService.createFromPrintRequested(orderId, items)` (drops `warehouseId`); `PrintJobRepository.createPrintJob(orderId, lines, session)` (drops `warehouseId`).

- [ ] **Step 1: Find the consumer that calls `createFromPrintRequested`**

Run: `grep -rn "createFromPrintRequested" apps/wms/src/print-job/`
Read the consumer file to see how `data.warehouseId` (from `PrintRequestedPayload`) currently flows in — this confirms the exact edit needed there (same pattern as Task 8 Step 6).

- [ ] **Step 2: Edit `print-job.schema.ts`**

Remove:
```typescript
  @Prop({ type: Types.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

```

- [ ] **Step 3: Edit `print-job.dto.ts`**

Remove `warehouseId` from `PrintJobResponseDto` (only DTO with the field, per the earlier survey — no create/query DTO has it).

- [ ] **Step 4: Edit `print-job.repository.ts`**

Change `createPrintJob`:
```typescript
  async createPrintJob(
    orderId: string,
    warehouseId: Types.ObjectId,
    ...
```
to drop `warehouseId` from the signature and the created document (read the file first for the full parameter list and body to make a precise edit).

- [ ] **Step 5: Edit `print-job.service.ts`**

Change `createFromPrintRequested`:
```typescript
  async createFromPrintRequested(
    orderId: string,
    warehouseId: string,
    items: ...,
  ) {
    const whId = new Types.ObjectId(warehouseId);
```
to drop the `warehouseId` param and the `whId` local variable entirely — replace every downstream use of `whId` (in `findBalanceByItemAndWarehouse` → now `findBalance`, `upsertBalance`, the touched-balances map, `repo.createPrintJob(orderId, whId, lines, session)` → `repo.createPrintJob(orderId, lines, session)`) by simply removing the argument.

In `consumeItem`/`completeItem`, remove every `job.warehouseId` reference from shelf validation, `upsertInventory`, `upsertBalance`, `insertMovement`, `checkAndEmitStockLow(itemId, job.warehouseId)` → `checkAndEmitStockLow(itemId)`.

- [ ] **Step 6: Update the consumer found in Step 1**

Drop the `warehouseId`/`data.warehouseId` argument from the `createFromPrintRequested` call, matching the payload shape from Task 1.

- [ ] **Step 7: Edit `print-job.module.ts`**

If it imports `WarehouseModule`, change to `LocationModule` (check first — the earlier survey didn't confirm this file imports it, since print-job's warehouse dependency is via `WarehouseRepository`/`WarehouseService` injected transitively through `StockModule` or directly; verify with `grep -n "Warehouse" apps/wms/src/print-job/print-job.module.ts` before editing).

- [ ] **Step 8: Update tests**

`print-job.service.spec.ts`: drop `warehouseId` from every `createFromPrintRequested` call, `consumeItem`/`completeItem` fixtures, and stock-repo call assertions.
`print-job.repository.spec.ts`: drop `warehouseId` from `createPrintJob` calls and fixtures.
`print-job.consumer.spec.ts`: drop `warehouseId` from the `PrintRequestedPayload` fixture and the `createFromPrintRequested` call assertion.

- [ ] **Step 9: Run print-job tests**

Run: `pnpm test -- apps/wms/src/print-job`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add apps/wms/src/print-job
git commit -m "refactor(print-job): bỏ warehouseId khỏi PrintJob"
```

---

### Task 11: Users — drop default `warehouseId`

**Files:**
- Modify: `apps/wms/src/users/schemas/user.schema.ts`
- Modify: `apps/wms/src/users/dto/update-user.dto.ts`
- Modify: `apps/wms/src/users/dto/query-users.dto.ts`
- Modify: `apps/wms/src/users/dto/user.response.dto.ts`
- Modify: `apps/wms/src/users/repositories/user.repository.ts`
- Test: `apps/wms/src/users/repositories/user.repository.spec.ts`

**Interfaces:**
- Consumes: nothing new.
- Produces: `User` schema, `UpdateUserDto`, `QueryUsersDto`, `UserResponseDto`, `FindAllUsersQuery`, `UpdateUserProfileInput` all without `warehouseId`.

- [ ] **Step 1: Edit `user.schema.ts`**

Remove:
```typescript
  @Prop({ type: SchemaTypes.ObjectId })
  warehouseId?: Types.ObjectId;

```
(read the file first to confirm the exact comment text above this line, e.g. "kho mặc định" — remove that comment line too).

- [ ] **Step 2: Edit `update-user.dto.ts`**

Remove:
```typescript
  @ApiPropertyOptional()
  @IsOptional()
  @IsMongoId()
  warehouseId?: string;

```

- [ ] **Step 3: Edit `query-users.dto.ts`**

Remove:
```typescript
  @ApiPropertyOptional()
  @IsOptional()
  @IsMongoId()
  warehouseId?: string;

```

- [ ] **Step 4: Edit `user.response.dto.ts`**

Remove from `UserResponseDto`:
```typescript
  @Expose()
  @Transform(...)
  @ApiPropertyOptional()
  warehouseId?: string;

```
(read the file first for the exact `@Transform` — it used `?? undefined` per the earlier survey, distinct from other response DTOs).

- [ ] **Step 5: Edit `user.repository.ts`**

Remove `warehouseId?: string;` from `FindAllUsersQuery` and `UpdateUserProfileInput`.
Remove `if (query.warehouseId) filter['warehouseId'] = query.warehouseId;` from `findAll`.
(`updateProfile`'s generic `{ ...data }` spread needs no code change — removing the field from the `UpdateUserProfileInput` interface is sufficient, per the earlier survey.)

- [ ] **Step 6: Update tests**

`user.repository.spec.ts`: remove `warehouseId` from fixtures, `findAll` filter tests, and `updateProfile` tests.

- [ ] **Step 7: Run users tests**

Run: `pnpm test -- apps/wms/src/users`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/wms/src/users
git commit -m "refactor(users): bỏ warehouseId (kho mặc định nhân viên) khỏi User"
```

---

### Task 12: Ecommerce — drop `fulfillWarehouseId`

**Files:**
- Modify: `apps/ecommerce/src/order/schemas/order.schema.ts`
- Modify: `apps/ecommerce/src/order/dto/order.dto.ts`
- Modify: `apps/ecommerce/src/order/reserve.consumer.ts`
- Modify: `apps/ecommerce/src/order/checkout.service.ts`
- Modify: `apps/ecommerce/prisma/schema.prisma`
- Test: any spec files under `apps/ecommerce/src/order/` referencing `fulfillWarehouseId` or `preferWarehouse`

**Interfaces:**
- Consumes: `StockReservedPayload`/`StockReserveRequestedPayload` without warehouse fields (Task 1).
- Produces: `Order` schema/DTO without `fulfillWarehouseId`.

- [ ] **Step 1: Edit `order.schema.ts`**

Remove:
```typescript
  /** WMS kho đã giữ tồn */
  @Prop({ type: String, default: null })
  fulfillWarehouseId: string | null;

```

- [ ] **Step 2: Edit `order.dto.ts`**

Remove from `OrderResponseDto`:
```typescript
  @Expose()
  @ApiProperty({ example: null, nullable: true })
  fulfillWarehouseId!: string | null;

```

- [ ] **Step 3: Edit `reserve.consumer.ts`**

Change `handleReserved`:
```typescript
  private async handleReserved(job: Job) {
    const { orderId, fulfillWarehouseId } = job.data as StockReservedPayload;
    const order = await this.orderRepo.findById(orderId);
    if (!order) return;

    await this.orderRepo.updateOrder(orderId, { fulfillWarehouseId });
    await this.orderService.onStockReserved(orderId);
    this.logger.log(
      `Giữ kho thành công: Đơn hàng ${orderId} -> Kho ${fulfillWarehouseId}`,
    );
  }
```
to:
```typescript
  private async handleReserved(job: Job) {
    const { orderId } = job.data as StockReservedPayload;
    const order = await this.orderRepo.findById(orderId);
    if (!order) return;

    await this.orderService.onStockReserved(orderId);
    this.logger.log(`Giữ kho thành công: Đơn hàng ${orderId}`);
  }
```

- [ ] **Step 4: Edit `checkout.service.ts`**

Change:
```typescript
    // Gửi yêu cầu kiểm kho và giữ tồn kho vật lý sang WMS
    await this.orderQueue.add(EVENTS.STOCK_RESERVE_REQUESTED, {
      orderId: order._id.toString(),
      items: cart.items.map((i) => ({ sku: i.sku, quantity: i.quantity })),
      preferWarehouse: 'CENTRAL',
    });
```
to:
```typescript
    // Gửi yêu cầu kiểm kho và giữ tồn kho vật lý sang WMS
    await this.orderQueue.add(EVENTS.STOCK_RESERVE_REQUESTED, {
      orderId: order._id.toString(),
      items: cart.items.map((i) => ({ sku: i.sku, quantity: i.quantity })),
    });
```

- [ ] **Step 5: Edit `apps/ecommerce/prisma/schema.prisma`**

Remove the `fulfillWarehouseId` line from the `Order` model (this file is a reference spec, not live Prisma — still update it to stay in sync):
```prisma
  fulfillWarehouseId String?           @db.ObjectId // CROSS-APP ref → wms warehouses.id (1 kho/đơn)
```

- [ ] **Step 6: Update tests**

Run: `grep -rln "fulfillWarehouseId\|preferWarehouse" apps/ecommerce/src/`
For each hit, remove the field from fixtures/assertions.

- [ ] **Step 7: Run ecommerce order tests**

Run: `pnpm test -- apps/ecommerce/src/order`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/ecommerce/src/order apps/ecommerce/prisma/schema.prisma
git commit -m "refactor(ecom): bỏ fulfillWarehouseId khỏi Order, không gửi preferWarehouse khi checkout"
```

---

### Task 13: Seed script, full-repo sweep, and dev DB reseed

**Files:**
- Modify: `apps/wms/src/seed/seed.ts`
- Modify: `apps/wms/test/happy-path.e2e-spec.ts`
- Modify: `apps/wms/scripts/backfill-barcode-registry.ts` (only if it references `warehouseId` — verify first)

**Interfaces:**
- Consumes: every schema/service/repository from Tasks 2-11.
- Produces: nothing new — this is the final sweep and verification task.

- [ ] **Step 1: Grep for any remaining `warehouse` reference outside historical docs**

Run: `grep -rilE "warehouse" --include="*.ts" apps libs | grep -v ".spec.ts" | sort`
Read through the output. Every remaining hit should be one of: `apps/wms/src/stock/schemas/warehouse-item.schema.ts` (this is `WarehouseItem`, the warehouse-agnostic SKU master data — **keep**, it's not part of this migration, its name just happens to contain "warehouse"), `apps/wms/src/stock/dto/*warehouse-item*` (same reason — **keep**), or genuine leftovers to fix.

- [ ] **Step 2: Fix `seed.ts`**

Read the current file (304 lines, function `seedWarehouseAndItems`). Remove the `WarehouseService.createWarehouse` call and the `Warehouse` document creation entirely. Rename the function to `seedZoneAndItems` (or similar — match whatever naming convention fits the rest of the file). Update `WarehouseService.createZone`/`createRack` calls to the new `LocationService` no-warehouseId signatures from Task 2. Remove `warehouseId` from the returned object shape and the log line that mentions it. Update every import from `../warehouse/warehouse.service` to `../location/location.service` (and repository if used directly).

Also check whether `seed.ts` calls any of the service methods touched in Tasks 5-11 (PO/GRN/GoodsIssue/etc. creation) with a `warehouseId` argument — grep the file for `warehouseId` after the rename to confirm zero remaining hits.

- [ ] **Step 3: Fix `happy-path.e2e-spec.ts`**

Read the file. Remove `checkWarehouseId` helper/assertions, remove `warehouseId` from any Mongo query filters used to verify seeded state, remove `fulfillWarehouseId` from any hand-built event payload in the test.

- [ ] **Step 4: Check `backfill-barcode-registry.ts`**

Run: `grep -n "warehouseId" apps/wms/scripts/backfill-barcode-registry.ts`
If there are hits, read the file and remove them following the same patterns as prior tasks. If there are no hits, skip.

- [ ] **Step 5: Full lint + typecheck across both apps**

Run: `pnpm lint`
Expected: PASS (0 errors). Fix anything flagged (unused imports like `IsMongoId`/`Types` left over from earlier edits are the most likely culprits — several steps in this plan called out "check before removing" for exactly this reason).

Run: `pnpm build`
Expected: PASS for both `wms` and `ecommerce` (and `notification`, unaffected but part of the monorepo build).

- [ ] **Step 6: Full test suite**

Run: `pnpm test`
Expected: PASS, 0 failures, across every app and lib.

- [ ] **Step 7: Final repo-wide grep verification**

Run: `grep -rilE "warehouseId" --include="*.ts" apps libs | grep -v ".spec.ts"`
Expected: empty output (aside from any `WarehouseItem`-named files, which don't contain the literal string `warehouseId` as a field — verify this assumption holds; if a stray hit remains, fix it before proceeding).

Run: `grep -rilE "fulfillWarehouseId|preferWarehouse" --include="*.ts" apps libs`
Expected: empty output.

- [ ] **Step 8: Wipe and reseed the local dev DB**

Confirm with the user before running any destructive DB command (per the dev-only migration decision in the spec — this drops the `warehouses` collection and any stale `zones`/`shelves` documents carrying the old `warehouseId` field, which would otherwise violate the new unique indexes on `zones.code` and `shelves.isStaging`).

```bash
# Confirm MONGO connection target first — never run against anything but local dev:
echo $WMS_DATABASE_URL
```
Then, with the user's explicit go-ahead, drop the stale collections (via `mongosh` or the project's existing db-reset tooling — check `package.json` for an existing `db:reset`-style script before hand-rolling a `mongosh` command) and run the seed script:
```bash
pnpm start:wms &  # or whatever the repo's documented way to trigger seed.ts is — check README/scripts first
```
(Follow whatever the project's actual seed-invocation mechanism is — inspect `package.json` scripts and `apps/wms/src/seed/seed.ts`'s bottom-of-file bootstrap code before running blind.)

- [ ] **Step 9: Verify seeded state**

Connect to the dev DB and confirm: `zones` collection has documents with no `warehouseId` field; `shelves` collection has exactly one document with `isStaging: true`; `warehouses` collection does not exist (or is empty and unused).

- [ ] **Step 10: Commit**

```bash
git add apps/wms/src/seed apps/wms/test
git commit -m "chore(seed): bỏ tạo Warehouse khỏi seed script, cập nhật e2e test cho single-warehouse"
```

---

## Post-plan verification checklist

After Task 13 completes, confirm every item from the spec's "Tiêu chí hoàn thành" (§5) holds:

- [ ] `grep -ril "warehouseId"` in `apps/`, `libs/` (excluding spec/plan docs) returns empty.
- [ ] No `Warehouse` schema/collection; `WarehouseModule`/`WarehouseService`/`WarehouseRepository`/`WarehouseController` do not exist anywhere in the codebase.
- [ ] `ShelfSchema` has the unique partial index on `{ isStaging: true, deletedAt: null }`.
- [ ] `ReservationService.reserveForOrder` takes no `preferWarehouse` parameter and contains no multi-warehouse loop.
- [ ] `StockReservedPayload`/`OrderReadyToFulfillPayload` have no `fulfillWarehouseId`; `StockReserveRequestedPayload` has no `preferWarehouse`.
- [ ] Ecommerce `Order` has no `fulfillWarehouseId` in schema, DTO, or the Prisma reference file.
- [ ] `pnpm lint`, `pnpm test`, `pnpm build` all pass for `wms` and `ecommerce`.
- [ ] Seed runs successfully and produces exactly one staging shelf with no `warehouseId` anywhere in the created documents.
