# Bổ sung CRUD cho WarehouseItem — Design

**Depends-on:** S1-04 (gap-fix) — `WarehouseItem` schema + `POST /stock/items` đã có

## Bối cảnh

`WarehouseItem` (master data mặt hàng kho) hiện chỉ có `POST /stock/items` (tạo mới). Không có `GET` (danh sách/chi tiết), `PATCH` (cập nhật), hay xoá — khác với mọi module tương tự khác trong hệ (`Supplier`, `Warehouse/Zone/Rack/Shelf`) đã có đủ CRUD. Gap này do sequencing sprint: task gốc chỉ scope "đủ để PO/GRN tham chiếu được", chưa từng có task hoàn thiện CRUD.

Hệ quả nếu không bổ sung: MANAGER/ADMIN không sửa được item tạo sai (vd thiếu `depth/width/height` cho gợi ý put-away), không có API cho FE hiển thị danh sách mặt hàng kho, không vô hiệu hoá được item cũ (`isActive`/`deletedAt` có sẵn trong schema nhưng chưa endpoint nào set được).

## Mục tiêu & phạm vi

Bổ sung 4 endpoint còn thiếu theo **đúng convention đã có ở `SupplierController`** (module tương tự gần nhất, đã có đủ CRUD): `GET` list (filter + phân trang), `GET :id` (chi tiết), `PATCH :id` (cập nhật), `DELETE :id` (soft-delete). Không đổi gì ở `POST` hiện có, không đổi schema `WarehouseItem`.

## Quyết định thiết kế

### 1. `sku` bất biến sau khi tạo — không cho sửa qua PATCH

`sku` là khóa liên kết xuyên app với `ProductVariant` bên Ecommerce (đồng bộ tồn kho `stock.changed` khớp theo `sku`). Đổi `sku` sau khi item đã có PO/GRN/InventoryStock tham chiếu sẽ phá đồng bộ: `itemId` (ObjectId) không đổi nhưng `sku` hiển thị lại khác — Ecom vẫn khớp `sku` cũ, WMS hiển thị `sku` mới, lệch dữ liệu 2 phía không có cơ chế phát hiện.

`UpdateWarehouseItemDto` loại bỏ hoàn toàn field `sku` (không kế thừa từ `CreateWarehouseItemDto`). Muốn đổi sku → tạo item mới + soft-delete item cũ (nghiệp vụ ngoài phạm vi code, không cần API riêng).

Cùng quy ước với `Supplier.code` ("mã NCC — unique, không đổi sau khi có PO") đã áp dụng trong module `Supplier`.

### 2. Soft-delete tự do — không chặn theo tham chiếu

Item đã có PO/GRN/InventoryStock tham chiếu vẫn cho phép soft-delete tự do, giống hệt `Supplier.deleteSupplier` (không check PO đang dùng NCC đó trước khi xoá). Lý do: `deletedAt` chỉ ẩn item khỏi danh sách/khỏi việc tạo PO mới (`createPurchaseOrder` đã check `deletedAt` từ trước — dòng 42-45 `purchase-order.service.ts`), không xoá dữ liệu lịch sử. PO/GRN/StockMovement cũ chỉ lưu `itemId` (ObjectId scalar), không populate/join — soft-delete `WarehouseItem` không ảnh hưởng tính toàn vẹn của chứng từ cũ.

Không thêm logic kiểm tra "còn tồn kho hay không" trước khi xoá — đây sẽ là scope creep ngoài mục tiêu "hoàn thiện CRUD còn thiếu".

### 3. Filter danh sách: `search` + `type` + `isActive` + phân trang

`GET /stock/items?search=&type=&isActive=&page=&limit=` — `search` regex-match trên `sku`/`name`/`barcode` (case-insensitive), `type` lọc theo `ItemType` enum, `isActive` lọc theo trạng thái. Pattern giống hệt `QuerySupplierDto`/`SupplierRepository.findSuppliers`.

## Thay đổi cụ thể

### `StockRepository` (`apps/wms/src/stock/stock.repository.ts`) — thêm method

```ts
async findItems(
  query: QueryWarehouseItemDto,
): Promise<{ data: WarehouseItemDocument[]; total: number }> {
  const page = query.page ?? 1;
  const limit = query.limit ?? 20;
  const filter: Record<string, unknown> = { deletedAt: null };

  if (query.type) filter['type'] = query.type;
  if (query.isActive !== undefined) filter['isActive'] = query.isActive;
  if (query.search) {
    filter['$or'] = [
      { sku: { $regex: query.search, $options: 'i' } },
      { name: { $regex: query.search, $options: 'i' } },
      { barcode: { $regex: query.search, $options: 'i' } },
    ];
  }

  const [data, total] = await Promise.all([
    this.itemModel
      .find(filter)
      .sort({ sku: 1 })
      .skip((page - 1) * limit)
      .limit(limit)
      .exec(),
    this.itemModel.countDocuments(filter).exec(),
  ]);
  return { data, total };
}

async updateItem(
  id: string,
  dto: UpdateWarehouseItemData,
  actorId: string,
): Promise<WarehouseItemDocument | null> {
  return this.itemModel
    .findOneAndUpdate(
      { _id: id, deletedAt: null },
      { ...dto, updatedBy: new Types.ObjectId(actorId) },
      { new: true },
    )
    .exec();
}

async softDeleteItem(id: string, actorId: string): Promise<boolean> {
  const res = await this.itemModel
    .updateOne(
      { _id: id, deletedAt: null },
      { deletedAt: new Date(), updatedBy: new Types.ObjectId(actorId) },
    )
    .exec();
  return res.modifiedCount > 0;
}
```

`findItemById` đã tồn tại (dùng lại cho chi tiết — hiện trả `.lean()`, cần đổi sang trả `WarehouseItemDocument` không `.lean()` cho route `GET :id` để nhất quán style response `doc.toObject()` — xem ghi chú "Thay đổi phụ" bên dưới).

### `StockService` (`apps/wms/src/stock/stock.service.ts`) — thêm method

```ts
async listWarehouseItems(
  query: QueryWarehouseItemDto,
): Promise<{ data: WarehouseItemDocument[]; total: number }> {
  return this.stockRepo.findItems(query);
}

async getWarehouseItem(id: string): Promise<WarehouseItemDocument> {
  const doc = await this.stockRepo.findItemByIdDocument(id);
  if (!doc) throw new AppException('STOCK_ITEM_NOT_FOUND');
  return doc;
}

async updateWarehouseItem(
  id: string,
  dto: UpdateWarehouseItemDto,
  actorId: string,
): Promise<WarehouseItemDocument> {
  const doc = await this.stockRepo.updateItem(id, dto, actorId);
  if (!doc) throw new AppException('STOCK_ITEM_NOT_FOUND');
  return doc;
}

async deleteWarehouseItem(id: string, actorId: string): Promise<void> {
  const deleted = await this.stockRepo.softDeleteItem(id, actorId);
  if (!deleted) throw new AppException('STOCK_ITEM_NOT_FOUND');
}
```

Không check trùng `sku`/`barcode` ở `updateWarehouseItem` — `sku` không sửa được (loại khỏi DTO), `barcode` vốn không có unique constraint ở schema (`sparse: true`, không `unique: true`), giữ nguyên hành vi hiện tại.

### DTO mới — `apps/wms/src/stock/dto/query-warehouse-item.dto.ts` (file mới)

```ts
export class QueryWarehouseItemDto {
  @ApiPropertyOptional({ description: 'Tìm theo sku, name hoặc barcode' })
  @IsOptional()
  @IsString()
  search?: string;

  @ApiPropertyOptional({ enum: ItemType })
  @IsOptional()
  @IsEnum(ItemType)
  type?: ItemType;

  @ApiPropertyOptional()
  @IsOptional()
  @Type(() => Boolean)
  @IsBoolean()
  isActive?: boolean;

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
```

### DTO mới — `UpdateWarehouseItemDto` (thêm vào `create-warehouse-item.dto.ts`)

```ts
export class UpdateWarehouseItemDto extends PartialType(
  OmitType(CreateWarehouseItemDto, ['sku'] as const),
) {}
```

### `StockController` (`apps/wms/src/stock/stock.controller.ts`) — thêm route

```
GET    /stock/items          — [ADMIN, MANAGER] danh sách + filter/phân trang
GET    /stock/items/:id      — [ADMIN, MANAGER] chi tiết
PATCH  /stock/items/:id      — [ADMIN, MANAGER] cập nhật (không có field sku)
DELETE /stock/items/:id      — [ADMIN] soft-delete (204 No Content)
```

Route tĩnh không có (`items` không có sub-path như `supplier/items/by-item/:id`), nên không cần lo route-shadowing như `SupplierController` — thứ tự khai báo `POST → GET → GET :id → PATCH :id → DELETE :id` tự nhiên, không bị NestJS match nhầm.

## Không đổi

- Schema `WarehouseItem` — không thêm/bớt field.
- `POST /stock/items` (`createWarehouseItem`) — giữ nguyên logic chặn trùng sku.
- Error codes — dùng lại `STOCK_ITEM_NOT_FOUND`/`STOCK_ITEM_SKU_CONFLICT` đã có trong `WMS_ERRORS`, không thêm code mới.
- `WarehouseItemResponseDto` — đã đủ field (bao gồm `depth/width/height` từ S2-05), dùng lại nguyên vẹn cho cả list/detail/update response.

## Thay đổi phụ trong code hiện có

- **`StockRepository.findItemById`**: hiện trả `.lean()` (dùng nội bộ PO/GRN, không qua controller nên không cần `.toObject()`). Cần thêm method mới `findItemByIdDocument(id): Promise<WarehouseItemDocument | null>` **không** `.lean()` để controller gọi `.toObject()` đúng convention response DTO (`plainToInstance(..., doc.toObject(), TO_OPTS)`) — không sửa `findItemById` hiện có (tránh phá các call site nội bộ đang dùng `.lean()` cho hiệu năng).

## Roles

Theo đúng convention `Supplier`: `GET`/`PATCH` cho `ADMIN, MANAGER`; `DELETE` chỉ `ADMIN` (thao tác phá hủy dữ liệu nhạy cảm hơn, giữ nguyên mức độ nghiêm ngặt như `Supplier`).

## Testing

- `stock.repository.spec.ts`: `findItems` (filter search/type/isActive đúng, phân trang đúng), `updateItem` (cập nhật đúng field, trả `null` khi không tìm thấy/đã xoá), `softDeleteItem` (set đúng `deletedAt`/`updatedBy`, trả `false` khi không tìm thấy), `findItemByIdDocument` (trả document không lean).
- `stock.service.spec.ts`: 4 method mới — throw `STOCK_ITEM_NOT_FOUND` đúng khi repo trả `null`/`false`.
- Không cần test controller riêng (theo pattern hiện có của repo — controller mỏng, test qua service).
