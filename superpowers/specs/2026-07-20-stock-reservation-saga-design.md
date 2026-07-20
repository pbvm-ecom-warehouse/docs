# Saga giữ tồn kho (Stock Reservation) — Design

**Ngày:** 2026-07-20
**Liên quan:** GitHub issue #3 "Saga reserve tồn kho lúc checkout không hoạt động — nguy cơ oversell" (`pbvm-ecom-warehouse/be-wms-ecom`)

## Bối cảnh

Checkout ở Ecommerce phát `STOCK_RESERVE_REQUESTED` (`apps/ecommerce/src/order/checkout.service.ts`) và đã có sẵn consumer chờ phản hồi (`apps/ecommerce/src/order/reserve.consumer.ts`), nhưng **WMS chưa từng implement phía nhận** — không consumer, không logic giữ tồn. Kết quả: đơn hàng checkout xong không giữ tồn kho thật, kẹt vĩnh viễn ở trạng thái `PLACED`, và có nguy cơ oversell khi nhiều khách checkout cùng SKU.

`libs/events/src/events.ts` đã khai báo sẵn đầy đủ payload cho saga 4 bước (`StockReserveRequestedPayload`, `StockReservedPayload`, `StockReserveFailedPayload`). `.claude/rules/architecture.md` đã chốt rõ: đồng bộ xuyên app đi qua saga event bất đồng bộ, **không** transaction xuyên DB — quyết định này giữ nguyên, và `docs/overview/main-flow.md` (đoạn mô tả reserve là "transaction atomic xuyên 2 DB") sẽ được sửa lại cho khớp.

## Kiến trúc saga

```
Ecom checkout → STOCK_RESERVE_REQUESTED ──▶ WMS: kiểm tra + giữ tồn (transaction, MỚI)
WMS ─ STOCK_RESERVED ──▶ Ecom: order → CONFIRMED (COD) / chờ payment (ONLINE) — ĐÃ CÓ
WMS ─ STOCK_RESERVE_FAILED ──▶ Ecom: hủy đơn, phục hồi giỏ hàng — ĐÃ CÓ
Ecom hủy đơn → ORDER_CANCELLED ──▶ WMS: giải phóng reserved (consumer MỚI)
```

Chỉ cần code thêm ở **phía WMS**. Phía Ecom (checkout, reserve.consumer.ts, auto-cancel sau 30 phút cho đơn ONLINE) đã hoàn thiện, không cần sửa.

`ORDER_CANCELLED` được dùng làm event chính thức để giải phóng tồn — không cần Ecom phát thêm `STOCK_RELEASE_REQUESTED`. Event `STOCK_RELEASE_REQUESTED` sẽ được xử lý riêng ở issue dọn dẹp `events.ts` (#8), ngoài phạm vi spec này.

## Module mới: `apps/wms/src/reservation/`

Đặt thành module domain riêng (không nhồi vào `stock`) vì reserve là quy trình nghiệp vụ có input `orderId` + logic chọn kho, không chỉ thao tác CRUD tồn kho thuần túy.

```
apps/wms/src/reservation/
  reservation.module.ts
  reservation.service.ts
  reservation.consumer.ts
  reservation.service.spec.ts
```

### `ReservationConsumer` (`@Processor(QUEUES.ORDER)`)

Cùng `QUEUES.ORDER` với `OrderReadyConsumer`, `OrderReturnedConsumer` hiện có (mỗi Processor tự `switch(job.name)`, không xung đột — đúng pattern đã dùng).

```
switch (job.name) {
  case STOCK_RESERVE_REQUESTED: reservationService.reserveForOrder(...)
  case ORDER_CANCELLED:         reservationService.releaseForOrder(...)
  default: logger.warn(job lạ)
}
```

### `ReservationService.reserveForOrder(orderId, items, preferWarehouse?)`

1. **Idempotency**: kiểm tra đã tồn tại `StockMovement` với `refType='reservation', refId=orderId` chưa. Nếu có → log + bỏ qua (job bị retry).
2. **Chọn kho** (transaction, xem thuật toán bên dưới):
   - Ứng viên: `preferWarehouse` trước, sau đó các kho active khác.
   - Với mỗi kho ứng viên, thử atomic-reserve từng SKU trong đơn; nếu **toàn bộ SKU** trong đơn đủ tồn ở kho đó → chọn kho này, dừng.
   - Nếu không kho nào đủ hết toàn bộ đơn → rollback mọi reserve tạm thời đã thử ở kho đó (transaction tự abort), thử kho tiếp theo.
3. Nếu tìm được kho: với mỗi SKU, `insertMovement(type=RESERVE, refType='reservation', refId=orderId, quantity=+qty, warehouseId=kho đã chọn, session)`. Phát `STOCK_RESERVED { orderId, fulfillWarehouseId }`.
4. Nếu không kho nào đủ: phát `STOCK_RESERVE_FAILED { orderId, reason, failedSkus }` — `failedSkus` lấy từ SKU thiếu tồn tại kho ứng viên tốt nhất (ít SKU thiếu nhất).
5. SKU không khớp `WarehouseItem` nào → coi là thiếu tồn (available=0), góp vào `failedSkus`, **không throw** (throw sẽ khiến BullMQ retry lặp lại lỗi y hệt — theo pattern `GoodsIssueService.createFromOrderReady`).
6. **Không** gọi `emitStockChanged`/phát `stock.changed` — reserve là biến động nội bộ `reserved` (đường 2 trong `architecture.md`), `available` giảm nhưng đã được Ecom tự trừ ngay lúc checkout theo saga riêng, không qua đường sync `stock.changed`.

### `ReservationService.releaseForOrder(orderId)`

1. Đọc các `StockMovement` loại `RESERVE` với `refId=orderId` (biết đã reserve SKU gì, số lượng bao nhiêu, ở kho nào).
2. Không tìm thấy (chưa từng reserve, hoặc đã release rồi) → log + bỏ qua (idempotent).
3. **Nếu đã tồn tại `GoodsIssue` cho `orderId`** (tra qua `GoodsIssueRepository.findByOrderId`) → log warning, bỏ qua. Không tự động hủy GoodsIssue trong phạm vi spec này (ngoài scope — cần quy trình thủ công riêng).
4. Ngược lại: transaction, với mỗi SKU đã reserve: `upsertBalance(itemId, warehouseId, 0, -qty, 0, session)` + `insertMovement(type=RELEASE, refType='reservation_release', refId=orderId, quantity=-qty, session)`.

### Thuật toán chọn kho — atomic check-and-reserve

Tránh race condition khi 2 đơn checkout cùng lúc cùng SKU bằng cách gộp "kiểm tra đủ tồn" + "tăng reserved" vào **1 query atomic**:

```js
balanceModel.findOneAndUpdate(
  {
    itemId, warehouseId,
    $expr: { $gte: [{ $subtract: ['$onHand', '$reserved', '$expired'] }, quantity] },
  },
  { $inc: { reserved: quantity } },
  { new: true, session },
)
```

Nếu kết quả `null` → không đủ tồn tại thời điểm đó (kể cả do đơn khác vừa giữ tồn) → kho này fail cho SKU đó, thử kho tiếp theo hoặc thêm vào `failedSkus`. Toàn bộ vòng lặp SKU cho 1 kho ứng viên chạy trong `StockTransactionHelper.withStockTransaction` — nếu SKU sau cùng fail, transaction abort, các `$inc` trước đó trong cùng transaction tự rollback (không cần code hoàn tác thủ công).

### Schema thay đổi

`apps/wms/src/stock/schemas/stock-movement.schema.ts` — thêm 2 giá trị vào `MovementType` enum: `RESERVE`, `RELEASE`. Các giá trị này chỉ ghi vết trên `reserved`, không ảnh hưởng `onHand`.

## Idempotency & retry

- Job BullMQ retry tối đa 5 lần (backoff exponential, cấu hình `EventsModule`).
- `reserveForOrder`: idempotent qua kiểm tra `StockMovement.refType='reservation'` tồn tại chưa.
- `releaseForOrder`: idempotent qua việc không tìm thấy movement RESERVE tương ứng (đã release trước đó thì không còn gì để trừ thêm — cần đảm bảo logic không trừ 2 lần nếu gọi lại: có thể kiểm tra thêm đã có `RELEASE` movement cho cùng `orderId` chưa, bỏ qua nếu có).

## Cập nhật tài liệu

- `docs/overview/main-flow.md`: sửa đoạn mô tả reserve từ "transaction atomic xuyên 2 DB" sang mô tả đúng saga 4 bước bất đồng bộ.

## Ngoài phạm vi (out of scope)

- Không tự động hủy/hoàn tác `GoodsIssue` khi đơn bị hủy sau khi đã sinh GoodsIssue — chỉ log warning.
- Không hỗ trợ reserve split nhiều kho cho 1 đơn (1 đơn = 1 `fulfillWarehouseId`, khớp model `Order`/`GoodsIssue` hiện có).
- Không xử lý event `STOCK_RELEASE_REQUESTED` (để dành cho issue dọn dẹp `events.ts` riêng — #8).
- Không sửa nội dung khác của `main-flow.md` ngoài đoạn mô tả cơ chế reserve.

## Test plan

Unit test (Jest, theo pattern `stock.service.spec.ts` / `goods-issue.service.spec.ts`):

**`ReservationService.reserveForOrder`**
- Đủ tồn ở `preferWarehouse` → `reserved` tăng đúng theo từng SKU, phát `STOCK_RESERVED` với đúng `fulfillWarehouseId`.
- `preferWarehouse` thiếu 1 SKU nhưng kho khác đủ toàn bộ → chọn kho khác, không rơi vãi reserve ở `preferWarehouse`.
- Không kho nào đủ toàn bộ đơn → phát `STOCK_RESERVE_FAILED` với đúng `failedSkus`, không có `reserved` nào bị tăng ở bất kỳ kho nào (transaction rollback).
- SKU không tồn tại trong `WarehouseItem` → không throw, góp vào `failedSkus`.
- Gọi lại 2 lần cùng `orderId` (mô phỏng retry) → lần 2 không reserve trùng.
- 2 lệnh reserve cùng SKU, tổng vượt quá `available` → chỉ 1 lệnh thành công (test atomic check qua `$expr`).

**`ReservationService.releaseForOrder`**
- Có movement RESERVE trước đó, chưa có GoodsIssue → giải phóng đúng `reserved -= qty` cho đúng kho.
- Không có movement RESERVE (chưa từng reserve) → bỏ qua, không lỗi.
- Đã có GoodsIssue cho đơn → log warning, không đổi `reserved`.
- Gọi lại 2 lần (retry) → không trừ `reserved` 2 lần.

**`ReservationConsumer`**
- Switch đúng case cho từng job name.
- Job lạ trên `QUEUES.ORDER` → log warning, không throw.
