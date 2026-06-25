# Ecommerce Week 3 — Shipping + Hardening + Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hoàn thiện Shipping module (Carrier + Shipment + status flows) + hardening toàn bộ flow + seed data đầy đủ + demo prep.

**Architecture:** Tạo `ShippingModule` trong `apps/wms` (vì Shipping là module WMS — quản lý vận đơn từ kho ra). Consumer `goods.issued` → tạo Shipment. WMS emit `shipment.shipped/delivered/returned` → Ecom consumer cập nhật fulfillmentStatus (đã có trong OrderService tuần 2).

**Tech Stack:** NestJS, Mongoose, BullMQ, Swagger

## Global Constraints

- Shipping module nằm ở `apps/wms` (không phải ecommerce) — SHIPPER là role WMS
- Ecom chỉ consume sự kiện shipment (đã implement ở tuần 2: ShipmentConsumer)
- `shipmentStatus` flow: PENDING → PICKED_UP → IN_TRANSIT → DELIVERED (hoặc FAILED → RETURNING → RETURNED)
- 1 GoodsIssue = 1 Shipment (không tách giao từng phần)
- Comment tiếng Việt giải thích *vì sao*
- Hardening: thêm Mongoose index, xử lý edge case, Swagger annotation đầy đủ

---

## File Structure (tạo mới / sửa)

```
apps/wms/src/
└── shipping/
    ├── schemas/
    │   ├── carrier.schema.ts      [TẠO MỚI]
    │   └── shipment.schema.ts     [TẠO MỚI]
    ├── dto/
    │   └── shipping.dto.ts        [TẠO MỚI]
    ├── shipping.repository.ts     [TẠO MỚI]
    ├── shipping.service.ts        [TẠO MỚI]
    ├── shipping.controller.ts     [TẠO MỚI]
    ├── goods-issued.consumer.ts   [TẠO MỚI — nhận goods.issued → tạo Shipment]
    └── shipping.module.ts         [TẠO MỚI]

apps/wms/src/wms.module.ts         [SỬA — import ShippingModule]
apps/ecommerce/src/seed.ts         [SỬA — seed đầy đủ hơn]
```

---

## Task E3-01: Carrier + Shipment schemas

**Files:**
- Create: `apps/wms/src/shipping/schemas/carrier.schema.ts`
- Create: `apps/wms/src/shipping/schemas/shipment.schema.ts`

**Interfaces:**
- Produces: `Carrier`, `Shipment` Mongoose schemas dùng cho ShippingModule

- [ ] **Step 1: Tạo Carrier schema**

```typescript
// apps/wms/src/shipping/schemas/carrier.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument } from 'mongoose';

export enum CarrierStatus { ACTIVE = 'ACTIVE', INACTIVE = 'INACTIVE' }

/**
 * Hãng vận chuyển — không xóa cứng nếu đã có vận đơn.
 * INACTIVE thay vì xóa để giữ lịch sử đối soát.
 */
@Schema({ collection: 'carriers', timestamps: true })
export class Carrier {
  @Prop({ required: true })
  name: string;

  @Prop({ required: true, unique: true, index: true })
  code: string; // VD: GHTK, GHN, VNPOST

  @Prop({ type: Object, default: {} })
  contactInfo: Record<string, string>; // { phone, email, address }

  @Prop({ default: '' })
  note: string;

  @Prop({ enum: CarrierStatus, default: CarrierStatus.ACTIVE, index: true })
  status: CarrierStatus;
}

export type CarrierDocument = HydratedDocument<Carrier>;
export const CarrierSchema = SchemaFactory.createForClass(Carrier);
```

- [ ] **Step 2: Tạo Shipment schema**

```typescript
// apps/wms/src/shipping/schemas/shipment.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

export enum ShipmentStatus {
  PENDING = 'PENDING',         // chờ gán carrier
  PICKED_UP = 'PICKED_UP',     // hãng đến lấy tại kho
  IN_TRANSIT = 'IN_TRANSIT',   // đang trên đường giao
  DELIVERED = 'DELIVERED',     // giao thành công
  FAILED = 'FAILED',           // giao thất bại (có thể retry)
  RETURNING = 'RETURNING',     // đang hoàn về kho
  RETURNED = 'RETURNED',       // đã hoàn về kho
}

class StatusHistoryEntry {
  status: ShipmentStatus;
  timestamp: Date;
  note?: string;
}

class Recipient {
  name: string;
  phone: string;
}

/**
 * Vận đơn — 1:1 với GoodsIssue WMS (1 đơn = 1 vận đơn, không tách giao).
 * Tự động tạo PENDING khi nhận event goods.issued.
 * SHIPPER điền carrierId + trackingNumber trước khi bàn giao.
 * statusHistory: append-only — mỗi lần đổi trạng thái ghi thêm 1 dòng.
 */
@Schema({ collection: 'shipments', timestamps: true })
export class Shipment {
  /** ID đơn Ecommerce — truy vết ngược */
  @Prop({ required: true, index: true })
  orderId: string;

  @Prop({ required: true, index: true })
  goodsIssueId: string;

  @Prop({ enum: ShipmentStatus, default: ShipmentStatus.PENDING, index: true })
  shipmentStatus: ShipmentStatus;

  @Prop({ type: Types.ObjectId, default: null })
  carrierId: Types.ObjectId | null;

  @Prop({ default: null })
  trackingNumber: string | null;

  @Prop({ type: Object, required: true })
  recipient: Recipient;

  /** COD: số tiền thu hộ; ONLINE: null */
  @Prop({ default: null })
  codAmount: number | null;

  @Prop({ type: String, enum: ['COD', 'ONLINE'], required: true })
  paymentMethod: 'COD' | 'ONLINE';

  /** Lịch sử trạng thái — append-only để đối soát */
  @Prop({ type: [Object], default: [] })
  statusHistory: StatusHistoryEntry[];

  /** Số lần thử giao */
  @Prop({ default: 0 })
  attempts: number;

  @Prop({ default: null })
  failReason: string | null;

  @Prop({ default: null })
  shippedAt: Date | null;

  @Prop({ default: null })
  deliveredAt: Date | null;
}

export type ShipmentDocument = HydratedDocument<Shipment>;
export const ShipmentSchema = SchemaFactory.createForClass(Shipment);
```

- [ ] **Step 3: Compile check**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm build 2>&1 | grep -E "ERROR|error TS" | head -20
```
Expected: Không lỗi TypeScript.

- [ ] **Step 4: Commit**

```bash
git add apps/wms/src/shipping/schemas/
git commit -m "feat(wms-shipping): Carrier + Shipment schemas"
```

---

## Task E3-02: Shipping DTOs + Repository + GoodsIssuedConsumer

**Files:**
- Create: `apps/wms/src/shipping/dto/shipping.dto.ts`
- Create: `apps/wms/src/shipping/shipping.repository.ts`
- Create: `apps/wms/src/shipping/goods-issued.consumer.ts`

**Interfaces:**
- Consumes: `GoodsIssuedPayload` từ `@app/events`
- Produces: `ShippingRepository` CRUD, `GoodsIssuedConsumer` tạo Shipment PENDING

- [ ] **Step 1: Tạo DTOs**

```typescript
// apps/wms/src/shipping/dto/shipping.dto.ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsEnum, IsNotEmpty, IsOptional, IsString } from 'class-validator';
import { ShipmentStatus } from '../schemas/shipment.schema';

export class CreateCarrierDto {
  @ApiProperty({ example: 'Giao Hàng Tiết Kiệm' })
  @IsString() @IsNotEmpty()
  name: string;

  @ApiProperty({ example: 'GHTK' })
  @IsString() @IsNotEmpty()
  code: string;

  @ApiPropertyOptional({ example: { phone: '1900636677' } })
  @IsOptional()
  contactInfo?: Record<string, string>;

  @ApiPropertyOptional()
  @IsString() @IsOptional()
  note?: string;
}

export class UpdateCarrierDto {
  @ApiPropertyOptional()
  @IsString() @IsOptional()
  name?: string;

  @ApiPropertyOptional()
  @IsOptional()
  contactInfo?: Record<string, string>;

  @ApiPropertyOptional()
  @IsString() @IsOptional()
  note?: string;
}

export class AssignCarrierDto {
  @ApiProperty({ example: '64abc...', description: 'ObjectId của Carrier' })
  @IsString() @IsNotEmpty()
  carrierId: string;

  @ApiProperty({ example: 'GHTK123456789', description: 'Mã vận đơn hãng cấp' })
  @IsString() @IsNotEmpty()
  trackingNumber: string;
}

export class UpdateShipmentStatusDto {
  @ApiProperty({ enum: ShipmentStatus })
  @IsEnum(ShipmentStatus)
  status: ShipmentStatus;

  @ApiPropertyOptional({ example: 'Khách không có nhà' })
  @IsString() @IsOptional()
  note?: string;
}

export class ShipmentFilterDto {
  @ApiPropertyOptional({ enum: ShipmentStatus })
  @IsEnum(ShipmentStatus) @IsOptional()
  status?: ShipmentStatus;

  @ApiPropertyOptional()
  @IsString() @IsOptional()
  orderId?: string;

  @ApiPropertyOptional()
  @IsString() @IsOptional()
  carrierId?: string;
}
```

- [ ] **Step 2: Tạo ShippingRepository**

```typescript
// apps/wms/src/shipping/shipping.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { FilterQuery, Model, Types } from 'mongoose';
import { Carrier, CarrierStatus } from './schemas/carrier.schema';
import { Shipment, ShipmentStatus } from './schemas/shipment.schema';
import { ShipmentFilterDto } from './dto/shipping.dto';

@Injectable()
export class ShippingRepository {
  constructor(
    @InjectModel(Carrier.name) private readonly carrierModel: Model<Carrier>,
    @InjectModel(Shipment.name) private readonly shipmentModel: Model<Shipment>,
  ) {}

  // ── Carrier ───────────────────────────────────────────────────────────────

  async createCarrier(data: Partial<Carrier>) {
    return this.carrierModel.create(data);
  }

  async listActiveCarriers() {
    return this.carrierModel.find({ status: CarrierStatus.ACTIVE }).sort({ name: 1 }).lean();
  }

  async listAllCarriers() {
    return this.carrierModel.find().sort({ name: 1 }).lean();
  }

  async updateCarrier(id: string, data: Partial<Carrier>) {
    return this.carrierModel.findByIdAndUpdate(id, data, { new: true }).lean();
  }

  async setCarrierStatus(id: string, status: CarrierStatus) {
    return this.carrierModel.findByIdAndUpdate(id, { status }, { new: true }).lean();
  }

  // ── Shipment ──────────────────────────────────────────────────────────────

  async createShipment(data: Partial<Shipment>) {
    return this.shipmentModel.create(data);
  }

  async findByOrderId(orderId: string) {
    return this.shipmentModel.findOne({ orderId }).lean();
  }

  async findById(id: string) {
    return this.shipmentModel.findById(id).lean();
  }

  async listShipments(filter: ShipmentFilterDto) {
    const q: FilterQuery<Shipment> = {};
    if (filter.status) q.shipmentStatus = filter.status;
    if (filter.orderId) q.orderId = filter.orderId;
    if (filter.carrierId) q.carrierId = new Types.ObjectId(filter.carrierId);
    return this.shipmentModel.find(q).sort({ createdAt: -1 }).lean();
  }

  /**
   * Cập nhật status + append vào statusHistory (append-only).
   * Tự động ghi shippedAt/deliveredAt khi chuyển sang IN_TRANSIT/DELIVERED.
   */
  async updateStatus(id: string, status: ShipmentStatus, note?: string) {
    const entry = { status, timestamp: new Date(), note };
    const updates: any = {
      shipmentStatus: status,
      $push: { statusHistory: entry },
    };
    if (status === ShipmentStatus.IN_TRANSIT) updates.shippedAt = new Date();
    if (status === ShipmentStatus.DELIVERED) updates.deliveredAt = new Date();
    if (status === ShipmentStatus.FAILED) {
      updates.$inc = { attempts: 1 };
      if (note) updates.failReason = note;
    }
    return this.shipmentModel.findByIdAndUpdate(id, updates, { new: true }).lean();
  }

  async assignCarrier(id: string, carrierId: string, trackingNumber: string) {
    return this.shipmentModel
      .findByIdAndUpdate(
        id,
        { carrierId: new Types.ObjectId(carrierId), trackingNumber },
        { new: true },
      )
      .lean();
  }
}
```

- [ ] **Step 3: Tạo GoodsIssuedConsumer**

```typescript
// apps/wms/src/shipping/goods-issued.consumer.ts
import { Processor, WorkerHost } from '@nestjs/bullmq';
import { Job } from 'bullmq';
import { Logger } from '@nestjs/common';
import { EVENTS, QUEUES } from '@app/events';
import { ShippingRepository } from './shipping.repository';

/**
 * Consumer nhận event `goods.issued` từ WMS khi hàng xuất kho.
 * Tự động tạo Shipment{PENDING} 1:1 với GoodsIssue.
 * payload: { orderId, goodsIssueId, recipient, paymentMethod, codAmount }
 */
@Processor(QUEUES.ORDER)
export class GoodsIssuedConsumer extends WorkerHost {
  private readonly logger = new Logger(GoodsIssuedConsumer.name);

  constructor(private readonly shippingRepo: ShippingRepository) {
    super();
  }

  async process(job: Job): Promise<void> {
    if (job.name !== EVENTS.GOODS_ISSUED && job.name !== 'order.ready_to_fulfill') return;

    // Khi nhận order.ready_to_fulfill từ Ecom: WMS xử lý GoodsIssue rồi emit goods.issued
    // Ở đây consumer đơn giản hoá: nhận goods.issued → tạo Shipment
    if (job.name !== EVENTS.GOODS_ISSUED) return;

    const { orderId, goodsIssueId, recipient, paymentMethod, codAmount } = job.data;

    // Kiểm tra idempotency — tránh tạo 2 Shipment cho cùng 1 GoodsIssue
    const existing = await this.shippingRepo.findByOrderId(orderId);
    if (existing) {
      this.logger.warn(`Shipment đã tồn tại cho orderId=${orderId}, bỏ qua`);
      return;
    }

    await this.shippingRepo.createShipment({
      orderId,
      goodsIssueId,
      recipient: recipient ?? { name: 'Khách hàng', phone: '0000000000' },
      paymentMethod: paymentMethod ?? 'ONLINE',
      codAmount: codAmount ?? null,
    });

    this.logger.log(`Tạo Shipment PENDING cho order ${orderId}`);
  }
}
```

- [ ] **Step 4: Commit**

```bash
git add apps/wms/src/shipping/dto/ apps/wms/src/shipping/shipping.repository.ts apps/wms/src/shipping/goods-issued.consumer.ts
git commit -m "feat(wms-shipping): DTOs + ShippingRepository + GoodsIssuedConsumer"
```

---

## Task E3-03: ShippingService + ShippingController

**Files:**
- Create: `apps/wms/src/shipping/shipping.service.ts`
- Create: `apps/wms/src/shipping/shipping.controller.ts`

**Interfaces:**
- Produces: REST API `/api/wms/shipping/*` + `/api/wms/carriers/*`

- [ ] **Step 1: Tạo ShippingService**

```typescript
// apps/wms/src/shipping/shipping.service.ts
import { BadRequestException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectQueue } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { EVENTS, QUEUES } from '@app/events';
import { ShippingRepository } from './shipping.repository';
import { AssignCarrierDto, CreateCarrierDto, ShipmentFilterDto, UpdateCarrierDto, UpdateShipmentStatusDto } from './dto/shipping.dto';
import { CarrierStatus } from './schemas/carrier.schema';
import { ShipmentStatus } from './schemas/shipment.schema';

@Injectable()
export class ShippingService {
  private readonly logger = new Logger(ShippingService.name);

  constructor(
    private readonly repo: ShippingRepository,
    @InjectQueue(QUEUES.SHIPMENT) private readonly shipmentQueue: Queue,
  ) {}

  // ── Carrier ───────────────────────────────────────────────────────────────

  async createCarrier(dto: CreateCarrierDto) {
    return this.repo.createCarrier({
      name: dto.name,
      code: dto.code,
      contactInfo: dto.contactInfo ?? {},
      note: dto.note ?? '',
    });
  }

  async listCarriers(activeOnly = false) {
    return activeOnly ? this.repo.listActiveCarriers() : this.repo.listAllCarriers();
  }

  async updateCarrier(id: string, dto: UpdateCarrierDto) {
    const updated = await this.repo.updateCarrier(id, dto as any);
    if (!updated) throw new NotFoundException('Hãng vận chuyển không tồn tại');
    return updated;
  }

  async setCarrierActive(id: string) {
    return this.repo.setCarrierStatus(id, CarrierStatus.ACTIVE);
  }

  async setCarrierInactive(id: string) {
    return this.repo.setCarrierStatus(id, CarrierStatus.INACTIVE);
  }

  // ── Shipment ──────────────────────────────────────────────────────────────

  async listShipments(filter: ShipmentFilterDto) {
    return this.repo.listShipments(filter);
  }

  async getShipment(id: string) {
    const s = await this.repo.findById(id);
    if (!s) throw new NotFoundException('Vận đơn không tồn tại');
    return s;
  }

  async assignCarrier(id: string, dto: AssignCarrierDto) {
    const s = await this.repo.findById(id);
    if (!s) throw new NotFoundException('Vận đơn không tồn tại');
    if (s.shipmentStatus !== ShipmentStatus.PENDING) {
      throw new BadRequestException('Chỉ gán carrier cho vận đơn PENDING');
    }
    return this.repo.assignCarrier(id, dto.carrierId, dto.trackingNumber);
  }

  /**
   * Cập nhật trạng thái giao — mỗi lần thay đổi emit event tương ứng về Ecom.
   * Luồng hợp lệ:
   *   PENDING → PICKED_UP → IN_TRANSIT → DELIVERED
   *                                  ↘ FAILED → (retry IN_TRANSIT) hoặc RETURNING → RETURNED
   */
  async updateStatus(id: string, dto: UpdateShipmentStatusDto) {
    const s = await this.repo.findById(id);
    if (!s) throw new NotFoundException('Vận đơn không tồn tại');

    const { status, note } = dto;

    // Validate chuyển trạng thái hợp lệ
    const allowedTransitions: Record<ShipmentStatus, ShipmentStatus[]> = {
      [ShipmentStatus.PENDING]: [ShipmentStatus.PICKED_UP],
      [ShipmentStatus.PICKED_UP]: [ShipmentStatus.IN_TRANSIT],
      [ShipmentStatus.IN_TRANSIT]: [ShipmentStatus.DELIVERED, ShipmentStatus.FAILED],
      [ShipmentStatus.FAILED]: [ShipmentStatus.IN_TRANSIT, ShipmentStatus.RETURNING],
      [ShipmentStatus.RETURNING]: [ShipmentStatus.RETURNED],
      [ShipmentStatus.DELIVERED]: [],
      [ShipmentStatus.RETURNED]: [],
    };

    if (!allowedTransitions[s.shipmentStatus]?.includes(status)) {
      throw new BadRequestException(
        `Không thể chuyển từ ${s.shipmentStatus} sang ${status}`,
      );
    }

    const updated = await this.repo.updateStatus(id, status, note);

    // Emit event tương ứng về Ecom/Notification
    if (status === ShipmentStatus.IN_TRANSIT) {
      await this.shipmentQueue.add(EVENTS.SHIPMENT_SHIPPED, {
        orderId: s.orderId, shipmentId: id, trackingNumber: s.trackingNumber,
      });
      this.logger.log(`Shipment ${id} → IN_TRANSIT, phát shipment.shipped`);
    } else if (status === ShipmentStatus.DELIVERED) {
      await this.shipmentQueue.add(EVENTS.SHIPMENT_DELIVERED, {
        orderId: s.orderId, shipmentId: id,
      });
      this.logger.log(`Shipment ${id} → DELIVERED, phát shipment.delivered`);
    } else if (status === ShipmentStatus.RETURNED) {
      await this.shipmentQueue.add(EVENTS.SHIPMENT_RETURNED, {
        orderId: s.orderId, shipmentId: id,
      });
      this.logger.log(`Shipment ${id} → RETURNED, phát shipment.returned`);
    }

    return updated;
  }
}
```

- [ ] **Step 2: Tạo ShippingController**

```typescript
// apps/wms/src/shipping/shipping.controller.ts
import {
  Body, Controller, Get, Param, Post, Put, Query, UseGuards,
} from '@nestjs/common';
import {
  ApiBearerAuth, ApiOperation, ApiParam, ApiQuery, ApiTags,
} from '@nestjs/swagger';
import { JwtAuthGuard } from '@app/auth';
import { ShippingService } from './shipping.service';
import {
  AssignCarrierDto, CreateCarrierDto, ShipmentFilterDto,
  UpdateCarrierDto, UpdateShipmentStatusDto,
} from './dto/shipping.dto';
import { ShipmentStatus } from './schemas/shipment.schema';

@ApiTags('carriers')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Controller('carriers')
export class CarrierController {
  constructor(private readonly svc: ShippingService) {}

  @Post()
  @ApiOperation({ summary: '[MANAGER] Tạo hãng vận chuyển mới' })
  createCarrier(@Body() dto: CreateCarrierDto) {
    return this.svc.createCarrier(dto);
  }

  @Get()
  @ApiOperation({ summary: 'Danh sách hãng vận chuyển' })
  @ApiQuery({ name: 'activeOnly', required: false, type: Boolean })
  listCarriers(@Query('activeOnly') activeOnly?: boolean) {
    return this.svc.listCarriers(activeOnly === true || String(activeOnly) === 'true');
  }

  @Put(':id')
  @ApiOperation({ summary: '[MANAGER] Cập nhật thông tin hãng' })
  updateCarrier(@Param('id') id: string, @Body() dto: UpdateCarrierDto) {
    return this.svc.updateCarrier(id, dto);
  }

  @Put(':id/activate')
  @ApiOperation({ summary: '[MANAGER] Kích hoạt hãng' })
  activate(@Param('id') id: string) {
    return this.svc.setCarrierActive(id);
  }

  @Put(':id/deactivate')
  @ApiOperation({ summary: '[MANAGER] Vô hiệu hóa hãng (không xóa, giữ lịch sử)' })
  deactivate(@Param('id') id: string) {
    return this.svc.setCarrierInactive(id);
  }
}

@ApiTags('shipments')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Controller('shipments')
export class ShipmentController {
  constructor(private readonly svc: ShippingService) {}

  @Get()
  @ApiOperation({ summary: '[SHIPPER] Danh sách vận đơn (filter theo status/orderId/carrierId)' })
  listShipments(@Query() filter: ShipmentFilterDto) {
    return this.svc.listShipments(filter);
  }

  @Get(':id')
  @ApiOperation({ summary: '[SHIPPER] Chi tiết vận đơn kèm statusHistory' })
  @ApiParam({ name: 'id', description: 'ObjectId của Shipment' })
  getShipment(@Param('id') id: string) {
    return this.svc.getShipment(id);
  }

  @Put(':id/assign')
  @ApiOperation({ summary: '[SHIPPER] Gán hãng + tracking number cho vận đơn PENDING' })
  @ApiParam({ name: 'id', description: 'ObjectId của Shipment' })
  assignCarrier(@Param('id') id: string, @Body() dto: AssignCarrierDto) {
    return this.svc.assignCarrier(id, dto);
  }

  @Put(':id/status')
  @ApiOperation({ summary: '[SHIPPER] Cập nhật trạng thái giao (append statusHistory)' })
  @ApiParam({ name: 'id', description: 'ObjectId của Shipment' })
  updateStatus(@Param('id') id: string, @Body() dto: UpdateShipmentStatusDto) {
    return this.svc.updateStatus(id, dto);
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add apps/wms/src/shipping/shipping.service.ts apps/wms/src/shipping/shipping.controller.ts
git commit -m "feat(wms-shipping): ShippingService (Carrier CRUD + Shipment status machine) + controllers"
```

---

## Task E3-04: ShippingModule + wiring vào WMS

**Files:**
- Create: `apps/wms/src/shipping/shipping.module.ts`
- Modify: `apps/wms/src/wms.module.ts`

- [ ] **Step 1: Tạo ShippingModule**

```typescript
// apps/wms/src/shipping/shipping.module.ts
import { BullModule } from '@nestjs/bullmq';
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { QUEUES } from '@app/events';
import { Carrier, CarrierSchema } from './schemas/carrier.schema';
import { Shipment, ShipmentSchema } from './schemas/shipment.schema';
import { ShippingRepository } from './shipping.repository';
import { ShippingService } from './shipping.service';
import { CarrierController, ShipmentController } from './shipping.controller';
import { GoodsIssuedConsumer } from './goods-issued.consumer';

@Module({
  imports: [
    MongooseModule.forFeature([
      { name: Carrier.name, schema: CarrierSchema },
      { name: Shipment.name, schema: ShipmentSchema },
    ]),
    BullModule.registerQueue(
      { name: QUEUES.ORDER },    // consume goods.issued
      { name: QUEUES.SHIPMENT }, // produce shipment.shipped/delivered/returned
    ),
  ],
  controllers: [CarrierController, ShipmentController],
  providers: [ShippingRepository, ShippingService, GoodsIssuedConsumer],
})
export class ShippingModule {}
```

- [ ] **Step 2: Tìm và thêm ShippingModule vào WmsModule**

```bash
# Xem cấu trúc WMS module
cat /home/hoaiphuong/code/wms-ecom/be/apps/wms/src/wms.module.ts | head -30
```

Thêm `ShippingModule` vào `imports[]` của WmsModule (tương tự cách CatalogModule được thêm vào EcommerceModule).

- [ ] **Step 3: Smoke test WMS**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm start:wms
```

Swagger `http://localhost:3001/api/wms/docs`:
- Tag `carriers` và `shipments` hiển thị đầy đủ endpoints

- [ ] **Step 4: Commit**

```bash
git add apps/wms/src/shipping/ apps/wms/src/wms.module.ts
git commit -m "feat(wms-shipping): ShippingModule hoàn chỉnh + wiring vào WmsModule"
```

---

## Task E3-05: Hardening — Index, validation, edge cases

**Files:**
- Modify: `apps/ecommerce/src/catalog/schemas/product-variant.schema.ts` (thêm index)
- Modify: `apps/ecommerce/src/order/schemas/order.schema.ts` (thêm index)
- Modify: `apps/ecommerce/src/catalog/catalog.repository.ts` (clamp availableQty âm)

**Interfaces:**
- Mục tiêu: index đúng, query không chậm, edge case không crash

- [ ] **Step 1: Thêm compound index quan trọng**

Trong `product-variant.schema.ts`, sau khi `SchemaFactory.createForClass`:
```typescript
// Index cho search: productId + isActive thường query cùng nhau
ProductVariantSchema.index({ productId: 1, isActive: 1 });
// Index cho sync tồn: sku là key chính
// (đã có unique index từ @Prop({ unique: true }))
```

Trong `order.schema.ts`:
```typescript
// Query đơn theo customer + trạng thái
OrderSchema.index({ customerId: 1, orderStatus: 1 });
OrderSchema.index({ customerId: 1, createdAt: -1 });
```

- [ ] **Step 2: Clamp availableQty âm**

Trong `catalog.repository.ts`, method `applyStockDeltaOnce`, sau khi `updateMany`:
```typescript
// Sau updateMany, clamp về 0 nếu âm (event đến lệch thứ tự — chấp nhận tạm thời)
await this.variantModel.updateMany(
  { sku, availableQty: { $lt: 0 } },
  { $set: { availableQty: 0 } },
  { session },
);
```

- [ ] **Step 3: Validate ObjectId params**

Tìm các controller nhận `@Param('id')` và thêm pipe nếu chưa có:
```typescript
// Trong main.ts đã có ValidationPipe — đủ cho body validation.
// Với @Param('id'), thêm guard đơn giản trong service:
import { Types } from 'mongoose';
if (!Types.ObjectId.isValid(id)) throw new BadRequestException('ID không hợp lệ');
```

Áp dụng trong `OrderService.findById`, `ShippingService.getShipment`, `CatalogService.updateProduct`.

- [ ] **Step 4: Xử lý Design dangling**

Trong `CartService.addItem`, khi `dto.designId` được truyền vào:
```typescript
// Verify design thuộc về customer trước khi dùng
if (dto.designId) {
  const design = await this.catalog.repo.findDesign(dto.designId, customerId);
  if (!design) throw new NotFoundException('Design không tồn tại hoặc không có quyền');
}
```

- [ ] **Step 5: Commit**

```bash
git add apps/ecommerce/src/catalog/ apps/ecommerce/src/order/
git commit -m "hardening: thêm Mongoose index, clamp availableQty âm, validate ObjectId + Design ownership"
```

---

## Task E3-06: Seed data đầy đủ cho demo

**Files:**
- Modify: `apps/ecommerce/src/seed.ts`

**Interfaces:**
- Produces: Data mẫu bao phủ mọi trạng thái để demo + test

- [ ] **Step 1: Mở rộng seed với đơn hàng ở nhiều trạng thái**

Thêm vào cuối `seed.ts` (sau phần tạo variants):

```typescript
// Tạo 1 customer mẫu để test
const { Customer, CustomerSchema } = await import('./auth/schemas/customer.schema');
// Nếu Customer model đã đăng ký trong EcommerceModule, lấy qua getModelToken
// Chỉ seed category/product/variant là đủ cho demo flow
// Orders sẽ được tạo thủ công qua Swagger trong demo

console.log('\n📋 Hướng dẫn demo:');
console.log('1. POST /auth/register → lấy token');
console.log('2. POST /auth/verify-email (nếu cần)');
console.log('3. GET /catalog/products → xem sản phẩm');
console.log('4. POST /cart/items (sku: LID-M, quantity: 2)');
console.log('5. POST /orders/checkout { addressId: "123", paymentMethod: "COD" }');
console.log('6. GET /orders → xem đơn đã đặt');
console.log('7. POST /orders/:id/cancel → hủy đơn');
console.log('\nDemo VNPay:');
console.log('1. POST /orders/checkout { paymentMethod: "ONLINE" }');
console.log('2. GET /payment/vnpay/create-url/:orderId → lấy payUrl');
console.log('3. Dùng sandbox VNPay để thanh toán');
console.log('4. GET /orders/:id → verify PAID');
```

- [ ] **Step 2: Tạo carrier mẫu (seed WMS)**

```typescript
// Script seed carrier cho WMS — chạy riêng
// apps/wms/src/seed-carrier.ts
import { NestFactory } from '@nestjs/core';
import { WmsModule } from './wms.module';
import { getModelToken } from '@nestjs/mongoose';
import { Model } from 'mongoose';
import { Carrier } from './shipping/schemas/carrier.schema';

async function seedCarrier() {
  const app = await NestFactory.createApplicationContext(WmsModule);
  const carrierModel: Model<Carrier> = app.get(getModelToken(Carrier.name));
  await carrierModel.deleteMany({});
  await carrierModel.insertMany([
    { name: 'Giao Hàng Tiết Kiệm', code: 'GHTK', contactInfo: { phone: '1900636677' } },
    { name: 'Giao Hàng Nhanh', code: 'GHN', contactInfo: { phone: '19001234' } },
    { name: 'VN Post', code: 'VNPOST', contactInfo: { phone: '1800545454' } },
  ]);
  console.log('✅ Seed xong: 3 carriers');
  await app.close();
}
seedCarrier().catch((e) => { console.error(e); process.exit(1); });
```

- [ ] **Step 3: Commit**

```bash
git add apps/ecommerce/src/seed.ts apps/wms/src/seed-carrier.ts
git commit -m "feat: seed data đầy đủ + hướng dẫn demo"
```

---

## Task E3-07: Swagger Annotation + Demo prep

**Files:**
- Review và bổ sung Swagger `@ApiBody examples` cho các endpoints quan trọng

**Interfaces:**
- Mục tiêu: Swagger chạy được full flow không cần Postman riêng

- [ ] **Step 1: Bổ sung @ApiBody example cho CheckoutDto**

```typescript
// Trong OrderController.checkout:
@ApiBody({
  type: CheckoutDto,
  examples: {
    cod: {
      value: { addressId: '64abc123', paymentMethod: 'COD' },
      summary: 'Đặt hàng COD',
    },
    online: {
      value: { addressId: '64abc123', paymentMethod: 'ONLINE' },
      summary: 'Đặt hàng Online (VNPay)',
    },
  },
})
```

- [ ] **Step 2: Bổ sung @ApiBody example cho AddCartItemDto**

```typescript
// Trong CartController.addItem:
@ApiBody({
  type: AddCartItemDto,
  examples: {
    standard: { value: { sku: 'LID-M', quantity: 2 }, summary: 'Hàng thường' },
    custom_print: {
      value: { sku: 'CUP-BLANK-M', quantity: 1, designFile: 'https://example.com/logo.png' },
      summary: 'Ly in custom',
    },
  },
})
```

- [ ] **Step 3: Bổ sung example UpdateShipmentStatusDto**

```typescript
// Trong ShipmentController.updateStatus:
@ApiBody({
  type: UpdateShipmentStatusDto,
  examples: {
    pickup: { value: { status: 'PICKED_UP' }, summary: 'Hãng đến lấy' },
    transit: { value: { status: 'IN_TRANSIT' }, summary: 'Đang vận chuyển' },
    delivered: { value: { status: 'DELIVERED' }, summary: 'Giao thành công' },
    failed: { value: { status: 'FAILED', note: 'Khách không có nhà' }, summary: 'Giao thất bại' },
    returning: { value: { status: 'RETURNING' }, summary: 'Đang hoàn về kho' },
    returned: { value: { status: 'RETURNED' }, summary: 'Đã hoàn về kho' },
  },
})
```

- [ ] **Step 4: Bug bash nội bộ — checklist**

Chạy từng flow và ghi note:

```
□ Auth: register → verify OTP → login → lấy token ✓/✗
□ Catalog: GET /categories → GET /products?q=ly&inStock=true → GET /products/:slug ✓/✗
□ Cart: POST /cart/items (STANDARD) → GET /cart → PUT /cart/items/:sku → DELETE /cart/items/:sku ✓/✗
□ Cart: POST /cart/items (CUSTOM_PRINT với designFile) → GET /cart ✓/✗
□ Checkout COD: POST /orders/checkout (COD) → GET /orders/:id (CONFIRMED, READY_TO_PICK) ✓/✗
□ Checkout ONLINE: POST /orders/checkout (ONLINE) → GET /payment/vnpay/create-url/:orderId ✓/✗
□ VNPay sandbox: mở payUrl → thanh toán sandbox → IPN → GET /orders/:id (PAID, CONFIRMED) ✓/✗
□ Cancel: POST /orders/:id/cancel → GET /orders/:id (CANCELLED) ✓/✗
□ Shipping: GET /shipments?status=PENDING → PUT /shipments/:id/assign → PUT /shipments/:id/status (IN_TRANSIT) ✓/✗
□ Delivered: PUT /shipments/:id/status (DELIVERED) → GET /orders/:id (DELIVERED, CLOSED) ✓/✗
□ RMA: POST /orders/:id/return → GET /orders/:id (RETURNED) ✓/✗
□ Giao thất bại: FAILED → RETURNING → RETURNED → GET /orders/:id (RETURNED, CANCELLED) ✓/✗
```

- [ ] **Step 5: Final commit**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
git add .
git commit -m "feat: week3 hoàn tất — Shipping, hardening, seed, Swagger annotation, bug bash"
```

---

## ✅ Checklist Definition of Done — Tuần 3 (= DoD toàn dự án)

**4 Happy-path qua Swagger:**
- [ ] Browse catalog → cart → checkout COD → `CONFIRMED, READY_TO_PICK` ✓
- [ ] Checkout ONLINE → VNPay sandbox → `PAID, CONFIRMED, READY_TO_PICK/ISSUED` ✓
- [ ] Checkout ly-in → `AWAITING_PRINT` → (mock print.completed) → `READY_TO_PICK` ✓
- [ ] Hủy đơn trước ISSUED → `CANCELLED` + phát release ✓

**Shipping flow:**
- [ ] `goods.issued` → Shipment{PENDING} tự động ✓
- [ ] Assign carrier + tracking → `PICKED_UP` → `IN_TRANSIT` (phát shipment.shipped) ✓
- [ ] `DELIVERED` → Order `DELIVERED, CLOSED`, COD → `PAID` ✓
- [ ] `FAILED` → `RETURNING` → `RETURNED` → Order `CANCELLED` ✓

**RMA:**
- [ ] `POST /orders/:id/return` sau DELIVERED trong 7 ngày → `RETURNED` ✓
- [ ] Quá 7 ngày → 400 BadRequest ✓
- [ ] Ly-in custom → 400 BadRequest ✓

**Infrastructure:**
- [ ] Mongoose index đã thêm (compound index trên Order, ProductVariant) ✓
- [ ] availableQty clamp về 0 khi âm ✓
- [ ] Webhook VNPay: gửi 2 lần cùng providerTxnId → không duplicate transaction ✓
- [ ] Swagger: tất cả endpoints có examples, có thể chạy demo không cần Postman ✓
