# Sync SKU/attributes lúc tạo mới (WMS → Ecom) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Khi WMS tạo `WarehouseItem` mới, tự động bắn event `item.created` để Ecommerce tạo (hoặc cập nhật) `ProductVariant` tương ứng với đúng `sku`/`attributes`, loại bỏ việc admin Ecom phải tự gõ tay lại.

**Architecture:** Event mới `item.created` trên `QUEUES.STOCK` (đã có sẵn wiring cả 2 phía). Producer: `StockService.createWarehouseItem` emit sau khi transaction Mongo commit. Consumer: thêm case trong `StockConsumer` hiện có, dùng `findOneAndUpdate(..., { upsert: true })` theo `sku` để vừa tạo mới (nếu chưa có, `productId: null`, `isActive: false`) vừa cập nhật `attributes` (ghi đè, nếu variant đã tồn tại) — idempotent tự nhiên với BullMQ retry.

**Tech Stack:** NestJS, Mongoose (`@nestjs/mongoose`), BullMQ (`@nestjs/bullmq`), Jest.

## Global Constraints

- Payload tối thiểu: chỉ `sku`, `name`, `attributes: {key, value}[]` — không mang `optionId`/`code`/barcode/kích thước (theo `libs/events` nguyên tắc "payload tối thiểu").
- Không transaction xuyên DB, không đọc chéo `wms_db`/`ecom_db` — mọi liên kết qua event + `sku`.
- Cấm `any` — dùng type rõ ràng ở mọi nơi (theo `.claude/rules/dto-conventions.md`).
- Service không throw NestJS exception thô — dùng `AppException` nếu cần throw trong service (theo `.claude/rules/error-handling.md`). Trong scope plan này không có nhánh lỗi mới cần throw ở service, nhưng nếu thêm sau, tuân theo rule này.
- Giữ nguyên `ProductVariant.attributes: Record<string,string>` — không đổi sang structured (đã chốt trong spec).
- Phạm vi: **chỉ xử lý lúc tạo mới**, không đụng update `attributes`/`isActive` của `WarehouseItem` (hiện chưa có API cho phép sửa 2 field đó).

---

## File Structure

| File | Thay đổi |
|---|---|
| `libs/events/src/events.ts` | Thêm `EVENTS.ITEM_CREATED`, `ItemCreatedPayload`, đăng ký vào `EventPayloadMap` |
| `apps/wms/src/stock/stock.service.ts` | `createWarehouseItem` emit `EVENTS.ITEM_CREATED` sau khi transaction commit |
| `apps/wms/src/stock/stock.service.spec.ts` | Test emit event đúng payload, không emit khi transaction throw |
| `apps/ecommerce/src/catalog/catalog.repository.ts` | Thêm method `upsertVariantFromItemCreated` |
| `apps/ecommerce/src/catalog/catalog.repository.spec.ts` | **Tạo mới** — test upsert tạo mới / ghi đè attributes giữ nguyên productId-price-isActive |
| `apps/ecommerce/src/catalog/stock.consumer.ts` | Thêm case `ITEM_CREATED` gọi repo method trên |
| `apps/ecommerce/src/catalog/stock.consumer.spec.ts` | **Tạo mới** — test case `ITEM_CREATED` gọi đúng repo method với đúng tham số |
| `apps/ecommerce/src/catalog/schemas/product-variant.schema.ts` | `productId` đổi sang optional |
| `apps/ecommerce/src/catalog/dto/product.dto.ts` | `ProductVariantResponseDto.productId` giữ nguyên (đã optional-safe qua `@Transform`); thêm `AssignVariantProductDto` |
| `apps/ecommerce/src/catalog/catalog.service.ts` | Thêm `assignVariantProduct` (gán `productId` cho variant đang chờ) |
| `apps/ecommerce/src/catalog/catalog.controller.ts` | Thêm endpoint `PATCH admin/catalog/variants/:id/assign-product`, thêm query `unassigned` cho listing |
| `apps/ecommerce/src/catalog/catalog.service.spec.ts` | Test `assignVariantProduct` |

---

### Task 1: Khai báo event `item.created` trong `libs/events`

**Files:**
- Modify: `libs/events/src/events.ts`

**Interfaces:**
- Produces: `EVENTS.ITEM_CREATED = 'item.created'`, `interface ItemCreatedPayload { sku: string; name: string; attributes: { key: string; value: string }[] }`, `EventPayloadMap[EVENTS.ITEM_CREATED]`

Không có test riêng cho file khai báo hằng số/type — đây là constants module, được test gián tiếp qua Task 2 và Task 4 (producer/consumer dùng đúng type sẽ fail biên dịch nếu sai).

- [ ] **Step 1: Thêm `ITEM_CREATED` vào `EVENTS`**

Trong `libs/events/src/events.ts`, sửa comment nhóm và thêm dòng mới ngay dưới `STOCK_EXPIRED`:

```ts
export const EVENTS = {
  // ----- Tồn kho (WMS → Ecommerce) -----
  STOCK_CHANGED: 'stock.changed',
  STOCK_EXPIRED: 'stock.expired',
  // ----- Master data mặt hàng (WMS → Ecommerce) -----
  ITEM_CREATED: 'item.created', // WMS tạo SKU mới → Ecom tạo/cập nhật ProductVariant
  // ----- Reserve theo saga (Ecommerce → WMS → Ecommerce) -----
  ...
```

- [ ] **Step 2: Thêm `ItemCreatedPayload` interface**

Ngay dưới `StockExpiredPayload`:

```ts
/** Payload tối thiểu — không mang optionId/code/barcode vì Ecom không dùng. */
export interface ItemCreatedPayload {
  sku: string;
  name: string;
  attributes: { key: string; value: string }[];
}
```

- [ ] **Step 3: Đăng ký vào `EventPayloadMap`**

Trong `EventPayloadMap`, thêm dòng ngay dưới `[EVENTS.STOCK_EXPIRED]`:

```ts
  [EVENTS.ITEM_CREATED]: ItemCreatedPayload;
```

- [ ] **Step 4: Build để xác nhận không lỗi biên dịch**

Run: `pnpm build` (hoặc `npx tsc --noEmit -p libs/events/tsconfig.lib.json` nếu có tsconfig riêng — kiểm tra bằng `ls libs/events/*.json` trước khi chạy)

Expected: build thành công, không lỗi TypeScript.

- [ ] **Step 5: Commit**

```bash
git add libs/events/src/events.ts
git commit -m "feat(events): thêm event item.created (WMS→Ecom sync SKU/attributes)"
```

---

### Task 2: Producer — `StockService.createWarehouseItem` emit `item.created`

**Files:**
- Modify: `apps/wms/src/stock/stock.service.ts`
- Test: `apps/wms/src/stock/stock.service.spec.ts`

**Interfaces:**
- Consumes: `EVENTS.ITEM_CREATED`, `ItemCreatedPayload` từ `@app/events` (Task 1)
- Produces: không có API mới — hành vi phụ trợ của `createWarehouseItem` đã có

- [ ] **Step 1: Viết test thất bại — emit đúng payload sau khi transaction thành công**

Thêm vào `describe('createWarehouseItem', ...)` trong `apps/wms/src/stock/stock.service.spec.ts`, sau test "resolve SKU qua SkuTemplateService...":

```ts
    it('bắn event item.created sau khi transaction commit thành công', async () => {
      skuTemplateSvc.resolveAndBuildSku.mockResolvedValue({
        sku: 'MAT-SYR-PEACH-750ML',
        attributeSnapshot: [
          {
            key: 'FLAVOR',
            optionId: 'opt-flavor',
            name: 'Đào',
            value: 'Đào',
            code: 'PEACH',
          },
        ],
      });
      barcodeSvc.generateAndReservePrimaryBarcode.mockResolvedValue(
        '2000000000015',
      );
      const createdDoc = {
        _id: new Types.ObjectId(),
        sku: 'MAT-SYR-PEACH-750ML',
        name: 'Syrup đào',
        attributes: [
          {
            key: 'FLAVOR',
            optionId: 'opt-flavor',
            name: 'Đào',
            value: 'Đào',
            code: 'PEACH',
          },
        ],
      };
      repo.createItem.mockResolvedValue(createdDoc);

      await svc.createWarehouseItem(dto as never, actorId);

      expect(queue.add).toHaveBeenCalledWith(EVENTS.ITEM_CREATED, {
        sku: 'MAT-SYR-PEACH-750ML',
        name: 'Syrup đào',
        attributes: [{ key: 'FLAVOR', value: 'Đào' }],
      });
    });

    it('không bắn event item.created khi transaction throw', async () => {
      skuTemplateSvc.resolveAndBuildSku.mockResolvedValue({
        sku: 'MAT-SYR-PEACH-750ML',
        attributeSnapshot: [],
      });
      barcodeSvc.generateAndReservePrimaryBarcode.mockResolvedValue(
        '2000000000015',
      );
      repo.createItem.mockRejectedValue(new Error('db down'));

      await expect(
        svc.createWarehouseItem(dto as never, actorId),
      ).rejects.toThrow('db down');
      expect(queue.add).not.toHaveBeenCalled();
    });
```

- [ ] **Step 2: Chạy test để xác nhận fail**

Run: `pnpm test -- stock.service.spec.ts -t "item.created"`
Expected: FAIL — `queue.add` không được gọi với `EVENTS.ITEM_CREATED` (vì `ITEM_CREATED` chưa được emit trong code) / có thể fail biên dịch nếu `EVENTS.ITEM_CREATED` chưa import — đảm bảo Task 1 đã hoàn thành trước.

- [ ] **Step 3: Import type + implement emit**

Trong `apps/wms/src/stock/stock.service.ts`, sửa import:

```ts
import {
  EVENTS,
  QUEUES,
  type ItemCreatedPayload,
  type StockChangedPayload,
  type StockLowPayload,
} from '@app/events';
```

Sửa `createWarehouseItem` — bọc kết quả transaction vào biến, emit sau khi `try` thành công (trước `return`), viết lại toàn bộ method:

```ts
  async createWarehouseItem(
    dto: CreateWarehouseItemDto,
    actorId: string,
    imageFiles?: UploadedImageFile[],
  ): Promise<WarehouseItemDocument> {
    if ((dto.type as ItemType) === ItemType.CUP_PRINTED) {
      throw new AppException('STOCK_SKU_TEMPLATE_MISMATCH');
    }

    const { sku, attributeSnapshot } =
      await this.skuTemplateSvc.resolveAndBuildSku(
        dto.templateId,
        dto.type,
        dto.attributeOptionIds,
      );

    const images: string[] = [];
    for (const file of imageFiles ?? []) {
      this.validateImageFile(file);
      const { url } = await this.cloudinary.uploadImage(
        file.buffer,
        'wms/warehouse-item',
      );
      images.push(url);
    }

    let created: WarehouseItemDocument;
    try {
      created = await this.txHelper.withStockTransaction(async (session) => {
        const itemId = new Types.ObjectId();
        const barcode = await this.barcodeSvc.generateAndReservePrimaryBarcode(
          itemId,
          session,
        );

        const data: CreateWarehouseItemData = {
          _id: itemId,
          sku,
          barcode,
          name: dto.name,
          type: dto.type,
          unit: dto.unit,
          altUnits: dto.altUnits,
          attributes: attributeSnapshot,
          isPerishable: dto.isPerishable,
          nearExpiryDays: dto.nearExpiryDays,
          minQuantity: dto.minQuantity,
          depth: dto.depth,
          width: dto.width,
          height: dto.height,
          images,
        };

        return this.stockRepo.createItem(
          data,
          new Types.ObjectId(actorId),
          session,
        );
      });
    } catch (err) {
      if (isMongoDuplicateKeyError(err)) {
        throw new AppException('STOCK_ITEM_SKU_CONFLICT');
      }
      throw err;
    }

    // Emit SAU KHI transaction đã commit — BullMQ không tham gia Mongo
    // transaction, nhất quán với convention của checkAndEmitStockLow.
    const payload: ItemCreatedPayload = {
      sku: created.sku,
      name: created.name,
      attributes: created.attributes.map((a) => ({
        key: a.key,
        value: a.value,
      })),
    };
    await this.stockQueue.add(EVENTS.ITEM_CREATED, payload);
    this.logger.log(`item.created → sku=${created.sku}`);

    return created;
  }
```

- [ ] **Step 4: Chạy lại test để xác nhận pass**

Run: `pnpm test -- stock.service.spec.ts`
Expected: PASS — toàn bộ suite `StockService` (bao gồm 2 test mới + các test cũ không bị vỡ).

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/stock.service.ts apps/wms/src/stock/stock.service.spec.ts
git commit -m "feat(wms): emit item.created sau khi tạo WarehouseItem thành công"
```

---

### Task 3: Ecom schema — `ProductVariant.productId` thành optional

**Files:**
- Modify: `apps/ecommerce/src/catalog/schemas/product-variant.schema.ts`

**Interfaces:**
- Produces: `ProductVariant.productId?: Types.ObjectId` (trước đó là required)

- [ ] **Step 1: Sửa schema**

Trong `apps/ecommerce/src/catalog/schemas/product-variant.schema.ts`, sửa:

```ts
  @Prop({ type: Types.ObjectId, index: true })
  productId?: Types.ObjectId;
```

(bỏ `required: true`, thêm dấu `?` vào type field).

- [ ] **Step 2: Kiểm tra chỗ dùng `.productId.toString()` không optional-chain — sửa nếu cần**

Run: `grep -rn "\.productId\." apps/ecommerce/src/catalog --include=*.ts | grep -v spec.ts`

Xác nhận các dòng sau vẫn an toàn (đã optional-safe hoặc nằm trong nhánh không null):
- `catalog.service.ts:321`: `updated.productId.toString()` trong `updateVariant` — variant vừa update qua `UpdateVariantDto` (không đổi `productId` thành null qua route này), giữ nguyên vì `dto.productId` (nếu có) luôn là string hợp lệ đã validate. Không sửa.
- `catalog.repository.ts:181-184` (`listVariantsByProduct`): filter theo `productId` cụ thể, không bị ảnh hưởng.
- `stock.consumer.ts:48`: `variant.productId.toString()` trong nhánh `if (variant)` của case `STOCK_CHANGED`/`STOCK_EXPIRED` — **cần sửa** vì variant giờ có thể có `productId: null` (variant mới tạo từ `item.created` chưa gán product). Sửa thành optional-safe, bọc trong `if (variant.productId)`:

```ts
            const variant = await this.catalogRepo.findVariantBySku(sku);
            if (variant?.productId) {
              const product = await this.catalogRepo.getProductById(
                variant.productId.toString(),
              );
              if (product) {
                await this.cacheService.del(
                  `ecom:catalog:products:detail:${product.slug}`,
                );
              }
            }
```

- [ ] **Step 3: Build để xác nhận không lỗi kiểu**

Run: `pnpm build`
Expected: build thành công — nếu có lỗi TS ở chỗ khác giả định `productId` non-null, sửa tương tự (optional-chain hoặc guard).

- [ ] **Step 4: Chạy test hiện có của catalog để không vỡ**

Run: `pnpm test -- catalog.service.spec.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ecommerce/src/catalog/schemas/product-variant.schema.ts apps/ecommerce/src/catalog/stock.consumer.ts
git commit -m "refactor(ecom): productId của ProductVariant thành optional (chuẩn bị nhận variant chưa gán product)"
```

---

### Task 4: Consumer — `CatalogRepository.upsertVariantFromItemCreated` + xử lý `item.created`

**Files:**
- Modify: `apps/ecommerce/src/catalog/catalog.repository.ts`
- Modify: `apps/ecommerce/src/catalog/stock.consumer.ts`
- Test: **Tạo mới** `apps/ecommerce/src/catalog/catalog.repository.spec.ts`
- Test: **Tạo mới** `apps/ecommerce/src/catalog/stock.consumer.spec.ts`

**Interfaces:**
- Consumes: `EVENTS.ITEM_CREATED`, `ItemCreatedPayload` từ `@app/events` (Task 1); `ProductVariant.productId?: Types.ObjectId` (Task 3)
- Produces: `CatalogRepository.upsertVariantFromItemCreated(sku: string, name: string, attributes: Record<string, string>): Promise<void>` — dùng bởi `StockConsumer`

- [ ] **Step 1: Viết test thất bại cho `CatalogRepository.upsertVariantFromItemCreated`**

Tạo file `apps/ecommerce/src/catalog/catalog.repository.spec.ts`:

```ts
import { Types } from 'mongoose';
import { CatalogRepository } from './catalog.repository';

const makeVariantModel = () => ({
  findOneAndUpdate: jest.fn(),
});

describe('CatalogRepository.upsertVariantFromItemCreated', () => {
  let repo: CatalogRepository;
  let variantModel: ReturnType<typeof makeVariantModel>;

  beforeEach(() => {
    variantModel = makeVariantModel();
    repo = new CatalogRepository(
      {} as never, // conn — không dùng trong method này
      variantModel as never,
      {} as never, // processedModel
      {} as never, // categoryModel
      {} as never, // productModel
      {} as never, // designModel
    );
  });

  it('upsert theo sku — set attributes, setOnInsert productId/isActive/price mặc định', async () => {
    variantModel.findOneAndUpdate.mockResolvedValue({});

    await repo.upsertVariantFromItemCreated('MAT-SYR-PEACH-750ML', 'Syrup đào', {
      FLAVOR: 'Đào',
    });

    expect(variantModel.findOneAndUpdate).toHaveBeenCalledWith(
      { sku: 'MAT-SYR-PEACH-750ML' },
      {
        $set: { attributes: { FLAVOR: 'Đào' } },
        $setOnInsert: {
          sku: 'MAT-SYR-PEACH-750ML',
          productId: null,
          isActive: false,
          price: 0,
          availableQty: 0,
        },
      },
      { upsert: true },
    );
  });
});
```

- [ ] **Step 2: Chạy test để xác nhận fail**

Run: `pnpm test -- catalog.repository.spec.ts`
Expected: FAIL — `upsertVariantFromItemCreated` chưa tồn tại trên `CatalogRepository`.

- [ ] **Step 3: Implement method trong `CatalogRepository`**

Trong `apps/ecommerce/src/catalog/catalog.repository.ts`, thêm ngay dưới `findVariantBySku` (trong nhóm `// ── PRODUCT VARIANT ──`):

```ts
  /**
   * Upsert theo sku khi WMS bắn item.created. Ghi đè attributes toàn bộ
   * (WMS là source of truth cho attributes vật lý). Nếu variant chưa tồn
   * tại, tạo mới ở trạng thái chờ admin Ecom gán productId/giá/active.
   */
  async upsertVariantFromItemCreated(
    sku: string,
    name: string,
    attributes: Record<string, string>,
  ): Promise<void> {
    await this.variantModel.findOneAndUpdate(
      { sku },
      {
        $set: { attributes },
        $setOnInsert: {
          sku,
          productId: null,
          isActive: false,
          price: 0,
          availableQty: 0,
        },
      },
      { upsert: true },
    );
  }
```

Lưu ý: tham số `name` hiện chưa dùng trong method (schema `ProductVariant` không có field `name` — tên hiển thị là của `Product`, không phải `ProductVariant`). Method vẫn nhận `name` để giữ đúng shape payload gọi từ consumer, nhưng không set field nào từ nó. Nếu ESLint báo `no-unused-vars` cho tham số, đổi tên tham số thành `_name` để tường minh là cố ý bỏ qua — chạy lint ở Step 6 để xác nhận có cần đổi không.

- [ ] **Step 4: Chạy lại test repository để xác nhận pass**

Run: `pnpm test -- catalog.repository.spec.ts`
Expected: PASS.

- [ ] **Step 5: Viết test thất bại cho `StockConsumer` case `ITEM_CREATED`**

Tạo file `apps/ecommerce/src/catalog/stock.consumer.spec.ts`:

```ts
import { EVENTS } from '@app/events';
import { Job } from 'bullmq';
import { StockConsumer } from './stock.consumer';

const makeCatalogRepo = () => ({
  applyStockDeltaOnce: jest.fn(),
  findVariantBySku: jest.fn(),
  getProductById: jest.fn(),
  upsertVariantFromItemCreated: jest.fn(),
});

const makeCacheService = () => ({
  del: jest.fn(),
});

describe('StockConsumer', () => {
  let consumer: StockConsumer;
  let catalogRepo: ReturnType<typeof makeCatalogRepo>;
  let cacheService: ReturnType<typeof makeCacheService>;

  beforeEach(() => {
    catalogRepo = makeCatalogRepo();
    cacheService = makeCacheService();
    consumer = new StockConsumer(catalogRepo as never, cacheService as never);
  });

  describe('item.created', () => {
    it('gọi upsertVariantFromItemCreated với attributes đã flatten thành Record', async () => {
      const job = {
        id: 'job-1',
        name: EVENTS.ITEM_CREATED,
        data: {
          sku: 'MAT-SYR-PEACH-750ML',
          name: 'Syrup đào',
          attributes: [{ key: 'FLAVOR', value: 'Đào' }],
        },
      } as unknown as Job;

      await consumer.process(job);

      expect(catalogRepo.upsertVariantFromItemCreated).toHaveBeenCalledWith(
        'MAT-SYR-PEACH-750ML',
        'Syrup đào',
        { FLAVOR: 'Đào' },
      );
    });
  });
});
```

- [ ] **Step 6: Chạy test để xác nhận fail**

Run: `pnpm test -- stock.consumer.spec.ts`
Expected: FAIL — case `EVENTS.ITEM_CREATED` chưa xử lý trong `StockConsumer.process`, rơi vào `default` (log warn, không gọi `upsertVariantFromItemCreated`).

- [ ] **Step 7: Implement case trong `StockConsumer`**

Trong `apps/ecommerce/src/catalog/stock.consumer.ts`, sửa import:

```ts
import {
  EVENTS,
  QUEUES,
  type ItemCreatedPayload,
  type StockChangedPayload,
  type StockExpiredPayload,
} from '@app/events';
```

Thêm case mới trong `switch (job.name)`, trước `default`:

```ts
      case EVENTS.ITEM_CREATED: {
        const { sku, name, attributes } = job.data as ItemCreatedPayload;
        const attrRecord = Object.fromEntries(
          attributes.map((a) => [a.key, a.value]),
        );
        await this.catalogRepo.upsertVariantFromItemCreated(
          sku,
          name,
          attrRecord,
        );
        this.logger.log(`item.created → variant upserted cho sku=${sku}`);
        break;
      }
```

- [ ] **Step 8: Chạy lại cả 2 test file để xác nhận pass**

Run: `pnpm test -- stock.consumer.spec.ts catalog.repository.spec.ts`
Expected: PASS.

- [ ] **Step 9: Chạy toàn bộ test suite catalog + wms stock để không vỡ hồi quy**

Run: `pnpm test -- apps/ecommerce/src/catalog apps/wms/src/stock`
Expected: PASS toàn bộ.

- [ ] **Step 10: Commit**

```bash
git add apps/ecommerce/src/catalog/catalog.repository.ts apps/ecommerce/src/catalog/catalog.repository.spec.ts apps/ecommerce/src/catalog/stock.consumer.ts apps/ecommerce/src/catalog/stock.consumer.spec.ts
git commit -m "feat(ecom): xử lý item.created — upsert ProductVariant theo sku"
```

---

### Task 5: Admin API — gán `productId` cho variant đang chờ + lọc "chưa gán product"

**Files:**
- Modify: `apps/ecommerce/src/catalog/dto/product.dto.ts`
- Modify: `apps/ecommerce/src/catalog/catalog.repository.ts`
- Modify: `apps/ecommerce/src/catalog/catalog.service.ts`
- Modify: `apps/ecommerce/src/catalog/catalog.controller.ts`
- Test: `apps/ecommerce/src/catalog/catalog.service.spec.ts`

**Interfaces:**
- Consumes: `ProductVariant.productId?: Types.ObjectId` (Task 3)
- Produces: `CatalogService.assignVariantProduct(id: string, productId: string): Promise<ProductVariantDocument>`, `CatalogRepository.listUnassignedVariants(): Promise<ProductVariant[]>`, DTO `AssignVariantProductDto { productId: string }`, endpoint `PATCH admin/catalog/variants/:id/assign-product`, endpoint `GET admin/catalog/variants/unassigned`

- [ ] **Step 1: Thêm `AssignVariantProductDto` trong `product.dto.ts`**

Trong `apps/ecommerce/src/catalog/dto/product.dto.ts`, ngay dưới `UpdateVariantDto`:

```ts
export class AssignVariantProductDto {
  @ApiProperty({ example: '64abc...' })
  @IsString()
  @IsNotEmpty()
  productId: string;
}
```

- [ ] **Step 2: Thêm `listUnassignedVariants` trong `CatalogRepository`**

Ngay dưới `findVariantBySku` trong `catalog.repository.ts`:

```ts
  async listUnassignedVariants() {
    return this.variantModel.find({ productId: null }).lean();
  }
```

- [ ] **Step 3: Viết test thất bại cho `CatalogService.assignVariantProduct`**

Thêm vào `apps/ecommerce/src/catalog/catalog.service.spec.ts` (kiểm tra import/mock pattern hiện có của file trước khi thêm — dùng cùng style `makeRepo`/`makeCacheService` nếu file đã định nghĩa, nếu chưa thì định nghĩa mock tối thiểu inline theo mẫu dưới):

```ts
describe('CatalogService.assignVariantProduct', () => {
  const makeRepo = () => ({
    getProductById: jest.fn(),
    updateVariant: jest.fn(),
  });
  const makeCache = () => ({ del: jest.fn() });

  it('gán productId cho variant đang chờ (productId=null)', async () => {
    const repo = makeRepo();
    const cache = makeCache();
    const svc = new CatalogService(repo as never, cache as never, {} as never);
    const productId = new Types.ObjectId().toString();
    repo.getProductById.mockResolvedValue({
      _id: productId,
      slug: 'ly-nhua',
    });
    repo.updateVariant.mockResolvedValue({
      _id: 'variant-1',
      sku: 'MAT-SYR-PEACH-750ML',
      productId: new Types.ObjectId(productId),
    });

    const result = await svc.assignVariantProduct('variant-1', productId);

    expect(repo.updateVariant).toHaveBeenCalledWith('variant-1', {
      productId: new Types.ObjectId(productId),
    });
    expect(result).toMatchObject({ sku: 'MAT-SYR-PEACH-750ML' });
  });

  it('throw CATALOG_PRODUCT_NOT_FOUND nếu productId không tồn tại', async () => {
    const repo = makeRepo();
    const cache = makeCache();
    const svc = new CatalogService(repo as never, cache as never, {} as never);
    repo.getProductById.mockResolvedValue(null);

    await expect(
      svc.assignVariantProduct('variant-1', new Types.ObjectId().toString()),
    ).rejects.toMatchObject({ code: 'CATALOG_PRODUCT_NOT_FOUND' });
  });
});
```

Kiểm tra trước khi thêm: xem constructor thật của `CatalogService` (dependency thứ 3 trở đi) bằng `grep -n "constructor" apps/ecommerce/src/catalog/catalog.service.ts` — nếu có thêm dependency ngoài `repo`/`cacheService` (vd `CloudinaryService`), truyền `{} as never` cho đủ tham số đúng thứ tự thật, không đoán.

- [ ] **Step 4: Chạy test để xác nhận fail**

Run: `pnpm test -- catalog.service.spec.ts -t "assignVariantProduct"`
Expected: FAIL — `svc.assignVariantProduct` chưa tồn tại.

- [ ] **Step 5: Implement `assignVariantProduct` trong `CatalogService`**

Trong `apps/ecommerce/src/catalog/catalog.service.ts`, thêm ngay dưới `updateVariant`:

```ts
  async assignVariantProduct(id: string, productId: string) {
    if (!Types.ObjectId.isValid(productId)) {
      throw new AppException('VALIDATION_FAILED', 'ID sản phẩm không hợp lệ');
    }
    const product = await this.repo.getProductById(productId);
    if (!product) throw new AppException('CATALOG_PRODUCT_NOT_FOUND');

    const updated = await this.repo.updateVariant(id, {
      productId: new Types.ObjectId(productId),
    });
    if (!updated) throw new AppException('CATALOG_VARIANT_NOT_FOUND');

    await this.cacheService.del(`ecom:catalog:products:detail:${product.slug}`);
    return updated;
  }
```

- [ ] **Step 6: Chạy lại test để xác nhận pass**

Run: `pnpm test -- catalog.service.spec.ts`
Expected: PASS toàn bộ file.

- [ ] **Step 7: Thêm endpoint trong `CatalogAdminController`**

Trong `apps/ecommerce/src/catalog/catalog.controller.ts`, import `AssignVariantProductDto` vào khối import từ `./dto/product.dto`, thêm ngay dưới `updateVariant`:

```ts
  @Get('variants/unassigned')
  @ApiOperation({ summary: '[Admin] Danh sách biến thể chưa gán sản phẩm (từ item.created)' })
  @ApiOkResponse({ type: [ProductVariantResponseDto] })
  async listUnassignedVariants() {
    const variants = await this.svc.listUnassignedVariants();
    return plainToInstance(ProductVariantResponseDto, variants, {
      excludeExtraneousValues: true,
    });
  }

  @Patch('variants/:id/assign-product')
  @ApiOperation({ summary: '[Admin] Gán sản phẩm cho biến thể đang chờ' })
  @ApiParam({ name: 'id', description: 'ID biến thể' })
  @ApiOkResponse({ type: ProductVariantResponseDto })
  async assignVariantProduct(
    @Param('id') id: string,
    @Body() dto: AssignVariantProductDto,
  ) {
    const variant = await this.svc.assignVariantProduct(id, dto.productId);
    return plainToInstance(ProductVariantResponseDto, variant, {
      excludeExtraneousValues: true,
    });
  }
```

Thêm `listUnassignedVariants` pass-through trong `CatalogService` (nếu controller gọi `this.svc.listUnassignedVariants()` trực tiếp, cần method service tương ứng) — thêm vào `catalog.service.ts` ngay dưới `assignVariantProduct`:

```ts
  async listUnassignedVariants() {
    return this.repo.listUnassignedVariants();
  }
```

- [ ] **Step 8: Build toàn bộ để xác nhận không lỗi TypeScript**

Run: `pnpm build`
Expected: build thành công.

- [ ] **Step 9: Chạy toàn bộ test catalog để xác nhận không hồi quy**

Run: `pnpm test -- apps/ecommerce/src/catalog`
Expected: PASS toàn bộ.

- [ ] **Step 10: Commit**

```bash
git add apps/ecommerce/src/catalog/dto/product.dto.ts apps/ecommerce/src/catalog/catalog.repository.ts apps/ecommerce/src/catalog/catalog.service.ts apps/ecommerce/src/catalog/catalog.controller.ts apps/ecommerce/src/catalog/catalog.service.spec.ts
git commit -m "feat(ecom): admin API gán productId cho variant chờ + liệt kê variant chưa gán"
```

---

### Task 6: Cập nhật tài liệu đồng bộ (`docs/overview/data-ownership.md`)

**Files:**
- Modify: `docs/overview/data-ownership.md`

**Interfaces:** Không có — chỉ tài liệu.

- [ ] **Step 1: Thêm dòng event mới vào bảng "Các event đồng bộ giữa WMS và Ecommerce"**

Mở `docs/overview/data-ownership.md`, tìm bảng ở mục `## Các event đồng bộ giữa WMS và Ecommerce` (dòng ~132-137), có 4 cột `| Event | Từ | Đến | Khi nào |`. Thêm dòng mới ngay dưới dòng `stock.changed` (dòng 136):

```markdown
| `item.created` | WMS | Ecommerce | **Tạo `WarehouseItem` mới** → Ecom upsert `ProductVariant` theo `sku` (chưa gán `productId`, `isActive=false`, `price=0` — chờ admin Ecom gán sản phẩm + giá). Chỉ xử lý lúc TẠO MỚI — sửa `attributes`/`isActive` sau khi tạo hiện chưa có API ở WMS nên chưa phát event tương ứng. |
```

- [ ] **Step 2: Commit**

```bash
git add docs/overview/data-ownership.md
git commit -m "docs: ghi nhận event item.created vào bảng đồng bộ WMS-Ecom"
```

---

## Self-Review Notes

- **Spec coverage:** Event contract (Task 1), producer (Task 2), consumer + upsert (Task 4), schema `productId` optional (Task 3), map attributes `ItemAttribute[]→Record` (Task 4 Step 7), xử lý `productId=null` ở admin (Task 5), docs (Task 6) — toàn bộ mục trong spec `2026-07-24-item-created-sync-design.md` đều có task tương ứng. Testing section của spec (unit producer/consumer, upsert tạo mới vs ghi đè) được phủ ở Task 2 và Task 4.
- **Không đụng update attributes/isActive của WarehouseItem** — đúng phạm vi đã chốt, không có task nào mở `UpdateWarehouseItemDto`.
- **Type consistency:** `ItemCreatedPayload` dùng nhất quán `{ sku, name, attributes: {key,value}[] }` xuyên Task 1/2/4. `upsertVariantFromItemCreated(sku, name, attributes: Record<string,string>)` dùng nhất quán ở Task 4 (định nghĩa + gọi từ consumer) và test.
