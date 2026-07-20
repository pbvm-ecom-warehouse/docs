# Spec thiết kế — Code hóa module Shipping (P7) trong `be`

> Trạng thái: ✅ Design đã duyệt — sẵn sàng viết implementation plan.
> Ngày: 2026-07-20.
> Bối cảnh: `docs/shipping/*.md` (use-cases, data-model, workflow) và `docs/superpowers/specs/2026-06-04-shipping-design.md` đã đặc tả đầy đủ nghiệp vụ module Shipping từ 2026-06-04, nhưng đó là **tài liệu markdown thuần** — kế hoạch `2026-06-04-shipping.md` chỉ tạo/sửa file `.md`, KHÔNG đụng tới code trong `be`. Backend `apps/wms` hiện **chưa có bất kỳ module `shipping/`, `carrier`, `shipment` nào**. Spec này là bước code hóa: chuyển đặc tả đã duyệt thành NestJS module thật trong `be`.

## 1. Mục tiêu & phạm vi

Hiện thực module **Shipping** trong `apps/wms` để lấp gap P7 (giao hàng): từ `goods.issued` (WMS đã xuất kho xong) đến khi đơn `CLOSED`/`CANCELLED`. Theo đúng data-model/use-cases/workflow đã duyệt ở `docs/shipping/`; không thiết kế lại nghiệp vụ, chỉ ánh xạ sang code + giải quyết các gap kỹ thuật phát sinh khi hiện thực (role thiếu, nguồn dữ liệu snapshot).

**Không đổi so với docs/shipping/*.md:**
- Enum `shipmentStatus`: `PENDING / PICKED_UP / IN_TRANSIT / DELIVERED / FAILED / RETURNING / RETURNED`.
- 3 mốc phát event: `IN_TRANSIT → shipment.shipped`, `DELIVERED → shipment.delivered`, `RETURNED → shipment.returned`.
- 1 đơn = 1 vận đơn (1:1 với `GoodsIssue`).
- YAGNI: không tích hợp API hãng (GHN/GHTK...), không tính `shippingFee`, không đối soát COD remittance.

## 2. Gap phát hiện khi code hóa (không có trong docs gốc)

### 2.1. Role `SHIPPER` chưa tồn tại

`libs/auth/src/roles.ts` → `WmsRole` hiện chỉ có `ADMIN | MANAGER | RECEIVER | PICKER | PRINTER | COUNTER`. Docs dùng actor `SHIPPER` cho UC-S02/S03/S04/S05.

**Quyết định:** thêm `SHIPPER = 'SHIPPER'` vào `WmsRole` enum. Đây là role nghiệp vụ riêng biệt (khác `PICKER` — xuất kho xong là hết việc của PICKER, SHIPPER tiếp quản từ lúc bàn giao hãng vận chuyển).

### 2.2. `GoodsIssue` không giữ snapshot cần cho `Shipment`

`GoodsIssuedPayload` (event `goods.issued`, WMS→Ecom) chỉ mang `{orderId, goodsIssueId}` — tối giản theo đúng nguyên tắc payload ở `events.md`. Nhưng `Shipment` cần `recipient{name,phone,address}`, `paymentMethod`, `codAmount` — dữ liệu này đến từ payload `order.ready_to_fulfill` (Ecom→WMS) lúc tạo `GoodsIssue`, và hiện **không được lưu lại** ở đâu cả (comment trong `goods-issue.schema.ts` xác nhận: *"không lưu... thuộc trách nhiệm module Shipping, đọc lại từ event gốc khi implement"* — nhưng event gốc không được persist nên không thể đọc lại được nếu không lưu).

**Quyết định:** mở rộng `GoodsIssue` schema lưu lại 4 field snapshot lúc `OrderReadyConsumer` tạo phiếu. `ShippingModule` đọc `GoodsIssue` theo `goodsIssueId` khi consume `goods.issued` để dựng `Shipment`. Không sửa `GoodsIssuedPayload` (giữ tối giản, đúng events.md) — không thêm consumer song song lắng nghe `order.ready_to_fulfill` ở Shipping (tránh phải tự đồng bộ thứ tự 2 event).

### 2.3. `SHIPMENT_RETURNED` chưa có consumer bên Ecom

`order.consumer.ts` (Ecommerce, `ShipmentConsumer`) đã xử lý `GOODS_ISSUED`, `PRINT_COMPLETED`, `SHIPMENT_SHIPPED`, `SHIPMENT_DELIVERED` — nhưng thiếu case `SHIPMENT_RETURNED` dù event + payload đã khai báo sẵn trong `libs/events/src/events.ts`. Cần bổ sung case này + `OrderService.onReturned()`.

## 3. Data model — thay đổi schema

### 3.1. Mở rộng `apps/wms/src/goods-issue/schemas/goods-issue.schema.ts`

Thêm vào class `GoodsIssue` (sau `warehouseId`, trước `status`):

```ts
@Prop({ type: Object, required: true })
shippingAddress!: Record<string, unknown>;

@Prop({ type: { name: String, phone: String }, required: true })
recipient!: { name: string; phone: string };

@Prop({ enum: ['COD', 'ONLINE'], required: true })
paymentMethod!: 'COD' | 'ONLINE';

@Prop({ type: Number, default: 0 })
codAmount!: number;
```

Nguồn: 4 field này lấy trực tiếp từ `OrderReadyToFulfillPayload` (đã có sẵn `shippingAddress`, `recipient`, `paymentMethod`, `codAmount` — xem `libs/events/src/events.ts:98-106`), truyền qua `GoodsIssueService.createFromOrderReady(...)`.

Sửa `OrderReadyConsumer` (`apps/wms/src/goods-issue/order-ready.consumer.ts`) để truyền các field này xuống `createFromOrderReady`.

Đây là dữ liệu bất biến của phiếu (snapshot lúc tạo, không đổi theo thời gian) — không phải audit field, không cần thêm vào nhóm audit riêng. `GoodsIssue` vẫn giữ nguyên nhóm "Chứng từ giao dịch" (`timestamps: true`, hủy bằng status).

### 3.2. `apps/wms/src/shipping/schemas/carrier.schema.ts` (mới)

```ts
export enum CarrierStatus {
  ACTIVE = 'ACTIVE',
  INACTIVE = 'INACTIVE',
}

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

  /** Chỗ chừa tích hợp API hãng sau — YAGNI, không dùng vòng này. */
  @Prop({ type: Object })
  apiConfig?: Record<string, unknown>;

  @Prop({ type: Types.ObjectId })
  createdBy?: Types.ObjectId;

  @Prop({ type: Types.ObjectId })
  updatedBy?: Types.ObjectId;

  @Prop({ type: Date, default: null })
  deletedAt?: Date | null;
}
```

Nhóm audit: **Master/config** → `createdBy/updatedBy/createdAt/updatedAt/deletedAt` (soft-delete), theo đúng bảng audit trong `data-and-mongoose.md`.

### 3.3. `apps/wms/src/shipping/schemas/shipment.schema.ts` (mới)

```ts
export enum ShipmentStatus {
  PENDING = 'PENDING',
  PICKED_UP = 'PICKED_UP',
  IN_TRANSIT = 'IN_TRANSIT',
  DELIVERED = 'DELIVERED',
  FAILED = 'FAILED',
  RETURNING = 'RETURNING',
  RETURNED = 'RETURNED',
}

@Schema({ _id: false })
class ShipmentStatusHistoryEntry {
  @Prop({ enum: ShipmentStatus, required: true })
  status!: ShipmentStatus;

  @Prop({ type: Date, required: true })
  at!: Date;

  @Prop({ type: Types.ObjectId })
  by?: Types.ObjectId;

  @Prop()
  note?: string;
}

@Schema({ collection: 'shipments', timestamps: true })
export class Shipment {
  @Prop({ required: true })
  orderId!: string; // id tham chiếu Ecom — KHÔNG đọc chéo ecom_db

  @Prop({ type: Types.ObjectId, required: true, unique: true })
  goodsIssueId!: Types.ObjectId; // 1:1 — unique chặn tạo trùng khi event redeliver

  @Prop({ type: Types.ObjectId, required: true })
  fulfillWarehouseId!: Types.ObjectId;

  @Prop({ type: Types.ObjectId })
  carrierId?: Types.ObjectId;

  @Prop()
  trackingNumber?: string;

  @Prop({ enum: ShipmentStatus, default: ShipmentStatus.PENDING })
  shipmentStatus!: ShipmentStatus;

  @Prop({ type: { name: String, phone: String, address: Object }, required: true })
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
```

Nhóm audit: **Chứng từ giao dịch** → `createdAt/updatedAt` (`timestamps: true`), hủy bằng `shipmentStatus`, KHÔNG soft-delete. `statusHistory[]` tự append, không sửa/xóa dòng cũ.

## 4. State machine `shipmentStatus`

Service enforce transitions hợp lệ, từ chối các bước nhảy không hợp lệ bằng `AppException('SHIPMENT_INVALID_TRANSITION')`:

```
PENDING → PICKED_UP → IN_TRANSIT → DELIVERED
                          ↕
                       FAILED ──retry──► (quay lại IN_TRANSIT)
                       FAILED ──bỏ cuộc──► RETURNING → RETURNED
```

Bảng transition hợp lệ (from → to được phép):
| From | To hợp lệ |
|---|---|
| `PENDING` | `PICKED_UP` |
| `PICKED_UP` | `IN_TRANSIT` |
| `IN_TRANSIT` | `DELIVERED`, `FAILED` |
| `FAILED` | `IN_TRANSIT` (retry), `RETURNING` (bỏ cuộc) |
| `RETURNING` | `RETURNED` |
| `DELIVERED`, `RETURNED` | (terminal — không transition tiếp) |

Side-effects theo transition:
- `→ PICKED_UP`: ghi `statusHistory`.
- `→ IN_TRANSIT` (lần đầu từ `PICKED_UP`): ghi `shippedAt`, phát `EVENTS.SHIPMENT_SHIPPED`.
- `→ IN_TRANSIT` (retry từ `FAILED`): KHÔNG phát lại `shipment.shipped` (Order đã `SHIPPED` rồi, tránh event thừa) — chỉ ghi `statusHistory`. *(Diễn giải kỹ thuật: `docs/shipping/workflow.md` WF-S02 mô tả retry "quay lại WF-S01 từ bước Bàn giao hãng" nhưng không nói rõ có bắn lại event hay không — quyết định này chọn không bắn lại vì `fulfillmentStatus` phía Order đã ở `SHIPPED`, bắn lại là dư thừa, không đổi hệ quả nghiệp vụ.)*
- `→ DELIVERED`: ghi `deliveredAt`, phát `EVENTS.SHIPMENT_DELIVERED`.
- `→ FAILED`: `attempts += 1`, ghi `failReason` + `statusHistory`.
- `→ RETURNING`: ghi `statusHistory` (chưa phát event — hàng chưa về kho).
- `→ RETURNED`: phát `EVENTS.SHIPMENT_RETURNED`.

## 5. Module & file layout

```
apps/wms/src/shipping/
  schemas/carrier.schema.ts
  schemas/shipment.schema.ts
  carrier.repository.ts
  carrier.service.ts
  carrier.controller.ts
  shipment.repository.ts
  shipment.service.ts        (state machine + emit event)
  shipment.controller.ts
  goods-issued.consumer.ts   (@Processor(QUEUES.SHIPMENT), job GOODS_ISSUED → auto-create Shipment)
  dto/carrier.dto.ts
  dto/shipment.dto.ts
  shipping.module.ts
```

`ShippingModule`:
```ts
imports: [
  BullModule.registerQueue({ name: QUEUES.SHIPMENT }),
  MongooseModule.forFeature([Carrier, Shipment]),
  GoodsIssueModule, // export GoodsIssueRepository — đọc snapshot theo goodsIssueId
],
providers: [CarrierRepository, CarrierService, ShipmentRepository, ShipmentService, GoodsIssuedConsumer],
controllers: [CarrierController, ShipmentController],
```

Đăng ký `ShippingModule` vào `AppModule` (wms root).

**Lưu ý kỹ thuật — không xung đột queue:** `goods.issued` hiện được `GoodsIssueService` produce lên `QUEUES.SHIPMENT`, và Ecommerce's `ShipmentConsumer` cũng lắng nghe `QUEUES.SHIPMENT` (2 process/app riêng biệt, cùng đọc 1 Redis queue). WMS tự thêm 1 consumer (`GoodsIssuedConsumer`) trong chính app WMS lắng nghe cùng job `GOODS_ISSUED` trên `QUEUES.SHIPMENT` — an toàn vì BullMQ worker theo `Processor` gắn với `@Processor(QUEUES.SHIPMENT)` chạy trong process WMS, độc lập với worker bên Ecom.

## 6. API endpoints

| Method | Path | Role | UC | Ghi chú |
|---|---|---|---|---|
| POST | `/carriers` | MANAGER, ADMIN | UC-S01 | tạo hãng, `status` mặc định `ACTIVE` |
| PATCH | `/carriers/:id` | MANAGER, ADMIN | UC-S01 | sửa info / đổi `status`; không xóa cứng |
| GET | `/carriers` | SHIPPER, MANAGER, ADMIN | UC-S01 | filter `status` |
| GET | `/shipments` | SHIPPER, MANAGER, ADMIN | UC-S05 | filter `shipmentStatus`/`orderId`/`carrierId`, phân trang `page`/`limit` |
| GET | `/shipments/:id` | SHIPPER, MANAGER, ADMIN | UC-S05 | chi tiết + `statusHistory` |
| PATCH | `/shipments/:id/assign` | SHIPPER, ADMIN | UC-S02 | body `{carrierId, trackingNumber}` — chỉ hợp lệ khi `shipmentStatus=PENDING` |
| PATCH | `/shipments/:id/status` | SHIPPER, ADMIN | UC-S03/S04 | body `{status, note?, failReason?}` — validate qua state machine §4 |

Response DTO theo pattern `dto-conventions.md`: `@Expose()` + `plainToInstance`, `_id → id`, enum khai `@ApiProperty({enum: ...})`, `@Roles` → `— [ROLE1, ROLE2]` trong `summary`.

## 7. Ecommerce side — bổ sung consumer

`apps/ecommerce/src/order/order.consumer.ts` (`ShipmentConsumer.process`) — thêm case:

```ts
case EVENTS.SHIPMENT_RETURNED: {
  const data = job.data as ShipmentEventPayload;
  if (!data.orderId) return;
  await this.orderService.onReturned(data.orderId);
  break;
}
```

`OrderService.onReturned(orderId)` (mới, đặt cạnh `onShipped`/`onDelivered`):
```ts
async onReturned(orderId: string) {
  const order = await this.repo.findById(orderId);
  if (!order) return;
  const updates: Partial<Order> = {
    fulfillmentStatus: FulfillmentStatus.RETURNED,
    orderStatus: OrderStatus.CANCELLED,
  };
  if (order.paymentMethod === PaymentMethod.ONLINE) {
    updates.paymentStatus = PaymentStatus.REFUND_PENDING;
  }
  await this.repo.updateOrder(orderId, updates);
  this.logger.log(`WMS cập nhật: Đơn ${orderId} hoàn về kho -> CANCELLED`);
}
```

COD không đổi `paymentStatus` (chưa từng thu được tiền — đúng theo `docs/shipping/data-model.md` §Quan hệ với Order).

## 8. Error codes mới (`apps/wms/src/common/error-codes.ts`)

```ts
CARRIER_NOT_FOUND: { status: NOT_FOUND, message: 'Không tìm thấy đơn vị vận chuyển' },
CARRIER_CODE_CONFLICT: { status: CONFLICT, message: 'Mã đơn vị vận chuyển đã tồn tại' },
CARRIER_INACTIVE: { status: BAD_REQUEST, message: 'Đơn vị vận chuyển đã ngừng hoạt động' },
SHIPMENT_NOT_FOUND: { status: NOT_FOUND, message: 'Không tìm thấy vận đơn' },
SHIPMENT_INVALID_TRANSITION: { status: BAD_REQUEST, message: 'Không thể chuyển sang trạng thái này từ trạng thái hiện tại' },
SHIPMENT_NOT_ASSIGNED: { status: BAD_REQUEST, message: 'Vận đơn chưa được gán hãng vận chuyển' },
```

## 9. Testing

Theo pattern `*.spec.ts` hiện có (vd `goods-issue.service.spec.ts`, `order-ready.consumer.spec.ts`):
- `carrier.service.spec.ts` — CRUD + validation code trùng, không xóa cứng khi đã gán vận đơn (nếu enforce).
- `shipment.service.spec.ts` — state machine: mọi transition hợp lệ/không hợp lệ, đúng event phát ra ở đúng mốc, `attempts`/`statusHistory` cập nhật đúng.
- `goods-issued.consumer.spec.ts` — idempotent khi `GOODS_ISSUED` redeliver (unique `goodsIssueId` không tạo trùng), copy đúng snapshot từ `GoodsIssue`.
- `order.consumer.spec.ts` (ecommerce, sửa) — thêm case `SHIPMENT_RETURNED`.
- `order.service.spec.ts` (ecommerce, sửa) — `onReturned`: CANCELLED + REFUND_PENDING (ONLINE) / giữ nguyên (COD).

## 10. Ngoài phạm vi (YAGNI — kế thừa từ spec gốc)

- Tích hợp API hãng thật (webhook trạng thái, tạo vận đơn tự động) — `apiConfig` chỉ là placeholder.
- Tính `shippingFee`.
- Đối soát dòng tiền COD/remittance với hãng.
- Notification thực tế khi `shipment.shipped`/`shipment.delivered` (app `notification` vẫn là stub — nằm ngoài phạm vi P7 shipping, đã có S4-04 riêng).
