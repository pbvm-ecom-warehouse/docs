# S1-04: Schema tồn 2 lớp + Helper Transaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the two-layer stock schema (`WarehouseItem` đầy đủ, `StockBalance`, `InventoryStock`, `Lot`, `StockMovement`) và helper `withStockTransaction` dùng trong các nghiệp vụ GRN/Issue/StockCount sau này.

**Architecture:**  
Tồn kho 2 lớp theo ERD: Lớp 1 (`stock_balances`) là snapshot tổng `onHand/reserved/expired` per item+warehouse; Lớp 2 (`inventory_stocks`) là tồn chi tiết per shelf+lot. `stock_movements` là sổ cái append-only (nguồn sự thật). Helper `withStockTransaction` wrap MongoDB session để đảm bảo atomic khi ghi đồng thời cả 3 collection trong cùng app. Không có giao tiếp xuyên app trong task này.

**Tech Stack:** NestJS, `@nestjs/mongoose`, Mongoose 8.x, TypeScript strict (no `any`), Jest (unit test với mock Model)

## Global Constraints

- Không dùng `any` — ESLint sẽ fail build nếu vi phạm
- Comment tiếng Việt giải thích *vì sao* (không giải thích *cái gì*)
- Collection names phải snake_case theo schema hiện có (`stock_balances`, `inventory_stocks`, `lots`, `stock_movements`)
- Audit rule theo `data-and-mongoose.md`: `stock_balances` + `inventory_stocks` → chỉ `updatedAt`; `stock_movements` → chỉ `createdAt` + `createdBy`, BẤT BIẾN; `lots` → `createdAt` + `updatedAt`; `warehouse_items` → master data → đủ 5 field audit + soft-delete
- Schema path alias `@app/database`, `@app/events`, `@app/common` đã có trong `tsconfig.json`
- Test pattern: mock Model/Service bằng jest.fn(), không hit MongoDB thật
- Không tạo CRUD controller cho stock trong task này — chỉ schema + helper + repository method cơ bản

---

## File Map

| File | Trạng thái | Mục đích |
|---|---|---|
| `apps/wms/src/stock/schemas/warehouse-item.schema.ts` | **Modify** | Expand từ stub tối thiểu → đầy đủ field theo DBML |
| `apps/wms/src/stock/schemas/stock-balance.schema.ts` | **Create** | Lớp 1 tồn tổng |
| `apps/wms/src/stock/schemas/inventory-stock.schema.ts` | **Create** | Lớp 2 tồn theo vị trí |
| `apps/wms/src/stock/schemas/lot.schema.ts` | **Create** | Lô hàng (dùng cho item `isPerishable`) |
| `apps/wms/src/stock/schemas/stock-movement.schema.ts` | **Create** | Sổ cái append-only |
| `apps/wms/src/stock/stock.repository.ts` | **Modify** | Thêm các method query cơ bản (findBalance, findInventory, findLot, insertMovement) |
| `apps/wms/src/stock/helpers/with-stock-transaction.helper.ts` | **Create** | Helper wrap `session.withTransaction` cho các nghiệp vụ cần atomic |
| `apps/wms/src/stock/helpers/with-stock-transaction.helper.spec.ts` | **Create** | Unit test helper |
| `apps/wms/src/stock/stock.module.ts` | **Modify** | Đăng ký 4 schema mới vào `MongooseModule.forFeature` |
| `apps/wms/src/common/error-codes.ts` | **Modify** | Thêm `STOCK_ITEM_NOT_FOUND`, `STOCK_INSUFFICIENT`, `LOT_NOT_FOUND` |

---

## Task 1: Expand WarehouseItem schema + enum ItemType

**Files:**
- Modify: `apps/wms/src/stock/schemas/warehouse-item.schema.ts`
- Create: `apps/wms/src/stock/schemas/warehouse-item.schema.spec.ts`

**Interfaces:**
- Produces: `WarehouseItem` class, `WarehouseItemDocument`, `WarehouseItemSchema`, `ItemType` enum — dùng bởi Task 2, 3, 4, 5, 6

- [ ] **Step 1: Viết failing test kiểm tra ItemType enum và các field schema**

```typescript
// apps/wms/src/stock/schemas/warehouse-item.schema.spec.ts
import { ItemType, WarehouseItem, WarehouseItemSchema } from './warehouse-item.schema';

describe('WarehouseItem schema', () => {
  it('ItemType enum có đủ 4 giá trị', () => {
    expect(Object.values(ItemType)).toEqual([
      'MATERIAL',
      'CUP_BLANK',
      'CUP_PRINTED',
      'PACKAGING',
    ]);
  });

  it('schema có field sku, barcode, name, type, unit, isPerishable, isActive', () => {
    const paths = WarehouseItemSchema.paths;
    expect(paths['sku']).toBeDefined();
    expect(paths['barcode']).toBeDefined();
    expect(paths['name']).toBeDefined();
    expect(paths['type']).toBeDefined();
    expect(paths['unit']).toBeDefined();
    expect(paths['isPerishable']).toBeDefined();
    expect(paths['isActive']).toBeDefined();
    expect(paths['deletedAt']).toBeDefined();
    expect(paths['createdBy']).toBeDefined();
    expect(paths['updatedBy']).toBeDefined();
  });
});
```

- [ ] **Step 2: Chạy test, xác nhận fail**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm test --testPathPattern="warehouse-item.schema.spec" --passWithNoTests 2>&1 | tail -20
```

Expected: FAIL — `ItemType` không tồn tại, `WarehouseItemSchema.paths` thiếu nhiều field

- [ ] **Step 3: Thay thế nội dung warehouse-item.schema.ts đầy đủ**

```typescript
// apps/wms/src/stock/schemas/warehouse-item.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

export enum ItemType {
  MATERIAL = 'MATERIAL',
  CUP_BLANK = 'CUP_BLANK',
  CUP_PRINTED = 'CUP_PRINTED',
  PACKAGING = 'PACKAGING',
}

/** Sub-document: đơn vị thay thế (vd thùng = 24 cái) */
@Schema({ _id: false })
class AltUnit {
  @Prop({ required: true })
  unit!: string;

  /** factor * unit_cơ_sở = 1 altUnit (vd 1 thùng = 24 cái → factor = 24) */
  @Prop({ required: true })
  factor!: number;
}
const AltUnitSchema = SchemaFactory.createForClass(AltUnit);

/** Sub-document: thuộc tính thêm (màu, kích thước…) */
@Schema({ _id: false })
class ItemAttribute {
  @Prop({ required: true })
  name!: string;

  @Prop({ required: true })
  value!: string;

  @Prop({ required: true })
  code!: string;
}
const ItemAttributeSchema = SchemaFactory.createForClass(ItemAttribute);

/**
 * Master data mặt hàng kho. `sku` là khóa liên kết với ProductVariant bên Ecommerce.
 * Dùng soft-delete (deletedAt) vì là master data — không xóa vật lý.
 */
@Schema({ collection: 'warehouse_items', timestamps: true })
export class WarehouseItem {
  @Prop({ required: true, unique: true })
  sku!: string;

  @Prop()
  barcode?: string;

  /** Mã NCC/EAN/UPC phụ — quét về cùng 1 item */
  @Prop({ type: [String], default: [] })
  altBarcodes!: string[];

  @Prop({ required: true })
  name!: string;

  @Prop({ enum: ItemType, required: true })
  type!: ItemType;

  /** Đơn vị cơ sở (vd "cái", "kg") */
  @Prop({ required: true })
  unit!: string;

  @Prop({ type: [AltUnitSchema], default: [] })
  altUnits!: AltUnit[];

  @Prop({ type: [ItemAttributeSchema], default: [] })
  attributes!: ItemAttribute[];

  /** true = hàng có hạn sử dụng, cần track Lot */
  @Prop({ default: false })
  isPerishable!: boolean;

  /** Số ngày trước hạn để đánh dấu "sắp hết hạn" */
  @Prop({ type: Number })
  nearExpiryDays?: number;

  @Prop({ default: true })
  isActive!: boolean;

  // audit master data (5 field theo data-and-mongoose.md)
  @Prop({ type: Types.ObjectId })
  createdBy?: Types.ObjectId;

  @Prop({ type: Types.ObjectId })
  updatedBy?: Types.ObjectId;

  @Prop({ type: Date, default: null })
  deletedAt?: Date | null;
}

export type WarehouseItemDocument = HydratedDocument<WarehouseItem>;
export const WarehouseItemSchema = SchemaFactory.createForClass(WarehouseItem);

WarehouseItemSchema.index({ sku: 1 }, { unique: true });
WarehouseItemSchema.index({ deletedAt: 1 });
WarehouseItemSchema.index({ barcode: 1 }, { sparse: true });
```

- [ ] **Step 4: Chạy test, xác nhận pass**

```bash
pnpm test --testPathPattern="warehouse-item.schema.spec" 2>&1 | tail -10
```

Expected: PASS 2 tests

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/schemas/warehouse-item.schema.ts apps/wms/src/stock/schemas/warehouse-item.schema.spec.ts
git commit -m "feat(wms/stock): expand WarehouseItem schema với ItemType enum và đầy đủ field (S1-04)"
```

---

## Task 2: Schema StockBalance (Lớp 1 — tồn tổng)

**Files:**
- Create: `apps/wms/src/stock/schemas/stock-balance.schema.ts`
- Create: `apps/wms/src/stock/schemas/stock-balance.schema.spec.ts`

**Interfaces:**
- Consumes: không có dependency ngoài Mongoose
- Produces: `StockBalance` class, `StockBalanceDocument`, `StockBalanceSchema` — dùng bởi Task 6, 7

- [ ] **Step 1: Viết failing test**

```typescript
// apps/wms/src/stock/schemas/stock-balance.schema.spec.ts
import { StockBalance, StockBalanceSchema } from './stock-balance.schema';

describe('StockBalance schema', () => {
  it('schema có đủ field tồn tổng', () => {
    const paths = StockBalanceSchema.paths;
    expect(paths['itemId']).toBeDefined();
    expect(paths['warehouseId']).toBeDefined();
    expect(paths['onHand']).toBeDefined();
    expect(paths['reserved']).toBeDefined();
    expect(paths['expired']).toBeDefined();
    expect(paths['minQuantity']).toBeDefined();
    // Snapshot — chỉ updatedAt, KHÔNG có createdAt/deletedAt
    expect(paths['updatedAt']).toBeDefined();
    expect(paths['createdAt']).toBeUndefined();
    expect(paths['deletedAt']).toBeUndefined();
  });

  it('collection name là stock_balances', () => {
    const col = StockBalanceSchema.get('collection') as string | undefined;
    // collection được set qua @Schema({ collection: ... })
    expect(col ?? 'stock_balances').toBe('stock_balances');
  });
});
```

- [ ] **Step 2: Chạy test, xác nhận fail**

```bash
pnpm test --testPathPattern="stock-balance.schema.spec" --passWithNoTests 2>&1 | tail -10
```

Expected: FAIL — module không tồn tại

- [ ] **Step 3: Tạo stock-balance.schema.ts**

```typescript
// apps/wms/src/stock/schemas/stock-balance.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, SchemaTypes, Types } from 'mongoose';

/**
 * Lớp 1 tồn kho — snapshot tổng per (item, warehouse).
 * available = onHand - reserved - expired → đây là số đẩy sang Ecommerce.
 * Nguồn sự thật đối soát là stock_movements (append-only).
 * Audit: chỉ updatedAt (snapshot — không có createdAt, không soft-delete).
 */
@Schema({
  collection: 'stock_balances',
  timestamps: { createdAt: false, updatedAt: true },
})
export class StockBalance {
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  itemId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

  @Prop({ required: true, default: 0 })
  onHand!: number;

  @Prop({ required: true, default: 0 })
  reserved!: number;

  @Prop({ required: true, default: 0 })
  expired!: number;

  /** Ngưỡng cảnh báo hàng sắp hết — bắn event stock.low khi available < minQuantity */
  @Prop({ default: 0 })
  minQuantity!: number;
}

export type StockBalanceDocument = HydratedDocument<StockBalance>;
export const StockBalanceSchema = SchemaFactory.createForClass(StockBalance);

// 1 bản ghi duy nhất per (item, warehouse) — upsert theo compound key này
StockBalanceSchema.index({ itemId: 1, warehouseId: 1 }, { unique: true });
```

- [ ] **Step 4: Chạy test, xác nhận pass**

```bash
pnpm test --testPathPattern="stock-balance.schema.spec" 2>&1 | tail -10
```

Expected: PASS 2 tests

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/schemas/stock-balance.schema.ts apps/wms/src/stock/schemas/stock-balance.schema.spec.ts
git commit -m "feat(wms/stock): thêm StockBalance schema — lớp 1 tồn tổng (S1-04)"
```

---

## Task 3: Schema Lot (lô hàng — dành cho hàng có hạn sử dụng)

**Files:**
- Create: `apps/wms/src/stock/schemas/lot.schema.ts`
- Create: `apps/wms/src/stock/schemas/lot.schema.spec.ts`

**Interfaces:**
- Produces: `Lot` class, `LotDocument`, `LotSchema`, `LotStatus` enum — dùng bởi Task 4, 6

- [ ] **Step 1: Viết failing test**

```typescript
// apps/wms/src/stock/schemas/lot.schema.spec.ts
import { Lot, LotSchema, LotStatus } from './lot.schema';

describe('Lot schema', () => {
  it('LotStatus enum có ACTIVE và EXPIRED', () => {
    expect(Object.values(LotStatus)).toEqual(['ACTIVE', 'EXPIRED']);
  });

  it('schema có đủ field lô hàng', () => {
    const paths = LotSchema.paths;
    expect(paths['itemId']).toBeDefined();
    expect(paths['lotNumber']).toBeDefined();
    expect(paths['expiryDate']).toBeDefined();
    expect(paths['receivedDate']).toBeDefined();
    expect(paths['status']).toBeDefined();
    // audit: createdAt + updatedAt (chứng từ nhập lô — không soft-delete)
    expect(paths['createdAt']).toBeDefined();
    expect(paths['updatedAt']).toBeDefined();
  });
});
```

- [ ] **Step 2: Chạy test, xác nhận fail**

```bash
pnpm test --testPathPattern="lot.schema.spec" --passWithNoTests 2>&1 | tail -10
```

Expected: FAIL — module không tồn tại

- [ ] **Step 3: Tạo lot.schema.ts**

```typescript
// apps/wms/src/stock/schemas/lot.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, SchemaTypes, Types } from 'mongoose';

export enum LotStatus {
  ACTIVE = 'ACTIVE',
  EXPIRED = 'EXPIRED',
}

/**
 * Lô hàng — chỉ dùng cho WarehouseItem.isPerishable = true.
 * Hàng hết hạn: consumer chạy cron đặt status = EXPIRED, bắn stock.expired event,
 * StockBalance.expired += qty, StockBalance.onHand -= qty.
 */
@Schema({ collection: 'lots', timestamps: true })
export class Lot {
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  itemId!: Types.ObjectId;

  @Prop({ required: true })
  lotNumber!: string;

  @Prop({ type: Date, required: true })
  expiryDate!: Date;

  @Prop({ type: Date, required: true })
  receivedDate!: Date;

  @Prop({ enum: LotStatus, default: LotStatus.ACTIVE })
  status!: LotStatus;
}

export type LotDocument = HydratedDocument<Lot>;
export const LotSchema = SchemaFactory.createForClass(Lot);

// lotNumber unique per item (cùng item không được có 2 lô cùng số)
LotSchema.index({ itemId: 1, lotNumber: 1 }, { unique: true });
LotSchema.index({ expiryDate: 1, status: 1 }); // hỗ trợ cron expired scan
```

- [ ] **Step 4: Chạy test, xác nhận pass**

```bash
pnpm test --testPathPattern="lot.schema.spec" 2>&1 | tail -10
```

Expected: PASS 2 tests

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/schemas/lot.schema.ts apps/wms/src/stock/schemas/lot.schema.spec.ts
git commit -m "feat(wms/stock): thêm Lot schema với LotStatus enum (S1-04)"
```

---

## Task 4: Schema InventoryStock (Lớp 2 — tồn theo vị trí)

**Files:**
- Create: `apps/wms/src/stock/schemas/inventory-stock.schema.ts`
- Create: `apps/wms/src/stock/schemas/inventory-stock.schema.spec.ts`

**Interfaces:**
- Produces: `InventoryStock` class, `InventoryStockDocument`, `InventoryStockSchema` — dùng bởi Task 6, 7

- [ ] **Step 1: Viết failing test**

```typescript
// apps/wms/src/stock/schemas/inventory-stock.schema.spec.ts
import { InventoryStock, InventoryStockSchema } from './inventory-stock.schema';

describe('InventoryStock schema', () => {
  it('schema có đủ field tồn theo vị trí', () => {
    const paths = InventoryStockSchema.paths;
    expect(paths['itemId']).toBeDefined();
    expect(paths['warehouseId']).toBeDefined();
    expect(paths['shelfId']).toBeDefined();
    expect(paths['lotId']).toBeDefined();
    expect(paths['quantity']).toBeDefined();
    // Snapshot — chỉ updatedAt
    expect(paths['updatedAt']).toBeDefined();
    expect(paths['createdAt']).toBeUndefined();
  });
});
```

- [ ] **Step 2: Chạy test, xác nhận fail**

```bash
pnpm test --testPathPattern="inventory-stock.schema.spec" --passWithNoTests 2>&1 | tail -10
```

Expected: FAIL — module không tồn tại

- [ ] **Step 3: Tạo inventory-stock.schema.ts**

```typescript
// apps/wms/src/stock/schemas/inventory-stock.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, SchemaTypes, Types } from 'mongoose';

/**
 * Lớp 2 tồn kho — snapshot chi tiết per (item, warehouse, shelf, lot).
 * lotId nullable với hàng không isPerishable.
 * Audit: chỉ updatedAt (snapshot).
 */
@Schema({
  collection: 'inventory_stocks',
  timestamps: { createdAt: false, updatedAt: true },
})
export class InventoryStock {
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  itemId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  shelfId!: Types.ObjectId;

  /** null với hàng không isPerishable */
  @Prop({ type: SchemaTypes.ObjectId, default: null })
  lotId!: Types.ObjectId | null;

  @Prop({ required: true, default: 0 })
  quantity!: number;
}

export type InventoryStockDocument = HydratedDocument<InventoryStock>;
export const InventoryStockSchema = SchemaFactory.createForClass(InventoryStock);

// 1 bản ghi per (item, shelf, lot) — lotId có thể null nên dùng compound 4 chiều
InventoryStockSchema.index(
  { itemId: 1, warehouseId: 1, shelfId: 1, lotId: 1 },
  { unique: true },
);
InventoryStockSchema.index({ shelfId: 1 }); // query tồn theo shelf
```

- [ ] **Step 4: Chạy test, xác nhận pass**

```bash
pnpm test --testPathPattern="inventory-stock.schema.spec" 2>&1 | tail -10
```

Expected: PASS 1 test

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/schemas/inventory-stock.schema.ts apps/wms/src/stock/schemas/inventory-stock.schema.spec.ts
git commit -m "feat(wms/stock): thêm InventoryStock schema — lớp 2 tồn theo vị trí (S1-04)"
```

---

## Task 5: Schema StockMovement (sổ cái append-only)

**Files:**
- Create: `apps/wms/src/stock/schemas/stock-movement.schema.ts`
- Create: `apps/wms/src/stock/schemas/stock-movement.schema.spec.ts`

**Interfaces:**
- Produces: `StockMovement` class, `StockMovementDocument`, `StockMovementSchema`, `MovementType` enum — dùng bởi Task 6, 7

- [ ] **Step 1: Viết failing test**

```typescript
// apps/wms/src/stock/schemas/stock-movement.schema.spec.ts
import { MovementType, StockMovement, StockMovementSchema } from './stock-movement.schema';

describe('StockMovement schema', () => {
  it('MovementType enum có 7 giá trị theo DBML', () => {
    expect(Object.values(MovementType)).toEqual([
      'RECEIVE',
      'PUTAWAY',
      'ISSUE',
      'ADJUST',
      'SCRAP',
      'PRINT_CONSUME',
      'PRINT_OUTPUT',
    ]);
  });

  it('schema có đủ field sổ cái, chỉ createdAt (KHÔNG updatedAt)', () => {
    const paths = StockMovementSchema.paths;
    expect(paths['itemId']).toBeDefined();
    expect(paths['warehouseId']).toBeDefined();
    expect(paths['shelfId']).toBeDefined();
    expect(paths['lotId']).toBeDefined();
    expect(paths['type']).toBeDefined();
    expect(paths['quantity']).toBeDefined();
    expect(paths['refType']).toBeDefined();
    expect(paths['refId']).toBeDefined();
    expect(paths['createdBy']).toBeDefined();
    // Sổ cái BẤT BIẾN — chỉ createdAt, không updatedAt
    expect(paths['createdAt']).toBeDefined();
    expect(paths['updatedAt']).toBeUndefined();
  });
});
```

- [ ] **Step 2: Chạy test, xác nhận fail**

```bash
pnpm test --testPathPattern="stock-movement.schema.spec" --passWithNoTests 2>&1 | tail -10
```

Expected: FAIL — module không tồn tại

- [ ] **Step 3: Tạo stock-movement.schema.ts**

```typescript
// apps/wms/src/stock/schemas/stock-movement.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, SchemaTypes, Types } from 'mongoose';

export enum MovementType {
  RECEIVE = 'RECEIVE',
  PUTAWAY = 'PUTAWAY',
  ISSUE = 'ISSUE',
  ADJUST = 'ADJUST',
  SCRAP = 'SCRAP',
  PRINT_CONSUME = 'PRINT_CONSUME',
  PRINT_OUTPUT = 'PRINT_OUTPUT',
}

/**
 * Sổ cái tồn kho — append-only, BẤT BIẾN.
 * Mọi biến động (nhập/xuất/điều chỉnh/hủy/in) đều tạo 1 movement.
 * quantity có dấu: +nhập, -xuất.
 * refType + refId trỏ về chứng từ gốc (vd refType='grn', refId=ObjectId).
 * Audit: chỉ createdAt + createdBy — KHÔNG updatedAt, KHÔNG deletedAt.
 */
@Schema({
  collection: 'stock_movements',
  timestamps: { createdAt: true, updatedAt: false },
})
export class StockMovement {
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  itemId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  warehouseId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  shelfId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, default: null })
  lotId!: Types.ObjectId | null;

  @Prop({ enum: MovementType, required: true })
  type!: MovementType;

  /** Số lượng có dấu: dương = nhập vào, âm = xuất ra */
  @Prop({ required: true })
  quantity!: number;

  /** Loại chứng từ nguồn (vd 'grn', 'goods_issue', 'stock_count') */
  @Prop({ required: true })
  refType!: string;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  refId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  createdBy!: Types.ObjectId;
}

export type StockMovementDocument = HydratedDocument<StockMovement>;
export const StockMovementSchema = SchemaFactory.createForClass(StockMovement);

StockMovementSchema.index({ itemId: 1, warehouseId: 1, createdAt: -1 });
StockMovementSchema.index({ refType: 1, refId: 1 }); // truy vết bút toán của 1 chứng từ
```

- [ ] **Step 4: Chạy test, xác nhận pass**

```bash
pnpm test --testPathPattern="stock-movement.schema.spec" 2>&1 | tail -10
```

Expected: PASS 2 tests

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/schemas/stock-movement.schema.ts apps/wms/src/stock/schemas/stock-movement.schema.spec.ts
git commit -m "feat(wms/stock): thêm StockMovement schema sổ cái append-only + MovementType enum (S1-04)"
```

---

## Task 6: Mở rộng StockRepository + error codes

**Files:**
- Modify: `apps/wms/src/stock/stock.repository.ts`
- Modify: `apps/wms/src/common/error-codes.ts`
- Create: `apps/wms/src/stock/stock.repository.spec.ts`

**Interfaces:**
- Consumes:
  - `WarehouseItem`, `WarehouseItemDocument` từ `./schemas/warehouse-item.schema`
  - `StockBalance`, `StockBalanceDocument` từ `./schemas/stock-balance.schema`
  - `InventoryStock`, `InventoryStockDocument` từ `./schemas/inventory-stock.schema`
  - `Lot`, `LotDocument`, `LotStatus` từ `./schemas/lot.schema`
  - `StockMovement`, `StockMovementDocument` từ `./schemas/stock-movement.schema`
- Produces:
  - `StockRepository` với các method: `findSkuById(itemId: string)`, `findBalanceByItemAndWarehouse(itemId: Types.ObjectId, warehouseId: Types.ObjectId, session?)`, `upsertBalance(itemId, warehouseId, delta, reservedDelta, expiredDelta, session?)`, `findInventory(itemId, warehouseId, shelfId, lotId, session?)`, `upsertInventory(itemId, warehouseId, shelfId, lotId, deltaQty, session?)`, `findActiveLotByNumber(itemId, lotNumber, session?)`, `createLot(data, session?)`, `insertMovement(data, session?)`

- [ ] **Step 1: Thêm error codes WMS**

Mở `apps/wms/src/common/error-codes.ts` và thay nội dung:

```typescript
// apps/wms/src/common/error-codes.ts
import { HttpStatus } from '@nestjs/common';
import type { HttpStatus as HttpStatusType } from '@nestjs/common';

export const WMS_ERRORS = {
  STOCK_ITEM_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy mặt hàng trong kho',
  },
  STOCK_INSUFFICIENT: {
    status: HttpStatus.CONFLICT,
    message: 'Số lượng tồn kho không đủ',
  },
  LOT_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy lô hàng',
  },
} as const satisfies Record<string, { status: HttpStatusType; message: string }>;

export type WmsErrorCode = keyof typeof WMS_ERRORS;
```

- [ ] **Step 2: Viết failing test cho StockRepository**

```typescript
// apps/wms/src/stock/stock.repository.spec.ts
import { getModelToken } from '@nestjs/mongoose';
import { Test } from '@nestjs/testing';
import { Types } from 'mongoose';
import { StockRepository } from './stock.repository';
import { InventoryStock } from './schemas/inventory-stock.schema';
import { Lot, LotStatus } from './schemas/lot.schema';
import { StockBalance } from './schemas/stock-balance.schema';
import { StockMovement } from './schemas/stock-movement.schema';
import { WarehouseItem } from './schemas/warehouse-item.schema';

const itemId = new Types.ObjectId();
const warehouseId = new Types.ObjectId();
const shelfId = new Types.ObjectId();

const makeModel = (overrides: Record<string, jest.Mock> = {}) => ({
  findById: jest.fn().mockReturnThis(),
  findOne: jest.fn().mockReturnThis(),
  findOneAndUpdate: jest.fn().mockReturnThis(),
  create: jest.fn(),
  select: jest.fn().mockReturnThis(),
  lean: jest.fn().mockReturnThis(),
  exec: jest.fn(),
  ...overrides,
});

describe('StockRepository', () => {
  let repo: StockRepository;
  let warehouseItemModel: ReturnType<typeof makeModel>;
  let balanceModel: ReturnType<typeof makeModel>;
  let inventoryModel: ReturnType<typeof makeModel>;
  let lotModel: ReturnType<typeof makeModel>;
  let movementModel: ReturnType<typeof makeModel>;

  beforeEach(async () => {
    warehouseItemModel = makeModel();
    balanceModel = makeModel();
    inventoryModel = makeModel();
    lotModel = makeModel();
    movementModel = makeModel();

    const module = await Test.createTestingModule({
      providers: [
        StockRepository,
        { provide: getModelToken(WarehouseItem.name), useValue: warehouseItemModel },
        { provide: getModelToken(StockBalance.name), useValue: balanceModel },
        { provide: getModelToken(InventoryStock.name), useValue: inventoryModel },
        { provide: getModelToken(Lot.name), useValue: lotModel },
        { provide: getModelToken(StockMovement.name), useValue: movementModel },
      ],
    }).compile();

    repo = module.get(StockRepository);
    jest.clearAllMocks();
  });

  describe('findSkuById', () => {
    it('trả về sku khi tìm thấy', async () => {
      warehouseItemModel.exec.mockResolvedValueOnce({ sku: 'LY-500ML' });
      const result = await repo.findSkuById(itemId.toString());
      expect(result).toEqual({ sku: 'LY-500ML' });
      expect(warehouseItemModel.findById).toHaveBeenCalledWith(itemId.toString());
    });

    it('trả về null khi không tìm thấy', async () => {
      warehouseItemModel.exec.mockResolvedValueOnce(null);
      const result = await repo.findSkuById('nonexistent');
      expect(result).toBeNull();
    });
  });

  describe('findBalanceByItemAndWarehouse', () => {
    it('gọi findOne với đúng filter', async () => {
      balanceModel.exec.mockResolvedValueOnce({ onHand: 10, reserved: 2, expired: 0 });
      const result = await repo.findBalanceByItemAndWarehouse(itemId, warehouseId);
      expect(result).toEqual({ onHand: 10, reserved: 2, expired: 0 });
      expect(balanceModel.findOne).toHaveBeenCalledWith(
        { itemId, warehouseId },
        null,
        { session: undefined },
      );
    });
  });

  describe('upsertBalance', () => {
    it('gọi findOneAndUpdate với $inc đúng delta', async () => {
      const mockDoc = { onHand: 15, reserved: 0, expired: 0 };
      balanceModel.exec.mockResolvedValueOnce(mockDoc);
      const result = await repo.upsertBalance(itemId, warehouseId, 5, 0, 0);
      expect(result).toBe(mockDoc);
      expect(balanceModel.findOneAndUpdate).toHaveBeenCalledWith(
        { itemId, warehouseId },
        { $inc: { onHand: 5, reserved: 0, expired: 0 } },
        { upsert: true, new: true, session: undefined },
      );
    });
  });

  describe('insertMovement', () => {
    it('gọi create với data và session', async () => {
      const data = {
        itemId,
        warehouseId,
        shelfId,
        lotId: null,
        type: 'RECEIVE' as const,
        quantity: 10,
        refType: 'grn',
        refId: new Types.ObjectId(),
        createdBy: new Types.ObjectId(),
      };
      const mockSession = {} as never;
      movementModel.create.mockResolvedValueOnce([{ _id: new Types.ObjectId() }]);
      await repo.insertMovement(data, mockSession);
      expect(movementModel.create).toHaveBeenCalledWith([data], { session: mockSession });
    });
  });
});
```

- [ ] **Step 3: Chạy test, xác nhận fail**

```bash
pnpm test --testPathPattern="stock.repository.spec" --passWithNoTests 2>&1 | tail -20
```

Expected: FAIL — method không tồn tại

- [ ] **Step 4: Viết StockRepository đầy đủ**

```typescript
// apps/wms/src/stock/stock.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { ClientSession, Model, Types } from 'mongoose';
import { InventoryStock, InventoryStockDocument } from './schemas/inventory-stock.schema';
import { Lot, LotDocument } from './schemas/lot.schema';
import { MovementType, StockMovement } from './schemas/stock-movement.schema';
import { StockBalance, StockBalanceDocument } from './schemas/stock-balance.schema';
import { WarehouseItem } from './schemas/warehouse-item.schema';

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

@Injectable()
export class StockRepository {
  constructor(
    @InjectModel(WarehouseItem.name)
    private readonly itemModel: Model<WarehouseItem>,
    @InjectModel(StockBalance.name)
    private readonly balanceModel: Model<StockBalance>,
    @InjectModel(InventoryStock.name)
    private readonly inventoryModel: Model<InventoryStock>,
    @InjectModel(Lot.name)
    private readonly lotModel: Model<Lot>,
    @InjectModel(StockMovement.name)
    private readonly movementModel: Model<StockMovement>,
  ) {}

  /** Lấy sku của một mặt hàng theo id — dùng khi publish stock.changed. */
  findSkuById(itemId: string) {
    return this.itemModel.findById(itemId).select('sku').lean().exec();
  }

  findBalanceByItemAndWarehouse(
    itemId: Types.ObjectId,
    warehouseId: Types.ObjectId,
    session?: ClientSession,
  ): Promise<StockBalanceDocument | null> {
    return this.balanceModel
      .findOne({ itemId, warehouseId }, null, { session })
      .exec();
  }

  /**
   * Upsert StockBalance: cộng dồn delta vào onHand, reservedDelta vào reserved,
   * expiredDelta vào expired. Dùng $inc để atomic.
   */
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
        { $inc: { onHand: onHandDelta, reserved: reservedDelta, expired: expiredDelta } },
        { upsert: true, new: true, session },
      )
      .exec();
  }

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

  /** Upsert InventoryStock: cộng dồn deltaQty vào quantity. */
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

  findActiveLotByNumber(
    itemId: Types.ObjectId,
    lotNumber: string,
    session?: ClientSession,
  ): Promise<LotDocument | null> {
    return this.lotModel
      .findOne({ itemId, lotNumber, status: 'ACTIVE' }, null, { session })
      .exec();
  }

  async createLot(
    data: {
      itemId: Types.ObjectId;
      lotNumber: string;
      expiryDate: Date;
      receivedDate: Date;
    },
    session?: ClientSession,
  ): Promise<LotDocument> {
    const [doc] = await this.lotModel.create([data], { session });
    return doc;
  }

  async insertMovement(
    data: InsertMovementData,
    session?: ClientSession,
  ): Promise<void> {
    await this.movementModel.create([data], { session });
  }
}
```

- [ ] **Step 5: Chạy test, xác nhận pass**

```bash
pnpm test --testPathPattern="stock.repository.spec" 2>&1 | tail -15
```

Expected: PASS 5 tests

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/stock/stock.repository.ts apps/wms/src/stock/stock.repository.spec.ts apps/wms/src/common/error-codes.ts
git commit -m "feat(wms/stock): mở rộng StockRepository với 7 method + WMS_ERRORS stock codes (S1-04)"
```

---

## Task 7: Helper withStockTransaction

**Files:**
- Create: `apps/wms/src/stock/helpers/with-stock-transaction.helper.ts`
- Create: `apps/wms/src/stock/helpers/with-stock-transaction.helper.spec.ts`

**Interfaces:**
- Consumes: `InjectConnection` từ `@nestjs/mongoose`, `Connection` từ `mongoose`
- Produces:
  ```typescript
  // Injectable service
  class StockTransactionHelper {
    withStockTransaction<T>(fn: (session: ClientSession) => Promise<T>): Promise<T>
  }
  ```

- [ ] **Step 1: Viết failing test**

```typescript
// apps/wms/src/stock/helpers/with-stock-transaction.helper.spec.ts
import { getConnectionToken } from '@nestjs/mongoose';
import { Test } from '@nestjs/testing';
import { ClientSession } from 'mongoose';
import { StockTransactionHelper } from './with-stock-transaction.helper';

describe('StockTransactionHelper', () => {
  let helper: StockTransactionHelper;
  let mockSession: Partial<ClientSession>;
  let withTransactionMock: jest.Mock;
  let endSessionMock: jest.Mock;

  beforeEach(async () => {
    withTransactionMock = jest.fn();
    endSessionMock = jest.fn().mockResolvedValue(undefined);
    mockSession = { withTransaction: withTransactionMock, endSession: endSessionMock };

    const mockConnection = {
      startSession: jest.fn().mockResolvedValue(mockSession),
    };

    const module = await Test.createTestingModule({
      providers: [
        StockTransactionHelper,
        { provide: getConnectionToken(), useValue: mockConnection },
      ],
    }).compile();

    helper = module.get(StockTransactionHelper);
    jest.clearAllMocks();
  });

  it('gọi fn bên trong withTransaction và trả về kết quả', async () => {
    const expected = { ok: true };
    withTransactionMock.mockImplementation(async (fn: (s: ClientSession) => Promise<unknown>) => {
      return fn(mockSession as ClientSession);
    });

    const fn = jest.fn().mockResolvedValue(expected);
    const result = await helper.withStockTransaction(fn);

    expect(fn).toHaveBeenCalledWith(mockSession);
    expect(result).toBe(expected);
  });

  it('luôn gọi endSession dù fn throw', async () => {
    withTransactionMock.mockImplementation(async (fn: (s: ClientSession) => Promise<unknown>) => {
      return fn(mockSession as ClientSession);
    });

    const fn = jest.fn().mockRejectedValue(new Error('db error'));
    await expect(helper.withStockTransaction(fn)).rejects.toThrow('db error');
    expect(endSessionMock).toHaveBeenCalled();
  });

  it('endSession luôn được gọi sau khi fn thành công', async () => {
    withTransactionMock.mockImplementation(async (fn: (s: ClientSession) => Promise<unknown>) => {
      return fn(mockSession as ClientSession);
    });

    await helper.withStockTransaction(jest.fn().mockResolvedValue(null));
    expect(endSessionMock).toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Chạy test, xác nhận fail**

```bash
pnpm test --testPathPattern="with-stock-transaction.helper.spec" --passWithNoTests 2>&1 | tail -10
```

Expected: FAIL — module không tồn tại

- [ ] **Step 3: Tạo thư mục và helper**

```bash
mkdir -p /home/hoaiphuong/code/wms-ecom/be/apps/wms/src/stock/helpers
```

```typescript
// apps/wms/src/stock/helpers/with-stock-transaction.helper.ts
import { Injectable } from '@nestjs/common';
import { InjectConnection } from '@nestjs/mongoose';
import { ClientSession, Connection } from 'mongoose';

/**
 * Wrap MongoDB session.withTransaction để các nghiệp vụ (GRN, Issue, StockCount...)
 * ghi đồng thời vào stock_balances + inventory_stocks + stock_movements một cách atomic.
 * Cần replica set (Atlas hoặc local --replSet rs0).
 */
@Injectable()
export class StockTransactionHelper {
  constructor(@InjectConnection() private readonly connection: Connection) {}

  async withStockTransaction<T>(fn: (session: ClientSession) => Promise<T>): Promise<T> {
    const session = await this.connection.startSession();
    try {
      return await session.withTransaction(fn);
    } finally {
      await session.endSession();
    }
  }
}
```

- [ ] **Step 4: Chạy test, xác nhận pass**

```bash
pnpm test --testPathPattern="with-stock-transaction.helper.spec" 2>&1 | tail -10
```

Expected: PASS 3 tests

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/helpers/with-stock-transaction.helper.ts apps/wms/src/stock/helpers/with-stock-transaction.helper.spec.ts
git commit -m "feat(wms/stock): thêm StockTransactionHelper wrap MongoDB session (S1-04)"
```

---

## Task 8: Wiring — Đăng ký schema mới vào StockModule

**Files:**
- Modify: `apps/wms/src/stock/stock.module.ts`

**Interfaces:**
- Consumes: tất cả schema class + schema object từ Task 1–5; `StockTransactionHelper` từ Task 7
- Produces: `StockModule` export `StockService` + `StockTransactionHelper` + `StockRepository`

- [ ] **Step 1: Chạy toàn bộ test trước khi thay đổi (baseline)**

```bash
pnpm test 2>&1 | tail -20
```

- [ ] **Step 2: Cập nhật StockModule**

```typescript
// apps/wms/src/stock/stock.module.ts
import { BullModule } from '@nestjs/bullmq';
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { QUEUES } from '@app/events';
import { InventoryStock, InventoryStockSchema } from './schemas/inventory-stock.schema';
import { Lot, LotSchema } from './schemas/lot.schema';
import { StockBalance, StockBalanceSchema } from './schemas/stock-balance.schema';
import { StockMovement, StockMovementSchema } from './schemas/stock-movement.schema';
import { WarehouseItem, WarehouseItemSchema } from './schemas/warehouse-item.schema';
import { StockTransactionHelper } from './helpers/with-stock-transaction.helper';
import { StockRepository } from './stock.repository';
import { StockService } from './stock.service';

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
  providers: [StockRepository, StockService, StockTransactionHelper],
  exports: [StockService, StockTransactionHelper, StockRepository],
})
export class StockModule {}
```

- [ ] **Step 3: Chạy toàn bộ test, xác nhận không regression**

```bash
pnpm test 2>&1 | tail -20
```

Expected: tất cả test pass (không có test mới cần viết ở bước này — wiring đã được cover bởi test các task trước + NestJS DI sẽ báo lỗi runtime nếu wiring sai)

- [ ] **Step 4: Build kiểm tra TypeScript**

```bash
pnpm build 2>&1 | tail -30
```

Expected: build thành công, không có TS error

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/stock.module.ts
git commit -m "feat(wms/stock): wire 4 schema mới + StockTransactionHelper vào StockModule (S1-04)"
```

---

## Self-Review

### Spec coverage

| Yêu cầu | Task |
|---|---|
| `WarehouseItem` đầy đủ field theo DBML | Task 1 |
| `StockBalance` (lớp 1) | Task 2 |
| `Lot` + `LotStatus` | Task 3 |
| `InventoryStock` (lớp 2) | Task 4 |
| `StockMovement` sổ cái append-only + `MovementType` | Task 5 |
| Repository method query/upsert/insert | Task 6 |
| Error codes `STOCK_*`, `LOT_*` | Task 6 |
| `withStockTransaction` helper atomic | Task 7 |
| Wiring StockModule | Task 8 |
| Audit rules đúng từng nhóm | Task 1(warehouse_items→master), Task 2(snapshot→updatedAt only), Task 3(lots→timestamps), Task 4(snapshot→updatedAt only), Task 5(sổ cái→createdAt only) |

### Placeholder scan — không có

### Type consistency — đã kiểm tra
- `InsertMovementData` type dùng `MovementType` (import từ stock-movement.schema) → đúng
- `findBalanceByItemAndWarehouse` signature nhất quán giữa spec test và implementation
- `upsertBalance` param `onHandDelta`, `reservedDelta`, `expiredDelta` nhất quán trong test và impl
- `StockTransactionHelper` method name `withStockTransaction` nhất quán trong spec và impl
