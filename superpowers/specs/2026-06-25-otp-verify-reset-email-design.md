# Spec: OTP verify/reset + email qua Resend (ecom auth + notification)

> Trạng thái: ✅ Đã chốt thiết kế (brainstorm 2026-06-25) — đầu vào cho `writing-plans`.
> Phạm vi **liên-app**: đổi verify email / reset mật khẩu của khách từ **magic-link token** sang **mã OTP 6 số nhập tay**, và hiện thực hóa app **notification** gửi email thật bằng **Resend** (React Email).

## 1. Bối cảnh & mục tiêu

Hiện trạng (code thật):

- **Ecom auth** đã phát 2 event vào `notification-queue`: `customer.verify_requested`, `customer.password_reset_requested`, payload `{ customerId, email, token }` với `token = generateOpaqueToken(48)` (~64 ký tự base64url). Verify/reset tra cứu **chỉ bằng token** (token toàn cục là duy nhất).
- **Notification** là **stub** — consumer chỉ `logger.log`, chưa gửi email/SMS/push. Firebase Admin đã wire (FCM), **chưa có** email provider, **không có DB**.
- `payment.success`, `stock.low`, `stock.near_expiry` đã khai báo nhưng **producer chưa build** → ngoài phạm vi đợt này.

Mục tiêu: khách verify email và đặt lại mật khẩu bằng **mã OTP 6 số** gõ tay, mã được gửi qua **email Resend**. Notification trở thành consumer gửi email thật cho 2 event đang chạy.

> Quyết định "mã nhập tay" (thay vì link) là lựa chọn của chủ dự án để frontend đơn giản (1 ô input). Đánh đổi: phần backend ecom auth nặng hơn (bảo mật OTP). Hai phần phải ship cùng nhau.

## 2. Ràng buộc & bất biến (phải giữ)

- **DB-per-app, không đọc chéo.** OTP lưu trong **Redis (keyspace của ecom)** — chọn vì OTP là dữ liệu phù du, dùng-một-lần, TTL gốc của Redis hợp đúng "chất". Notification **không** có DB, **không** lưu mã.
- **Không lưu mã gốc.** Trong Redis chỉ lưu `hashToken(code)` (sha256), không lưu plaintext.
- **Redis dùng chung cluster với BullMQ** (cùng `REDIS_HOST/PORT/PASSWORD` từ `@app/events`), nhưng OTP nằm ở keyspace riêng (`otp:*`) của ecom — không phải dữ liệu xuyên app. Đây là pattern mới (trước nay Redis chỉ làm transport BullMQ), chấp nhận có chủ đích.
- **Auth tách app, secret riêng** — không đụng cơ chế JWT.
- **Cross-cutting chuẩn `@app/common`**: response/error envelope, `AppException`, `@AuthThrottle()`, Zod env validation. Code mới phải theo.
- **Notification vẫn là consumer thuần**: `@Processor(QUEUES.NOTIFICATION)`, không phát event, không DB.

## 3. Contract event (`libs/events`)

`CustomerEmailActionPayload`: đổi field `token` → **`code`** (giữ `customerId`, `email`). Tên event không đổi.

```ts
export interface CustomerEmailActionPayload {
  customerId: string;
  email: string;
  code: string; // mã OTP 6 số (plaintext, chỉ để notification ghép vào email)
}
```

> `code` plaintext đi ngang qua payload event chỉ để notification soạn email. Nguồn sự thật để verify là bản ghi (đã hash) trong `customer_auth_tokens`.

## 4. Ecom auth — sinh & xác thực OTP (phần chính)

### 4.1 OtpStore (gói gọn Redis) — đơn vị mới trong ecom
Một service `OtpStore` đóng gói toàn bộ key layout + thao tác Redis, để `AuthService` không chạm trực tiếp Redis. Dùng `ioredis` (client mới ở ecom), cấu hình từ `redisConfig` của `@app/events` (host/port/password).

- **Key**: `otp:{type}:{customerId}` (`type` ∈ `verify_email` | `reset_password`).
- **Value**: Redis hash `{ codeHash, attempts }`.
- **Interface**:
  - `issue(customerId, type, code)`: pipeline `DEL key` → `HSET key codeHash=hashToken(code) attempts=0` → `EXPIRE key OTP_TTL_SEC`. Ghi đè ⇒ mỗi khách/type **1 mã sống** + **TTL gốc** tự hết hạn.
  - `verify(customerId, type, code)`: `HGETALL key`. Rỗng → `INVALID`. So `hashToken(code)` với `codeHash`:
    - sai → `HINCRBY key attempts 1`; nếu `attempts >= OTP_MAX_ATTEMPTS` → `DEL key`; trả `INVALID`.
    - đúng → `DEL key`; trả `OK`.

> `customer_auth_tokens` (Mongo) **không còn dùng** cho verify/reset. Để lại schema/repo cũng được (vô hại) hoặc dọn sau — YAGNI, plan sẽ chỉ ngừng dùng, không bắt buộc xóa.

### 4.2 Hằng số (đặt trong service, YAGNI env)
- `OTP_LENGTH = 6`
- `OTP_TTL_SEC = 600` (10 phút, cho cả verify lẫn reset)
- `OTP_MAX_ATTEMPTS = 5`

### 4.3 Sinh mã (`sendEmailAction`)
1. Sinh mã 6 số bằng `crypto.randomInt(0, 1_000_000)` → `padStart(6, '0')`.
2. `otpStore.issue(customerId, type, code)` (tự ghi đè mã cũ + đặt TTL).
3. Emit event `{ customerId, email, code }` với job option **`removeOnComplete: true`** (xóa mã plaintext khỏi job data trong Redis sau khi gửi xong).

### 4.4 Xác thực (verify & reset)
Mã 6 số **không duy nhất** → phải khoanh theo khách (qua `email`):

- `POST /auth/verify-email` (public): body đổi `{ token }` → **`{ email, code }`**.
- `POST /auth/reset-password` (public): body đổi `{ token, newPassword }` → **`{ email, code, newPassword }`**.

Luồng chung:
1. Resolve khách theo `email`. Không thấy → trả lỗi/thông điệp **trung lập** (reset: giữ `NEUTRAL_RESET_MESSAGE`; verify: lỗi chung, không lộ email tồn tại).
2. `otpStore.verify(customerId, type, code)`:
   - `INVALID` → lỗi "mã không đúng hoặc đã hết hạn" (đã gộp cả hết-hạn, sai, hết-lần).
   - `OK` → thực hiện verify (markEmailVerified) / reset (updatePassword + `revokeAllForCustomer`).

### 4.5 Rate-limit
Đảm bảo `@AuthThrottle()` (5/60s) trên `verify-email`, `reset-password`, `forgot-password`, `resend-verify-email`.

### 4.6 Endpoint không đổi interface
- `forgot-password` `{ email }` → vẫn neutral, nội bộ sinh mã reset.
- `resend-verify-email` (authenticated) → re-sinh mã verify (hủy mã cũ).

## 5. Notification — email OTP (phần gọn)

### 5.1 Cấu trúc mới `apps/notification/src/`
```
email/
  email.module.ts        # provider EmailService (đọc config Resend)
  email.service.ts       # send({to,subject,react,idempotencyKey}); tắt mềm nếu thiếu RESEND_API_KEY
  templates/
    verify-email.tsx      # React Email: hiển thị mã 6 số + hạn dùng
    reset-password.tsx    # React Email: hiển thị mã 6 số + hạn dùng
notification.consumer.ts  # verify/reset → chọn template + EmailService.send
```

### 5.2 EmailService
- Bọc Resend SDK; gửi qua `resend.emails.send({ from, to, subject, react }, { idempotencyKey })`.
- `idempotencyKey = job.id` → BullMQ retry cùng job ⇒ cùng key ⇒ Resend dedupe server-side.
- **Tắt mềm**: thiếu `RESEND_API_KEY` (hoặc `RESEND_FROM`) → `logger.warn` + bỏ qua, không crash (để dev không cần Resend vẫn chạy app).

### 5.3 Consumer
- `customer.verify_requested` → template `verify-email` với `code` + `email`.
- `customer.password_reset_requested` → template `reset-password`.
- Event chưa có producer (`payment.success`, `stock.low`, `stock.near_expiry`) → **giữ log + TODO**.
- Job lạ → `logger.warn` (không throw).

### 5.4 Template
React Email (JSX): hiển thị **mã 6 số** to/rõ, kèm câu "mã hết hạn sau 10 phút", tiếng Việt. **Không link, không `ECOM_WEB_URL`.**

## 6. Config / build

- **Notification env** (Zod, optional): `RESEND_API_KEY`, `RESEND_FROM` (vd `'WMS Shop <no-reply@domain>'`). Thêm vào `.env.example` + `.env.production.example`. **Không** thêm `ECOM_WEB_URL`.
- **Deps notification**: `resend`, `@react-email/components`, `react`.
- **Deps ecom**: `ioredis` (client Redis trực tiếp cho `OtpStore`). Ecom env đã có `REDIS_HOST/PORT/PASSWORD` (dùng cho BullMQ) → tái dùng, không thêm env mới.
- **Build TSX**: thêm `"jsx": "react-jsx"` **chỉ trong** `apps/notification/tsconfig.app.json` (không đụng 2 app kia). Verify bằng `nest build notification` sau khi code.
- **Docker**: deps nằm trong `dependencies` (không devDependencies) → stage `--prod` của image vẫn có. Không sửa Dockerfile.

## 7. Bảo mật & lỗi

Mã 6 số entropy thấp (1M tổ hợp) → bù bằng tổ hợp kiểm soát:
- **Hạn ngắn** (10 phút, TTL gốc của Redis tự hết hạn) + **1 mã sống/khách/type** (ghi đè key) + **dùng-một-lần** (`DEL` sau khi đúng).
- **Giới hạn 5 lần thử** (`attempts` trong Redis hash) rồi `DEL` mã.
- **Rate-limit** endpoint nhập mã.
- **`removeOnComplete`** xóa mã plaintext khỏi job data (Redis) sau khi gửi.
- **Idempotency** khi gửi email (Resend key).
- Lưu ý đã chấp nhận: chỉ lưu `hashToken(code)` (sha256) trong Redis — đủ cho mã ngắn-hạn + dùng-một-lần + giới hạn thử (bcrypt mã là YAGNI). `code` plaintext có mặt tạm trong job data tới khi gửi xong (đã giảm bằng `removeOnComplete` + TTL ngắn). OTP và job BullMQ **cùng cluster Redis** nhưng khác keyspace — không ảnh hưởng nhau.

## 8. Test

- **Ecom (unit)**: `OtpStore` (mock ioredis hoặc ioredis-mock): issue ghi đè + set TTL, verify đúng / sai (`attempts++`) / hết-lần (`DEL`) / không-có-key. `AuthService` (mock `OtpStore`): verify/reset gọi đúng, reset revoke refresh, forgot neutral.
- **Notification (unit)**: consumer gọi `EmailService.send` với đúng `code`/`to`/`idempotencyKey=job.id`; template render ra mã 6 số; nhánh tắt-mềm khi thiếu `RESEND_API_KEY`.
- **E2E** cần Mongo/Redis → `describe.skip` (theo lệ dự án).

## 9. Ngoài phạm vi (YAGNI)

- Email cho `payment.success` / `stock.*` (producer chưa build).
- Push FCM (cần kho device token).
- SMS.
- Đưa OTP TTL / max-attempts ra env (để hằng số trong code).
- Đổi `hashToken` sang bcrypt cho mã.
