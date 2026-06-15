# Chuẩn hóa cross-cutting: response / error / logging / throttle / pagination

> Spec thiết kế — 2026-06-15. Áp cho cả 3 app (wms, ecommerce, notification).
> Tất cả tiện ích dùng chung đặt ở `libs/common` (`@app/common`), wiring đồng nhất qua 1 helper bootstrap.

## Mục tiêu

Chuẩn hóa các mối quan tâm xuyên suốt (cross-cutting) để mọi app cùng một hợp đồng với client:

1. **Envelope response thành công** thống nhất `{ data, meta }`.
2. **Mã lỗi nghiệp vụ** chuỗi ổn định + shape lỗi chuẩn.
3. **Logging structured** (nestjs-pino) có correlation id, log cả request & response (kèm redaction).
4. **Throttle phân tầng** (default + auth), số lấy từ env.
5. **Phân trang** 3 dạng: không phân trang / cursor keyset (mặc định API chính) / offset (màn admin).

Nguyên tắc: tiện ích dùng chung ở `libs/common`, mã miền riêng ở từng app. Không lệch chuẩn giữa 3 app — dùng helper bootstrap chung.

## Quyết định đã chốt (từ brainstorming)

| Chủ đề | Quyết định |
|---|---|
| Envelope success | **A** — bọc MỌI response: `{ data, meta: { requestId, timestamp } }` |
| Mã lỗi | **A** — `code` chuỗi nghiệp vụ; catalog chung ở `libs/common` + mã miền mỗi app |
| Logging | **A** — `nestjs-pino`, correlation id, log cả request & response + redaction |
| Throttle | **A** — phân tầng `default` + `auth` (5/60s), số từ env |
| Pagination | Cursor keyset chuẩn = mặc định API chính; offset cho admin, `totalItems/totalPages` **optional** |

Mặc định tự chốt: `VALIDATION_FAILED` = HTTP 400; `auth` throttle = 5 req/60s/IP; ngưỡng cắt log response body = 10KB; dùng `setupApp()` helper chung.

---

## 1. Envelope response thành công

`ResponseInterceptor` (đăng ký global) bọc giá trị controller trả về:

```jsonc
{
  "data": <payload>,
  "meta": { "requestId": "01J...", "timestamp": "2026-06-15T10:00:00.000Z" }
}
```

- `requestId`: lấy từ logger (đọc header `X-Request-Id` nếu client gửi, không thì sinh mới). Cùng một id xuất hiện ở log và ở response lỗi → trace 1 request xuyên suốt.
- `timestamp`: ISO 8601 thời điểm tạo response.
- Nếu controller trả về `PaginatedResult<T>` (marker class, xem §5), interceptor gộp khối `pagination` vào `meta`.
- `@RawResponse()` decorator để **opt-out** khỏi bọc — dùng cho webhook/payment callback cần shape nguyên bản theo yêu cầu cổng ngoài.

**File:**
- `libs/common/src/interceptors/response.interceptor.ts`
- `libs/common/src/decorators/raw-response.decorator.ts`
- (bỏ `interceptors/logging.interceptor.ts` cũ — pino lo phần này)

## 2. Mã lỗi & exception filter

### Catalog chung — `libs/common/src/errors/error-codes.ts`

Mỗi code map sẵn HTTP status + message mặc định (tiếng Việt):

| code | HTTP | Ý nghĩa |
|---|---|---|
| `VALIDATION_FAILED` | 400 | Input sai (class-validator) |
| `UNAUTHENTICATED` | 401 | Thiếu/sai token |
| `FORBIDDEN` | 403 | Không đủ quyền |
| `NOT_FOUND` | 404 | Không tìm thấy tài nguyên |
| `CONFLICT` | 409 | Xung đột trạng thái |
| `RATE_LIMITED` | 429 | Vượt throttle |
| `INTERNAL` | 500 | Lỗi nội bộ (giấu chi tiết) |

### Mã miền mỗi app — `apps/<app>/src/common/error-codes.ts`

Ví dụ: `AUTH_INVALID_CREDENTIALS`, `STOCK_INSUFFICIENT`, `ORDER_NOT_CANCELLABLE`, `STOCK_RESERVE_FAILED`. Chỉ là hằng chuỗi; `AppException` nhận mọi chuỗi code.

### `AppException` — `libs/common/src/errors/app.exception.ts`

`extends HttpException`, mang `code`, `message`, `details?`, `status`. Ném gọn:

```ts
throw new AppException('STOCK_INSUFFICIENT', 'Không đủ tồn cho SKU ABC', 409, [
  { field: 'quantity', issue: 'available=3 < requested=5' },
]);
```

Nếu không truyền status → lấy status mặc định theo code trong catalog.

### `AllExceptionsFilter` (viết lại) — output chuẩn

```jsonc
{
  "error": { "code": "STOCK_INSUFFICIENT", "message": "...", "details": [...] },
  "meta": { "requestId": "01J...", "timestamp": "...", "path": "/api/wms/..." }
}
```

Quy tắc map:
- `AppException` → dùng nguyên `code/message/details/status`.
- `ValidationPipe` (BadRequestException từ class-validator) → `VALIDATION_FAILED`, `details` = danh sách lỗi field.
- `ThrottlerException` → `RATE_LIMITED`.
- `HttpException` khác (Unauthorized/Forbidden/NotFound từ guard) → map theo status sang code tương ứng.
- Lỗi lạ (không phải HttpException) → `INTERNAL`, giấu chi tiết khỏi client, **log full stack** (5xx).
- `requestId` lấy từ logger context để khớp với log.

## 3. Logging (nestjs-pino)

- `buildPinoOptions(config)` dùng chung ở `libs/common/src/logging/pino.options.ts`; mỗi app import `LoggerModule.forRootAsync` dùng helper này.
- `genReqId`: đọc header `x-request-id`, không có thì sinh UUID; set vào header response `X-Request-Id`. Đây là nguồn `requestId` cho envelope (§1) và lỗi (§2).
- **autoLogging**: log request khi đến và response khi xong (method, url, status, thời gian).
- **Log body request & response** với **redaction** che các path nhạy cảm:
  - `req.body.password`, `req.body.refreshToken`, `req.body.token`, `req.body.otp`, `req.body.currentPassword`, `req.body.newPassword`
  - `req.headers.authorization`, `req.headers.cookie`
  - Giá trị che thay bằng `"[REDACTED]"`.
- **Ngưỡng cắt response body**: > 10KB hoặc array > 50 phần tử → chỉ log metadata (kích thước / số phần tử), không log full → tránh log phình & rò dữ liệu khối lượng lớn.
- Dev: transport `pino-pretty` (đọc dễ). Prod: JSON 1 dòng (đẩy Loki/ELK sau). Mức log theo env `LOG_LEVEL` (default `info`).
- Bỏ `LoggingInterceptor` thủ công hiện tại.

**Dependencies thêm:** `nestjs-pino`, `pino-http`, `pino-pretty` (dev).

## 4. Throttle phân tầng

- `ThrottlerModule.forRootAsync` khai báo named throttlers:
  - `default`: `THROTTLE_DEFAULT_LIMIT` (mặc định 100) / `THROTTLE_DEFAULT_TTL` (60s)
  - `auth`: `THROTTLE_AUTH_LIMIT` (mặc định 5) / `THROTTLE_AUTH_TTL` (60s)
- `@AuthThrottle()` (`libs/common/src/decorators/throttle.decorators.ts`) áp tầng `auth` lên: login, register, refresh, forgot-password, reset-password.
- `@SkipThrottle()` (sẵn của `@nestjs/throttler`) cho health check.
- Global `ThrottlerGuard` (đã có ở mỗi app module) giữ nguyên. `ThrottlerException` → `RATE_LIMITED` ở filter.
- Cấu hình từ env → tinh chỉnh không cần build lại.

## 5. Phân trang — `libs/common/src/pagination/`

### Không phân trang
Trả thẳng theo envelope §1: `{ data: [...], meta }`.

### Cursor keyset (mặc định API chính)
- DTO `CursorPaginationQuery`: `limit` (default 20, max 100), `cursor?` (chuỗi opaque). class-validator + transform.
- `encodeCursor(obj)` / `decodeCursor(str)`: base64url JSON của `{ sortValue, _id }`. **Opaque** — không lộ field nội bộ.
- `buildKeysetFilter({ sortField, direction, cursor })`: dựng filter Mongo theo keyset (so sánh `(sortValue, _id)` với cursor), **KHÔNG dùng `skip`** → nhanh & ổn định khi data đổi.
- Lấy `limit + 1` bản ghi để biết `hasNext`; cắt còn `limit`, build `nextCursor` từ phần tử cuối.
- Meta:
```jsonc
"pagination": { "type": "cursor", "limit": 20, "nextCursor": "eyJ...", "hasNext": true }
```

### Offset (màn admin cần số trang)
- DTO `OffsetPaginationQuery`: `page` (default 1, min 1), `limit` (default 20, max 100).
- `buildOffsetMeta(items, page, limit, totalItems?)`:
  - `totalItems` truyền vào (đã `count`) → tính `totalPages`, `hasPrev`, `hasNext`.
  - `totalItems` bỏ trống → chỉ `page/limit/hasNext` (suy từ số phần tử trả về). Tránh query `count` khi không cần.
- Meta:
```jsonc
"pagination": { "type": "offset", "page": 1, "limit": 20,
                "totalItems": 137, "totalPages": 7, "hasNext": true, "hasPrev": false }
```

### Marker
- `PaginatedResult<T>` (class chứa `items` + `pagination`) — controller trả về để `ResponseInterceptor` nhận diện và gộp `pagination` vào `meta`, đặt `items` thành `data`.

## 6. Wiring & cấu trúc

- `setupApp(app, { corsOrigins, isProd, globalPrefix })` ở `libs/common/src/bootstrap/setup-app.ts`: helmet + cors (`buildCorsOptions`) + `ValidationPipe` + global `AllExceptionsFilter` + global `ResponseInterceptor` + `useLogger(pino)` + `enableShutdownHooks`. Mỗi `main.ts` chỉ gọi 1 dòng → không lệch chuẩn 3 app.
- Root module mỗi app: thêm `LoggerModule.forRootAsync(buildPinoOptions)` và đổi `ThrottlerModule` sang named throttlers từ env.
- Env schema (Zod, theo quy ước `env-validation-zod`) 3 app bổ sung: `LOG_LEVEL`, `THROTTLE_DEFAULT_LIMIT/TTL`, `THROTTLE_AUTH_LIMIT/TTL`. Cập nhật `.env.example`.
- Export tất cả qua `libs/common/src/index.ts`.

## 7. Testing

- **Unit:**
  - `AppException` → `AllExceptionsFilter` cho ra đúng envelope `{ error, meta }` (gồm map ValidationPipe/Throttler/unknown).
  - `encodeCursor`/`decodeCursor` roundtrip; cursor hỏng → ném `VALIDATION_FAILED`.
  - `buildKeysetFilter` sinh đúng filter cho asc/desc.
  - `buildOffsetMeta` có/không `totalItems`.
  - Redaction: body chứa `password`/`authorization` bị che trong log.
- **e2e nhẹ:** gọi 1 endpoint thật → assert shape `{ data, meta.requestId }` + header `X-Request-Id`; gọi route lỗi → assert `{ error.code, meta }`.

## 8. Ngoài phạm vi (YAGNI)

- Throttle theo userId/key (chỉ theo IP).
- Đẩy log sang Loki/ELK (chỉ chuẩn JSON sẵn sàng, chưa wiring hạ tầng).
- i18n message lỗi (message tiếng Việt cố định; `code` để FE tự dịch nếu cần).
- Tracing phân tán (OpenTelemetry) — `requestId` đủ cho giai đoạn này.
