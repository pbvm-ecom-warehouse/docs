# Bổ sung CRUD cho WarehouseItem — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bổ sung 4 endpoint CRUD còn thiếu cho `WarehouseItem` (danh sách + filter, chi tiết, cập nhật, soft-delete), hiện chỉ có `POST` (tạo mới).

**Architecture:** Thêm method mới vào `StockRepository`/`StockService` theo đúng convention `SupplierRepository`/`SupplierService` đã có (filter+phân trang bằng `$or` regex, `findOneAndUpdate`/`updateOne` với `deletedAt: null` guard). Thêm route mới vào `StockController` theo đúng convention `SupplierController` (`GET`/`GET :id`/`PATCH :id`/`DELETE :id`, roles ADMIN/MANAGER, DELETE chỉ ADMIN).

**Tech Stack:** NestJS, Mongoose, class-validator/class-transformer, Jest (`Test.createTestingModule` cho repository test — theo đúng pattern hiện có trong `stock.repository.spec.ts`; constructor injection thủ công cho service test — theo đúng pattern hiện có trong `stock.service.spec.ts`).

## Global Constraints

- `sku` **bất biến sau khi tạo** — `UpdateWarehouseItemDto` không có field `sku` (không kế thừa từ `CreateWarehouseItemDto`).
- Soft-delete **tự do, không check tham chiếu** PO/GRN/InventoryStock — giống hệt `Supplier.deleteSupplier`.
- Không thêm error code mới — dùng lại `STOCK_ITEM_NOT_FOUND` (đã có trong `WMS_ERRORS`, `apps/wms/src/common/error-codes.ts`).
- Không đổi schema `WarehouseItem`, không đổi `POST /stock/items` hiện có.
- Cấm `any` — mọi type rõ ràng (`.claude/rules/dto-conventions.md`).
- Roles: `GET`/`PATCH` → `ADMIN, MANAGER`; `DELETE` → `ADMIN` only (theo đúng `SupplierController`).
- Mọi `@Roles(...)` phải ghi vào `@ApiOperation({ summary: '... — [ROLE1, ROLE2]' })`.
- Response DTO dùng `@Expose()` + `plainToInstance(..., { excludeExtraneousValues: true })`.

---

### Task 1: `StockRepository` — thêm `findItems`, `updateItem`, `softDeleteItem`, `findItemByIdDocument`

**Files:**
- Modify: `apps/wms/src/stock/stock.repository.ts`
- Modify: `apps/wms/src/stock/stock.repository.spec.ts`

**Interfaces:**
- Produces:
  - `StockRepository.findItems(query: QueryWarehouseItemInput): Promise<{ data: WarehouseItemDocument[]; total: number }>` — `QueryWarehouseItemInput = { search?: string; type?: ItemType; isActive?: boolean; page?: number; limit?: number }` (Task 2 sẽ định nghĩa `QueryWarehouseItemDto` khớp shape này).
  - `StockRepository.updateItem(id: string, data: UpdateWarehouseItemData, actorId: string): Promise<WarehouseItemDocument | null>` — `UpdateWarehouseItemData` là `Partial<Omit<CreateWarehouseItemData, 'sku'>>` (khai trong cùng file, cạnh `CreateWarehouseItemData`).
  - `StockRepository.softDeleteItem(id: string, actorId: string): Promise<boolean>`.
  - `StockRepository.findItemByIdDocument(id: string): Promise<WarehouseItemDocument | null>` — khác `findItemById` hiện có (trả `.lean()` — giữ nguyên, dùng nội bộ PO/GRN); method mới này **không** `.lean()`, dùng cho controller gọi `.toObject()`.

- [ ] **Step 1: Đọc file test hiện có để nắm pattern mock**

Đọc `apps/wms/src/stock/stock.repository.spec.ts` — xác nhận dùng `Test.createTestingModule` + `getModelToken`, biến model là `warehouseItemModel = makeModel()` với `makeModel()` mặc định có `findById/findOne/findOneAndUpdate` (mockReturnThis) + `create/select/lean/exec`. Cần bổ sung thêm các chain method còn thiếu cho task này: `sort`, `skip`, `limit`, `countDocuments`, `updateOne`.

- [ ] **Step 2: Viết test thất bại cho `findItems`**

Thêm vào `apps/wms/src/stock/stock.repository.spec.ts`, sau block `describe` hiện có (dùng `describe('findItems', ...)`):

```typescript
describe('findItems', () => {
  it('lọc theo search (sku/name/barcode), type, isActive; luôn kèm deletedAt:null', async () => {
    warehouseItemModel.find = jest.fn().mockReturnThis();
    warehouseItemModel.sort = jest.fn().mockReturnThis();
    warehouseItemModel.skip = jest.fn().mockReturnThis();
    warehouseItemModel.limit = jest.fn().mockReturnThis();
    warehouseItemModel.exec = jest.fn().mockResolvedValue([]);
    warehouseItemModel.countDocuments = jest.fn().mockReturnThis();

    await repo.findItems({
      search: 'cup',
      type: ItemType.CUP_BLANK,
      isActive: true,
      page: 2,
      limit: 10,
    });

    expect(warehouseItemModel.find).toHaveBeenCalledWith({
      deletedAt: null,
      type: ItemType.CUP_BLANK,
      isActive: true,
      $or: [
        { sku: { $regex: 'cup', $options: 'i' } },
        { name: { $regex: 'cup', $options: 'i' } },
        { barcode: { $regex: 'cup', $options: 'i' } },
      ],
    });
    expect(warehouseItemModel.sort).toHaveBeenCalledWith({ sku: 1 });
    expect(warehouseItemModel.skip).toHaveBeenCalledWith(10); // (page-1)*limit = (2-1)*10
    expect(warehouseItemModel.limit).toHaveBeenCalledWith(10);
  });

  it('mặc định page=1, limit=20, không filter gì khi query rỗng', async () => {
    warehouseItemModel.find = jest.fn().mockReturnThis();
    warehouseItemModel.sort = jest.fn().mockReturnThis();
    warehouseItemModel.skip = jest.fn().mockReturnThis();
    warehouseItemModel.limit = jest.fn().mockReturnThis();
    warehouseItemModel.exec = jest.fn().mockResolvedValue([]);
    warehouseItemModel.countDocuments = jest.fn().mockReturnThis();

    await repo.findItems({});

    expect(warehouseItemModel.find).toHaveBeenCalledWith({ deletedAt: null });
    expect(warehouseItemModel.skip).toHaveBeenCalledWith(0);
    expect(warehouseItemModel.limit).toHaveBeenCalledWith(20);
  });

  it('trả về data + total từ countDocuments', async () => {
    const mockDocs = [{ sku: 'A' }, { sku: 'B' }];
    warehouseItemModel.find = jest.fn().mockReturnThis();
    warehouseItemModel.sort = jest.fn().mockReturnThis();
    warehouseItemModel.skip = jest.fn().mockReturnThis();
    warehouseItemModel.limit = jest.fn().mockReturnThis();
    warehouseItemModel.exec = jest
      .fn()
      .mockResolvedValueOnce(mockDocs)
      .mockResolvedValueOnce(2);
    warehouseItemModel.countDocuments = jest.fn().mockReturnThis();

    const result = await repo.findItems({});

    expect(result).toEqual({ data: mockDocs, total: 2 });
  });
});
```

Thêm import `ItemType` vào đầu file test (đã có sẵn `import { WarehouseItem } from './schemas/warehouse-item.schema';` — sửa thành `import { ItemType, WarehouseItem } from './schemas/warehouse-item.schema';`).

- [ ] **Step 3: Chạy test, xác nhận fail**

Run: `pnpm test -- stock.repository.spec.ts -t findItems`
Expected: FAIL — `repo.findItems is not a function`.

- [ ] **Step 4: Thêm `findItems` vào `StockRepository`**

Trong `apps/wms/src/stock/stock.repository.ts`, thêm type input mới ngay sau `CreateWarehouseItemData` (dòng 46), và method mới vào cuối class (sau `findShelfIdsWithItem`, trước dấu `}` đóng class ở dòng 272):

```typescript
export type QueryWarehouseItemInput = {
  search?: string;
  type?: ItemType;
  isActive?: boolean;
  page?: number;
  limit?: number;
};

export type UpdateWarehouseItemData = Partial<
  Omit<CreateWarehouseItemData, 'sku'>
>;
```

```typescript
  /** Danh sách WarehouseItem — filter search (sku/name/barcode) + type + isActive, phân trang. */
  async findItems(
    query: QueryWarehouseItemInput,
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
```

- [ ] **Step 5: Chạy lại test findItems, xác nhận pass**

Run: `pnpm test -- stock.repository.spec.ts -t findItems`
Expected: PASS cả 3 test case.

- [ ] **Step 6: Viết test thất bại cho `updateItem`**

Thêm vào file test:

```typescript
describe('updateItem', () => {
  it('gọi findOneAndUpdate với filter deletedAt:null, set updatedBy', async () => {
    const id = itemId.toString();
    const actorId = new Types.ObjectId().toString();
    warehouseItemModel.findOneAndUpdate = jest.fn().mockReturnThis();
    warehouseItemModel.exec = jest.fn().mockResolvedValue({ _id: itemId });

    await repo.updateItem(id, { name: 'Tên mới' }, actorId);

    expect(warehouseItemModel.findOneAndUpdate).toHaveBeenCalledWith(
      { _id: id, deletedAt: null },
      { name: 'Tên mới', updatedBy: new Types.ObjectId(actorId) },
      { new: true },
    );
  });

  it('trả null khi item không tồn tại hoặc đã xoá', async () => {
    warehouseItemModel.findOneAndUpdate = jest.fn().mockReturnThis();
    warehouseItemModel.exec = jest.fn().mockResolvedValue(null);

    const result = await repo.updateItem(
      itemId.toString(),
      { name: 'X' },
      new Types.ObjectId().toString(),
    );

    expect(result).toBeNull();
  });
});
```

- [ ] **Step 7: Chạy test, xác nhận fail**

Run: `pnpm test -- stock.repository.spec.ts -t updateItem`
Expected: FAIL — `repo.updateItem is not a function`.

- [ ] **Step 8: Thêm `updateItem` vào `StockRepository`**

Thêm vào cuối class:

```typescript
  /** Cập nhật WarehouseItem — không sửa sku (bất biến sau khi tạo). */
  async updateItem(
    id: string,
    data: UpdateWarehouseItemData,
    actorId: string,
  ): Promise<WarehouseItemDocument | null> {
    return this.itemModel
      .findOneAndUpdate(
        { _id: id, deletedAt: null },
        { ...data, updatedBy: new Types.ObjectId(actorId) },
        { new: true },
      )
      .exec();
  }
```

- [ ] **Step 9: Chạy lại test updateItem, xác nhận pass**

Run: `pnpm test -- stock.repository.spec.ts -t updateItem`
Expected: PASS cả 2 test case.

- [ ] **Step 10: Viết test thất bại cho `softDeleteItem`**

```typescript
describe('softDeleteItem', () => {
  it('set deletedAt + updatedBy khi tìm thấy item chưa xoá', async () => {
    const id = itemId.toString();
    const actorId = new Types.ObjectId().toString();
    warehouseItemModel.updateOne = jest
      .fn()
      .mockReturnValue({ exec: jest.fn().mockResolvedValue({ modifiedCount: 1 }) });

    const result = await repo.softDeleteItem(id, actorId);

    expect(warehouseItemModel.updateOne).toHaveBeenCalledWith(
      { _id: id, deletedAt: null },
      { deletedAt: expect.any(Date), updatedBy: new Types.ObjectId(actorId) },
    );
    expect(result).toBe(true);
  });

  it('trả false khi không tìm thấy item (đã xoá hoặc không tồn tại)', async () => {
    warehouseItemModel.updateOne = jest
      .fn()
      .mockReturnValue({ exec: jest.fn().mockResolvedValue({ modifiedCount: 0 }) });

    const result = await repo.softDeleteItem(
      itemId.toString(),
      new Types.ObjectId().toString(),
    );

    expect(result).toBe(false);
  });
});
```

- [ ] **Step 11: Chạy test, xác nhận fail**

Run: `pnpm test -- stock.repository.spec.ts -t softDeleteItem`
Expected: FAIL — `repo.softDeleteItem is not a function`.

- [ ] **Step 12: Thêm `softDeleteItem` vào `StockRepository`**

```typescript
  /** Soft-delete WarehouseItem — tự do, không check tham chiếu PO/GRN/InventoryStock. */
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

- [ ] **Step 13: Chạy lại test softDeleteItem, xác nhận pass**

Run: `pnpm test -- stock.repository.spec.ts -t softDeleteItem`
Expected: PASS cả 2 test case.

- [ ] **Step 14: Viết test thất bại cho `findItemByIdDocument`**

```typescript
describe('findItemByIdDocument', () => {
  it('gọi findById không lean, trả document đầy đủ', async () => {
    const id = itemId.toString();
    const mockDoc = { _id: itemId, sku: 'SKU-1' };
    warehouseItemModel.findById = jest.fn().mockReturnThis();
    warehouseItemModel.exec = jest.fn().mockResolvedValue(mockDoc);

    const result = await repo.findItemByIdDocument(id);

    expect(warehouseItemModel.findById).toHaveBeenCalledWith(id);
    expect(warehouseItemModel.lean).not.toHaveBeenCalled();
    expect(result).toBe(mockDoc);
  });
});
```

- [ ] **Step 15: Chạy test, xác nhận fail**

Run: `pnpm test -- stock.repository.spec.ts -t findItemByIdDocument`
Expected: FAIL — `repo.findItemByIdDocument is not a function`.

- [ ] **Step 16: Thêm `findItemByIdDocument` vào `StockRepository`**

Thêm ngay sau `findItemById` hiện có (dòng 68-71):

```typescript
  /** Đọc WarehouseItem theo id, KHÔNG lean — dùng cho controller (cần .toObject() cho response DTO). */
  findItemByIdDocument(itemId: string) {
    return this.itemModel.findById(itemId).exec();
  }
```

- [ ] **Step 17: Chạy lại toàn bộ file test, xác nhận pass**

Run: `pnpm test -- stock.repository.spec.ts`
Expected: PASS toàn bộ file (test cũ + test mới).

- [ ] **Step 18: Build để xác nhận không lỗi type**

Run: `pnpm build`
Expected: build thành công.

- [ ] **Step 19: Commit**

```bash
git add apps/wms/src/stock/stock.repository.ts apps/wms/src/stock/stock.repository.spec.ts
git commit -m "feat(wms/stock): thêm findItems/updateItem/softDeleteItem/findItemByIdDocument"
```

---

### Task 2: DTO mới — `QueryWarehouseItemDto`, `UpdateWarehouseItemDto`

**Files:**
- Create: `apps/wms/src/stock/dto/query-warehouse-item.dto.ts`
- Modify: `apps/wms/src/stock/dto/create-warehouse-item.dto.ts`

**Interfaces:**
- Consumes: `QueryWarehouseItemInput`, `UpdateWarehouseItemData` (Task 1).
- Produces: `QueryWarehouseItemDto` (shape khớp `QueryWarehouseItemInput`), `UpdateWarehouseItemDto` (shape khớp `UpdateWarehouseItemData`, không có field `sku`) — Task 3 (service) và Task 4 (controller) dùng 2 DTO này.

- [ ] **Step 1: Tạo `QueryWarehouseItemDto`**

Tạo file `apps/wms/src/stock/dto/query-warehouse-item.dto.ts`:

```typescript
import { ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  IsBoolean,
  IsEnum,
  IsInt,
  IsOptional,
  IsString,
  Max,
  Min,
} from 'class-validator';
import { ItemType } from '../schemas/warehouse-item.schema';

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

- [ ] **Step 2: Thêm `UpdateWarehouseItemDto` vào `create-warehouse-item.dto.ts`**

Trong `apps/wms/src/stock/dto/create-warehouse-item.dto.ts`, sửa dòng import đầu file (dòng 1) từ:

```typescript
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
```

thành:

```typescript
import {
  ApiProperty,
  ApiPropertyOptional,
  OmitType,
  PartialType,
} from '@nestjs/swagger';
```

Thêm vào cuối file (sau dấu `}` đóng `CreateWarehouseItemDto`, dòng 122):

```typescript

export class UpdateWarehouseItemDto extends PartialType(
  OmitType(CreateWarehouseItemDto, ['sku'] as const),
) {}
```

- [ ] **Step 3: Build để xác nhận DTO hợp lệ**

Run: `pnpm build`
Expected: build thành công — `PartialType(OmitType(...))` là pattern chuẩn `@nestjs/swagger`, không cần test riêng cho DTO thuần khai báo (không có logic).

- [ ] **Step 4: Commit**

```bash
git add apps/wms/src/stock/dto/query-warehouse-item.dto.ts apps/wms/src/stock/dto/create-warehouse-item.dto.ts
git commit -m "feat(wms/stock): thêm QueryWarehouseItemDto và UpdateWarehouseItemDto"
```

---

### Task 3: `StockService` — thêm `listWarehouseItems`, `getWarehouseItem`, `updateWarehouseItem`, `deleteWarehouseItem`

**Files:**
- Modify: `apps/wms/src/stock/stock.service.ts`
- Modify: `apps/wms/src/stock/stock.service.spec.ts`

**Interfaces:**
- Consumes: `StockRepository.findItems`, `StockRepository.updateItem`, `StockRepository.softDeleteItem`, `StockRepository.findItemByIdDocument` (Task 1); `QueryWarehouseItemDto`, `UpdateWarehouseItemDto` (Task 2).
- Produces:
  - `StockService.listWarehouseItems(query: QueryWarehouseItemDto): Promise<{ data: WarehouseItemDocument[]; total: number }>`
  - `StockService.getWarehouseItem(id: string): Promise<WarehouseItemDocument>` — throw `AppException('STOCK_ITEM_NOT_FOUND')`
  - `StockService.updateWarehouseItem(id: string, dto: UpdateWarehouseItemDto, actorId: string): Promise<WarehouseItemDocument>` — throw `AppException('STOCK_ITEM_NOT_FOUND')`
  - `StockService.deleteWarehouseItem(id: string, actorId: string): Promise<void>` — throw `AppException('STOCK_ITEM_NOT_FOUND')`

  Task 4 (controller) gọi 4 method này.

- [ ] **Step 1: Đọc file test hiện có để nắm pattern mock**

Đã xác nhận ở bước brainstorming: `makeRepo()` factory trả `jest.fn()` cho từng method dùng, constructor injection thủ công `new StockService(repo as never, queue as never)`.

- [ ] **Step 2: Cập nhật `makeRepo()` — thêm mock cho 4 method mới**

Trong `apps/wms/src/stock/stock.service.spec.ts`, sửa `makeRepo()` (dòng 4-8) từ:

```typescript
const makeRepo = () => ({
  findSkuById: jest.fn(),
  findItemBySku: jest.fn(),
  createItem: jest.fn(),
});
```

thành:

```typescript
const makeRepo = () => ({
  findSkuById: jest.fn(),
  findItemBySku: jest.fn(),
  createItem: jest.fn(),
  findItems: jest.fn(),
  findItemByIdDocument: jest.fn(),
  updateItem: jest.fn(),
  softDeleteItem: jest.fn(),
});
```

- [ ] **Step 3: Viết test thất bại cho `listWarehouseItems`**

Thêm vào cuối file (sau `describe('publishAvailableForItem', ...)`, trước dấu `}` đóng `describe('StockService', ...)` ở dòng 113):

```typescript
  describe('listWarehouseItems', () => {
    it('forward query xuống repo.findItems, trả nguyên kết quả', async () => {
      const mockResult = { data: [{ sku: 'A' }], total: 1 };
      repo.findItems.mockResolvedValue(mockResult);

      const result = await svc.listWarehouseItems({ search: 'a' });

      expect(repo.findItems).toHaveBeenCalledWith({ search: 'a' });
      expect(result).toBe(mockResult);
    });
  });
```

- [ ] **Step 4: Chạy test, xác nhận fail**

Run: `pnpm test -- stock.service.spec.ts -t listWarehouseItems`
Expected: FAIL — `svc.listWarehouseItems is not a function`.

- [ ] **Step 5: Thêm `listWarehouseItems` vào `StockService`**

Trong `apps/wms/src/stock/stock.service.ts`, import `QueryWarehouseItemInput` từ repository (sửa dòng 7-8 import hiện có), thêm import `QueryWarehouseItemDto`, `UpdateWarehouseItemDto` từ dto:

```typescript
import { StockRepository } from './stock.repository';
import type {
  CreateWarehouseItemData,
  UpdateWarehouseItemData,
} from './stock.repository';
import type { WarehouseItemDocument } from './schemas/warehouse-item.schema';
import type { QueryWarehouseItemDto } from './dto/query-warehouse-item.dto';
import type { UpdateWarehouseItemDto } from './dto/create-warehouse-item.dto';
```

Thêm method vào cuối class (sau `createWarehouseItem`, trước dấu `}` đóng class ở dòng 53):

```typescript
  async listWarehouseItems(
    query: QueryWarehouseItemDto,
  ): Promise<{ data: WarehouseItemDocument[]; total: number }> {
    return this.stockRepo.findItems(query);
  }
```

- [ ] **Step 6: Chạy lại test listWarehouseItems, xác nhận pass**

Run: `pnpm test -- stock.service.spec.ts -t listWarehouseItems`
Expected: PASS.

- [ ] **Step 7: Viết test thất bại cho `getWarehouseItem`**

```typescript
  describe('getWarehouseItem', () => {
    it('trả document khi tìm thấy', async () => {
      const mockDoc = { _id: new Types.ObjectId(), sku: 'SKU-1' };
      repo.findItemByIdDocument.mockResolvedValue(mockDoc);

      const result = await svc.getWarehouseItem('item1');

      expect(repo.findItemByIdDocument).toHaveBeenCalledWith('item1');
      expect(result).toBe(mockDoc);
    });

    it('throw STOCK_ITEM_NOT_FOUND khi không tìm thấy', async () => {
      repo.findItemByIdDocument.mockResolvedValue(null);

      await expect(svc.getWarehouseItem('missing')).rejects.toMatchObject({
        code: 'STOCK_ITEM_NOT_FOUND',
      });
    });
  });
```

- [ ] **Step 8: Chạy test, xác nhận fail**

Run: `pnpm test -- stock.service.spec.ts -t getWarehouseItem`
Expected: FAIL — `svc.getWarehouseItem is not a function`.

- [ ] **Step 9: Thêm `getWarehouseItem` vào `StockService`**

```typescript
  async getWarehouseItem(id: string): Promise<WarehouseItemDocument> {
    const doc = await this.stockRepo.findItemByIdDocument(id);
    if (!doc) throw new AppException('STOCK_ITEM_NOT_FOUND');
    return doc;
  }
```

- [ ] **Step 10: Chạy lại test getWarehouseItem, xác nhận pass**

Run: `pnpm test -- stock.service.spec.ts -t getWarehouseItem`
Expected: PASS cả 2 test case.

- [ ] **Step 11: Viết test thất bại cho `updateWarehouseItem`**

```typescript
  describe('updateWarehouseItem', () => {
    const actorId = new Types.ObjectId().toString();

    it('trả document đã cập nhật khi thành công', async () => {
      const mockDoc = { _id: new Types.ObjectId(), name: 'Tên mới' };
      repo.updateItem.mockResolvedValue(mockDoc);

      const result = await svc.updateWarehouseItem(
        'item1',
        { name: 'Tên mới' },
        actorId,
      );

      expect(repo.updateItem).toHaveBeenCalledWith(
        'item1',
        { name: 'Tên mới' },
        actorId,
      );
      expect(result).toBe(mockDoc);
    });

    it('throw STOCK_ITEM_NOT_FOUND khi không tìm thấy/đã xoá', async () => {
      repo.updateItem.mockResolvedValue(null);

      await expect(
        svc.updateWarehouseItem('missing', { name: 'X' }, actorId),
      ).rejects.toMatchObject({ code: 'STOCK_ITEM_NOT_FOUND' });
    });
  });
```

- [ ] **Step 12: Chạy test, xác nhận fail**

Run: `pnpm test -- stock.service.spec.ts -t updateWarehouseItem`
Expected: FAIL — `svc.updateWarehouseItem is not a function`.

- [ ] **Step 13: Thêm `updateWarehouseItem` vào `StockService`**

```typescript
  async updateWarehouseItem(
    id: string,
    dto: UpdateWarehouseItemDto,
    actorId: string,
  ): Promise<WarehouseItemDocument> {
    const doc = await this.stockRepo.updateItem(
      id,
      dto as UpdateWarehouseItemData,
      actorId,
    );
    if (!doc) throw new AppException('STOCK_ITEM_NOT_FOUND');
    return doc;
  }
```

- [ ] **Step 14: Chạy lại test updateWarehouseItem, xác nhận pass**

Run: `pnpm test -- stock.service.spec.ts -t updateWarehouseItem`
Expected: PASS cả 2 test case.

- [ ] **Step 15: Viết test thất bại cho `deleteWarehouseItem`**

```typescript
  describe('deleteWarehouseItem', () => {
    const actorId = new Types.ObjectId().toString();

    it('gọi softDeleteItem, không throw khi thành công', async () => {
      repo.softDeleteItem.mockResolvedValue(true);

      await expect(
        svc.deleteWarehouseItem('item1', actorId),
      ).resolves.toBeUndefined();
      expect(repo.softDeleteItem).toHaveBeenCalledWith('item1', actorId);
    });

    it('throw STOCK_ITEM_NOT_FOUND khi không tìm thấy/đã xoá', async () => {
      repo.softDeleteItem.mockResolvedValue(false);

      await expect(
        svc.deleteWarehouseItem('missing', actorId),
      ).rejects.toMatchObject({ code: 'STOCK_ITEM_NOT_FOUND' });
    });
  });
```

- [ ] **Step 16: Chạy test, xác nhận fail**

Run: `pnpm test -- stock.service.spec.ts -t deleteWarehouseItem`
Expected: FAIL — `svc.deleteWarehouseItem is not a function`.

- [ ] **Step 17: Thêm `deleteWarehouseItem` vào `StockService`**

```typescript
  async deleteWarehouseItem(id: string, actorId: string): Promise<void> {
    const deleted = await this.stockRepo.softDeleteItem(id, actorId);
    if (!deleted) throw new AppException('STOCK_ITEM_NOT_FOUND');
  }
```

- [ ] **Step 18: Chạy lại toàn bộ file test, xác nhận pass**

Run: `pnpm test -- stock.service.spec.ts`
Expected: PASS toàn bộ file (test cũ + 8 test mới).

- [ ] **Step 19: Build để xác nhận không lỗi type**

Run: `pnpm build`
Expected: build thành công.

- [ ] **Step 20: Commit**

```bash
git add apps/wms/src/stock/stock.service.ts apps/wms/src/stock/stock.service.spec.ts
git commit -m "feat(wms/stock): thêm listWarehouseItems/getWarehouseItem/updateWarehouseItem/deleteWarehouseItem"
```

---

### Task 4: `StockController` — thêm route `GET`/`GET :id`/`PATCH :id`/`DELETE :id`

**Files:**
- Modify: `apps/wms/src/stock/stock.controller.ts`

**Interfaces:**
- Consumes: `StockService.listWarehouseItems`, `StockService.getWarehouseItem`, `StockService.updateWarehouseItem`, `StockService.deleteWarehouseItem` (Task 3); `QueryWarehouseItemDto` (Task 2); `WarehouseItemResponseDto` (đã có, không đổi).

- [ ] **Step 1: Thêm import mới vào `stock.controller.ts`**

Sửa toàn bộ phần import ở đầu `apps/wms/src/stock/stock.controller.ts` (dòng 1-19) từ:

```typescript
// apps/wms/src/stock/stock.controller.ts
import { Body, Controller, Post, UseGuards } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiCreatedResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  CurrentUser,
  JwtAuthGuard,
  Roles,
  RolesGuard,
  WmsRole,
} from '@app/auth';
import { plainToInstance } from 'class-transformer';
import { StockService } from './stock.service';
import { CreateWarehouseItemDto } from './dto/create-warehouse-item.dto';
import { WarehouseItemResponseDto } from './dto/warehouse-item.response.dto';
```

thành:

```typescript
// apps/wms/src/stock/stock.controller.ts
import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiCreatedResponse,
  ApiNoContentResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  CurrentUser,
  JwtAuthGuard,
  Roles,
  RolesGuard,
  WmsRole,
} from '@app/auth';
import { plainToInstance } from 'class-transformer';
import { StockService } from './stock.service';
import {
  CreateWarehouseItemDto,
  UpdateWarehouseItemDto,
} from './dto/create-warehouse-item.dto';
import { QueryWarehouseItemDto } from './dto/query-warehouse-item.dto';
import { WarehouseItemResponseDto } from './dto/warehouse-item.response.dto';
```

- [ ] **Step 2: Thêm 4 route mới sau method `create` hiện có**

Trong `apps/wms/src/stock/stock.controller.ts`, thêm vào ngay sau method `create` (sau dòng 40, trước dấu `}` đóng class):

```typescript
  @Get()
  @Roles(WmsRole.ADMIN, WmsRole.MANAGER)
  @ApiOperation({
    summary: 'Danh sách mặt hàng kho — [ADMIN, MANAGER]',
  })
  @ApiOkResponse({ type: [WarehouseItemResponseDto] })
  async list(@Query() query: QueryWarehouseItemDto): Promise<{
    data: WarehouseItemResponseDto[];
    total: number;
    page: number;
    limit: number;
  }> {
    const { data, total } = await this.svc.listWarehouseItems(query);
    return {
      data: plainToInstance(
        WarehouseItemResponseDto,
        data.map((d) => d.toObject()),
        TO_OPTS,
      ),
      total,
      page: query.page ?? 1,
      limit: query.limit ?? 20,
    };
  }

  @Get(':id')
  @Roles(WmsRole.ADMIN, WmsRole.MANAGER)
  @ApiOperation({ summary: 'Chi tiết mặt hàng kho — [ADMIN, MANAGER]' })
  @ApiOkResponse({ type: WarehouseItemResponseDto })
  async getOne(@Param('id') id: string): Promise<WarehouseItemResponseDto> {
    const doc = await this.svc.getWarehouseItem(id);
    return plainToInstance(WarehouseItemResponseDto, doc.toObject(), TO_OPTS);
  }

  @Patch(':id')
  @Roles(WmsRole.ADMIN, WmsRole.MANAGER)
  @ApiOperation({
    summary: 'Cập nhật mặt hàng kho (không sửa sku) — [ADMIN, MANAGER]',
  })
  @ApiOkResponse({ type: WarehouseItemResponseDto })
  async update(
    @Param('id') id: string,
    @Body() dto: UpdateWarehouseItemDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<WarehouseItemResponseDto> {
    const doc = await this.svc.updateWarehouseItem(id, dto, actorId);
    return plainToInstance(WarehouseItemResponseDto, doc.toObject(), TO_OPTS);
  }

  @Delete(':id')
  @Roles(WmsRole.ADMIN)
  @HttpCode(HttpStatus.NO_CONTENT)
  @ApiOperation({ summary: 'Xoá mặt hàng kho (soft-delete) — [ADMIN]' })
  @ApiNoContentResponse()
  async remove(
    @Param('id') id: string,
    @CurrentUser('sub') actorId: string,
  ): Promise<void> {
    await this.svc.deleteWarehouseItem(id, actorId);
  }
```

- [ ] **Step 3: Build để xác nhận route hợp lệ**

Run: `pnpm build`
Expected: build thành công.

- [ ] **Step 4: Chạy toàn bộ test suite của app WMS**

Run: `pnpm test -- apps/wms`
Expected: PASS toàn bộ (không phá test nào khác).

- [ ] **Step 5: Chạy toàn bộ test suite monorepo**

Run: `pnpm test`
Expected: PASS toàn bộ.

- [ ] **Step 6: Khởi động app, xác nhận route map đúng (smoke test)**

Run: `pnpm start:wms` (chạy nền hoặc terminal riêng). Nếu môi trường không có MongoDB/Redis thật, app sẽ fail ở bước kết nối DB — đó là bình thường, chỉ cần xác nhận log route-mapping xuất hiện đủ 4 route mới trước khi lỗi kết nối DB (nếu có):
```
Mapped {/api/wms/stock/items, GET} route
Mapped {/api/wms/stock/items/:id, GET} route
Mapped {/api/wms/stock/items/:id, PATCH} route
Mapped {/api/wms/stock/items/:id, DELETE} route
```
Nếu có MongoDB/Redis thật, dùng Swagger UI (`/api/docs`) để gọi thử: tạo 1 item qua `POST`, sau đó `GET` danh sách thấy item vừa tạo, `GET :id` thấy chi tiết, `PATCH :id` sửa `name` thành công (thử gửi kèm `sku` trong body — xác nhận field đó bị bỏ qua vì không có trong `UpdateWarehouseItemDto`), `DELETE :id` trả 204, gọi lại `GET :id` thấy `STOCK_ITEM_NOT_FOUND`.

- [ ] **Step 7: Commit**

```bash
git add apps/wms/src/stock/stock.controller.ts
git commit -m "feat(wms/stock): thêm route GET/PATCH/DELETE cho warehouse items"
```

---

## Self-Review (đã chạy trước khi giao plan)

**1. Spec coverage:**
- `findItems` filter search/type/isActive + phân trang → Task 1. ✓
- `updateItem` không cho sửa sku (loại field khỏi DTO, không phải logic chặn ở service/repo) → Task 2 (`UpdateWarehouseItemDto` không kế thừa `sku`). ✓
- `softDeleteItem` tự do không check tham chiếu → Task 1 (không có logic check PO/GRN nào được thêm). ✓
- `findItemByIdDocument` tách biệt `findItemById` (giữ nguyên `.lean()` cho call site nội bộ) → Task 1. ✓
- 4 route `GET`/`GET :id`/`PATCH :id`/`DELETE :id`, roles đúng (`DELETE` chỉ ADMIN) → Task 4. ✓
- Dùng lại `STOCK_ITEM_NOT_FOUND`, không thêm code lỗi mới → Task 3. ✓
- Response DTO dùng lại `WarehouseItemResponseDto` đã có (không đổi) → Task 4. ✓

**2. Placeholder scan:** Không còn "TBD"/"tương tự Task N" — mọi step có code đầy đủ, copy chính xác dòng import/method hiện có trước khi viết diff.

**3. Type consistency:** `QueryWarehouseItemInput` (Task 1, repository) ↔ `QueryWarehouseItemDto` (Task 2, DTO) ↔ tham số `query` trong `StockService.listWarehouseItems`/`StockController.list` (Task 3, 4) — cùng shape `{ search?, type?, isActive?, page?, limit? }` xuyên suốt. `UpdateWarehouseItemData` (Task 1) ↔ `UpdateWarehouseItemDto` (Task 2) ↔ tham số `dto` trong `updateWarehouseItem`/`update` (Task 3, 4) — Task 3 Step 13 dùng `dto as UpdateWarehouseItemData` để khớp kiểu giữa 2 type song song (DTO có decorator, type thuần không) — đây là pattern nhất quán với cách `CreateWarehouseItemDto`/`CreateWarehouseItemData` đã tách biệt từ trước (xem `stock.service.ts` hiện có, `createWarehouseItem(data: CreateWarehouseItemData, ...)` nhận tham số đã gõ theo type thuần dù controller truyền vào là instance DTO).
