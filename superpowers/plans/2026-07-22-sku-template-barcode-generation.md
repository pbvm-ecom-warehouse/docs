# SKU Template & EAN-13 Barcode Generation (Issue #25) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace client-supplied `sku`/`barcode` on `WarehouseItem` creation (for `CUP_BLANK`/`MATERIAL`/`PACKAGING`) with BE-generated SKUs built from a fixed template registry and admin-managed attribute options, plus BE-generated unique EAN-13 barcodes tracked in a dedicated registry — closing the "quét mã có thể resolve sai item" risk described in GitHub issue #25.

**Architecture:** A new `attribute-option` sub-module under `apps/wms/src/stock/` provides admin CRUD for `item_attribute_options` (key/code/name, unique per `{key, code}`). A pure-function SKU template registry (11 hardcoded templates, no DB) resolves `itemType (+ category)` → ordered field list, and a builder joins option codes into the final SKU string. A `barcode` sub-module adds `barcode_counters` (atomic per-prefix sequence) and `barcode_registry` (unique code → item, `PRIMARY`/`ALTERNATE`) collections, plus a pure EAN-13 checksum function. `StockService.createWarehouseItem` is rewritten to: reject client `sku`/`barcode` for the 3 public types, reject `CUP_PRINTED` entirely (stays print-job-only), resolve template + options, generate SKU, generate barcode, and persist item + registry entry inside one Mongo transaction (`StockTransactionHelper`, already exists). A one-off backfill script dry-run-reports legacy barcode collisions without auto-resolving them, per the issue's explicit non-goal of auto-picking a winner.

**Tech Stack:** NestJS 10, Mongoose 8 (MongoDB replica set required for transactions — already the case for other stock mutations), Jest (mocked-repository unit tests, no `mongodb-memory-server` in this repo), class-validator/class-transformer DTOs, `@app/common` `AppException`.

## Global Constraints

- DB-per-app rule: everything in this plan lives in `wms_db` only; no cross-DB reads (see `architecture.md`).
- Collections: `item_attribute_options`, `barcode_counters`, `barcode_registry` — snake_case, per `data-and-mongoose.md`.
- Audit convention: `item_attribute_options` is master/config data → `createdBy`/`updatedBy`/`createdAt`/`updatedAt`/`deletedAt` (soft-delete). `barcode_registry` is closer to a ledger (append + occasional link-swap) → `createdAt` only, no soft-delete (entries are removed only via explicit unlink, never a `deletedAt` filter). `barcode_counters` is a snapshot/sequence → `updatedAt` only.
- Services throw `AppException('CODE')` with no inline status/message — the status/message MUST resolve from `ERROR_CATALOG` (`libs/common/src/errors/error-codes.ts`), never from the unused `apps/wms/src/common/error-codes.ts` (`WMS_ERRORS`), because `AppException` only reads `ERROR_CATALOG` (`libs/common/src/errors/app.exception.ts:25-29`). This plan removes `WMS_ERRORS` and folds every code into `ERROR_CATALOG`.
- Roles: attribute-option create/update/deactivate = `WmsRole.ADMIN` only. Attribute-option read + sku-template + sku-preview = `WmsRole.ADMIN, WmsRole.MANAGER`. Item creation stays `WmsRole.ADMIN, WmsRole.MANAGER` (unchanged from today).
- No client-supplied `sku`/`barcode`/`altBarcodes` accepted for `CUP_BLANK`/`MATERIAL`/`PACKAGING` creation. `CUP_PRINTED` cannot be created via the public endpoint at all (still created internally by `PrintJobService.resolveOutputItem`, untouched by this plan).
- EAN-13: prefix `20` (2 digits) + 10-digit atomic sequence (zero-padded) + 1 checksum digit = 13 digits total.
- Every Vietnamese comment in new code explains *why*, matching repo style — no restating *what* the code does.
- `pnpm lint`, targeted `jest`, and `nest build wms` must all pass before this plan is considered done.

---

## File Structure

```
libs/common/src/errors/error-codes.ts          MODIFY — fold WMS_ERRORS in, add 8 new issue codes
apps/wms/src/common/error-codes.ts             DELETE — dead file, nothing imports it

apps/wms/src/stock/schemas/
  warehouse-item.schema.ts                     MODIFY — add category?, ItemAttribute.key/optionId
  attribute-option.schema.ts                   CREATE — ItemAttributeOption
  barcode-counter.schema.ts                    CREATE — BarcodeCounter
  barcode-registry.schema.ts                   CREATE — BarcodeRegistryEntry

apps/wms/src/stock/sku/
  sku-template.registry.ts                     CREATE — 11 template defs + lookup fn
  sku-template.service.ts                      CREATE — resolves template incl. category branching
  sku-builder.ts                                CREATE — pure fn: template + option codes → SKU string
  sku-template.service.spec.ts                  CREATE
  sku-builder.spec.ts                           CREATE

apps/wms/src/stock/attribute-option/
  attribute-option.repository.ts                CREATE
  attribute-option.service.ts                   CREATE
  attribute-option.controller.ts                CREATE
  attribute-option.module.ts                    CREATE (imported by StockModule, or folded into it — see Task 12)
  dto/attribute-option.dto.ts                    CREATE
  attribute-option.service.spec.ts               CREATE

apps/wms/src/stock/barcode/
  ean13.ts                                       CREATE — pure checksum/generation fn
  ean13.spec.ts                                  CREATE
  barcode.repository.ts                          CREATE — counter increment + registry CRUD
  barcode.service.ts                             CREATE — generateUniqueBarcode(), findItemIdByCode()
  barcode.service.spec.ts                         CREATE

apps/wms/src/stock/dto/
  create-warehouse-item.dto.ts                   MODIFY — split into 4 discriminated create DTOs
  warehouse-item.response.dto.ts                 MODIFY — add category, attributes.key/optionId
  sku-template.response.dto.ts                   CREATE
  sku-preview.dto.ts                              CREATE

apps/wms/src/stock/stock.repository.ts           MODIFY — createItem/findItemBySku take session; findItemByBarcode repointed
apps/wms/src/stock/stock.service.ts               MODIFY — createWarehouseItem rewritten
apps/wms/src/stock/stock.controller.ts            MODIFY — new item creation flow, new sku-template/sku-preview endpoints
apps/wms/src/stock/stock.module.ts                MODIFY — register new schemas/providers/controllers

apps/wms/src/stock/stock.service.spec.ts          MODIFY — update createWarehouseItem tests
apps/wms/src/stock/stock.repository.spec.ts       MODIFY — session-param coverage

apps/wms/scripts/backfill-barcode-registry.ts     CREATE — dry-run report script
```

---

### Task 1: Fold `WMS_ERRORS` into `ERROR_CATALOG`, add the 8 new issue error codes

**Files:**
- Modify: `libs/common/src/errors/error-codes.ts`
- Delete: `apps/wms/src/common/error-codes.ts`
- Test: `libs/common/src/errors/error-codes.spec.ts` (create if none exists — check first)

**Interfaces:**
- Produces: `ERROR_CATALOG` gains every key currently in `WMS_ERRORS` (verbatim status/message) plus 8 new keys: `STOCK_SKU_TEMPLATE_NOT_FOUND` (404), `STOCK_SKU_TEMPLATE_MISMATCH` (400), `STOCK_ATTRIBUTE_OPTION_NOT_FOUND` (404), `STOCK_ATTRIBUTE_OPTION_INACTIVE` (400), `STOCK_ATTRIBUTE_CODE_CONFLICT` (409), `STOCK_ATTRIBUTE_CODE_IMMUTABLE` (400), `STOCK_ITEM_SKU_CONFLICT` (409, already exists — keep as-is, do not duplicate), `STOCK_ITEM_BARCODE_CONFLICT` (409).

- [ ] **Step 1: Check for an existing spec file covering `ERROR_CATALOG`**

Run: `find /home/hoaiphuong/code/wms-ecom/be/libs/common/src/errors -name "*.spec.ts"`

If `error-codes.spec.ts` doesn't exist, Step 2 creates a minimal one. If it exists, read it and extend it instead of creating a duplicate.

- [ ] **Step 2: Write the failing test**

Create `/home/hoaiphuong/code/wms-ecom/be/libs/common/src/errors/error-codes.spec.ts` (or append if it exists):

```ts
import { HttpStatus } from '@nestjs/common';
import { ERROR_CATALOG } from './error-codes';

describe('ERROR_CATALOG — WMS SKU/barcode codes (issue #25)', () => {
  it('chứa đủ 8 code mới của issue #25 với status đúng', () => {
    expect(ERROR_CATALOG.STOCK_SKU_TEMPLATE_NOT_FOUND.status).toBe(
      HttpStatus.NOT_FOUND,
    );
    expect(ERROR_CATALOG.STOCK_SKU_TEMPLATE_MISMATCH.status).toBe(
      HttpStatus.BAD_REQUEST,
    );
    expect(ERROR_CATALOG.STOCK_ATTRIBUTE_OPTION_NOT_FOUND.status).toBe(
      HttpStatus.NOT_FOUND,
    );
    expect(ERROR_CATALOG.STOCK_ATTRIBUTE_OPTION_INACTIVE.status).toBe(
      HttpStatus.BAD_REQUEST,
    );
    expect(ERROR_CATALOG.STOCK_ATTRIBUTE_CODE_CONFLICT.status).toBe(
      HttpStatus.CONFLICT,
    );
    expect(ERROR_CATALOG.STOCK_ATTRIBUTE_CODE_IMMUTABLE.status).toBe(
      HttpStatus.BAD_REQUEST,
    );
    expect(ERROR_CATALOG.STOCK_ITEM_SKU_CONFLICT.status).toBe(
      HttpStatus.CONFLICT,
    );
    expect(ERROR_CATALOG.STOCK_ITEM_BARCODE_CONFLICT.status).toBe(
      HttpStatus.CONFLICT,
    );
  });

  it('mọi code cũ của WMS_ERRORS (đã xóa) vẫn resolve đúng qua ERROR_CATALOG', () => {
    expect(ERROR_CATALOG.STOCK_ITEM_NOT_FOUND.status).toBe(
      HttpStatus.NOT_FOUND,
    );
    expect(ERROR_CATALOG.PRINT_JOB_ITEM_ALREADY_COMPLETED.status).toBe(
      HttpStatus.CONFLICT,
    );
    expect(ERROR_CATALOG.SHIPMENT_INVALID_TRANSITION.status).toBe(
      HttpStatus.BAD_REQUEST,
    );
  });
});
```

- [ ] **Step 2b: Run test to verify it fails**

Run: `npx jest libs/common/src/errors/error-codes.spec.ts`
Expected: FAIL — `ERROR_CATALOG.STOCK_SKU_TEMPLATE_NOT_FOUND` is `undefined` (TypeError reading `.status`).

- [ ] **Step 3: Fold `WMS_ERRORS` into `ERROR_CATALOG`**

Open `/home/hoaiphuong/code/wms-ecom/be/libs/common/src/errors/error-codes.ts`. Immediately before the closing `} as const;` (currently after the `USER_*` block), insert every key from `apps/wms/src/common/error-codes.ts` that is **not already present** in `ERROR_CATALOG` (i.e. skip `STOCK_ITEM_SKU_CONFLICT`, which already exists at line 18-21 of `libs/common`'s file with the exact same status/message). Add this block, preserving the exact status/message pairs from the deleted file:

```ts
  // ── WMS — Stock (WarehouseItem) ─────────────────────────────────────────
  STOCK_ITEM_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy mặt hàng trong kho',
  },
  STOCK_INSUFFICIENT: {
    status: HttpStatus.CONFLICT,
    message: 'Số lượng tồn kho không đủ',
  },
  LOT_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy lô hàng',
  },

  // ── WMS — Putaway ────────────────────────────────────────────────────────
  PUTAWAY_TASK_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy lệnh sắp xếp',
  },
  PUTAWAY_ITEM_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy mặt hàng theo barcode đã quét',
  },
  PUTAWAY_SHELF_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy vị trí theo barcode đã quét',
  },
  PUTAWAY_SHELF_IS_STAGING: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Không thể xếp hàng vào chính vị trí nhận hàng tạm (staging)',
  },
  PUTAWAY_ITEM_MISMATCH: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Mặt hàng hoặc lô quét được không thuộc lệnh sắp xếp này',
  },
  PUTAWAY_QTY_EXCEEDS: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Số lượng quét vượt quá số lượng còn lại cần xếp',
  },

  // ── WMS — Goods Issue ────────────────────────────────────────────────────
  GOODS_ISSUE_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy phiếu xuất kho',
  },
  GOODS_ISSUE_ITEM_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy mặt hàng theo barcode đã quét',
  },
  GOODS_ISSUE_SHELF_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy vị trí theo barcode đã quét',
  },
  GOODS_ISSUE_ITEM_MISMATCH: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Mặt hàng quét được không thuộc phiếu xuất kho này',
  },
  GOODS_ISSUE_QTY_EXCEEDS: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Số lượng quét vượt quá số lượng còn lại cần xuất',
  },

  // ── WMS — Print Job ──────────────────────────────────────────────────────
  PRINT_JOB_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy lệnh in',
  },
  PRINT_JOB_ITEM_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy mặt hàng theo barcode đã quét',
  },
  PRINT_JOB_SHELF_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy vị trí theo barcode đã quét',
  },
  PRINT_JOB_ITEM_MISMATCH: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Mặt hàng quét được không thuộc lệnh in này',
  },
  PRINT_JOB_QTY_EXCEEDS: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Số lượng quét vượt quá số lượng còn lại/đã tiêu thụ',
  },
  PRINT_JOB_ITEM_NOT_CONSUMED: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Dòng chưa tiêu thụ hết CUP_BLANK, chưa thể xác nhận in xong',
  },
  PRINT_JOB_ITEM_ALREADY_COMPLETED: {
    status: HttpStatus.CONFLICT,
    message: 'Dòng này đã được xác nhận in xong trước đó',
  },

  // ── WMS — Stock Count ────────────────────────────────────────────────────
  STOCK_COUNT_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy phiếu kiểm kho',
  },
  STOCK_COUNT_EMPTY_SCOPE: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Không có tồn kho nào trong phạm vi đã chọn',
  },
  STOCK_COUNT_ITEM_MISMATCH: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Vị trí/lô không thuộc phiếu kiểm kho này',
  },
  STOCK_COUNT_ALREADY_APPROVED: {
    status: HttpStatus.CONFLICT,
    message: 'Phiếu đã duyệt, không thể sửa',
  },
  STOCK_COUNT_NOT_COMPLETED: {
    status: HttpStatus.CONFLICT,
    message: 'Phiếu chưa đếm xong, không thể duyệt',
  },

  // ── WMS — Scrap Note ─────────────────────────────────────────────────────
  SCRAP_NOTE_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy phiếu hủy hàng',
  },
  SCRAP_NOTE_ITEM_ISPERISHABLE_NO_LOT: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Mặt hàng có hạn sử dụng phải chọn lô khi đề xuất hủy',
  },
  SCRAP_NOTE_QTY_EXCEEDS: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Số lượng đề xuất hủy vượt quá tồn thật tại vị trí này',
  },
  SCRAP_NOTE_ALREADY_DECIDED: {
    status: HttpStatus.CONFLICT,
    message: 'Phiếu đã được duyệt hoặc từ chối, không thể xử lý lại',
  },

  // ── WMS — Goods Return ───────────────────────────────────────────────────
  GOODS_RETURN_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy phiếu hoàn hàng',
  },
  GOODS_RETURN_ALREADY_DECIDED: {
    status: HttpStatus.CONFLICT,
    message: 'Phiếu đã xử lý xong hoặc đã huỷ, không thể thao tác lại',
  },
  GOODS_RETURN_ITEM_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Dòng hàng không tồn tại trong phiếu hoàn',
  },
  GOODS_RETURN_NOT_INSPECTED: {
    status: HttpStatus.CONFLICT,
    message: 'Phiếu chưa được kiểm tra tình trạng, không thể xác nhận',
  },
  GOODS_RETURN_ITEM_ISPERISHABLE_NO_LOT: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Mặt hàng có hạn sử dụng phải chọn lô khi nhập lại hàng tốt',
  },

  // ── WMS — Shipping ───────────────────────────────────────────────────────
  CARRIER_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy đơn vị vận chuyển',
  },
  CARRIER_CODE_CONFLICT: {
    status: HttpStatus.CONFLICT,
    message: 'Mã đơn vị vận chuyển đã tồn tại',
  },
  CARRIER_INACTIVE: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Đơn vị vận chuyển đã ngừng hoạt động',
  },
  SHIPMENT_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy vận đơn',
  },
  SHIPMENT_INVALID_TRANSITION: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Không thể chuyển sang trạng thái này từ trạng thái hiện tại',
  },
  SHIPMENT_NOT_ASSIGNED: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Vận đơn chưa được gán hãng vận chuyển',
  },

  // ── WMS — SKU Template / Attribute Option / Barcode Registry (issue #25) ──
  // AppException chỉ resolve status/message qua ERROR_CATALOG (xem
  // libs/common/src/errors/app.exception.ts) — KHÔNG thêm code domain WMS vào
  // apps/wms/src/common/error-codes.ts nữa (file đó đã bị xóa vì chưa từng
  // được đọc, mọi throw new AppException('CODE') từng âm thầm trả 400 sai).
  STOCK_SKU_TEMPLATE_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy template SKU cho loại/nhóm mặt hàng này',
  },
  STOCK_SKU_TEMPLATE_MISMATCH: {
    status: HttpStatus.BAD_REQUEST,
    message: 'templateId không khớp với itemType/category đã chọn',
  },
  STOCK_ATTRIBUTE_OPTION_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy option thuộc tính',
  },
  STOCK_ATTRIBUTE_OPTION_INACTIVE: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Option thuộc tính đã ngừng sử dụng',
  },
  STOCK_ATTRIBUTE_CODE_CONFLICT: {
    status: HttpStatus.CONFLICT,
    message: 'Code đã tồn tại trong nhóm thuộc tính này',
  },
  STOCK_ATTRIBUTE_CODE_IMMUTABLE: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Không thể sửa code của option đã được sử dụng',
  },
  STOCK_ITEM_BARCODE_CONFLICT: {
    status: HttpStatus.CONFLICT,
    message: 'Barcode bị trùng, thử lại thao tác',
  },
```

Also update the file's top comment (currently: `App tự thêm mã miền (vd STOCK_INSUFFICIENT) ở apps/<app>/src/common/error-codes.ts`) — remove the now-false claim since `apps/wms` no longer has its own error-codes file:

```ts
/**
 * Catalog mã lỗi CHUNG cho mọi app. Mỗi code có HTTP status + message mặc định.
 * AppException nhận mọi chuỗi code, không bắt buộc nằm trong catalog này — nhưng
 * NẾU không có ở đây, AppException fallback về HttpStatus.BAD_REQUEST + message=code
 * (xem app.exception.ts). Vì AppException chỉ đọc catalog này (không đọc file nào
 * khác), toàn bộ code domain của mọi app (kể cả WMS-only) đặt tại đây.
 */
```

- [ ] **Step 4: Delete the dead file**

Run: `rm /home/hoaiphuong/code/wms-ecom/be/apps/wms/src/common/error-codes.ts`

- [ ] **Step 5: Run test to verify it passes**

Run: `npx jest libs/common/src/errors/error-codes.spec.ts`
Expected: PASS (both tests green).

- [ ] **Step 6: Run full lint + existing WMS test suite to confirm nothing referenced the deleted file**

Run: `npx eslint libs/common/src/errors/error-codes.ts && npx jest apps/wms --silent 2>&1 | tail -30`
Expected: lint clean; all existing `apps/wms` specs still pass (they only ever imported `AppException`/`ERROR_CATALOG`, never `WMS_ERRORS`, per the repo-wide grep already done during planning).

- [ ] **Step 7: Commit**

```bash
git add libs/common/src/errors/error-codes.ts libs/common/src/errors/error-codes.spec.ts
git rm apps/wms/src/common/error-codes.ts
git commit -m "fix(wms): fold unused WMS_ERRORS into ERROR_CATALOG, add issue #25 error codes"
```

---

### Task 2: `ItemAttributeOption` schema

**Files:**
- Create: `apps/wms/src/stock/schemas/attribute-option.schema.ts`
- Test: none (pure schema — covered indirectly by Task 3's repository tests)

**Interfaces:**
- Produces: `ItemAttributeOption` class, `ItemAttributeOptionDocument` type, `AttributeOptionKey` string union type, `ItemAttributeOptionSchema`.

- [ ] **Step 1: Write the schema**

```ts
// apps/wms/src/stock/schemas/attribute-option.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

/**
 * Nhóm thuộc tính hợp lệ — cố định theo template registry (sku-template.registry.ts).
 * ADMIN chỉ tạo option TRONG các key này, không tự thêm key mới (ngoài scope issue #25:
 * "ADMIN tự thiết kế template/category mới trên UI").
 */
export enum AttributeOptionKey {
  // Cup
  CUP_STYLE = 'CUP_STYLE',
  MATERIAL = 'MATERIAL',
  CAPACITY = 'CAPACITY',
  COLOR = 'COLOR',
  // Material
  MATERIAL_CATEGORY = 'MATERIAL_CATEGORY',
  MATERIAL_TYPE = 'MATERIAL_TYPE',
  FLAVOR = 'FLAVOR',
  SPEC = 'SPEC',
  // Packaging
  PACKAGING_CATEGORY = 'PACKAGING_CATEGORY',
  PACKAGING_STYLE = 'PACKAGING_STYLE',
  COMPATIBILITY = 'COMPATIBILITY',
  DIAMETER = 'DIAMETER',
  LENGTH = 'LENGTH',
  SIZE = 'SIZE',
}

/**
 * Option giá trị thuộc tính (vd key=COLOR, code=CLR, name="Trong suốt") dùng để
 * ADMIN quản lý danh sách giá trị hợp lệ cho mỗi field template, KHÔNG phải để
 * ADMIN đổi cấu trúc template. Soft-delete + deactivate tách biệt: deactivate
 * (isActive=false) là thao tác thường xuyên (ẩn khỏi lựa chọn mới, option cũ
 * vẫn hiển thị đúng trên item đã tạo); soft-delete gần như không dùng tới vì
 * option đã dùng không được xóa vật lý (xem STOCK_ATTRIBUTE_CODE_IMMUTABLE).
 */
@Schema({ collection: 'item_attribute_options', timestamps: true })
export class ItemAttributeOption {
  @Prop({ enum: AttributeOptionKey, required: true })
  key!: AttributeOptionKey;

  @Prop({ required: true })
  name!: string;

  /** Đoạn mã ngắn dùng ghép vào SKU (vd "CLR", "HRT") — unique trong cùng key. */
  @Prop({ required: true })
  code!: string;

  @Prop({ default: true })
  isActive!: boolean;

  @Prop({ default: 0 })
  sortOrder!: number;

  @Prop({ type: Types.ObjectId })
  createdBy?: Types.ObjectId;

  @Prop({ type: Types.ObjectId })
  updatedBy?: Types.ObjectId;

  @Prop({ type: Date, default: null })
  deletedAt?: Date | null;
}

export type ItemAttributeOptionDocument = HydratedDocument<ItemAttributeOption>;
export const ItemAttributeOptionSchema = SchemaFactory.createForClass(
  ItemAttributeOption,
);

ItemAttributeOptionSchema.index({ key: 1, code: 1 }, { unique: true });
ItemAttributeOptionSchema.index({ key: 1, isActive: 1 });
ItemAttributeOptionSchema.index({ deletedAt: 1 });
```

- [ ] **Step 2: Verify it compiles**

Run: `npx tsc --noEmit -p apps/wms/tsconfig.app.json 2>&1 | grep attribute-option || echo "no errors"`
Expected: `no errors` (schema-only files have no runtime test at this stage — correctness is verified via Task 3's repository tests exercising it against real class shapes).

- [ ] **Step 3: Commit**

```bash
git add apps/wms/src/stock/schemas/attribute-option.schema.ts
git commit -m "feat(wms): add ItemAttributeOption schema for SKU attribute values"
```

---

### Task 3: `AttributeOptionRepository` + `AttributeOptionService` (CRUD + code-suggestion)

**Files:**
- Create: `apps/wms/src/stock/attribute-option/attribute-option.repository.ts`
- Create: `apps/wms/src/stock/attribute-option/attribute-option.service.ts`
- Test: `apps/wms/src/stock/attribute-option/attribute-option.service.spec.ts`

**Interfaces:**
- Consumes: `ItemAttributeOption`, `ItemAttributeOptionDocument`, `AttributeOptionKey` from Task 2 (`../schemas/attribute-option.schema`). `AppException` from `@app/common`.
- Produces:
  - `AttributeOptionRepository`: `findByKey(key: AttributeOptionKey, includeInactive: boolean): Promise<ItemAttributeOptionDocument[]>`, `findById(id: string): Promise<ItemAttributeOptionDocument | null>`, `findByKeyAndCode(key: AttributeOptionKey, code: string): Promise<ItemAttributeOptionDocument | null>`, `findByIds(ids: string[]): Promise<ItemAttributeOptionDocument[]>`, `create(data: CreateAttributeOptionData, createdBy: Types.ObjectId): Promise<ItemAttributeOptionDocument>`, `update(id: string, data: Partial<{ name: string; code: string; isActive: boolean; sortOrder: number }>, updatedBy: Types.ObjectId): Promise<ItemAttributeOptionDocument | null>`.
  - `AttributeOptionService`: `list(key: AttributeOptionKey, includeInactive: boolean)`, `suggestCode(key: AttributeOptionKey, name: string): { code: string }`, `create(dto: CreateAttributeOptionDto, actorId: string)`, `update(id: string, dto: UpdateAttributeOptionDto, actorId: string)`.
  - Exports `suggestCodeFromName(name: string): string` as a standalone pure function (also unit-tested directly) — strips diacritics, uppercases, takes first letters of words up to 6 chars, non-alnum stripped.

- [ ] **Step 1: Write the failing tests**

Create `apps/wms/src/stock/attribute-option/attribute-option.service.spec.ts`:

```ts
import { Types } from 'mongoose';
import {
  AttributeOptionService,
  suggestCodeFromName,
} from './attribute-option.service';
import { AttributeOptionKey } from '../schemas/attribute-option.schema';

const makeRepo = () => ({
  findByKey: jest.fn(),
  findById: jest.fn(),
  findByKeyAndCode: jest.fn(),
  findByIds: jest.fn(),
  create: jest.fn(),
  update: jest.fn(),
});

describe('suggestCodeFromName', () => {
  it('bỏ dấu, uppercase, ghép chữ cái đầu mỗi từ, tối đa 6 ký tự', () => {
    expect(suggestCodeFromName('Trong suốt')).toBe('TS');
    expect(suggestCodeFromName('Trái Tim')).toBe('TT');
    expect(suggestCodeFromName('Đường nâu')).toBe('DN');
  });

  it('từ đơn dài → cắt 6 ký tự đầu, bỏ dấu, uppercase', () => {
    expect(suggestCodeFromName('Matcha')).toBe('MATCHA');
    expect(suggestCodeFromName('Chocolate')).toBe('CHOCOL');
  });

  it('loại ký tự không phải chữ/số', () => {
    expect(suggestCodeFromName('Ly 500ml!')).toBe('L5');
  });
});

describe('AttributeOptionService', () => {
  let svc: AttributeOptionService;
  let repo: ReturnType<typeof makeRepo>;
  const actorId = new Types.ObjectId().toString();

  beforeEach(() => {
    repo = makeRepo();
    svc = new AttributeOptionService(repo as never);
  });

  describe('create', () => {
    const dto = {
      key: AttributeOptionKey.COLOR,
      name: 'Trong suốt',
      code: 'CLR',
    };

    it('tạo option mới khi code chưa tồn tại trong key', async () => {
      repo.findByKeyAndCode.mockResolvedValue(null);
      repo.create.mockResolvedValue({ _id: new Types.ObjectId(), ...dto });

      await svc.create(dto, actorId);

      expect(repo.findByKeyAndCode).toHaveBeenCalledWith(
        AttributeOptionKey.COLOR,
        'CLR',
      );
      expect(repo.create).toHaveBeenCalledWith(
        dto,
        new Types.ObjectId(actorId),
      );
    });

    it('throw STOCK_ATTRIBUTE_CODE_CONFLICT khi code đã tồn tại trong cùng key', async () => {
      repo.findByKeyAndCode.mockResolvedValue({ _id: new Types.ObjectId() });

      await expect(svc.create(dto, actorId)).rejects.toMatchObject({
        code: 'STOCK_ATTRIBUTE_CODE_CONFLICT',
      });
      expect(repo.create).not.toHaveBeenCalled();
    });
  });

  describe('update', () => {
    const id = new Types.ObjectId().toString();

    it('throw STOCK_ATTRIBUTE_CODE_IMMUTABLE khi cố đổi code', async () => {
      repo.findById.mockResolvedValue({
        _id: id,
        key: AttributeOptionKey.COLOR,
        code: 'CLR',
      });

      await expect(
        svc.update(id, { code: 'NEW' } as never, actorId),
      ).rejects.toMatchObject({ code: 'STOCK_ATTRIBUTE_CODE_IMMUTABLE' });
      expect(repo.update).not.toHaveBeenCalled();
    });

    it('cho phép đổi name/isActive/sortOrder (không đụng code)', async () => {
      repo.findById.mockResolvedValue({
        _id: id,
        key: AttributeOptionKey.COLOR,
        code: 'CLR',
      });
      repo.update.mockResolvedValue({ _id: id, name: 'Đỏ' });

      await svc.update(id, { name: 'Đỏ' } as never, actorId);

      expect(repo.update).toHaveBeenCalledWith(
        id,
        { name: 'Đỏ' },
        new Types.ObjectId(actorId),
      );
    });

    it('throw STOCK_ATTRIBUTE_OPTION_NOT_FOUND khi id không tồn tại', async () => {
      repo.findById.mockResolvedValue(null);

      await expect(
        svc.update(id, { name: 'x' } as never, actorId),
      ).rejects.toMatchObject({ code: 'STOCK_ATTRIBUTE_OPTION_NOT_FOUND' });
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest apps/wms/src/stock/attribute-option/attribute-option.service.spec.ts`
Expected: FAIL — module `./attribute-option.service` doesn't exist.

- [ ] **Step 3: Write the repository**

```ts
// apps/wms/src/stock/attribute-option/attribute-option.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import {
  AttributeOptionKey,
  ItemAttributeOption,
  ItemAttributeOptionDocument,
} from '../schemas/attribute-option.schema';

export type CreateAttributeOptionData = {
  key: AttributeOptionKey;
  name: string;
  code: string;
};

@Injectable()
export class AttributeOptionRepository {
  constructor(
    @InjectModel(ItemAttributeOption.name)
    private readonly model: Model<ItemAttributeOption>,
  ) {}

  findByKey(
    key: AttributeOptionKey,
    includeInactive: boolean,
  ): Promise<ItemAttributeOptionDocument[]> {
    const filter: Record<string, unknown> = { key, deletedAt: null };
    if (!includeInactive) filter['isActive'] = true;
    return this.model.find(filter).sort({ sortOrder: 1, name: 1 }).exec();
  }

  findById(id: string): Promise<ItemAttributeOptionDocument | null> {
    return this.model.findOne({ _id: id, deletedAt: null }).exec();
  }

  findByKeyAndCode(
    key: AttributeOptionKey,
    code: string,
  ): Promise<ItemAttributeOptionDocument | null> {
    return this.model.findOne({ key, code, deletedAt: null }).exec();
  }

  findByIds(ids: string[]): Promise<ItemAttributeOptionDocument[]> {
    return this.model.find({ _id: { $in: ids }, deletedAt: null }).exec();
  }

  create(
    data: CreateAttributeOptionData,
    createdBy: Types.ObjectId,
  ): Promise<ItemAttributeOptionDocument> {
    return this.model.create({ ...data, createdBy, isActive: true });
  }

  update(
    id: string,
    data: Partial<{ name: string; isActive: boolean; sortOrder: number }>,
    updatedBy: Types.ObjectId,
  ): Promise<ItemAttributeOptionDocument | null> {
    return this.model
      .findOneAndUpdate(
        { _id: id, deletedAt: null },
        { ...data, updatedBy },
        { new: true },
      )
      .exec();
  }
}
```

- [ ] **Step 4: Write the service**

```ts
// apps/wms/src/stock/attribute-option/attribute-option.service.ts
import { Injectable } from '@nestjs/common';
import { AppException } from '@app/common';
import { Types } from 'mongoose';
import {
  AttributeOptionRepository,
  CreateAttributeOptionData,
} from './attribute-option.repository';
import { AttributeOptionKey } from '../schemas/attribute-option.schema';

/**
 * Gợi ý code từ name: bỏ dấu tiếng Việt, uppercase, ghép chữ cái đầu mỗi từ
 * (name nhiều từ) hoặc cắt 6 ký tự đầu (name 1 từ) — ADMIN luôn phải xác nhận/
 * sửa lại trước khi lưu (issue #25: "Hệ thống gợi ý code; ADMIN phải xác nhận").
 */
export function suggestCodeFromName(name: string): string {
  const stripped = name
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/đ/gi, 'd')
    .replace(/[^a-zA-Z0-9\s]/g, '')
    .trim();

  const words = stripped.split(/\s+/).filter(Boolean);

  if (words.length > 1) {
    return words
      .map((w) => w[0])
      .join('')
      .toUpperCase()
      .slice(0, 6);
  }
  return (words[0] ?? '').toUpperCase().slice(0, 6);
}

export type CreateAttributeOptionDto = CreateAttributeOptionData;
export type UpdateAttributeOptionDto = Partial<{
  name: string;
  isActive: boolean;
  sortOrder: number;
}>;

@Injectable()
export class AttributeOptionService {
  constructor(private readonly repo: AttributeOptionRepository) {}

  list(key: AttributeOptionKey, includeInactive: boolean) {
    return this.repo.findByKey(key, includeInactive);
  }

  suggestCode(_key: AttributeOptionKey, name: string): { code: string } {
    return { code: suggestCodeFromName(name) };
  }

  async create(dto: CreateAttributeOptionDto, actorId: string) {
    const existing = await this.repo.findByKeyAndCode(dto.key, dto.code);
    if (existing) {
      throw new AppException('STOCK_ATTRIBUTE_CODE_CONFLICT');
    }
    return this.repo.create(dto, new Types.ObjectId(actorId));
  }

  async update(id: string, dto: UpdateAttributeOptionDto, actorId: string) {
    const existing = await this.repo.findById(id);
    if (!existing) {
      throw new AppException('STOCK_ATTRIBUTE_OPTION_NOT_FOUND');
    }
    // Code bất biến sau khi tạo — option có thể đã được dùng để build SKU của
    // item đang tồn tại, đổi code sẽ làm sai lệch snapshot attributes[].code
    // trên các item cũ (xem data-and-mongoose.md: "Không sửa code sau khi option đã dùng").
    if ('code' in dto) {
      throw new AppException('STOCK_ATTRIBUTE_CODE_IMMUTABLE');
    }
    return this.repo.update(id, dto, new Types.ObjectId(actorId));
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx jest apps/wms/src/stock/attribute-option/attribute-option.service.spec.ts`
Expected: PASS (10 tests).

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/stock/attribute-option/attribute-option.repository.ts apps/wms/src/stock/attribute-option/attribute-option.service.ts apps/wms/src/stock/attribute-option/attribute-option.service.spec.ts
git commit -m "feat(wms): add AttributeOptionRepository/Service with code-suggestion"
```

---

### Task 4: Attribute-option DTOs + controller

**Files:**
- Create: `apps/wms/src/stock/attribute-option/dto/attribute-option.dto.ts`
- Create: `apps/wms/src/stock/attribute-option/attribute-option.controller.ts`
- Test: covered by Task 12's e2e-style controller wiring smoke test (build + Swagger check); no dedicated controller spec per repo convention (controllers here are thin wrappers, business logic tested at service level — matches `stock.controller.ts` having no `.spec.ts` of its own).

**Interfaces:**
- Consumes: `AttributeOptionService`, `AttributeOptionKey` (Task 2/3).
- Produces: `CreateAttributeOptionDto`, `UpdateAttributeOptionDto`, `CodeSuggestionDto`, `CodeSuggestionResponseDto`, `AttributeOptionResponseDto` request/response DTOs; `AttributeOptionController` with routes `GET /stock/attribute-options`, `POST /stock/attribute-options/code-suggestion`, `POST /stock/attribute-options`, `PATCH /stock/attribute-options/:id`.

- [ ] **Step 1: Write the DTOs**

```ts
// apps/wms/src/stock/attribute-option/dto/attribute-option.dto.ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Expose, Transform } from 'class-transformer';
import {
  IsBoolean,
  IsEnum,
  IsInt,
  IsOptional,
  IsString,
  MinLength,
} from 'class-validator';
import { Types } from 'mongoose';
import { AttributeOptionKey } from '../../schemas/attribute-option.schema';

export class QueryAttributeOptionDto {
  @ApiProperty({ enum: AttributeOptionKey })
  @IsEnum(AttributeOptionKey)
  key!: AttributeOptionKey;

  @ApiPropertyOptional({ default: false })
  @IsOptional()
  @Transform(({ value }: { value: unknown }) => value === 'true' || value === true)
  @IsBoolean()
  includeInactive?: boolean;
}

export class CodeSuggestionDto {
  @ApiProperty({ enum: AttributeOptionKey })
  @IsEnum(AttributeOptionKey)
  key!: AttributeOptionKey;

  @ApiProperty({ example: 'Trong suốt' })
  @IsString()
  @MinLength(1)
  name!: string;
}

export class CodeSuggestionResponseDto {
  @Expose()
  @ApiProperty({ example: 'TS' })
  code!: string;
}

export class CreateAttributeOptionDto {
  @ApiProperty({ enum: AttributeOptionKey })
  @IsEnum(AttributeOptionKey)
  key!: AttributeOptionKey;

  @ApiProperty({ example: 'Trong suốt' })
  @IsString()
  @MinLength(1)
  name!: string;

  @ApiProperty({ example: 'CLR' })
  @IsString()
  @MinLength(1)
  code!: string;
}

export class UpdateAttributeOptionDto {
  @ApiPropertyOptional({ example: 'Trong suốt (đã đổi tên)' })
  @IsOptional()
  @IsString()
  @MinLength(1)
  name?: string;

  @ApiPropertyOptional({ example: true })
  @IsOptional()
  @IsBoolean()
  isActive?: boolean;

  @ApiPropertyOptional({ example: 10 })
  @IsOptional()
  @IsInt()
  sortOrder?: number;
}

export class AttributeOptionResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId } }) =>
    obj._id?.toString(),
  )
  @ApiProperty()
  id!: string;

  @Expose()
  @ApiProperty({ enum: AttributeOptionKey })
  key!: AttributeOptionKey;

  @Expose()
  @ApiProperty()
  name!: string;

  @Expose()
  @ApiProperty()
  code!: string;

  @Expose()
  @ApiProperty()
  isActive!: boolean;

  @Expose()
  @ApiProperty()
  sortOrder!: number;
}
```

- [ ] **Step 2: Write the controller**

```ts
// apps/wms/src/stock/attribute-option/attribute-option.controller.ts
import { Body, Controller, Get, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiCreatedResponse, ApiOkResponse, ApiOperation, ApiTags } from '@nestjs/swagger';
import { CurrentUser, JwtAuthGuard, Roles, RolesGuard, WmsRole } from '@app/auth';
import { plainToInstance } from 'class-transformer';
import { AttributeOptionService } from './attribute-option.service';
import {
  AttributeOptionResponseDto,
  CodeSuggestionDto,
  CodeSuggestionResponseDto,
  CreateAttributeOptionDto,
  QueryAttributeOptionDto,
  UpdateAttributeOptionDto,
} from './dto/attribute-option.dto';

const TO_OPTS = { excludeExtraneousValues: true } as const;

@ApiTags('stock-attribute-options')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard, RolesGuard)
@Controller('stock/attribute-options')
export class AttributeOptionController {
  constructor(private readonly svc: AttributeOptionService) {}

  @Get()
  @Roles(WmsRole.ADMIN, WmsRole.MANAGER)
  @ApiOperation({ summary: 'Danh sách option thuộc tính theo key — [ADMIN, MANAGER]' })
  @ApiOkResponse({ type: [AttributeOptionResponseDto] })
  async list(@Query() query: QueryAttributeOptionDto) {
    const list = await this.svc.list(query.key, query.includeInactive ?? false);
    return plainToInstance(AttributeOptionResponseDto, list, TO_OPTS);
  }

  @Post('code-suggestion')
  @Roles(WmsRole.ADMIN)
  @ApiOperation({ summary: 'Gợi ý code từ name — ADMIN xác nhận trước khi lưu — [ADMIN]' })
  @ApiOkResponse({ type: CodeSuggestionResponseDto })
  suggestCode(@Body() dto: CodeSuggestionDto) {
    const result = this.svc.suggestCode(dto.key, dto.name);
    return plainToInstance(CodeSuggestionResponseDto, result, TO_OPTS);
  }

  @Post()
  @Roles(WmsRole.ADMIN)
  @ApiOperation({ summary: 'Tạo option thuộc tính mới — [ADMIN]' })
  @ApiCreatedResponse({ type: AttributeOptionResponseDto })
  async create(
    @Body() dto: CreateAttributeOptionDto,
    @CurrentUser('sub') actorId: string,
  ) {
    const doc = await this.svc.create(dto, actorId);
    return plainToInstance(AttributeOptionResponseDto, doc.toObject(), TO_OPTS);
  }

  @Patch(':id')
  @Roles(WmsRole.ADMIN)
  @ApiOperation({ summary: 'Cập nhật option (name/isActive/sortOrder, không sửa code) — [ADMIN]' })
  @ApiOkResponse({ type: AttributeOptionResponseDto })
  async update(
    @Param('id') id: string,
    @Body() dto: UpdateAttributeOptionDto,
    @CurrentUser('sub') actorId: string,
  ) {
    const doc = await this.svc.update(id, dto, actorId);
    return plainToInstance(AttributeOptionResponseDto, doc?.toObject(), TO_OPTS);
  }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `npx tsc --noEmit -p apps/wms/tsconfig.app.json 2>&1 | grep attribute-option || echo "no errors"`
Expected: `no errors` (module isn't wired into `StockModule` yet — that's Task 12 — so this compiles standalone).

- [ ] **Step 4: Commit**

```bash
git add apps/wms/src/stock/attribute-option/dto/attribute-option.dto.ts apps/wms/src/stock/attribute-option/attribute-option.controller.ts
git commit -m "feat(wms): add attribute-option DTOs and admin controller"
```

---

### Task 5: SKU template registry (11 templates, pure data + lookup)

**Files:**
- Create: `apps/wms/src/stock/sku/sku-template.registry.ts`
- Test: `apps/wms/src/stock/sku/sku-template.registry.spec.ts`

**Interfaces:**
- Consumes: `ItemType` from `../schemas/warehouse-item.schema`; `AttributeOptionKey` from `../schemas/attribute-option.schema`.
- Produces:
  - `interface SkuTemplateField { key: AttributeOptionKey }` — ordered list of fields.
  - `interface SkuTemplate { templateId: string; itemType: ItemType; category: string | null; prefix: string; fields: SkuTemplateField[] }` (`category: null` for `CUP_BLANK`, which has no category branching).
  - `SKU_TEMPLATES: SkuTemplate[]` — all 11 templates below.
  - `findRootTemplates(itemType: ItemType): SkuTemplate[]` — returns matching templates (1 for `CUP_BLANK`, all category variants for `MATERIAL`/`PACKAGING`).
  - `findTemplateById(templateId: string): SkuTemplate | undefined`.
  - `CATEGORY_CODE_KEY: Record<'MATERIAL' | 'PACKAGING', AttributeOptionKey>` mapping `MATERIAL → MATERIAL_CATEGORY`, `PACKAGING → PACKAGING_CATEGORY` (used by Task 6 to know which option key represents "category" for a given itemType).

- [ ] **Step 1: Write the failing test**

```ts
// apps/wms/src/stock/sku/sku-template.registry.spec.ts
import { ItemType } from '../schemas/warehouse-item.schema';
import {
  SKU_TEMPLATES,
  findRootTemplates,
  findTemplateById,
} from './sku-template.registry';

describe('sku-template.registry', () => {
  it('khai đủ 11 template (1 CUP_BLANK + 6 MATERIAL + 4 PACKAGING)', () => {
    expect(SKU_TEMPLATES).toHaveLength(11);
    expect(
      SKU_TEMPLATES.filter((t) => t.itemType === ItemType.CUP_BLANK),
    ).toHaveLength(1);
    expect(
      SKU_TEMPLATES.filter((t) => t.itemType === ItemType.MATERIAL),
    ).toHaveLength(6);
    expect(
      SKU_TEMPLATES.filter((t) => t.itemType === ItemType.PACKAGING),
    ).toHaveLength(4);
  });

  it('CUP_BLANK trả đúng 1 template ngay (không cần category)', () => {
    const templates = findRootTemplates(ItemType.CUP_BLANK);
    expect(templates).toHaveLength(1);
    expect(templates[0].prefix).toBe('CUP');
    expect(templates[0].fields.map((f) => f.key)).toEqual([
      'CUP_STYLE',
      'MATERIAL',
      'CAPACITY',
      'COLOR',
    ]);
  });

  it('MATERIAL trả về 6 template con (mỗi nhóm 1 template)', () => {
    const templates = findRootTemplates(ItemType.MATERIAL);
    expect(templates).toHaveLength(6);
  });

  it('template Syrup đúng field order theo issue: FLAVOR, SPEC (không có MATERIAL_TYPE)', () => {
    const syrup = SKU_TEMPLATES.find((t) => t.templateId === 'MATERIAL_SYRUP');
    expect(syrup?.prefix).toBe('MAT-SYR');
    expect(syrup?.fields.map((f) => f.key)).toEqual(['FLAVOR', 'SPEC']);
  });

  it('findTemplateById trả undefined nếu không khớp', () => {
    expect(findTemplateById('NOPE')).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest apps/wms/src/stock/sku/sku-template.registry.spec.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the registry**

```ts
// apps/wms/src/stock/sku/sku-template.registry.ts
import { ItemType } from '../schemas/warehouse-item.schema';
import { AttributeOptionKey } from '../schemas/attribute-option.schema';

export interface SkuTemplateField {
  key: AttributeOptionKey;
}

/**
 * category=null cho CUP_BLANK (không phân nhóm con). category != null cho
 * MATERIAL/PACKAGING — mỗi nhóm (Trà, Sữa, Nắp ly...) là 1 template riêng,
 * chọn qua categoryOptionId (issue #25: "MATERIAL/PACKAGING lần đầu trả
 * category options; sau khi chọn category trả child template").
 */
export interface SkuTemplate {
  templateId: string;
  itemType: ItemType;
  category: string | null;
  prefix: string;
  fields: SkuTemplateField[];
}

const f = (key: AttributeOptionKey): SkuTemplateField => ({ key });

/**
 * 11 template đã chốt trong issue #25 — KHÔNG đọc từ DB, ADMIN không sửa cấu
 * trúc này qua UI (chỉ quản lý option VALUE qua AttributeOptionService).
 * Đổi template = sửa code + review, không phải thao tác vận hành.
 */
export const SKU_TEMPLATES: SkuTemplate[] = [
  {
    templateId: 'CUP_BLANK',
    itemType: ItemType.CUP_BLANK,
    category: null,
    prefix: 'CUP',
    fields: [
      f(AttributeOptionKey.CUP_STYLE),
      f(AttributeOptionKey.MATERIAL),
      f(AttributeOptionKey.CAPACITY),
      f(AttributeOptionKey.COLOR),
    ],
  },
  {
    templateId: 'MATERIAL_TEA',
    itemType: ItemType.MATERIAL,
    category: 'TEA',
    prefix: 'MAT-TEA',
    fields: [
      f(AttributeOptionKey.MATERIAL_TYPE),
      f(AttributeOptionKey.FLAVOR),
      f(AttributeOptionKey.SPEC),
    ],
  },
  {
    templateId: 'MATERIAL_MILK',
    itemType: ItemType.MATERIAL,
    category: 'MILK',
    prefix: 'MAT-MILK',
    fields: [f(AttributeOptionKey.MATERIAL_TYPE), f(AttributeOptionKey.SPEC)],
  },
  {
    templateId: 'MATERIAL_SUGAR',
    itemType: ItemType.MATERIAL,
    category: 'SUGAR',
    prefix: 'MAT-SUGAR',
    fields: [f(AttributeOptionKey.MATERIAL_TYPE), f(AttributeOptionKey.SPEC)],
  },
  {
    templateId: 'MATERIAL_TOPPING',
    itemType: ItemType.MATERIAL,
    category: 'TOPPING',
    prefix: 'MAT-TOP',
    fields: [
      f(AttributeOptionKey.MATERIAL_TYPE),
      f(AttributeOptionKey.FLAVOR),
      f(AttributeOptionKey.SPEC),
    ],
  },
  {
    templateId: 'MATERIAL_SYRUP',
    itemType: ItemType.MATERIAL,
    category: 'SYRUP',
    prefix: 'MAT-SYR',
    fields: [f(AttributeOptionKey.FLAVOR), f(AttributeOptionKey.SPEC)],
  },
  {
    templateId: 'MATERIAL_POWDER',
    itemType: ItemType.MATERIAL,
    category: 'POWDER',
    prefix: 'MAT-PWD',
    fields: [f(AttributeOptionKey.FLAVOR), f(AttributeOptionKey.SPEC)],
  },
  {
    templateId: 'PACKAGING_LID',
    itemType: ItemType.PACKAGING,
    category: 'LID',
    prefix: 'PKG-LID',
    fields: [
      f(AttributeOptionKey.PACKAGING_STYLE),
      f(AttributeOptionKey.COMPATIBILITY),
      f(AttributeOptionKey.COLOR),
    ],
  },
  {
    templateId: 'PACKAGING_STRAW',
    itemType: ItemType.PACKAGING,
    category: 'STRAW',
    prefix: 'PKG-STR',
    fields: [
      f(AttributeOptionKey.DIAMETER),
      f(AttributeOptionKey.LENGTH),
      f(AttributeOptionKey.COLOR),
    ],
  },
  {
    templateId: 'PACKAGING_BAG',
    itemType: ItemType.PACKAGING,
    category: 'BAG',
    prefix: 'PKG-BAG',
    fields: [
      f(AttributeOptionKey.MATERIAL),
      f(AttributeOptionKey.SIZE),
      f(AttributeOptionKey.COLOR),
    ],
  },
  {
    templateId: 'PACKAGING_BOX',
    itemType: ItemType.PACKAGING,
    category: 'BOX',
    prefix: 'PKG-BOX',
    fields: [
      f(AttributeOptionKey.MATERIAL),
      f(AttributeOptionKey.SIZE),
      f(AttributeOptionKey.COLOR),
    ],
  },
];

/** itemType nào cần chọn category trước (MATERIAL/PACKAGING) → key option đại diện category đó. */
export const CATEGORY_CODE_KEY: Partial<Record<ItemType, AttributeOptionKey>> = {
  [ItemType.MATERIAL]: AttributeOptionKey.MATERIAL_CATEGORY,
  [ItemType.PACKAGING]: AttributeOptionKey.PACKAGING_CATEGORY,
};

export function findRootTemplates(itemType: ItemType): SkuTemplate[] {
  return SKU_TEMPLATES.filter((t) => t.itemType === itemType);
}

export function findTemplateById(templateId: string): SkuTemplate | undefined {
  return SKU_TEMPLATES.find((t) => t.templateId === templateId);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest apps/wms/src/stock/sku/sku-template.registry.spec.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/sku/sku-template.registry.ts apps/wms/src/stock/sku/sku-template.registry.spec.ts
git commit -m "feat(wms): add SKU template registry (11 templates for CUP_BLANK/MATERIAL/PACKAGING)"
```

---

### Task 6: `SkuBuilder` — pure function joining template + option codes into final SKU

**Files:**
- Create: `apps/wms/src/stock/sku/sku-builder.ts`
- Test: `apps/wms/src/stock/sku/sku-builder.spec.ts`

**Interfaces:**
- Consumes: `SkuTemplate` from Task 5.
- Produces: `buildSku(template: SkuTemplate, codesByKey: Record<string, string>): string` — throws plain `Error` (caller in Task 7 wraps as `AppException`) if a required field's code is missing, to keep this function framework-agnostic and trivially testable.

- [ ] **Step 1: Write the failing test**

```ts
// apps/wms/src/stock/sku/sku-builder.spec.ts
import { buildSku } from './sku-builder';
import { findTemplateById } from './sku-template.registry';

describe('buildSku', () => {
  it('sinh đúng CUP-HRT-PET-500-CLR theo ví dụ trong issue #25', () => {
    const template = findTemplateById('CUP_BLANK')!;
    const sku = buildSku(template, {
      CUP_STYLE: 'HRT',
      MATERIAL: 'PET',
      CAPACITY: '500',
      COLOR: 'CLR',
    });
    expect(sku).toBe('CUP-HRT-PET-500-CLR');
  });

  it('sinh đúng MAT-SYR-PEACH-750ML theo ví dụ trong issue #25', () => {
    const template = findTemplateById('MATERIAL_SYRUP')!;
    const sku = buildSku(template, { FLAVOR: 'PEACH', SPEC: '750ML' });
    expect(sku).toBe('MAT-SYR-PEACH-750ML');
  });

  it('sinh đúng PKG-STR-12MM-230MM-BLK theo ví dụ trong issue #25', () => {
    const template = findTemplateById('PACKAGING_STRAW')!;
    const sku = buildSku(template, {
      DIAMETER: '12MM',
      LENGTH: '230MM',
      COLOR: 'BLK',
    });
    expect(sku).toBe('PKG-STR-12MM-230MM-BLK');
  });

  it('luôn theo đúng order của template, bất kể order key trong object truyền vào', () => {
    const template = findTemplateById('MATERIAL_SYRUP')!;
    const sku = buildSku(template, { SPEC: '750ML', FLAVOR: 'PEACH' });
    expect(sku).toBe('MAT-SYR-PEACH-750ML');
  });

  it('throw nếu thiếu code cho 1 field bắt buộc', () => {
    const template = findTemplateById('MATERIAL_SYRUP')!;
    expect(() => buildSku(template, { FLAVOR: 'PEACH' })).toThrow();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest apps/wms/src/stock/sku/sku-builder.spec.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the builder**

```ts
// apps/wms/src/stock/sku/sku-builder.ts
import { SkuTemplate } from './sku-template.registry';

/**
 * Ghép prefix + code của từng field THEO ĐÚNG THỨ TỰ template.fields — cố ý
 * không dựa vào thứ tự key trong object đầu vào (JS object key order không
 * phải hợp đồng ổn định, và request từ client có thể gửi field theo bất kỳ
 * thứ tự nào — issue #25 checklist: "SKU builder đúng order, không phụ thuộc
 * order key request").
 */
export function buildSku(
  template: SkuTemplate,
  codesByKey: Record<string, string>,
): string {
  const parts = [template.prefix];
  for (const field of template.fields) {
    const code = codesByKey[field.key];
    if (!code) {
      throw new Error(`Thiếu code cho field ${field.key} của template ${template.templateId}`);
    }
    parts.push(code);
  }
  return parts.join('-');
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest apps/wms/src/stock/sku/sku-builder.spec.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/sku/sku-builder.ts apps/wms/src/stock/sku/sku-builder.spec.ts
git commit -m "feat(wms): add pure SKU builder joining template prefix + option codes"
```

---

### Task 7: `SkuTemplateService` — resolves template incl. category branching, validates options, builds SKU

**Files:**
- Create: `apps/wms/src/stock/sku/sku-template.service.ts`
- Test: `apps/wms/src/stock/sku/sku-template.service.spec.ts`

**Interfaces:**
- Consumes: `SKU_TEMPLATES`, `findRootTemplates`, `findTemplateById`, `CATEGORY_CODE_KEY`, `SkuTemplate` (Task 5); `buildSku` (Task 6); `AttributeOptionRepository` (Task 3, injected); `AppException` from `@app/common`; `ItemType` from `../schemas/warehouse-item.schema`; `AttributeOptionKey` from `../schemas/attribute-option.schema`.
- Produces:
  - `SkuTemplateService` injectable with:
    - `getRootOrCategoryOptions(itemType: ItemType, categoryOptionId?: string): Promise<SkuTemplateLookupResult>` — for `CUP_BLANK` returns `{ kind: 'template', template }` directly; for `MATERIAL`/`PACKAGING` with no `categoryOptionId` returns `{ kind: 'category-options', options: ItemAttributeOptionDocument[] }` (active options for the category key); with `categoryOptionId` given, loads that option, matches `option.code` to a template's `category`, returns `{ kind: 'template', template }` (throws `STOCK_SKU_TEMPLATE_NOT_FOUND` if no template matches that category code).
    - `resolveAndBuildSku(templateId: string, itemType: ItemType, attributeOptionIds: string[]): Promise<{ sku: string; attributeSnapshot: AttributeSnapshotEntry[] }>` — loads the template by id, throws `STOCK_SKU_TEMPLATE_NOT_FOUND` if missing, throws `STOCK_SKU_TEMPLATE_MISMATCH` if `template.itemType !== itemType`; loads all `attributeOptionIds` via `AttributeOptionRepository.findByIds`, throws `STOCK_ATTRIBUTE_OPTION_NOT_FOUND` if any id didn't resolve, throws `STOCK_ATTRIBUTE_OPTION_INACTIVE` if any resolved option has `isActive === false`; builds a `codesByKey` map from the resolved options (keyed by `option.key`), throws `STOCK_ATTRIBUTE_OPTION_NOT_FOUND` if a template field's key isn't covered by any given option (via `buildSku` catching and re-throwing as `AppException`); calls `buildSku`; returns the SKU plus a snapshot array `{ key, optionId, name, value, code }[]` (one entry per template field, in template order) for persisting into `WarehouseItem.attributes`.
  - `interface AttributeSnapshotEntry { key: AttributeOptionKey; optionId: string; name: string; value: string; code: string }` (`name`/`value` both hold the option's display name — matches existing `ItemAttribute.name`/`.value` duplication, kept for backward-compat with the pre-existing sub-schema shape per `data-and-mongoose.md`'s "giữ name/value/code").

- [ ] **Step 1: Write the failing tests**

```ts
// apps/wms/src/stock/sku/sku-template.service.spec.ts
import { SkuTemplateService } from './sku-template.service';
import { ItemType } from '../schemas/warehouse-item.schema';
import { AttributeOptionKey } from '../schemas/attribute-option.schema';

const makeOptionRepo = () => ({
  findByIds: jest.fn(),
});

describe('SkuTemplateService', () => {
  let svc: SkuTemplateService;
  let optionRepo: ReturnType<typeof makeOptionRepo>;

  beforeEach(() => {
    optionRepo = makeOptionRepo();
    svc = new SkuTemplateService(optionRepo as never);
  });

  describe('getRootOrCategoryOptions', () => {
    it('CUP_BLANK trả template ngay, không cần category', async () => {
      const result = await svc.getRootOrCategoryOptions(ItemType.CUP_BLANK);
      expect(result.kind).toBe('template');
      if (result.kind === 'template') {
        expect(result.template.templateId).toBe('CUP_BLANK');
      }
    });

    it('MATERIAL không truyền categoryOptionId → trả kind=category-options', async () => {
      const result = await svc.getRootOrCategoryOptions(ItemType.MATERIAL);
      expect(result.kind).toBe('category-options');
    });

    it('MATERIAL + categoryOptionId khớp option code=SYRUP → trả template MATERIAL_SYRUP', async () => {
      optionRepo.findByIds.mockResolvedValue([
        {
          _id: 'opt1',
          key: AttributeOptionKey.MATERIAL_CATEGORY,
          code: 'SYRUP',
          isActive: true,
        },
      ]);
      const result = await svc.getRootOrCategoryOptions(
        ItemType.MATERIAL,
        'opt1',
      );
      expect(result.kind).toBe('template');
      if (result.kind === 'template') {
        expect(result.template.templateId).toBe('MATERIAL_SYRUP');
      }
    });

    it('categoryOptionId không khớp option nào → STOCK_ATTRIBUTE_OPTION_NOT_FOUND', async () => {
      optionRepo.findByIds.mockResolvedValue([]);
      await expect(
        svc.getRootOrCategoryOptions(ItemType.MATERIAL, 'bad-id'),
      ).rejects.toMatchObject({ code: 'STOCK_ATTRIBUTE_OPTION_NOT_FOUND' });
    });
  });

  describe('resolveAndBuildSku', () => {
    const activeOptions = [
      {
        _id: 'opt-flavor',
        key: AttributeOptionKey.FLAVOR,
        code: 'PEACH',
        name: 'Đào',
        isActive: true,
      },
      {
        _id: 'opt-spec',
        key: AttributeOptionKey.SPEC,
        code: '750ML',
        name: '750ml',
        isActive: true,
      },
    ];

    it('sinh đúng SKU MAT-SYR-PEACH-750ML + snapshot đúng field order', async () => {
      optionRepo.findByIds.mockResolvedValue(activeOptions);

      const result = await svc.resolveAndBuildSku(
        'MATERIAL_SYRUP',
        ItemType.MATERIAL,
        ['opt-flavor', 'opt-spec'],
      );

      expect(result.sku).toBe('MAT-SYR-PEACH-750ML');
      expect(result.attributeSnapshot.map((s) => s.key)).toEqual([
        'FLAVOR',
        'SPEC',
      ]);
    });

    it('throw STOCK_SKU_TEMPLATE_NOT_FOUND nếu templateId không tồn tại', async () => {
      await expect(
        svc.resolveAndBuildSku('NOPE', ItemType.MATERIAL, []),
      ).rejects.toMatchObject({ code: 'STOCK_SKU_TEMPLATE_NOT_FOUND' });
    });

    it('throw STOCK_SKU_TEMPLATE_MISMATCH nếu template.itemType khác itemType truyền vào', async () => {
      await expect(
        svc.resolveAndBuildSku('MATERIAL_SYRUP', ItemType.PACKAGING, []),
      ).rejects.toMatchObject({ code: 'STOCK_SKU_TEMPLATE_MISMATCH' });
    });

    it('throw STOCK_ATTRIBUTE_OPTION_NOT_FOUND nếu thiếu option cho 1 field', async () => {
      optionRepo.findByIds.mockResolvedValue([activeOptions[0]]);
      await expect(
        svc.resolveAndBuildSku('MATERIAL_SYRUP', ItemType.MATERIAL, [
          'opt-flavor',
        ]),
      ).rejects.toMatchObject({ code: 'STOCK_ATTRIBUTE_OPTION_NOT_FOUND' });
    });

    it('throw STOCK_ATTRIBUTE_OPTION_INACTIVE nếu option bị deactivate', async () => {
      optionRepo.findByIds.mockResolvedValue([
        { ...activeOptions[0], isActive: false },
        activeOptions[1],
      ]);
      await expect(
        svc.resolveAndBuildSku('MATERIAL_SYRUP', ItemType.MATERIAL, [
          'opt-flavor',
          'opt-spec',
        ]),
      ).rejects.toMatchObject({ code: 'STOCK_ATTRIBUTE_OPTION_INACTIVE' });
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest apps/wms/src/stock/sku/sku-template.service.spec.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the service**

```ts
// apps/wms/src/stock/sku/sku-template.service.ts
import { Injectable } from '@nestjs/common';
import { AppException } from '@app/common';
import { AttributeOptionRepository } from '../attribute-option/attribute-option.repository';
import { AttributeOptionKey } from '../schemas/attribute-option.schema';
import { ItemType } from '../schemas/warehouse-item.schema';
import { buildSku } from './sku-builder';
import {
  CATEGORY_CODE_KEY,
  SkuTemplate,
  findRootTemplates,
  findTemplateById,
} from './sku-template.registry';

export interface AttributeSnapshotEntry {
  key: AttributeOptionKey;
  optionId: string;
  name: string;
  value: string;
  code: string;
}

export type SkuTemplateLookupResult =
  | { kind: 'template'; template: SkuTemplate }
  | {
      kind: 'category-options';
      categoryKey: AttributeOptionKey;
    };

@Injectable()
export class SkuTemplateService {
  constructor(private readonly optionRepo: AttributeOptionRepository) {}

  /**
   * CUP_BLANK không phân nhóm → trả template ngay. MATERIAL/PACKAGING cần
   * chọn category trước: không truyền categoryOptionId → FE phải tự GET
   * /attribute-options?key=<categoryKey> (client tự query, service chỉ báo
   * categoryKey cần dùng — tránh trộn 2 trách nhiệm khác nhau vào 1 response).
   */
  async getRootOrCategoryOptions(
    itemType: ItemType,
    categoryOptionId?: string,
  ): Promise<SkuTemplateLookupResult> {
    const categoryKey = CATEGORY_CODE_KEY[itemType];
    if (!categoryKey) {
      const [template] = findRootTemplates(itemType);
      if (!template) throw new AppException('STOCK_SKU_TEMPLATE_NOT_FOUND');
      return { kind: 'template', template };
    }

    if (!categoryOptionId) {
      return { kind: 'category-options', categoryKey };
    }

    const [option] = await this.optionRepo.findByIds([categoryOptionId]);
    if (!option) throw new AppException('STOCK_ATTRIBUTE_OPTION_NOT_FOUND');

    const template = findRootTemplates(itemType).find(
      (t) => t.category === option.code,
    );
    if (!template) throw new AppException('STOCK_SKU_TEMPLATE_NOT_FOUND');
    return { kind: 'template', template };
  }

  /**
   * Nguồn sự thật duy nhất để sinh SKU cuối — BE KHÔNG tin sku/preview từ FE
   * (issue #25: "BE resolve lại template/type/category, load option và trả
   * SKU/barcode cuối cùng"). Luôn load lại option từ DB (không nhận code sẵn
   * từ client) để chặn option đã bị deactivate/đổi giữa lúc preview và lúc submit.
   */
  async resolveAndBuildSku(
    templateId: string,
    itemType: ItemType,
    attributeOptionIds: string[],
  ): Promise<{ sku: string; attributeSnapshot: AttributeSnapshotEntry[] }> {
    const template = findTemplateById(templateId);
    if (!template) throw new AppException('STOCK_SKU_TEMPLATE_NOT_FOUND');
    if (template.itemType !== itemType) {
      throw new AppException('STOCK_SKU_TEMPLATE_MISMATCH');
    }

    const options = await this.optionRepo.findByIds(attributeOptionIds);
    const byKey = new Map(options.map((o) => [o.key, o]));

    const codesByKey: Record<string, string> = {};
    const attributeSnapshot: AttributeSnapshotEntry[] = [];

    for (const field of template.fields) {
      const option = byKey.get(field.key);
      if (!option) throw new AppException('STOCK_ATTRIBUTE_OPTION_NOT_FOUND');
      if (!option.isActive) {
        throw new AppException('STOCK_ATTRIBUTE_OPTION_INACTIVE');
      }
      codesByKey[field.key] = option.code;
      attributeSnapshot.push({
        key: field.key,
        optionId: option._id.toString(),
        name: option.name,
        value: option.name,
        code: option.code,
      });
    }

    const sku = buildSku(template, codesByKey);
    return { sku, attributeSnapshot };
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest apps/wms/src/stock/sku/sku-template.service.spec.ts`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/sku/sku-template.service.ts apps/wms/src/stock/sku/sku-template.service.spec.ts
git commit -m "feat(wms): add SkuTemplateService resolving category branching + building final SKU"
```

---

### Task 8: EAN-13 checksum/generation pure function

**Files:**
- Create: `apps/wms/src/stock/barcode/ean13.ts`
- Test: `apps/wms/src/stock/barcode/ean13.spec.ts`

**Interfaces:**
- Produces: `computeEan13CheckDigit(first12Digits: string): number`, `buildEan13(prefix: string, sequence: number): string` (prefix `'20'` + 10-digit zero-padded sequence + checksum = 13 chars total; throws if `prefix.length + String(sequence).length > 12` i.e. sequence overflowed 10 digits).

- [ ] **Step 1: Write the failing test**

```ts
// apps/wms/src/stock/barcode/ean13.spec.ts
import { buildEan13, computeEan13CheckDigit } from './ean13';

describe('computeEan13CheckDigit', () => {
  it('tính đúng checksum cho barcode EAN-13 chuẩn đã biết', () => {
    // 690123456789 → check digit đúng là 2 (kiểm chứng lại bằng thuật toán EAN-13 chuẩn)
    expect(computeEan13CheckDigit('690123456789')).toBe(2);
  });

  it('tính đúng checksum cho 12 số toàn 0', () => {
    expect(computeEan13CheckDigit('000000000000')).toBe(0);
  });
});

describe('buildEan13', () => {
  it('ghép prefix 20 + sequence 10 số (zero-pad) + checksum = đủ 13 ký tự', () => {
    const code = buildEan13('20', 42);
    expect(code).toHaveLength(13);
    expect(code.startsWith('200000000042')).toBe(true);
  });

  it('2 sequence khác nhau → 2 mã khác nhau', () => {
    const a = buildEan13('20', 1);
    const b = buildEan13('20', 2);
    expect(a).not.toBe(b);
  });

  it('throw nếu sequence vượt quá 10 chữ số', () => {
    expect(() => buildEan13('20', 12345678901)).toThrow();
  });

  it('checksum trong mã sinh ra khớp với computeEan13CheckDigit', () => {
    const code = buildEan13('20', 999);
    const first12 = code.slice(0, 12);
    const checkDigit = Number(code[12]);
    expect(checkDigit).toBe(computeEan13CheckDigit(first12));
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest apps/wms/src/stock/barcode/ean13.spec.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the implementation**

```ts
// apps/wms/src/stock/barcode/ean13.ts

/**
 * Thuật toán checksum chuẩn EAN-13: từ vị trí 1 (trái→phải, 1-indexed) trên
 * 12 số đầu, vị trí lẻ ×1, vị trí chẵn ×3, tổng rồi lấy (10 - tổng mod 10) mod 10.
 */
export function computeEan13CheckDigit(first12Digits: string): number {
  const digits = first12Digits.split('').map(Number);
  const sum = digits.reduce((acc, d, idx) => {
    const weight = idx % 2 === 0 ? 1 : 3;
    return acc + d * weight;
  }, 0);
  return (10 - (sum % 10)) % 10;
}

/**
 * prefix nội bộ '20' (issue #25) + sequence atomic 10 chữ số (từ barcode_counters,
 * xem barcode.repository.ts) + 1 checksum = 13 ký tự. Sequence do BarcodeService
 * cấp — hàm này chỉ lắp ráp + tính checksum, không tự sinh số.
 */
export function buildEan13(prefix: string, sequence: number): string {
  const sequenceDigits = 12 - prefix.length;
  const sequenceStr = String(sequence);
  if (sequenceStr.length > sequenceDigits) {
    throw new Error(
      `sequence ${sequence} vượt quá ${sequenceDigits} chữ số cho phép (prefix=${prefix})`,
    );
  }
  const first12 = prefix + sequenceStr.padStart(sequenceDigits, '0');
  const checkDigit = computeEan13CheckDigit(first12);
  return first12 + String(checkDigit);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx jest apps/wms/src/stock/barcode/ean13.spec.ts`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/stock/barcode/ean13.ts apps/wms/src/stock/barcode/ean13.spec.ts
git commit -m "feat(wms): add pure EAN-13 checksum/build functions"
```

---

### Task 9: `BarcodeCounter` + `BarcodeRegistryEntry` schemas

**Files:**
- Create: `apps/wms/src/stock/schemas/barcode-counter.schema.ts`
- Create: `apps/wms/src/stock/schemas/barcode-registry.schema.ts`

**Interfaces:**
- Produces: `BarcodeCounter { prefix: string (unique), seq: number }`, `BarcodeCounterDocument`, `BarcodeCounterSchema`. `BarcodeRegistryEntry { code: string (unique), itemId: ObjectId, kind: BarcodeKind }`, `BarcodeKind` enum (`PRIMARY`/`ALTERNATE`), `BarcodeRegistryEntryDocument`, `BarcodeRegistryEntrySchema`.

- [ ] **Step 1: Write the schemas**

```ts
// apps/wms/src/stock/schemas/barcode-counter.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument } from 'mongoose';

/**
 * Sequence atomic theo prefix (chỉ '20' hiện tại) — cấp qua findOneAndUpdate
 * $inc trong transaction cùng lúc tạo item (barcode.repository.ts), không
 * dùng timestamps vì đây là bộ đếm thuần, chỉ cần biết lần cập nhật gần nhất.
 */
@Schema({ collection: 'barcode_counters', timestamps: { updatedAt: true, createdAt: false } })
export class BarcodeCounter {
  @Prop({ required: true, unique: true })
  prefix!: string;

  @Prop({ required: true, default: 0 })
  seq!: number;
}

export type BarcodeCounterDocument = HydratedDocument<BarcodeCounter>;
export const BarcodeCounterSchema = SchemaFactory.createForClass(BarcodeCounter);
```

```ts
// apps/wms/src/stock/schemas/barcode-registry.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

export enum BarcodeKind {
  PRIMARY = 'PRIMARY',
  ALTERNATE = 'ALTERNATE',
}

/**
 * 1 mã (barcode chính hoặc altBarcode) → đúng 1 item, bất kể PRIMARY/ALTERNATE
 * (issue #25: "Registry chặn primary-primary, primary-alternate,
 * alternate-alternate"). unique index trên `code` một mình đã đảm bảo điều
 * này — không cần compound với kind. Sổ cái thuần, không soft-delete: gỡ 1 mã
 * (vd sửa altBarcodes) là xóa document, không đánh dấu deletedAt.
 */
@Schema({ collection: 'barcode_registry', timestamps: { createdAt: true, updatedAt: false } })
export class BarcodeRegistryEntry {
  @Prop({ required: true, unique: true })
  code!: string;

  @Prop({ type: Types.ObjectId, required: true })
  itemId!: Types.ObjectId;

  @Prop({ enum: BarcodeKind, required: true })
  kind!: BarcodeKind;
}

export type BarcodeRegistryEntryDocument = HydratedDocument<BarcodeRegistryEntry>;
export const BarcodeRegistryEntrySchema = SchemaFactory.createForClass(BarcodeRegistryEntry);

BarcodeRegistryEntrySchema.index({ itemId: 1 });
```

- [ ] **Step 2: Verify it compiles**

Run: `npx tsc --noEmit -p apps/wms/tsconfig.app.json 2>&1 | grep barcode- || echo "no errors"`
Expected: `no errors`.

- [ ] **Step 3: Commit**

```bash
git add apps/wms/src/stock/schemas/barcode-counter.schema.ts apps/wms/src/stock/schemas/barcode-registry.schema.ts
git commit -m "feat(wms): add BarcodeCounter and BarcodeRegistryEntry schemas"
```

---

### Task 10: `BarcodeRepository` + `BarcodeService` — atomic sequence, unique generation, registry lookups

**Files:**
- Create: `apps/wms/src/stock/barcode/barcode.repository.ts`
- Create: `apps/wms/src/stock/barcode/barcode.service.ts`
- Test: `apps/wms/src/stock/barcode/barcode.service.spec.ts`

**Interfaces:**
- Consumes: `BarcodeCounter`, `BarcodeRegistryEntry`, `BarcodeKind` (Task 9); `buildEan13` (Task 8); `AppException` from `@app/common`; `ClientSession`, `Types` from `mongoose`.
- Produces:
  - `BarcodeRepository`:
    - `nextSequence(prefix: string, session: ClientSession): Promise<number>` — `findOneAndUpdate({ prefix }, { $inc: { seq: 1 } }, { upsert: true, new: true, session })`, returns `doc.seq`.
    - `insertRegistryEntry(code: string, itemId: Types.ObjectId, kind: BarcodeKind, session: ClientSession): Promise<void>` — plain `create([{...}], { session })`; lets Mongo's unique index throw a raw `MongoServerError` (11000) on collision — **not caught here**, caller (`BarcodeService`) catches it.
    - `findByCode(code: string): Promise<{ itemId: Types.ObjectId } | null>` — `findOne({ code }).lean()`.
    - `deleteByCode(code: string, session?: ClientSession): Promise<void>`.
  - `BarcodeService`:
    - `generateUniqueBarcode(session: ClientSession): Promise<string>` — loops: get next sequence, build EAN-13, try `insertRegistryEntry` as `PRIMARY` with a placeholder — **actually**, registry entry needs the real `itemId` which isn't known until the item document is created. So this method only **reserves the code** (inserts registry row with a caller-supplied `itemId`) — see corrected signature below.
    - `generateAndReservePrimaryBarcode(itemId: Types.ObjectId, session: ClientSession): Promise<string>` — gets next sequence via `nextSequence('20', session)`, builds EAN-13 via `buildEan13('20', seq)`, calls `insertRegistryEntry(code, itemId, BarcodeKind.PRIMARY, session)`; on a caught Mongo 11000 error (duplicate `code` — astronomically unlikely given atomic sequence, but the issue's checklist explicitly demands defensive handling), retries `nextSequence` up to 3 times before throwing `AppException('STOCK_ITEM_BARCODE_CONFLICT')`.
    - `findItemIdByCode(code: string): Promise<Types.ObjectId | null>` — delegates to `findByCode`, returns `.itemId` or `null`. This is the new `findItemByBarcode` replacement.
    - `isMongoDuplicateKeyError(err: unknown): boolean` — exported helper checking `(err as { code?: number }).code === 11000`, reused by Task 11 for the SKU 11000→409 mapping.

- [ ] **Step 1: Write the failing tests**

```ts
// apps/wms/src/stock/barcode/barcode.service.spec.ts
import { Types } from 'mongoose';
import { BarcodeService, isMongoDuplicateKeyError } from './barcode.service';
import { BarcodeKind } from '../schemas/barcode-registry.schema';

const makeRepo = () => ({
  nextSequence: jest.fn(),
  insertRegistryEntry: jest.fn(),
  findByCode: jest.fn(),
  deleteByCode: jest.fn(),
});

const fakeSession = {} as never;

describe('isMongoDuplicateKeyError', () => {
  it('nhận diện đúng lỗi Mongo 11000', () => {
    expect(isMongoDuplicateKeyError({ code: 11000 })).toBe(true);
    expect(isMongoDuplicateKeyError({ code: 12345 })).toBe(false);
    expect(isMongoDuplicateKeyError(new Error('other'))).toBe(false);
  });
});

describe('BarcodeService', () => {
  let svc: BarcodeService;
  let repo: ReturnType<typeof makeRepo>;
  const itemId = new Types.ObjectId();

  beforeEach(() => {
    repo = makeRepo();
    svc = new BarcodeService(repo as never);
  });

  describe('generateAndReservePrimaryBarcode', () => {
    it('sinh EAN-13 hợp lệ (13 ký tự, prefix 20) và ghi registry PRIMARY', async () => {
      repo.nextSequence.mockResolvedValue(1);
      repo.insertRegistryEntry.mockResolvedValue(undefined);

      const code = await svc.generateAndReservePrimaryBarcode(itemId, fakeSession);

      expect(code).toHaveLength(13);
      expect(code.startsWith('20')).toBe(true);
      expect(repo.insertRegistryEntry).toHaveBeenCalledWith(
        code,
        itemId,
        BarcodeKind.PRIMARY,
        fakeSession,
      );
    });

    it('2 lần gọi liên tiếp (sequence khác nhau) → 2 mã khác nhau', async () => {
      repo.nextSequence.mockResolvedValueOnce(1).mockResolvedValueOnce(2);
      repo.insertRegistryEntry.mockResolvedValue(undefined);

      const a = await svc.generateAndReservePrimaryBarcode(itemId, fakeSession);
      const b = await svc.generateAndReservePrimaryBarcode(itemId, fakeSession);

      expect(a).not.toBe(b);
    });

    it('retry khi gặp 11000 (race hiếm), thành công ở lần thử lại', async () => {
      repo.nextSequence.mockResolvedValueOnce(1).mockResolvedValueOnce(2);
      repo.insertRegistryEntry
        .mockRejectedValueOnce({ code: 11000 })
        .mockResolvedValueOnce(undefined);

      const code = await svc.generateAndReservePrimaryBarcode(itemId, fakeSession);

      expect(code).toHaveLength(13);
      expect(repo.nextSequence).toHaveBeenCalledTimes(2);
    });

    it('throw STOCK_ITEM_BARCODE_CONFLICT sau 3 lần retry 11000 liên tiếp', async () => {
      repo.nextSequence.mockResolvedValue(1);
      repo.insertRegistryEntry.mockRejectedValue({ code: 11000 });

      await expect(
        svc.generateAndReservePrimaryBarcode(itemId, fakeSession),
      ).rejects.toMatchObject({ code: 'STOCK_ITEM_BARCODE_CONFLICT' });
    });

    it('lỗi khác 11000 → ném thẳng ra, không nuốt lỗi', async () => {
      repo.nextSequence.mockResolvedValue(1);
      const boom = new Error('mongo down');
      repo.insertRegistryEntry.mockRejectedValue(boom);

      await expect(
        svc.generateAndReservePrimaryBarcode(itemId, fakeSession),
      ).rejects.toBe(boom);
    });
  });

  describe('findItemIdByCode', () => {
    it('trả itemId khi tìm thấy', async () => {
      repo.findByCode.mockResolvedValue({ itemId });
      const result = await svc.findItemIdByCode('2000000000015');
      expect(result).toEqual(itemId);
    });

    it('trả null khi không tìm thấy', async () => {
      repo.findByCode.mockResolvedValue(null);
      const result = await svc.findItemIdByCode('nope');
      expect(result).toBeNull();
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest apps/wms/src/stock/barcode/barcode.service.spec.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the repository**

```ts
// apps/wms/src/stock/barcode/barcode.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { ClientSession, Model, Types } from 'mongoose';
import { BarcodeCounter } from '../schemas/barcode-counter.schema';
import {
  BarcodeKind,
  BarcodeRegistryEntry,
} from '../schemas/barcode-registry.schema';

@Injectable()
export class BarcodeRepository {
  constructor(
    @InjectModel(BarcodeCounter.name)
    private readonly counterModel: Model<BarcodeCounter>,
    @InjectModel(BarcodeRegistryEntry.name)
    private readonly registryModel: Model<BarcodeRegistryEntry>,
  ) {}

  /** $inc atomic — an toàn dưới concurrent request nhờ Mongo single-document atomicity. */
  async nextSequence(prefix: string, session: ClientSession): Promise<number> {
    const doc = await this.counterModel.findOneAndUpdate(
      { prefix },
      { $inc: { seq: 1 } },
      { upsert: true, new: true, session },
    );
    return doc.seq;
  }

  /** Không catch lỗi 11000 ở đây — để caller (BarcodeService) quyết định retry hay map lỗi. */
  async insertRegistryEntry(
    code: string,
    itemId: Types.ObjectId,
    kind: BarcodeKind,
    session: ClientSession,
  ): Promise<void> {
    await this.registryModel.create([{ code, itemId, kind }], { session });
  }

  findByCode(code: string): Promise<{ itemId: Types.ObjectId } | null> {
    return this.registryModel.findOne({ code }).lean().exec();
  }

  async deleteByCode(code: string, session?: ClientSession): Promise<void> {
    await this.registryModel.deleteOne({ code }, { session }).exec();
  }
}
```

- [ ] **Step 4: Write the service**

```ts
// apps/wms/src/stock/barcode/barcode.service.ts
import { Injectable } from '@nestjs/common';
import { AppException } from '@app/common';
import { ClientSession, Types } from 'mongoose';
import { BarcodeRepository } from './barcode.repository';
import { buildEan13 } from './ean13';
import { BarcodeKind } from '../schemas/barcode-registry.schema';

const PRIMARY_PREFIX = '20';
const MAX_RETRIES = 3;

export function isMongoDuplicateKeyError(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code?: unknown }).code === 11000
  );
}

@Injectable()
export class BarcodeService {
  constructor(private readonly repo: BarcodeRepository) {}

  /**
   * Sequence từ barcode_counters gần như không bao giờ trùng (atomic $inc),
   * nhưng vẫn retry khi gặp 11000 thay vì throw ngay — phòng trường hợp registry
   * đã có sẵn 1 code trùng do dữ liệu backfill cũ (xem backfill-barcode-registry.ts),
   * đúng yêu cầu issue #25: "Hai request khác SKU nhận hai EAN-13 khác nhau".
   */
  async generateAndReservePrimaryBarcode(
    itemId: Types.ObjectId,
    session: ClientSession,
  ): Promise<string> {
    let lastError: unknown;
    for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
      const seq = await this.repo.nextSequence(PRIMARY_PREFIX, session);
      const code = buildEan13(PRIMARY_PREFIX, seq);
      try {
        await this.repo.insertRegistryEntry(
          code,
          itemId,
          BarcodeKind.PRIMARY,
          session,
        );
        return code;
      } catch (err) {
        if (!isMongoDuplicateKeyError(err)) throw err;
        lastError = err;
      }
    }
    throw new AppException('STOCK_ITEM_BARCODE_CONFLICT');
    // lastError giữ lại cho debugging nếu cần log thêm sau này — không throw trực
    // tiếp lastError vì AppException là chuẩn lỗi FE switch-case của toàn hệ thống.
    void lastError;
  }

  async findItemIdByCode(code: string): Promise<Types.ObjectId | null> {
    const entry = await this.repo.findByCode(code);
    return entry?.itemId ?? null;
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx jest apps/wms/src/stock/barcode/barcode.service.spec.ts`
Expected: PASS (9 tests).

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/stock/barcode/barcode.repository.ts apps/wms/src/stock/barcode/barcode.service.ts apps/wms/src/stock/barcode/barcode.service.spec.ts
git commit -m "feat(wms): add BarcodeRepository/Service — atomic sequence, unique registry, 11000 retry"
```

---

### Task 11: Rewrite `WarehouseItem` schema + `StockRepository.createItem`/`findItemBySku` for sessions

**Files:**
- Modify: `apps/wms/src/stock/schemas/warehouse-item.schema.ts`
- Modify: `apps/wms/src/stock/stock.repository.ts`
- Modify: `apps/wms/src/stock/stock.repository.spec.ts`

**Interfaces:**
- Consumes: `AttributeSnapshotEntry` shape from Task 7 (structurally, not imported — schema stays framework-agnostic of `sku/` module).
- Produces:
  - `ItemAttribute` gains `key: string` (required) and `optionId: Types.ObjectId` (required) fields, alongside existing `name`/`value`/`code`.
  - `WarehouseItem` gains `category?: string` (the matched template's `category` string, e.g. `'SYRUP'`; `undefined` for `CUP_BLANK`).
  - `StockRepository.createItem(data, createdBy, session?: ClientSession): Promise<WarehouseItemDocument>` — session now optional 3rd param, passed to `this.itemModel.create([...], { session })`.
  - `StockRepository.findItemBySku(sku, session?: ClientSession)` — session passed to `.session(session)` when provided (needed so the in-transaction conflict pre-check sees uncommitted writes from the same transaction, though the actual conflict-closing mechanism is the unique index + 11000 catch in Task 12, not this pre-check).
  - `CreateWarehouseItemData` type gains `category?: string` and `attributes` entries gain `key`/`optionId`.

- [ ] **Step 1: Write the failing test (repository session-passthrough)**

Read the existing `stock.repository.spec.ts` first to match its exact mocking style:

Run: `sed -n '1,40p' apps/wms/src/stock/stock.repository.spec.ts`

Then append (matching whatever `describe('StockRepository', ...)` structure already exists — the exact insertion point depends on that file's current layout, so read it fully before editing):

```ts
describe('createItem — session passthrough', () => {
  it('truyền session vào Model.create khi có session', async () => {
    const session = {} as never;
    const createSpy = jest
      .spyOn(repo['itemModel'], 'create')
      .mockResolvedValue([{ _id: 'x' }] as never);

    await repo.createItem(
      {
        sku: 'SKU-1',
        name: 'Test',
        type: 'CUP_BLANK' as never,
        unit: 'cái',
      },
      new Types.ObjectId(),
      session,
    );

    expect(createSpy).toHaveBeenCalledWith(
      [expect.objectContaining({ sku: 'SKU-1' })],
      { session },
    );
  });
});
```

(Adjust `repo['itemModel']` access to whatever the file's existing model-mocking convention is — inspect the top of `stock.repository.spec.ts` for how `itemModel` is constructed/injected before finalizing this step; if the file uses a fully mocked model object rather than a real Mongoose model, spy on that mock directly instead of using `jest.spyOn`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest apps/wms/src/stock/stock.repository.spec.ts -t "session passthrough"`
Expected: FAIL — `createItem` doesn't accept/forward a 3rd `session` argument yet.

- [ ] **Step 3: Update the schema**

In `apps/wms/src/stock/schemas/warehouse-item.schema.ts`, modify the `ItemAttribute` sub-schema (around line 24-36):

```ts
/** Sub-document: thuộc tính thêm (màu, kích thước…) — snapshot từ ItemAttributeOption tại thời điểm tạo item. */
@Schema({ _id: false })
class ItemAttribute {
  /** Nhóm thuộc tính (vd 'COLOR') — khớp AttributeOptionKey, giữ dạng string ở đây để schema WarehouseItem không phụ thuộc trực tiếp enum của attribute-option module. */
  @Prop({ required: true })
  key!: string;

  @Prop({ type: Types.ObjectId, required: true })
  optionId!: Types.ObjectId;

  @Prop({ required: true })
  name!: string;

  @Prop({ required: true })
  value!: string;

  /** Mã định danh thuộc tính — dùng khi map với hệ thống ngoài hoặc filter theo loại */
  @Prop({ required: true })
  code!: string;
}
const ItemAttributeSchema = SchemaFactory.createForClass(ItemAttribute);
```

Add `category` to the `WarehouseItem` class, right after the `type` field (around line 57-58):

```ts
  @Prop({ enum: ItemType, required: true })
  type!: ItemType;

  /** Nhóm con trong itemType (vd 'SYRUP' cho MATERIAL) — null cho CUP_BLANK (không phân nhóm). Khớp SkuTemplate.category. */
  @Prop()
  category?: string;
```

- [ ] **Step 4: Update `CreateWarehouseItemData` and `createItem`/`findItemBySku` in the repository**

In `apps/wms/src/stock/stock.repository.ts`, update the `import` line to include `ClientSession` (already imported per Task-1 research — confirm it's already there) and update `CreateWarehouseItemData`:

```ts
export type CreateWarehouseItemData = {
  /** Cho phép caller cấp sẵn _id — StockService.createWarehouseItem (Task 12) cần
   * biết itemId TRƯỚC khi document tồn tại, để BarcodeService ghi registry entry
   * trỏ đúng item trong cùng transaction (xem stock.service.ts). Optional vì
   * print-job's internal creation path (print-job.service.ts) không cần cấp trước. */
  _id?: Types.ObjectId;
  sku: string;
  barcode?: string;
  altBarcodes?: string[];
  name: string;
  type: ItemType;
  category?: string;
  unit: string;
  altUnits?: { unit: string; factor: number }[];
  attributes?: {
    key: string;
    optionId: Types.ObjectId;
    name: string;
    value: string;
    code: string;
  }[];
  isPerishable?: boolean;
  nearExpiryDays?: number;
  minQuantity?: number;
  depth?: number;
  width?: number;
  height?: number;
  blankItemId?: Types.ObjectId;
};
```

Replace `findItemBySku` and `createItem`:

```ts
  /** Tra WarehouseItem theo sku — dùng khi tạo mới để chặn trùng sku (kể cả đã soft-delete). */
  findItemBySku(sku: string, session?: ClientSession) {
    const query = this.itemModel.findOne({ sku }).lean();
    if (session) query.session(session);
    return query.exec();
  }

  /** Tạo mới WarehouseItem (master data). isActive mặc định true. session bắt buộc
   * truyền khi tạo trong luồng sinh SKU/barcode (issue #25 — "Create item + registry
   * trong cùng Mongo transaction"); optional để không phá vỡ print-job's internal
   * creation path (chưa cần transaction, xem print-job.service.ts). */
  async createItem(
    data: CreateWarehouseItemData,
    createdBy: Types.ObjectId,
    session?: ClientSession,
  ): Promise<WarehouseItemDocument> {
    const [doc] = await this.itemModel.create(
      [{ ...data, createdBy, isActive: true }],
      { session },
    );
    return doc;
  }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx jest apps/wms/src/stock/stock.repository.spec.ts`
Expected: PASS (all existing tests + new session-passthrough test).

- [ ] **Step 6: Run the full stock test suite to catch any break from the schema change**

Run: `npx jest apps/wms/src/stock --silent 2>&1 | tail -40`
Expected: All pass. `print-job.service.spec.ts` (if it asserts on the exact object passed to `createItem`) may need its expected-call assertions checked — if it fails due to the new optional `session` param being `undefined` in the expected call, that's a pre-existing test needing a one-line update (add `undefined` as 3rd arg in the `toHaveBeenCalledWith` assertion, or use `expect.anything()` — inspect the actual failure before deciding).

- [ ] **Step 7: Commit**

```bash
git add apps/wms/src/stock/schemas/warehouse-item.schema.ts apps/wms/src/stock/stock.repository.ts apps/wms/src/stock/stock.repository.spec.ts
git commit -m "feat(wms): extend WarehouseItem schema (category, attribute key/optionId), add session param to createItem"
```

---

### Task 12: Rewrite `StockService.createWarehouseItem` — transactional SKU + barcode generation, reject client sku/barcode/CUP_PRINTED

**Files:**
- Modify: `apps/wms/src/stock/stock.service.ts`
- Modify: `apps/wms/src/stock/stock.service.spec.ts`
- Modify: `apps/wms/src/stock/dto/create-warehouse-item.dto.ts`
- Modify: `apps/wms/src/stock/dto/warehouse-item.response.dto.ts`
- Modify: `apps/wms/src/stock/stock.controller.ts`
- Modify: `apps/wms/src/stock/stock.module.ts`

**Interfaces:**
- Consumes: `SkuTemplateService.resolveAndBuildSku` (Task 7), `BarcodeService.generateAndReservePrimaryBarcode` (Task 10), `StockTransactionHelper.withStockTransaction` (existing), `StockRepository.createItem(data, createdBy, session)` / `findItemBySku(sku, session)` (Task 11), `isMongoDuplicateKeyError` (Task 10).
- Produces: `StockService.createWarehouseItem(dto: CreatePublicWarehouseItemDto, actorId: string): Promise<WarehouseItemDocument>` — new signature (breaking change to the public create-item contract, intentional per issue). `CreatePublicWarehouseItemDto` (new DTO name, replaces old `CreateWarehouseItemDto` for the 3 public types) with fields `{ type: ItemType.CUP_BLANK | MATERIAL | PACKAGING; templateId: string; attributeOptionIds: string[]; name: string; unit: string; altUnits?; isPerishable?; nearExpiryDays?; minQuantity?; depth?; width?; height? }` — **no `sku`, `barcode`, `altBarcodes`, `attributes` fields** (those 4 are now 100% BE-derived).

- [ ] **Step 1: Write the failing tests**

Read the current `stock.service.spec.ts` in full first (already read during planning — 39 existing lines shown, file likely continues past what was read). Replace the `describe('createWarehouseItem', ...)` block entirely with:

```ts
// apps/wms/src/stock/stock.service.spec.ts
import { Types } from 'mongoose';
import { EVENTS } from '@app/events';
import { StockService } from './stock.service';
import { ItemType } from './schemas/warehouse-item.schema';

const makeRepo = () => ({
  findSkuById: jest.fn(),
  findItemBySku: jest.fn(),
  createItem: jest.fn(),
  findItems: jest.fn(),
  findItemByIdDocument: jest.fn(),
  updateItem: jest.fn(),
  softDeleteItem: jest.fn(),
  findSkuAndMinQuantityById: jest.fn(),
  findBalanceByItemAndWarehouse: jest.fn(),
});

const makeQueue = () => ({ add: jest.fn() });

const makeSkuTemplateService = () => ({
  resolveAndBuildSku: jest.fn(),
});

const makeBarcodeService = () => ({
  generateAndReservePrimaryBarcode: jest.fn(),
});

const makeTransactionHelper = () => ({
  withStockTransaction: jest.fn((fn: (session: unknown) => unknown) =>
    fn({} as never),
  ),
});

describe('StockService', () => {
  let svc: StockService;
  let repo: ReturnType<typeof makeRepo>;
  let queue: ReturnType<typeof makeQueue>;
  let notificationQueue: ReturnType<typeof makeQueue>;
  let skuTemplateSvc: ReturnType<typeof makeSkuTemplateService>;
  let barcodeSvc: ReturnType<typeof makeBarcodeService>;
  let txHelper: ReturnType<typeof makeTransactionHelper>;

  beforeEach(() => {
    repo = makeRepo();
    queue = makeQueue();
    notificationQueue = makeQueue();
    skuTemplateSvc = makeSkuTemplateService();
    barcodeSvc = makeBarcodeService();
    txHelper = makeTransactionHelper();
    svc = new StockService(
      repo as never,
      queue as never,
      notificationQueue as never,
      skuTemplateSvc as never,
      barcodeSvc as never,
      txHelper as never,
    );
  });

  describe('createWarehouseItem', () => {
    const actorId = new Types.ObjectId().toString();
    const dto = {
      type: ItemType.MATERIAL,
      templateId: 'MATERIAL_SYRUP',
      attributeOptionIds: ['opt-flavor', 'opt-spec'],
      name: 'Syrup đào',
      unit: 'chai',
    };

    it('reject CUP_PRINTED — không cho tạo thủ công qua API public', async () => {
      await expect(
        svc.createWarehouseItem(
          { ...dto, type: ItemType.CUP_PRINTED } as never,
          actorId,
        ),
      ).rejects.toMatchObject({ code: 'STOCK_SKU_TEMPLATE_MISMATCH' });
      expect(skuTemplateSvc.resolveAndBuildSku).not.toHaveBeenCalled();
    });

    it('resolve SKU qua SkuTemplateService, sinh barcode, tạo item trong transaction', async () => {
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
      const createdDoc = { _id: new Types.ObjectId(), sku: 'MAT-SYR-PEACH-750ML' };
      repo.createItem.mockResolvedValue(createdDoc);

      const result = await svc.createWarehouseItem(dto as never, actorId);

      expect(skuTemplateSvc.resolveAndBuildSku).toHaveBeenCalledWith(
        'MATERIAL_SYRUP',
        ItemType.MATERIAL,
        ['opt-flavor', 'opt-spec'],
      );
      expect(repo.createItem).toHaveBeenCalledWith(
        expect.objectContaining({
          sku: 'MAT-SYR-PEACH-750ML',
          barcode: '2000000000015',
        }),
        new Types.ObjectId(actorId),
        expect.anything(),
      );
      expect(result).toBe(createdDoc);
    });

    it('map lỗi 11000 trên sku (race hiếm) thành STOCK_ITEM_SKU_CONFLICT, không throw 500 thô', async () => {
      skuTemplateSvc.resolveAndBuildSku.mockResolvedValue({
        sku: 'MAT-SYR-PEACH-750ML',
        attributeSnapshot: [],
      });
      barcodeSvc.generateAndReservePrimaryBarcode.mockResolvedValue(
        '2000000000015',
      );
      repo.createItem.mockRejectedValue({
        code: 11000,
        keyPattern: { sku: 1 },
      });

      await expect(
        svc.createWarehouseItem(dto as never, actorId),
      ).rejects.toMatchObject({ code: 'STOCK_ITEM_SKU_CONFLICT' });
    });

    it('lỗi 11000 khác field sku (fallback) vẫn map về STOCK_ITEM_SKU_CONFLICT nếu không nhận diện được keyPattern', async () => {
      skuTemplateSvc.resolveAndBuildSku.mockResolvedValue({
        sku: 'MAT-SYR-PEACH-750ML',
        attributeSnapshot: [],
      });
      barcodeSvc.generateAndReservePrimaryBarcode.mockResolvedValue(
        '2000000000015',
      );
      repo.createItem.mockRejectedValue({ code: 11000, keyPattern: {} });

      await expect(
        svc.createWarehouseItem(dto as never, actorId),
      ).rejects.toMatchObject({ code: 'STOCK_ITEM_SKU_CONFLICT' });
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx jest apps/wms/src/stock/stock.service.spec.ts`
Expected: FAIL — `StockService` constructor doesn't accept the new deps, `createWarehouseItem` signature mismatch.

- [ ] **Step 3: Rewrite `create-warehouse-item.dto.ts`**

Replace the file's `CreateWarehouseItemDto`/`UpdateWarehouseItemDto` section (keep `AltUnitDto`, drop `ItemAttributeDto` — attributes are no longer client input for the 3 public types):

```ts
// apps/wms/src/stock/dto/create-warehouse-item.dto.ts
import {
  ApiProperty,
  ApiPropertyOptional,
  OmitType,
  PartialType,
} from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  ArrayMinSize,
  IsArray,
  IsBoolean,
  IsIn,
  IsInt,
  IsMongoId,
  IsNumber,
  IsOptional,
  IsString,
  Min,
  MinLength,
  ValidateNested,
} from 'class-validator';
import { ItemType } from '../schemas/warehouse-item.schema';

export class AltUnitDto {
  @ApiProperty({ example: 'thùng' })
  @IsString()
  @MinLength(1)
  unit!: string;

  @ApiProperty({
    example: 24,
    description: '1 altUnit = factor * đơn vị cơ sở',
  })
  @IsInt()
  @Min(1)
  factor!: number;
}

/**
 * SKU/barcode/attributes KHÔNG nhận từ client (issue #25) — BE tự resolve
 * template + option rồi sinh. type chỉ nhận 3 giá trị public (CUP_PRINTED bị
 * chặn ở service, không khai trong @IsIn để Swagger không gợi ý sai).
 */
export class CreateWarehouseItemDto {
  @ApiProperty({
    enum: [ItemType.CUP_BLANK, ItemType.MATERIAL, ItemType.PACKAGING],
    example: ItemType.CUP_BLANK,
  })
  @IsIn([ItemType.CUP_BLANK, ItemType.MATERIAL, ItemType.PACKAGING])
  type!: ItemType.CUP_BLANK | ItemType.MATERIAL | ItemType.PACKAGING;

  @ApiProperty({ example: 'CUP_BLANK', description: 'Lấy từ GET /stock/item-types/:type/sku-template' })
  @IsString()
  @MinLength(1)
  templateId!: string;

  @ApiProperty({ type: [String], example: ['66a1...', '66a2...'] })
  @IsArray()
  @ArrayMinSize(1)
  @IsMongoId({ each: true })
  attributeOptionIds!: string[];

  @ApiProperty({ example: 'Ly nhựa 500ml' })
  @IsString()
  @MinLength(1)
  name!: string;

  @ApiProperty({ example: 'cái' })
  @IsString()
  @MinLength(1)
  unit!: string;

  @ApiPropertyOptional({ type: [AltUnitDto] })
  @IsOptional()
  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => AltUnitDto)
  altUnits?: AltUnitDto[];

  @ApiPropertyOptional({ example: false })
  @IsOptional()
  @IsBoolean()
  isPerishable?: boolean;

  @ApiPropertyOptional({ example: 7 })
  @IsOptional()
  @IsInt()
  @Min(0)
  nearExpiryDays?: number;

  @ApiPropertyOptional({
    example: 10,
    description: 'Ngưỡng tối thiểu — available dưới ngưỡng này thì phát cảnh báo stock.low',
  })
  @IsOptional()
  @IsInt()
  @Min(0)
  minQuantity?: number;

  @ApiPropertyOptional({ example: 10, description: 'Chiều sâu 1 đơn vị cơ sở (cm)' })
  @IsOptional()
  @IsNumber()
  @Min(0)
  depth?: number;

  @ApiPropertyOptional({ example: 8, description: 'Chiều rộng 1 đơn vị cơ sở (cm)' })
  @IsOptional()
  @IsNumber()
  @Min(0)
  width?: number;

  @ApiPropertyOptional({ example: 12, description: 'Chiều cao 1 đơn vị cơ sở (cm)' })
  @IsOptional()
  @IsNumber()
  @Min(0)
  height?: number;
}

export class UpdateWarehouseItemDto extends PartialType(
  OmitType(CreateWarehouseItemDto, [
    'type',
    'templateId',
    'attributeOptionIds',
  ] as const),
) {}
```

Note: `UpdateWarehouseItemDto` no longer touches `sku`/`type`/`templateId`/`attributeOptionIds` — matches existing controller summary "không sửa sku" and extends the same immutability to type/template/options (re-deriving SKU on update is out of scope, matches issue's non-goal "Bulk variant matrix" adjacency and keeps update semantics unchanged from today).

- [ ] **Step 4: Update `warehouse-item.response.dto.ts`**

Add `category` and update `ItemAttributeResponseDto` to include `key`/`optionId`:

```ts
export class ItemAttributeResponseDto {
  @Expose()
  @ApiProperty()
  key!: string;

  @Expose()
  @Transform(({ obj }: { obj: { optionId?: Types.ObjectId } }) =>
    obj.optionId?.toString(),
  )
  @ApiProperty()
  optionId!: string;

  @Expose()
  @ApiProperty()
  name!: string;

  @Expose()
  @ApiProperty()
  value!: string;

  @Expose()
  @ApiProperty()
  code!: string;
}
```

And in `WarehouseItemResponseDto`, add after `type`:

```ts
  @Expose()
  @ApiPropertyOptional()
  category?: string;
```

- [ ] **Step 5: Rewrite `StockService`**

```ts
// apps/wms/src/stock/stock.service.ts
import { InjectQueue } from '@nestjs/bullmq';
import { Injectable, Logger } from '@nestjs/common';
import {
  EVENTS,
  QUEUES,
  type StockChangedPayload,
  type StockLowPayload,
} from '@app/events';
import { AppException } from '@app/common';
import { Queue } from 'bullmq';
import { Types } from 'mongoose';
import { StockRepository } from './stock.repository';
import type { CreateWarehouseItemData } from './stock.repository';
import type { WarehouseItemDocument } from './schemas/warehouse-item.schema';
import { ItemType } from './schemas/warehouse-item.schema';
import type { QueryWarehouseItemDto } from './dto/query-warehouse-item.dto';
import type {
  CreateWarehouseItemDto,
  UpdateWarehouseItemDto,
} from './dto/create-warehouse-item.dto';
import { SkuTemplateService } from './sku/sku-template.service';
import { BarcodeService, isMongoDuplicateKeyError } from './barcode/barcode.service';
import { StockTransactionHelper } from './helpers/with-stock-transaction.helper';

@Injectable()
export class StockService {
  private readonly logger = new Logger(StockService.name);

  constructor(
    private readonly stockRepo: StockRepository,
    @InjectQueue(QUEUES.STOCK) private readonly stockQueue: Queue,
    @InjectQueue(QUEUES.NOTIFICATION)
    private readonly notificationQueue: Queue,
    private readonly skuTemplateSvc: SkuTemplateService,
    private readonly barcodeSvc: BarcodeService,
    private readonly txHelper: StockTransactionHelper,
  ) {}

  async emitStockChanged(
    sku: string,
    delta: number,
    refType: string,
    refId: Types.ObjectId | string,
  ): Promise<void> {
    const payload: StockChangedPayload = { sku, delta };
    const jobId = `${refType}:${refId.toString()}:${sku}`;
    await this.stockQueue.add(EVENTS.STOCK_CHANGED, payload, { jobId });
    this.logger.log(`stock.changed → sku=${sku} delta=${delta} jobId=${jobId}`);
  }

  async publishAvailableForItem(
    itemId: string,
    delta: number,
    refType: string,
    refId: Types.ObjectId | string,
  ): Promise<void> {
    const item = await this.stockRepo.findSkuById(itemId);
    if (!item) return;
    await this.emitStockChanged(item.sku, delta, refType, refId);
  }

  async checkAndEmitStockLow(
    itemId: Types.ObjectId,
    warehouseId: Types.ObjectId,
  ): Promise<void> {
    const item = await this.stockRepo.findSkuAndMinQuantityById(itemId);
    if (!item || item.minQuantity == null) return;

    const balance = await this.stockRepo.findBalanceByItemAndWarehouse(
      itemId,
      warehouseId,
    );
    if (!balance) return;

    const available = balance.onHand - balance.reserved - balance.expired;
    if (available >= item.minQuantity) return;

    const payload: StockLowPayload = {
      sku: item.sku,
      warehouseId: warehouseId.toString(),
      available,
      minQuantity: item.minQuantity,
    };
    await this.notificationQueue.add(EVENTS.STOCK_LOW, payload);
    this.logger.log(
      `stock.low → sku=${item.sku} warehouseId=${warehouseId.toString()} available=${available} minQuantity=${item.minQuantity}`,
    );
  }

  /**
   * Tạo WarehouseItem CUP_BLANK/MATERIAL/PACKAGING — sku/barcode/attributes
   * hoàn toàn do BE tự resolve, KHÔNG tin bất kỳ giá trị nào từ client ngoài
   * templateId + attributeOptionIds (issue #25). CUP_PRINTED bị chặn ở đây —
   * chỉ tạo được qua PrintJobService.resolveOutputItem (đường nội bộ, xem
   * print-job.service.ts, không đổi trong scope issue này).
   *
   * Create item + đặt barcode registry trong CÙNG 1 Mongo transaction — nếu
   * 1 trong 2 fail thì rollback cả 2 (issue #25: "Create item + registry trong
   * cùng Mongo transaction"). Lỗi 11000 trên unique index sku bị bắt và map
   * sang STOCK_ITEM_SKU_CONFLICT (409) thay vì để lộ raw MongoServerError
   * (checklist: "không trả 500 khi race").
   */
  async createWarehouseItem(
    dto: CreateWarehouseItemDto,
    actorId: string,
  ): Promise<WarehouseItemDocument> {
    if (dto.type === ItemType.CUP_PRINTED) {
      throw new AppException('STOCK_SKU_TEMPLATE_MISMATCH');
    }

    const { sku, attributeSnapshot } = await this.skuTemplateSvc.resolveAndBuildSku(
      dto.templateId,
      dto.type,
      dto.attributeOptionIds,
    );

    try {
      return await this.txHelper.withStockTransaction(async (session) => {
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
  }

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
}
```

**Design note:** `itemId = new Types.ObjectId()` is pre-generated so `generateAndReservePrimaryBarcode` can write the registry row pointing at the item's future `_id` before the item document itself exists — both writes land inside the same transaction, so there's never a moment where the registry references a non-existent item. `CreateWarehouseItemData._id` (Task 11) carries this id through to `stockRepo.createItem`, and Mongoose's `Model.create` accepts a client-supplied `_id` natively.

- [ ] **Step 6: Update `stock.controller.ts`**

The `create` method body stays the same shape (`svc.createWarehouseItem(dto, actorId)`) since only the DTO's internal fields changed, not the method signature at the controller boundary. Update the Swagger summary to reflect the new contract:

```ts
  @Post()
  @Roles(WmsRole.ADMIN, WmsRole.MANAGER)
  @ApiOperation({
    summary:
      'Tạo mặt hàng kho mới (CUP_BLANK/MATERIAL/PACKAGING) — BE tự sinh sku/barcode từ template — [ADMIN, MANAGER]',
  })
  @ApiCreatedResponse({ type: WarehouseItemResponseDto })
  async create(
    @Body() dto: CreateWarehouseItemDto,
    @CurrentUser('sub') actorId: string,
  ): Promise<WarehouseItemResponseDto> {
    const doc = await this.svc.createWarehouseItem(dto, actorId);
    return plainToInstance(WarehouseItemResponseDto, doc.toObject(), TO_OPTS);
  }
```

- [ ] **Step 7: Wire new providers/schemas into `stock.module.ts`**

```ts
// apps/wms/src/stock/stock.module.ts
import { BullModule } from '@nestjs/bullmq';
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { QUEUES } from '@app/events';
import {
  InventoryStock,
  InventoryStockSchema,
} from './schemas/inventory-stock.schema';
import { Lot, LotSchema } from './schemas/lot.schema';
import {
  StockBalance,
  StockBalanceSchema,
} from './schemas/stock-balance.schema';
import {
  StockMovement,
  StockMovementSchema,
} from './schemas/stock-movement.schema';
import {
  WarehouseItem,
  WarehouseItemSchema,
} from './schemas/warehouse-item.schema';
import {
  ItemAttributeOption,
  ItemAttributeOptionSchema,
} from './schemas/attribute-option.schema';
import {
  BarcodeCounter,
  BarcodeCounterSchema,
} from './schemas/barcode-counter.schema';
import {
  BarcodeRegistryEntry,
  BarcodeRegistryEntrySchema,
} from './schemas/barcode-registry.schema';
import { ExpiredLotScanService } from './expired-lot-scan.service';
import { StockTransactionHelper } from './helpers/with-stock-transaction.helper';
import { NearExpiryScanService } from './near-expiry-scan.service';
import { StockController } from './stock.controller';
import { StockRepository } from './stock.repository';
import { StockService } from './stock.service';
import { AttributeOptionController } from './attribute-option/attribute-option.controller';
import { AttributeOptionRepository } from './attribute-option/attribute-option.repository';
import { AttributeOptionService } from './attribute-option/attribute-option.service';
import { SkuTemplateController } from './sku/sku-template.controller';
import { SkuTemplateService } from './sku/sku-template.service';
import { BarcodeRepository } from './barcode/barcode.repository';
import { BarcodeService } from './barcode/barcode.service';

@Module({
  imports: [
    BullModule.registerQueue(
      { name: QUEUES.STOCK },
      { name: QUEUES.NOTIFICATION },
    ),
    MongooseModule.forFeature([
      { name: WarehouseItem.name, schema: WarehouseItemSchema },
      { name: StockBalance.name, schema: StockBalanceSchema },
      { name: InventoryStock.name, schema: InventoryStockSchema },
      { name: Lot.name, schema: LotSchema },
      { name: StockMovement.name, schema: StockMovementSchema },
      { name: ItemAttributeOption.name, schema: ItemAttributeOptionSchema },
      { name: BarcodeCounter.name, schema: BarcodeCounterSchema },
      { name: BarcodeRegistryEntry.name, schema: BarcodeRegistryEntrySchema },
    ]),
  ],
  controllers: [StockController, AttributeOptionController, SkuTemplateController],
  providers: [
    StockRepository,
    StockService,
    StockTransactionHelper,
    NearExpiryScanService,
    ExpiredLotScanService,
    AttributeOptionRepository,
    AttributeOptionService,
    SkuTemplateService,
    BarcodeRepository,
    BarcodeService,
  ],
  exports: [
    StockService,
    StockTransactionHelper,
    StockRepository,
    BarcodeService,
  ],
})
export class StockModule {}
```

(`SkuTemplateController` is created in Task 13 — this step references it ahead of time; if executing tasks strictly in order, comment out that import/registration until Task 13 lands, or execute Task 13 immediately after this step before running the build.)

- [ ] **Step 8: Run test to verify it passes**

Run: `npx jest apps/wms/src/stock/stock.service.spec.ts apps/wms/src/stock/stock.repository.spec.ts`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add apps/wms/src/stock/stock.service.ts apps/wms/src/stock/stock.service.spec.ts apps/wms/src/stock/stock.controller.ts apps/wms/src/stock/stock.module.ts apps/wms/src/stock/dto/create-warehouse-item.dto.ts apps/wms/src/stock/dto/warehouse-item.response.dto.ts apps/wms/src/stock/stock.repository.ts
git commit -m "feat(wms): rewrite createWarehouseItem — transactional SKU+barcode generation, reject CUP_PRINTED, map 11000 to 409"
```

---

### Task 13: `sku-template` + `sku-preview` public endpoints

**Files:**
- Create: `apps/wms/src/stock/sku/sku-template.controller.ts`
- Create: `apps/wms/src/stock/dto/sku-template.response.dto.ts`
- Create: `apps/wms/src/stock/dto/sku-preview.dto.ts`

**Interfaces:**
- Consumes: `SkuTemplateService.getRootOrCategoryOptions` (Task 7), `AttributeOptionService.list` (Task 3), `SkuTemplateService.resolveAndBuildSku` — reused for preview (Task 7).
- Produces:
  - `GET /stock/item-types/:type/sku-template?categoryOptionId=<id>` → `SkuTemplateOrCategoryResponseDto` (either `{ kind: 'template', templateId, type, prefix, category, fields }` or `{ kind: 'category-options', categoryKey, options: AttributeOptionResponseDto[] }`).
  - `POST /stock/items/sku-preview` body `{ type, templateId, attributeOptionIds }` → `SkuPreviewResponseDto { sku: string }` — read-only preview, does **not** reserve a barcode or touch the counter (only calls `resolveAndBuildSku`, never `BarcodeService`).

- [ ] **Step 1: Write the response DTOs**

```ts
// apps/wms/src/stock/dto/sku-template.response.dto.ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Expose, Type } from 'class-transformer';
import { AttributeOptionResponseDto } from '../attribute-option/dto/attribute-option.dto';

export class SkuTemplateFieldResponseDto {
  @Expose()
  @ApiProperty()
  key!: string;
}

export class SkuTemplateResponseDto {
  @Expose()
  @ApiProperty({ example: 'template' })
  kind!: 'template';

  @Expose()
  @ApiProperty()
  templateId!: string;

  @Expose()
  @ApiProperty()
  itemType!: string;

  @Expose()
  @ApiPropertyOptional()
  category?: string | null;

  @Expose()
  @ApiProperty()
  prefix!: string;

  @Expose()
  @Type(() => SkuTemplateFieldResponseDto)
  @ApiProperty({ type: [SkuTemplateFieldResponseDto] })
  fields!: SkuTemplateFieldResponseDto[];
}

export class SkuCategoryOptionsResponseDto {
  @Expose()
  @ApiProperty({ example: 'category-options' })
  kind!: 'category-options';

  @Expose()
  @ApiProperty()
  categoryKey!: string;

  @Expose()
  @Type(() => AttributeOptionResponseDto)
  @ApiProperty({ type: [AttributeOptionResponseDto] })
  options!: AttributeOptionResponseDto[];
}
```

```ts
// apps/wms/src/stock/dto/sku-preview.dto.ts
import { ApiProperty } from '@nestjs/swagger';
import { Expose } from 'class-transformer';
import { ArrayMinSize, IsArray, IsIn, IsMongoId, IsString, MinLength } from 'class-validator';
import { ItemType } from '../schemas/warehouse-item.schema';

export class SkuPreviewDto {
  @ApiProperty({
    enum: [ItemType.CUP_BLANK, ItemType.MATERIAL, ItemType.PACKAGING],
  })
  @IsIn([ItemType.CUP_BLANK, ItemType.MATERIAL, ItemType.PACKAGING])
  type!: ItemType.CUP_BLANK | ItemType.MATERIAL | ItemType.PACKAGING;

  @ApiProperty({ example: 'MATERIAL_SYRUP' })
  @IsString()
  @MinLength(1)
  templateId!: string;

  @ApiProperty({ type: [String] })
  @IsArray()
  @ArrayMinSize(1)
  @IsMongoId({ each: true })
  attributeOptionIds!: string[];
}

export class SkuPreviewResponseDto {
  @Expose()
  @ApiProperty({ example: 'MAT-SYR-PEACH-750ML' })
  sku!: string;
}
```

- [ ] **Step 2: Write the controller**

```ts
// apps/wms/src/stock/sku/sku-template.controller.ts
import { Body, Controller, Get, Param, Post, Query, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOkResponse, ApiOperation, ApiTags } from '@nestjs/swagger';
import { JwtAuthGuard, Roles, RolesGuard, WmsRole } from '@app/auth';
import { plainToInstance } from 'class-transformer';
import { SkuTemplateService } from './sku-template.service';
import { AttributeOptionService } from '../attribute-option/attribute-option.service';
import { ItemType } from '../schemas/warehouse-item.schema';
import {
  SkuCategoryOptionsResponseDto,
  SkuTemplateResponseDto,
} from '../dto/sku-template.response.dto';
import { SkuPreviewDto, SkuPreviewResponseDto } from '../dto/sku-preview.dto';
import { AttributeOptionResponseDto } from '../attribute-option/dto/attribute-option.dto';

const TO_OPTS = { excludeExtraneousValues: true } as const;

const PUBLIC_ITEM_TYPES = [
  ItemType.CUP_BLANK,
  ItemType.MATERIAL,
  ItemType.PACKAGING,
] as const;

@ApiTags('stock-sku-template')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard, RolesGuard)
@Controller('stock')
export class SkuTemplateController {
  constructor(
    private readonly skuTemplateSvc: SkuTemplateService,
    private readonly optionSvc: AttributeOptionService,
  ) {}

  @Get('item-types/:type/sku-template')
  @Roles(WmsRole.ADMIN, WmsRole.MANAGER)
  @ApiOperation({
    summary:
      'Lấy template SKU (root hoặc category options nếu chưa chọn category) — [ADMIN, MANAGER]',
  })
  @ApiOkResponse({
    schema: {
      oneOf: [
        { $ref: '#/components/schemas/SkuTemplateResponseDto' },
        { $ref: '#/components/schemas/SkuCategoryOptionsResponseDto' },
      ],
    },
  })
  async getSkuTemplate(
    @Param('type') type: (typeof PUBLIC_ITEM_TYPES)[number],
    @Query('categoryOptionId') categoryOptionId?: string,
  ) {
    const result = await this.skuTemplateSvc.getRootOrCategoryOptions(
      type,
      categoryOptionId,
    );

    if (result.kind === 'template') {
      return plainToInstance(
        SkuTemplateResponseDto,
        {
          kind: 'template',
          templateId: result.template.templateId,
          itemType: result.template.itemType,
          category: result.template.category,
          prefix: result.template.prefix,
          fields: result.template.fields,
        },
        TO_OPTS,
      );
    }

    const options = await this.optionSvc.list(result.categoryKey, false);
    return plainToInstance(
      SkuCategoryOptionsResponseDto,
      {
        kind: 'category-options',
        categoryKey: result.categoryKey,
        options: plainToInstance(AttributeOptionResponseDto, options, TO_OPTS),
      },
      TO_OPTS,
    );
  }

  @Post('items/sku-preview')
  @Roles(WmsRole.ADMIN, WmsRole.MANAGER)
  @ApiOperation({
    summary:
      'Xem trước SKU (không tạo item, không cấp barcode) — [ADMIN, MANAGER]',
  })
  @ApiOkResponse({ type: SkuPreviewResponseDto })
  async previewSku(@Body() dto: SkuPreviewDto) {
    const { sku } = await this.skuTemplateSvc.resolveAndBuildSku(
      dto.templateId,
      dto.type,
      dto.attributeOptionIds,
    );
    return plainToInstance(SkuPreviewResponseDto, { sku }, TO_OPTS);
  }
}
```

- [ ] **Step 3: Verify it compiles standalone**

Run: `npx tsc --noEmit -p apps/wms/tsconfig.app.json 2>&1 | grep sku-template.controller || echo "no errors"`
Expected: `no errors`.

- [ ] **Step 4: Finish wiring `stock.module.ts` (uncomment/confirm `SkuTemplateController` registration from Task 12 Step 7)**

If Task 12 Step 7 was executed with the `SkuTemplateController` import commented out, uncomment it now.

- [ ] **Step 5: Full build to confirm the module wires correctly end-to-end**

Run: `npx nest build wms 2>&1 | tail -60`
Expected: `webpack compiled successfully`.

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/stock/sku/sku-template.controller.ts apps/wms/src/stock/dto/sku-template.response.dto.ts apps/wms/src/stock/dto/sku-preview.dto.ts apps/wms/src/stock/stock.module.ts
git commit -m "feat(wms): add GET sku-template and POST sku-preview endpoints"
```

---

### Task 14: Repoint `findItemByBarcode` to the registry (put-away/goods-issue/print-job scan resolution)

**Files:**
- Modify: `apps/wms/src/stock/stock.repository.ts` (remove `findItemByBarcode`, lines 135-141)
- Modify: `apps/wms/src/stock/stock.repository.spec.ts` (remove the `describe('findItemByBarcode', ...)` block, currently around line 295-310)
- Modify: `apps/wms/src/print-job/print-job.service.ts:252`
- Modify: `apps/wms/src/goods-issue/goods-issue.service.ts:133`
- Modify: `apps/wms/src/put-away/put-away.service.ts:74`
- Modify: `apps/wms/src/print-job/print-job.service.spec.ts` (mocks at lines 19, 355, 368, 382, 401, 418, 436, 489)
- Modify: `apps/wms/src/goods-issue/goods-issue.service.spec.ts` (mocks at lines 17, 202, 214, 227, 243, 261, 277, 294, 314, 370, 403)
- Modify: `apps/wms/src/put-away/put-away.service.spec.ts` (mocks at lines 13, 107, 122, 142, 159, 190, 210, 232, 251)
- Modify: `apps/wms/src/put-away/put-away.module.ts` (stale comment on line 16 referencing `findItemByBarcode`)

**Interfaces:**
- Consumes: `BarcodeService.findItemIdByCode` (Task 10), `StockRepository.findItemByIdDocument` (existing, unfiltered by `deletedAt` — matches `findItemByBarcode`'s current behavior of not filtering soft-deleted items).
- Produces: all 3 call sites replace `this.stockRepo.findItemByBarcode(dto.itemBarcode)` with a 2-step resolve: `this.barcodeSvc.findItemIdByCode(dto.itemBarcode)` → `this.stockRepo.findItemByIdDocument(itemId.toString())`. **Verified requirement**: `put-away.service.ts` reads `item.isPerishable` downstream (line 91 in the current file), so the resolved value must be the full hydrated document, not just an id — `findItemByIdDocument` satisfies this (it's already used elsewhere in `stock.controller.ts`/`stock.service.ts` and returns the full doc).

- [ ] **Step 1: Write/adjust the failing tests for all 3 affected services**

All 3 spec files mock `stockRepo.findItemByBarcode` directly (confirmed via grep — no other collaborator involved in these tests). For each of the 3 spec files, apply this mechanical transform:

1. In the `makeRepo()`/mock-repo factory at the top of the file, remove the `findItemByBarcode: jest.fn(),` line.
2. Add a new mock factory for the barcode service:
   ```ts
   const makeBarcodeService = () => ({
     findItemIdByCode: jest.fn(),
   });
   ```
3. In the `beforeEach`, construct it and pass it into the service constructor as the new injected dependency (exact constructor position depends on that service's current parameter order — read the service file's constructor before editing the test's instantiation call).
4. Replace every `stockRepo.findItemByBarcode.mockResolvedValue(X)` with two lines:
   ```ts
   barcodeSvc.findItemIdByCode.mockResolvedValue(X ? X._id : null);
   stockRepo.findItemByIdDocument.mockResolvedValue(X);
   ```
   (`stockRepo.findItemByIdDocument` mock already exists in `goods-issue.service.spec.ts`/`put-away.service.spec.ts`/`print-job.service.spec.ts` for other test paths in those same files — reuse it, don't add a duplicate mock key. Confirm via `grep -n "findItemByIdDocument" <file>` before editing; if it's missing from a given file's mock factory, add `findItemByIdDocument: jest.fn(),` alongside the other repo mocks.)

Apply this to all mock-call sites listed in the Files section above (7 in print-job, 10 in goods-issue, 8 in put-away).

- [ ] **Step 2: Run the affected tests to verify they fail**

Run: `npx jest apps/wms/src/put-away apps/wms/src/goods-issue apps/wms/src/print-job --silent 2>&1 | tail -60`
Expected: FAIL — services still call `stockRepo.findItemByBarcode` (removed from mock), or constructor arg count mismatch.

- [ ] **Step 3: Remove `findItemByBarcode` from `StockRepository` and its dedicated spec**

In `apps/wms/src/stock/stock.repository.ts`, delete lines 135-141 (the method and its preceding doc comment). In `apps/wms/src/stock/stock.repository.spec.ts`, delete the `describe('findItemByBarcode', ...)` block (~line 295-310).

Run: `grep -rn "findItemByBarcode" /home/hoaiphuong/code/wms-ecom/be/apps/wms/src --include="*.ts"`
Expected after this step: zero matches anywhere (confirms no caller missed).

- [ ] **Step 4: Update `print-job.service.ts:252`**

Change:
```ts
    const item = await this.stockRepo.findItemByBarcode(dto.itemBarcode);
    if (!item) throw new AppException('PRINT_JOB_ITEM_NOT_FOUND');
```
to:
```ts
    const itemId = await this.barcodeSvc.findItemIdByCode(dto.itemBarcode);
    if (!itemId) throw new AppException('PRINT_JOB_ITEM_NOT_FOUND');
    const item = await this.stockRepo.findItemByIdDocument(itemId.toString());
    if (!item) throw new AppException('PRINT_JOB_ITEM_NOT_FOUND');
```
Inject `BarcodeService` in the constructor (add `private readonly barcodeSvc: BarcodeService` alongside the existing `stockRepo`/other deps — read the current constructor first to match parameter ordering style) and import it from `../stock/barcode/barcode.service`.

- [ ] **Step 5: Update `goods-issue.service.ts:133`**

Same transform, using `GOODS_ISSUE_ITEM_NOT_FOUND`:
```ts
    const itemId = await this.barcodeSvc.findItemIdByCode(dto.itemBarcode);
    if (!itemId) throw new AppException('GOODS_ISSUE_ITEM_NOT_FOUND');
    const item = await this.stockRepo.findItemByIdDocument(itemId.toString());
    if (!item) throw new AppException('GOODS_ISSUE_ITEM_NOT_FOUND');
```
Inject `BarcodeService` in the constructor, same as Step 4.

- [ ] **Step 6: Update `put-away.service.ts:74`**

Same transform, using `PUTAWAY_ITEM_NOT_FOUND`:
```ts
    const itemId = await this.barcodeSvc.findItemIdByCode(dto.itemBarcode);
    if (!itemId) throw new AppException('PUTAWAY_ITEM_NOT_FOUND');
    const item = await this.stockRepo.findItemByIdDocument(itemId.toString());
    if (!item) throw new AppException('PUTAWAY_ITEM_NOT_FOUND');
```
Inject `BarcodeService` in the constructor, same as Step 4. The downstream `item.isPerishable` read (current line 91) needs no change — `findItemByIdDocument` returns the full document.

- [ ] **Step 7: Fix module wiring + stale comment**

`apps/wms/src/put-away/put-away.module.ts:16` has a comment `// StockRepository (findItemByBarcode/upsertInventory/insertMovement) + StockTransactionHelper` — update it to drop the now-removed method name:
```ts
    StockModule, // StockRepository (upsertInventory/insertMovement) + StockTransactionHelper + BarcodeService
```

Confirm `PutAwayModule`, `GoodsIssueModule`, `PrintJobModule` each already import `StockModule` (they must, since they already inject `StockRepository`/`StockTransactionHelper` today) — `BarcodeService` becomes available automatically once Task 12 Step 7 adds it to `StockModule`'s `exports` array, no new module import needed.

- [ ] **Step 8: Run the affected tests to verify they pass**

Run: `npx jest apps/wms/src/put-away apps/wms/src/goods-issue apps/wms/src/print-job apps/wms/src/stock --silent 2>&1 | tail -60`
Expected: PASS.

- [ ] **Step 9: Run the full WMS suite**

Run: `npx jest apps/wms --silent 2>&1 | tail -60`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add apps/wms/src/stock/stock.repository.ts apps/wms/src/stock/stock.repository.spec.ts apps/wms/src/put-away apps/wms/src/goods-issue apps/wms/src/print-job
git commit -m "feat(wms): repoint barcode scan resolution to barcode_registry, remove ambiguous \$or lookup"
```

---

### Task 15: Backfill dry-run script for legacy barcodes

**Files:**
- Create: `apps/wms/scripts/backfill-barcode-registry.ts`

**Interfaces:**
- Consumes: `WarehouseItem` model (raw Mongoose connection, not via NestJS DI — this is a standalone script per repo convention for one-off scripts — confirm there's a `scripts/` precedent via `ls apps/wms/scripts 2>/dev/null` first; if none exists, create the directory and check `apps/wms/src/seed/seed.ts` for the DB-connection bootstrap pattern to copy).
- Produces: a script invocable via `ts-node` (or `pnpm` script) that:
  1. Connects to `wms_db` using the same env var (`WMS_DATABASE_URL`) as the app.
  2. Scans every `WarehouseItem` with a non-null `barcode` and/or non-empty `altBarcodes`.
  3. Builds an in-memory map `code → itemId[]` across both `barcode` and `altBarcodes` fields combined.
  4. Reports every `code` mapped to more than 1 distinct `itemId` as a collision (console table: code, conflicting item ids + skus) — does **not** pick a winner (per issue: "báo toàn bộ collision và không tự chọn item thắng").
  5. For codes with exactly 1 owning item, inserts a `barcode_registry` entry (`kind = PRIMARY` if it matches `item.barcode`, `ALTERNATE` if it matches an `altBarcodes` entry) — this is the actual backfill; collisions are skipped entirely (left unregistered, reported for manual resolution).
  6. Runs in `--dry-run` mode by default (only prints the plan/report, writes nothing) unless invoked with `--apply`.

- [ ] **Step 1: Check for existing scripts precedent**

Run: `ls /home/hoaiphuong/code/wms-ecom/be/apps/wms/scripts 2>/dev/null; find /home/hoaiphuong/code/wms-ecom/be/apps/wms/src/seed -name "*.ts"`

Read `apps/wms/src/seed/seed.ts` in full to copy its exact DB-bootstrap pattern (how it reads `WMS_DATABASE_URL`, connects, and is invoked — likely a `pnpm` script entry in `package.json`).

- [ ] **Step 2: Write the script**

(Concrete connection boilerplate must mirror whatever `seed.ts` actually does — read it fully in Step 1 before finalizing this file. Below is the reporting/backfill logic assuming a raw `mongoose.connect(uri)` pattern; adjust the connection block to match `seed.ts` exactly.)

```ts
// apps/wms/scripts/backfill-barcode-registry.ts
import 'dotenv/config';
import mongoose from 'mongoose';
import { WarehouseItemSchema } from '../src/stock/schemas/warehouse-item.schema';
import { BarcodeRegistryEntrySchema } from '../src/stock/schemas/barcode-registry.schema';

const DRY_RUN = !process.argv.includes('--apply');

async function main() {
  const uri = process.env.WMS_DATABASE_URL;
  if (!uri) throw new Error('Thiếu WMS_DATABASE_URL trong env');
  await mongoose.connect(uri);

  const ItemModel = mongoose.model('WarehouseItem', WarehouseItemSchema, 'warehouse_items');
  const RegistryModel = mongoose.model(
    'BarcodeRegistryEntry',
    BarcodeRegistryEntrySchema,
    'barcode_registry',
  );

  const items = await ItemModel.find({}).lean();

  // code → danh sách item sở hữu mã đó (kể cả trùng barcode chính lẫn altBarcodes)
  const codeOwners = new Map<
    string,
    { itemId: string; sku: string; kind: 'PRIMARY' | 'ALTERNATE' }[]
  >();

  for (const item of items) {
    const itemId = String(item._id);
    if (item.barcode) {
      const list = codeOwners.get(item.barcode) ?? [];
      list.push({ itemId, sku: item.sku, kind: 'PRIMARY' });
      codeOwners.set(item.barcode, list);
    }
    for (const alt of item.altBarcodes ?? []) {
      const list = codeOwners.get(alt) ?? [];
      list.push({ itemId, sku: item.sku, kind: 'ALTERNATE' });
      codeOwners.set(alt, list);
    }
  }

  const collisions: { code: string; owners: typeof codeOwners extends Map<string, infer V> ? V : never }[] = [];
  const clean: { code: string; itemId: string; kind: 'PRIMARY' | 'ALTERNATE' }[] = [];

  for (const [code, owners] of codeOwners.entries()) {
    const distinctItemIds = new Set(owners.map((o) => o.itemId));
    if (distinctItemIds.size > 1) {
      collisions.push({ code, owners });
    } else {
      clean.push({ code, itemId: owners[0].itemId, kind: owners[0].kind });
    }
  }

  console.log(`Tổng số mã quét được: ${codeOwners.size}`);
  console.log(`Mã sạch (1 item sở hữu): ${clean.length}`);
  console.log(`Mã COLLISION (nhiều item cùng dùng 1 mã): ${collisions.length}`);

  if (collisions.length > 0) {
    console.log('\n⚠️  Danh sách collision — KHÔNG tự chọn item thắng, cần xử lý tay:');
    for (const c of collisions) {
      console.log(`  code=${c.code}`);
      for (const o of c.owners) {
        console.log(`    - itemId=${o.itemId} sku=${o.sku} kind=${o.kind}`);
      }
    }
  }

  if (DRY_RUN) {
    console.log('\n[DRY RUN] Không ghi gì vào barcode_registry. Chạy lại với --apply để ghi các mã sạch.');
  } else {
    console.log(`\nGhi ${clean.length} entry sạch vào barcode_registry...`);
    for (const entry of clean) {
      await RegistryModel.updateOne(
        { code: entry.code },
        { $setOnInsert: { code: entry.code, itemId: entry.itemId, kind: entry.kind } },
        { upsert: true },
      );
    }
    console.log('Xong.');
  }

  await mongoose.disconnect();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

- [ ] **Step 3: Add a `package.json` script entry**

Read the existing `scripts` section of `package.json` first (`grep -n '"scripts"' -A 20 package.json`), then add, matching whatever runner (`ts-node`, `tsx`) the `seed` script already uses:

```json
"backfill:barcode-registry": "ts-node -r tsconfig-paths/register apps/wms/scripts/backfill-barcode-registry.ts"
```

(Match the exact `ts-node`/`tsx` invocation style already used by the `seed` script in `package.json` — copy it verbatim, only swapping the file path.)

- [ ] **Step 4: Manual verification against a local/dev DB**

This script touches real data and is explicitly a one-off operational tool, not something with an automated Jest test (no `mongodb-memory-server` in this repo, and the issue doesn't require automated tests for the backfill step — only "Backfill dry-run barcode cũ, báo toàn bộ collision" as a manual acceptance criterion). Run manually against a dev/staging DB, never production, and only report results — do not run `--apply` without explicit user confirmation given it writes to the database.

Run (dry-run only, safe): `pnpm backfill:barcode-registry`
Expected: prints the collision/clean report; writes nothing.

- [ ] **Step 5: Commit**

```bash
git add apps/wms/scripts/backfill-barcode-registry.ts package.json
git commit -m "feat(wms): add barcode_registry backfill dry-run script for legacy barcode data"
```

---

### Task 16: Seed initial attribute options + fix `seed.ts`'s now-broken `createWarehouseItem` calls

**Files:**
- Modify: `apps/wms/src/seed/seed.ts`

**Interfaces:**
- Consumes: `AttributeOptionService.create` (Task 3), `AttributeOptionKey` (Task 2), `StockService.createWarehouseItem` new signature (Task 12 — `{ type, templateId, attributeOptionIds, name, unit, ... }`, no `sku`/`barcode`).
- Produces: `seed.ts` gains a `seedAttributeOptions(app)` step (idempotent, same check-then-create pattern as `seedUsers`) run before `seedWarehouseAndItems`, and both existing `stockService.createWarehouseItem(...)` calls are rewritten to the new contract.

**Why this task exists:** `apps/wms/src/seed/seed.ts:172-200` calls `stockService.createWarehouseItem({ sku: 'SEED-MAT-001', barcode: '...', ... })` and `{ sku: 'SEED-CUP-BLANK-001', ... }` directly. Task 12 removes `sku`/`barcode` from `CreateWarehouseItemDto` entirely and requires `templateId` + `attributeOptionIds` instead — without this task, `seed.ts` fails to compile/run after Task 12 lands, breaking demo/E2E setup (`docs/superpowers/plans/2026-07-18-s4-05-seed-e2e-demo.md` depends on this script staying runnable).

- [ ] **Step 1: Read the full current `seed.ts` imports and `seedWarehouseAndItems` signature**

Run: `sed -n '1,20p;114,205p' apps/wms/src/seed/seed.ts`

Confirm the exact `adminId` type and how `stockService`/other services are obtained (`app.get(...)`), to match style exactly.

- [ ] **Step 2: Add `seedAttributeOptions` — idempotent seed of the options needed for the 2 seeded items**

The two existing seeded items are `MATERIAL` (generic, will become an `MAT-*` template — pick `MATERIAL_TEA` template as an arbitrary valid choice since the seed item's exact flavor doesn't matter for demo data) and `CUP_BLANK`. Add this function to `seed.ts`, right after the `SEED_USERS` constant:

```ts
import { AttributeOptionKey } from '../stock/schemas/attribute-option.schema';
import { AttributeOptionService } from '../stock/attribute-option/attribute-option.service';

const SEED_ATTRIBUTE_OPTIONS: {
  key: AttributeOptionKey;
  name: string;
  code: string;
}[] = [
  { key: AttributeOptionKey.CUP_STYLE, name: 'Trái tim', code: 'HRT' },
  { key: AttributeOptionKey.MATERIAL, name: 'Nhựa PET', code: 'PET' },
  { key: AttributeOptionKey.CAPACITY, name: '500ml', code: '500' },
  { key: AttributeOptionKey.COLOR, name: 'Trong suốt', code: 'CLR' },
  { key: AttributeOptionKey.MATERIAL_TYPE, name: 'Trà đen', code: 'BLK' },
  { key: AttributeOptionKey.FLAVOR, name: 'Nguyên bản', code: 'ORG' },
  { key: AttributeOptionKey.SPEC, name: '500g', code: '500G' },
];

/**
 * Seed option thuộc tính tối thiểu để seedWarehouseAndItems build được SKU
 * qua template thật (issue #25) — không seed đủ 14 key, chỉ seed đúng những
 * option 2 item demo (MATERIAL_TEA, CUP_BLANK) cần. Idempotent qua unique
 * {key, code} — AttributeOptionService.create tự throw STOCK_ATTRIBUTE_CODE_CONFLICT
 * nếu đã tồn tại, bắt và bỏ qua (không phải lỗi seed, là trạng thái mong đợi
 * khi seed chạy lại).
 */
async function seedAttributeOptions(
  app: INestApplicationContext,
  adminId: string,
): Promise<Record<string, string>> {
  const optionSvc = app.get(AttributeOptionService);
  const codeToId: Record<string, string> = {};

  for (const opt of SEED_ATTRIBUTE_OPTIONS) {
    try {
      const created = await optionSvc.create(opt, adminId);
      codeToId[opt.code] = created._id.toString();
    } catch (err) {
      if ((err as { code?: string }).code !== 'STOCK_ATTRIBUTE_CODE_CONFLICT') {
        throw err;
      }
      const existing = await optionSvc.list(opt.key, true);
      const match = existing.find((o) => o.code === opt.code);
      if (match) codeToId[opt.code] = match._id.toString();
    }
  }

  return codeToId;
}
```

- [ ] **Step 3: Wire `seedAttributeOptions` into `seed()` and pass ids into `seedWarehouseAndItems`**

```ts
export async function seed(): Promise<void> {
  const app = await NestFactory.createApplicationContext(AppModule);
  try {
    const { adminId } = await seedUsers(app);
    const optionIds = await seedAttributeOptions(app, adminId);
    await seedWarehouseAndItems(app, adminId, optionIds);
    logger.log('Seed hoàn tất.');
  } finally {
    await app.close();
  }
}
```

Update `seedWarehouseAndItems`'s signature to accept `optionIds: Record<string, string>` as a 3rd parameter.

- [ ] **Step 4: Rewrite the two `createWarehouseItem` calls**

Replace lines 172-200 (per the version read in Step 1):

```ts
  const material = await stockService.createWarehouseItem(
    {
      type: ItemType.MATERIAL,
      templateId: 'MATERIAL_TEA',
      attributeOptionIds: [
        optionIds['BLK'], // MATERIAL_TYPE: Trà đen
        optionIds['ORG'], // FLAVOR: Nguyên bản
        optionIds['500G'], // SPEC: 500g
      ],
      name: 'Nguyên liệu seed',
      unit: 'kg',
      isPerishable: false,
      minQuantity: 10,
      depth: 10,
      width: 8,
      height: 12,
    },
    adminId,
  );
  const cupBlank = await stockService.createWarehouseItem(
    {
      type: ItemType.CUP_BLANK,
      templateId: 'CUP_BLANK',
      attributeOptionIds: [
        optionIds['HRT'], // CUP_STYLE
        optionIds['PET'], // MATERIAL
        optionIds['500'], // CAPACITY
        optionIds['CLR'], // COLOR
      ],
      name: 'Ly nhựa trơn seed',
      unit: 'cái',
      isPerishable: false,
      minQuantity: 20,
      depth: 8,
      width: 8,
      height: 15,
    },
    adminId,
  );
```

Note: SKU/barcode are no longer passed or known ahead of time — any downstream code in `seed.ts` that referenced `'SEED-MAT-001'`/`'SEED-CUP-BLANK-001'` as literal strings (e.g. logging, or other seed functions reading these SKUs back) must be updated to read `material.sku`/`cupBlank.sku` from the returned document instead. Grep for the literal strings to confirm:

Run: `grep -n "SEED-MAT-001\|SEED-CUP-BLANK-001" apps/wms/src/seed/*.ts`

Update any hits found beyond the two `createWarehouseItem` calls themselves.

- [ ] **Step 5: Type-check and confirm the seed module still compiles**

Run: `npx tsc --noEmit -p apps/wms/tsconfig.app.json 2>&1 | grep seed.ts || echo "no errors"`
Expected: `no errors`.

- [ ] **Step 6: Manual smoke run against a dev DB (only if the user confirms a disposable dev DB is available — do not run against shared/staging data without asking)**

Run: `pnpm --filter wms run seed` (or whatever the actual `package.json` script name is — check `grep -n '"seed' package.json` first)
Expected: completes with `Seed hoàn tất.`, no thrown errors; re-running it immediately logs `seed data đã tồn tại — bỏ qua toàn bộ warehouse/item/supplier` (idempotency preserved).

- [ ] **Step 7: Commit**

```bash
git add apps/wms/src/seed/seed.ts
git commit -m "fix(wms): update seed.ts for new template-based createWarehouseItem contract"
```

---

### Task 17: Full verification pass

**Files:** none (verification only).

- [ ] **Step 1: Lint**

Run: `pnpm lint 2>&1 | tail -80`
Expected: no errors introduced by this plan's files (pre-existing unrelated lint issues in other worktrees/files are out of scope — confirm any failures shown are NOT in `apps/wms/src/stock/**`, `libs/common/src/errors/**`, or `apps/wms/scripts/**`).

- [ ] **Step 2: Full WMS test suite**

Run: `npx jest apps/wms --silent 2>&1 | tail -80`
Expected: all pass, including every new `.spec.ts` from Tasks 1, 3, 4 (indirectly), 5, 6, 7, 8, 10, 11, 12, 14.

- [ ] **Step 3: `libs/common` test suite (error-codes)**

Run: `npx jest libs/common --silent 2>&1 | tail -40`
Expected: all pass, including Task 1's `error-codes.spec.ts`.

- [ ] **Step 4: Build**

Run: `npx nest build wms 2>&1 | tail -60`
Expected: `webpack compiled successfully`.

- [ ] **Step 5: Cross-check acceptance criteria from the issue**

Go through each checkbox in issue #25's "Acceptance criteria" section and confirm a task in this plan covers it:
- Preview/create sinh đúng 3 ví dụ SKU → Task 6 (`sku-builder.spec.ts`), Task 7 (`sku-template.service.spec.ts`).
- Category không có template → reject → Task 7 (`STOCK_SKU_TEMPLATE_NOT_FOUND`).
- Option inactive/sai group/thiếu → reject → Task 7.
- Client sku/barcode bị bỏ qua/reject → Task 12 (new DTO has no such fields at all — strongest form of "reject": impossible to send).
- Hai request cùng tổ hợp → 1 thành công, 1 409 → Task 12 (11000 catch → `STOCK_ITEM_SKU_CONFLICT`).
- Hai request khác SKU → 2 EAN-13 khác nhau đúng prefix/checksum → Task 8, Task 10.
- 1 mã chỉ thuộc 1 item bất kể primary/alternate → Task 9 (`code` unique index, no compound with `kind`).
- Không sửa code option đã dùng; đổi tên/deactivate vẫn được → Task 3 (`STOCK_ATTRIBUTE_CODE_IMMUTABLE`).
- Put-away/goods issue/print job quét barcode resolve đúng item → Task 14.
- Seed script vẫn chạy được sau khi đổi contract `createWarehouseItem` → Task 16.
- `pnpm lint`, Jest, `pnpm build` pass → this task.

If any item lacks a clear task, stop and add one before declaring the plan complete — do not mark this step done with a gap.

- [ ] **Step 6: Final commit (if any cleanup was needed during verification)**

```bash
git add -A
git status
# Only commit if verification produced uncommitted fixes:
git commit -m "chore(wms): verification fixes for SKU template/barcode generation (issue #25)"
```

---

## Notes for the executing engineer

- **Task 12 and Task 13 have a forward reference**: Task 12 Step 7 wires `SkuTemplateController` into `stock.module.ts` before Task 13 creates that file. Either execute Task 13 immediately after Task 12 Step 7 (before running Task 12 Step 8's test run, which doesn't need the controller compiled), or temporarily comment out the `SkuTemplateController` import/registration in Task 12 Step 7 and uncomment it in Task 13 Step 4. The plan's task order assumes the latter.
- **Task 14 requires live investigation**: the exact call sites of `findItemByBarcode` were not fully enumerated during planning (only the definition site and the issue's acceptance-criteria mention of put-away/goods-issue/print-job). Step 1 of Task 14 is a mandatory grep-and-read before any edit — do not guess call site shapes.
- **`Types.ObjectId` pre-generation pattern** (Task 12): generating the item's `_id` before calling `createItem` is what lets the barcode registry entry be written with a valid `itemId` inside the same transaction as the item document — both writes happen before either is visible outside the transaction, so there's no window where a registry entry points at a non-existent item.
- Every new Vietnamese comment must explain **why**, not what — this was enforced throughout the plan; keep that discipline for any code written ad hoc during execution (e.g. Task 14's per-service edits).
