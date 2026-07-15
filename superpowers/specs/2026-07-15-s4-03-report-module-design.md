# S4-03: Module Report — tồn & hiệu suất kho (read-only) — Design

**Nguồn:** [planning/issues/S4-03-report-module.md](../../planning/issues/S4-03-report-module.md), [overview/gap-analysis.md §5 Report](../../overview/gap-analysis.md), [db/02-hang-hoa-va-ton-kho.md](../../db/02-hang-hoa-va-ton-kho.md)

## Bối cảnh

WMS chưa có endpoint báo cáo nào — mọi số liệu tồn/hiệu suất hiện chỉ xem được qua các collection thô (`stock_balances`, `inventory_stocks`, `stock_movements`, `lots`). Task này thêm 1 module **thuần đọc** (không schema mới, không state machine, không event) cho MANAGER/ADMIN xem: tồn theo SKU+kho, tồn theo lô (kèm cảnh báo hết hạn), và hiệu suất nhập/xuất/điều chỉnh theo khoảng ngày. Doanh thu/số đơn hàng cần dữ liệu bên Ecommerce (Order) — ngoài phạm vi task này (đúng ghi chú trong issue).

## Phạm vi & quyết định thiết kế đã chốt

1. **1 endpoint tồn theo SKU+kho, không gộp lô vào cùng response** — `GET /reports/stock` trả 1 dòng/(sku, warehouse) đọc trực tiếp từ `StockBalance` (đã là snapshot đúng cấp độ này — không cần tự tính lại từ `InventoryStock`). Phần lô hết hạn/sắp hết hạn tách sang endpoint riêng (`GET /reports/stock/lots`) vì `Lot` chỉ áp dụng cho hàng `isPerishable`; gộp chung sẽ làm response phức tạp không cần thiết cho hàng thường.
2. **Báo cáo hiệu suất trả tổng hợp theo loại movement trong cả khoảng ngày, không breakdown theo từng ngày** — khớp đúng acceptance criteria ("khớp đếm trên `stock_movements` trong khoảng ngày"), không thêm time-series (YAGNI — issue không yêu cầu vẽ biểu đồ xu hướng).
3. **Chuẩn phân trang mới (`PaginatedResult`/`OffsetPaginationQuery`/`buildOffsetMeta` từ `@app/common`)** — hạ tầng này đã tồn tại trong `libs/common/src/pagination/` từ cross-cutting-standards nhưng **chưa module nào trong `apps/wms` dùng** (tất cả vẫn tự viết `{ data, total, page, limit }`, vd `stock.controller.ts`). Report là module mới, hoàn toàn hợp lý để là module đầu tiên theo đúng chuẩn đã thiết kế sẵn — không phải sửa module cũ.
4. **Ngưỡng "sắp hết hạn" cố định 7 ngày**, không nhận query param tùy chỉnh — đơn giản hoá cho task này, dễ thêm `?withinDays=` sau nếu FE cần.
5. **`GET /reports/performance` không phân trang** — kết quả group theo `MovementType` (tối đa 8 dòng cố định theo enum hiện có), phân trang không có ý nghĩa với tập kết quả nhỏ cố định này.
6. **`dateFrom`/`dateTo` optional, mặc định 30 ngày gần nhất nếu không truyền** — tránh bắt buộc client luôn phải tính ngày, vẫn cho phép filter khoảng tuỳ ý khi cần.
7. **Không validate tồn tại của `warehouseId`/`sku` trong filter** — đây là các tiêu chí `$match` thuần, khớp quy ước hiện có (`QueryWarehouseItemDto` và các query DTO tương tự trong dự án không kiểm tra FK tồn tại). `warehouseId` vẫn gắn `@IsMongoId()` để tránh Mongoose `CastError` (500) khi client gửi id sai định dạng — lỗi đó phải là `400 VALIDATION_FAILED` qua `ValidationPipe` toàn cục.
8. **Không có schema/state machine/event riêng** — module không sở hữu collection mới, không cần `AppException` domain-specific ngoài validation input chuẩn (không có case "not found"/"conflict" vì đây không phải thao tác trên 1 document cụ thể).
9. **`ReportModule` tự đăng ký `MongooseModule.forFeature([...])` cho 6 model đã tồn tại** (`StockBalance`, `InventoryStock`, `StockMovement`, `Lot`, `WarehouseItem`, `Warehouse`) thay vì import `StockModule`/`WarehouseModule` để tái dùng repository — vì các repository hiện có (`StockRepository`, `WarehouseRepository`) không có method aggregate phù hợp cho báo cáo (group theo type, sum theo lô...), và NestJS/Mongoose cho phép nhiều module đăng ký cùng 1 model name+schema trên cùng 1 connection mà không xung đột (nguyên lý y hệt việc nhiều module cùng `BullModule.registerQueue` cùng 1 queue, đã ghi trong `events.md`).

## Kiến trúc

Module mới, độc lập, chỉ đọc: `apps/wms/src/report/`.

```
apps/wms/src/report/
  dto/
    query-stock-report.dto.ts        (request: warehouseId?, sku?, page, limit)
    query-lot-report.dto.ts          (request: warehouseId?, sku?, status?, page, limit)
    query-performance-report.dto.ts  (request: dateFrom?, dateTo?, warehouseId?, sku?)
    report.response.dto.ts           (response: StockReportItemDto, LotReportItemDto, PerformanceReportItemDto)
  report.repository.ts    (aggregation pipelines, @InjectModel × 6)
  report.repository.spec.ts
  report.service.ts       (gọi repository, tính available/expiryFlag/date-range mặc định, map sang response DTO)
  report.service.spec.ts
  report.controller.ts    (3 route GET, @Roles(ADMIN, MANAGER))
  report.module.ts
```

Không import `EventsModule` (không produce/consume event nào). Đăng ký vào `AppModule` sau `GoodsReturnModule`.

## Endpoints

Tất cả dưới `api/wms`, guard `JwtAuthGuard, RolesGuard`, `@Roles(WmsRole.ADMIN, WmsRole.MANAGER)`.

### 1. `GET /reports/stock`
Query: `warehouseId?` (`@IsMongoId`), `sku?` (`@IsString`), `page`/`limit` (`OffsetPaginationQuery`).
Nguồn: `StockBalance` — mỗi document đã là 1 dòng (itemId, warehouseId) sẵn, `$match` theo filter (resolve `sku` → `itemId` qua `$lookup WarehouseItem` rồi `$match` trên `sku` đã lookup, hoặc resolve `itemId` trước ở service nếu `sku` được truyền — chọn cách resolve trước ở service để giữ pipeline đơn giản: nếu `sku` có mà không tìm thấy `WarehouseItem` tương ứng → trả `data: [], total: 0` ngay, không query xuống `StockBalance`).
`$lookup` → `WarehouseItem` (sku, name), `Warehouse` (name). Response mỗi dòng:
```
{ sku, itemName, warehouseId, warehouseName, onHand, reserved, expired, available }
```
`available = onHand - reserved - expired` tính ở `ReportService` (không tính trong pipeline — dễ unit-test).

### 2. `GET /reports/stock/lots`
Query: `warehouseId?`, `sku?`, `status?` (`LotStatus` enum), `page`/`limit`.
Nguồn: `InventoryStock` với `$match: { lotId: { $ne: null } }` (loại hàng không perishable) + filter warehouse, `$group` theo `(lotId, warehouseId)` sum `quantity`, `$lookup` → `Lot` (lotNumber, expiryDate, status — filter theo `status` nếu truyền), `$lookup` → `WarehouseItem` (qua `itemId` — cần giữ `itemId` trong `$group` bằng `$first` vì cùng 1 lot luôn cùng 1 item) và `Warehouse` (name). Response mỗi dòng:
```
{ sku, itemName, lotNumber, expiryDate, warehouseId, warehouseName, quantity, status, expiryFlag }
```
`expiryFlag` tính ở service: `status === EXPIRED || expiryDate < now` → `'expired'`; else `expiryDate <= now + 7 ngày` → `'expiringSoon'`; else `'ok'`.

### 3. `GET /reports/performance`
Query: `dateFrom?`, `dateTo?` (`@IsDateString`, mặc định service tự set `dateTo = now`, `dateFrom = now - 30 ngày` nếu thiếu), `warehouseId?`, `sku?`. **Không phân trang.**
Nguồn: `StockMovement` `$match` theo `createdAt` range + filter (sku resolve giống endpoint 1: không tìm thấy `WarehouseItem` → trả mảng rỗng ngay), `$group` theo `type` → `{ totalQuantity: $sum quantity (giữ dấu), movementCount: $sum 1 }`. Response: mảng đầy đủ `MovementType` (kể cả loại có `movementCount: 0` trong khoảng đó — để FE không phải tự suy luận loại nào vắng mặt), sort theo thứ tự khai báo enum.

## Xử lý lỗi

Không có `AppException` domain-specific — module không thao tác trên 1 document cụ thể nên không có case `NOT_FOUND`/`CONFLICT`. Input sai định dạng (ObjectId không hợp lệ, ngày không hợp lệ) → `400 VALIDATION_FAILED` tự động qua `ValidationPipe` toàn cục (hành vi có sẵn, không cần code thêm).

## Testing

- `report.repository.spec.ts`: mock 6 model, assert từng pipeline dựng đúng `$match`/`$group`/`$lookup` stage theo filter truyền vào.
- `report.service.spec.ts`: mock repository, assert tính `available` đúng công thức, phân loại `expiryFlag` đúng biên (đúng 7 ngày, đúng thời điểm `now`), mặc định `dateFrom`/`dateTo` khi không truyền, xử lý case `sku` không khớp `WarehouseItem` nào (trả rỗng, không query xuống collection lớn).
- Không có `report.controller.spec.ts` — khớp quy ước hiện tại (chỉ `auth.controller.ts` có controller spec; các controller domain khác là pass-through mỏng, test ở service/repository).

## Ngoài phạm vi (không làm trong task này)

- Báo cáo doanh thu/số đơn hàng (cần dữ liệu Order bên Ecommerce — không đọc chéo DB, ngoài phạm vi WMS-thuần theo đúng issue).
- Time-series/breakdown theo ngày cho báo cáo hiệu suất.
- Ngưỡng "sắp hết hạn" tùy chỉnh qua query param.
- Export CSV/Excel — chỉ JSON qua API.
- Cache/materialized view cho báo cáo — đọc trực tiếp qua aggregation mỗi request (dữ liệu không đủ lớn để cần tại thời điểm này).
