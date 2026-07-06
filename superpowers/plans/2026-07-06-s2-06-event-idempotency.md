# S2-06: Idempotency key cho stock.changed — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Thêm `jobId` deterministic (`${refType}:${refId}:${sku}`) khi phát event `stock.changed`/`stock.expired` qua BullMQ, để 2 lần gọi độc lập cho cùng 1 biến động nghiệp vụ không tạo ra 2 job riêng biệt (tránh Ecom cộng dồn `availableQty` 2 lần).

**Architecture:** Sửa signature `StockService.emitStockChanged`/`publishAvailableForItem` để nhận thêm `refType: string, refId: Types.ObjectId | string` (đúng quy ước đã có trên `StockMovement.refType/refId`), rồi truyền `jobId` khi gọi `stockQueue.add()`. Cập nhật caller duy nhất hiện có (`GoodsReceiptNoteService`) để truyền `'grn'` + `grn._id`.

**Tech Stack:** NestJS, BullMQ (`bullmq.Queue.add(name, data, opts)` — `opts.jobId`), Jest.

## Global Constraints

- Không đổi payload event (`StockChangedPayload = { sku, delta }`) — chỉ thêm option `jobId` khi `.add()`, không sửa `libs/events/src/events.ts`.
- Không sửa `EventsModule`, `redis.config.ts`, hay bất kỳ file nào trong `apps/ecommerce/` — `StockConsumer`/`applyStockDeltaOnce` giữ nguyên logic, chỉ nhận `job.id` deterministic hơn thay vì ngẫu nhiên.
- `refType`/`refId` là tham số **bắt buộc** trên `emitStockChanged`/`publishAvailableForItem` — không có nhánh optional/fallback khi thiếu.
- `refType: string` dùng đúng giá trị đã xuất hiện trên `StockMovement.refType` cho cùng nghiệp vụ (vd `'grn'` cho GRN) — nhất quán đặt tên.
- Cấm `any` — mọi type rõ ràng (`.claude/rules/dto-conventions.md`).
- Test theo pattern hiện có trong `stock.service.spec.ts`/`goods-receipt-note.service.spec.ts`: constructor injection thủ công + mock factory `jest.fn()`, không dùng `Test.createTestingModule`.

---

### Task 1: Sửa signature `StockService` + thêm test mới

**Files:**
- Modify: `apps/wms/src/stock/stock.service.ts`
- Modify: `apps/wms/src/stock/stock.service.spec.ts`

**Interfaces:**
- Produces: `StockService.emitStockChanged(sku: string, delta: number, refType: string, refId: Types.ObjectId | string): Promise<void>` và `StockService.publishAvailableForItem(itemId: string, delta: number, refType: string, refId: Types.ObjectId | string): Promise<void>` — Task 2 (`GoodsReceiptNoteService`) gọi 2 method này với `refType`/`refId` mới.

- [ ] **Step 1: Đọc file test hiện có để nắm pattern mock**

Đọc `apps/wms/src/stock/stock.service.spec.ts` — xác nhận `makeQueue()` trả `{ add: jest.fn() }`, `svc = new StockService(repo as never, queue as never)`. File hiện **chưa có** test nào cho `emitStockChanged`/`publishAvailableForItem` — đây là test mới hoàn toàn, không sửa test cũ.

- [ ] **Step 2: Viết test thất bại cho `emitStockChanged`**

Thêm vào `apps/wms/src/stock/stock.service.spec.ts`, sau `describe('createWarehouseItem', ...)`:

```typescript
describe('emitStockChanged', () => {
  it('gọi queue.add với jobId deterministic refType:refId:sku', async () => {
    await svc.emitStockChanged('SKU-1', 20, 'grn', 'grn1');

    expect(queue.add).toHaveBeenCalledWith(
      'stock.changed',
      { sku: 'SKU-1', delta: 20 },
      { jobId: 'grn:grn1:SKU-1' },
    );
  });

  it('chấp nhận refId dạng ObjectId, chuyển sang string trong jobId', async () => {
    const refId = new Types.ObjectId();

    await svc.emitStockChanged('SKU-2', -5, 'stock-count', refId);

    expect(queue.add).toHaveBeenCalledWith(
      'stock.changed',
      { sku: 'SKU-2', delta: -5 },
      { jobId: `stock-count:${refId.toString()}:SKU-2` },
    );
  });
});
```

- [ ] **Step 3: Chạy test, xác nhận fail**

Run: `pnpm test -- stock.service.spec.ts -t emitStockChanged`
Expected: FAIL — `queue.add` được gọi nhưng thiếu tham số thứ 3 `{ jobId }` (hoặc TypeScript báo lỗi biên dịch vì `emitStockChanged` hiện chỉ nhận 2 tham số, gọi với 4 tham số sẽ lỗi type trước khi chạy test).

- [ ] **Step 4: Sửa `emitStockChanged` và `publishAvailableForItem`**

Trong `apps/wms/src/stock/stock.service.ts`, thay toàn bộ 2 method (dòng 26-40):

```typescript
  /** Phát event báo Ecommerce cộng/trừ availableQty theo delta (đã gộp mọi kho).
   * jobId = refType:refId:sku — deterministic theo đúng chứng từ nguồn (khớp
   * StockMovement.refType/refId), để BullMQ tự chặn tạo job trùng nếu bị gọi
   * lặp cho cùng 1 biến động thật (vd retry ở tầng trên) — tránh Ecom cộng
   * dồn availableQty 2 lần cho cùng 1 sự kiện. */
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

  /**
   * Tính lại available tổng (mọi kho) của 1 item rồi báo Ecommerce.
   * Dùng sau khi ghi stock_balances trong các nghiệp vụ WMS.
   */
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
```

- [ ] **Step 5: Chạy lại test emitStockChanged, xác nhận pass**

Run: `pnpm test -- stock.service.spec.ts -t emitStockChanged`
Expected: PASS cả 2 test case.

- [ ] **Step 6: Viết test cho `publishAvailableForItem`**

Thêm vào `apps/wms/src/stock/stock.service.spec.ts`, sau block `emitStockChanged`:

```typescript
describe('publishAvailableForItem', () => {
  it('tra sku qua findSkuById rồi forward refType/refId xuống emitStockChanged', async () => {
    repo.findSkuById.mockResolvedValue({ sku: 'SKU-3' });

    await svc.publishAvailableForItem('item1', 35, 'grn', 'grn1');

    expect(repo.findSkuById).toHaveBeenCalledWith('item1');
    expect(queue.add).toHaveBeenCalledWith(
      'stock.changed',
      { sku: 'SKU-3', delta: 35 },
      { jobId: 'grn:grn1:SKU-3' },
    );
  });

  it('không gọi emitStockChanged khi findSkuById trả null', async () => {
    repo.findSkuById.mockResolvedValue(null);

    await svc.publishAvailableForItem('item-not-found', 10, 'grn', 'grn1');

    expect(queue.add).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 7: Chạy lại toàn bộ file, xác nhận pass**

Run: `pnpm test -- stock.service.spec.ts`
Expected: PASS toàn bộ file (test cũ `createWarehouseItem` + 4 test mới).

- [ ] **Step 8: Build để xác nhận không lỗi type**

Run: `pnpm build`
Expected: build thất bại tại bước này là **đúng dự kiến** — `GoodsReceiptNoteService` (Task 2) vẫn đang gọi `publishAvailableForItem(itemId, totalBaseQty)` với 2 tham số cũ, giờ thiếu 2 tham số bắt buộc mới. Xác nhận lỗi build đúng là do dòng gọi ở `goods-receipt-note.service.ts:244` (không phải lỗi khác) — đây là tín hiệu cho biết Task 2 cần sửa tiếp, không phải lỗi cần fix ở Task 1.

- [ ] **Step 9: Commit**

```bash
git add apps/wms/src/stock/stock.service.ts apps/wms/src/stock/stock.service.spec.ts
git commit -m "feat(wms/stock): thêm jobId deterministic refType:refId:sku cho emitStockChanged"
```

---

### Task 2: Cập nhật caller `GoodsReceiptNoteService` + sửa test hiện có

**Files:**
- Modify: `apps/wms/src/goods-receipt-note/goods-receipt-note.service.ts`
- Modify: `apps/wms/src/goods-receipt-note/goods-receipt-note.service.spec.ts`

**Interfaces:**
- Consumes: `StockService.publishAvailableForItem(itemId: string, delta: number, refType: string, refId: Types.ObjectId | string): Promise<void>` (Task 1).

- [ ] **Step 1: Sửa call site trong `confirmGoodsReceiptNote`**

Trong `apps/wms/src/goods-receipt-note/goods-receipt-note.service.ts`, dòng 242-244, thay:

```typescript
    // Ngoài transaction — BullMQ không tham gia Mongo transaction
    for (const [itemId, totalBaseQty] of baseQtyByItem) {
      await this.stockService.publishAvailableForItem(itemId, totalBaseQty);
    }
```

thành:

```typescript
    // Ngoài transaction — BullMQ không tham gia Mongo transaction
    for (const [itemId, totalBaseQty] of baseQtyByItem) {
      await this.stockService.publishAvailableForItem(
        itemId,
        totalBaseQty,
        'grn',
        grn._id,
      );
    }
```

(`grn._id` đã dùng ở dòng 232 cùng hàm cho `createTaskFromGrn` — cùng biến `grn` vẫn trong scope tại đây, không cần khai báo thêm.)

- [ ] **Step 2: Build để xác nhận lỗi type đã hết**

Run: `pnpm build`
Expected: build thành công — lỗi type từ Task 1 Step 8 đã được giải quyết.

- [ ] **Step 3: Chạy test `goods-receipt-note.service.spec.ts`, xác nhận 3 assertion cũ fail**

Run: `pnpm test -- goods-receipt-note.service.spec.ts`
Expected: FAIL ở 3 vị trí — các `expect(stockService.publishAvailableForItem).toHaveBeenCalledWith(itemId, N)` (dòng ~300, ~445, ~521 trước khi sửa) giờ nhận thêm 2 tham số thực tế (`'grn'`, `grn._id`) nên assertion cũ (chỉ 2 tham số) không khớp.

- [ ] **Step 4: Sửa assertion thứ nhất (test đơn giản, 1 dòng GRN)**

Tìm đoạn (khoảng dòng 300):

```typescript
      expect(stockService.publishAvailableForItem).toHaveBeenCalledWith(
        itemId,
        20,
      );
```

Sửa thành:

```typescript
      expect(stockService.publishAvailableForItem).toHaveBeenCalledWith(
        itemId,
        20,
        'grn',
        grnId,
      );
```

(biến `grnId` đã khai báo `const grnId = 'grn1';` ở đầu file, dùng làm `_id` của mock GRN trong test này — xem `_id: grnId` ở phần setup `repo.findGoodsReceiptNoteById.mockResolvedValueOnce({ _id: grnId, ... })` phía trên cùng test case.)

- [ ] **Step 5: Sửa assertion thứ hai (test multi-lot cùng itemId)**

Tìm đoạn (khoảng dòng 443-448):

```typescript
      // publishAvailableForItem gộp theo itemId TRƯỚC transaction (baseQtyByItem) — gọi 1 lần với tổng 35
      expect(stockService.publishAvailableForItem).toHaveBeenCalledTimes(1);
      expect(stockService.publishAvailableForItem).toHaveBeenCalledWith(
        itemId,
        35,
      );
```

Sửa thành:

```typescript
      // publishAvailableForItem gộp theo itemId TRƯỚC transaction (baseQtyByItem) — gọi 1 lần với tổng 35
      expect(stockService.publishAvailableForItem).toHaveBeenCalledTimes(1);
      expect(stockService.publishAvailableForItem).toHaveBeenCalledWith(
        itemId,
        35,
        'grn',
        grnId,
      );
```

- [ ] **Step 6: Sửa assertion thứ ba (test quy đổi altUnits)**

Tìm đoạn (khoảng dòng 515-524, ngay sau `poService.applyReceivedQty` cùng test case altUnits thùng→cái):

```typescript
      expect(stockService.publishAvailableForItem).toHaveBeenCalledWith(
        itemId,
        100,
      );
```

Sửa thành:

```typescript
      expect(stockService.publishAvailableForItem).toHaveBeenCalledWith(
        itemId,
        100,
        'grn',
        grnId,
      );
```

- [ ] **Step 7: Chạy lại toàn bộ file, xác nhận pass**

Run: `pnpm test -- goods-receipt-note.service.spec.ts`
Expected: PASS toàn bộ file — không có assertion nào còn dùng signature 2-tham-số cũ.

- [ ] **Step 8: Chạy toàn bộ test suite của app WMS + build**

Run: `pnpm test -- apps/wms`
Expected: PASS toàn bộ (không phá test nào khác).

Run: `pnpm build`
Expected: build thành công.

- [ ] **Step 9: Chạy toàn bộ test suite monorepo (xác nhận không phá Ecommerce/notification)**

Run: `pnpm test`
Expected: PASS toàn bộ — đặc biệt xác nhận `apps/ecommerce/src/catalog/stock.consumer.ts`/`catalog.repository.spec.ts` (nếu có test cho `applyStockDeltaOnce`) không bị ảnh hưởng, vì signature/logic bên Ecommerce không đổi.

- [ ] **Step 10: Commit**

```bash
git add apps/wms/src/goods-receipt-note/goods-receipt-note.service.ts apps/wms/src/goods-receipt-note/goods-receipt-note.service.spec.ts
git commit -m "fix(wms/goods-receipt-note): truyền refType/refId khi publishAvailableForItem"
```

---

## Self-Review (đã chạy trước khi giao plan)

**1. Spec coverage:**
- Signature `emitStockChanged`/`publishAvailableForItem` nhận thêm `refType`/`refId` → Task 1. ✓
- `jobId = refType:refId:sku` truyền vào `stockQueue.add()` → Task 1 Step 4. ✓
- Caller GRN cập nhật truyền `'grn'` + `grn._id` → Task 2 Step 1. ✓
- Payload event không đổi, `EventsModule`/Ecommerce không đổi → không có task nào chạm vào các file đó (đúng theo Global Constraints). ✓
- Test mới cho 2 method chưa từng có test → Task 1 Steps 2, 6. ✓
- Test cũ ở GRN cần cập nhật theo signature mới → Task 2 Steps 4-6 (3 vị trí cụ thể, đúng dòng đã xác định trước khi viết plan). ✓

**2. Placeholder scan:** Không còn "TBD"/"tương tự Task N". Mọi step code đầy đủ, chạy `grep`/đọc file thật trước khi viết Task 2 Steps 4-6 để lấy đúng số dòng và biến `grnId` thay vì đoán.

**3. Type consistency:** `refType: string, refId: Types.ObjectId | string` dùng nhất quán xuyên Task 1 (định nghĩa) → Task 2 (gọi với `grn._id`, kiểu `Types.ObjectId` theo schema `GoodsReceiptNote._id`). `jobId` string format `${refType}:${refId.toString()}:${sku}` khớp giữa code thật (Task 1 Step 4) và test assertion (Task 1 Steps 2, 6).
