# Thiết kế: Tích hợp Cloudinary cho các nghiệp vụ cần ảnh

## Bối cảnh

Khảo sát toàn bộ codebase (`apps/wms`, `apps/ecommerce`, `libs/*`) cho thấy:

- **Chưa có tích hợp Cloudinary/Multer/S3/upload service nào** — không có trong `package.json`, không có trong `.env.example`.
- Một số schema/DTO đã có sẵn field kiểu `string` chứa URL ảnh, nhưng **chưa có endpoint upload thật** — API hiện tại chỉ nhận URL đã có sẵn từ đâu đó bên ngoài:
  - `Product.images: string[]` — `apps/ecommerce/src/catalog/schemas/product.schema.ts:37`
  - `Design.file` / `Design.thumbnail` — `apps/ecommerce/src/catalog/schemas/design.schema.ts`
  - `CartItem.designFile`, `OrderItem.designFile`, `PrintJobItem.designFile` — chỉ snapshot lại URL từ `Design`, không tự upload.
- Nghiệp vụ chứng từ WMS (GRN, GoodsReturn, ScrapNote, StockCount) **hoàn toàn chưa có khái niệm ảnh minh chứng**, dù đây là nhu cầu thực tế phổ biến trong vận hành kho (chụp ảnh hàng lỗi, ảnh lệch tồn, ảnh hàng trả...).
- `User` (WMS, `apps/wms/src/auth/schemas/user.schema.ts`) và `User` (Ecom/customer, `apps/ecommerce/src/auth/schemas/user.schema.ts`) đều chưa có field avatar.
- Repo đã có **tiền lệ rõ ràng** cho việc tích hợp 1 SDK bên thứ 3 dùng chung toàn hệ thống: `libs/common/src/firebase/firebase-admin.module.ts` — `@Global() @Module` đọc config qua `ConfigService`, expose 1 service duy nhất. Cloudinary sẽ đi theo đúng pattern này.

## Mục tiêu

Bổ sung khả năng upload ảnh lên Cloudinary cho các nghiệp vụ thực sự cần, theo đúng 4 luật bất biến của kiến trúc (mỗi app tự quản lý ảnh của mình, không đọc chéo DB, DTO tách request/response, lỗi qua `AppException`).

**Không mục tiêu:** không xây dựng UI, không làm image transformation/CDN nâng cao (crop, watermark...) ở giai đoạn này — chỉ upload + lưu URL + trả về.

## Kiến trúc tổng thể

```
apps/wms ──┐                      ┌── Cloudinary (cloud lưu ảnh)
           ├──▶ CloudinaryModule ─┤
apps/ecommerce ┘  (libs/common)   └── trả về secure_url, public_id
```

- **`CloudinaryModule`** đặt tại `libs/common/src/cloudinary/`, export qua `@app/common`, giống hệt cấu trúc `firebase/`.
- Mỗi app tự có **1 `UploadController` (hoặc thêm endpoint vào controller domain có sẵn)** nhận `multipart/form-data` qua `FileInterceptor` (từ `@nestjs/platform-express`, cần thêm dependency `multer` + `@types/multer`), gọi `CloudinaryService.uploadImage(buffer, folder)`, trả về URL để FE lưu vào field tương ứng.
- **Không tự động xoá ảnh cũ trên Cloudinary khi field bị ghi đè** ở giai đoạn này (out of scope — tránh side-effect phá vỡ ảnh đang dùng chung, vd `Design` tái sử dụng nhiều đơn).
- Ảnh tổ chức theo folder Cloudinary riêng từng nghiệp vụ (`wms/grn`, `wms/goods-return`, `wms/scrap-note`, `wms/stock-count`, `ecom/products`, `ecom/designs`, `wms/avatars`, `ecom/avatars`) để dễ quản lý/dọn dẹp phía Cloudinary console.
- Giới hạn: chỉ nhận file ảnh (`image/jpeg`, `image/png`, `image/webp`), tối đa 5MB — validate ở `FileInterceptor` (fileFilter + limits), lỗi vượt giới hạn ném `AppException('VALIDATION_FAILED', ...)` qua exception filter có sẵn (multer lỗi bắt trong controller, không phải service).

## Danh sách issue (thứ tự phụ thuộc)

```
IMG-01 (hạ tầng — làm trước tất cả)
  ├─ IMG-02 (ảnh sản phẩm)
  ├─ IMG-03 (design ly-in)
  ├─ IMG-04 (GRN)
  ├─ IMG-05 (GoodsReturn)
  ├─ IMG-06 (ScrapNote)
  ├─ IMG-07 (StockCount)
  ├─ IMG-08 (avatar users/customers)
  └─ IMG-09 (backlog — Shipment POD)
```

---

### IMG-01 — Hạ tầng: CloudinaryModule dùng chung

**Vị trí code:** `libs/common/src/cloudinary/cloudinary.module.ts`, `cloudinary.service.ts`, export qua `libs/common/src/index.ts`.

**Nội dung:**
- Thêm dependency `cloudinary` (SDK chính thức), `multer`, `@types/multer` vào `package.json`.
- `CloudinaryModule` — `@Global() @Module`, cấu hình SDK bằng `CLOUDINARY_CLOUD_NAME` / `CLOUDINARY_API_KEY` / `CLOUDINARY_API_SECRET` đọc qua `ConfigService.getOrThrow` (theo đúng cách `DatabaseModule.forApp` và `firebase-credential.ts` đang đọc env).
- `CloudinaryService` với method `uploadImage(file: Buffer, folder: string): Promise<{ url: string; publicId: string }>` — dùng `cloudinary.uploader.upload_stream`.
- Thêm 3 biến env vào `.env.example` và `.env.production.example`.
- Thêm Zod schema validate 3 biến env mới (theo memory: dự án validate env bằng Zod trong `ConfigModule.forRoot({ validate })`).
- Import `CloudinaryModule` ở root module của `apps/wms` và `apps/ecommerce` (Notification không cần).
- Unit test cho `CloudinaryService` (mock SDK `cloudinary.uploader.upload_stream`).

**Acceptance criteria:**
- [ ] `CLOUDINARY_*` env thiếu → app fail-fast lúc boot (giống các `*_DATABASE_URL` khác), không fail âm thầm lúc gọi API.
- [ ] `CloudinaryService.uploadImage()` trả về `{ url, publicId }`, ném lỗi rõ ràng nếu SDK reject.
- [ ] Không app nào khác phải tự cấu hình SDK Cloudinary lần 2 — chỉ import module.

---

### IMG-02 — Ecommerce: Upload ảnh sản phẩm

**Phụ thuộc:** IMG-01.

**Vị trí code:** `apps/ecommerce/src/catalog/` (controller/service Product có sẵn).

**Nội dung:**
- Thêm endpoint `POST /api/shop/products/:id/images` (hoặc `POST /api/shop/products/images/upload` rồi FE tự gộp mảng URL vào `UpdateProductDto.images` — chọn theo REST hiện có của `ProductController`) — nhận `multipart/form-data` field `file`, upload qua `CloudinaryService` vào folder `ecom/products`, trả `ImageUploadResponseDto { url: string }`.
- Roles: giống các endpoint quản trị Product hiện có (admin/back-office) — không public.
- Response DTO mới `ImageUploadResponseDto` theo đúng convention `@Expose()` + `plainToInstance`.
- Swagger: `@ApiConsumes('multipart/form-data')`, `@ApiBody` khai schema `binary`.

**Acceptance criteria:**
- [ ] Upload thành công → URL Cloudinary hợp lệ, có thể set trực tiếp vào `Product.images[]` qua `PATCH` sẵn có.
- [ ] File không phải ảnh hoặc > 5MB → lỗi `VALIDATION_FAILED` theo `AppException`, không phải lỗi 500 thô từ multer.

---

### IMG-03 — Ecommerce: Upload Design ly-in

**Phụ thuộc:** IMG-01.

**Vị trí code:** `apps/ecommerce/src/catalog/` (Design đã có schema/DTO tại `design.schema.ts`, `dto/design.dto.ts`).

**Nội dung:**
- Thêm endpoint upload cho **artwork gốc** (`file`) — nhận `multipart/form-data`, upload Cloudinary folder `ecom/designs`.
- Sinh **thumbnail** tự động: dùng Cloudinary transformation URL (`f_auto,q_auto,w_300` qua chính `secure_url` gốc, không cần upload file riêng) — không cần xử lý ảnh phía server.
- Endpoint tạo `Design` (`create-design.dto.ts` nếu có, hoặc endpoint hiện có) nhận thẳng `file`/`thumbnail` đã upload, hoặc gộp luôn bước upload + tạo Design trong 1 call tuỳ theo controller hiện tại — quyết định cụ thể khi viết plan.
- **Không đụng vào** `CartItem.designFile` / `OrderItem.designFile` / `PrintJobItem.designFile` — các field này tiếp tục snapshot URL có sẵn từ `Design`, không có logic mới.

**Acceptance criteria:**
- [ ] Khách upload artwork → nhận về `file` (URL gốc) + `thumbnail` (URL biến thể nhỏ) để tạo `Design`.
- [ ] Chỉ chủ sở hữu (`customerId` khớp JWT) mới upload/gán design cho chính mình.

---

### IMG-04 — WMS: Ảnh minh chứng nhập kho (GRN)

**Phụ thuộc:** IMG-01.

**Vị trí code:** `apps/wms/src/goods-receipt-note/schemas/goods-receipt-note.schema.ts`, DTO, controller/service tương ứng.

**Nội dung:**
- Thêm field `images?: string[]` vào `GoodsReceiptNote` (cấp phiếu, không phải từng dòng item) — ảnh chụp kiện hàng/hàng lỗi lúc nhận.
- Endpoint upload ảnh gắn vào GRN theo id, folder Cloudinary `wms/grn`.
- Cập nhật `UpdateGoodsReceiptNoteDto`/response DTO tương ứng.
- Roles: RECEIVER (người tạo/xác nhận GRN theo rule hiện có).

**Acceptance criteria:**
- [ ] GRN có thể lưu 0..N ảnh minh chứng.
- [ ] Ảnh chỉ thêm được khi GRN chưa `APPROVED` (tránh sửa chứng từ đã duyệt — theo đúng tinh thần "chứng từ giao dịch hủy bằng status").

---

### IMG-05 — WMS: Ảnh hàng trả (GoodsReturn)

**Phụ thuộc:** IMG-01.

**Vị trí code:** `apps/wms/src/goods-return/schemas/goods-return.schema.ts`.

**Nội dung:**
- Thêm field `images?: string[]` vào **`GoodsReturnItem`** (không phải cấp phiếu) — vì tình trạng `GOOD`/`DAMAGED` được đánh giá **theo từng dòng hàng** lúc RECEIVER inspect (xem comment hiện có trong schema: "condition/shelfId/lotId là null cho tới khi RECEIVER inspect").
- Gắn ảnh cùng lúc với hành động inspect (cùng endpoint set `condition`, không tách endpoint riêng) — folder Cloudinary `wms/goods-return`.

**Acceptance criteria:**
- [ ] Khi RECEIVER set `condition=DAMAGED`, có thể đính kèm ảnh minh chứng cho đúng dòng đó.
- [ ] Ảnh optional — không chặn luồng inspect hiện có nếu RECEIVER không đính ảnh.

---

### IMG-06 — WMS: Ảnh bằng chứng hủy hàng (ScrapNote)

**Phụ thuộc:** IMG-01.

**Vị trí code:** `apps/wms/src/scrap-note/schemas/scrap-note.schema.ts`.

**Nội dung:**
- Thêm field `images?: string[]` vào **`ScrapNoteItem`** (mỗi dòng đề xuất hủy có `reason` riêng — ảnh nên đi kèm từng dòng, nhất quán với field `reason` sẵn có ở cùng cấp).
- Đính ảnh lúc tạo phiếu (COUNTER/RECEIVER tạo tay kèm toàn bộ dòng ngay từ đầu — không auto-generate).
- Folder Cloudinary `wms/scrap-note`.

**Acceptance criteria:**
- [ ] Ảnh optional theo từng dòng hủy.
- [ ] MANAGER xem được ảnh khi duyệt (`approveScrapNote`) — không bắt buộc phải có ảnh mới duyệt được (giữ nguyên luồng approve hiện tại).

---

### IMG-07 — WMS: Ảnh lệch tồn (StockCount)

**Phụ thuộc:** IMG-01.

**Vị trí code:** `apps/wms/src/stock-count/schemas/stock-count.schema.ts`.

**Nội dung:**
- Thêm field `images?: string[]` vào **`StockCountItem`** — đính kèm cùng lúc COUNTER nhập `actualQty`/`reason` cho dòng bị lệch (`delta !== 0`).
- Folder Cloudinary `wms/stock-count`.

**Acceptance criteria:**
- [ ] Chỉ dòng có `delta !== 0` mới cần khuyến khích đính ảnh (không bắt buộc ở tầng validate — để nghiệp vụ tự quyết).
- [ ] Không ảnh hưởng luồng đếm/approve hiện có.

---

### IMG-08 — WMS + Ecommerce: Avatar người dùng

**Phụ thuộc:** IMG-01.

**Vị trí code:**
- `apps/wms/src/auth/schemas/user.schema.ts` (nhân viên, collection `users` trong `wms_db`)
- `apps/ecommerce/src/auth/schemas/user.schema.ts` (khách hàng, collection `users` trong `ecom_db` — lưu ý: 2 collection cùng tên `users` nhưng khác DB, không nhầm lẫn)

**Nội dung:**
- Thêm field `avatarUrl?: string` vào cả 2 schema `User`.
- Mỗi app tự có endpoint `POST .../me/avatar` (WMS: `apps/wms/src/auth/`, Ecom: `apps/ecommerce/src/auth/`) — user tự upload avatar cho chính mình (theo JWT hiện có, không cần role đặc biệt).
- Folder Cloudinary: `wms/avatars` và `ecom/avatars` (tách riêng, đúng luật "mỗi app tự quản lý dữ liệu của mình").
- Cập nhật `UserResponseDto` (WMS) và `CustomerResponseDto` (Ecom) thêm `@Expose() avatarUrl`.

**Acceptance criteria:**
- [ ] Nhân viên WMS và khách hàng Ecom đều tự upload avatar qua endpoint riêng của app mình — không có endpoint dùng chung xuyên app.
- [ ] `avatarUrl` xuất hiện trong response `GET /me` tương ứng mỗi app.

---

### IMG-09 — Backlog: Ảnh POD giao hàng (Shipment)

**Phụ thuộc:** IMG-01. **Ưu tiên thấp — chỉ tạo issue để track, chưa lên chi tiết acceptance criteria.**

**Vị trí code:** `apps/wms/src/shipping/` (`Shipment` schema).

**Nội dung sơ bộ:** ảnh chụp bằng chứng giao hàng thành công (proof of delivery) khi carrier/nhân viên xác nhận `shipment.delivered`. Chi tiết thiết kế (ai chụp, chụp lúc nào, field cấp Shipment hay cấp status-history entry) để lại cho lúc brainstorm riêng khi ưu tiên tới.

---

## Testing

- Mỗi issue nghiệp vụ (IMG-02 → IMG-08): unit test cho phần validate/service logic (không test thật lên Cloudinary — mock `CloudinaryService`).
- IMG-01: unit test `CloudinaryService` mock SDK.
- Không cần E2E test upload thật (phụ thuộc network/Cloudinary that) trong phạm vi các issue này.

## Rủi ro / điểm mở

- **Không tự xoá ảnh cũ** khi field bị ghi đè — rác tích lũy trên Cloudinary theo thời gian. Chấp nhận ở giai đoạn này, có thể làm cleanup job sau nếu cần.
- **Giới hạn dung lượng free tier Cloudinary** — không thuộc phạm vi thiết kế kỹ thuật, cần theo dõi khi vận hành thật.
