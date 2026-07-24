# S3-01: UC-05 Soạn & xuất hàng (Goods Issue) — Design

**Nguồn:** [warehouse/use-cases.md#UC-05](../../warehouse/use-cases.md), [warehouse/workflow.md](../../warehouse/workflow.md), [overview/main-flow.md P6](../../overview/main-flow.md), [overview/data-ownership.md](../../overview/data-ownership.md)

## Bối cảnh

Đơn hàng bên Ecommerce vào `fulfillmentStatus = READY_TO_PICK` (COD ngay sau checkout / online không ly-in khi `payment.success` / đơn ly-in sau khi in xong) thì bắn event `order.ready_to_fulfill` sang WMS. WMS cần:

1. Tự sinh phiếu xuất kho (`GoodsIssue`) khi nhận event này.
2. Cho PICKER pick hàng theo gợi ý vị trí (FEFO với hàng có hạn sử dụng), quét xác nhận đúng món/đúng chỗ.
3. Trừ tồn thật (`onHand -=`, `reserved -=` — `available` không đổi vì đã trừ lúc chốt đơn ở checkout).
4. Khi xuất xong toàn bộ phiếu → bắn `goods.issued` (WMS→Ecom) để Ecom cập nhật `fulfillmentStatus = ISSUED`.

Tồn đã được giữ (`reserved`) từ lúc checkout (atomic trong transaction, không qua event) — UC-05 chỉ hiện thực hóa việc lấy hàng & trừ tồn thật, không reserve lại.

`goods.issued` và các event `shipment.*` đều được Ecom lắng nghe trên cùng 1 queue (`apps/ecommerce/src/order/order.consumer.ts` @Processor(QUEUES.SHIPMENT)) — WMS phải publish `GOODS_ISSUED` lên `QUEUES.SHIPMENT`, không phải `QUEUES.ORDER`, để khớp consumer đã có sẵn bên Ecom.

Module Shipping (sinh `Shipment{PENDING}` sau `goods.issued`) và các trường `shippingAddress`/`recipient`/`paymentMethod`/`codAmount` trong payload `order.ready_to_fulfill` nằm **ngoài phạm vi** task này — sẽ tự nhận payload/đọc lại event gốc khi module Shipping được implement.

## Phạm vi & quyết định thiết kế đã chốt

1. **Tự động tạo GoodsIssue khi nhận event** — consumer nhận `order.ready_to_fulfill` → tạo ngay `GoodsIssue{status: PENDING}`, không cần MANAGER thao tác thủ công. Nhất quán với `PutAwayTask` (tự sinh khi GRN `CONFIRMED`).
2. **Không có luồng cảnh báo thiếu tồn riêng** — vì tồn đã reserve từ checkout, về lý thuyết luôn đủ. Nếu lệch dữ liệu (hiếm), việc chặn xảy ra tự nhiên ở bước PICKER quét xác nhận từng dòng (throw `STOCK_INSUFFICIENT` nếu tồn tại shelf/lot không đủ).
3. **FEFO là gợi ý, không ép buộc** — endpoint gợi ý trả danh sách `(shelf, lot, expiryDate, quantity)` sắp theo FEFO tăng dần (lô `EXPIRED` bị loại khỏi danh sách); PICKER có thể chọn dòng khác ngoài gợi ý đầu tiên khi quét xác nhận.
4. **API xác nhận dùng chung shape với `PutAwayController.confirmLine`** — `POST /goods-issues/:id/confirm-line { itemBarcode, shelfCode, quantity, lotId? }`. Nhất quán với module `put-away` đã có (cùng actor PICKER quét barcode).
5. **SKU không khớp WarehouseItem** — bỏ qua dòng đó, log warning, vẫn tạo `GoodsIssue` với các dòng hợp lệ còn lại. Tránh 1 dòng lỗi dữ liệu chặn toàn bộ job BullMQ (retry sẽ lặp lại lỗi y hệt vì payload không đổi).
6. **`GoodsIssue` không lưu shipping info** — chỉ giữ `orderId` (string từ Ecom) + `warehouseId` + `items`. `shippingAddress`/`recipient`/`paymentMethod`/`codAmount` thuộc trách nhiệm module Shipping, tránh ghép 2 trách nhiệm vào 1 document.

## Kiến trúc

Module mới `apps/wms/src/goods-issue/`, đặt cạnh `goods-receipt-note` và `put-away` (theo đúng cấu trúc domain hiện có), import `StockModule` + `WarehouseModule` giống `PutAwayModule`.

```
apps/wms/src/goods-issue/
  schemas/goods-issue.schema.ts
  dto/goods-issue.dto.ts               (request: ConfirmGoodsIssueLineDto, QueryGoodsIssueDto; response: GoodsIssueResponseDto, PickSuggestionResponseDto)
  goods-issue.repository.ts
  goods-issue.service.ts
  goods-issue.controller.ts
  order-ready.consumer.ts              (@Processor(QUEUES.ORDER) — nhận order.ready_to_fulfill)
  goods-issue.module.ts
```

Đăng ký `GoodsIssueModule` vào `AppModule` (`apps/wms/src/app.module.ts`).

> Lưu ý phát hiện phụ trong lúc khảo sát: `PutAwayModule` hiện **chưa** được import vào `AppModule` dù code đã hoàn chỉnh — đây là gap có sẵn từ trước, không thuộc phạm vi task này nhưng cần user xác nhận có muốn fix kèm không.

### Schema: `GoodsIssue`

Chứng từ giao dịch — hủy bằng `status`, KHÔNG soft-delete (theo `data-and-mongoose.md`).

```ts
export enum GoodsIssueStatus {
  PENDING = 'PENDING',
  CONFIRMED = 'CONFIRMED',
}

@Schema({ _id: false })
class GoodsIssueItem {
  itemId: Types.ObjectId;      // required — WarehouseItem._id
  sku: string;                  // required — denormalized, để hiển thị
  quantity: number;             // required, min 0 — số cần xuất (từ payload)
  remainingQty: number;         // required, min 0 — còn lại chưa xuất, giảm dần mỗi lần confirm-line
}
// không audit riêng — kế thừa từ GoodsIssue cha (giống GoodsReceiptNoteItem/PutAwayItem)

@Schema({ collection: 'goods_issues', timestamps: true })
export class GoodsIssue {
  orderId: string;              // required — id đơn hàng bên Ecom (KHÔNG phải ObjectId nội bộ WMS)
  warehouseId: Types.ObjectId;  // required — từ payload.fulfillWarehouseId
  status: GoodsIssueStatus;     // default PENDING
  items: GoodsIssueItem[];      // required
}
// timestamps: true (createdAt/updatedAt) — chứng từ giao dịch, không có createdBy vì
// consumer sự kiện tạo, không có actor người dùng lúc tạo (khác GRN/PutAway do MANAGER/RECEIVER tạo)
```

Index: `{ orderId: 1 }` (unique — 1 đơn 1 phiếu xuất, tránh consumer chạy lại tạo trùng), `{ status: 1 }`.

### Luồng 1 — Consumer tạo GoodsIssue

`order-ready.consumer.ts` — `@Processor(QUEUES.ORDER)`, xử lý `EVENTS.ORDER_READY_TO_FULFILL`:

1. Payload: `OrderReadyToFulfillPayload { orderId, fulfillWarehouseId, items: {sku, quantity}[], ... }`
2. Idempotency: kiểm tra đã có `GoodsIssue` với `orderId` này chưa (unique index + kiểm tra trước khi insert) — nếu có, log warning, bỏ qua (job có thể redeliver do BullMQ retry).
3. Map từng `item.sku` → `WarehouseItem._id` qua `StockRepository.findItemBySku`. Sku không khớp → `logger.warn`, loại dòng đó khỏi danh sách.
4. Nếu còn ≥ 1 dòng hợp lệ → tạo `GoodsIssue{status: PENDING, orderId, warehouseId: fulfillWarehouseId, items}`. Nếu 0 dòng hợp lệ → chỉ log warning, không tạo phiếu rỗng.

Cần đăng ký `BullModule.registerQueue({ name: QUEUES.ORDER })` trong `GoodsIssueModule` (WMS chưa từng consume queue này).

### Luồng 2 — Gợi ý vị trí pick (FEFO)

`GET /goods-issues/:id/items/:itemId/suggestions`

- Đọc `WarehouseItem.isPerishable`:
  - **true**: tìm mọi `InventoryStock(itemId, warehouseId, quantity>0)` join `Lot` (status=ACTIVE, loại EXPIRED), sắp `expiryDate` tăng dần.
  - **false**: tìm mọi `InventoryStock(itemId, warehouseId, quantity>0, lotId=null)`, sắp theo `quantity` giảm dần (ưu tiên shelf có nhiều hàng nhất, giảm số lần PICKER phải đi nhiều chỗ).
- Trả về `{ shelfId, shelfCode, lotId, lotNumber, expiryDate, quantity }[]`.
- Repository method mới: `StockRepository.findAvailableStockForPick(itemId, warehouseId, isPerishable)`.

### Luồng 3 — Xác nhận xuất từng dòng

`POST /goods-issues/:id/confirm-line { itemBarcode, shelfCode, quantity, lotId? }` — PICKER role.

Đối xứng với `PutAwayService.confirmLine`:

1. Tìm `GoodsIssue` theo id — không có → `GOODS_ISSUE_NOT_FOUND`.
2. Tìm item theo `itemBarcode` (`StockRepository.findItemByBarcode`) — không có → `GOODS_ISSUE_ITEM_NOT_FOUND`.
3. Tìm shelf theo `shelfCode` (`WarehouseRepository.findShelfByCode`) — không có / khác `warehouseId` của phiếu → `GOODS_ISSUE_SHELF_NOT_FOUND`.
4. Khớp dòng `items[]` theo `itemId` — không thấy → `GOODS_ISSUE_ITEM_MISMATCH`. `dto.quantity > line.remainingQty` → `GOODS_ISSUE_QTY_EXCEEDS`.
5. Kiểm tra `InventoryStock(itemId, warehouseId, shelfId, lotId)` có đủ `quantity` không — thiếu → `STOCK_INSUFFICIENT` (tái dùng code có sẵn, đây chính là điểm chặn tự nhiên cho case lệch tồn nêu ở mục Phạm vi #2).
6. Trong `StockTransactionHelper.withStockTransaction`:
   - `InventoryStock(shelf, lot).quantity -= qty`
   - `StockBalance(item, warehouse): onHand -= qty, reserved -= qty` (available không đổi)
   - `StockMovement{type: ISSUE, quantity: -qty, refType: 'goods_issue', refId}`
   - `GoodsIssue.items[line].remainingQty -= qty`
   - Nếu mọi `remainingQty === 0` → `status = CONFIRMED`
7. Sau transaction: nếu vừa chuyển `CONFIRMED` → gọi `emitGoodsIssued(orderId, goodsIssueId)`.

**Không bắn `stock.changed`** — khớp bất biến trong `data-ownership.md` ("KHÔNG bắn khi... pick-xuất").

### Luồng 4 — Producer `goods.issued`

Thêm method trong `GoodsIssueService` (không đụng `StockService` vì đây không phải sync `available`):

```ts
async emitGoodsIssued(orderId: string, goodsIssueId: string): Promise<void> {
  const payload: GoodsIssuedPayload = { orderId, goodsIssueId };
  const jobId = `goods_issue:${goodsIssueId}`;
  await this.shipmentQueue.add(EVENTS.GOODS_ISSUED, payload, { jobId });
}
```

`GoodsIssueModule` cần `BullModule.registerQueue({ name: QUEUES.SHIPMENT })` (WMS chưa từng producer lên queue này).

## Error codes mới (`apps/wms/src/common/error-codes.ts`)

| Code | Status | Message |
|---|---|---|
| `GOODS_ISSUE_NOT_FOUND` | 404 | Không tìm thấy phiếu xuất kho |
| `GOODS_ISSUE_ITEM_NOT_FOUND` | 404 | Không tìm thấy mặt hàng theo barcode đã quét |
| `GOODS_ISSUE_SHELF_NOT_FOUND` | 404 | Không tìm thấy vị trí theo barcode đã quét |
| `GOODS_ISSUE_ITEM_MISMATCH` | 400 | Mặt hàng quét được không thuộc phiếu xuất kho này |
| `GOODS_ISSUE_QTY_EXCEEDS` | 400 | Số lượng quét vượt quá số lượng còn lại cần xuất |

(`STOCK_INSUFFICIENT` đã có sẵn trong catalog — tái dùng.)

## API tổng hợp

| Method | Path | Role | Mô tả |
|---|---|---|---|
| GET | `/goods-issues` | PICKER, MANAGER, ADMIN | Danh sách phiếu xuất (filter status, phân trang) |
| GET | `/goods-issues/:id` | PICKER, MANAGER, ADMIN | Chi tiết phiếu |
| GET | `/goods-issues/:id/items/:itemId/suggestions` | PICKER, ADMIN | Gợi ý vị trí pick (FEFO nếu perishable) |
| POST | `/goods-issues/:id/confirm-line` | PICKER, ADMIN | Quét xác nhận 1 dòng xuất |

## Testing

- `goods-issue.schema.spec.ts` — validate schema, index.
- `goods-issue.service.spec.ts` — case chính: tạo từ event (sku hợp lệ/không hợp lệ), confirm-line đủ/thiếu tồn, chuyển CONFIRMED khi hết remainingQty, emit goods.issued đúng 1 lần.
- `order-ready.consumer.spec.ts` — idempotency (nhận lại event cùng orderId không tạo trùng), bỏ qua sku không khớp.
- `goods-issue.repository.spec.ts` — theo pattern `put-away.repository.spec.ts`.

## Ngoài phạm vi (out of scope)

- Module Shipping (`Shipment{PENDING}` sinh sau `goods.issued`) — task riêng theo `shipping/use-cases.md` UC-S02.
- Xử lý case reserved thực tế bị âm/lệch nghiêm trọng (để dành UC-06 kiểm kho).
- Fix `PutAwayModule` chưa import vào `AppModule` (gap có sẵn, phát hiện phụ — cần xác nhận riêng có nên fix kèm không).
