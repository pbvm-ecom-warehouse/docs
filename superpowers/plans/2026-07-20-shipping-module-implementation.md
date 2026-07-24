# Module Shipping (P7) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hiện thực module Shipping trong `apps/wms` (be) — carriers + shipments — nối P7 (giao hàng) end-to-end từ `goods.issued` đến `shipment.delivered`/`shipment.returned`, khớp đặc tả đã duyệt ở `docs/shipping/*.md` và spec code hóa `docs/superpowers/specs/2026-07-20-shipping-module-implementation-design.md`.

**Architecture:** NestJS monorepo, module mới `apps/wms/src/shipping/` theo đúng pattern module hiện có (`goods-issue/`, `goods-return/`): repository + service + controller + consumer, Mongoose schema riêng, DTO request/response tách biệt theo `dto-conventions.md`. Nối vào `AppModule` (wms). Bổ sung 1 case event mới ở phía `apps/ecommerce`.

**Tech Stack:** NestJS, Mongoose (`@nestjs/mongoose`), BullMQ (`@nestjs/bullmq`), class-validator/class-transformer, Jest.

## Global Constraints

- KHÔNG đọc chéo `ecom_db` — mọi dữ liệu đơn cần cho Shipment lấy từ snapshot đã lưu trong `GoodsIssue` (do event `order.ready_to_fulfill` mang qua).
- Service KHÔNG được throw `NestJS exception` thô — dùng `AppException('CODE')` từ `@app/common`, code catalog domain đặt ở `apps/wms/src/common/error-codes.ts`.
- Response DTO dùng `@Expose()` + `plainToInstance(..., { excludeExtraneousValues: true })`; `_id` → `id`; enum khai `@ApiProperty({ enum: ... })`; mọi `@Roles(...)` → thêm `— [ROLE1, ROLE2]` vào `summary`.
- Cấm `any` (kể cả implicit) — mọi callback `@Transform` phải type rõ `obj`.
- Schema giữ tên collection snake_case qua `@Schema({ collection: '...' })`; audit đúng nhóm (Master vs Chứng từ) theo `data-and-mongoose.md`.
- 1 `GoodsIssue` ↔ 1 `Shipment` — unique index trên `goodsIssueId`, idempotent khi event `goods.issued` redeliver.
- Producer/consumer BullMQ theo `libs/events/src/events.ts` — không đổi tên event/queue đã khai báo sẵn (`SHIPMENT_SHIPPED/DELIVERED/RETURNED`, `QUEUES.SHIPMENT`).
- Comment tiếng Việt giải thích *vì sao*, không giải thích *làm gì*.

---

### Task 1: Thêm role `SHIPPER` vào `WmsRole`

**Files:**
- Modify: `libs/auth/src/roles.ts`

**Interfaces:**
- Produces: `WmsRole.SHIPPER` — dùng ở mọi task sau (`@Roles(WmsRole.SHIPPER, ...)`).

- [ ] **Step 1: Thêm giá trị enum**

Trong `libs/auth/src/roles.ts`, sửa:

```ts
export enum WmsRole {
  ADMIN = 'ADMIN', // toàn quyền — RolesGuard luôn bypass cho ADMIN
  MANAGER = 'MANAGER',
  RECEIVER = 'RECEIVER', // nhập kho
  PICKER = 'PICKER', // xuất/soạn hàng
  PRINTER = 'PRINTER', // in ly
  COUNTER = 'COUNTER', // kiểm kho
  SHIPPER = 'SHIPPER', // quản lý vận đơn — từ lúc bàn giao hãng đến giao thành công/hoàn về
}
```

- [ ] **Step 2: Build để xác nhận không có nơi nào exhaustive-switch trên `WmsRole` bị vỡ**

Run: `pnpm build`
Expected: build thành công, không lỗi TS liên quan `WmsRole`.

- [ ] **Step 3: Commit**

```bash
git add libs/auth/src/roles.ts
git commit -m "feat(auth): thêm WmsRole.SHIPPER cho module Shipping"
```

---

### Task 2: Mở rộng `GoodsIssue` schema lưu snapshot đơn (recipient/paymentMethod/codAmount/shippingAddress)

**Files:**
- Modify: `apps/wms/src/goods-issue/schemas/goods-issue.schema.ts`
- Modify: `apps/wms/src/goods-issue/goods-issue.repository.ts`
- Modify: `apps/wms/src/goods-issue/goods-issue.service.ts`
- Modify: `apps/wms/src/goods-issue/order-ready.consumer.ts`
- Test modify: `apps/wms/src/goods-issue/goods-issue.service.spec.ts`
- Test modify: `apps/wms/src/goods-issue/order-ready.consumer.spec.ts`

**Interfaces:**
- Consumes: `OrderReadyToFulfillPayload` (`libs/events/src/events.ts:98-106`) — đã có `shippingAddress: Record<string, unknown>`, `recipient: {name,phone}`, `paymentMethod: 'COD'|'ONLINE'`, `codAmount?: number`.
- Produces: `GoodsIssueDocument` giờ có thêm field `shippingAddress`, `recipient`, `paymentMethod`, `codAmount` — Task 4 (`ShippingService`) đọc lại các field này qua `GoodsIssueRepository.findById`.

- [ ] **Step 1: Viết test thất bại cho schema — field mới tồn tại và required**

Thêm vào cuối `apps/wms/src/goods-issue/schemas/goods-issue.schema.spec.ts` (đọc file hiện có trước để giữ đúng style test schema — nếu file dùng `SchemaFactory` trực tiếp, theo mẫu sau):

```ts
it('có field snapshot recipient/paymentMethod/codAmount/shippingAddress', () => {
  const paths = GoodsIssueSchema.paths;
  expect(paths['recipient']).toBeDefined();
  expect(paths['paymentMethod']).toBeDefined();
  expect(paths['codAmount']).toBeDefined();
  expect(paths['shippingAddress']).toBeDefined();
});
```

- [ ] **Step 2: Chạy test, xác nhận fail**

Run: `pnpm test -- goods-issue.schema.spec.ts`
Expected: FAIL — `paths['recipient']` là `undefined`.

- [ ] **Step 3: Sửa schema**

Trong `apps/wms/src/goods-issue/schemas/goods-issue.schema.ts`, thêm vào class `GoodsIssue` (sau `warehouseId`, trước `status`):

```ts
  /** Snapshot địa chỉ giao — từ payload order.ready_to_fulfill, không đổi theo thời gian */
  @Prop({ type: Object, required: true })
  shippingAddress!: Record<string, unknown>;

  /** Snapshot người nhận — dùng để dựng Shipment (module Shipping đọc lại qua goodsIssueId) */
  @Prop({ type: { name: String, phone: String }, required: true })
  recipient!: { name: string; phone: string };

  @Prop({ enum: ['COD', 'ONLINE'], required: true })
  paymentMethod!: 'COD' | 'ONLINE';

  @Prop({ type: Number, default: 0 })
  codAmount!: number;
```

- [ ] **Step 4: Chạy lại test, xác nhận pass**

Run: `pnpm test -- goods-issue.schema.spec.ts`
Expected: PASS

- [ ] **Step 5: Sửa `GoodsIssueRepository.createGoodsIssue` nhận thêm snapshot**

Trong `apps/wms/src/goods-issue/goods-issue.repository.ts`, sửa interface + method:

```ts
export interface CreateGoodsIssueInput {
  orderId: string;
  warehouseId: Types.ObjectId;
  lines: CreateGoodsIssueLineInput[];
  shippingAddress: Record<string, unknown>;
  recipient: { name: string; phone: string };
  paymentMethod: 'COD' | 'ONLINE';
  codAmount: number;
}
```

Sửa chữ ký `createGoodsIssue`:

```ts
  async createGoodsIssue(input: CreateGoodsIssueInput): Promise<GoodsIssueDocument> {
    const [doc] = await this.model.create([
      {
        orderId: input.orderId,
        warehouseId: input.warehouseId,
        status: GoodsIssueStatus.PENDING,
        shippingAddress: input.shippingAddress,
        recipient: input.recipient,
        paymentMethod: input.paymentMethod,
        codAmount: input.codAmount,
        items: input.lines.map((l) => ({
          itemId: l.itemId,
          sku: l.sku,
          quantity: l.quantity,
          remainingQty: l.quantity,
        })),
      },
    ]);
    return doc;
  }
```

> Đổi từ tham số rời sang 1 object input — số lượng tham số đã vượt quá 3, gộp lại cho rõ và tránh nhầm thứ tự.

- [ ] **Step 6: Sửa `GoodsIssueService.createFromOrderReady` nhận + truyền thêm 4 field**

Trong `apps/wms/src/goods-issue/goods-issue.service.ts`, sửa chữ ký method:

```ts
  async createFromOrderReady(
    orderId: string,
    warehouseId: string,
    items: OrderReadyItem[],
    shippingAddress: Record<string, unknown>,
    recipient: { name: string; phone: string },
    paymentMethod: 'COD' | 'ONLINE',
    codAmount: number,
  ): Promise<void> {
    const existing = await this.repo.findByOrderId(orderId);
    if (existing) {
      this.logger.warn(
        `GoodsIssue đã tồn tại cho orderId=${orderId} → bỏ qua (idempotent).`,
      );
      return;
    }

    const lines: { itemId: Types.ObjectId; sku: string; quantity: number }[] =
      [];
    for (const item of items) {
      const warehouseItem = await this.stockRepo.findItemBySku(item.sku);
      if (!warehouseItem) {
        this.logger.warn(
          `Sku=${item.sku} không khớp WarehouseItem nào → bỏ qua dòng này (orderId=${orderId}).`,
        );
        continue;
      }
      lines.push({
        itemId: warehouseItem._id,
        sku: item.sku,
        quantity: item.quantity,
      });
    }

    if (lines.length === 0) {
      this.logger.warn(
        `Không có dòng nào khớp sku cho orderId=${orderId} → không tạo GoodsIssue.`,
      );
      return;
    }

    await this.repo.createGoodsIssue({
      orderId,
      warehouseId: new Types.ObjectId(warehouseId),
      lines,
      shippingAddress,
      recipient,
      paymentMethod,
      codAmount,
    });
  }
```

- [ ] **Step 7: Sửa `OrderReadyConsumer` truyền đủ field**

Trong `apps/wms/src/goods-issue/order-ready.consumer.ts`, sửa lời gọi:

```ts
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

- [ ] **Step 8: Sửa test `goods-issue.service.spec.ts`**

Sửa `makeRepo()` — `createGoodsIssue` vẫn là `jest.fn()` (không đổi chữ ký mock, chỉ đổi assertion). Sửa 2 test case trong `describe('createFromOrderReady')`:

```ts
  const snapshotArgs = () =>
    [
      { street: '123 Le Loi' },
      { name: 'Nguyen Van A', phone: '0900000000' },
      'COD' as const,
      0,
    ] as const;

  describe('createFromOrderReady', () => {
    it('bỏ qua nếu đã có GoodsIssue cho orderId này (idempotent)', async () => {
      repo.findByOrderId.mockResolvedValue({ _id: 'gi1' });
      await svc.createFromOrderReady(
        orderId,
        warehouseId.toString(),
        [{ sku: 'SKU-1', quantity: 5 }],
        ...snapshotArgs(),
      );
      expect(repo.createGoodsIssue).not.toHaveBeenCalled();
    });

    it('bỏ qua dòng sku không khớp WarehouseItem, vẫn tạo phiếu với dòng hợp lệ', async () => {
      repo.findByOrderId.mockResolvedValue(null);
      stockRepo.findItemBySku.mockImplementation((sku: string) =>
        sku === 'SKU-1'
          ? Promise.resolve({ _id: itemId, sku: 'SKU-1' })
          : Promise.resolve(null),
      );
      const [shippingAddress, recipient, paymentMethod, codAmount] =
        snapshotArgs();
      await svc.createFromOrderReady(
        orderId,
        warehouseId.toString(),
        [
          { sku: 'SKU-1', quantity: 5 },
          { sku: 'SKU-UNKNOWN', quantity: 3 },
        ],
        shippingAddress,
        recipient,
        paymentMethod,
        codAmount,
      );
      expect(repo.createGoodsIssue).toHaveBeenCalledWith({
        orderId,
        warehouseId,
        lines: [{ itemId, sku: 'SKU-1', quantity: 5 }],
        shippingAddress,
        recipient,
        paymentMethod,
        codAmount,
      });
    });

    it('không tạo phiếu nếu không có dòng nào khớp sku', async () => {
      repo.findByOrderId.mockResolvedValue(null);
      stockRepo.findItemBySku.mockResolvedValue(null);
      await svc.createFromOrderReady(
        orderId,
        warehouseId.toString(),
        [{ sku: 'SKU-UNKNOWN', quantity: 3 }],
        ...snapshotArgs(),
      );
      expect(repo.createGoodsIssue).not.toHaveBeenCalled();
    });
  });
```

- [ ] **Step 9: Sửa test `order-ready.consumer.spec.ts`**

```ts
  it('gọi createFromOrderReady với đúng dữ liệu khi nhận order.ready_to_fulfill', async () => {
    const job = {
      name: EVENTS.ORDER_READY_TO_FULFILL,
      data: {
        orderId: 'order-1',
        fulfillWarehouseId: 'wh-1',
        items: [{ sku: 'SKU-1', quantity: 5 }],
        shippingAddress: { street: '123 Le Loi' },
        recipient: { name: 'A', phone: '0900000000' },
        paymentMethod: 'COD',
        codAmount: 0,
      },
    } as never;

    await consumer.process(job);

    expect(service.createFromOrderReady).toHaveBeenCalledWith(
      'order-1',
      'wh-1',
      [{ sku: 'SKU-1', quantity: 5 }],
      { street: '123 Le Loi' },
      { name: 'A', phone: '0900000000' },
      'COD',
      0,
    );
  });
```

- [ ] **Step 10: Chạy toàn bộ test goods-issue, xác nhận pass**

Run: `pnpm test -- goods-issue`
Expected: PASS toàn bộ (schema, service, repository, consumer specs).

- [ ] **Step 11: Build**

Run: `pnpm build`
Expected: thành công.

- [ ] **Step 12: Commit**

```bash
git add apps/wms/src/goods-issue
git commit -m "feat(goods-issue): lưu snapshot recipient/paymentMethod/codAmount/shippingAddress cho module Shipping đọc lại"
```

---

### Task 3: Schema `Carrier` + `Shipment`

**Files:**
- Create: `apps/wms/src/shipping/schemas/carrier.schema.ts`
- Create: `apps/wms/src/shipping/schemas/shipment.schema.ts`
- Test: `apps/wms/src/shipping/schemas/carrier.schema.spec.ts`
- Test: `apps/wms/src/shipping/schemas/shipment.schema.spec.ts`

**Interfaces:**
- Produces: `Carrier`, `CarrierDocument`, `CarrierSchema`, `CarrierStatus` enum; `Shipment`, `ShipmentDocument`, `ShipmentSchema`, `ShipmentStatus` enum — dùng ở Task 4/5.

- [ ] **Step 1: Viết test thất bại cho `Carrier` schema**

```ts
// apps/wms/src/shipping/schemas/carrier.schema.spec.ts
import { CarrierSchema, CarrierStatus } from './carrier.schema';

describe('CarrierSchema', () => {
  it('có index unique trên code', () => {
    const indexes = CarrierSchema.indexes();
    const hasUniqueCode = indexes.some(
      ([fields, opts]) => fields['code'] === 1 && opts?.unique === true,
    );
    expect(hasUniqueCode).toBe(true);
  });

  it('status mặc định ACTIVE', () => {
    const path = CarrierSchema.path('status');
    expect(path.defaultValue).toBe(CarrierStatus.ACTIVE);
  });

  it('collection name là carriers', () => {
    expect(CarrierSchema.get('collection')).toBe('carriers');
  });
});
```

- [ ] **Step 2: Chạy test, xác nhận fail**

Run: `pnpm test -- carrier.schema.spec.ts`
Expected: FAIL — module `./carrier.schema` không tồn tại.

- [ ] **Step 3: Viết `carrier.schema.ts`**

```ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

export enum CarrierStatus {
  ACTIVE = 'ACTIVE',
  INACTIVE = 'INACTIVE',
}

/**
 * Danh mục hãng vận chuyển — config tay, MANAGER/ADMIN quản lý (UC-S01).
 * Master data: soft-delete qua deletedAt, audit đầy đủ.
 */
@Schema({ collection: 'carriers', timestamps: true })
export class Carrier {
  @Prop({ required: true })
  name!: string;

  @Prop({ required: true, unique: true })
  code!: string;

  @Prop({ enum: CarrierStatus, default: CarrierStatus.ACTIVE })
  status!: CarrierStatus;

  @Prop({ type: Object })
  contactInfo?: Record<string, unknown>;

  @Prop()
  note?: string;

  /** Chỗ chừa tích hợp API hãng sau (endpoint/token) — YAGNI, không dùng vòng này. */
  @Prop({ type: Object })
  apiConfig?: Record<string, unknown>;

  @Prop({ type: Types.ObjectId })
  createdBy?: Types.ObjectId;

  @Prop({ type: Types.ObjectId })
  updatedBy?: Types.ObjectId;

  @Prop({ type: Date, default: null })
  deletedAt?: Date | null;
}

export type CarrierDocument = HydratedDocument<Carrier>;
export const CarrierSchema = SchemaFactory.createForClass(Carrier);

CarrierSchema.index({ code: 1 }, { unique: true });
CarrierSchema.index({ status: 1 });
```

- [ ] **Step 4: Chạy lại test carrier, xác nhận pass**

Run: `pnpm test -- carrier.schema.spec.ts`
Expected: PASS

- [ ] **Step 5: Viết test thất bại cho `Shipment` schema**

```ts
// apps/wms/src/shipping/schemas/shipment.schema.spec.ts
import { ShipmentSchema, ShipmentStatus } from './shipment.schema';

describe('ShipmentSchema', () => {
  it('có index unique trên goodsIssueId (1 GoodsIssue = 1 Shipment)', () => {
    const indexes = ShipmentSchema.indexes();
    const hasUnique = indexes.some(
      ([fields, opts]) =>
        fields['goodsIssueId'] === 1 && opts?.unique === true,
    );
    expect(hasUnique).toBe(true);
  });

  it('shipmentStatus mặc định PENDING', () => {
    const path = ShipmentSchema.path('shipmentStatus');
    expect(path.defaultValue).toBe(ShipmentStatus.PENDING);
  });

  it('attempts mặc định 0', () => {
    const path = ShipmentSchema.path('attempts');
    expect(path.defaultValue).toBe(0);
  });

  it('collection name là shipments', () => {
    expect(ShipmentSchema.get('collection')).toBe('shipments');
  });
});
```

- [ ] **Step 6: Chạy test, xác nhận fail**

Run: `pnpm test -- shipment.schema.spec.ts`
Expected: FAIL — module `./shipment.schema` không tồn tại.

- [ ] **Step 7: Viết `shipment.schema.ts`**

```ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

export enum ShipmentStatus {
  PENDING = 'PENDING',
  PICKED_UP = 'PICKED_UP',
  IN_TRANSIT = 'IN_TRANSIT',
  DELIVERED = 'DELIVERED',
  FAILED = 'FAILED',
  RETURNING = 'RETURNING',
  RETURNED = 'RETURNED',
}

/** Append-only log — không sửa/xóa dòng cũ, chỉ thêm mỗi lần đổi trạng thái. */
@Schema({ _id: false })
export class ShipmentStatusHistoryEntry {
  @Prop({ enum: ShipmentStatus, required: true })
  status!: ShipmentStatus;

  @Prop({ type: Date, required: true })
  at!: Date;

  @Prop({ type: Types.ObjectId })
  by?: Types.ObjectId;

  @Prop()
  note?: string;
}
const ShipmentStatusHistoryEntrySchema = SchemaFactory.createForClass(
  ShipmentStatusHistoryEntry,
);

/**
 * Vận đơn (UC-S02..S05) — 1:1 với GoodsIssue, auto-sinh khi nhận goods.issued.
 * Chứng từ giao dịch: hủy bằng shipmentStatus, KHÔNG soft-delete.
 */
@Schema({ collection: 'shipments', timestamps: true })
export class Shipment {
  /** id tham chiếu đơn Ecom — KHÔNG đọc chéo ecom_db, chỉ lưu để đối soát & đẩy event */
  @Prop({ required: true })
  orderId!: string;

  @Prop({ type: Types.ObjectId, required: true })
  goodsIssueId!: Types.ObjectId;

  @Prop({ type: Types.ObjectId, required: true })
  fulfillWarehouseId!: Types.ObjectId;

  @Prop({ type: Types.ObjectId })
  carrierId?: Types.ObjectId;

  @Prop()
  trackingNumber?: string;

  @Prop({ enum: ShipmentStatus, default: ShipmentStatus.PENDING })
  shipmentStatus!: ShipmentStatus;

  /** Snapshot từ GoodsIssue lúc auto-sinh — WMS không đọc lại ecom_db sau đó */
  @Prop({
    type: { name: String, phone: String, address: Object },
    required: true,
  })
  recipient!: { name: string; phone: string; address: Record<string, unknown> };

  @Prop({ enum: ['COD', 'ONLINE'], required: true })
  paymentMethod!: 'COD' | 'ONLINE';

  @Prop({ type: Number, default: 0 })
  codAmount!: number;

  @Prop({ type: Number, default: 0 })
  attempts!: number;

  @Prop()
  failReason?: string;

  @Prop({ type: [ShipmentStatusHistoryEntrySchema], default: [] })
  statusHistory!: ShipmentStatusHistoryEntry[];

  @Prop({ type: Date })
  shippedAt?: Date;

  @Prop({ type: Date })
  deliveredAt?: Date;
}

export type ShipmentDocument = HydratedDocument<Shipment>;
export const ShipmentSchema = SchemaFactory.createForClass(Shipment);

// 1 GoodsIssue = 1 Shipment — chặn tạo trùng nếu goods.issued redeliver
ShipmentSchema.index({ goodsIssueId: 1 }, { unique: true });
ShipmentSchema.index({ orderId: 1 });
ShipmentSchema.index({ shipmentStatus: 1 });
ShipmentSchema.index({ carrierId: 1 });
```

- [ ] **Step 8: Chạy lại test shipment, xác nhận pass**

Run: `pnpm test -- shipment.schema.spec.ts`
Expected: PASS

- [ ] **Step 9: Build**

Run: `pnpm build`
Expected: thành công.

- [ ] **Step 10: Commit**

```bash
git add apps/wms/src/shipping/schemas
git commit -m "feat(shipping): schema Carrier + Shipment (carriers/shipments collection)"
```

---

### Task 4: Error codes cho Shipping

**Files:**
- Modify: `apps/wms/src/common/error-codes.ts`

**Interfaces:**
- Produces: `WMS_ERRORS.CARRIER_NOT_FOUND`, `CARRIER_CODE_CONFLICT`, `CARRIER_INACTIVE`, `SHIPMENT_NOT_FOUND`, `SHIPMENT_INVALID_TRANSITION`, `SHIPMENT_NOT_ASSIGNED` — dùng ở Task 5/6.

- [ ] **Step 1: Thêm code vào `WMS_ERRORS`**

Trong `apps/wms/src/common/error-codes.ts`, thêm trước dòng đóng `} as const satisfies ...`:

```ts
  CARRIER_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy đơn vị vận chuyển',
  },
  CARRIER_CODE_CONFLICT: {
    status: HttpStatus.CONFLICT,
    message: 'Mã đơn vị vận chuyển đã tồn tại',
  },
  CARRIER_INACTIVE: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Đơn vị vận chuyển đã ngừng hoạt động',
  },
  SHIPMENT_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy vận đơn',
  },
  SHIPMENT_INVALID_TRANSITION: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Không thể chuyển sang trạng thái này từ trạng thái hiện tại',
  },
  SHIPMENT_NOT_ASSIGNED: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Vận đơn chưa được gán hãng vận chuyển',
  },
```

- [ ] **Step 2: Build để xác nhận `as const satisfies` không vỡ type**

Run: `pnpm build`
Expected: thành công.

- [ ] **Step 3: Commit**

```bash
git add apps/wms/src/common/error-codes.ts
git commit -m "feat(shipping): thêm error codes CARRIER_*/SHIPMENT_*"
```

---

### Task 5: `CarrierRepository` + `CarrierService` + DTO + `CarrierController` (UC-S01)

**Files:**
- Create: `apps/wms/src/shipping/carrier.repository.ts`
- Create: `apps/wms/src/shipping/carrier.service.ts`
- Create: `apps/wms/src/shipping/dto/carrier.dto.ts`
- Create: `apps/wms/src/shipping/carrier.controller.ts`
- Test: `apps/wms/src/shipping/carrier.service.spec.ts`

**Interfaces:**
- Consumes: `Carrier`, `CarrierDocument`, `CarrierStatus` (Task 3); `WMS_ERRORS.CARRIER_*` (Task 4); `WmsRole.SHIPPER` (Task 1).
- Produces: `CarrierRepository` (`findById`, `findByCode`, `create`, `update`, `findAll`), `CarrierService` (`create`, `update`, `list`, `getById`) — dùng ở `ShippingModule` (Task 8) và `ShipmentService` (Task 6, để validate `carrierId` đang `ACTIVE`).

- [ ] **Step 1: Viết `CarrierRepository`**

```ts
// apps/wms/src/shipping/carrier.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import { Carrier, CarrierDocument, CarrierStatus } from './schemas/carrier.schema';

export interface CreateCarrierInput {
  name: string;
  code: string;
  contactInfo?: Record<string, unknown>;
  note?: string;
  createdBy: Types.ObjectId;
}

export interface UpdateCarrierInput {
  name?: string;
  contactInfo?: Record<string, unknown>;
  note?: string;
  status?: CarrierStatus;
  updatedBy: Types.ObjectId;
}

export interface QueryCarrierInput {
  status?: CarrierStatus;
  page?: number;
  limit?: number;
}

@Injectable()
export class CarrierRepository {
  constructor(
    @InjectModel(Carrier.name) private readonly model: Model<Carrier>,
  ) {}

  findById(id: string): Promise<CarrierDocument | null> {
    return this.model.findOne({ _id: id, deletedAt: null }).exec();
  }

  findByCode(code: string): Promise<CarrierDocument | null> {
    return this.model.findOne({ code, deletedAt: null }).exec();
  }

  async create(input: CreateCarrierInput): Promise<CarrierDocument> {
    const [doc] = await this.model.create([
      {
        name: input.name,
        code: input.code,
        contactInfo: input.contactInfo,
        note: input.note,
        createdBy: input.createdBy,
      },
    ]);
    return doc;
  }

  update(id: string, input: UpdateCarrierInput): Promise<CarrierDocument | null> {
    return this.model
      .findOneAndUpdate(
        { _id: id, deletedAt: null },
        { $set: input },
        { new: true },
      )
      .exec();
  }

  async findAll(
    query: QueryCarrierInput,
  ): Promise<{ data: CarrierDocument[]; total: number }> {
    const page = query.page ?? 1;
    const limit = query.limit ?? 20;
    const filter: Record<string, unknown> = { deletedAt: null };
    if (query.status) filter['status'] = query.status;

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
}
```

- [ ] **Step 2: Viết test thất bại cho `CarrierService`**

```ts
// apps/wms/src/shipping/carrier.service.spec.ts
import { Types } from 'mongoose';
import { CarrierService } from './carrier.service';
import { CarrierStatus } from './schemas/carrier.schema';

const makeRepo = () => ({
  findById: jest.fn(),
  findByCode: jest.fn(),
  create: jest.fn(),
  update: jest.fn(),
  findAll: jest.fn(),
});

describe('CarrierService', () => {
  let svc: CarrierService;
  let repo: ReturnType<typeof makeRepo>;
  const actorId = new Types.ObjectId().toString();

  beforeEach(() => {
    repo = makeRepo();
    svc = new CarrierService(repo as never);
  });

  describe('create', () => {
    it('throw CARRIER_CODE_CONFLICT nếu code đã tồn tại', async () => {
      repo.findByCode.mockResolvedValue({ _id: 'c1' });
      await expect(
        svc.create({ name: 'GHN', code: 'GHN' }, actorId),
      ).rejects.toMatchObject({ code: 'CARRIER_CODE_CONFLICT' });
      expect(repo.create).not.toHaveBeenCalled();
    });

    it('tạo carrier mới khi code chưa tồn tại', async () => {
      repo.findByCode.mockResolvedValue(null);
      repo.create.mockResolvedValue({ _id: 'c1', code: 'GHN' });
      const result = await svc.create({ name: 'GHN', code: 'GHN' }, actorId);
      expect(repo.create).toHaveBeenCalledWith({
        name: 'GHN',
        code: 'GHN',
        contactInfo: undefined,
        note: undefined,
        createdBy: new Types.ObjectId(actorId),
      });
      expect(result).toEqual({ _id: 'c1', code: 'GHN' });
    });
  });

  describe('update', () => {
    it('throw CARRIER_NOT_FOUND nếu carrier không tồn tại', async () => {
      repo.findById.mockResolvedValue(null);
      await expect(
        svc.update('c1', { status: CarrierStatus.INACTIVE }, actorId),
      ).rejects.toMatchObject({ code: 'CARRIER_NOT_FOUND' });
    });

    it('cập nhật carrier khi tồn tại', async () => {
      repo.findById.mockResolvedValue({ _id: 'c1' });
      repo.update.mockResolvedValue({ _id: 'c1', status: CarrierStatus.INACTIVE });
      const result = await svc.update(
        'c1',
        { status: CarrierStatus.INACTIVE },
        actorId,
      );
      expect(repo.update).toHaveBeenCalledWith('c1', {
        status: CarrierStatus.INACTIVE,
        updatedBy: new Types.ObjectId(actorId),
      });
      expect(result).toEqual({ _id: 'c1', status: CarrierStatus.INACTIVE });
    });
  });

  describe('getById', () => {
    it('throw CARRIER_NOT_FOUND nếu không tồn tại', async () => {
      repo.findById.mockResolvedValue(null);
      await expect(svc.getById('c1')).rejects.toMatchObject({
        code: 'CARRIER_NOT_FOUND',
      });
    });
  });

  describe('list', () => {
    it('ủy quyền cho repo.findAll', async () => {
      repo.findAll.mockResolvedValue({ data: [], total: 0 });
      const result = await svc.list({});
      expect(repo.findAll).toHaveBeenCalledWith({});
      expect(result).toEqual({ data: [], total: 0 });
    });
  });
});
```

- [ ] **Step 3: Chạy test, xác nhận fail**

Run: `pnpm test -- carrier.service.spec.ts`
Expected: FAIL — module `./carrier.service` không tồn tại.

- [ ] **Step 4: Viết `CarrierService`**

```ts
// apps/wms/src/shipping/carrier.service.ts
import { Injectable } from '@nestjs/common';
import { AppException } from '@app/common';
import { Types } from 'mongoose';
import {
  CarrierRepository,
  CreateCarrierInput,
  QueryCarrierInput,
} from './carrier.repository';
import { CarrierDocument, CarrierStatus } from './schemas/carrier.schema';

export interface CreateCarrierDtoInput {
  name: string;
  code: string;
  contactInfo?: Record<string, unknown>;
  note?: string;
}

export interface UpdateCarrierDtoInput {
  name?: string;
  contactInfo?: Record<string, unknown>;
  note?: string;
  status?: CarrierStatus;
}

@Injectable()
export class CarrierService {
  constructor(private readonly repo: CarrierRepository) {}

  async create(
    input: CreateCarrierDtoInput,
    actorId: string,
  ): Promise<CarrierDocument> {
    const existing = await this.repo.findByCode(input.code);
    if (existing) throw new AppException('CARRIER_CODE_CONFLICT');

    const createInput: CreateCarrierInput = {
      name: input.name,
      code: input.code,
      contactInfo: input.contactInfo,
      note: input.note,
      createdBy: new Types.ObjectId(actorId),
    };
    return this.repo.create(createInput);
  }

  async update(
    id: string,
    input: UpdateCarrierDtoInput,
    actorId: string,
  ): Promise<CarrierDocument> {
    const existing = await this.repo.findById(id);
    if (!existing) throw new AppException('CARRIER_NOT_FOUND');

    const updated = await this.repo.update(id, {
      ...input,
      updatedBy: new Types.ObjectId(actorId),
    });
    if (!updated) throw new AppException('CARRIER_NOT_FOUND');
    return updated;
  }

  async getById(id: string): Promise<CarrierDocument> {
    const doc = await this.repo.findById(id);
    if (!doc) throw new AppException('CARRIER_NOT_FOUND');
    return doc;
  }

  list(
    query: QueryCarrierInput,
  ): Promise<{ data: CarrierDocument[]; total: number }> {
    return this.repo.findAll(query);
  }
}
```

- [ ] **Step 5: Chạy lại test, xác nhận pass**

Run: `pnpm test -- carrier.service.spec.ts`
Expected: PASS

- [ ] **Step 6: Viết DTO**

```ts
// apps/wms/src/shipping/dto/carrier.dto.ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Expose, Transform, Type } from 'class-transformer';
import {
  IsEnum,
  IsInt,
  IsObject,
  IsOptional,
  IsString,
  Max,
  Min,
  MinLength,
} from 'class-validator';
import { Types } from 'mongoose';
import { CarrierStatus } from '../schemas/carrier.schema';

export class CreateCarrierDto {
  @ApiProperty({ example: 'Giao Hàng Nhanh' })
  @IsString()
  @MinLength(1)
  name!: string;

  @ApiProperty({ example: 'GHN' })
  @IsString()
  @MinLength(1)
  code!: string;

  @ApiPropertyOptional({ example: { phone: '1900636677' } })
  @IsOptional()
  @IsObject()
  contactInfo?: Record<string, unknown>;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  note?: string;
}

export class UpdateCarrierDto {
  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @MinLength(1)
  name?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsObject()
  contactInfo?: Record<string, unknown>;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  note?: string;

  @ApiPropertyOptional({ enum: CarrierStatus })
  @IsOptional()
  @IsEnum(CarrierStatus)
  status?: CarrierStatus;
}

export class QueryCarrierDto {
  @ApiPropertyOptional({ enum: CarrierStatus })
  @IsOptional()
  @IsEnum(CarrierStatus)
  status?: CarrierStatus;

  @ApiPropertyOptional({ default: 1, minimum: 1 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  page?: number;

  @ApiPropertyOptional({ default: 20, minimum: 1, maximum: 100 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;
}

export class CarrierResponseDto {
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
  @ApiProperty({ enum: CarrierStatus })
  status!: CarrierStatus;

  @Expose()
  @ApiPropertyOptional()
  contactInfo?: Record<string, unknown>;

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

- [ ] **Step 7: Viết `CarrierController`**

```ts
// apps/wms/src/shipping/carrier.controller.ts
import { Body, Controller, Get, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOkResponse, ApiCreatedResponse, ApiOperation, ApiTags } from '@nestjs/swagger';
import { CurrentUser, JwtAuthGuard, Roles, RolesGuard, WmsRole } from '@app/auth';
import { plainToInstance } from 'class-transformer';
import { CarrierService } from './carrier.service';
import { CreateCarrierDto, UpdateCarrierDto, QueryCarrierDto, CarrierResponseDto } from './dto/carrier.dto';

const TO_OPTS = { excludeExtraneousValues: true } as const;

@ApiTags('carriers')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard, RolesGuard)
@Controller('carriers')
export class CarrierController {
  constructor(private readonly svc: CarrierService) {}

  @Post()
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Tạo đơn vị vận chuyển — [MANAGER, ADMIN]' })
  @ApiCreatedResponse({ type: CarrierResponseDto })
  async create(
    @Body() dto: CreateCarrierDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<CarrierResponseDto> {
    const doc = await this.svc.create(dto, actorId);
    return plainToInstance(CarrierResponseDto, doc.toObject(), TO_OPTS);
  }

  @Patch(':id')
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Cập nhật đơn vị vận chuyển — [MANAGER, ADMIN]' })
  @ApiOkResponse({ type: CarrierResponseDto })
  async update(
    @Param('id') id: string,
    @Body() dto: UpdateCarrierDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<CarrierResponseDto> {
    const doc = await this.svc.update(id, dto, actorId);
    return plainToInstance(CarrierResponseDto, doc.toObject(), TO_OPTS);
  }

  @Get()
  @Roles(WmsRole.SHIPPER, WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Danh sách đơn vị vận chuyển — [SHIPPER, MANAGER, ADMIN]' })
  @ApiOkResponse({ type: [CarrierResponseDto] })
  async list(@Query() query: QueryCarrierDto): Promise<{
    data: CarrierResponseDto[];
    total: number;
    page: number;
    limit: number;
  }> {
    const { data, total } = await this.svc.list(query);
    return {
      data: plainToInstance(CarrierResponseDto, data.map((d) => d.toObject()), TO_OPTS),
      total,
      page: query.page ?? 1,
      limit: query.limit ?? 20,
    };
  }

  @Get(':id')
  @Roles(WmsRole.SHIPPER, WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Chi tiết đơn vị vận chuyển — [SHIPPER, MANAGER, ADMIN]' })
  @ApiOkResponse({ type: CarrierResponseDto })
  async getById(@Param('id') id: string): Promise<CarrierResponseDto> {
    const doc = await this.svc.getById(id);
    return plainToInstance(CarrierResponseDto, doc.toObject(), TO_OPTS);
  }
}
```

- [ ] **Step 8: Build + chạy toàn bộ test shipping**

Run: `pnpm build && pnpm test -- shipping`
Expected: thành công, PASS.

- [ ] **Step 9: Commit**

```bash
git add apps/wms/src/shipping/carrier.repository.ts apps/wms/src/shipping/carrier.service.ts apps/wms/src/shipping/carrier.controller.ts apps/wms/src/shipping/dto/carrier.dto.ts apps/wms/src/shipping/carrier.service.spec.ts
git commit -m "feat(shipping): CarrierRepository/Service/Controller (UC-S01)"
```

---

### Task 6: `ShipmentRepository` + `ShipmentService` (state machine) — UC-S02/S03/S04/S05

**Files:**
- Create: `apps/wms/src/shipping/shipment.repository.ts`
- Create: `apps/wms/src/shipping/shipment.service.ts`
- Test: `apps/wms/src/shipping/shipment.service.spec.ts`

**Interfaces:**
- Consumes: `Shipment`, `ShipmentDocument`, `ShipmentStatus` (Task 3); `CarrierService.getById` + `CarrierStatus` (Task 5); `WMS_ERRORS.SHIPMENT_*`/`CARRIER_INACTIVE` (Task 4); `EVENTS.SHIPMENT_SHIPPED/DELIVERED/RETURNED`, `QUEUES.SHIPMENT`, `ShipmentEventPayload` (`libs/events/src/events.ts`).
- Produces: `ShipmentRepository` (`findById`, `findByGoodsIssueId`, `createFromGoodsIssue`, `assignCarrier`, `pushStatus`, `findAll`), `ShipmentService` (`createFromGoodsIssue`, `assignCarrier`, `updateStatus`, `getById`, `list`) — dùng ở `GoodsIssuedConsumer` (Task 7), `ShipmentController` (Task 8).

- [ ] **Step 1: Viết `ShipmentRepository`**

```ts
// apps/wms/src/shipping/shipment.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import { Shipment, ShipmentDocument, ShipmentStatus } from './schemas/shipment.schema';

export interface CreateShipmentFromGoodsIssueInput {
  orderId: string;
  goodsIssueId: Types.ObjectId;
  fulfillWarehouseId: Types.ObjectId;
  recipient: { name: string; phone: string; address: Record<string, unknown> };
  paymentMethod: 'COD' | 'ONLINE';
  codAmount: number;
}

export interface QueryShipmentInput {
  shipmentStatus?: ShipmentStatus;
  orderId?: string;
  carrierId?: string;
  page?: number;
  limit?: number;
}

@Injectable()
export class ShipmentRepository {
  constructor(
    @InjectModel(Shipment.name) private readonly model: Model<Shipment>,
  ) {}

  findById(id: string): Promise<ShipmentDocument | null> {
    return this.model.findOne({ _id: id }).exec();
  }

  findByGoodsIssueId(goodsIssueId: string): Promise<ShipmentDocument | null> {
    return this.model.findOne({ goodsIssueId }).exec();
  }

  async createFromGoodsIssue(
    input: CreateShipmentFromGoodsIssueInput,
  ): Promise<ShipmentDocument> {
    const [doc] = await this.model.create([
      {
        orderId: input.orderId,
        goodsIssueId: input.goodsIssueId,
        fulfillWarehouseId: input.fulfillWarehouseId,
        shipmentStatus: ShipmentStatus.PENDING,
        recipient: input.recipient,
        paymentMethod: input.paymentMethod,
        codAmount: input.codAmount,
      },
    ]);
    return doc;
  }

  assignCarrier(
    id: string,
    carrierId: Types.ObjectId,
    trackingNumber: string,
  ): Promise<ShipmentDocument | null> {
    return this.model
      .findOneAndUpdate(
        { _id: id, shipmentStatus: ShipmentStatus.PENDING },
        { $set: { carrierId, trackingNumber } },
        { new: true },
      )
      .exec();
  }

  /** Ghi status mới + append statusHistory + set field thời điểm tương ứng nếu có. */
  pushStatus(
    id: string,
    update: {
      shipmentStatus: ShipmentStatus;
      historyEntry: { status: ShipmentStatus; at: Date; by?: Types.ObjectId; note?: string };
      extra?: Record<string, unknown>;
    },
  ): Promise<ShipmentDocument | null> {
    return this.model
      .findOneAndUpdate(
        { _id: id },
        {
          $set: { shipmentStatus: update.shipmentStatus, ...update.extra },
          $push: { statusHistory: update.historyEntry },
        },
        { new: true },
      )
      .exec();
  }

  async findAll(
    query: QueryShipmentInput,
  ): Promise<{ data: ShipmentDocument[]; total: number }> {
    const page = query.page ?? 1;
    const limit = query.limit ?? 20;
    const filter: Record<string, unknown> = {};
    if (query.shipmentStatus) filter['shipmentStatus'] = query.shipmentStatus;
    if (query.orderId) filter['orderId'] = query.orderId;
    if (query.carrierId) filter['carrierId'] = query.carrierId;

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
}
```

- [ ] **Step 2: Viết test thất bại cho `ShipmentService` — bao phủ toàn bộ state machine**

```ts
// apps/wms/src/shipping/shipment.service.spec.ts
import { Types } from 'mongoose';
import { ShipmentService } from './shipment.service';
import { ShipmentStatus } from './schemas/shipment.schema';
import { CarrierStatus } from './schemas/carrier.schema';
import { EVENTS } from '@app/events';

const makeRepo = () => ({
  findById: jest.fn(),
  findByGoodsIssueId: jest.fn(),
  createFromGoodsIssue: jest.fn(),
  assignCarrier: jest.fn(),
  pushStatus: jest.fn(),
  findAll: jest.fn(),
});

const makeCarrierService = () => ({
  getById: jest.fn(),
});

const makeQueue = () => ({ add: jest.fn() });

describe('ShipmentService', () => {
  let svc: ShipmentService;
  let repo: ReturnType<typeof makeRepo>;
  let carrierService: ReturnType<typeof makeCarrierService>;
  let queue: ReturnType<typeof makeQueue>;
  const actorId = new Types.ObjectId().toString();
  const shipmentId = 'ship1';
  const carrierId = new Types.ObjectId().toString();
  const orderId = 'order-1';

  beforeEach(() => {
    repo = makeRepo();
    carrierService = makeCarrierService();
    queue = makeQueue();
    svc = new ShipmentService(repo as never, carrierService as never, queue as never);
  });

  describe('createFromGoodsIssue', () => {
    it('bỏ qua nếu đã có Shipment cho goodsIssueId này (idempotent)', async () => {
      repo.findByGoodsIssueId.mockResolvedValue({ _id: shipmentId });
      await svc.createFromGoodsIssue({
        orderId,
        goodsIssueId: 'gi1',
        fulfillWarehouseId: 'wh1',
        recipient: { name: 'A', phone: '090', address: {} },
        paymentMethod: 'COD',
        codAmount: 0,
      });
      expect(repo.createFromGoodsIssue).not.toHaveBeenCalled();
    });

    it('tạo Shipment PENDING khi chưa tồn tại', async () => {
      repo.findByGoodsIssueId.mockResolvedValue(null);
      repo.createFromGoodsIssue.mockResolvedValue({ _id: shipmentId });
      await svc.createFromGoodsIssue({
        orderId,
        goodsIssueId: 'gi1',
        fulfillWarehouseId: 'wh1',
        recipient: { name: 'A', phone: '090', address: {} },
        paymentMethod: 'COD',
        codAmount: 0,
      });
      expect(repo.createFromGoodsIssue).toHaveBeenCalledWith({
        orderId,
        goodsIssueId: new Types.ObjectId('gi1'.padEnd(24, '0')),
        fulfillWarehouseId: new Types.ObjectId('wh1'.padEnd(24, '0')),
        recipient: { name: 'A', phone: '090', address: {} },
        paymentMethod: 'COD',
        codAmount: 0,
      });
    });
  });

  describe('assignCarrier', () => {
    it('throw SHIPMENT_NOT_FOUND nếu shipment không tồn tại', async () => {
      repo.findById.mockResolvedValue(null);
      await expect(
        svc.assignCarrier(shipmentId, carrierId, 'TRACK-1'),
      ).rejects.toMatchObject({ code: 'SHIPMENT_NOT_FOUND' });
    });

    it('throw CARRIER_INACTIVE nếu carrier không ACTIVE', async () => {
      repo.findById.mockResolvedValue({ _id: shipmentId, shipmentStatus: ShipmentStatus.PENDING });
      carrierService.getById.mockResolvedValue({ status: CarrierStatus.INACTIVE });
      await expect(
        svc.assignCarrier(shipmentId, carrierId, 'TRACK-1'),
      ).rejects.toMatchObject({ code: 'CARRIER_INACTIVE' });
    });

    it('gán carrier + trackingNumber khi hợp lệ', async () => {
      repo.findById.mockResolvedValue({ _id: shipmentId, shipmentStatus: ShipmentStatus.PENDING });
      carrierService.getById.mockResolvedValue({ status: CarrierStatus.ACTIVE });
      repo.assignCarrier.mockResolvedValue({ _id: shipmentId, carrierId });
      const result = await svc.assignCarrier(shipmentId, carrierId, 'TRACK-1');
      expect(repo.assignCarrier).toHaveBeenCalledWith(
        shipmentId,
        new Types.ObjectId(carrierId),
        'TRACK-1',
      );
      expect(result).toEqual({ _id: shipmentId, carrierId });
    });
  });

  describe('updateStatus — state machine', () => {
    const baseShipment = (status: ShipmentStatus) => ({
      _id: shipmentId,
      orderId,
      shipmentStatus: status,
      attempts: 0,
      paymentMethod: 'COD',
    });

    it('throw SHIPMENT_INVALID_TRANSITION cho bước nhảy không hợp lệ (PENDING → DELIVERED)', async () => {
      repo.findById.mockResolvedValue(baseShipment(ShipmentStatus.PENDING));
      await expect(
        svc.updateStatus(shipmentId, ShipmentStatus.DELIVERED, actorId, {}),
      ).rejects.toMatchObject({ code: 'SHIPMENT_INVALID_TRANSITION' });
      expect(repo.pushStatus).not.toHaveBeenCalled();
    });

    it('PENDING → PICKED_UP: ghi statusHistory, không phát event', async () => {
      repo.findById.mockResolvedValue(baseShipment(ShipmentStatus.PENDING));
      repo.pushStatus.mockResolvedValue({ _id: shipmentId, shipmentStatus: ShipmentStatus.PICKED_UP });
      await svc.updateStatus(shipmentId, ShipmentStatus.PICKED_UP, actorId, {});
      expect(repo.pushStatus).toHaveBeenCalledWith(
        shipmentId,
        expect.objectContaining({ shipmentStatus: ShipmentStatus.PICKED_UP }),
      );
      expect(queue.add).not.toHaveBeenCalled();
    });

    it('PICKED_UP → IN_TRANSIT: ghi shippedAt, phát shipment.shipped', async () => {
      repo.findById.mockResolvedValue(baseShipment(ShipmentStatus.PICKED_UP));
      repo.pushStatus.mockResolvedValue({ _id: shipmentId, shipmentStatus: ShipmentStatus.IN_TRANSIT });
      await svc.updateStatus(shipmentId, ShipmentStatus.IN_TRANSIT, actorId, {});
      expect(repo.pushStatus).toHaveBeenCalledWith(
        shipmentId,
        expect.objectContaining({
          shipmentStatus: ShipmentStatus.IN_TRANSIT,
          extra: expect.objectContaining({ shippedAt: expect.any(Date) }),
        }),
      );
      expect(queue.add).toHaveBeenCalledWith(
        EVENTS.SHIPMENT_SHIPPED,
        { orderId, shipmentId },
        expect.anything(),
      );
    });

    it('FAILED → IN_TRANSIT (retry): KHÔNG phát lại shipment.shipped', async () => {
      repo.findById.mockResolvedValue(baseShipment(ShipmentStatus.FAILED));
      repo.pushStatus.mockResolvedValue({ _id: shipmentId, shipmentStatus: ShipmentStatus.IN_TRANSIT });
      await svc.updateStatus(shipmentId, ShipmentStatus.IN_TRANSIT, actorId, {});
      expect(queue.add).not.toHaveBeenCalled();
    });

    it('IN_TRANSIT → DELIVERED: ghi deliveredAt, phát shipment.delivered', async () => {
      repo.findById.mockResolvedValue(baseShipment(ShipmentStatus.IN_TRANSIT));
      repo.pushStatus.mockResolvedValue({ _id: shipmentId, shipmentStatus: ShipmentStatus.DELIVERED });
      await svc.updateStatus(shipmentId, ShipmentStatus.DELIVERED, actorId, {});
      expect(repo.pushStatus).toHaveBeenCalledWith(
        shipmentId,
        expect.objectContaining({
          shipmentStatus: ShipmentStatus.DELIVERED,
          extra: expect.objectContaining({ deliveredAt: expect.any(Date) }),
        }),
      );
      expect(queue.add).toHaveBeenCalledWith(
        EVENTS.SHIPMENT_DELIVERED,
        { orderId, shipmentId },
        expect.anything(),
      );
    });

    it('IN_TRANSIT → FAILED: attempts += 1, ghi failReason, không phát event', async () => {
      repo.findById.mockResolvedValue(baseShipment(ShipmentStatus.IN_TRANSIT));
      repo.pushStatus.mockResolvedValue({ _id: shipmentId, shipmentStatus: ShipmentStatus.FAILED, attempts: 1 });
      await svc.updateStatus(shipmentId, ShipmentStatus.FAILED, actorId, { failReason: 'Khách vắng nhà' });
      expect(repo.pushStatus).toHaveBeenCalledWith(
        shipmentId,
        expect.objectContaining({
          shipmentStatus: ShipmentStatus.FAILED,
          extra: expect.objectContaining({ attempts: 1, failReason: 'Khách vắng nhà' }),
        }),
      );
      expect(queue.add).not.toHaveBeenCalled();
    });

    it('FAILED → RETURNING: ghi statusHistory, chưa phát event (hàng chưa về kho)', async () => {
      repo.findById.mockResolvedValue(baseShipment(ShipmentStatus.FAILED));
      repo.pushStatus.mockResolvedValue({ _id: shipmentId, shipmentStatus: ShipmentStatus.RETURNING });
      await svc.updateStatus(shipmentId, ShipmentStatus.RETURNING, actorId, {});
      expect(queue.add).not.toHaveBeenCalled();
    });

    it('RETURNING → RETURNED: phát shipment.returned', async () => {
      repo.findById.mockResolvedValue(baseShipment(ShipmentStatus.RETURNING));
      repo.pushStatus.mockResolvedValue({ _id: shipmentId, shipmentStatus: ShipmentStatus.RETURNED });
      await svc.updateStatus(shipmentId, ShipmentStatus.RETURNED, actorId, {});
      expect(queue.add).toHaveBeenCalledWith(
        EVENTS.SHIPMENT_RETURNED,
        { orderId, shipmentId },
        expect.anything(),
      );
    });

    it('throw SHIPMENT_INVALID_TRANSITION từ trạng thái terminal (DELIVERED → bất kỳ)', async () => {
      repo.findById.mockResolvedValue(baseShipment(ShipmentStatus.DELIVERED));
      await expect(
        svc.updateStatus(shipmentId, ShipmentStatus.RETURNING, actorId, {}),
      ).rejects.toMatchObject({ code: 'SHIPMENT_INVALID_TRANSITION' });
    });
  });

  describe('getById', () => {
    it('throw SHIPMENT_NOT_FOUND khi không tồn tại', async () => {
      repo.findById.mockResolvedValue(null);
      await expect(svc.getById(shipmentId)).rejects.toMatchObject({
        code: 'SHIPMENT_NOT_FOUND',
      });
    });
  });

  describe('list', () => {
    it('ủy quyền cho repo.findAll', async () => {
      repo.findAll.mockResolvedValue({ data: [], total: 0 });
      const result = await svc.list({});
      expect(repo.findAll).toHaveBeenCalledWith({});
      expect(result).toEqual({ data: [], total: 0 });
    });
  });
});
```

> Lưu ý test `createFromGoodsIssue`: dùng `'gi1'.padEnd(24, '0')` không hợp lệ vì `Types.ObjectId` cần chuỗi hex — sửa lại dùng `new Types.ObjectId().toString()` làm input thực tế thay vì literal `'gi1'`/`'wh1'`. Khai báo 2 biến `goodsIssueIdStr` và `warehouseIdStr` ở đầu `describe('createFromGoodsIssue')` bằng `new Types.ObjectId().toString()`, dùng chúng trong cả input lẫn assertion (thay `'gi1'` và `'wh1'` ở step này bằng 2 biến đó).

- [ ] **Step 3: Chạy test, xác nhận fail**

Run: `pnpm test -- shipment.service.spec.ts`
Expected: FAIL — module `./shipment.service` không tồn tại.

- [ ] **Step 4: Viết `ShipmentService`**

```ts
// apps/wms/src/shipping/shipment.service.ts
import { Injectable } from '@nestjs/common';
import { InjectQueue } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { AppException } from '@app/common';
import { EVENTS, QUEUES, type ShipmentEventPayload } from '@app/events';
import { Types } from 'mongoose';
import {
  ShipmentRepository,
  QueryShipmentInput,
  CreateShipmentFromGoodsIssueInput,
} from './shipment.repository';
import { ShipmentDocument, ShipmentStatus } from './schemas/shipment.schema';
import { CarrierService } from './carrier.service';
import { CarrierStatus } from './schemas/carrier.schema';

/** Bảng transition hợp lệ — key: from, value: các to được phép. */
const VALID_TRANSITIONS: Record<ShipmentStatus, ShipmentStatus[]> = {
  [ShipmentStatus.PENDING]: [ShipmentStatus.PICKED_UP],
  [ShipmentStatus.PICKED_UP]: [ShipmentStatus.IN_TRANSIT],
  [ShipmentStatus.IN_TRANSIT]: [ShipmentStatus.DELIVERED, ShipmentStatus.FAILED],
  [ShipmentStatus.FAILED]: [ShipmentStatus.IN_TRANSIT, ShipmentStatus.RETURNING],
  [ShipmentStatus.RETURNING]: [ShipmentStatus.RETURNED],
  [ShipmentStatus.DELIVERED]: [],
  [ShipmentStatus.RETURNED]: [],
};

export interface UpdateStatusOptions {
  note?: string;
  failReason?: string;
}

@Injectable()
export class ShipmentService {
  constructor(
    private readonly repo: ShipmentRepository,
    private readonly carrierService: CarrierService,
    @InjectQueue(QUEUES.SHIPMENT) private readonly shipmentQueue: Queue,
  ) {}

  async createFromGoodsIssue(
    input: {
      orderId: string;
      goodsIssueId: string;
      fulfillWarehouseId: string;
      recipient: { name: string; phone: string; address: Record<string, unknown> };
      paymentMethod: 'COD' | 'ONLINE';
      codAmount: number;
    },
  ): Promise<void> {
    const existing = await this.repo.findByGoodsIssueId(input.goodsIssueId);
    if (existing) return;

    const createInput: CreateShipmentFromGoodsIssueInput = {
      orderId: input.orderId,
      goodsIssueId: new Types.ObjectId(input.goodsIssueId),
      fulfillWarehouseId: new Types.ObjectId(input.fulfillWarehouseId),
      recipient: input.recipient,
      paymentMethod: input.paymentMethod,
      codAmount: input.codAmount,
    };
    await this.repo.createFromGoodsIssue(createInput);
  }

  async assignCarrier(
    id: string,
    carrierId: string,
    trackingNumber: string,
  ): Promise<ShipmentDocument> {
    const shipment = await this.repo.findById(id);
    if (!shipment) throw new AppException('SHIPMENT_NOT_FOUND');

    const carrier = await this.carrierService.getById(carrierId);
    if (carrier.status !== CarrierStatus.ACTIVE) {
      throw new AppException('CARRIER_INACTIVE');
    }

    const updated = await this.repo.assignCarrier(
      id,
      new Types.ObjectId(carrierId),
      trackingNumber,
    );
    if (!updated) throw new AppException('SHIPMENT_NOT_FOUND');
    return updated;
  }

  async updateStatus(
    id: string,
    toStatus: ShipmentStatus,
    actorId: string,
    options: UpdateStatusOptions,
  ): Promise<ShipmentDocument> {
    const shipment = await this.repo.findById(id);
    if (!shipment) throw new AppException('SHIPMENT_NOT_FOUND');

    const fromStatus = shipment.shipmentStatus;
    const allowed = VALID_TRANSITIONS[fromStatus] ?? [];
    if (!allowed.includes(toStatus)) {
      throw new AppException('SHIPMENT_INVALID_TRANSITION');
    }

    const now = new Date();
    const extra: Record<string, unknown> = {};
    if (toStatus === ShipmentStatus.IN_TRANSIT && fromStatus === ShipmentStatus.PICKED_UP) {
      extra['shippedAt'] = now;
    }
    if (toStatus === ShipmentStatus.DELIVERED) {
      extra['deliveredAt'] = now;
    }
    if (toStatus === ShipmentStatus.FAILED) {
      extra['attempts'] = shipment.attempts + 1;
      if (options.failReason) extra['failReason'] = options.failReason;
    }

    const updated = await this.repo.pushStatus(id, {
      shipmentStatus: toStatus,
      historyEntry: {
        status: toStatus,
        at: now,
        by: new Types.ObjectId(actorId),
        note: options.note,
      },
      extra,
    });
    if (!updated) throw new AppException('SHIPMENT_NOT_FOUND');

    // Chỉ 3 mốc phát event sang Ecom — theo docs/shipping/data-model.md
    // §Quan hệ với Order. Retry FAILED→IN_TRANSIT KHÔNG bắn lại shipment.shipped
    // (Order đã SHIPPED rồi, bắn lại là dư thừa).
    const payload: ShipmentEventPayload = {
      orderId: shipment.orderId,
      shipmentId: id,
      trackingNumber: shipment.trackingNumber,
    };
    if (toStatus === ShipmentStatus.IN_TRANSIT && fromStatus === ShipmentStatus.PICKED_UP) {
      await this.shipmentQueue.add(EVENTS.SHIPMENT_SHIPPED, payload);
    } else if (toStatus === ShipmentStatus.DELIVERED) {
      await this.shipmentQueue.add(EVENTS.SHIPMENT_DELIVERED, payload);
    } else if (toStatus === ShipmentStatus.RETURNED) {
      await this.shipmentQueue.add(EVENTS.SHIPMENT_RETURNED, payload);
    }

    return updated;
  }

  async getById(id: string): Promise<ShipmentDocument> {
    const doc = await this.repo.findById(id);
    if (!doc) throw new AppException('SHIPMENT_NOT_FOUND');
    return doc;
  }

  list(
    query: QueryShipmentInput,
  ): Promise<{ data: ShipmentDocument[]; total: number }> {
    return this.repo.findAll(query);
  }
}
```

- [ ] **Step 5: Sửa lại phần test bị đánh dấu ở Step 2 (dùng ObjectId thật thay vì literal ngắn)**

Trong `describe('createFromGoodsIssue')`, khai báo đầu block:

```ts
  describe('createFromGoodsIssue', () => {
    const goodsIssueIdStr = new Types.ObjectId().toString();
    const warehouseIdStr = new Types.ObjectId().toString();

    it('bỏ qua nếu đã có Shipment cho goodsIssueId này (idempotent)', async () => {
      repo.findByGoodsIssueId.mockResolvedValue({ _id: shipmentId });
      await svc.createFromGoodsIssue({
        orderId,
        goodsIssueId: goodsIssueIdStr,
        fulfillWarehouseId: warehouseIdStr,
        recipient: { name: 'A', phone: '090', address: {} },
        paymentMethod: 'COD',
        codAmount: 0,
      });
      expect(repo.createFromGoodsIssue).not.toHaveBeenCalled();
    });

    it('tạo Shipment PENDING khi chưa tồn tại', async () => {
      repo.findByGoodsIssueId.mockResolvedValue(null);
      repo.createFromGoodsIssue.mockResolvedValue({ _id: shipmentId });
      await svc.createFromGoodsIssue({
        orderId,
        goodsIssueId: goodsIssueIdStr,
        fulfillWarehouseId: warehouseIdStr,
        recipient: { name: 'A', phone: '090', address: {} },
        paymentMethod: 'COD',
        codAmount: 0,
      });
      expect(repo.createFromGoodsIssue).toHaveBeenCalledWith({
        orderId,
        goodsIssueId: new Types.ObjectId(goodsIssueIdStr),
        fulfillWarehouseId: new Types.ObjectId(warehouseIdStr),
        recipient: { name: 'A', phone: '090', address: {} },
        paymentMethod: 'COD',
        codAmount: 0,
      });
    });
  });
```

- [ ] **Step 6: Chạy lại test, xác nhận pass**

Run: `pnpm test -- shipment.service.spec.ts`
Expected: PASS toàn bộ (bao gồm mọi nhánh state machine).

- [ ] **Step 7: Build**

Run: `pnpm build`
Expected: thành công.

- [ ] **Step 8: Commit**

```bash
git add apps/wms/src/shipping/shipment.repository.ts apps/wms/src/shipping/shipment.service.ts apps/wms/src/shipping/shipment.service.spec.ts
git commit -m "feat(shipping): ShipmentRepository/Service — state machine 7 trạng thái, phát 3 event shipment.*"
```

---

### Task 7: `GoodsIssuedConsumer` — auto-sinh Shipment khi nhận `goods.issued`

**Files:**
- Create: `apps/wms/src/shipping/goods-issued.consumer.ts`
- Test: `apps/wms/src/shipping/goods-issued.consumer.spec.ts`

**Interfaces:**
- Consumes: `ShipmentService.createFromGoodsIssue` (Task 6); `GoodsIssueRepository.findById` (đã có, export từ `GoodsIssueModule`); `EVENTS.GOODS_ISSUED`, `QUEUES.SHIPMENT`, `GoodsIssuedPayload`.
- Produces: `GoodsIssuedConsumer` — đăng ký provider trong `ShippingModule` (Task 8).

- [ ] **Step 1: Viết test thất bại**

```ts
// apps/wms/src/shipping/goods-issued.consumer.spec.ts
import { GoodsIssuedConsumer } from './goods-issued.consumer';
import { EVENTS } from '@app/events';

describe('GoodsIssuedConsumer', () => {
  let consumer: GoodsIssuedConsumer;
  let shipmentService: { createFromGoodsIssue: jest.Mock };
  let goodsIssueRepo: { findById: jest.Mock };

  beforeEach(() => {
    shipmentService = { createFromGoodsIssue: jest.fn() };
    goodsIssueRepo = { findById: jest.fn() };
    consumer = new GoodsIssuedConsumer(
      shipmentService as never,
      goodsIssueRepo as never,
    );
  });

  it('tạo Shipment từ snapshot GoodsIssue khi nhận goods.issued', async () => {
    goodsIssueRepo.findById.mockResolvedValue({
      _id: 'gi1',
      orderId: 'order-1',
      warehouseId: 'wh1',
      shippingAddress: { street: '123' },
      recipient: { name: 'A', phone: '090' },
      paymentMethod: 'COD',
      codAmount: 0,
    });
    const job = {
      name: EVENTS.GOODS_ISSUED,
      data: { orderId: 'order-1', goodsIssueId: 'gi1' },
    } as never;

    await consumer.process(job);

    expect(shipmentService.createFromGoodsIssue).toHaveBeenCalledWith({
      orderId: 'order-1',
      goodsIssueId: 'gi1',
      fulfillWarehouseId: 'wh1',
      recipient: { name: 'A', phone: '090', address: { street: '123' } },
      paymentMethod: 'COD',
      codAmount: 0,
    });
  });

  it('bỏ qua nếu không tìm thấy GoodsIssue (log warning, không throw)', async () => {
    goodsIssueRepo.findById.mockResolvedValue(null);
    const job = {
      name: EVENTS.GOODS_ISSUED,
      data: { orderId: 'order-1', goodsIssueId: 'gi1' },
    } as never;

    await consumer.process(job);

    expect(shipmentService.createFromGoodsIssue).not.toHaveBeenCalled();
  });

  it('bỏ qua job không phải goods.issued', async () => {
    const job = { name: 'some.other.event', data: {} } as never;
    await consumer.process(job);
    expect(shipmentService.createFromGoodsIssue).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Chạy test, xác nhận fail**

Run: `pnpm test -- goods-issued.consumer.spec.ts`
Expected: FAIL — module `./goods-issued.consumer` không tồn tại.

- [ ] **Step 3: Viết `GoodsIssuedConsumer`**

```ts
// apps/wms/src/shipping/goods-issued.consumer.ts
import { Processor, WorkerHost } from '@nestjs/bullmq';
import { Logger } from '@nestjs/common';
import { Job } from 'bullmq';
import { EVENTS, QUEUES, type GoodsIssuedPayload } from '@app/events';
import { ShipmentService } from './shipment.service';
import { GoodsIssueRepository } from '../goods-issue/goods-issue.repository';

/**
 * Consumer nội bộ WMS — nhận goods.issued (do GoodsIssueService phát trên
 * cùng QUEUES.SHIPMENT mà Ecommerce cũng lắng nghe). 2 process riêng biệt
 * cùng đọc 1 queue Redis, không xung đột.
 */
@Processor(QUEUES.SHIPMENT)
export class GoodsIssuedConsumer extends WorkerHost {
  private readonly logger = new Logger(GoodsIssuedConsumer.name);

  constructor(
    private readonly shipmentService: ShipmentService,
    private readonly goodsIssueRepo: GoodsIssueRepository,
  ) {
    super();
  }

  async process(job: Job): Promise<void> {
    switch (job.name) {
      case EVENTS.GOODS_ISSUED: {
        const data = job.data as GoodsIssuedPayload;
        const gi = await this.goodsIssueRepo.findById(data.goodsIssueId);
        if (!gi) {
          this.logger.warn(
            `Không tìm thấy GoodsIssue=${data.goodsIssueId} → bỏ qua auto-sinh Shipment.`,
          );
          return;
        }
        await this.shipmentService.createFromGoodsIssue({
          orderId: gi.orderId,
          goodsIssueId: data.goodsIssueId,
          fulfillWarehouseId: gi.warehouseId.toString(),
          recipient: {
            name: gi.recipient.name,
            phone: gi.recipient.phone,
            address: gi.shippingAddress,
          },
          paymentMethod: gi.paymentMethod,
          codAmount: gi.codAmount,
        });
        this.logger.log(
          `Auto-sinh Shipment{PENDING} cho goodsIssueId=${data.goodsIssueId}`,
        );
        break;
      }
      default:
      // Bỏ qua job khác trên cùng queue (vd job của Ecom consumer không liên quan process này)
    }
  }
}
```

> Lưu ý: `@Processor(QUEUES.SHIPMENT)` chỉ đăng ký **1 lần** trong app WMS — nếu app này chưa có consumer nào khác lắng nghe cùng queue thì không có xung đột đăng ký. Kiểm tra Step 4.

- [ ] **Step 4: Xác nhận không có consumer khác trong `apps/wms` đã đăng ký `@Processor(QUEUES.SHIPMENT)`**

Run: `grep -rn "@Processor(QUEUES.SHIPMENT)" apps/wms/src`
Expected: chỉ 1 kết quả — `apps/wms/src/shipping/goods-issued.consumer.ts`.

- [ ] **Step 5: Chạy lại test, xác nhận pass**

Run: `pnpm test -- goods-issued.consumer.spec.ts`
Expected: PASS

- [ ] **Step 6: Build**

Run: `pnpm build`
Expected: thành công.

- [ ] **Step 7: Commit**

```bash
git add apps/wms/src/shipping/goods-issued.consumer.ts apps/wms/src/shipping/goods-issued.consumer.spec.ts
git commit -m "feat(shipping): GoodsIssuedConsumer — auto-sinh Shipment{PENDING} khi nhận goods.issued"
```

---

### Task 8: `ShipmentController` (UC-S02..S05) + `ShippingModule` + nối `AppModule`

**Files:**
- Create: `apps/wms/src/shipping/dto/shipment.dto.ts`
- Create: `apps/wms/src/shipping/shipment.controller.ts`
- Create: `apps/wms/src/shipping/shipping.module.ts`
- Modify: `apps/wms/src/goods-issue/goods-issue.module.ts` (export `GoodsIssueRepository` nếu chưa export)
- Modify: `apps/wms/src/app.module.ts`

**Interfaces:**
- Consumes: `ShipmentService` (Task 6), `CarrierService`/`CarrierController` (Task 5), `GoodsIssuedConsumer` (Task 7), `GoodsIssueModule` (export sẵn `GoodsIssueRepository` — xác nhận ở `goods-issue.module.ts:26`).

- [ ] **Step 1: Xác nhận `GoodsIssueModule` đã export `GoodsIssueRepository`**

Đọc `apps/wms/src/goods-issue/goods-issue.module.ts` — dòng `exports: [GoodsIssueService, GoodsIssueRepository]` đã có sẵn (xem file hiện tại). Không cần sửa.

- [ ] **Step 2: Viết DTO cho Shipment**

```ts
// apps/wms/src/shipping/dto/shipment.dto.ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Expose, Transform, Type } from 'class-transformer';
import {
  IsEnum,
  IsInt,
  IsMongoId,
  IsOptional,
  IsString,
  Max,
  Min,
  MinLength,
} from 'class-validator';
import { Types } from 'mongoose';
import { ShipmentStatus } from '../schemas/shipment.schema';

export class AssignShipmentDto {
  @ApiProperty({ description: 'ObjectId của carrier (phải đang ACTIVE)' })
  @IsMongoId()
  carrierId!: string;

  @ApiProperty({ example: 'GHN123456789' })
  @IsString()
  @MinLength(1)
  trackingNumber!: string;
}

export class UpdateShipmentStatusDto {
  @ApiProperty({ enum: ShipmentStatus })
  @IsEnum(ShipmentStatus)
  status!: ShipmentStatus;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  note?: string;

  @ApiPropertyOptional({ description: 'Bắt buộc có ý nghĩa khi status=FAILED' })
  @IsOptional()
  @IsString()
  failReason?: string;
}

export class QueryShipmentDto {
  @ApiPropertyOptional({ enum: ShipmentStatus })
  @IsOptional()
  @IsEnum(ShipmentStatus)
  shipmentStatus?: ShipmentStatus;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  orderId?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsMongoId()
  carrierId?: string;

  @ApiPropertyOptional({ default: 1, minimum: 1 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  page?: number;

  @ApiPropertyOptional({ default: 20, minimum: 1, maximum: 100 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;
}

class ShipmentStatusHistoryResponseDto {
  @Expose()
  @ApiProperty({ enum: ShipmentStatus })
  status!: ShipmentStatus;

  @Expose()
  @ApiProperty()
  at!: Date;

  @Expose()
  @Transform(({ obj }: { obj: { by?: Types.ObjectId } }) => obj.by?.toString())
  @ApiPropertyOptional()
  by?: string;

  @Expose()
  @ApiPropertyOptional()
  note?: string;
}

export class ShipmentResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) => obj._id?.toString())
  @ApiProperty()
  id!: string;

  @Expose()
  @ApiProperty()
  orderId!: string;

  @Expose()
  @Transform(({ obj }: { obj: { goodsIssueId?: Types.ObjectId } }) =>
    obj.goodsIssueId?.toString(),
  )
  @ApiProperty()
  goodsIssueId!: string;

  @Expose()
  @Transform(({ obj }: { obj: { fulfillWarehouseId?: Types.ObjectId } }) =>
    obj.fulfillWarehouseId?.toString(),
  )
  @ApiProperty()
  fulfillWarehouseId!: string;

  @Expose()
  @Transform(({ obj }: { obj: { carrierId?: Types.ObjectId } }) =>
    obj.carrierId?.toString(),
  )
  @ApiPropertyOptional()
  carrierId?: string;

  @Expose()
  @ApiPropertyOptional()
  trackingNumber?: string;

  @Expose()
  @ApiProperty({ enum: ShipmentStatus })
  shipmentStatus!: ShipmentStatus;

  @Expose()
  @ApiProperty()
  recipient!: { name: string; phone: string; address: Record<string, unknown> };

  @Expose()
  @ApiProperty({ enum: ['COD', 'ONLINE'] })
  paymentMethod!: 'COD' | 'ONLINE';

  @Expose()
  @ApiProperty()
  codAmount!: number;

  @Expose()
  @ApiProperty()
  attempts!: number;

  @Expose()
  @ApiPropertyOptional()
  failReason?: string;

  @Expose()
  @Type(() => ShipmentStatusHistoryResponseDto)
  @ApiProperty({ type: [ShipmentStatusHistoryResponseDto] })
  statusHistory!: ShipmentStatusHistoryResponseDto[];

  @Expose()
  @ApiPropertyOptional()
  shippedAt?: Date;

  @Expose()
  @ApiPropertyOptional()
  deliveredAt?: Date;

  @Expose()
  @ApiProperty()
  createdAt!: Date;

  @Expose()
  @ApiProperty()
  updatedAt!: Date;
}
```

- [ ] **Step 3: Viết `ShipmentController`**

```ts
// apps/wms/src/shipping/shipment.controller.ts
import { Body, Controller, Get, Param, Patch, Query, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOkResponse, ApiOperation, ApiTags } from '@nestjs/swagger';
import { CurrentUser, JwtAuthGuard, Roles, RolesGuard, WmsRole } from '@app/auth';
import { plainToInstance } from 'class-transformer';
import { ShipmentService } from './shipment.service';
import {
  AssignShipmentDto,
  UpdateShipmentStatusDto,
  QueryShipmentDto,
  ShipmentResponseDto,
} from './dto/shipment.dto';

const TO_OPTS = { excludeExtraneousValues: true } as const;

@ApiTags('shipments')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard, RolesGuard)
@Controller('shipments')
export class ShipmentController {
  constructor(private readonly svc: ShipmentService) {}

  @Get()
  @Roles(WmsRole.SHIPPER, WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Danh sách vận đơn — [SHIPPER, MANAGER, ADMIN]' })
  @ApiOkResponse({ type: [ShipmentResponseDto] })
  async list(@Query() query: QueryShipmentDto): Promise<{
    data: ShipmentResponseDto[];
    total: number;
    page: number;
    limit: number;
  }> {
    const { data, total } = await this.svc.list(query);
    return {
      data: plainToInstance(ShipmentResponseDto, data.map((d) => d.toObject()), TO_OPTS),
      total,
      page: query.page ?? 1,
      limit: query.limit ?? 20,
    };
  }

  @Get(':id')
  @Roles(WmsRole.SHIPPER, WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Chi tiết vận đơn — [SHIPPER, MANAGER, ADMIN]' })
  @ApiOkResponse({ type: ShipmentResponseDto })
  async getById(@Param('id') id: string): Promise<ShipmentResponseDto> {
    const doc = await this.svc.getById(id);
    return plainToInstance(ShipmentResponseDto, doc.toObject(), TO_OPTS);
  }

  @Patch(':id/assign')
  @Roles(WmsRole.SHIPPER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Gán hãng vận chuyển + mã tracking — [SHIPPER, ADMIN]' })
  @ApiOkResponse({ type: ShipmentResponseDto })
  async assign(
    @Param('id') id: string,
    @Body() dto: AssignShipmentDto,
  ): Promise<ShipmentResponseDto> {
    const doc = await this.svc.assignCarrier(id, dto.carrierId, dto.trackingNumber);
    return plainToInstance(ShipmentResponseDto, doc.toObject(), TO_OPTS);
  }

  @Patch(':id/status')
  @Roles(WmsRole.SHIPPER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Cập nhật trạng thái giao hàng — [SHIPPER, ADMIN]' })
  @ApiOkResponse({ type: ShipmentResponseDto })
  async updateStatus(
    @Param('id') id: string,
    @Body() dto: UpdateShipmentStatusDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<ShipmentResponseDto> {
    const doc = await this.svc.updateStatus(id, dto.status, actorId, {
      note: dto.note,
      failReason: dto.failReason,
    });
    return plainToInstance(ShipmentResponseDto, doc.toObject(), TO_OPTS);
  }
}
```

- [ ] **Step 4: Viết `ShippingModule`**

```ts
// apps/wms/src/shipping/shipping.module.ts
import { BullModule } from '@nestjs/bullmq';
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { QUEUES } from '@app/events';
import { Carrier, CarrierSchema } from './schemas/carrier.schema';
import { Shipment, ShipmentSchema } from './schemas/shipment.schema';
import { CarrierRepository } from './carrier.repository';
import { CarrierService } from './carrier.service';
import { CarrierController } from './carrier.controller';
import { ShipmentRepository } from './shipment.repository';
import { ShipmentService } from './shipment.service';
import { ShipmentController } from './shipment.controller';
import { GoodsIssuedConsumer } from './goods-issued.consumer';
import { GoodsIssueModule } from '../goods-issue/goods-issue.module';

@Module({
  imports: [
    // SHIPMENT: consume goods.issued (auto-sinh Shipment) · produce shipment.shipped/delivered/returned
    BullModule.registerQueue({ name: QUEUES.SHIPMENT }),
    MongooseModule.forFeature([
      { name: Carrier.name, schema: CarrierSchema },
      { name: Shipment.name, schema: ShipmentSchema },
    ]),
    GoodsIssueModule, // GoodsIssueRepository — đọc snapshot recipient/paymentMethod/codAmount
  ],
  providers: [
    CarrierRepository,
    CarrierService,
    ShipmentRepository,
    ShipmentService,
    GoodsIssuedConsumer,
  ],
  controllers: [CarrierController, ShipmentController],
  exports: [CarrierService, ShipmentService],
})
export class ShippingModule {}
```

- [ ] **Step 5: Nối vào `AppModule`**

Trong `apps/wms/src/app.module.ts`, thêm import:

```ts
import { ShippingModule } from './shipping/shipping.module';
```

Thêm vào mảng `imports`, sau `GoodsReturnModule`:

```ts
    ShippingModule, // P7: carriers + shipments, auto-sinh sau goods.issued, phát shipment.shipped/delivered/returned
```

- [ ] **Step 6: Build toàn bộ**

Run: `pnpm build`
Expected: thành công, không lỗi resolve module.

- [ ] **Step 7: Chạy toàn bộ test suite wms**

Run: `pnpm test -- apps/wms`
Expected: PASS toàn bộ.

- [ ] **Step 8: Commit**

```bash
git add apps/wms/src/shipping/dto/shipment.dto.ts apps/wms/src/shipping/shipment.controller.ts apps/wms/src/shipping/shipping.module.ts apps/wms/src/app.module.ts
git commit -m "feat(shipping): ShipmentController (UC-S02..S05) + ShippingModule nối vào AppModule"
```

---

### Task 9: Ecommerce — xử lý `shipment.returned`

**Files:**
- Modify: `apps/ecommerce/src/order/order.consumer.ts`
- Modify: `apps/ecommerce/src/order/order.service.ts`
- Test: `apps/ecommerce/src/order/order.consumer.spec.ts` (tạo mới)
- Test: `apps/ecommerce/src/order/order.service.spec.ts` (tạo mới, chỉ cho phần onReturned — không viết lại test cho toàn bộ service)

**Interfaces:**
- Consumes: `EVENTS.SHIPMENT_RETURNED`, `ShipmentEventPayload`; `FulfillmentStatus`, `OrderStatus`, `PaymentStatus`, `PaymentMethod` (`apps/ecommerce/src/order/schemas/order.schema.ts`).
- Produces: `OrderService.onReturned(orderId: string): Promise<void>`.

- [ ] **Step 1: Viết test thất bại cho `OrderService.onReturned`**

```ts
// apps/ecommerce/src/order/order.service.spec.ts
import { Types } from 'mongoose';
import { OrderService } from './order.service';
import { FulfillmentStatus, OrderStatus, PaymentStatus, PaymentMethod } from './schemas/order.schema';

const makeRepo = () => ({
  findById: jest.fn(),
  updateOrder: jest.fn(),
  listByCustomer: jest.fn(),
  listAll: jest.fn(),
});

const makeQueue = () => ({ add: jest.fn() });
const makePaymentService = () => ({});

describe('OrderService.onReturned', () => {
  let svc: OrderService;
  let repo: ReturnType<typeof makeRepo>;
  const orderId = new Types.ObjectId().toString();

  beforeEach(() => {
    repo = makeRepo();
    svc = new OrderService(
      repo as never,
      makeQueue() as never,
      makePaymentService() as never,
    );
  });

  it('không làm gì nếu order không tồn tại', async () => {
    repo.findById.mockResolvedValue(null);
    await svc.onReturned(orderId);
    expect(repo.updateOrder).not.toHaveBeenCalled();
  });

  it('COD: RETURNED/CANCELLED, không đổi paymentStatus', async () => {
    repo.findById.mockResolvedValue({ paymentMethod: PaymentMethod.COD });
    await svc.onReturned(orderId);
    expect(repo.updateOrder).toHaveBeenCalledWith(orderId, {
      fulfillmentStatus: FulfillmentStatus.RETURNED,
      orderStatus: OrderStatus.CANCELLED,
    });
  });

  it('ONLINE: RETURNED/CANCELLED + paymentStatus=REFUND_PENDING', async () => {
    repo.findById.mockResolvedValue({ paymentMethod: PaymentMethod.ONLINE });
    await svc.onReturned(orderId);
    expect(repo.updateOrder).toHaveBeenCalledWith(orderId, {
      fulfillmentStatus: FulfillmentStatus.RETURNED,
      orderStatus: OrderStatus.CANCELLED,
      paymentStatus: PaymentStatus.REFUND_PENDING,
    });
  });
});
```

- [ ] **Step 2: Chạy test, xác nhận fail**

Run: `pnpm test -- order.service.spec.ts`
Expected: FAIL — `svc.onReturned` không phải hàm.

- [ ] **Step 3: Thêm `onReturned` vào `OrderService`**

Trong `apps/ecommerce/src/order/order.service.ts`, thêm sau `onDelivered` (cuối class, trước dấu `}` đóng class):

```ts

  async onReturned(orderId: string) {
    const order = await this.repo.findById(orderId);
    if (!order) return;

    const updates: Partial<Order> = {
      fulfillmentStatus: FulfillmentStatus.RETURNED,
      orderStatus: OrderStatus.CANCELLED,
    };

    // Return-to-sender (chưa từng giao thành công) — ONLINE đã trả trước cần hoàn tiền;
    // COD chưa thu được đồng nào nên không cần hoàn.
    if (order.paymentMethod === PaymentMethod.ONLINE) {
      updates.paymentStatus = PaymentStatus.REFUND_PENDING;
    }

    await this.repo.updateOrder(orderId, updates);
    this.logger.log(
      `WMS cập nhật: Đơn ${orderId} hoàn về kho (chưa giao được) -> CANCELLED`,
    );
  }
```

- [ ] **Step 4: Chạy lại test, xác nhận pass**

Run: `pnpm test -- order.service.spec.ts`
Expected: PASS

- [ ] **Step 5: Viết test thất bại cho `ShipmentConsumer` case mới**

```ts
// apps/ecommerce/src/order/order.consumer.spec.ts
import { ShipmentConsumer } from './order.consumer';
import { EVENTS } from '@app/events';

describe('ShipmentConsumer', () => {
  let consumer: ShipmentConsumer;
  let orderService: {
    onGoodsIssued: jest.Mock;
    onPrintCompleted: jest.Mock;
    onShipped: jest.Mock;
    onDelivered: jest.Mock;
    onReturned: jest.Mock;
  };

  beforeEach(() => {
    orderService = {
      onGoodsIssued: jest.fn(),
      onPrintCompleted: jest.fn(),
      onShipped: jest.fn(),
      onDelivered: jest.fn(),
      onReturned: jest.fn(),
    };
    consumer = new ShipmentConsumer(orderService as never);
  });

  it('gọi onReturned khi nhận shipment.returned', async () => {
    const job = {
      name: EVENTS.SHIPMENT_RETURNED,
      data: { orderId: 'order-1', shipmentId: 'ship1' },
    } as never;
    await consumer.process(job);
    expect(orderService.onReturned).toHaveBeenCalledWith('order-1');
  });

  it('bỏ qua job shipment.returned thiếu orderId', async () => {
    const job = { name: EVENTS.SHIPMENT_RETURNED, data: {} } as never;
    await consumer.process(job);
    expect(orderService.onReturned).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 6: Chạy test, xác nhận fail**

Run: `pnpm test -- order.consumer.spec.ts`
Expected: FAIL — `case EVENTS.SHIPMENT_RETURNED` chưa tồn tại nên `onReturned` không được gọi.

- [ ] **Step 7: Thêm case vào `ShipmentConsumer`**

Trong `apps/ecommerce/src/order/order.consumer.ts`, thêm import `ShipmentEventPayload` đã có sẵn (đã import ở đầu file), thêm case sau `SHIPMENT_DELIVERED`:

```ts
      case EVENTS.SHIPMENT_RETURNED: {
        const data = job.data as ShipmentEventPayload;
        if (!data.orderId) return;
        this.logger.log(
          `Nhận sự kiện fulfillment: ${job.name} cho đơn hàng ${data.orderId}`,
        );
        await this.orderService.onReturned(data.orderId);
        break;
      }
```

- [ ] **Step 8: Chạy lại test, xác nhận pass**

Run: `pnpm test -- order.consumer.spec.ts`
Expected: PASS

- [ ] **Step 9: Build + chạy toàn bộ test ecommerce**

Run: `pnpm build && pnpm test -- apps/ecommerce`
Expected: thành công, PASS toàn bộ.

- [ ] **Step 10: Commit**

```bash
git add apps/ecommerce/src/order/order.consumer.ts apps/ecommerce/src/order/order.service.ts apps/ecommerce/src/order/order.consumer.spec.ts apps/ecommerce/src/order/order.service.spec.ts
git commit -m "feat(order): xử lý shipment.returned — RETURNED/CANCELLED, REFUND_PENDING nếu ONLINE"
```

---

### Task 10: Kiểm tra toàn cục + lint

**Files:** không tạo/sửa file mới — chỉ verify.

- [ ] **Step 1: Lint toàn repo**

Run: `pnpm lint`
Expected: không lỗi (hoặc chỉ auto-fix, không còn lỗi sau khi chạy).

- [ ] **Step 2: Build toàn repo**

Run: `pnpm build`
Expected: thành công cho cả `wms` và `ecommerce`.

- [ ] **Step 3: Chạy toàn bộ test suite**

Run: `pnpm test`
Expected: PASS toàn bộ, không skip, không lỗi.

- [ ] **Step 4: Xác nhận không còn `@Processor(QUEUES.SHIPMENT)` trùng lặp trong `apps/wms`**

Run: `grep -rn "@Processor(QUEUES.SHIPMENT)" apps/wms/src apps/ecommerce/src`
Expected: 1 kết quả ở `apps/wms/src/shipping/goods-issued.consumer.ts`, 1 kết quả ở `apps/ecommerce/src/order/order.consumer.ts` — mỗi app đúng 1 consumer.

- [ ] **Step 5: Xác nhận `EVENTS.SHIPMENT_RETURNED` đã có consumer**

Run: `grep -n "SHIPMENT_RETURNED" apps/ecommerce/src/order/order.consumer.ts`
Expected: xuất hiện trong `case EVENTS.SHIPMENT_RETURNED`.

- [ ] **Step 6: Không commit gì ở task này (chỉ verify) — nếu lint tự fix có thay đổi file, commit riêng**

```bash
git status
# Nếu có thay đổi do lint --fix:
git add -A
git commit -m "chore(shipping): lint fix"
```

---

## Self-Review

- **Spec coverage:** §2.1 role SHIPPER → Task 1. §2.2 snapshot GoodsIssue → Task 2. §2.3 consumer SHIPMENT_RETURNED → Task 9. §3.1 mở rộng GoodsIssue → Task 2. §3.2 Carrier schema → Task 3. §3.3 Shipment schema → Task 3. §4 state machine → Task 6. §5 module layout → Task 3/5/6/7/8. §6 API endpoints → Task 5/8. §7 Ecommerce onReturned → Task 9. §8 error codes → Task 4. §9 testing → mỗi task có spec riêng theo TDD. §10 YAGNI — không có task nào implement (đúng ý, không cần task).
- **Placeholder scan:** không còn "TBD"/"TODO"; mọi step code có nội dung đầy đủ, mọi lệnh test có chỉ định file cụ thể.
- **Type consistency:** `ShipmentService.createFromGoodsIssue` input shape khớp giữa Task 6 (định nghĩa) và Task 7 (gọi từ consumer) — cùng field `orderId/goodsIssueId/fulfillWarehouseId/recipient/paymentMethod/codAmount`. `CarrierService.getById` dùng ở Task 6 khớp chữ ký định nghĩa ở Task 5. `WMS_ERRORS` code dùng trong service (Task 5/6) khớp đúng tên khai ở Task 4. `EVENTS.SHIPMENT_*`/`QUEUES.SHIPMENT`/`ShipmentEventPayload` dùng nhất quán Task 6/7/9, đúng với khai báo sẵn có ở `libs/events/src/events.ts` (không cần sửa file này).

---

## Lưu ý git

Nhánh hiện tại `develop` (be repo) — không phải `main`. Theo lịch sử commit gần đây (`72b5494 Merge branch 'worktree-stock-reservation-saga' into develop`), nhánh feature tự chọn merge về `develop` khi hoàn tất, không tự ý push `main`.
