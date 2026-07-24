# S1-04: Bổ sung tạo mới WarehouseItem + validate itemId trong PO

**Ngày**: 2026-07-04
**Trạng thái**: Approved

## Bối cảnh

Audit schema tồn kho 2/3 lớp (`WarehouseItem` → `StockBalance` → `InventoryStock`) phát hiện gap: **không có bất kỳ API nào tạo mới `WarehouseItem`**.

- `apps/wms/src/stock/` không có controller — chỉ có `StockService`/`StockRepository`, và repository chỉ có hàm đọc (`findSkuById`, `findItemById`, `findItemByBarcode`).
- `PurchaseOrderService.createPurchaseOrder` nhận `itemId` từ client nhưng không validate item tồn tại.
- `GoodsReceiptNoteService.confirmGoodsReceiptNote` đọc `WarehouseItem` qua `findItemById` chỉ để lấy `isPerishable`, dùng optional chaining — nếu không tìm thấy thì âm thầm bỏ qua, không tạo mới, không throw.
- Kết luận: muốn thêm SKU mới vào hệ thống hiện tại phải thao tác thẳng vào MongoDB.

## Phạm vi

1. Thêm `POST /api/wms/stock/items` tạo mới `WarehouseItem` — vai trò `ADMIN`, `MANAGER`.
2. Thêm validate `itemId` tồn tại (và chưa soft-delete) trong `PurchaseOrderService.createPurchaseOrder`, throw `STOCK_ITEM_NOT_FOUND` nếu không thấy.

Ngoài phạm vi: update/list/soft-delete `WarehouseItem` (chỉ bổ sung create — đủ để đóng gap hiện tại), sync sang Ecommerce (tạo `WarehouseItem` không phát event; đồng bộ tồn chỉ xảy ra qua `stock.changed` khi có biến động số lượng, nằm ngoài việc tạo master item).

## Thiết kế

### 1. Endpoint tạo WarehouseItem

**File mới**: `apps/wms/src/stock/stock.controller.ts` — controller đầu tiên của `StockModule`. Đăng ký vào `stock.module.ts`: thêm `controllers: [StockController]`.

**Request DTO** — `apps/wms/src/stock/dto/create-warehouse-item.dto.ts`:

```ts
export class CreateWarehouseItemDto {
  @IsString() @MinLength(1)
  sku!: string;

  @IsOptional() @IsString()
  barcode?: string;

  @IsOptional() @IsArray() @IsString({ each: true })
  altBarcodes?: string[];

  @IsString() @MinLength(1)
  name!: string;

  @IsEnum(ItemType)
  type!: ItemType;

  @IsString() @MinLength(1)
  unit!: string;

  @IsOptional() @IsArray() @ValidateNested({ each: true }) @Type(() => AltUnitDto)
  altUnits?: AltUnitDto[];

  @IsOptional() @IsArray() @ValidateNested({ each: true }) @Type(() => ItemAttributeDto)
  attributes?: ItemAttributeDto[];

  @IsOptional() @IsBoolean()
  isPerishable?: boolean;

  @IsOptional() @IsInt() @Min(0)
  nearExpiryDays?: number;
}
```

`AltUnitDto` (`unit`, `factor`) và `ItemAttributeDto` (`name`, `value`, `code`) là nested DTO khớp sub-schema hiện có trong `warehouse-item.schema.ts`.

**Response DTO** — `apps/wms/src/stock/dto/warehouse-item.response.dto.ts`:

```ts
export class WarehouseItemResponseDto {
  @Expose() @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) => obj._id?.toString())
  id!: string;

  @Expose() sku!: string;
  @Expose() barcode?: string;
  @Expose() altBarcodes!: string[];
  @Expose() name!: string;
  @Expose() @ApiProperty({ enum: ItemType }) type!: ItemType;
  @Expose() unit!: string;
  @Expose() @Type(() => AltUnitResponseDto) altUnits!: AltUnitResponseDto[];
  @Expose() @Type(() => ItemAttributeResponseDto) attributes!: ItemAttributeResponseDto[];
  @Expose() isPerishable!: boolean;
  @Expose() nearExpiryDays?: number;
  @Expose() isActive!: boolean;
  @Expose() createdAt!: Date;
  @Expose() updatedAt!: Date;
}
```

Không expose `createdBy`/`updatedBy`/`deletedAt`/`__v`.

**Repository** — thêm vào `StockRepository`:

```ts
findItemBySku(sku: string) {
  return this.itemModel.findOne({ sku }).lean().exec();
}

async createItem(
  data: Omit<WarehouseItem, 'createdBy' | 'updatedBy' | 'deletedAt' | 'isActive'>,
  createdBy: Types.ObjectId,
): Promise<WarehouseItemDocument> {
  const [doc] = await this.itemModel.create([
    { ...data, createdBy, isActive: true },
  ]);
  return doc;
}
```

Không cần transaction — thao tác đơn, không đụng `StockBalance`/`InventoryStock`.

**Service** — thêm vào `StockService`:

```ts
async createWarehouseItem(
  dto: CreateWarehouseItemDto,
  actorId: string,
): Promise<WarehouseItemDocument> {
  const existing = await this.stockRepo.findItemBySku(dto.sku);
  if (existing) {
    throw new AppException('STOCK_ITEM_SKU_CONFLICT');
  }
  return this.stockRepo.createItem(dto, new Types.ObjectId(actorId));
}
```

`findItemBySku` tìm theo `sku` không filter `deletedAt` — vì unique index trên `sku` không phân biệt trạng thái soft-delete, sku trùng với bản ghi đã xóa mềm vẫn phải bị chặn (theo lựa chọn "Throw CONFLICT" đã chốt, không tự khôi phục).

**Error code mới** — thêm vào `apps/wms/src/common/error-codes.ts`:

```ts
STOCK_ITEM_SKU_CONFLICT: {
  status: HttpStatus.CONFLICT,
  message: 'SKU đã tồn tại trong hệ thống',
},
```

**Controller** — copy đúng pattern từ `purchase-order.controller.ts` (đã đọc, xác nhận): `@UseGuards(JwtAuthGuard, RolesGuard)` ở class-level, `@CurrentUser('sub') actorId: string` lấy id trực tiếp dạng string, response build bằng `plainToInstance(Dto, doc.toObject(), TO_OPTS)`:

```ts
const TO_OPTS = { excludeExtraneousValues: true } as const;

@ApiTags('stock')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard, RolesGuard)
@Controller('stock/items')
export class StockController {
  constructor(private readonly stockService: StockService) {}

  @Post()
  @Roles(WmsRole.ADMIN, WmsRole.MANAGER)
  @ApiOperation({ summary: 'Tạo mặt hàng kho mới — [ADMIN, MANAGER]' })
  @ApiCreatedResponse({ type: WarehouseItemResponseDto })
  async create(
    @Body() dto: CreateWarehouseItemDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<WarehouseItemResponseDto> {
    const doc = await this.stockService.createWarehouseItem(dto, actorId);
    return plainToInstance(WarehouseItemResponseDto, doc.toObject(), TO_OPTS);
  }
}
```

`StockService.createWarehouseItem` nhận `actorId: string`, tự `new Types.ObjectId(actorId)` khi gọi repository (khớp kiểu `Types.ObjectId` của `createdBy` trong schema).

### 2. Validate itemId trong PurchaseOrder

Trong `apps/wms/src/purchase-order/purchase-order.service.ts`, method `createPurchaseOrder`: trước khi build `po.items`, với mỗi dòng trong `dto.items`, gọi `stockRepo.findItemById(item.itemId)`. Nếu kết quả null hoặc `deletedAt != null` → `throw new AppException('STOCK_ITEM_NOT_FOUND')`.

Cần inject `StockRepository` vào `PurchaseOrderService` (qua `imports: [StockModule]` trong `purchase-order.module.ts`, export sẵn có từ `StockModule`).

## Test

- `stock.service.spec.ts`: `createWarehouseItem` — tạo thành công (kiểm `isActive: true`, `createdBy` set đúng); conflict khi trùng sku (kể cả bản ghi cũ có `deletedAt` khác null).
- `purchase-order.service.spec.ts`: `createPurchaseOrder` — throw `STOCK_ITEM_NOT_FOUND` khi `itemId` không tồn tại; throw khi item đã bị soft-delete; vẫn tạo PO thành công khi item hợp lệ (test hiện có không bị regressive).

## Rủi ro / lưu ý khi implement

- `warehouse-item.schema.ts` field `attributes`/`altUnits` là sub-document (`@Schema({ _id: false })`) — DTO nested cần `ValidateNested` + `Type()` đúng như PO đã làm với `CreatePurchaseOrderItemDto`.
- Giữ nguyên comment tiếng Việt theo phong cách hiện có trong file.
- Controller pattern (`@UseGuards`, `@CurrentUser('sub')`, `TO_OPTS`, `doc.toObject()`) đã xác nhận trực tiếp từ `purchase-order.controller.ts` — copy y hệt, không cần đoán lại lúc code.
- `PurchaseOrderModule` đã `exports: [PurchaseOrderService]` nhưng **không export** `StockRepository`/`StockModule` sẵn — cần thêm `StockModule` vào `imports` của `purchase-order.module.ts` để inject `StockRepository` vào `PurchaseOrderService`.
