# SupplierItem hỗ trợ nhiều NCC/SKU Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Đổi `SupplierItem` từ mô hình 1 SKU ↔ 1 NCC chính (unique `itemId`) sang mô hình n-n: mỗi cặp (SKU, NCC) là 1 báo giá độc lập, khớp thực tế 1 SKU mua được từ nhiều NCC.

**Architecture:** Đổi unique index từ `itemId` sang compound `{itemId, supplierId}` trong Mongoose schema. Repository tách API "list mọi báo giá của 1 SKU" và "tìm đúng 1 cặp (SKU, NCC)". Service/Controller/PO cập nhật theo. Không migration dữ liệu (chưa có dữ liệu thật).

**Tech Stack:** NestJS, Mongoose, Jest, class-validator/class-transformer (theo convention sẵn có trong `apps/wms`).

## Global Constraints

- Service dùng `AppException` từ `@app/common`, không throw NestJS exception thô (xem `.claude/rules/error-handling.md`).
- Mọi error code domain (kể cả WMS-only) đặt trong `libs/common/src/errors/error-codes.ts` (`ERROR_CATALOG`) — **không** có file `apps/wms/src/common/error-codes.ts` riêng trong codebase hiện tại (khác mô tả cũ trong rule doc — theo code thực tế).
- Response DTO dùng `@Expose()` + `plainToInstance(..., { excludeExtraneousValues: true })`, field `_id` map ra `id` qua `@Transform`.
- Chạy test bằng `NODE_OPTIONS=--experimental-vm-modules npx jest <path>` (không dùng `npx jest` trực tiếp — thư viện `jose`/`firebase-admin` cần flag ESM, xem `package.json` script `test`).
- Comment tiếng Việt giải thích *vì sao*, không giải thích *cái gì*.

---

### Task 1: Đổi unique index trên schema `SupplierItem`

**Files:**
- Modify: `apps/wms/src/supplier/schemas/supplier-item.schema.ts`
- Modify: `apps/wms/src/supplier/schemas/supplier-item.schema.spec.ts`

**Interfaces:**
- Produces: `SupplierItemSchema` với compound unique index `{itemId: 1, supplierId: 1}` thay cho `itemId: {unique: true}` đơn lẻ. Field list không đổi.

- [ ] **Step 1: Sửa test kỳ vọng — compound index thay vì single unique**

Thay nội dung `apps/wms/src/supplier/schemas/supplier-item.schema.spec.ts`:

```ts
import { SupplierItemSchema } from './supplier-item.schema';

describe('SupplierItem schema', () => {
  it('schema có đủ field cần thiết', () => {
    const paths = SupplierItemSchema.paths;
    expect(paths['itemId']).toBeDefined();
    expect(paths['supplierId']).toBeDefined();
    expect(paths['purchasePrice']).toBeDefined();
    expect(paths['leadTimeDays']).toBeDefined();
    expect(paths['minOrderQty']).toBeDefined();
    expect(paths['isActive']).toBeDefined();
  });

  it('itemId KHÔNG unique riêng lẻ (1 SKU có thể có nhiều NCC báo giá)', () => {
    const itemIdPath = SupplierItemSchema.path('itemId') as {
      options?: { unique?: boolean };
    };
    expect(itemIdPath.options?.unique).toBeFalsy();
  });

  it('có compound unique index {itemId, supplierId} — 1 cặp SKU+NCC chỉ 1 báo giá', () => {
    const indexes = SupplierItemSchema.indexes();
    const compoundIndex = indexes.find(
      ([fields]) =>
        fields['itemId'] === 1 &&
        fields['supplierId'] === 1 &&
        Object.keys(fields).length === 2,
    );
    expect(compoundIndex).toBeDefined();
    const [, options] = compoundIndex!;
    expect(options.unique).toBe(true);
  });
});
```

- [ ] **Step 2: Chạy test để xác nhận fail (schema chưa đổi)**

Run: `NODE_OPTIONS=--experimental-vm-modules npx jest apps/wms/src/supplier/schemas/supplier-item.schema.spec.ts -v`
Expected: FAIL — 2 test mới đều fail (`itemId` vẫn unique, chưa có compound index).

- [ ] **Step 3: Sửa schema**

Trong `apps/wms/src/supplier/schemas/supplier-item.schema.ts`, đổi field `itemId`:

```ts
  /** WarehouseItem._id — không unique riêng lẻ: 1 SKU có thể có nhiều NCC báo giá
   * song song (xem compound index bên dưới, ràng buộc theo cặp itemId+supplierId). */
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  itemId!: Types.ObjectId;
```

Ở cuối file, sau dòng `export const SupplierItemSchema = SchemaFactory.createForClass(SupplierItem);`, thêm:

```ts
// 1 cặp (SKU, NCC) chỉ có đúng 1 báo giá — nhiều NCC có thể cùng báo giá 1 SKU,
// nhưng không được trùng 2 báo giá cho cùng 1 cặp.
SupplierItemSchema.index({ itemId: 1, supplierId: 1 }, { unique: true });
```

File hoàn chỉnh sau khi sửa (`apps/wms/src/supplier/schemas/supplier-item.schema.ts`):

```ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, SchemaTypes, Types } from 'mongoose';

/**
 * Danh mục giá: mỗi cặp (SKU, NCC) là 1 báo giá độc lập — 1 SKU có thể mua
 * được từ nhiều NCC khác nhau, cần lưu song song để so sánh giá trước khi
 * đặt PO (issue #30). Không soft-delete — toggle isActive khi hết hiệu lực.
 * updatedAt tự update qua timestamps.
 */
@Schema({
  collection: 'supplier_items',
  timestamps: { createdAt: false, updatedAt: true },
})
export class SupplierItem {
  /** WarehouseItem._id — không unique riêng lẻ: 1 SKU có thể có nhiều NCC báo giá
   * song song (xem compound index bên dưới, ràng buộc theo cặp itemId+supplierId). */
  @Prop({ type: SchemaTypes.ObjectId, required: true })
  itemId!: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId, required: true })
  supplierId!: Types.ObjectId;

  /** Mã hàng phía NCC để đối chiếu khi đặt hàng */
  @Prop()
  supplierItemCode?: string;

  /** Giá nhập gợi ý (sửa tay được khi tạo PO) */
  @Prop({ type: Number, required: true, min: 0 })
  purchasePrice!: number;

  /** Số ngày giao dự kiến */
  @Prop({ type: Number, min: 0 })
  leadTimeDays?: number;

  /** Số lượng đặt tối thiểu (MOQ) */
  @Prop({ type: Number, min: 0 })
  minOrderQty?: number;

  /** false = báo giá hết hiệu lực, không gợi ý khi tạo PO */
  @Prop({ default: true })
  isActive!: boolean;
}

export type SupplierItemDocument = HydratedDocument<SupplierItem>;
export const SupplierItemSchema = SchemaFactory.createForClass(SupplierItem);

// 1 cặp (SKU, NCC) chỉ có đúng 1 báo giá — nhiều NCC có thể cùng báo giá 1 SKU,
// nhưng không được trùng 2 báo giá cho cùng 1 cặp.
SupplierItemSchema.index({ itemId: 1, supplierId: 1 }, { unique: true });
```

- [ ] **Step 4: Chạy test để xác nhận pass**

Run: `NODE_OPTIONS=--experimental-vm-modules npx jest apps/wms/src/supplier/schemas/supplier-item.schema.spec.ts -v`
Expected: PASS — 3/3 test.

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/supplier/schemas/supplier-item.schema.ts apps/wms/src/supplier/schemas/supplier-item.schema.spec.ts
git commit -m "$(cat <<'EOF'
feat(supplier): đổi SupplierItem sang compound unique {itemId, supplierId}

1 SKU giờ có thể có nhiều NCC báo giá song song — khớp thực tế mua hàng
(issue #30). Ràng buộc duy nhất còn lại: 1 cặp (SKU, NCC) chỉ 1 báo giá.
EOF
)"
```

---

### Task 2: Thêm error code `SUPPLIER_ITEM_PAIR_CONFLICT`, sửa message `SUPPLIER_ITEM_SKU_EXISTS` không dùng đến

**Files:**
- Modify: `libs/common/src/errors/error-codes.ts`

**Interfaces:**
- Produces: mã lỗi `SUPPLIER_ITEM_PAIR_CONFLICT` (409) trong `ERROR_CATALOG`, dùng ở Task 4 khi update `SupplierItem` gây trùng compound key.

- [ ] **Step 1: Sửa `ERROR_CATALOG`**

Trong `libs/common/src/errors/error-codes.ts`, tìm khối:

```ts
  SUPPLIER_ITEM_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy thông tin giá của SKU này',
  },
  SUPPLIER_ITEM_SKU_EXISTS: {
    status: HttpStatus.CONFLICT,
    message: 'SKU này đã có NCC chính — cập nhật thay vì tạo mới',
  },
```

Thay bằng (xóa `SUPPLIER_ITEM_SKU_EXISTS` — không còn dùng được sau khi bỏ ràng buộc 1 SKU = 1 NCC chính, không có nơi nào tham chiếu code này trong codebase; thêm `SUPPLIER_ITEM_PAIR_CONFLICT` cho tình huống mới):

```ts
  SUPPLIER_ITEM_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy báo giá NCC cho SKU này',
  },
  SUPPLIER_ITEM_PAIR_CONFLICT: {
    status: HttpStatus.CONFLICT,
    message: 'Cặp SKU và NCC này đã có báo giá — cập nhật thay vì tạo mới',
  },
```

- [ ] **Step 2: Kiểm tra không còn nơi nào tham chiếu `SUPPLIER_ITEM_SKU_EXISTS`**

Run: `grep -rn "SUPPLIER_ITEM_SKU_EXISTS" apps libs --include="*.ts"`
Expected: không có kết quả nào (đã xác nhận trước khi viết plan — dead code, an toàn xóa).

- [ ] **Step 3: Build để xác nhận không lỗi type**

Run: `npx tsc --noEmit -p tsconfig.json 2>&1 | grep -i "error-codes\|SUPPLIER_ITEM_SKU_EXISTS"`
Expected: không có output.

- [ ] **Step 4: Commit**

```bash
git add libs/common/src/errors/error-codes.ts
git commit -m "$(cat <<'EOF'
feat(errors): thêm SUPPLIER_ITEM_PAIR_CONFLICT, bỏ SUPPLIER_ITEM_SKU_EXISTS

SUPPLIER_ITEM_SKU_EXISTS mô tả ràng buộc "1 SKU = 1 NCC chính" đã bị bỏ
(issue #30) và không có nơi nào dùng — thay bằng mã lỗi khớp compound
key mới {itemId, supplierId}.
EOF
)"
```

---

### Task 3: Repository — tách `findSupplierItemsByItemId` (mảng) và `findSupplierItemByItemAndSupplier` (1 bản ghi)

**Files:**
- Modify: `apps/wms/src/supplier/supplier.repository.ts`
- Modify: `apps/wms/src/supplier/supplier.repository.spec.ts`

**Interfaces:**
- Consumes: `SupplierItemDocument` (từ `./schemas/supplier-item.schema`), Mongoose `Model<SupplierItemDocument>`.
- Produces:
  - `findSupplierItemsByItemId(itemId: string): Promise<SupplierItemDocument[]>` — thay cho `findSupplierItemByItemId` (đã xóa).
  - `findSupplierItemByItemAndSupplier(itemId: string, supplierId: string): Promise<SupplierItemDocument | null>` — mới.
  - `updateSupplierItem` giữ nguyên chữ ký, nhưng bắt lỗi trùng khóa 11000 và ném lại `AppException('SUPPLIER_ITEM_PAIR_CONFLICT')` (dùng cho Task 4 gọi qua).

- [ ] **Step 1: Sửa test — thay `findSupplierItemByItemId` bằng 2 method mới**

Trong `apps/wms/src/supplier/supplier.repository.spec.ts`, thay khối `describe('findSupplierItemByItemId', ...)`:

```ts
  describe('findSupplierItemByItemId', () => {
    it('gọi findOne với itemId ObjectId', async () => {
      supplierItemModel.exec.mockResolvedValue(null);
      await repo.findSupplierItemByItemId(itemId);
      expect(supplierItemModel.findOne).toHaveBeenCalledWith({
        itemId: expect.any(Types.ObjectId),
      });
    });
  });
```

bằng:

```ts
  describe('findSupplierItemsByItemId', () => {
    it('gọi find với itemId ObjectId, trả về mảng mọi NCC báo giá SKU đó', async () => {
      const fakeDocs = [{ itemId }, { itemId }];
      supplierItemModel.exec.mockResolvedValue(fakeDocs);
      const result = await repo.findSupplierItemsByItemId(itemId);
      expect(supplierItemModel.find).toHaveBeenCalledWith({
        itemId: expect.any(Types.ObjectId),
      });
      expect(result).toEqual(fakeDocs);
    });
  });

  describe('findSupplierItemByItemAndSupplier', () => {
    it('gọi findOne với đúng cặp itemId + supplierId ObjectId', async () => {
      supplierItemModel.exec.mockResolvedValue(null);
      await repo.findSupplierItemByItemAndSupplier(itemId, supplierId);
      expect(supplierItemModel.findOne).toHaveBeenCalledWith({
        itemId: expect.any(Types.ObjectId),
        supplierId: expect.any(Types.ObjectId),
      });
    });

    it('trả về document khi tìm thấy', async () => {
      const fakeDoc = { itemId, supplierId };
      supplierItemModel.exec.mockResolvedValue(fakeDoc);
      const result = await repo.findSupplierItemByItemAndSupplier(
        itemId,
        supplierId,
      );
      expect(result).toEqual(fakeDoc);
    });
  });
```

Sửa `makeModel` (đầu file) — thêm `find` đã có sẵn (`find: jest.fn().mockReturnThis()`), không cần đổi gì thêm ở đó.

- [ ] **Step 2: Chạy test để xác nhận fail**

Run: `NODE_OPTIONS=--experimental-vm-modules npx jest apps/wms/src/supplier/supplier.repository.spec.ts -v`
Expected: FAIL — `repo.findSupplierItemsByItemId is not a function`, `repo.findSupplierItemByItemAndSupplier is not a function`.

- [ ] **Step 3: Sửa repository**

Trong `apps/wms/src/supplier/supplier.repository.ts`, thay:

```ts
  async findSupplierItemByItemId(
    itemId: string,
  ): Promise<SupplierItemDocument | null> {
    return this.supplierItemModel
      .findOne({ itemId: new Types.ObjectId(itemId) })
      .exec();
  }
```

bằng:

```ts
  /** Mọi báo giá (mọi NCC) đã đăng ký cho 1 SKU — dùng để so sánh giá trước khi đặt PO. */
  async findSupplierItemsByItemId(
    itemId: string,
  ): Promise<SupplierItemDocument[]> {
    return this.supplierItemModel
      .find({ itemId: new Types.ObjectId(itemId) })
      .exec();
  }

  /** Tra đúng 1 báo giá theo cặp (SKU, NCC) — dùng khi upsert và khi PO auto-fill giá. */
  async findSupplierItemByItemAndSupplier(
    itemId: string,
    supplierId: string,
  ): Promise<SupplierItemDocument | null> {
    return this.supplierItemModel
      .findOne({
        itemId: new Types.ObjectId(itemId),
        supplierId: new Types.ObjectId(supplierId),
      })
      .exec();
  }
```

Sửa `updateSupplierItem` để bắt lỗi trùng khóa Mongo (11000) khi đổi `supplierId` sang cặp đã tồn tại:

```ts
  async updateSupplierItem(
    id: string,
    dto: UpdateSupplierItemDto,
  ): Promise<SupplierItemDocument | null> {
    // Convert supplierId string thành ObjectId nếu có trong dto
    const update: Record<string, unknown> = { ...dto };
    if (dto.supplierId)
      update['supplierId'] = new Types.ObjectId(dto.supplierId);
    try {
      return await this.supplierItemModel
        .findOneAndUpdate({ _id: id }, update, { new: true })
        .exec();
    } catch (err) {
      // Đổi supplierId trùng cặp (itemId, supplierId) đã có báo giá khác → 11000
      if ((err as { code?: number }).code === 11000) {
        throw new AppException('SUPPLIER_ITEM_PAIR_CONFLICT');
      }
      throw err;
    }
  }
```

Thêm import `AppException` ở đầu file (`apps/wms/src/supplier/supplier.repository.ts`):

```ts
import { AppException } from '@app/common';
```

- [ ] **Step 4: Chạy test để xác nhận pass**

Run: `NODE_OPTIONS=--experimental-vm-modules npx jest apps/wms/src/supplier/supplier.repository.spec.ts -v`
Expected: PASS — mọi test trong file, bao gồm 3 test mới.

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/supplier/supplier.repository.ts apps/wms/src/supplier/supplier.repository.spec.ts
git commit -m "$(cat <<'EOF'
feat(supplier): repository hỗ trợ nhiều báo giá NCC/SKU

findSupplierItemByItemId (1 bản ghi) → findSupplierItemsByItemId (mảng,
mọi NCC của 1 SKU) + findSupplierItemByItemAndSupplier (đúng 1 cặp).
updateSupplierItem dịch lỗi trùng khóa Mongo sang SUPPLIER_ITEM_PAIR_CONFLICT.
EOF
)"
```

---

### Task 4: Service — `upsertSupplierItem` theo cặp, `listSupplierItemsByItemId`, `getSupplierItemByItemAndSupplier`

**Files:**
- Modify: `apps/wms/src/supplier/supplier.service.ts`
- Modify: `apps/wms/src/supplier/supplier.service.spec.ts`

**Interfaces:**
- Consumes: `SupplierRepository.findSupplierItemsByItemId`, `SupplierRepository.findSupplierItemByItemAndSupplier`, `SupplierRepository.createSupplierItem`, `SupplierRepository.updateSupplierItem`, `SupplierRepository.findSupplierItemById` (từ Task 3).
- Produces:
  - `upsertSupplierItem(dto: CreateSupplierItemDto): Promise<SupplierItemDocument>` — tìm theo cặp `(dto.itemId, dto.supplierId)` thay vì chỉ `dto.itemId`.
  - `listSupplierItemsByItemId(itemId: string): Promise<SupplierItemDocument[]>` — thay cho `getSupplierItemByItemId` (đã xóa), **không throw** khi rỗng.
  - `getSupplierItemByItemAndSupplier(itemId: string, supplierId: string): Promise<SupplierItemDocument>` — mới, throw `SUPPLIER_ITEM_NOT_FOUND` khi rỗng (dùng bởi `PurchaseOrderService`, Task 6).

- [ ] **Step 1: Sửa test**

Trong `apps/wms/src/supplier/supplier.service.spec.ts`, sửa `makeRepo`:

```ts
const makeRepo = () => ({
  createSupplier: jest.fn(),
  findSupplierById: jest.fn(),
  findSupplierByCode: jest.fn(),
  findSuppliers: jest.fn(),
  updateSupplier: jest.fn(),
  changeSupplierStatus: jest.fn(),
  softDeleteSupplier: jest.fn(),
  createSupplierItem: jest.fn(),
  findSupplierItemById: jest.fn(),
  findSupplierItemsByItemId: jest.fn(),
  findSupplierItemByItemAndSupplier: jest.fn(),
  findSupplierItemsBySupplierId: jest.fn(),
  updateSupplierItem: jest.fn(),
});
```

Thay khối `describe('upsertSupplierItem', ...)`:

```ts
  describe('upsertSupplierItem', () => {
    const dto = {
      itemId,
      supplierId,
      purchasePrice: 10000,
    };

    it('tạo mới khi cặp (itemId, supplierId) chưa có báo giá', async () => {
      repo.findSupplierItemByItemAndSupplier.mockResolvedValue(null);
      repo.createSupplierItem.mockResolvedValue({ itemId, supplierId });
      await svc.upsertSupplierItem(dto);
      expect(repo.findSupplierItemByItemAndSupplier).toHaveBeenCalledWith(
        itemId,
        supplierId,
      );
      expect(repo.createSupplierItem).toHaveBeenCalledWith(dto);
    });

    it('update khi cặp (itemId, supplierId) đã có báo giá (không truyền itemId vào update)', async () => {
      const existing = { _id: { toString: () => 'existingId' }, itemId, supplierId };
      repo.findSupplierItemByItemAndSupplier.mockResolvedValue(existing);
      repo.updateSupplierItem.mockResolvedValue({ itemId, supplierId });
      await svc.upsertSupplierItem(dto);
      // itemId bị loại khỏi payload update — field bất biến sau khi tạo
      const { supplierId: s, purchasePrice: p } = dto;
      expect(repo.updateSupplierItem).toHaveBeenCalledWith('existingId', {
        supplierId: s,
        purchasePrice: p,
      });
    });

    it('cùng itemId nhưng khác supplierId → tạo báo giá mới, không ghi đè báo giá NCC khác', async () => {
      repo.findSupplierItemByItemAndSupplier.mockResolvedValue(null);
      repo.createSupplierItem.mockResolvedValue({ itemId, supplierId: 'sup999' });
      const dtoOtherSupplier = { ...dto, supplierId: 'sup999' };
      await svc.upsertSupplierItem(dtoOtherSupplier);
      expect(repo.findSupplierItemByItemAndSupplier).toHaveBeenCalledWith(
        itemId,
        'sup999',
      );
      expect(repo.createSupplierItem).toHaveBeenCalledWith(dtoOtherSupplier);
    });
  });

  describe('listSupplierItemsByItemId', () => {
    it('trả về mảng rỗng khi SKU chưa có báo giá nào (không throw)', async () => {
      repo.findSupplierItemsByItemId.mockResolvedValue([]);
      await expect(svc.listSupplierItemsByItemId(itemId)).resolves.toEqual([]);
    });

    it('trả về mọi báo giá của SKU', async () => {
      const docs = [{ itemId, supplierId: 'sup1' }, { itemId, supplierId: 'sup2' }];
      repo.findSupplierItemsByItemId.mockResolvedValue(docs);
      await expect(svc.listSupplierItemsByItemId(itemId)).resolves.toEqual(docs);
    });
  });

  describe('getSupplierItemByItemAndSupplier', () => {
    it('throw SUPPLIER_ITEM_NOT_FOUND khi không có báo giá cho cặp này', async () => {
      repo.findSupplierItemByItemAndSupplier.mockResolvedValue(null);
      await expect(
        svc.getSupplierItemByItemAndSupplier(itemId, supplierId),
      ).rejects.toMatchObject({ code: 'SUPPLIER_ITEM_NOT_FOUND' });
    });

    it('trả về báo giá khi tìm thấy', async () => {
      const doc = { itemId, supplierId, purchasePrice: 5000 };
      repo.findSupplierItemByItemAndSupplier.mockResolvedValue(doc);
      await expect(
        svc.getSupplierItemByItemAndSupplier(itemId, supplierId),
      ).resolves.toEqual(doc);
    });
  });
```

- [ ] **Step 2: Chạy test để xác nhận fail**

Run: `NODE_OPTIONS=--experimental-vm-modules npx jest apps/wms/src/supplier/supplier.service.spec.ts -v`
Expected: FAIL — `svc.listSupplierItemsByItemId is not a function`, `svc.getSupplierItemByItemAndSupplier is not a function`, và test upsert cũ fail vì gọi `findSupplierItemByItemId` không còn tồn tại trên mock.

- [ ] **Step 3: Sửa service**

Trong `apps/wms/src/supplier/supplier.service.ts`, thay khối `// ─── SupplierItem ───` hoàn toàn:

```ts
  // ─── SupplierItem ─────────────────────────────────────────────────────────

  /**
   * Tạo báo giá mới nếu cặp (SKU, NCC) chưa có, cập nhật nếu đã có.
   * Ràng buộc: 1 cặp (itemId, supplierId) ↔ 1 dòng SupplierItem (compound unique).
   * Nhiều NCC khác nhau báo giá cùng 1 SKU → mỗi NCC là 1 bản ghi riêng.
   */
  async upsertSupplierItem(
    dto: CreateSupplierItemDto,
  ): Promise<SupplierItemDocument> {
    const existing = await this.repo.findSupplierItemByItemAndSupplier(
      dto.itemId,
      dto.supplierId,
    );
    if (!existing) {
      return this.repo.createSupplierItem(dto);
    }
    // Không truyền itemId vào update — field này bất biến sau khi tạo
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    const { itemId: _itemId, ...updateFields } = dto;
    const updated = await this.repo.updateSupplierItem(
      existing._id.toString(),
      updateFields,
    );
    if (!updated) throw new AppException('SUPPLIER_ITEM_NOT_FOUND');
    return updated;
  }

  async getSupplierItem(id: string): Promise<SupplierItemDocument> {
    const doc = await this.repo.findSupplierItemById(id);
    if (!doc) throw new AppException('SUPPLIER_ITEM_NOT_FOUND');
    return doc;
  }

  async listSupplierItemsBySupplierId(
    supplierId: string,
  ): Promise<SupplierItemDocument[]> {
    return this.repo.findSupplierItemsBySupplierId(supplierId);
  }

  /** Mọi báo giá (mọi NCC) của 1 SKU — mảng rỗng nếu chưa ai báo giá (trạng thái hợp lệ). */
  async listSupplierItemsByItemId(
    itemId: string,
  ): Promise<SupplierItemDocument[]> {
    return this.repo.findSupplierItemsByItemId(itemId);
  }

  /** Tra đúng báo giá theo cặp (SKU, NCC) — dùng bởi PurchaseOrderService khi auto-fill giá. */
  async getSupplierItemByItemAndSupplier(
    itemId: string,
    supplierId: string,
  ): Promise<SupplierItemDocument> {
    const doc = await this.repo.findSupplierItemByItemAndSupplier(
      itemId,
      supplierId,
    );
    if (!doc) throw new AppException('SUPPLIER_ITEM_NOT_FOUND');
    return doc;
  }

  async updateSupplierItem(
    id: string,
    dto: UpdateSupplierItemDto,
  ): Promise<SupplierItemDocument> {
    const doc = await this.repo.updateSupplierItem(id, dto);
    if (!doc) throw new AppException('SUPPLIER_ITEM_NOT_FOUND');
    return doc;
  }
```

- [ ] **Step 4: Chạy test để xác nhận pass**

Run: `NODE_OPTIONS=--experimental-vm-modules npx jest apps/wms/src/supplier/supplier.service.spec.ts -v`
Expected: PASS — mọi test trong file.

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/supplier/supplier.service.ts apps/wms/src/supplier/supplier.service.spec.ts
git commit -m "$(cat <<'EOF'
feat(supplier): service hỗ trợ nhiều báo giá NCC/SKU

upsertSupplierItem tìm/ghi theo cặp (itemId, supplierId) thay vì chỉ
itemId — báo giá NCC khác không còn bị ghi đè. Thêm
listSupplierItemsByItemId (mảng, không throw khi rỗng) và
getSupplierItemByItemAndSupplier (dùng bởi PO, throw khi thiếu).
EOF
)"
```

---

### Task 5: Controller — `GET /supplier/items/by-item/:itemId` trả về mảng

**Files:**
- Modify: `apps/wms/src/supplier/supplier.controller.ts`

**Interfaces:**
- Consumes: `SupplierService.listSupplierItemsByItemId` (Task 4).
- Produces: `GET supplier/items/by-item/:itemId` trả `SupplierItemResponseDto[]` thay vì 1 object.

- [ ] **Step 1: Sửa controller**

Trong `apps/wms/src/supplier/supplier.controller.ts`, thay:

```ts
  @Get('items/by-item/:itemId')
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({ summary: 'Tra giá NCC theo itemId (SKU) — [MANAGER, ADMIN]' })
  @ApiOkResponse({ type: SupplierItemResponseDto })
  async getSupplierItemByItemId(
    @Param('itemId') itemId: string,
  ): Promise<SupplierItemResponseDto> {
    const doc = await this.svc.getSupplierItemByItemId(itemId);
    return plainToInstance(SupplierItemResponseDto, doc.toObject(), TO_OPTS);
  }
```

bằng:

```ts
  @Get('items/by-item/:itemId')
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({
    summary:
      'Danh sách báo giá của mọi NCC cho 1 SKU — so sánh giá trước khi đặt PO — [MANAGER, ADMIN]',
  })
  @ApiOkResponse({ type: [SupplierItemResponseDto] })
  async listSupplierItemsByItemId(
    @Param('itemId') itemId: string,
  ): Promise<SupplierItemResponseDto[]> {
    const docs = await this.svc.listSupplierItemsByItemId(itemId);
    return plainToInstance(
      SupplierItemResponseDto,
      docs.map((d) => d.toObject()),
      TO_OPTS,
    );
  }
```

- [ ] **Step 2: Build để xác nhận không lỗi type**

Run: `npx tsc --noEmit -p tsconfig.json 2>&1 | grep -i "supplier.controller"`
Expected: không có output.

- [ ] **Step 3: Lint**

Run: `npx eslint apps/wms/src/supplier/supplier.controller.ts`
Expected: `ESLint: No issues found` (hoặc tự `--fix` nếu chỉ là prettier).

- [ ] **Step 4: Commit**

```bash
git add apps/wms/src/supplier/supplier.controller.ts
git commit -m "$(cat <<'EOF'
feat(supplier): GET items/by-item/:itemId trả về mảng báo giá

Đổi từ 1 SupplierItemResponseDto sang mảng — mỗi SKU giờ có thể có
nhiều báo giá NCC song song (issue #30), cần trả đủ để UI so sánh giá.
EOF
)"
```

---

### Task 6: Purchase Order — dùng `getSupplierItemByItemAndSupplier`, gỡ patch tạm của issue #29

**Files:**
- Modify: `apps/wms/src/purchase-order/purchase-order.service.ts`
- Modify: `apps/wms/src/purchase-order/purchase-order.service.spec.ts`

**Interfaces:**
- Consumes: `SupplierService.getSupplierItemByItemAndSupplier(itemId: string, supplierId: string): Promise<SupplierItemDocument>` (Task 4).

- [ ] **Step 1: Sửa test**

Trong `apps/wms/src/purchase-order/purchase-order.service.spec.ts`, sửa `makeSupplierService`:

```ts
const makeSupplierService = () => ({
  assertSupplierActive: jest.fn(),
  getSupplierItemByItemAndSupplier: jest.fn(),
});
```

Sửa test `'tự điền unitPrice từ SupplierItem khi item để trống giá và supplierId khớp'`:

```ts
    it('tự điền unitPrice từ SupplierItem đúng cặp (itemId, supplierId)', async () => {
      supplierSvc.getSupplierItemByItemAndSupplier.mockResolvedValue({
        purchasePrice: 7000,
        isActive: true,
      });
      repo.createPurchaseOrder.mockResolvedValue({ poNumber: 'PO-X' });
      await svc.createPurchaseOrder(baseDto, actorId);
      expect(supplierSvc.getSupplierItemByItemAndSupplier).toHaveBeenCalledWith(
        itemId,
        supplierId,
      );
      expect(repo.createPurchaseOrder).toHaveBeenCalledWith(
        baseDto,
        expect.any(String),
        [
          {
            itemId,
            sku: 'SKU-1',
            expectedQty: 10,
            unit: 'cái',
            unitPrice: 7000,
          },
        ],
        actorId,
      );
    });
```

**Xóa** hoàn toàn test `'throw PO_PRICE_MISSING khi SupplierItem tìm được thuộc NCC KHÁC với dto.supplierId (issue #29)'` — kịch bản này không còn khả thi: `getSupplierItemByItemAndSupplier` tra đúng theo cặp, không thể trả về báo giá của NCC khác nữa (nếu khác NCC thì kết quả luôn là "không tìm thấy", đã phủ bởi test `SUPPLIER_ITEM_NOT_FOUND` có sẵn).

Sửa mọi chỗ khác gọi `supplierSvc.getSupplierItemByItemId` trong file thành `supplierSvc.getSupplierItemByItemAndSupplier` (3 chỗ còn lại: test `'throw PO_PRICE_MISSING khi thiếu giá...'`, `'không đổi mã lỗi khi...'`, `'throw PO_PRICE_MISSING khi SupplierItem tìm được nhưng isActive=false'`, và test `'sinh poNumber theo format...'`). Ví dụ:

```ts
    it('throw PO_PRICE_MISSING khi thiếu giá và SKU chưa có SupplierItem', async () => {
      supplierSvc.getSupplierItemByItemAndSupplier.mockRejectedValue({
        code: 'SUPPLIER_ITEM_NOT_FOUND',
      });
      await expect(
        svc.createPurchaseOrder(baseDto as never, actorId),
      ).rejects.toMatchObject({
        code: 'PO_PRICE_MISSING',
      });
    });

    it('không đổi mã lỗi khi getSupplierItemByItemAndSupplier throw lỗi khác SUPPLIER_ITEM_NOT_FOUND', async () => {
      supplierSvc.getSupplierItemByItemAndSupplier.mockRejectedValue({
        code: 'INTERNAL',
      });
      await expect(
        svc.createPurchaseOrder(baseDto as never, actorId),
      ).rejects.toMatchObject({
        code: 'INTERNAL',
      });
    });

    it('throw PO_PRICE_MISSING khi SupplierItem tìm được nhưng isActive=false', async () => {
      supplierSvc.getSupplierItemByItemAndSupplier.mockResolvedValue({
        purchasePrice: 7000,
        isActive: false,
      });
      await expect(
        svc.createPurchaseOrder(baseDto as never, actorId),
      ).rejects.toMatchObject({
        code: 'PO_PRICE_MISSING',
      });
      expect(repo.createPurchaseOrder).not.toHaveBeenCalled();
    });

    it('sinh poNumber theo format PO-YYYYMMDD-xxxx', async () => {
      repo.countByPoNumberPrefix.mockResolvedValue(4);
      supplierSvc.getSupplierItemByItemAndSupplier.mockResolvedValue({
        purchasePrice: 1000,
        isActive: true,
      });
      repo.createPurchaseOrder.mockResolvedValue({ poNumber: 'PO-X' });
      await svc.createPurchaseOrder(baseDto, actorId);
      const poNumberArg = repo.createPurchaseOrder.mock.calls[0][1] as string;
      expect(poNumberArg).toMatch(/^PO-\d{8}-0005$/);
    });
```

Sửa test `'giữ nguyên unitPrice nếu user đã nhập tay'` — đổi assertion `expect(supplierSvc.getSupplierItemByItemId).not.toHaveBeenCalled();` thành `expect(supplierSvc.getSupplierItemByItemAndSupplier).not.toHaveBeenCalled();`.

- [ ] **Step 2: Chạy test để xác nhận fail**

Run: `NODE_OPTIONS=--experimental-vm-modules npx jest apps/wms/src/purchase-order/purchase-order.service.spec.ts -v`
Expected: FAIL — service thật vẫn gọi `getSupplierItemByItemId` (chưa đổi), mock mới không được set up đúng tên method service thật sự gọi.

- [ ] **Step 3: Sửa `purchase-order.service.ts`**

Thay khối xử lý giá trong `createPurchaseOrder` (`apps/wms/src/purchase-order/purchase-order.service.ts`):

```ts
      let unitPrice = item.unitPrice;
      if (unitPrice === undefined) {
        // Giá để trống → tra bảng giá NCC; SKU chưa từng khai giá thì từ chối luôn PO
        let supplierItem: { purchasePrice: number; isActive: boolean };
        try {
          supplierItem =
            await this.supplierService.getSupplierItemByItemAndSupplier(
              item.itemId,
              dto.supplierId,
            );
        } catch (err) {
          // Chỉ dịch lỗi "chưa có báo giá" sang PO_PRICE_MISSING; lỗi khác (vd hạ tầng) giữ nguyên
          if ((err as { code?: string })?.code === 'SUPPLIER_ITEM_NOT_FOUND') {
            throw new AppException('PO_PRICE_MISSING');
          }
          throw err;
        }
        // Báo giá hết hiệu lực (isActive=false) → coi như chưa có giá, không tự điền
        if (!supplierItem.isActive) {
          throw new AppException('PO_PRICE_MISSING');
        }
        unitPrice = supplierItem.purchasePrice;
      }
```

Lưu ý: đoạn so `supplierItem.supplierId.toString() !== dto.supplierId` (thêm ở fix issue #29, commit `63fe496`) bị **xóa hoàn toàn** — không còn cần thiết vì `getSupplierItemByItemAndSupplier` đã tra đúng cặp ngay từ đầu, không thể trả về báo giá NCC khác.

Sửa import ở đầu file — bỏ `Types` khỏi import `mongoose` nếu không còn dùng ở đâu khác trong file (kiểm tra bằng grep trước khi xóa):

Run: `grep -n "Types\." apps/wms/src/purchase-order/purchase-order.service.ts`

Nếu không còn dòng nào dùng `Types.` (ngoài dòng import), sửa:

```ts
import type { ClientSession } from 'mongoose';
```

(bỏ `, Types` khỏi import — file gốc trước fix #29 vốn chỉ import `ClientSession`).

- [ ] **Step 4: Chạy test để xác nhận pass**

Run: `NODE_OPTIONS=--experimental-vm-modules npx jest apps/wms/src/purchase-order/purchase-order.service.spec.ts -v`
Expected: PASS — mọi test trong file (16 test, sau khi xóa 1 test case của issue #29 khỏi tổng 17 trước đó).

- [ ] **Step 5: Build + lint toàn phần liên quan**

Run: `npx tsc --noEmit -p tsconfig.json 2>&1 | grep -i "purchase-order\|supplier"`
Expected: không có output mới so với baseline (baseline có sẵn lỗi preexisting ở `purchase-order.repository.spec.ts` không liên quan — xác nhận bằng cách so khớp dòng lỗi với baseline trước khi bắt đầu Task 1, nếu cần chạy `git stash && npx tsc --noEmit -p tsconfig.json 2>&1 | grep -i "purchase-order\|supplier" && git stash pop` để so sánh).

Run: `npx eslint apps/wms/src/purchase-order/purchase-order.service.ts apps/wms/src/purchase-order/purchase-order.service.spec.ts`
Expected: `ESLint: No issues found`.

Run: `npx nest build wms`
Expected: `webpack ... compiled successfully`.

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/purchase-order/purchase-order.service.ts apps/wms/src/purchase-order/purchase-order.service.spec.ts
git commit -m "$(cat <<'EOF'
feat(purchase-order): auto-fill giá theo đúng cặp (SKU, NCC) qua SupplierItem

Đổi từ getSupplierItemByItemId sang getSupplierItemByItemAndSupplier —
tra đúng báo giá của NCC đang chọn trên PO ngay từ query, không cần so
khớp supplierId thủ công sau đó nữa. Gỡ bỏ patch tạm thêm ở fix #29
(commit 63fe496), nay dư thừa vì query đã đảm bảo đúng cặp.

Refs #30
EOF
)"
```

---

### Task 7: Verify toàn bộ + chạy full test suite domain supplier/purchase-order

**Files:** không tạo/sửa file — chỉ verify.

- [ ] **Step 1: Chạy toàn bộ test liên quan**

Run: `NODE_OPTIONS=--experimental-vm-modules npx jest apps/wms/src/supplier apps/wms/src/purchase-order -v`
Expected: mọi test suite PASS, không có suite nào fail.

- [ ] **Step 2: Type-check toàn repo, so sánh với baseline**

Run: `npx tsc --noEmit -p tsconfig.json 2>&1 | tail -5`
Expected: tổng số lỗi bằng đúng baseline trước khi bắt đầu (baseline đo tại Task 6 Step 5) — không phát sinh lỗi mới từ các thay đổi trong plan này.

- [ ] **Step 3: Lint toàn bộ file đã sửa trong plan**

Run:
```bash
npx eslint \
  apps/wms/src/supplier/schemas/supplier-item.schema.ts \
  apps/wms/src/supplier/schemas/supplier-item.schema.spec.ts \
  apps/wms/src/supplier/supplier.repository.ts \
  apps/wms/src/supplier/supplier.repository.spec.ts \
  apps/wms/src/supplier/supplier.service.ts \
  apps/wms/src/supplier/supplier.service.spec.ts \
  apps/wms/src/supplier/supplier.controller.ts \
  apps/wms/src/purchase-order/purchase-order.service.ts \
  apps/wms/src/purchase-order/purchase-order.service.spec.ts \
  libs/common/src/errors/error-codes.ts
```
Expected: `ESLint: No issues found` (dùng `--fix` nếu chỉ là lỗi prettier, rồi commit riêng `chore: lint fix` nếu có thay đổi).

- [ ] **Step 4: Build toàn app wms**

Run: `npx nest build wms`
Expected: `webpack ... compiled successfully`.

- [ ] **Step 5: Không cần commit — task này chỉ verify**

Nếu Step 3 tạo ra thay đổi từ `--fix`, commit riêng:

```bash
git add -A
git commit -m "chore(supplier,purchase-order): lint fix"
```
