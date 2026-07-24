# Sync SKU/attributes lúc tạo mới — WMS → Ecom — Design

## Bối cảnh

WMS tạo `WarehouseItem` (sku + `attributes: ItemAttribute[]` structured, snapshot từ `ItemAttributeOption`) hoàn toàn local — `createWarehouseItem` không bắn event nào (`apps/wms/src/stock/stock.service.ts:135-205`). Ecom phải chờ admin tự tay tạo `ProductVariant` và tự gõ lại `attributes` (dạng `Record<string,string>` tự do, `apps/ecommerce/src/catalog/schemas/product-variant.schema.ts`) — không có gì đảm bảo khớp giữa 2 bên ngoài chuỗi `sku`, dễ sai chính tả/thiếu sót, và là công sức trùng lặp.

Đây là gap thật, không phải tính năng dở dang: `docs/overview/data-ownership.md` không có mục nào mô tả việc này; 19 event hiện có trong `libs/events/src/events.ts` chỉ có `stock.changed`/`stock.expired` mang `{sku, delta}` (số lượng), không có event nào mang tên/attribute.

## Phạm vi

**Chỉ xử lý thời điểm tạo SKU mới.** Không đụng update, vì code hiện tại **chưa cho phép** sửa `attributes`/`isActive` qua API:
- `UpdateWarehouseItemDto` = `PartialType(OmitType(CreateWarehouseItemDto, ['type', 'templateId', 'attributeOptionIds']))` → `attributeOptionIds` (nguồn tạo ra `attributes`) bị loại khỏi input, `attributes` không có đường nào populate qua update.
- Không có field `isActive` ở bất kỳ DTO nào — `isActive` chỉ hardcode `true` lúc tạo (`stock.repository.ts:319`).

Việc mở rộng update để sửa 2 field này là một task riêng, làm sau nếu cần.

## Event contract (`libs/events/src/events.ts`)

- Queue: dùng lại `QUEUES.STOCK` — cùng domain với `stock.changed`, không cần queue/wiring mới (`StockService` đã inject sẵn `stockQueue`).
- Event mới: `EVENTS.ITEM_CREATED = 'item.created'` (WMS → Ecom).
- Payload tối thiểu:

```ts
export interface ItemCreatedPayload {
  sku: string;
  name: string;
  attributes: { key: string; value: string }[]; // key chuẩn hóa (COLOR, SIZE...), value tên hiển thị
}
```

Không mang `optionId`/`code`/`barcode`/kích thước vật lý — Ecom không có khái niệm đó và không dùng tới. Đăng ký vào `EventPayloadMap`.

## Producer — `StockService.createWarehouseItem`

Emit sau khi transaction commit thành công (`apps/wms/src/stock/stock.service.ts`, sau dòng ~198 nơi `withStockTransaction` trả về), theo đúng convention đã có của `checkAndEmitStockLow` (emit sau commit vì BullMQ không transactional, tránh emit rồi transaction rollback).

```ts
await this.stockQueue.add(EVENTS.ITEM_CREATED, {
  sku: doc.sku,
  name: doc.name,
  attributes: doc.attributes.map((a) => ({ key: a.key, value: a.value })),
} satisfies ItemCreatedPayload);
```

Không cần `jobId` idempotency kiểu `refType:refId` như `stock.changed` — `sku` là unique tự nhiên phía Ecom, consumer dùng upsert theo `sku` nên xử lý trùng job tự nhiên idempotent (xem dưới).

## Consumer — thêm case trong `stock.consumer.ts` hiện có

Cùng `@Processor(QUEUES.STOCK)` đang xử lý `STOCK_CHANGED`/`STOCK_EXPIRED`, thêm case `ITEM_CREATED`:

```ts
case EVENTS.ITEM_CREATED: {
  const payload = job.data as ItemCreatedPayload;
  const attributes = Object.fromEntries(
    payload.attributes.map((a) => [a.key, a.value]),
  );
  await this.variantModel.findOneAndUpdate(
    { sku: payload.sku },
    {
      $set: { attributes },
      $setOnInsert: {
        sku: payload.sku,
        productId: null,
        isActive: false,
        price: 0,
        availableQty: 0,
      },
    },
    { upsert: true },
  );
  break;
}
```

Hành vi:
- **Chưa có variant** → tạo mới, `productId: null`, `isActive: false`, `price: 0` — admin Ecom vào UI gán Product + set giá + bật active sau.
- **Đã có variant** (admin từng tạo tay, hoặc retry job) → ghi đè `attributes` toàn bộ từ WMS (WMS là source of truth cho attributes vật lý), giữ nguyên `productId`/`price`/`isActive` đã có — không đụng phần Ecom sở hữu.
- **Idempotency**: `findOneAndUpdate(..., { upsert: true })` theo `sku` unique tự nhiên xử lý đúng cả 2 nhánh trong 1 lệnh, an toàn với BullMQ retry (tối đa 5 lần theo default job options).

## Map attributes: `ItemAttribute[]` → `Record<string,string>`

Giữ nguyên schema/FE Ecom hiện tại (không đổi sang structured). Key của Record lấy từ `ItemAttribute.key` (enum chuẩn hóa `AttributeOptionKey` như `COLOR`, `SIZE` — đã chuẩn hóa sẵn từ WMS), value lấy từ `ItemAttribute.value` (tên hiển thị). Bỏ `optionId`/`code` vì Ecom không dùng. Lợi ích phụ: tự động dọn sự thiếu nhất quán hiện tại của việc admin Ecom gõ tay key tự do (vd `"mau"` lẫn `"color"`).

## Thay đổi schema cần thiết

- `ProductVariant.productId`: đổi từ required sang optional (`productId?: Types.ObjectId`) để cho phép trạng thái "chờ gán Product". Rà lại các chỗ giả định `productId` luôn có giá trị: API list theo product, response DTO, mọi query lọc theo `productId`.
- Thêm cách lọc "variant chưa gán product" ở Ecom admin (query `productId: null`) để admin dễ tìm và xử lý — tối thiểu 1 query param hoặc endpoint, không cần UI phức tạp trong phạm vi spec này.

## Testing

- Unit: `StockService.createWarehouseItem` gọi `stockQueue.add` với đúng `EVENTS.ITEM_CREATED` và payload shape sau khi transaction commit; không gọi khi transaction throw.
- Unit: consumer case `ITEM_CREATED` — upsert tạo mới khi chưa có variant (kiểm tra `productId: null`, `isActive: false`); upsert ghi đè `attributes` nhưng giữ nguyên `productId`/`price`/`isActive` khi variant đã tồn tại.
- E2E (nếu có harness event WMS→Ecom sẵn, xem `S4-05` seed/e2e design): tạo warehouse item mới → verify `ProductVariant` xuất hiện bên Ecom với đúng `sku`/`attributes`.
