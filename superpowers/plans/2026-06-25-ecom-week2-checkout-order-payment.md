# Ecommerce Week 2 — Checkout + Order + Payment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Xây dựng luồng mua hàng cốt lõi: Checkout → Order → Payment (COD + VNPay/Momo webhook + auto-cancel).

**Architecture:** Tạo 3 module mới: `CheckoutModule`, `OrderModule`, `PaymentModule`. Checkout dùng Saga 2 bước qua BullMQ (reserve request → reserve reply) để tránh 2-phase commit xuyên MongoDB. Order state machine 3 trục độc lập. Payment webhook xử lý idempotent theo `providerTxnId`.

**Tech Stack:** NestJS, Mongoose, BullMQ (delayed jobs cho auto-cancel), `@nestjs/schedule` (hoặc BullMQ delayed), `@nestjs/swagger`, VNPay sandbox HMAC-SHA512, `crypto` (Node built-in)

## Global Constraints

- App prefix: `api/shop`
- Không đọc chéo DB — WMS reserve qua BullMQ saga, không REST call trực tiếp
- `STOCK_RESERVE_REQUESTED` → WMS xử lý → reply `STOCK_RESERVED` hoặc `STOCK_RESERVE_FAILED`
- Đơn có `hasPrintItems=true` bắt buộc `paymentMethod=ONLINE` — chặn ở checkout
- `providerTxnId` là unique key idempotency cho payment webhook
- Delay auto-cancel = 30 phút (cấu hình qua env `PAYMENT_DEADLINE_MINUTES`, default 30)
- Comment tiếng Việt giải thích *vì sao*
- Events lib (`libs/events`) đã đủ payload — không cần sửa

---

## File Structure (tạo mới / sửa)

```
apps/ecommerce/src/
├── order/
│   ├── schemas/
│   │   ├── order.schema.ts           [TẠO MỚI]
│   │   └── payment-transaction.schema.ts  [TẠO MỚI]
│   ├── dto/
│   │   ├── checkout.dto.ts           [TẠO MỚI]
│   │   └── order.dto.ts              [TẠO MỚI]
│   ├── order.repository.ts           [TẠO MỚI]
│   ├── order.service.ts              [TẠO MỚI — state machine + fulfillment]
│   ├── checkout.service.ts           [TẠO MỚI — saga reserve + tạo Order]
│   ├── payment.service.ts            [TẠO MỚI — VNPay/Momo + COD]
│   ├── order.controller.ts           [TẠO MỚI]
│   ├── payment.controller.ts         [TẠO MỚI — webhook endpoint]
│   ├── reserve.consumer.ts           [TẠO MỚI — nhận STOCK_RESERVED/FAILED reply]
│   ├── order.consumer.ts             [TẠO MỚI — nhận goods.issued, print.completed]
│   └── order.module.ts               [TẠO MỚI]
└── ecommerce.module.ts               [SỬA — import OrderModule]
```

---

## Task E2-01: Order + PaymentTransaction schemas và DTOs

**Files:**
- Create: `apps/ecommerce/src/order/schemas/order.schema.ts`
- Create: `apps/ecommerce/src/order/schemas/payment-transaction.schema.ts`
- Create: `apps/ecommerce/src/order/dto/checkout.dto.ts`
- Create: `apps/ecommerce/src/order/dto/order.dto.ts`

**Interfaces:**
- Produces: `Order`, `PaymentTransaction` schemas + checkout/cancel DTOs

- [ ] **Step 1: Tạo Order schema (state machine 3 trục)**

```typescript
// apps/ecommerce/src/order/schemas/order.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

export enum PaymentMethod { COD = 'COD', ONLINE = 'ONLINE' }
export enum PaymentStatus { UNPAID = 'UNPAID', PAID = 'PAID', REFUND_PENDING = 'REFUND_PENDING', REFUNDED = 'REFUNDED' }
export enum OrderStatus { PLACED = 'PLACED', CONFIRMED = 'CONFIRMED', CANCELLED = 'CANCELLED', CLOSED = 'CLOSED' }
export enum FulfillmentStatus {
  NONE = 'NONE',
  AWAITING_PRINT = 'AWAITING_PRINT',
  READY_TO_PICK = 'READY_TO_PICK',
  ISSUED = 'ISSUED',
  SHIPPED = 'SHIPPED',
  DELIVERED = 'DELIVERED',
  RETURNED = 'RETURNED',
}

class OrderItem {
  sku: string;
  name: string;         // snapshot — không thay đổi dù catalog đổi
  unitPrice: number;    // snapshot giá lúc đặt
  quantity: number;
  isPrintItem: boolean;
  designFile?: string;  // snapshot URL artwork (CUSTOM_PRINT)
  designId?: string;    // ref Design (để reuse — có thể dangling nếu khách xóa)
  printJobId?: string;  // WMS PrintJob ID — gán sau khi print.completed
}

class ShippingAddress {
  recipientName: string;
  phone: string;
  line: string;
  ward: string;
  district: string;
  province: string;
}

/**
 * Đơn hàng với 3 trục trạng thái độc lập:
 *   paymentStatus × orderStatus × fulfillmentStatus
 * Ví dụ: COD đang giao = { UNPAID, CONFIRMED, SHIPPED }
 *        Ly-in online chờ in = { PAID, CONFIRMED, AWAITING_PRINT }
 *
 * fulfillWarehouseId: kho WMS đã giữ tồn (nhận từ STOCK_RESERVED reply).
 * hasPrintItems: true → gate bắt buộc ONLINE + paymentDeadline.
 */
@Schema({ collection: 'orders', timestamps: true })
export class Order {
  @Prop({ required: true, unique: true, index: true })
  code: string; // VD: ORD-20260625-001

  @Prop({ required: true, type: Types.ObjectId, index: true })
  customerId: Types.ObjectId;

  @Prop({ type: [Object], required: true })
  items: OrderItem[];

  @Prop({ type: Object, required: true })
  shippingAddress: ShippingAddress;

  @Prop({ required: true, min: 0 })
  subtotal: number;

  @Prop({ default: 0 })
  shippingFee: number;

  @Prop({ required: true, min: 0 })
  total: number;

  @Prop({ enum: PaymentMethod, required: true })
  paymentMethod: PaymentMethod;

  @Prop({ enum: PaymentStatus, default: PaymentStatus.UNPAID, index: true })
  paymentStatus: PaymentStatus;

  @Prop({ enum: OrderStatus, default: OrderStatus.PLACED, index: true })
  orderStatus: OrderStatus;

  @Prop({ enum: FulfillmentStatus, default: FulfillmentStatus.NONE, index: true })
  fulfillmentStatus: FulfillmentStatus;

  /** WMS kho đã reserve — nhận từ STOCK_RESERVED event */
  @Prop({ default: null })
  fulfillWarehouseId: string | null;

  @Prop({ default: false })
  hasPrintItems: boolean;

  /** Đơn ONLINE: hạn trả tiền; quá hạn → auto cancel */
  @Prop({ default: null })
  paymentDeadline: Date | null;

  @Prop({ default: null })
  cancelReason: string | null;

  @Prop({ default: null })
  placedAt: Date | null;
}

export type OrderDocument = HydratedDocument<Order>;
export const OrderSchema = SchemaFactory.createForClass(Order);
```

- [ ] **Step 2: Tạo PaymentTransaction schema**

```typescript
// apps/ecommerce/src/order/schemas/payment-transaction.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

export enum TxnType { CHARGE = 'CHARGE', COD_COLLECT = 'COD_COLLECT', REFUND = 'REFUND' }
export enum TxnStatus { SUCCESS = 'SUCCESS', FAILED = 'FAILED', PENDING = 'PENDING' }

/**
 * Sổ cái append-only — mỗi lần có biến động tiền thật thì thêm 1 dòng.
 * Không sửa/xóa dòng cũ. paymentStatus trên Order được recompute từ tập hợp này.
 * providerTxnId là idempotency key — unique index đảm bảo webhook trùng không ghi 2 lần.
 */
@Schema({ collection: 'payment_transactions', timestamps: true })
export class PaymentTransaction {
  @Prop({ required: true, type: Types.ObjectId, index: true })
  orderId: Types.ObjectId;

  @Prop({ enum: TxnType, required: true })
  type: TxnType;

  @Prop({ default: null })
  provider: string | null; // 'VNPAY' | 'MOMO' | 'COD' | null

  @Prop({ required: true, min: 0 })
  amount: number;

  @Prop({ enum: TxnStatus, required: true })
  status: TxnStatus;

  /** Mã giao dịch từ cổng — unique index đảm bảo idempotency webhook */
  @Prop({ default: null, sparse: true })
  providerTxnId: string | null;

  /** Raw payload từ webhook — lưu để debug/đối soát */
  @Prop({ type: Object, default: {} })
  raw: Record<string, unknown>;
}

export type PaymentTransactionDocument = HydratedDocument<PaymentTransaction>;
export const PaymentTransactionSchema = SchemaFactory.createForClass(PaymentTransaction);

// Tạo unique sparse index cho providerTxnId sau khi build schema
PaymentTransactionSchema.index({ providerTxnId: 1 }, { unique: true, sparse: true });
```

- [ ] **Step 3: Tạo DTOs**

```typescript
// apps/ecommerce/src/order/dto/checkout.dto.ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsEnum, IsNotEmpty, IsOptional, IsString } from 'class-validator';
import { PaymentMethod } from '../schemas/order.schema';

export class CheckoutDto {
  /** ID address trong sổ địa chỉ của khách */
  @ApiProperty({ example: '64abc...', description: 'ObjectId của address trong customer.addresses[]' })
  @IsString() @IsNotEmpty()
  addressId: string;

  @ApiProperty({ enum: PaymentMethod, example: PaymentMethod.COD })
  @IsEnum(PaymentMethod)
  paymentMethod: PaymentMethod;
}

// apps/ecommerce/src/order/dto/order.dto.ts
import { ApiPropertyOptional } from '@nestjs/swagger';
import { IsOptional, IsString } from 'class-validator';

export class CancelOrderDto {
  @ApiPropertyOptional({ example: 'Đặt nhầm sản phẩm' })
  @IsString() @IsOptional()
  reason?: string;
}
```

- [ ] **Step 4: Commit**

```bash
git add apps/ecommerce/src/order/schemas/ apps/ecommerce/src/order/dto/
git commit -m "feat(ecom-order): Order + PaymentTransaction schemas + DTOs"
```

---

## Task E2-02: OrderRepository

**Files:**
- Create: `apps/ecommerce/src/order/order.repository.ts`

**Interfaces:**
- Produces: `createOrder`, `findById`, `updateOrder`, `appendPaymentTransaction`, `findTransactionByProviderTxnId`, `listByCustomer`

- [ ] **Step 1: Tạo OrderRepository**

```typescript
// apps/ecommerce/src/order/order.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import { Order, OrderStatus, PaymentStatus, FulfillmentStatus } from './schemas/order.schema';
import { PaymentTransaction, TxnType, TxnStatus } from './schemas/payment-transaction.schema';

@Injectable()
export class OrderRepository {
  constructor(
    @InjectModel(Order.name) private readonly orderModel: Model<Order>,
    @InjectModel(PaymentTransaction.name) private readonly txnModel: Model<PaymentTransaction>,
  ) {}

  async createOrder(data: Partial<Order>) {
    return this.orderModel.create(data);
  }

  async findById(id: string) {
    return this.orderModel.findById(id).lean();
  }

  async findByCode(code: string) {
    return this.orderModel.findOne({ code }).lean();
  }

  async listByCustomer(customerId: string) {
    return this.orderModel
      .find({ customerId: new Types.ObjectId(customerId) })
      .sort({ createdAt: -1 })
      .lean();
  }

  /** Cập nhật bất kỳ trục trạng thái nào — state machine guard nằm ở Service */
  async updateOrder(id: string, data: Partial<Order>) {
    return this.orderModel.findByIdAndUpdate(id, data, { new: true }).lean();
  }

  /**
   * Append-only: thêm 1 dòng vào payment_transactions.
   * Ném DuplicateKey (11000) nếu providerTxnId đã tồn tại — caller bắt để idempotency.
   */
  async appendTransaction(data: Partial<PaymentTransaction>) {
    return this.txnModel.create(data);
  }

  async findTransactionByProviderTxnId(providerTxnId: string) {
    return this.txnModel.findOne({ providerTxnId }).lean();
  }

  async listTransactions(orderId: string) {
    return this.txnModel.find({ orderId: new Types.ObjectId(orderId) }).sort({ createdAt: 1 }).lean();
  }

  /** Sinh mã đơn theo format ORD-YYYYMMDD-NNN */
  async generateOrderCode(): Promise<string> {
    const today = new Date();
    const prefix = `ORD-${today.getFullYear()}${String(today.getMonth() + 1).padStart(2, '0')}${String(today.getDate()).padStart(2, '0')}`;
    const count = await this.orderModel.countDocuments({
      code: { $regex: `^${prefix}` },
    });
    return `${prefix}-${String(count + 1).padStart(3, '0')}`;
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/ecommerce/src/order/order.repository.ts
git commit -m "feat(ecom-order): OrderRepository với CRUD + append-only transactions"
```

---

## Task E2-03: CheckoutService — Saga reserve + tạo Order

**Files:**
- Create: `apps/ecommerce/src/order/checkout.service.ts`
- Create: `apps/ecommerce/src/order/reserve.consumer.ts`

**Interfaces:**
- Consumes: `CartService.getCart`, `OrderRepository`, BullMQ `ORDER_QUEUE` (emit `STOCK_RESERVE_REQUESTED`) và nhận reply `STOCK_RESERVED` / `STOCK_RESERVE_FAILED`
- Produces: `CheckoutService.checkout(customerId, dto): Promise<Order>`

- [ ] **Step 1: Tạo CheckoutService**

```typescript
// apps/ecommerce/src/order/checkout.service.ts
import {
  BadRequestException, Injectable, Logger, ServiceUnavailableException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { InjectQueue } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { QUEUES, EVENTS } from '@app/events';
import { CartService } from '../cart/cart.service';
import { OrderRepository } from './order.repository';
import { CheckoutDto } from './dto/checkout.dto';
import {
  FulfillmentStatus, Order, OrderStatus, PaymentMethod, PaymentStatus,
} from './schemas/order.schema';

@Injectable()
export class CheckoutService {
  private readonly logger = new Logger(CheckoutService.name);

  constructor(
    private readonly cartService: CartService,
    private readonly orderRepo: OrderRepository,
    private readonly config: ConfigService,
    @InjectQueue(QUEUES.ORDER) private readonly orderQueue: Queue,
  ) {}

  async checkout(customerId: string, dto: CheckoutDto): Promise<Order> {
    const cart = await this.cartService.getCart(customerId);
    if (!cart.items?.length) throw new BadRequestException('Giỏ hàng trống');

    const hasPrintItems = cart.items.some((i) => i.isPrintItem);

    // Gate: đơn có ly-in bắt buộc ONLINE (make-to-order trả trước)
    if (hasPrintItems && dto.paymentMethod === PaymentMethod.COD) {
      throw new BadRequestException(
        'Đơn có sản phẩm in custom phải thanh toán ONLINE (trả trước)',
      );
    }

    // Tính tiền
    const subtotal = cart.items.reduce((sum, i) => sum + i.unitPrice * i.quantity, 0);
    const shippingFee = 0; // v1: miễn phí ship
    const total = subtotal + shippingFee;

    // Lấy địa chỉ từ customerId + addressId (đọc từ customer collection qua auth module)
    // v1: dùng địa chỉ mặc định → TODO: inject CustomerRepository nếu cần đọc addressId cụ thể
    const shippingAddress = {
      recipientName: 'Khách hàng',
      phone: '0000000000',
      line: dto.addressId, // placeholder — Week 3 sẽ join customer.addresses
      ward: '', district: '', province: '',
    };

    const deadlineMinutes = this.config.get<number>('PAYMENT_DEADLINE_MINUTES') ?? 30;
    const paymentDeadline = dto.paymentMethod === PaymentMethod.ONLINE
      ? new Date(Date.now() + deadlineMinutes * 60 * 1000)
      : null;

    const code = await this.orderRepo.generateOrderCode();

    // Tạo Order ngay (optimistic) — nếu reserve fail sẽ cancel sau
    const order = await this.orderRepo.createOrder({
      code,
      customerId: customerId as any,
      items: cart.items.map((i) => ({
        sku: i.sku,
        name: i.sku, // v1: dùng sku làm tên; Week 3: enrich từ catalog
        unitPrice: i.unitPrice,
        quantity: i.quantity,
        isPrintItem: i.isPrintItem,
        designFile: i.designFile,
        designId: i.designId,
      })),
      shippingAddress: shippingAddress as any,
      subtotal,
      shippingFee,
      total,
      paymentMethod: dto.paymentMethod,
      paymentStatus: PaymentStatus.UNPAID,
      orderStatus: OrderStatus.PLACED,
      fulfillmentStatus: FulfillmentStatus.NONE,
      hasPrintItems,
      paymentDeadline,
      placedAt: new Date(),
    });

    // Phát STOCK_RESERVE_REQUESTED — WMS sẽ reply STOCK_RESERVED hoặc STOCK_RESERVE_FAILED
    await this.orderQueue.add(EVENTS.STOCK_RESERVE_REQUESTED, {
      orderId: order._id.toString(),
      items: cart.items.map((i) => ({ sku: i.sku, quantity: i.quantity })),
      preferWarehouse: 'CENTRAL',
    });

    this.logger.log(`Checkout OK: order ${code} → chờ WMS reserve`);

    // Nếu COD: tạo delayed job auto-confirm sau khi reserve xong (xem reserve.consumer.ts)
    // Nếu ONLINE: tạo delayed job auto-cancel sau paymentDeadline
    if (dto.paymentMethod === PaymentMethod.ONLINE) {
      await this.orderQueue.add(
        'auto.cancel',
        { orderId: order._id.toString() },
        { delay: deadlineMinutes * 60 * 1000, jobId: `auto-cancel:${order._id}` },
      );
    }

    return order as any;
  }
}
```

- [ ] **Step 2: Tạo ReserveConsumer — nhận reply từ WMS**

```typescript
// apps/ecommerce/src/order/reserve.consumer.ts
import { Processor, WorkerHost, OnWorkerEvent } from '@nestjs/bullmq';
import { Job } from 'bullmq';
import { Logger } from '@nestjs/common';
import { EVENTS, QUEUES } from '@app/events';
import { OrderRepository } from './order.repository';
import { OrderService } from './order.service';

/**
 * Consumer nhận reply từ WMS sau khi xử lý STOCK_RESERVE_REQUESTED:
 *   - STOCK_RESERVED → cập nhật fulfillWarehouseId, chuyển sang bước tiếp
 *   - STOCK_RESERVE_FAILED → cancel đơn, trả lại cart
 *   - auto.cancel → đơn ONLINE quá hạn chưa trả → cancel
 */
@Processor(QUEUES.ORDER)
export class ReserveConsumer extends WorkerHost {
  private readonly logger = new Logger(ReserveConsumer.name);

  constructor(
    private readonly orderRepo: OrderRepository,
    private readonly orderService: OrderService,
  ) {
    super();
  }

  async process(job: Job): Promise<void> {
    switch (job.name) {
      case EVENTS.STOCK_RESERVED:
        await this.handleReserved(job);
        break;
      case EVENTS.STOCK_RESERVE_FAILED:
        await this.handleReserveFailed(job);
        break;
      case 'auto.cancel':
        await this.handleAutoCancel(job);
        break;
      default:
        // Bỏ qua job không thuộc consumer này
    }
  }

  private async handleReserved(job: Job) {
    const { orderId, fulfillWarehouseId } = job.data;
    const order = await this.orderRepo.findById(orderId);
    if (!order) return;
    // Cập nhật fulfillWarehouseId rồi chuyển flow tiếp theo qua OrderService
    await this.orderRepo.updateOrder(orderId, { fulfillWarehouseId });
    await this.orderService.onStockReserved(orderId);
    this.logger.log(`Reserve OK: order ${orderId} → warehouse ${fulfillWarehouseId}`);
  }

  private async handleReserveFailed(job: Job) {
    const { orderId, reason } = job.data;
    const order = await this.orderRepo.findById(orderId);
    if (!order) return;
    await this.orderService.cancelOrder(orderId, `Reserve thất bại: ${reason}`);
    this.logger.warn(`Reserve FAILED: order ${orderId} → đã cancel`);
  }

  private async handleAutoCancel(job: Job) {
    const { orderId } = job.data;
    const order = await this.orderRepo.findById(orderId);
    if (!order) return;
    // Chỉ cancel nếu vẫn còn UNPAID (chưa thanh toán)
    const { PaymentStatus } = await import('./schemas/order.schema');
    if (order.paymentStatus !== PaymentStatus.UNPAID) return;
    await this.orderService.cancelOrder(orderId, 'Quá hạn thanh toán (30 phút)');
    this.logger.warn(`Auto-cancel: order ${orderId} quá hạn thanh toán`);
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add apps/ecommerce/src/order/checkout.service.ts apps/ecommerce/src/order/reserve.consumer.ts
git commit -m "feat(ecom-order): CheckoutService (saga reserve) + ReserveConsumer (auto-cancel)"
```

---

## Task E2-04: OrderService — State machine + fulfillment consumers

**Files:**
- Create: `apps/ecommerce/src/order/order.service.ts`
- Create: `apps/ecommerce/src/order/order.consumer.ts`

**Interfaces:**
- Consumes: `OrderRepository`, BullMQ queues ORDER/PRINT/SHIPMENT
- Produces: `onStockReserved`, `onPaymentSuccess`, `cancelOrder`, `returnOrder` — được gọi từ consumers và controllers

- [ ] **Step 1: Tạo OrderService (state machine)**

```typescript
// apps/ecommerce/src/order/order.service.ts
import { BadRequestException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectQueue } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { EVENTS, QUEUES } from '@app/events';
import { OrderRepository } from './order.repository';
import {
  FulfillmentStatus, OrderStatus, PaymentMethod, PaymentStatus,
} from './schemas/order.schema';
import { TxnStatus, TxnType } from './schemas/payment-transaction.schema';

@Injectable()
export class OrderService {
  private readonly logger = new Logger(OrderService.name);

  constructor(
    private readonly repo: OrderRepository,
    @InjectQueue(QUEUES.ORDER) private readonly orderQueue: Queue,
  ) {}

  async findById(id: string) {
    const order = await this.repo.findById(id);
    if (!order) throw new NotFoundException('Đơn hàng không tồn tại');
    return order;
  }

  async listByCustomer(customerId: string) {
    return this.repo.listByCustomer(customerId);
  }

  /**
   * Gọi sau khi WMS reply STOCK_RESERVED.
   * COD → confirm ngay. ONLINE → chờ thanh toán.
   */
  async onStockReserved(orderId: string) {
    const order = await this.repo.findById(orderId);
    if (!order) return;

    if (order.paymentMethod === PaymentMethod.COD) {
      // COD: xác nhận ngay → ready to pick
      await this.repo.updateOrder(orderId, {
        orderStatus: OrderStatus.CONFIRMED,
        fulfillmentStatus: FulfillmentStatus.READY_TO_PICK,
      });
      await this.orderQueue.add(EVENTS.ORDER_READY_TO_FULFILL, {
        orderId,
        fulfillWarehouseId: order.fulfillWarehouseId,
        items: order.items.map((i) => ({ sku: i.sku, quantity: i.quantity })),
        shippingAddress: order.shippingAddress,
        recipient: {
          name: (order.shippingAddress as any).recipientName,
          phone: (order.shippingAddress as any).phone,
        },
        paymentMethod: 'COD',
      });
      this.logger.log(`COD order ${orderId} → CONFIRMED, READY_TO_PICK`);
    }
    // ONLINE: chờ webhook payment → onPaymentSuccess
  }

  /**
   * Gọi khi payment webhook xác nhận thanh toán thành công.
   * Cập nhật PAID, xác nhận đơn, phát event tiếp theo.
   */
  async onPaymentSuccess(orderId: string, providerTxnId: string, amount: number, provider: string) {
    const order = await this.repo.findById(orderId);
    if (!order) throw new NotFoundException('Đơn hàng không tồn tại');

    // Idempotency: nếu đã PAID rồi thì bỏ qua (webhook có thể đến 2 lần)
    if (order.paymentStatus === PaymentStatus.PAID) {
      this.logger.warn(`Webhook trùng: order ${orderId} đã PAID`);
      return order;
    }

    // Append transaction CHARGE SUCCESS
    try {
      await this.repo.appendTransaction({
        orderId: order._id as any,
        type: TxnType.CHARGE,
        provider,
        amount,
        status: TxnStatus.SUCCESS,
        providerTxnId,
        raw: {},
      });
    } catch (e: any) {
      if (e.code === 11000) {
        this.logger.warn(`Duplicate providerTxnId ${providerTxnId} → bỏ qua`);
        return order;
      }
      throw e;
    }

    const nextFulfillment = order.hasPrintItems
      ? FulfillmentStatus.AWAITING_PRINT
      : FulfillmentStatus.READY_TO_PICK;

    await this.repo.updateOrder(orderId, {
      paymentStatus: PaymentStatus.PAID,
      orderStatus: OrderStatus.CONFIRMED,
      fulfillmentStatus: nextFulfillment,
    });

    if (order.hasPrintItems) {
      // Phát lệnh in cho WMS
      await this.orderQueue.add(EVENTS.PRINT_REQUESTED, {
        orderId,
        items: order.items
          .filter((i) => i.isPrintItem)
          .map((i) => ({ sku: i.sku, quantity: i.quantity, designFile: i.designFile })),
      });
      this.logger.log(`Order ${orderId} → AWAITING_PRINT, phát print.requested`);
    } else {
      await this.orderQueue.add(EVENTS.ORDER_READY_TO_FULFILL, {
        orderId,
        fulfillWarehouseId: order.fulfillWarehouseId,
        items: order.items.map((i) => ({ sku: i.sku, quantity: i.quantity })),
        shippingAddress: order.shippingAddress,
        recipient: {
          name: (order.shippingAddress as any).recipientName,
          phone: (order.shippingAddress as any).phone,
        },
        paymentMethod: 'ONLINE',
      });
      this.logger.log(`Order ${orderId} → READY_TO_PICK, phát order.ready_to_fulfill`);
    }

    return this.repo.findById(orderId);
  }

  /** Hủy đơn — release reserve qua event, cập nhật trạng thái */
  async cancelOrder(orderId: string, reason = '') {
    const order = await this.repo.findById(orderId);
    if (!order) return;

    const cancellable = [FulfillmentStatus.NONE, FulfillmentStatus.AWAITING_PRINT, FulfillmentStatus.READY_TO_PICK];
    if (!cancellable.includes(order.fulfillmentStatus as any)) {
      throw new BadRequestException('Không thể hủy đơn đã xuất kho trở lên');
    }

    // Ly-in: chỉ hủy được trước AWAITING_PRINT
    if (order.hasPrintItems && order.fulfillmentStatus === FulfillmentStatus.AWAITING_PRINT) {
      throw new BadRequestException('Đơn ly-in đã chuyển sang in — không thể hủy');
    }

    await this.repo.updateOrder(orderId, {
      orderStatus: OrderStatus.CANCELLED,
      cancelReason: reason,
    });

    // Phát để WMS release reserve
    await this.orderQueue.add(EVENTS.ORDER_CANCELLED, {
      orderId,
      reason,
    });

    // Nếu đã PAID → hoàn tiền pending
    if (order.paymentStatus === PaymentStatus.PAID) {
      await this.repo.updateOrder(orderId, { paymentStatus: PaymentStatus.REFUND_PENDING });
    }

    this.logger.log(`Order ${orderId} → CANCELLED`);
  }

  /** Hoàn hàng RMA — sau DELIVERED, trong hạn 7 ngày */
  async returnOrder(orderId: string, customerId: string) {
    const order = await this.repo.findById(orderId);
    if (!order) throw new NotFoundException('Đơn hàng không tồn tại');

    if (order.fulfillmentStatus !== FulfillmentStatus.DELIVERED) {
      throw new BadRequestException('Chỉ hoàn được đơn đã giao thành công');
    }

    // Check hạn 7 ngày
    const RETURN_DAYS = 7;
    const deliveredAt = order.updatedAt as Date;
    if (Date.now() - new Date(deliveredAt).getTime() > RETURN_DAYS * 86400 * 1000) {
      throw new BadRequestException('Đã quá hạn đổi trả (7 ngày)');
    }

    // Ly-in custom: không hoàn
    if (order.items.some((i) => i.isPrintItem)) {
      throw new BadRequestException('Sản phẩm in custom không nhận hoàn (trừ lỗi/hỏng — liên hệ shop)');
    }

    await this.repo.updateOrder(orderId, {
      fulfillmentStatus: FulfillmentStatus.RETURNED,
    });

    await this.orderQueue.add(EVENTS.ORDER_RETURNED, {
      orderId,
      items: order.items.map((i) => ({ sku: i.sku, quantity: i.quantity })),
    });

    this.logger.log(`Order ${orderId} → RMA returned`);
    return this.repo.findById(orderId);
  }

  // ── Gọi từ OrderConsumer ──────────────────────────────────────────────────

  async onGoodsIssued(orderId: string, goodsIssueId: string) {
    await this.repo.updateOrder(orderId, { fulfillmentStatus: FulfillmentStatus.ISSUED });
    this.logger.log(`Order ${orderId} → ISSUED (goodsIssueId: ${goodsIssueId})`);
  }

  async onPrintCompleted(orderId: string, printJobId: string) {
    const order = await this.repo.findById(orderId);
    if (!order) return;

    // Gán printJobId vào item tương ứng
    const items = order.items.map((item) =>
      item.isPrintItem && !item.printJobId ? { ...item, printJobId } : item,
    );
    await this.repo.updateOrder(orderId, { items } as any);

    // Kiểm tất cả ly-in đã có printJobId chưa
    const allPrinted = items.filter((i) => i.isPrintItem).every((i) => !!i.printJobId);
    if (allPrinted) {
      await this.repo.updateOrder(orderId, { fulfillmentStatus: FulfillmentStatus.READY_TO_PICK });
      const updated = await this.repo.findById(orderId);
      await this.orderQueue.add(EVENTS.ORDER_READY_TO_FULFILL, {
        orderId,
        fulfillWarehouseId: updated?.fulfillWarehouseId,
        items: items.map((i) => ({ sku: i.sku, quantity: i.quantity })),
        shippingAddress: updated?.shippingAddress,
        recipient: {
          name: (updated?.shippingAddress as any)?.recipientName,
          phone: (updated?.shippingAddress as any)?.phone,
        },
        paymentMethod: 'ONLINE',
      });
      this.logger.log(`Order ${orderId} → READY_TO_PICK (all print done)`);
    }
  }

  async onShipped(orderId: string) {
    await this.repo.updateOrder(orderId, { fulfillmentStatus: FulfillmentStatus.SHIPPED });
  }

  async onDelivered(orderId: string) {
    const order = await this.repo.findById(orderId);
    if (!order) return;
    const updates: any = {
      fulfillmentStatus: FulfillmentStatus.DELIVERED,
      orderStatus: OrderStatus.CLOSED,
    };
    // COD: ghi nhận thanh toán khi giao
    if (order.paymentMethod === PaymentMethod.COD) {
      updates.paymentStatus = PaymentStatus.PAID;
    }
    await this.repo.updateOrder(orderId, updates);
  }
}
```

- [ ] **Step 2: Tạo OrderConsumer (goods.issued + print.completed)**

```typescript
// apps/ecommerce/src/order/order.consumer.ts
import { Processor, WorkerHost } from '@nestjs/bullmq';
import { Job } from 'bullmq';
import { Logger } from '@nestjs/common';
import { EVENTS, QUEUES } from '@app/events';
import { OrderService } from './order.service';

/** Consumer nhận events từ WMS liên quan đến fulfillment đơn hàng */
@Processor(QUEUES.SHIPMENT)
export class ShipmentConsumer extends WorkerHost {
  private readonly logger = new Logger(ShipmentConsumer.name);
  constructor(private readonly orderService: OrderService) { super(); }

  async process(job: Job): Promise<void> {
    const { orderId, shipmentId } = job.data;
    switch (job.name) {
      case EVENTS.SHIPMENT_SHIPPED:
        await this.orderService.onShipped(orderId);
        break;
      case EVENTS.SHIPMENT_DELIVERED:
        await this.orderService.onDelivered(orderId);
        break;
      case EVENTS.GOODS_ISSUED:
        await this.orderService.onGoodsIssued(orderId, job.data.goodsIssueId);
        break;
      case EVENTS.PRINT_COMPLETED:
        await this.orderService.onPrintCompleted(orderId, job.data.printJobId);
        break;
    }
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add apps/ecommerce/src/order/order.service.ts apps/ecommerce/src/order/order.consumer.ts
git commit -m "feat(ecom-order): OrderService state machine + ShipmentConsumer fulfillment"
```

---

## Task E2-05: PaymentService — VNPay webhook + COD

**Files:**
- Create: `apps/ecommerce/src/order/payment.service.ts`
- Create: `apps/ecommerce/src/order/payment.controller.ts`

**Interfaces:**
- Consumes: `OrderService.onPaymentSuccess`, VNPay sandbox (HMAC-SHA512)
- Produces: `GET /payment/vnpay-return`, `POST /payment/vnpay-ipn` (webhook), `GET /payment/create-url/:orderId`

- [ ] **Step 1: Tạo PaymentService**

```typescript
// apps/ecommerce/src/order/payment.service.ts
import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import * as crypto from 'crypto';
import * as querystring from 'querystring';
import { OrderRepository } from './order.repository';
import { OrderService } from './order.service';
import { PaymentMethod, PaymentStatus } from './schemas/order.schema';

@Injectable()
export class PaymentService {
  private readonly logger = new Logger(PaymentService.name);

  constructor(
    private readonly config: ConfigService,
    private readonly orderRepo: OrderRepository,
    private readonly orderService: OrderService,
  ) {}

  /**
   * Tạo URL redirect sang cổng VNPay sandbox.
   * Tài liệu: https://sandbox.vnpayment.vn/apis/
   */
  async createVnpayUrl(orderId: string, ipAddr: string): Promise<string> {
    const order = await this.orderRepo.findById(orderId);
    if (!order) throw new BadRequestException('Đơn hàng không tồn tại');
    if (order.paymentMethod !== PaymentMethod.ONLINE) {
      throw new BadRequestException('Đơn này không dùng thanh toán online');
    }
    if (order.paymentStatus === PaymentStatus.PAID) {
      throw new BadRequestException('Đơn đã thanh toán');
    }

    const tmnCode = this.config.get<string>('VNPAY_TMN_CODE')!;
    const secretKey = this.config.get<string>('VNPAY_SECRET_KEY')!;
    const returnUrl = this.config.get<string>('VNPAY_RETURN_URL')!;
    const vnpUrl = 'https://sandbox.vnpayment.vn/paymentv2/vpcpay.html';

    const now = new Date();
    const createDate = now.toISOString().replace(/[-T:.Z]/g, '').slice(0, 14);
    const expireDate = new Date(now.getTime() + 30 * 60 * 1000)
      .toISOString().replace(/[-T:.Z]/g, '').slice(0, 14);

    const params: Record<string, string> = {
      vnp_Version: '2.1.0',
      vnp_Command: 'pay',
      vnp_TmnCode: tmnCode,
      vnp_Amount: String(order.total * 100), // VNPay nhân 100
      vnp_CurrCode: 'VND',
      vnp_TxnRef: order.code, // mã đơn làm ref
      vnp_OrderInfo: `Thanh toan don hang ${order.code}`,
      vnp_OrderType: 'other',
      vnp_Locale: 'vn',
      vnp_ReturnUrl: returnUrl,
      vnp_IpAddr: ipAddr,
      vnp_CreateDate: createDate,
      vnp_ExpireDate: expireDate,
    };

    const sortedParams = Object.keys(params)
      .sort()
      .reduce((acc, k) => ({ ...acc, [k]: params[k] }), {} as Record<string, string>);

    const signData = querystring.stringify(sortedParams, undefined, undefined, { encodeURIComponent: (s) => s });
    const hmac = crypto.createHmac('sha512', secretKey);
    const signed = hmac.update(Buffer.from(signData, 'utf-8')).digest('hex');

    sortedParams['vnp_SecureHash'] = signed;
    return `${vnpUrl}?${querystring.stringify(sortedParams)}`;
  }

  /**
   * Xử lý IPN (Instant Payment Notification) từ VNPay.
   * Phải trả về { RspCode: '00', Message: 'success' } khi OK.
   * Idempotent: gửi 2 lần cũng an toàn nhờ providerTxnId unique index.
   */
  async handleVnpayIpn(query: Record<string, string>): Promise<{ RspCode: string; Message: string }> {
    const secretKey = this.config.get<string>('VNPAY_SECRET_KEY')!;

    const secureHash = query['vnp_SecureHash'];
    const { vnp_SecureHash, vnp_SecureHashType, ...params } = query;

    const sortedParams = Object.keys(params)
      .sort()
      .reduce((acc, k) => ({ ...acc, [k]: params[k] }), {} as Record<string, string>);

    const signData = querystring.stringify(sortedParams, undefined, undefined, { encodeURIComponent: (s) => s });
    const hmac = crypto.createHmac('sha512', secretKey);
    const signed = hmac.update(Buffer.from(signData, 'utf-8')).digest('hex');

    if (signed !== secureHash) {
      this.logger.warn('VNPay IPN: chữ ký không khớp');
      return { RspCode: '97', Message: 'Invalid signature' };
    }

    const orderCode = query['vnp_TxnRef'];
    const providerTxnId = query['vnp_TransactionNo'];
    const responseCode = query['vnp_ResponseCode'];
    const amount = parseInt(query['vnp_Amount'] ?? '0', 10) / 100;

    const order = await this.orderRepo.findByCode(orderCode);
    if (!order) return { RspCode: '01', Message: 'Order not found' };

    if (responseCode === '00') {
      await this.orderService.onPaymentSuccess(
        order._id.toString(), providerTxnId, amount, 'VNPAY',
      );
      return { RspCode: '00', Message: 'success' };
    } else {
      this.logger.warn(`VNPay IPN: thanh toán thất bại responseCode=${responseCode}`);
      return { RspCode: '00', Message: 'confirmed failure' };
    }
  }
}
```

- [ ] **Step 2: Tạo PaymentController**

```typescript
// apps/ecommerce/src/order/payment.controller.ts
import { Controller, Get, Param, Query, Req, UseGuards } from '@nestjs/common';
import { Request } from 'express';
import { ApiBearerAuth, ApiOperation, ApiParam, ApiTags } from '@nestjs/swagger';
import { JwtAuthGuard } from '@app/auth';
import { PaymentService } from './payment.service';

@ApiTags('payment')
@Controller('payment')
export class PaymentController {
  constructor(private readonly svc: PaymentService) {}

  /** Tạo URL thanh toán VNPay sandbox — khách redirect sang cổng */
  @Get('vnpay/create-url/:orderId')
  @ApiBearerAuth()
  @UseGuards(JwtAuthGuard)
  @ApiOperation({ summary: 'Lấy URL thanh toán VNPay cho đơn ONLINE' })
  @ApiParam({ name: 'orderId', example: '64abc...' })
  createVnpayUrl(@Param('orderId') orderId: string, @Req() req: Request) {
    const ip = req.headers['x-forwarded-for'] as string ?? req.socket.remoteAddress ?? '127.0.0.1';
    return this.svc.createVnpayUrl(orderId, ip).then((url) => ({ payUrl: url }));
  }

  /**
   * IPN endpoint — VNPay gọi server-to-server sau khi thanh toán.
   * KHÔNG cần auth (VNPay gọi trực tiếp, verify bằng HMAC).
   * Cần ngrok/localtunnel để test local.
   */
  @Get('vnpay/ipn')
  @ApiOperation({ summary: 'VNPay IPN webhook (server-to-server, không cần auth)' })
  handleVnpayIpn(@Query() query: Record<string, string>) {
    return this.svc.handleVnpayIpn(query);
  }

  /** Return URL — VNPay redirect khách về sau khi thanh toán */
  @Get('vnpay/return')
  @ApiOperation({ summary: 'VNPay return URL (redirect từ cổng về, không cần auth)' })
  vnpayReturn(@Query() query: Record<string, string>) {
    // v1: chỉ trả JSON status — FE sẽ dùng để hiển thị kết quả
    const success = query['vnp_ResponseCode'] === '00';
    return { success, orderCode: query['vnp_TxnRef'], message: success ? 'Thanh toán thành công' : 'Thanh toán thất bại' };
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add apps/ecommerce/src/order/payment.service.ts apps/ecommerce/src/order/payment.controller.ts
git commit -m "feat(ecom-payment): PaymentService VNPay sandbox + IPN webhook idempotent"
```

---

## Task E2-06: OrderController + OrderModule + wiring

**Files:**
- Create: `apps/ecommerce/src/order/order.controller.ts`
- Create: `apps/ecommerce/src/order/order.module.ts`
- Modify: `apps/ecommerce/src/ecommerce.module.ts`

- [ ] **Step 1: Tạo OrderController**

```typescript
// apps/ecommerce/src/order/order.controller.ts
import { Body, Controller, Get, Param, Post, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiParam, ApiTags } from '@nestjs/swagger';
import { CurrentUser, JwtAuthGuard } from '@app/auth';
import { CheckoutService } from './checkout.service';
import { OrderService } from './order.service';
import { CheckoutDto } from './dto/checkout.dto';
import { CancelOrderDto } from './dto/order.dto';

@ApiTags('orders')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Controller('orders')
export class OrderController {
  constructor(
    private readonly checkoutSvc: CheckoutService,
    private readonly orderSvc: OrderService,
  ) {}

  @Post('checkout')
  @ApiOperation({ summary: 'Đặt hàng từ giỏ — reserve tồn + tạo Order' })
  checkout(@CurrentUser('sub') customerId: string, @Body() dto: CheckoutDto) {
    return this.checkoutSvc.checkout(customerId, dto);
  }

  @Get()
  @ApiOperation({ summary: 'Danh sách đơn hàng của tôi' })
  listOrders(@CurrentUser('sub') customerId: string) {
    return this.orderSvc.listByCustomer(customerId);
  }

  @Get(':id')
  @ApiOperation({ summary: 'Chi tiết đơn hàng (3 trục trạng thái)' })
  @ApiParam({ name: 'id', description: 'ObjectId của Order' })
  getOrder(@Param('id') id: string) {
    return this.orderSvc.findById(id);
  }

  @Post(':id/cancel')
  @ApiOperation({ summary: 'Hủy đơn (chỉ trước khi ISSUED, ly-in trước khi AWAITING_PRINT)' })
  @ApiParam({ name: 'id', description: 'ObjectId của Order' })
  cancelOrder(@Param('id') id: string, @Body() dto: CancelOrderDto) {
    return this.orderSvc.cancelOrder(id, dto.reason);
  }

  @Post(':id/return')
  @ApiOperation({ summary: 'Hoàn hàng RMA (sau DELIVERED, trong 7 ngày, không áp dụng ly-in custom)' })
  @ApiParam({ name: 'id', description: 'ObjectId của Order' })
  returnOrder(@Param('id') id: string, @CurrentUser('sub') customerId: string) {
    return this.orderSvc.returnOrder(id, customerId);
  }
}
```

- [ ] **Step 2: Tạo OrderModule**

```typescript
// apps/ecommerce/src/order/order.module.ts
import { BullModule } from '@nestjs/bullmq';
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { QUEUES } from '@app/events';
import { CartModule } from '../cart/cart.module';
import { Order, OrderSchema } from './schemas/order.schema';
import { PaymentTransaction, PaymentTransactionSchema } from './schemas/payment-transaction.schema';
import { OrderRepository } from './order.repository';
import { OrderService } from './order.service';
import { CheckoutService } from './checkout.service';
import { PaymentService } from './payment.service';
import { OrderController } from './order.controller';
import { PaymentController } from './payment.controller';
import { ReserveConsumer } from './reserve.consumer';
import { ShipmentConsumer } from './order.consumer';

@Module({
  imports: [
    MongooseModule.forFeature([
      { name: Order.name, schema: OrderSchema },
      { name: PaymentTransaction.name, schema: PaymentTransactionSchema },
    ]),
    BullModule.registerQueue(
      { name: QUEUES.ORDER },
      { name: QUEUES.SHIPMENT },
    ),
    CartModule,
  ],
  controllers: [OrderController, PaymentController],
  providers: [
    OrderRepository, OrderService, CheckoutService, PaymentService,
    ReserveConsumer, ShipmentConsumer,
  ],
  exports: [OrderService],
})
export class OrderModule {}
```

- [ ] **Step 3: Import OrderModule vào EcommerceModule**

```typescript
// apps/ecommerce/src/ecommerce.module.ts — thêm vào imports[]:
import { OrderModule } from './order/order.module';
// OrderModule, // order/checkout/payment
```

- [ ] **Step 4: Thêm VNPay env vào .env.example**

```bash
# Thêm vào file .env và .env.example:
VNPAY_TMN_CODE=your_tmn_code_here
VNPAY_SECRET_KEY=your_secret_key_here
VNPAY_RETURN_URL=http://localhost:3002/api/shop/payment/vnpay/return
PAYMENT_DEADLINE_MINUTES=30
```

- [ ] **Step 5: Smoke test**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm start:ecom
```

Swagger `http://localhost:3002/api/shop/docs`:
- Tag `orders`: POST /checkout, GET /, GET /:id, POST /:id/cancel, POST /:id/return
- Tag `payment`: GET /vnpay/create-url/:orderId, GET /vnpay/ipn, GET /vnpay/return

- [ ] **Step 6: Test manual COD flow**

```
1. POST /auth/login → lấy accessToken
2. POST /cart/items (sku=LID-M, quantity=2)
3. GET /cart → verify items
4. POST /orders/checkout { addressId: "123", paymentMethod: "COD" }
5. GET /orders/:id → verify orderStatus=CONFIRMED, fulfillmentStatus=READY_TO_PICK
```

- [ ] **Step 7: Commit**

```bash
git add apps/ecommerce/src/order/ apps/ecommerce/src/ecommerce.module.ts
git commit -m "feat(ecom-order): OrderModule đầy đủ (checkout/order/payment/consumers)"
```

---

## ✅ Checklist Definition of Done — Tuần 2

- [ ] `POST /orders/checkout` COD → `{PLACED→CONFIRMED, UNPAID, READY_TO_PICK}` ✓
- [ ] `POST /orders/checkout` ONLINE → `{PLACED, UNPAID, NONE}` + lấy VNPay URL ✓
- [ ] VNPay IPN mock → `{CONFIRMED, PAID, READY_TO_PICK}` (hàng thường) ✓
- [ ] VNPay IPN mock → `{CONFIRMED, PAID, AWAITING_PRINT}` (có ly-in) ✓
- [ ] `POST /orders/:id/cancel` trước ISSUED → `CANCELLED` + phát release ✓
- [ ] Checkout ly-in với COD → 400 BadRequest ✓
- [ ] Auto-cancel sau 30 phút (dùng BullMQ delayed job delay=1ms để test) ✓
- [ ] Webhook trùng providerTxnId → không duplicate transaction ✓
- [ ] `POST /orders/:id/return` sau DELIVERED → `RETURNED` ✓
