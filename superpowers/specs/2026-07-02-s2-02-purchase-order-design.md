# S2-02: UC-01 Purchase Order — Design

**Sprint:** 2 · **Size:** M · **Depends-on:** S2-01 (Supplier)
**Issue:** `docs/planning/issues/S2-02-purchase-order.md`
**Tài liệu tham chiếu:** `docs/warehouse/use-cases.md` UC-01, `docs/warehouse/data-model.md` (Nhóm 4), `docs/db/03-nhap-kho.md`, `docs/overview/erd.md`

## Bối cảnh

PO là bước đầu luồng nhập kho (WF-01): MANAGER đặt hàng từ NCC trước khi hàng về. S2-02 chỉ làm phần **tạo + xem PO**. Cập nhật trạng thái theo lượng nhận thực tế (`PARTIALLY_RECEIVED`/`COMPLETED`) là việc của GRN (S2-03) — không làm ở đây.

## Quyết định thiết kế (đã chốt cùng user)

1. **Status enum:** dùng bộ đầy đủ theo `data-model.md`/`erd.md` (nguồn chi tiết nhất, khớp `db/03-nhap-kho.md` và `workflow.md` WF-01) thay vì bộ rút gọn trong issue file:
   `DRAFT | CONFIRMED | SENT | PARTIALLY_RECEIVED | COMPLETED | CANCELLED`.
2. **Flow tạo PO — 1 bước:** `POST /purchase-orders` tạo PO và set thẳng `status = CONFIRMED` (không dừng ở `DRAFT`, chưa đánh dấu `SENT`). Khớp acceptance criteria "Tạo PO với NCC hợp lệ → trạng thái active ngay". Không có API confirm/send riêng trong S2-02.
3. **PO item có field `unit`** (đơn vị đặt, có thể là đơn vị phụ như "thùng") dù việc quy đổi `baseQty = qty × factor` chỉ thực sự dùng ở GRN (S2-03) — thêm sẵn để tránh migrate schema sau.
4. **Không chuẩn bị hook cho GRN.** Không thêm `receivedQty` hay method `applyReceivedQty` — S2-03 tự thiết kế field/method khi cần.
5. **Không có API hủy PO** trong S2-02. `CANCELLED` chỉ khai báo trong enum.
6. **`warehouseId` là field bắt buộc** trên PO (kho sẽ nhận hàng) — validate tồn tại qua `WarehouseService.getWarehouse()`.
7. **Giá thiếu → từ chối tạo PO.** Nếu dòng item để trống `unitPrice` và SKU đó chưa có `SupplierItem` (chưa khai báo giá) → ném lỗi, không cho tạo PO với giá rỗng/0 ngầm định.

## Phạm vi

### Schema

**`PurchaseOrder`** — collection `purchase_orders`, **chứng từ giao dịch** (theo `data-and-mongoose.md`): `timestamps: true`, hủy bằng `status`, KHÔNG soft-delete.

| Field | Type | Ghi chú |
|---|---|---|
| `poNumber` | `string`, unique | Mã PO hiển thị, hệ tự sinh (`PO-YYYYMMDD-xxxx`) |
| `supplierId` | `ObjectId`, required | Ref `Supplier` — không populate xuyên module, chỉ lưu id |
| `warehouseId` | `ObjectId`, required | Ref `Warehouse` — kho sẽ nhận hàng |
| `status` | enum, default `CONFIRMED` | `DRAFT/CONFIRMED/SENT/PARTIALLY_RECEIVED/COMPLETED/CANCELLED` |
| `orderDate` | `Date`, default `now` | |
| `expectedDate` | `Date`, optional | Ngày dự kiến nhận |
| `note` | `string`, optional | |
| `items` | `PurchaseOrderItem[]` | Sub-document, xem bên dưới |
| `createdBy` | `ObjectId` | User tạo (MANAGER/ADMIN) |

**`PurchaseOrderItem`** — sub-document (`@Schema({ _id: false })`, giống pattern `AltUnit` trong `warehouse-item.schema.ts`):

| Field | Type | Ghi chú |
|---|---|---|
| `itemId` | `ObjectId`, required | `WarehouseItem._id` |
| `sku` | `string`, required | Denormalized từ `WarehouseItem.sku` — hiển thị nhanh không cần join |
| `expectedQty` | `number`, required, min 0 | Số lượng đặt theo `unit` |
| `unit` | `string`, required | Đơn vị đặt (đơn vị cơ sở hoặc đơn vị phụ của `WarehouseItem`) |
| `unitPrice` | `number`, required, min 0 | Giá đặt — tự điền từ `SupplierItem.purchasePrice` nếu để trống lúc tạo |

Bảng dòng `*Item` không mang audit riêng (kế thừa từ PO cha) — đúng quy ước `data-and-mongoose.md`.

### Module mới: `apps/wms/src/purchase-order/`

Cấu trúc theo mẫu `supplier/`:
```
purchase-order/
  schemas/purchase-order.schema.ts   (PurchaseOrder + PurchaseOrderItem sub-schema)
  dto/purchase-order.dto.ts          (Create/Query DTO + ResponseDto)
  purchase-order.repository.ts
  purchase-order.service.ts
  purchase-order.controller.ts
  purchase-order.module.ts
```

`PurchaseOrderModule` imports `SupplierModule` (dùng `SupplierService.assertSupplierActive` + `getSupplierItemByItemId`) và `WarehouseModule` (dùng `WarehouseService.getWarehouse`). Đăng ký vào `AppModule`.

### Service logic — `createPurchaseOrder(dto, actorId)`

1. `supplierService.assertSupplierActive(dto.supplierId)` — ném `SUPPLIER_NOT_ACTIVE` (đã có sẵn, message đã nói rõ "không thể xác nhận PO") nếu NCC không `ACTIVE` (bao gồm `BLACKLIST`/`INACTIVE`).
2. `warehouseService.getWarehouse(dto.warehouseId)` — ném `WAREHOUSE_NOT_FOUND` nếu không tồn tại (dùng lại code có sẵn).
3. Với từng dòng item trong `dto.items`:
   - Nếu `unitPrice` có giá trị → giữ nguyên (cho phép sửa tay, override giá gợi ý).
   - Nếu thiếu → gọi `supplierService.getSupplierItemByItemId(itemId)`; nếu tồn tại → lấy `purchasePrice`; nếu không tồn tại (ném `SUPPLIER_ITEM_NOT_FOUND` từ service) → catch và re-throw `PO_PRICE_MISSING` (message rõ ràng hơn cho ngữ cảnh PO).
4. Sinh `poNumber`, set `status = CONFIRMED`, gọi `repo.createPurchaseOrder(...)`.

### Endpoints

Base path: `api/wms/purchase-orders` (global prefix `api/wms` đã set ở `main.ts`).

| Method | Path | Roles | Mô tả |
|---|---|---|---|
| `POST` | `/purchase-orders` | `MANAGER, ADMIN` | Tạo PO — logic ở trên |
| `GET` | `/purchase-orders` | `MANAGER, ADMIN` | List, offset pagination (`page/limit`), filter `status?`, `supplierId?` |
| `GET` | `/purchase-orders/:id` | `MANAGER, ADMIN` | Chi tiết PO |

Response DTO theo `dto-conventions.md`: `PurchaseOrderResponseDto` (`@Expose` toàn field, `_id`→`id`, nested `items` qua `@Type(() => PurchaseOrderItemResponseDto)`). Enum `status` khai `@ApiProperty({ enum: PurchaseOrderStatus })`. `@Roles` ghi kèm `— [MANAGER, ADMIN]` trong `@ApiOperation summary`.

### Error codes mới (`apps/wms/src/common/error-codes.ts` → `WMS_ERRORS`)

```ts
PO_PRICE_MISSING: { status: HttpStatus.BAD_REQUEST, message: 'Thiếu đơn giá — SKU chưa có báo giá NCC, cần nhập tay' }
PO_NOT_FOUND: { status: HttpStatus.NOT_FOUND, message: 'Không tìm thấy đơn đặt hàng' }
```

(Dùng lại `SUPPLIER_NOT_ACTIVE`, `WAREHOUSE_NOT_FOUND`, `SUPPLIER_ITEM_NOT_FOUND` đã có sẵn — không tạo trùng.)

## Acceptance Criteria (từ issue, giữ nguyên)

- Tạo PO với NCC hợp lệ (status `ACTIVE`) → PO lưu với `status = CONFIRMED`.
- Tạo PO với NCC `BLACKLIST`/`INACTIVE` → bị từ chối (`SUPPLIER_NOT_ACTIVE`).
- Dòng item để trống `unitPrice` và SKU có `SupplierItem` → tự điền `purchasePrice`.
- Dòng item để trống `unitPrice` và SKU **không có** `SupplierItem` → từ chối tạo PO (`PO_PRICE_MISSING`).
- `warehouseId` không tồn tại → từ chối (`WAREHOUSE_NOT_FOUND`).

## Ngoài phạm vi (rõ ràng KHÔNG làm ở S2-02)

- API confirm/send PO (`DRAFT→CONFIRMED→SENT`) riêng biệt.
- API hủy PO (`CANCELLED`).
- Field hoặc method chuẩn bị cho GRN cập nhật trạng thái PO (`receivedQty`, `applyReceivedQty`...) — để S2-03 tự thiết kế.
- Quy đổi đơn vị phụ → đơn vị cơ sở (`baseQty = qty × factor`) — chỉ cần ở GRN.

## Testing

- Unit test `PurchaseOrderService`: giá tự điền, giá thiếu bị từ chối, NCC blacklist bị chặn, warehouse không tồn tại bị chặn.
- Unit test `PurchaseOrderRepository`: create, findById, list với filter/pagination.
- Theo `test-driven-development` skill convention của repo (xem `*.spec.ts` cạnh mỗi service/repository hiện có).
