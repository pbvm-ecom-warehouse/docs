# S3-02: UC-04 Lệnh in ly Make-to-Order (CUP_BLANK→CUP_PRINTED) — Design

**Nguồn:** [warehouse/use-cases.md#UC-04](../../warehouse/use-cases.md), [warehouse/workflow.md#WF-02](../../warehouse/workflow.md), [warehouse/data-model.md#PrintJob](../../warehouse/data-model.md), [overview/erd.dbml](../../overview/erd.dbml)

## Bối cảnh

Đơn hàng bên Ecommerce có ly-in (`CUSTOM_PRINT`) khi vào trạng thái `PAID` sẽ bắn `print.requested` (Ecom→WMS) — **đã có code thật producer** ở `apps/ecommerce/src/order/order.service.ts:138` (không chỉ là event khai báo suông). WMS cần:

1. Tự sinh `PrintJob{PENDING}` khi nhận event, giữ (`reserved`) `CUP_BLANK` đầu vào 1 lần cho phần cần in.
2. Cho PRINTER quét xác nhận tiêu thụ `CUP_BLANK` khi bắt đầu in (`PRINT_CONSUME`).
3. Cho PRINTER xác nhận in xong, nhập `CUP_PRINTED` và giữ reserve cho đúng đơn (`PRINT_OUTPUT`).
4. Khi mọi dòng của job hoàn tất → bắn `print.completed` (WMS→Ecom) để Ecom set `fulfillmentStatus` tiếp (nếu đủ mọi ly-in → `READY_TO_PICK`).

**Quyết định đã có từ trước, KHÔNG thuộc phạm vi task này:** việc quyết định "design đã có sẵn tồn CUP_PRINTED đủ hay chưa, có cần mở PrintJob hay không" là trách nhiệm phía Ecom trước khi bắn `print.requested`. WMS coi mọi item trong payload `print.requested` là **đã xác nhận cần in**, không tự phán đoán lại.

`print.completed` (giống `goods.issued`) phải publish lên **`QUEUES.SHIPMENT`**, không phải `QUEUES.PRINT` — xác nhận từ code thật: `ShipmentConsumer` bên Ecom (`apps/ecommerce/src/order/order.consumer.ts:35`, `@Processor(QUEUES.SHIPMENT)`) đã có sẵn `case EVENTS.PRINT_COMPLETED`. Tên hằng `QUEUES.PRINT: 'print-queue'` hiện chỉ dùng cho chiều `print.requested` (Ecom→WMS), không dùng cho chiều ngược lại.

## Phạm vi & quyết định thiết kế đã chốt

1. **Tự động tạo PrintJob khi nhận event** — `PrintJobConsumer` nhận `print.requested` → tạo ngay `PrintJob{status: PENDING}` cho mỗi item, không có API tạo thủ công. Nhất quán với `GoodsIssue` (S3-01) và `PutAwayTask`. WF-02 vẽ "MANAGER tạo Print Job" nhưng use-cases.md ghi rõ trigger là event — theo code/use-cases.md, MANAGER chỉ xem (GET), không tạo thủ công.
2. **SKU CUP_PRINTED sinh từ Ecom, không phải WMS tự ghép chuỗi** — payload `print.requested.items[].sku` đã là sku CUP_PRINTED chuẩn hoá (vd `CUP-PLA-500-WHT-DSG042`). WMS chỉ `findItemBySku`/`createItem`, không tự sinh sku.
3. **Xác định CUP_BLANK đầu vào qua field mới `WarehouseItem.blankItemId`** — lưu trên chính item CUP_PRINTED. Nếu sku CUP_PRINTED đã tồn tại (design từng in trước đó) → đọc lại `blankItemId` có sẵn, không cần gửi lại. Nếu là design hoàn toàn mới (chưa từng có item CUP_PRINTED) → cần `blankSku` trong payload để tạo item mới kèm `blankItemId`. **Mở rộng `PrintRequestedPayload.items[]` thêm field optional `blankSku?: string`** (không breaking — optional, chỉ bắt buộc *về mặt nghiệp vụ* khi design mới).
4. **Thiếu tồn CUP_BLANK lúc tạo job** — vẫn tạo `PrintJob`/dòng, `reservedQty = min(quantity, available)`, log warning. Không chặn tạo job (khác GoodsIssue nơi tồn luôn đủ vì đã reserve ở checkout — ở đây job mở ra *chính vì* thiếu CUP_PRINTED nên thiếu CUP_BLANK là tình huống thật cần MANAGER xử lý thủ công/nhập thêm PO, không phải lỗi hệ thống cần retry).
5. **`PrintJobItem` track riêng `quantity` (yêu cầu) và `reservedQty`/`remainingQty` (thực giữ được)** — vì có thể reserve thiếu (mục 4). `consume` giới hạn theo `remainingQty` (phản ánh đúng số đã giữ thật), không theo `quantity` gốc.
6. **Sku output đã tồn tại nhưng sai `type` hoặc thiếu `blankItemId`** → log warning, bỏ dòng đó (không chặn cả job) — nhất quán cách GoodsIssue bỏ qua sku không khớp.
7. **Không có endpoint cancel trong lần này** — docs có nhắc `CANCELLED` (huỷ trước khi in → giải phóng reserved blank) nhưng không phải trọng tâm S3-02. Để ngoài phạm vi, làm task riêng nếu cần.
8. **`consume` và `complete` là 2 bước tách biệt trên cùng 1 dòng** (không gộp làm 1 API) — khớp đúng WF-02: quét-in (`IN_PROGRESS`) và xác-nhận-xong (nhập CUP_PRINTED) là 2 hành động PRINTER làm cách nhau (thời gian in vật lý ở giữa).

## Kiến trúc

Module mới `apps/wms/src/print-job/`, đặt cạnh `goods-issue`, import `StockModule` + `WarehouseModule`.

```
apps/wms/src/print-job/
  schemas/print-job.schema.ts
  dto/print-job.dto.ts          (request: ConsumePrintJobItemDto, CompletePrintJobItemDto, QueryPrintJobDto; response: PrintJobResponseDto)
  print-job.repository.ts
  print-job.service.ts
  print-job.controller.ts
  print-job.consumer.ts         (@Processor(QUEUES.PRINT) — nhận print.requested)
  print-job.module.ts
```

Đăng ký `PrintJobModule` vào `AppModule`.

Thêm field `blankItemId?: Types.ObjectId` vào `apps/wms/src/stock/schemas/warehouse-item.schema.ts` (chỉ có ý nghĩa khi `type = CUP_PRINTED`, trỏ về `WarehouseItem` `CUP_BLANK` gốc).

Mở rộng `libs/events/src/events.ts`:
```ts
export interface PrintRequestedPayload {
  orderId: string;
  items: { sku: string; quantity: number; designFile?: string; blankSku?: string }[];
}
```
Cập nhật producer `apps/ecommerce/src/order/order.service.ts:138` gửi kèm `blankSku` khi có (Ecom biết sku CUP_BLANK gốc của variant — chi tiết lấy từ đâu thuộc phạm vi Ecom, ngoài task be/wms này, nhưng cần sửa cùng lúc để contract nhất quán 2 phía).

### Schema: `PrintJob`

Chứng từ giao dịch — hủy bằng `status`, KHÔNG soft-delete.

```ts
export enum PrintJobStatus {
  PENDING = 'PENDING',
  IN_PROGRESS = 'IN_PROGRESS',
  COMPLETED = 'COMPLETED',
  CANCELLED = 'CANCELLED',   // giá trị tồn tại theo ERD nhưng không có luồng set nó trong task này
}

export enum PrintJobLineStatus {
  PENDING = 'PENDING',
  CONSUMED = 'CONSUMED',
  COMPLETED = 'COMPLETED',
}

@Schema({ _id: false })
class PrintJobItem {
  inputItemId: Types.ObjectId;   // required — WarehouseItem CUP_BLANK
  outputItemId: Types.ObjectId;  // required — WarehouseItem CUP_PRINTED (per-design)
  sku: string;                    // required — denormalized sku CUP_PRINTED, để hiển thị
  designFile?: string;
  quantity: number;               // required, min 0 — số yêu cầu từ đơn
  reservedQty: number;            // required, min 0 — số thực đã giữ (≤ quantity)
  remainingQty: number;           // required, min 0 — còn lại chưa consume, khởi tạo = reservedQty
  lineStatus: PrintJobLineStatus; // default PENDING
}

@Schema({ collection: 'print_jobs', timestamps: true })
export class PrintJob {
  orderId: string;                // required — id đơn hàng bên Ecom
  warehouseId: Types.ObjectId;    // required
  status: PrintJobStatus;         // default PENDING
  confirmedBy?: Types.ObjectId;   // PRINTER — set khi job chuyển COMPLETED
  items: PrintJobItem[];          // required
}
```

Index: `{ orderId: 1 }` (unique — 1 đơn 1 print job — xem lưu ý dưới), `{ status: 1 }`.

> **Lưu ý 1 đơn có thể có nhiều item khác design nhưng cùng 1 `PrintJob`** — giống `GoodsIssue`, mỗi đơn ứng với đúng 1 `PrintJob` chứa nhiều `PrintJobItem` (mỗi dòng 1 design). Không tạo nhiều `PrintJob` cho cùng đơn.

### Luồng 1 — Consumer tạo PrintJob

`print-job.consumer.ts` — `@Processor(QUEUES.PRINT)`, xử lý `EVENTS.PRINT_REQUESTED`:

1. Payload: `PrintRequestedPayload { orderId, items: {sku, quantity, designFile?, blankSku?}[] }`.
2. Idempotency: `findByOrderId` — đã có thì log warning, bỏ qua.
3. Với mỗi item:
   - `findItemBySku(item.sku)`:
     - Có, `type=CUP_PRINTED`, có `blankItemId` → dùng luôn `outputItemId` + `inputItemId = blankItemId`.
     - Có nhưng sai `type`/thiếu `blankItemId` → `logger.warn`, bỏ dòng.
     - Không có → cần `item.blankSku`; không có `blankSku` hoặc `findItemBySku(blankSku)` không ra `CUP_BLANK` → `logger.warn`, bỏ dòng. Có → `createItem({ sku: item.sku, type: CUP_PRINTED, blankItemId: blank._id, ... })`, tạo output item mới.
   - Đọc `StockBalance` của `inputItemId` tại `warehouseId` → `available = onHand - reserved - expired`. `reservedQty = min(item.quantity, max(available, 0))`. `available < quantity` → `logger.warn` (thiếu hụt, ghi rõ số thiếu).
   - `reservedQty > 0` → `upsertBalance(inputItemId, warehouseId, 0, +reservedQty, 0)` (chỉ tăng `reserved`, không đổi `onHand`) → `available` blank giảm → **bắn `stock.changed`** cho blank (delta = -reservedQty).
4. Còn ≥ 1 dòng hợp lệ → tạo `PrintJob{PENDING}`. 0 dòng hợp lệ → chỉ log, không tạo job rỗng.

Cần `BullModule.registerQueue({ name: QUEUES.PRINT })` trong `PrintJobModule`.

### Luồng 2 — Consume (PRINTER quét CUP_BLANK, bắt đầu in)

`POST /print-jobs/:id/items/:itemId/consume { itemBarcode, shelfCode, quantity, lotId? }` — `:itemId` = `inputItemId`.

1. `findById(id)` — không có → `PRINT_JOB_NOT_FOUND`.
2. `findItemByBarcode(dto.itemBarcode)` — không có → `PRINT_JOB_ITEM_NOT_FOUND`.
3. `findShelfByCode(dto.shelfCode)` — không có / khác `warehouseId` → `PRINT_JOB_SHELF_NOT_FOUND`.
4. Khớp dòng theo `inputItemId === item._id` — không thấy → `PRINT_JOB_ITEM_MISMATCH`. `dto.quantity > line.remainingQty` → `PRINT_JOB_QTY_EXCEEDS`.
5. Kiểm `InventoryStock(inputItemId, warehouseId, shelfId, lotId)` đủ `quantity` — thiếu → `STOCK_INSUFFICIENT`.
6. Trong transaction:
   - `InventoryStock(shelf, lot).quantity -= qty`
   - `StockBalance(inputItemId): onHand -= qty, reserved -= qty` (available không đổi)
   - `StockMovement{type: PRINT_CONSUME, quantity: -qty, refType: 'print_job', refId}`
   - `line.remainingQty -= qty`; nếu `remainingQty === 0` → `line.lineStatus = CONSUMED`
   - Nếu job đang `PENDING` → `job.status = IN_PROGRESS` (dòng đầu tiên bắt đầu tiêu thụ)

Có thể gọi `consume` nhiều lần cho cùng dòng (in theo đợt) cho tới khi `remainingQty = 0`. Nếu `reservedQty = 0` ngay từ đầu (hết sạch CUP_BLANK lúc tạo job — xem mục Phạm vi #4), dòng đó không bao giờ có gì để consume và ở lại `PENDING` vô thời hạn — đây là trạng thái chờ MANAGER bổ sung tồn, không phải lỗi cần xử lý tự động.

**Không bắn `stock.changed`** cho bước này — available không đổi.

### Luồng 3 — Complete (PRINTER xác nhận in xong, nhập CUP_PRINTED)

`POST /print-jobs/:id/items/:itemId/complete { shelfCode, quantity }` — `:itemId` = `inputItemId` (tra ra đúng dòng, dùng `outputItemId` của dòng đó để ghi nhận). Complete luôn xử lý **toàn bộ `reservedQty` của dòng trong 1 lần gọi** (không hỗ trợ complete từng phần theo nhiều đợt như `consume`) — vì đã bắt buộc dòng phải `CONSUMED` hết (`remainingQty = 0`) trước khi complete được.

1. `findById(id)` — không có → `PRINT_JOB_NOT_FOUND`.
2. Khớp dòng theo `inputItemId` param — không thấy → `PRINT_JOB_ITEM_MISMATCH`.
3. Dòng chưa `CONSUMED` (còn `remainingQty > 0`) → `PRINT_JOB_ITEM_NOT_CONSUMED` (chặn complete trước khi consume xong).
4. `findShelfByCode(dto.shelfCode)` — không có/khác `warehouseId` → `PRINT_JOB_SHELF_NOT_FOUND`.
5. `dto.quantity` phải bằng đúng `reservedQty` của dòng (in ra đúng số đã tiêu thụ, không hơn không kém, không chia nhiều lần) — lệch → `PRINT_JOB_QTY_EXCEEDS`.
6. Trong transaction:
   - `InventoryStock(outputItemId, warehouseId, shelfId, lotId=null).quantity += qty` (put-away tại chỗ, ly in không track lot)
   - `StockBalance(outputItemId): onHand += qty, reserved += qty` (giữ reserve cho đúng đơn — available printed không đổi)
   - `StockMovement{type: PRINT_OUTPUT, quantity: +qty, refType: 'print_job', refId}`
   - `line.lineStatus = COMPLETED`
   - Nếu mọi dòng `COMPLETED` → `job.status = COMPLETED`, `job.confirmedBy = actorId`

**Không bắn `stock.changed`** cho CUP_PRINTED — available không đổi (đã reserve ngay lúc nhập).

7. Sau transaction: nếu job vừa chuyển `COMPLETED` → `emitPrintCompleted(orderId, jobId)`.

### Luồng 4 — Producer `print.completed`

```ts
async emitPrintCompleted(orderId: string, printJobId: string): Promise<void> {
  const payload: PrintCompletedPayload = { orderId, printJobId };
  const jobId = `print_job:${printJobId}`;
  await this.shipmentQueue.add(EVENTS.PRINT_COMPLETED, payload, { jobId });
}
```

`PrintJobModule` cần `BullModule.registerQueue({ name: QUEUES.SHIPMENT })`.

## Error codes mới (`apps/wms/src/common/error-codes.ts`)

| Code | Status | Message |
|---|---|---|
| `PRINT_JOB_NOT_FOUND` | 404 | Không tìm thấy lệnh in |
| `PRINT_JOB_ITEM_NOT_FOUND` | 404 | Không tìm thấy mặt hàng theo barcode đã quét |
| `PRINT_JOB_SHELF_NOT_FOUND` | 404 | Không tìm thấy vị trí theo barcode đã quét |
| `PRINT_JOB_ITEM_MISMATCH` | 400 | Mặt hàng quét được không thuộc lệnh in này |
| `PRINT_JOB_QTY_EXCEEDS` | 400 | Số lượng quét vượt quá số lượng còn lại/đã tiêu thụ |
| `PRINT_JOB_ITEM_NOT_CONSUMED` | 400 | Dòng chưa tiêu thụ hết CUP_BLANK, chưa thể xác nhận in xong |

(`STOCK_INSUFFICIENT` đã có sẵn — tái dùng.)

## API tổng hợp

| Method | Path | Role | Mô tả |
|---|---|---|---|
| GET | `/print-jobs` | MANAGER, PRINTER, ADMIN | Danh sách lệnh in (filter status, phân trang) |
| GET | `/print-jobs/:id` | MANAGER, PRINTER, ADMIN | Chi tiết lệnh in |
| POST | `/print-jobs/:id/items/:itemId/consume` | PRINTER, ADMIN | Quét CUP_BLANK+shelf, bắt đầu in (trừ thật blank) |
| POST | `/print-jobs/:id/items/:itemId/complete` | PRINTER, ADMIN | Xác nhận in xong, nhập CUP_PRINTED |

## Testing

- `print-job.schema.spec.ts` — validate schema, index, enum.
- `print-job.service.spec.ts` — tạo từ event (sku có sẵn/design mới/thiếu blankSku/thiếu tồn), consume đủ/thiếu tồn, complete trước/sau khi consume xong, chuyển IN_PROGRESS/COMPLETED đúng thời điểm, emit print.completed đúng 1 lần (jobId dedupe).
- `print-job.consumer.spec.ts` — idempotency theo orderId, bỏ qua sku lỗi (sai type/thiếu blankItemId/thiếu blankSku), reserve đúng min(quantity, available).
- `print-job.repository.spec.ts` — theo pattern `goods-issue.repository.spec.ts`.
- `warehouse-item.schema.spec.ts` — bổ sung case field `blankItemId` mới (không bắt buộc, chỉ set khi CUP_PRINTED).

## Ngoài phạm vi (out of scope)

- Endpoint/luồng `CANCELLED` (huỷ lệnh in, giải phóng reserved blank trước khi in) — để task riêng nếu cần.
- Sinh/in tem barcode tự động cho `WarehouseItem` CUP_PRINTED mới tạo (docs nhắc "hệ sinh/in tem barcode" — coi như bước thủ công/khác task, ở đây chỉ tạo `barcode` field nếu Ecom gửi kèm, không tự sinh mã).
- Sửa phía Ecom để thực sự gửi `blankSku` trong payload `print.requested` — task này chỉ mở rộng contract (`PrintRequestedPayload`) và code phía WMS đọc field đó; việc Ecom xác định đúng `blankSku` cho mỗi variant CUSTOM_PRINT là quyết định/implementation riêng bên `apps/ecommerce`.
- Trường hợp `reservedQty < quantity` (thiếu hụt CUP_BLANK) không có cơ chế tự động bù/re-check khi có hàng về — MANAGER xử lý thủ công (nhập thêm PO rồi tạo lệnh in bổ sung thủ công nếu cần, ngoài phạm vi tự động hoá).
