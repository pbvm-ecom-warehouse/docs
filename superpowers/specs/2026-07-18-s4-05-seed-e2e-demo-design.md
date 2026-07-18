# S4-05: Seed data + E2E happy-path WMS + bug bash + demo — Design

**Ticket:** [S4-05-seed-e2e-demo.md](../../planning/issues/S4-05-seed-e2e-demo.md)
**Ngày:** 2026-07-18
**Trạng thái:** Đã duyệt, chuyển sang implementation plan.

## Bối cảnh

S4-05 là việc cuối sprint 4: chốt chất lượng bằng 1 kịch bản E2E chạy được từ seed, chứng minh luồng WMS P0 (nhập) → P5 (in ly, ngoài phạm vi vì cần đơn hàng thật) → P6 (xuất) → kiểm kê hoạt động đúng, đồng thời để lại seed data + demo script cho cả team dùng khi demo.

**Ràng buộc môi trường quan trọng:** máy thực hiện task này **không có Docker** (WSL2 integration chưa bật) và **không có Redis local**. `WMS_DATABASE_URL` trong `.env` trỏ Atlas thật (có replica set, dùng được cho `session.withTransaction` nếu cần), nhưng app không boot được nếu thiếu Redis (EventsModule/BullMQ ở root). Do đó:
- Toàn bộ code (seed script + e2e spec) được viết và review tĩnh (đọc kỹ, kiểm tra logic, khớp DTO/schema thật) nhưng **không tự chạy được `pnpm test:e2e` hay `pnpm seed:wms` trong phiên làm việc này**.
- Người dùng sẽ tự bật Docker/Redis (`docker compose -f docker-compose.local.yml up -d redis` hoặc cài Redis local) và chạy lệnh thật, báo lại nếu có lỗi.

## Phạm vi (khớp acceptance criteria ticket)

1. Seed script tạo: 1 kho trung tâm + zone/rack/shelf (có kích thước), vài `WarehouseItem` (MATERIAL/CUP_BLANK), 1 supplier + bảng giá, users đủ 6 role (ADMIN/MANAGER/RECEIVER/PICKER/PRINTER/COUNTER).
2. 1 test E2E chạy được bằng `pnpm test:e2e`, đi qua toàn bộ happy-path: `login → tạo PO → GRN CONFIRMED (onHand tăng) → put-away (+ gợi ý) → xuất hàng (onHand giảm, goods.issued) → kiểm kê khớp`.
3. Assertion bất biến 2 lớp tồn kho (`onHand === Σ InventoryStock.quantity`) sau mỗi bước quan trọng, và số dòng `StockMovement` khớp số thao tác thực hiện.
4. `docs/planning/demo-script.md` — kịch bản demo thủ công, lặp lại được, dùng seed data.
5. Bug bash: code-review tập trung các module nằm trên happy-path (không phải chạy app thật do thiếu hạ tầng).

**Ngoài phạm vi:** P5 (in ly) — vì cần đơn hàng thật từ ecommerce; luồng reserve/checkout xuyên app; scrap/return (đã có ticket riêng S4-01/S4-02).

## Kiến trúc & luồng dữ liệu

### 1. Seed script — `apps/wms/src/seed/seed.ts`

Chạy bằng Nest **application context** (không HTTP), gọi thẳng các service thật để tái dùng logic hash password / validate — không viết trực tiếp xuống Mongo như `scripts/seed-ecom-users.js` (script đó dùng raw mongoose vì ecom chưa có service phù hợp lúc viết; ở đây WMS đã có `AuthService.createUser` sẵn nên dùng lại).

```ts
const app = await NestFactory.createApplicationContext(AppModule);
// lấy service qua app.get(XxxService)
```

**Thứ tự tạo (idempotent — kiểm tra tồn tại trước khi tạo, giống pattern seed-ecom-users.js):**

1. `AuthService.bootstrapAdmin()` nếu chưa có user nào (service tự chặn nếu đã có ADMIN — theo report Explore, endpoint `bootstrap-admin` ném `AUTH_BOOTSTRAP_FORBIDDEN` nếu `countAll() > 0`; script phải bắt lỗi này gracefully nếu chạy lại lần 2).
2. `AuthService.createUser(dto, createdByAdminId)` cho 5 role còn lại: MANAGER/RECEIVER/PICKER/PRINTER/COUNTER — username/password cố định, in ra console khi seed xong (không lưu file riêng, không phải bí mật production).
3. `WarehouseService`: 1 Warehouse ("Kho trung tâm") → 1 Zone → 1 Rack → **2 Shelf**: 1 shelf `isStaging=true` (đích GRN confirm), 1 shelf thường có `innerDepth/innerWidth/innerHeight/fillFactor` khai đủ để put-away suggestion có dữ liệu tính toán.
4. Service đứng sau `POST /stock/items` (cần xác định tên class chính xác lúc viết code — Explore report chỉ xác nhận route, chưa xác nhận tên service): tạo 2 `WarehouseItem` — 1 MATERIAL (`isPerishable=false`), 1 CUP_BLANK (`isPerishable=false`, có `depth/width/height` để khớp shelf) — **không seed item perishable** để tránh phải seed thêm `lotNumber`/`expiryDate` phức tạp hoá bug bash (có thể bổ sung sau nếu cần test riêng nhánh lô/hạn).
5. `SupplierService`: 1 Supplier + `SupplierItem` (giá) cho từng WarehouseItem vừa tạo.

**Script command:** thêm `"seed:wms": "ts-node -r tsconfig-paths/register apps/wms/src/seed/seed.ts"` vào `package.json`. Đóng app context (`app.close()`) ở cuối kể cả khi lỗi (try/finally).

### 2. E2E happy-path — `apps/wms/test/happy-path.e2e-spec.ts`

Bỏ `describe.skip`, dùng `supertest` qua HTTP thật (đúng route + `ValidationPipe` + `RolesGuard` + response envelope), giống style `app.e2e-spec.ts` đã có. Test **tự tạo data riêng** (không phụ thuộc seed script đã chạy trước — độc lập, lặp lại được), qua các bước:

```
1. POST /auth/bootstrap-admin              → admin token
2. POST /auth/users ×5 (bằng admin token)  → MANAGER/RECEIVER/PICKER/PRINTER/COUNTER tokens (login riêng từng user)
3. POST /warehouse, /warehouse/zones, /warehouse/racks, /warehouse/shelves (staging + real) — token MANAGER
4. POST /stock/items — token ADMIN hoặc MANAGER — 1 WarehouseItem non-perishable
5. POST /supplier, /supplier/items — token MANAGER
6. POST /purchase-orders — token MANAGER — status trả về CONFIRMED (default, không có bước "confirm" riêng)
7. POST /goods-receipt-notes (ref PO) — token RECEIVER
   POST /goods-receipt-notes/:id/confirm — token RECEIVER
   ASSERT: StockBalance.onHand tăng đúng actualQty; StockMovement thêm 1 dòng RECEIVE
8. GET /putaway/suggestions?sku=&qty=&warehouseId= — token RECEIVER — ASSERT có ít nhất 1 gợi ý, không có warning
9. POST /putaway-tasks/:id/confirm-line — token RECEIVER — dời tồn từ shelf staging → shelf thật
   ASSERT: InventoryStock ở staging giảm, ở shelf thật tăng đúng qty; onHand KHÔNG đổi; StockMovement +1 dòng PUTAWAY
10. Enqueue trực tiếp job `EVENTS.ORDER_READY_TO_FULFILL` vào `QUEUES.ORDER` qua BullMQ Queue lấy từ testing module (@InjectQueue) — payload tối thiểu theo OrderReadyPayload thật (orderId giả, sku, warehouseId, qty)
    Poll GoodsIssueRepository (qua model injected) cho tới khi GoodsIssue xuất hiện (timeout ngắn, vd 5s) — xác nhận consumer đã xử lý job thật
11. POST /goods-issues/:id/confirm-line — token PICKER
    ASSERT: onHand giảm đúng qty; reserved về lại đúng baseline; StockMovement +1 dòng ISSUE; goods.issued đã enqueue (kiểm qua spy hoặc đọc queue — xem "Điểm mở" bên dưới)
12. POST /stock-counts — token MANAGER
    POST /stock-counts/:id/items/:itemId/count — token COUNTER — actualQty = onHand hiện tại (đọc trước đó, không cố tình lệch)
    POST /stock-counts/:id/approve — token MANAGER
    ASSERT: không có StockMovement type ADJUST mới sinh ra (vì count khớp 0 delta), status → APPROVED
13. Assertion tổng cuối: với item vừa test, onHand === Σ InventoryStock.quantity (mọi shelf); tổng số StockMovement của item = 3 (RECEIVE + PUTAWAY + ISSUE); không có dòng ADJUST.
```

**Helper bất biến:** 1 hàm dùng chung `assertTwoLayerInvariant(itemId, warehouseId)` — inject `getModelToken(StockBalance.name)` / `getModelToken(InventoryStock.name)` từ testing module, gọi sau bước 7, 9, 11, 13.

**Timeout & polling cho BullMQ job:** dùng vòng lặp `while` với `sleep` ngắn (100-200ms) + timeout tổng (5-10s) để chờ consumer xử lý xong job bất đồng bộ — không dùng `sleep` cố định dài (tránh test giòn/chậm vô ích).

### 3. `docs/planning/demo-script.md`

Kịch bản demo thủ công bằng curl (hoặc mô tả request/response), theo đúng thứ tự bước E2E ở trên nhưng viết cho người trình bày đọc (không phải code test) — dùng data seed thật từ `pnpm seed:wms` (username/password cố định), không phải data tự sinh của e2e test. Mỗi bước: mục đích ngắn, lệnh curl mẫu, response kỳ vọng (rút gọn), điểm cần chỉ ra cho người xem (vd "chú ý `onHand` tăng từ 0 → 100 ở bước này").

### 4. Bug bash (code-review, không chạy app thật)

Review tập trung các file nằm trên đường happy-path, tìm bug logic — không phải audit toàn bộ codebase:
- `put-away-suggestion.service.ts` — công thức 3D volume, fallback fillFactor.
- `goods-receipt-note.service.ts` (đoạn `confirm`) — 2-layer stock update có atomic đúng không (session/transaction), có tạo đúng `PutAwayTask` không.
- `put-away.service.ts` (`confirm-line`) — dời tồn giữa 2 shelf có giữ invariant `onHand` không đổi không.
- `goods-issue/order-ready.consumer.ts` — idempotency khi job retry (BullMQ retry 5 lần theo rule events.md).
- `stock-count.service.ts` (approve) — tính delta, sinh `ADJUST` đúng dấu.

Phát hiện gì sẽ báo cáo cụ thể (file:line + kịch bản lỗi), không tự ý sửa nếu không chắc — theo tinh thần "receiving code review"/không đoán.

## Điểm mở cần xác nhận lúc code (không chặn thiết kế)

- Tên chính xác của service đứng sau `POST /stock/items` (Explore report xác nhận route/DTO nhưng không nêu tên class) — xác định khi đọc `apps/wms/src/stock/`.
- Cách assert `goods.issued` đã enqueue: có thể spy `Queue.add` qua Nest testing module override, hoặc đọc trực tiếp job trong Redis qua BullMQ API — chọn cách đơn giản nhất lúc viết code, ưu tiên spy (không phụ thuộc timing thêm).
- Nếu `AuthService.bootstrapAdmin()` ném lỗi khi DB đã có user (từ lần seed trước) — seed script cần catch cụ thể theo `AppException` code (không catch chung `Error`), tra đúng error code lúc viết.

## Testing

- `pnpm test:e2e` (file mới `happy-path.e2e-spec.ts`, dùng chung `apps/wms/test/jest-e2e.json`) — cần Mongo replica-set + Redis chạy thật, người dùng tự chạy sau khi bật hạ tầng.
- `pnpm seed:wms` — chạy thủ công 1 lần, kiểm tra idempotent bằng cách chạy 2 lần liên tiếp không lỗi/không tạo trùng.
- Không thêm unit test riêng cho seed script (nó là script vận hành, không phải business logic — theo `CLAUDE.md` không cần abstraction/test thừa cho một-lần-chạy).

## Rủi ro

- Không thể tự chạy e2e trong phiên này → mọi lỗi runtime thực tế (vd sai tên field DTO, thiếu await, race condition BullMQ) chỉ lộ ra khi người dùng chạy thật. Sẽ review kỹ tối đa bằng cách đọc source thật của từng DTO/schema trước khi viết, nhưng không thay thế được 1 lần chạy thật.

## Bug Bash Findings (S4-05)

Static code review (Task 6) trên 5 target đã nêu ở mục "4. Bug bash" — không chạy app thật, không sửa code. Kết luận: **không tìm thấy defect nào** trên happy-path. Cả 3 service ghi tồn (GRN confirm, put-away confirm-line, stock-count approve, goods-issue confirm-line) đều đã dùng `withStockTransaction` đúng cách ở call-site (xác nhận trong lúc viết plan) — review lần này bổ sung: mọi write bên trong từng callback đều **forward `session` đến tận Mongoose call**, không có write nào "thoát" transaction. Deeper correctness (concurrent writes thật, race condition dưới tải) không thể xác minh tĩnh — cần người dùng tự chạy e2e/tải thật.

Chi tiết theo từng target:

1. **`apps/wms/src/put-away-suggestion/put-away-suggestion.service.ts` — `fits()` (dòng 109-116)** — Confirmed-no-issue. Trace tay 2 kịch bản: (a) shelf không khai kích thước (`innerDepth/innerWidth/innerHeight` đều `undefined` → coerce `?? 0` → `shelfDims=[0,0,0]`) — vì `suggest()` đã chặn sớm ở dòng 50-52 (`if (!item.depth || !item.width || !item.height) return ITEM_NO_DIMENSIONS`) nên `itemDims` truyền vào `fits()` luôn có 3 số dương thật, mọi so sánh `d <= 0` đều false → `fits()` trả `false` đúng, không false-positive. (b) Kịch bản tổng quát hơn: item 25×25×2 vs shelf inner 30×3×30 → sort desc cả hai `[25,25,2]` vs `[30,30,3]`, so từng cặp đều `<=` → `true`; kiểm tra geometry thật (2 phải khớp trục 3 của shelf, 25/25 khớp 2 trục 30) xác nhận đây **là** một phép xoay trục hợp lệ thật — không phải false-positive. Về lý thuyết: sort-descending-rồi-so-từng-cặp là thuật toán **đúng hoàn toàn** (không chỉ là "heuristic") cho bài toán "có tồn tại hoán vị trục nào để hộp vừa container" khi giới hạn ở 6 phép xoay trục-thẳng (axis-aligned) — đây đúng là mô hình đặt hàng lên kệ. Severity: Confirmed-no-issue.

2. **`apps/wms/src/goods-receipt-note/goods-receipt-note.service.ts::confirmGoodsReceiptNote` (transaction callback dòng 158-253)** — Confirmed-no-issue. Trace từng write trong callback: `stockRepo.upsertBalance` (dòng 200-207, session ✓), `stockRepo.upsertInventory` (212-219, session ✓), `stockRepo.insertMovement` (220-233, session ✓), `purchaseOrderService.applyReceivedQty` (234-239, session ✓ — forward tiếp xuống `repo.findPurchaseOrderByIdWithSession` và `repo.applyReceivedQtyAndStatus`, cả hai đều nhận `session` và truyền vào Mongoose option), `putAwayService.createTaskFromGrn` (244-250, session ✓ → `repo.createTask` dùng `model.create([...], { session })`), `repo.updateStatusConfirmed` (252, session ✓ → `findOneAndUpdate(..., { session })`). Không có write nào thiếu `session`. Severity: Confirmed-no-issue.

3. **`apps/wms/src/put-away/put-away.service.ts::confirmLine` (transaction callback dòng 118-173)** — Confirmed-no-issue. Cả 6 write trong callback (`upsertInventory` staging −qty, `upsertInventory` shelf đích +qty, `insertMovement` PUTAWAY staging, `insertMovement` PUTAWAY đích, `repo.decrementRemainingQty`, `repo.markCompletedIfAllDone`) đều forward `session` đến Mongoose. Về câu hỏi quantity=0 ở `InventoryStock`: `upsertInventory` dùng `$inc` qua `findOneAndUpdate(..., { upsert: true })` — **không bao giờ xoá row**, nên khi trừ hết về đúng 0, row vẫn tồn tại với `quantity: 0`. Unique index của `InventoryStock` là `{itemId, warehouseId, shelfId, lotId}` (`inventory-stock.schema.ts` dòng 37-40) — **không** gồm `quantity` — nên lần put-away kế tiếp về cùng staging shelf sẽ khớp đúng row 0 sẵn có qua `findOneAndUpdate` (match theo 4 khoá đó) và `$inc` tiếp, không tạo insert mới → không có nguy cơ vi phạm unique index. `assertTwoLayerInvariant` (e2e Task 3) cũng không bị ảnh hưởng vì row `quantity:0` đóng góp đúng 0 vào tổng dù còn tồn tại hay bị xoá. Severity: Confirmed-no-issue.

4. **`apps/wms/src/goods-issue/order-ready.consumer.ts` + `goods-issue.service.ts::createFromOrderReady` (dòng 46-88)** — Confirmed-no-issue, nhưng khác với giả thuyết nêu trong brief. Đọc kỹ thân hàm: vòng lặp `for (const item of items)` (dòng 61-74) **chỉ đọc** (`stockRepo.findItemBySku` — không có write nào trong vòng lặp này, sku không khớp thì `continue` chứ không throw). `repo.createGoodsIssue` chỉ được gọi **đúng 1 lần** (dòng 83-87), sau khi vòng lặp resolve toàn bộ `lines` đã hoàn tất — không có ghi từng dòng riêng lẻ bên trong loop. Vì vậy kịch bản "tạo GoodsIssue rồi throw giữa chừng ở item sau, để lại doc dở dang chặn future retry" **không xảy ra được với code hiện tại**: nếu có lỗi thật trong loop (vd `findItemBySku` throw exception hạ tầng như mất kết nối Mongo) thì nó throw TRƯỚC khi `createGoodsIssue` từng được gọi — không có doc nào được tạo, nên guard `findByOrderId` đầu hàm vẫn cho retry chạy lại sạch, đúng ý đồ idempotent. Đây không phải bug — brief nêu giả thuyết nhưng code không khớp shape đó (không có write nào trong loop để "một phần" thất bại). Severity: Confirmed-no-issue (giả thuyết trong brief không áp dụng được cho code thật).

5. **`apps/wms/src/stock-count/stock-count.service.ts::approveStockCount` (dòng 179-267)** — Confirmed-no-issue. `delta` được tính ở `stock-count.repository.ts` dòng 124: `line.delta = actualQty - line.systemQty` — đúng công thực actualQty − systemQty như brief yêu cầu (dương nếu đếm được nhiều hơn hệ thống ghi nhận, âm nếu ít hơn). `approveStockCount` dùng thẳng `delta` này cho cả `upsertInventory`, `upsertBalance` (onHandDelta), và `insertMovement` với `type: MovementType.ADJUST, quantity: delta` (dòng 231-232) — không đảo dấu, không tính lại. Khớp đúng quy ước "quantity có dấu: + = tăng tồn, − = giảm tồn" ở `stock-movement.schema.ts` dòng 18/42 (comment nêu ví dụ RECEIVE/ISSUE nhưng quy ước dấu áp dụng chung mọi `MovementType`, và ADJUST tuân thủ đúng). Mọi write trong transaction callback (dòng 202-246) đều forward `session`. Severity: Confirmed-no-issue.

**Kiểm tra chéo bổ sung (theo constraint global của plan, không phải mục riêng trong brief nhưng liên quan):**
- Grep toàn bộ 5 file service/consumer trên: không có `throw new BadRequestException/NotFoundException/UnauthorizedException/ConflictException/ForbiddenException` nào — mọi throw đều qua `AppException('CODE')`. Confirmed-no-issue.
- Grep `movementModel.` trong toàn bộ `apps/wms/src`: chỉ có `.create(...)` (qua `insertMovement`), không có `updateOne`/`findOneAndUpdate` nào chạm `StockMovement` — bất biến append-only của sổ cái được giữ nguyên. Confirmed-no-issue.

**Tổng kết:** 0 Critical, 0 Important, 0 Minor, 5 Confirmed-no-issue (đúng 5/5 target trong brief) + 2 kiểm tra chéo bổ sung cũng Confirmed-no-issue. Review này là **static-only** — không phát hiện bug logic nào trên happy-path, nhưng hành vi runtime dưới ghi đồng thời thật (race condition, lock contention Mongo transaction, BullMQ redelivery thật) chưa được xác minh và nằm ngoài phạm vi review tĩnh — đề nghị người dùng tự chạy `pnpm test:e2e` + 1 lượt demo thật để chốt.
- `PurchaseOrderStatus` default `CONFIRMED` ngay khi tạo (theo Explore report) — nghĩa là không có bước "xác nhận PO" riêng trong happy-path dù workflow doc mô tả có; test theo đúng code, không theo doc.
