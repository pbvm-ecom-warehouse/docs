# Demo Script — WMS Happy Path (S4-05)

Chạy lại được: seed 1 lần, sau đó lặp lại các bước dưới bằng curl/Postman. Yêu cầu app WMS đang chạy (`pnpm start:wms`), Redis + Mongo (replica set) đã sẵn sàng.

Prefix API toàn cục: `/api/wms`. Port mặc định `WMS_PORT=3001` (đổi `localhost:3001` theo `.env` thực tế nếu khác).

## Chuẩn bị

```bash
pnpm seed:wms
```

Script seed idempotent (chạy lại không tạo trùng), tạo sẵn:

- **1 ADMIN**: `seed_admin`
- **5 user theo role**: `seed_manager` (MANAGER), `seed_receiver` (RECEIVER), `seed_picker` (PICKER), `seed_printer` (PRINTER), `seed_counter` (COUNTER)
- Mật khẩu chung cho cả 6 user: **`Seed@12345`**
- 1 warehouse **"Kho trung tâm (seed)"** → 1 zone (`SEED-A`) → 1 rack (`SEED-A1`) → 2 shelf:
  - shelf staging: code **`SEED-A1-STAGING`** (`isStaging: true`)
  - shelf chính: code **`SEED-A1-T2`** (kích thước trong: `innerDepth=120, innerWidth=80, innerHeight=50, fillFactor=0.8`)
- 2 item:
  - MATERIAL: sku **`SEED-MAT-001`**, barcode **`SEED-MAT-001-BC`**, tên "Nguyên liệu seed", đơn vị `kg`
  - CUP_BLANK: sku **`SEED-CUP-BLANK-001`**, barcode **`SEED-CUP-BLANK-001-BC`**, tên "Ly nhựa trơn seed", đơn vị `cái`
- 1 supplier: code **`SEED-NCC-001`**, tên "Nhà cung cấp seed" (gắn giá mua sẵn cho cả 2 item)

Console log của `pnpm seed:wms` in ra id thật của warehouse + 2 shelf (dòng `Kho seed: <warehouseId>, shelf staging: ..., shelf chính: ...`). Item/supplier id không được log trực tiếp — lấy qua API (`GET /api/wms/...`) hoặc query Mongo (`db.warehouse_items.find({sku: "SEED-MAT-001"})`, `db.suppliers.find({code: "SEED-NCC-001"})`) sau khi seed xong. Copy các id này để thay vào `<WAREHOUSE_ID>`, `<ITEM_ID>`, `<SUPPLIER_ID>`, `<SHELF_MAIN_ID>` ở các bước dưới.

## Bước 1 — Đăng nhập MANAGER

```bash
curl -X POST http://localhost:3001/api/wms/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"seed_manager","password":"Seed@12345"}'
```

Kỳ vọng: `200`, body `{ data: { accessToken, refreshToken, mustChangePassword: true } }`. Lưu `accessToken` → `$MANAGER_TOKEN`.

**Điểm nhấn cho người xem:** `mustChangePassword: true` — user seed chưa đổi mật khẩu lần đầu, đúng hành vi bảo mật mặc định.

## Bước 2 — Tạo Purchase Order

```bash
curl -X POST http://localhost:3001/api/wms/purchase-orders \
  -H "Authorization: Bearer $MANAGER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "supplierId": "<SUPPLIER_ID>",
    "warehouseId": "<WAREHOUSE_ID>",
    "items": [{ "itemId": "<ITEM_ID>", "sku": "SEED-MAT-001", "expectedQty": 100, "unit": "kg" }]
  }'
```

Kỳ vọng: `201`, `status: "CONFIRMED"` ngay (không có bước xác nhận PO riêng — PO tạo ra đã sẵn sàng nhận hàng). Lưu `data.id` → `$PO_ID`.

## Bước 3 — Đăng nhập RECEIVER, tạo + confirm GRN

```bash
curl -X POST http://localhost:3001/api/wms/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"seed_receiver","password":"Seed@12345"}'
# lưu accessToken → $RECEIVER_TOKEN

curl -X POST http://localhost:3001/api/wms/goods-receipt-notes \
  -H "Authorization: Bearer $RECEIVER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "purchaseOrderId": "'"$PO_ID"'",
    "items": [{ "itemId": "<ITEM_ID>", "sku": "SEED-MAT-001", "actualQty": 100, "unit": "kg" }]
  }'
# lưu data.id → $GRN_ID

curl -X POST http://localhost:3001/api/wms/goods-receipt-notes/$GRN_ID/confirm \
  -H "Authorization: Bearer $RECEIVER_TOKEN"
```

**Điểm nhấn:** `onHand` của item tăng từ 0 → 100 ngay khi GRN `CONFIRMED` (không đợi duyệt `APPROVED`). Đồng thời hệ tự sinh 1 PutAwayTask ở background, hàng nằm tạm ở shelf staging (`SEED-A1-STAGING`) — bước sau sẽ dời đi.

## Bước 4 — Gợi ý put-away rồi xác nhận

```bash
curl -G http://localhost:3001/api/wms/putaway/suggestions \
  -H "Authorization: Bearer $RECEIVER_TOKEN" \
  --data-urlencode "sku=SEED-MAT-001" \
  --data-urlencode "qty=100" \
  --data-urlencode "warehouseId=<WAREHOUSE_ID>"
```

**Điểm nhấn:** gợi ý dựa trên thể tích 3 chiều (`depth × width × height` của item so với `innerDepth/innerWidth/innerHeight × fillFactor` của shelf) — không phải chọn ngẫu nhiên. Với item seed (`depth=10, width=8, height=12`) và shelf `SEED-A1-T2` (`innerDepth=120, innerWidth=80, innerHeight=50, fillFactor=0.8`), shelf này đủ sức chứa nên sẽ nằm trong danh sách gợi ý.

```bash
curl -X POST http://localhost:3001/api/wms/putaway-tasks/<PUTAWAY_TASK_ID>/confirm-line \
  -H "Authorization: Bearer $RECEIVER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{ "itemBarcode": "SEED-MAT-001-BC", "shelfCode": "SEED-A1-T2", "quantity": 100 }'
```

(`<PUTAWAY_TASK_ID>` lấy từ `GET /api/wms/putaway-tasks?...` lọc theo GRN vừa confirm, hoặc từ log/DB `put_away_tasks` với `refId = $GRN_ID`.)

**Điểm nhấn:** `onHand` KHÔNG đổi (vẫn 100) — put-away chỉ dời vị trí trong lớp 2 (`InventoryStock`: từ shelf staging sang shelf `SEED-A1-T2`), không phải nhập thêm.

## Bước 5 — Xuất kho (mô phỏng đơn hàng sẵn sàng xuất)

Trong demo thật, bước này do event `order.ready_to_fulfill` từ Ecommerce kích hoạt tự động (`GoodsIssueService.createFromOrderReady` tạo `GoodsIssue` từ event). Để demo độc lập WMS, enqueue thủ công job này vào queue `ORDER` (xem `apps/wms/test/happy-path.e2e-spec.ts` phần enqueue `EVENTS.ORDER_READY_TO_FULFILL` để tham khảo payload mẫu), hoặc demo nguyên luồng cùng app Ecommerce nếu có thời gian.

```bash
curl -X POST http://localhost:3001/api/wms/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"seed_picker","password":"Seed@12345"}'
# lưu accessToken → $PICKER_TOKEN

curl -X POST http://localhost:3001/api/wms/goods-issues/<GOODS_ISSUE_ID>/confirm-line \
  -H "Authorization: Bearer $PICKER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{ "itemBarcode": "SEED-MAT-001-BC", "shelfCode": "SEED-A1-T2", "quantity": 30 }'
```

(`<GOODS_ISSUE_ID>` lấy từ `GET /api/wms/goods-issues?...` sau khi GoodsIssue được tạo từ event ở trên.)

**Điểm nhấn:** `onHand` giảm 100 → 70. Sự kiện `goods.issued` được bắn cho Ecommerce (nếu app đó đang chạy, `fulfillment` của đơn sẽ chuyển `ISSUED`).

## Bước 6 — Kiểm kê khớp

```bash
curl -X POST http://localhost:3001/api/wms/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"seed_manager","password":"Seed@12345"}'
# $MANAGER_TOKEN

curl -X POST http://localhost:3001/api/wms/stock-counts \
  -H "Authorization: Bearer $MANAGER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{ "warehouseId": "<WAREHOUSE_ID>" }'
# lưu data.id → $COUNT_ID, và data.items[].systemQty cho item đang demo

curl -X POST http://localhost:3001/api/wms/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"seed_counter","password":"Seed@12345"}'
# $COUNTER_TOKEN

curl -X POST http://localhost:3001/api/wms/stock-counts/$COUNT_ID/items/<ITEM_ID>/count \
  -H "Authorization: Bearer $COUNTER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{ "shelfId": "<SHELF_MAIN_ID>", "actualQty": 70 }'

curl -X POST http://localhost:3001/api/wms/stock-counts/$COUNT_ID/approve \
  -H "Authorization: Bearer $MANAGER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{}'
```

(`<SHELF_MAIN_ID>` là ObjectId thật của shelf `SEED-A1-T2`, lấy từ log seed hoặc `GET /api/wms/warehouses/...`.)

**Điểm nhấn (kết thúc demo):** đếm đúng số hệ thống (70) → 0 chênh lệch, không sinh `StockMovement` loại `ADJUST`. Toàn bộ demo có 3 nghiệp vụ (nhập/dời/xuất) nhưng để lại **4 dòng** trong sổ cái `stock_movements`, không phải 3 — vì bước dời hàng (put-away `confirm-line`) chạm 2 vị trí cùng lúc nên tự sinh 2 dòng (trừ ở shelf staging, cộng ở shelf đích), trong khi nhập (GRN confirm) và xuất (goods-issue confirm-line) mỗi bước chỉ sinh 1 dòng. `onHand` luôn khớp tổng `InventoryStock` — chứng minh bất biến 2 lớp tồn kho giữ nguyên xuyên suốt.
