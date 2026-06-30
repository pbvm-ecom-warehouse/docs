# S1-05: Notification Module Docs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Viết bộ tài liệu thiết kế đầy đủ cho module Notification — bao gồm use-cases, data-model, consumer-design, template-design, và idempotency-design — đủ để S4-04 (code thật) triển khai không cần đặt thêm câu hỏi kiến trúc.

**Architecture:** Notification app là **consumer thuần** (không DB, không phát event) trên `QUEUES.NOTIFICATION`. Hiện đã có code OTP email (verify/reset); tài liệu cần phủ thêm phần chưa code: `stock.low`, `stock.near_expiry`, `payment.success`, và push FCM. Tài liệu đặt tại `docs/notification/` theo cùng cấu trúc `warehouse/`, `catalog/`, v.v.

**Tech Stack:** Markdown, sơ đồ ASCII, NestJS BullMQ, Resend (React Email), Firebase Admin (FCM).

## Global Constraints

- Tài liệu phải nhất quán với code hiện tại trong `apps/notification/src/` (không đề xuất kiến trúc khác với những gì đã code)
- Tên event/payload lấy từ `libs/events/src/events.ts` — không tự sáng tác
- Idempotency key = `job.id` (đã dùng trong code) — tài liệu phải giải thích cơ chế này
- Notification KHÔNG có DB, KHÔNG đọc `wms_db` hay `ecom_db`
- Giữ tiếng Việt cho comment/giải thích (theo convention codebase)
- Sprint plan nói S4-04 mới là task code thật cho `stock.low`/`stock.near_expiry` — S1-05 chỉ thiết kế (docs)

---

## File Structure

| File | Trách nhiệm |
|---|---|
| `docs/notification/use-cases.md` | 5 use-cases: UC-N01…UC-N05 (verify email, reset password, payment, stock.low, stock.near_expiry) |
| `docs/notification/data-model.md` | Payload contract (từ `events.ts`), không có schema MongoDB; mô tả "no-DB design" |
| `docs/notification/consumer-design.md` | Kiến trúc consumer: `@Processor`, `switch(job.name)`, routing logic, graceful degradation khi provider tắt |
| `docs/notification/template-design.md` | Danh mục template (đã có + tương lai), design system màu/font, quy trình thêm template mới |
| `docs/notification/idempotency.md` | Cơ chế chống gửi trùng: `job.id` → Resend `idempotencyKey`; FCM deduplication; retry BullMQ 5 lần |

---

### Task 1: Tạo `docs/notification/use-cases.md`

**Files:**
- Create: `docs/notification/use-cases.md`

**Interfaces:**
- Consumes: payload từ `libs/events/src/events.ts` (`CustomerEmailActionPayload`, `PaymentSuccessPayload`, `StockLowPayload`, `StockNearExpiryPayload`)
- Produces: UC-N01–UC-N05 — các task sau tham chiếu tên UC này

- [ ] **Step 1: Tạo file `docs/notification/use-cases.md`**

```markdown
# Notification — Use Cases

## Tổng quan

Module Notification là **consumer thuần**: nhận event từ `notification-queue` (BullMQ), gửi thông báo qua Resend (email) hoặc Firebase Cloud Messaging (FCM push). Không có DB riêng, không phát event đi đâu.

| # | Tên | Trigger event | Kênh | Actor nhận | Trạng thái |
|---|---|---|---|---|---|
| UC-N01 | Gửi email xác minh tài khoản | `customer.verify_requested` | Email (Resend) | Khách hàng | ✅ Đã code |
| UC-N02 | Gửi email đặt lại mật khẩu | `customer.password_reset_requested` | Email (Resend) | Khách hàng | ✅ Đã code |
| UC-N03 | Gửi email xác nhận thanh toán | `payment.success` | Email (Resend) | Khách hàng | 📋 Thiết kế (S4-04) |
| UC-N04 | Cảnh báo tồn kho thấp | `stock.low` | Email + FCM push | MANAGER (nội bộ) | 📋 Thiết kế (S4-04) |
| UC-N05 | Cảnh báo hàng sắp hết hạn | `stock.near_expiry` | Email + FCM push | MANAGER (nội bộ) | 📋 Thiết kế (S4-04) |

> **Chú ý scope:** UC-N01 và UC-N02 đã được hiện thực hóa trong `apps/notification/`. UC-N03, UC-N04, UC-N05 được thiết kế ở đây để S4-04 code mà không cần phân tích lại kiến trúc.

---

## UC-N01: Gửi email xác minh tài khoản

**Trigger:** `customer.verify_requested` trên `notification-queue`  
**Kênh:** Email qua Resend  
**Actor nhận:** Khách hàng (address lấy từ `payload.email`)  
**Idempotency:** `job.id` → Resend `idempotencyKey` (BullMQ retry 5 lần không gửi trùng)

### Payload (`CustomerEmailActionPayload`)

```ts
{
  customerId: string;   // ObjectId khách hàng — chỉ để log, không dùng để gửi
  email: string;        // địa chỉ nhận
  code: string;         // OTP 6 số (plaintext, chỉ dùng để soạn email)
}
```

> `code` đi qua payload event ở dạng plaintext để Notification soạn email. Mã gốc để verify **không** lưu trong Notification (chỉ có hash trong Redis bên Ecom).

### Luồng chính

1. Consumer nhận job `customer.verify_requested`
2. Trích `{ email, code }` từ `job.data`
3. Soạn email dùng React Email template `VerifyEmail({ code })`
4. Gọi `EmailService.send({ to: email, subject: 'Mã xác minh email', react, idempotencyKey: job.id })`
5. Resend gửi email; lỗi → log, không throw (BullMQ sẽ retry theo schedule)

### Xử lý lỗi

| Tình huống | Hành vi |
|---|---|
| `RESEND_API_KEY` không cấu hình | `EmailService.send()` tắt mềm — log warn, không throw |
| Resend trả lỗi HTTP | Log error, throw để BullMQ retry (tối đa 5 lần) |
| Job không có `id` | Dùng fallback key `${job.name}:${Date.now()}` |

---

## UC-N02: Gửi email đặt lại mật khẩu

**Trigger:** `customer.password_reset_requested` trên `notification-queue`  
**Kênh:** Email qua Resend  
**Actor nhận:** Khách hàng  
**Payload:** `CustomerEmailActionPayload` (giống UC-N01)

### Luồng chính

1. Consumer nhận job `customer.password_reset_requested`
2. Soạn email dùng template `ResetPasswordEmail({ code })` (ô OTP màu đỏ để phân biệt với verify)
3. Gọi `EmailService.send(...)` với `idempotencyKey: job.id`

> Khác UC-N01: dùng template khác (màu đỏ cảnh báo hành động nhạy cảm). Logic xử lý lỗi giống hệt.

---

## UC-N03: Gửi email xác nhận thanh toán

**Trigger:** `payment.success` trên `notification-queue`  
**Kênh:** Email qua Resend  
**Actor nhận:** Khách hàng  
**Trạng thái:** 📋 Thiết kế — code trong S4-04

### Payload (`PaymentSuccessPayload`)

```ts
{
  orderId: string;         // mã đơn hàng — hiển thị trong email
  customerEmail: string;   // địa chỉ nhận
  amount: number;          // số tiền (VND) — hiển thị đã format
}
```

### Thiết kế template `PaymentSuccessEmail`

**File:** `apps/notification/src/email/templates/payment-success.tsx`

Nội dung email:
- Tiêu đề: "Thanh toán thành công — Đơn #{orderId}"
- Số tiền: format `Intl.NumberFormat('vi-VN', { style: 'currency', currency: 'VND' })`
- Màu accent xanh lá (`#16A34A`) để phân biệt với verify (xanh dương) và reset (đỏ)
- CTA: không cần link (order tracking chưa có frontend)

### Luồng chính

1. Consumer nhận `payment.success`
2. Trích `{ orderId, customerEmail, amount }` từ `job.data`
3. Soạn email `PaymentSuccessEmail({ orderId, amount })`
4. `EmailService.send({ to: customerEmail, subject: 'Thanh toán thành công', react, idempotencyKey: job.id })`

---

## UC-N04: Cảnh báo tồn kho thấp

**Trigger:** `stock.low` trên `notification-queue`  
**Producer:** WMS (sau khi `StockBalance.available` giảm xuống dưới ngưỡng `minQuantity`)  
**Kênh:** Email (gửi tới địa chỉ quản lý kho) + FCM push (nếu `FIREBASE_PROJECT_ID` cấu hình)  
**Actor nhận:** MANAGER kho (địa chỉ email đặt trong `WAREHOUSE_ALERT_EMAIL`)  
**Trạng thái:** 📋 Thiết kế — code trong S4-04

### Payload (`StockLowPayload`)

```ts
{
  sku: string;            // SKU cảnh báo
  warehouseId: string;    // kho bị ảnh hưởng
  available: number;      // số lượng hiện tại
  minQuantity: number;    // ngưỡng tối thiểu
}
```

### Env mới cần thêm

```
WAREHOUSE_ALERT_EMAIL=manager@company.com   # bắt buộc khi FCM hoặc email alert bật
```

> Cập nhật `apps/notification/src/config/env.validation.ts` khi code S4-04.

### Thiết kế template `StockLowAlertEmail`

**File:** `apps/notification/src/email/templates/stock-low-alert.tsx`

Nội dung:
- Tiêu đề: "⚠️ Tồn kho thấp — SKU: {sku}"
- Màu vàng/cam cảnh báo (`#D97706`)
- Hiển thị: SKU, kho, số hiện tại, ngưỡng tối thiểu, tỉ lệ % còn lại

### FCM push (nếu Firebase bật)

```ts
await firebaseService.getMessaging().send({
  topic: `stock_alert_${warehouseId}`,   // MANAGER subscribe topic này
  notification: {
    title: `Tồn kho thấp — ${sku}`,
    body: `Còn ${available}/${minQuantity} (${warehouseId})`,
  },
  data: { sku, warehouseId, available: String(available) },
});
```

> Topic naming: `stock_alert_{warehouseId}`. App mobile của MANAGER subscribe topic này khi đăng nhập. Không cần lưu FCM token trong Notification (dùng topic, không unicast).

### Luồng chính

1. Consumer nhận `stock.low`
2. Cast `job.data` → `StockLowPayload`
3. Nếu `emailService.isEnabled()` → gửi `StockLowAlertEmail` tới `WAREHOUSE_ALERT_EMAIL`
4. Nếu `firebaseService.isEnabled()` → gửi FCM push tới topic `stock_alert_{warehouseId}`
5. Nếu cả 2 đều tắt → log warn (không throw — cảnh báo không quan trọng bằng giao dịch)

---

## UC-N05: Cảnh báo hàng sắp hết hạn

**Trigger:** `stock.near_expiry` trên `notification-queue`  
**Producer:** WMS (job định kỳ quét lot sắp hết hạn, vd trong 7 ngày tới)  
**Kênh:** Email + FCM push  
**Actor nhận:** MANAGER kho  
**Trạng thái:** 📋 Thiết kế — code trong S4-04

### Payload (`StockNearExpiryPayload`)

```ts
{
  sku: string;          // SKU có lot sắp hết hạn
  lotNumber: string;    // số lô
  expiryDate: string;   // ISO 8601 — Notification format thành "dd/MM/yyyy"
}
```

### Thiết kế template `StockNearExpiryEmail`

**File:** `apps/notification/src/email/templates/stock-near-expiry.tsx`

Nội dung:
- Tiêu đề: "⏰ Lô hàng sắp hết hạn — SKU: {sku}"
- Màu cam/đỏ (`#DC2626`)
- Hiển thị: SKU, số lô, ngày hết hạn (format `dd/MM/yyyy`), số ngày còn lại (tính từ `expiryDate - Date.now()`)

### FCM push

```ts
await firebaseService.getMessaging().send({
  topic: `stock_alert_expiry`,
  notification: {
    title: `Hàng sắp hết hạn — ${sku}`,
    body: `Lô ${lotNumber} hết hạn ${formatDate(expiryDate)}`,
  },
  data: { sku, lotNumber, expiryDate },
});
```

### Luồng chính

1. Consumer nhận `stock.near_expiry`
2. Cast `job.data` → `StockNearExpiryPayload`
3. Gửi email + FCM (tương tự UC-N04, topic = `stock_alert_expiry`)
```

- [ ] **Step 2: Kiểm tra file đã tạo đúng vị trí**

```bash
ls -la docs/notification/
```
Kết quả mong đợi: thư mục `docs/notification/` tồn tại với file `use-cases.md`.

- [ ] **Step 3: Commit**

```bash
git add docs/notification/use-cases.md
git commit -m "docs(notification): thêm use-cases UC-N01–UC-N05 (S1-05)"
```

---

### Task 2: Tạo `docs/notification/data-model.md`

**Files:**
- Create: `docs/notification/data-model.md`

**Interfaces:**
- Consumes: payload interfaces từ `libs/events/src/events.ts`
- Produces: tài liệu "no-DB design" + payload contract

- [ ] **Step 1: Tạo file `docs/notification/data-model.md`**

```markdown
# Notification — Data Model

## Nguyên tắc: No-DB Design

Module Notification **không có database riêng**. Lý do:

1. **Consumer thuần**: chỉ nhận event và gửi thông báo — không cần lưu trạng thái
2. **Idempotency không cần DB**: Resend SDK nhận `idempotencyKey` (= `job.id`) để dedupe phía provider; FCM tự dedupe theo `messageId`
3. **Audit trail**: BullMQ lưu job history trong Redis (cấu hình `removeOnComplete: { count: 1000 }` trong `EventsModule`)

> Đây là **lựa chọn có chủ đích** (khác với Ecom dùng Redis OTP hay WMS dùng MongoDB). Thêm DB vào Notification chỉ khi có usecase cụ thể (vd: delivery report, unsubscribe preferences).

---

## Event Payload Contract

Các payload dưới đây được khai báo chính thức trong `libs/events/src/events.ts`.  
Notification KHÔNG được tự sửa payload — mọi thay đổi phải qua `libs/events`.

### `customer.verify_requested` và `customer.password_reset_requested`

```ts
interface CustomerEmailActionPayload {
  customerId: string;   // ObjectId — chỉ log, không dùng để gửi
  email: string;        // địa chỉ email nhận thông báo
  code: string;         // OTP 6 số (plaintext — chỉ để soạn email, không lưu)
}
```

**Queue:** `notification-queue`  
**Producer:** `apps/ecommerce/src/auth/`

---

### `payment.success`

```ts
interface PaymentSuccessPayload {
  orderId: string;          // mã đơn hàng — hiển thị trong email
  customerEmail: string;    // địa chỉ nhận
  amount: number;           // số tiền (VND, integer)
}
```

**Queue:** `notification-queue`  
**Producer:** `apps/ecommerce/src/order/` (sau khi thanh toán xác nhận)

---

### `stock.low`

```ts
interface StockLowPayload {
  sku: string;            // SKU cảnh báo
  warehouseId: string;    // ObjectId kho — chỉ để display, không query DB
  available: number;      // số lượng hiện tại (integer)
  minQuantity: number;    // ngưỡng tối thiểu cấu hình trong WarehouseItem
}
```

**Queue:** `notification-queue`  
**Producer:** `apps/wms/src/stock/` (sau mỗi biến động tồn, khi `available < minQuantity`)

---

### `stock.near_expiry`

```ts
interface StockNearExpiryPayload {
  sku: string;          // SKU
  lotNumber: string;    // số lô (từ InventoryStock.lotNumber)
  expiryDate: string;   // ISO 8601 date string (vd: "2026-07-15T00:00:00.000Z")
}
```

**Queue:** `notification-queue`  
**Producer:** `apps/wms/src/stock/` (job định kỳ quét lot có `expiryDate <= now + 7d`)

---

## Env Variables

Tất cả cấu hình Notification đến từ env — không có config trong DB.

| Variable | Bắt buộc | Mô tả |
|---|---|---|
| `REDIS_HOST` | ✅ | Redis host (dùng chung với BullMQ) |
| `REDIS_PORT` | ✅ | Redis port |
| `REDIS_PASSWORD` | ❌ | Redis password (optional) |
| `NOTIFICATION_PORT` | ✅ | HTTP port của app |
| `RESEND_API_KEY` | ❌ | Resend API key — thiếu thì email tắt mềm |
| `RESEND_FROM` | ❌ | Địa chỉ "from" (vd: `noreply@matestock.vn`) |
| `FIREBASE_PROJECT_ID` | ❌ | Firebase project — thiếu thì FCM tắt mềm |
| `FIREBASE_CLIENT_EMAIL` | ❌ | Firebase service account email |
| `FIREBASE_PRIVATE_KEY` | ❌ | Firebase private key (có `\n` literal) |
| `WAREHOUSE_ALERT_EMAIL` | ❌ | Email nhận cảnh báo kho (UC-N04, UC-N05) |

> `WAREHOUSE_ALERT_EMAIL` chưa có trong `env.validation.ts` — cần thêm khi code S4-04.

---

## So sánh với các app khác

| App | DB | Redis | Lý do |
|---|---|---|---|
| WMS | MongoDB (`wms_db`) | BullMQ transport | Nghiệp vụ kho: master data, sổ cái, tồn kho |
| Ecommerce | MongoDB (`ecom_db`) | BullMQ + OTP keyspace | Catalog, đơn hàng, auth khách |
| Notification | **Không có** | BullMQ consumer only | Consumer thuần — không cần lưu state |
```

- [ ] **Step 2: Commit**

```bash
git add docs/notification/data-model.md
git commit -m "docs(notification): thêm data-model — no-DB design + payload contract (S1-05)"
```

---

### Task 3: Tạo `docs/notification/consumer-design.md`

**Files:**
- Create: `docs/notification/consumer-design.md`

**Interfaces:**
- Consumes: UC-N01–UC-N05 (Task 1), payload contract (Task 2)
- Produces: kiến trúc consumer đủ chi tiết để code S4-04

- [ ] **Step 1: Tạo file `docs/notification/consumer-design.md`**

```markdown
# Notification — Consumer Design

## Kiến trúc tổng quan

```
notification-queue (Redis/BullMQ)
         │
         ▼
NotificationConsumer (@Processor)
    process(job: Job)
         │
         ├── customer.verify_requested        → EmailService.send(VerifyEmail)
         ├── customer.password_reset_requested → EmailService.send(ResetPasswordEmail)
         ├── payment.success                  → EmailService.send(PaymentSuccessEmail)   [S4-04]
         ├── stock.low                        → EmailService.send(StockLowAlertEmail)   [S4-04]
         │                                    → FirebaseService.push(topic)             [S4-04]
         ├── stock.near_expiry                → EmailService.send(StockNearExpiryEmail) [S4-04]
         │                                    → FirebaseService.push(topic)             [S4-04]
         └── * (unknown)                      → logger.warn (không throw)
```

**File chính:** `apps/notification/src/notification.consumer.ts`

---

## Module wiring

```
NotificationModule
  imports:
    - ConfigModule (isGlobal)
    - LoggerModule (nestjs-pino)
    - CommonModule (global filter/interceptor/pipe)
    - EventsModule (BullMQ + Redis)
    - EmailModule (Resend)
    - FirebaseModule (FCM Admin)
    - BullModule.registerQueue({ name: QUEUES.NOTIFICATION })
  providers:
    - NotificationService
    - NotificationConsumer
```

> `EventsModule` cấu hình Redis connection và `defaultJobOptions` (retry 5 lần, backoff exponential). `BullModule.registerQueue` đăng ký worker process cho queue này.

---

## Graceful Degradation

Notification được thiết kế **không crash** khi provider thiếu cấu hình:

| Provider | Kiểm tra | Hành vi khi tắt |
|---|---|---|
| Email (Resend) | `emailService.isEnabled()` | Log warn, return sớm — không throw |
| FCM (Firebase) | `firebaseService.isEnabled()` | Skip phần push — không throw |

Tức là với UC-N04/N05: nếu chỉ có email (không có Firebase), chỉ gửi email; nếu chỉ có Firebase, chỉ gửi push; nếu không có cả 2, log warn.

---

## Routing Pattern

```ts
async process(job: Job): Promise<void> {
  const key = job.id ?? `${job.name}:${Date.now()}`;
  switch (job.name) {
    case EVENTS.CUSTOMER_VERIFY_REQUESTED: {
      // ... đã code
      break;
    }
    case EVENTS.CUSTOMER_PASSWORD_RESET_REQUESTED: {
      // ... đã code
      break;
    }
    case EVENTS.PAYMENT_SUCCESS: {
      const payload = job.data as PaymentSuccessPayload;
      await this.email.send({ to: payload.customerEmail, subject: '...', react: PaymentSuccessEmail(...), idempotencyKey: key });
      break;
    }
    case EVENTS.STOCK_LOW: {
      const payload = job.data as StockLowPayload;
      if (this.email.isEnabled()) {
        await this.email.send({ to: this.alertEmail, subject: '...', react: StockLowAlertEmail(...), idempotencyKey: key });
      }
      if (this.firebase.isEnabled()) {
        await this.firebase.getMessaging().send({ topic: `stock_alert_${payload.warehouseId}`, ... });
      }
      if (!this.email.isEnabled() && !this.firebase.isEnabled()) {
        this.logger.warn(`stock.low cho ${payload.sku} — không có provider nào bật.`);
      }
      break;
    }
    case EVENTS.STOCK_NEAR_EXPIRY: {
      // tương tự STOCK_LOW, topic = 'stock_alert_expiry'
      break;
    }
    default:
      this.logger.warn(`Bỏ qua job lạ trên notification-queue: ${job.name}`);
  }
}
```

---

## Cách thêm event mới — checklist

Khi muốn Notification xử lý một event mới:

1. **Đảm bảo event đã khai báo** trong `libs/events/src/events.ts` (tên + payload interface)
2. **Tạo template** (nếu gửi email) trong `apps/notification/src/email/templates/`
3. **Thêm `case`** vào `switch(job.name)` trong `notification.consumer.ts`
4. **Thêm test** trong `notification.consumer.spec.ts` — kiểm tra case mới + không ảnh hưởng case cũ
5. **Cập nhật use-cases.md** thêm UC mới vào bảng tổng quan

---

## Error Handling

| Tình huống | Hành vi |
|---|---|
| Provider lỗi tạm thời (5xx) | Throw → BullMQ retry (tối đa 5 lần, backoff exponential) |
| Email tắt mềm (`isEnabled() = false`) | Return sớm, không throw, không retry |
| FCM tắt mềm (`isEnabled() = false`) | Skip push, không throw |
| Job không có field bắt buộc | Log error + throw (coi là data contract violation — không nên retry) |
| Job name không nhận ra | Log warn, return — không throw (job có thể từ tương lai) |

---

## Test Strategy

File: `apps/notification/src/notification.consumer.spec.ts`

**Mỗi case cần test:**
1. Happy path: gọi đúng service với đúng argument
2. Tắt mềm: khi `email.isEnabled()` = false → không gọi `email.send()`
3. Cả 2 provider tắt (UC-N04/N05): log warn, không throw

**Pattern test đang dùng (copy theo):**
```ts
function make() {
  const email = { send: jest.fn().mockResolvedValue(undefined), isEnabled: jest.fn().mockReturnValue(true) };
  const firebase = { isEnabled: jest.fn().mockReturnValue(false), getMessaging: jest.fn() };
  const consumer = new NotificationConsumer(email as any, firebase as any);
  return { consumer, email, firebase };
}
```
```

- [ ] **Step 2: Commit**

```bash
git add docs/notification/consumer-design.md
git commit -m "docs(notification): thêm consumer-design — routing, graceful degradation, test strategy (S1-05)"
```

---

### Task 4: Tạo `docs/notification/template-design.md`

**Files:**
- Create: `docs/notification/template-design.md`

**Interfaces:**
- Consumes: UC-N01–UC-N05 (Task 1)
- Produces: design system + danh mục template

- [ ] **Step 1: Tạo file `docs/notification/template-design.md`**

```markdown
# Notification — Email Template Design

## Design System

Tất cả template dùng [@react-email/components](https://react.email) + inline style (không CSS file riêng — email client compatibility). Màu sắc dùng nhất quán để FE/user nhận ra loại thông báo ngay từ màu OTP/header.

### Color Palette

| Màu | Hex | Dùng cho |
|---|---|---|
| `INK` (chữ chính) | `#0F172A` | Text body, tiêu đề |
| `SLATE` (chữ phụ) | `#64748B` | Mô tả, footer |
| `SURFACE` (nền nhạt) | `#F8FAFC` | Nền body email, section footer |
| `BORDER` | `#E2E8F0` | Đường kẻ `<Hr />` |
| `WHITE` | `#FFFFFF` | Nền container |
| `ACCENT` (xanh dương) | `#2563EB` | Verify email (UC-N01) |
| `ACCENT_LIGHT` | `#EFF6FF` | Nền ô OTP verify |
| `WARN` (đỏ) | `#DC2626` | Reset password (UC-N02), near expiry (UC-N05) |
| `WARN_LIGHT` | `#FFF5F5` | Nền ô OTP reset |
| `SUCCESS` (xanh lá) | `#16A34A` | Payment success (UC-N03) |
| `ALERT` (vàng cam) | `#D97706` | Stock low (UC-N04) |

### Typography

```ts
const SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif";
const MONO = "'Courier New', Courier, monospace"; // chỉ dùng cho ô OTP
```

### Layout chuẩn

```
[Header: Logo MateStock + màu accent theo loại]
[HR]
[Body: label uppercase + tiêu đề + mô tả + nội dung chính]
[HR]
[Footer: disclaimer + copyright + link hỗ trợ]
```

Container: `maxWidth: 480px`, `borderRadius: 12px`, `border: 1px solid #E2E8F0`.

---

## Danh mục Template

### VerifyEmail (✅ Đã code)

**File:** `apps/notification/src/email/templates/verify-email.tsx`  
**Props:** `{ code: string }`  
**Preview text:** "Mã xác minh MateStock: {code} — hết hạn sau 10 phút"  
**Điểm nhận ra:** OTP box xanh dương, label "Xác minh tài khoản"

---

### ResetPasswordEmail (✅ Đã code)

**File:** `apps/notification/src/email/templates/reset-password.tsx`  
**Props:** `{ code: string }`  
**Preview text:** "Đặt lại mật khẩu MateStock: {code} — hết hạn sau 10 phút"  
**Điểm nhận ra:** OTP box đỏ (`WARN`), label "Đặt lại mật khẩu", thêm cảnh báo "Nếu không phải bạn yêu cầu, hãy đổi mật khẩu ngay"

---

### PaymentSuccessEmail (📋 S4-04)

**File:** `apps/notification/src/email/templates/payment-success.tsx`  
**Props:** `{ orderId: string; amount: number }`  
**Điểm nhận ra:** màu xanh lá (`SUCCESS`), không có OTP box

```tsx
// Hiển thị số tiền
const formatted = new Intl.NumberFormat('vi-VN', {
  style: 'currency',
  currency: 'VND',
}).format(amount);
// Output: "250.000 ₫"
```

Cấu trúc body:
```
✅ Thanh toán thành công
Đơn hàng #orderId đã được xác nhận
Số tiền: {formatted}
[Cảm ơn đã mua hàng tại MateStock]
```

---

### StockLowAlertEmail (📋 S4-04)

**File:** `apps/notification/src/email/templates/stock-low-alert.tsx`  
**Props:** `{ sku: string; warehouseId: string; available: number; minQuantity: number }`  
**Điểm nhận ra:** màu vàng cam (`ALERT`)

Cấu trúc body:
```
⚠️ Tồn kho thấp
SKU: {sku} tại kho {warehouseId}
Hiện tại: {available} / Ngưỡng tối thiểu: {minQuantity}
Tỉ lệ: {Math.round(available/minQuantity*100)}%
```

---

### StockNearExpiryEmail (📋 S4-04)

**File:** `apps/notification/src/email/templates/stock-near-expiry.tsx`  
**Props:** `{ sku: string; lotNumber: string; expiryDate: string }`  
**Điểm nhận ra:** màu đỏ (`WARN`)

```tsx
// Format ngày
const formatted = new Date(expiryDate).toLocaleDateString('vi-VN', {
  day: '2-digit', month: '2-digit', year: 'numeric',
});
// Output: "15/07/2026"

const daysLeft = Math.ceil((new Date(expiryDate).getTime() - Date.now()) / 86_400_000);
```

Cấu trúc body:
```
⏰ Lô hàng sắp hết hạn
SKU: {sku} — Lô: {lotNumber}
Ngày hết hạn: {formatted} (còn {daysLeft} ngày)
```

---

## Cách thêm template mới

1. Tạo file `apps/notification/src/email/templates/<name>.tsx`
2. Export function `export function <Name>Email(props: Props): ReactElement`
3. Thêm test vào `apps/notification/src/email/templates/templates.spec.ts`:
   ```ts
   it('<Name>Email chứa nội dung chính', async () => {
     const html = await render(<Name>Email({ ...props }));
     expect(html).toContain(/* key field */);
   });
   ```
4. Import và dùng trong `notification.consumer.ts`
5. Cập nhật `template-design.md` với spec của template mới

---

## Test Email (Dev)

Resend cung cấp **Resend Dev mode** (gửi thật tới email đã verify).  
Để test template mà không gửi email thật: dùng `@react-email/render` trong test:

```ts
import { render } from '@react-email/components';
const html = await render(StockLowAlertEmail({ sku: 'LY-500ML', ... }));
// Kiểm tra html chứa các string quan trọng
```
```

- [ ] **Step 2: Commit**

```bash
git add docs/notification/template-design.md
git commit -m "docs(notification): thêm template-design — design system + danh mục 5 template (S1-05)"
```

---

### Task 5: Tạo `docs/notification/idempotency.md`

**Files:**
- Create: `docs/notification/idempotency.md`

**Interfaces:**
- Consumes: consumer-design (Task 3), BullMQ retry config từ `libs/events`
- Produces: tài liệu idempotency đủ để dev hiểu tại sao không gửi trùng

- [ ] **Step 1: Tạo file `docs/notification/idempotency.md`**

```markdown
# Notification — Idempotency & Retry

## Vấn đề: BullMQ retry 5 lần có thể gửi thông báo nhiều lần

`EventsModule` cấu hình `defaultJobOptions: { attempts: 5, backoff: { type: 'exponential', delay: 1000 } }`. Nếu consumer throw lỗi (vd: Resend trả 5xx lần đầu), BullMQ sẽ retry job tới 5 lần.

**Nếu không xử lý idempotency:** 1 mã OTP có thể được gửi tới 5 lần email. 1 cảnh báo `stock.low` có thể gây 5 FCM push.

---

## Giải pháp: `job.id` làm khóa idempotency

Mỗi BullMQ job có `job.id` duy nhất và **không đổi** qua các lần retry. Consumer dùng `job.id` làm khóa idempotency cho từng provider.

### Email (Resend)

Resend SDK hỗ trợ `idempotencyKey` tại cấp HTTP header. Cùng 1 key trong 24h → Resend bỏ qua request thứ 2+:

```ts
await resend.emails.send(
  { from, to, subject, react },
  { idempotencyKey: job.id }  // ← BullMQ job.id
);
```

> Resend lưu key 24h. Vì BullMQ retry trong vài phút (exponential backoff), window này đủ rộng.

**Fallback khi `job.id` = undefined:**
```ts
const key = job.id ?? `${job.name}:${Date.now()}`;
```
`job.id` chỉ undefined trong unit test nếu không set — môi trường production BullMQ luôn assign id.

---

### FCM Push (Firebase)

Firebase Admin SDK tự gán `message_id` cho mỗi `send()`. FCM không có built-in idempotency key qua SDK.

**Chiến lược cho FCM:** chấp nhận gửi trùng (duplicate push notification) là acceptable trade-off vì:
1. Push notification không có side effect tài chính/bảo mật (khác email OTP)
2. Retry scenario hiếm (Resend thường ổn định hơn FCM)
3. User nhận 2 lần cảnh báo "tồn kho thấp" không phải lỗi nghiêm trọng

Nếu cần strict dedup cho FCM trong tương lai: dùng Redis `SETNX` với TTL 5 phút làm distributed lock trước khi gọi `getMessaging().send()`.

---

## Retry Flow

```
Job STOCK_LOW arrives (job.id = "abc123")
         │
         ▼
EmailService.send({ idempotencyKey: "abc123" })
         │
     Resend 5xx (lỗi tạm)
         │
         ▼
Consumer throws → BullMQ schedules retry
         │
     (1s backoff)
         │
         ▼
EmailService.send({ idempotencyKey: "abc123" })  ← CÙNG KEY
         │
     Resend 200 OK (nhưng không gửi lại — idempotent)
         │
         ▼
Job COMPLETED
```

---

## Khi nào KHÔNG retry

Consumer return (không throw) trong các trường hợp sau → BullMQ không retry:

| Case | Lý do không retry |
|---|---|
| Email tắt mềm (`isEnabled() = false`) | Config issue — retry cũng không giải quyết |
| FCM tắt mềm (`isEnabled() = false`) | Config issue |
| Job name không nhận ra | Unknown event — retry vô ích |

Chỉ throw (và cho retry) khi **provider lỗi tạm thời** (network, 5xx).

---

## Monitoring & Observability

BullMQ Bull Board (nếu cài) hoặc Redis CLI có thể xem:
- `failed` jobs: job đã retry hết 5 lần vẫn fail
- `completed` jobs: xử lý thành công

Log quan trọng (dùng `nestjs-pino`):
- `WARN`: job tắt mềm (email/FCM disabled) — không phải lỗi, nhưng cần biết
- `ERROR`: Resend/FCM trả lỗi — sẽ retry
- `WARN`: job name không nhận ra — có thể là event mới chưa implement

---

## Checklist khi thêm event mới

- [ ] Dùng `idempotencyKey: job.id ?? \`${job.name}:${Date.now()}\`` cho mọi `EmailService.send()`
- [ ] Nếu gọi FCM: ghi comment giải thích về duplicate push (acceptable hay cần Redis lock)
- [ ] Test case "retry cùng job.id không gửi trùng" → trong integration test, mock Resend và kiểm tra idempotencyKey không thay đổi qua 2 lần `process()` cùng job
```

- [ ] **Step 2: Commit**

```bash
git add docs/notification/idempotency.md
git commit -m "docs(notification): thêm idempotency — job.id/Resend dedup, FCM trade-off, retry flow (S1-05)"
```

---

### Task 6: Tạo `docs/notification/README.md` và cập nhật index

**Files:**
- Create: `docs/notification/README.md`

**Interfaces:**
- Consumes: tất cả 4 file docs đã tạo (Task 1–5)
- Produces: entry point dẫn đường cho dev mới

- [ ] **Step 1: Tạo `docs/notification/README.md`**

```markdown
# Notification Module

App `apps/notification` — **consumer thuần** nhận event từ `notification-queue` và gửi thông báo qua Resend (email) hoặc Firebase Cloud Messaging (FCM push). Không có DB riêng.

## Tài liệu

| File | Nội dung |
|---|---|
| [use-cases.md](./use-cases.md) | 5 use-cases: UC-N01–UC-N05 (verify, reset, payment, stock.low, near_expiry) |
| [data-model.md](./data-model.md) | No-DB design + payload contract từ `libs/events` + env variables |
| [consumer-design.md](./consumer-design.md) | Kiến trúc consumer, routing, graceful degradation, cách thêm event mới |
| [template-design.md](./template-design.md) | Design system màu/font, danh mục 5 template, cách thêm template mới |
| [idempotency.md](./idempotency.md) | Chống gửi trùng: job.id → Resend idempotencyKey, FCM trade-off, retry flow |

## Trạng thái hiện tại

| UC | Tên | Trạng thái |
|---|---|---|
| UC-N01 | Gửi email xác minh | ✅ Đã code |
| UC-N02 | Gửi email reset mật khẩu | ✅ Đã code |
| UC-N03 | Email xác nhận thanh toán | 📋 Thiết kế (S4-04) |
| UC-N04 | Cảnh báo tồn kho thấp | 📋 Thiết kế (S4-04) |
| UC-N05 | Cảnh báo hàng sắp hết hạn | 📋 Thiết kế (S4-04) |

## Code liên quan

- Consumer: `apps/notification/src/notification.consumer.ts`
- Email service: `apps/notification/src/email/email.service.ts`
- Templates: `apps/notification/src/email/templates/`
- Firebase: `apps/notification/src/firebase/`
- Event contract: `libs/events/src/events.ts`
```

- [ ] **Step 2: Commit tất cả**

```bash
git add docs/notification/README.md
git commit -m "docs(notification): thêm README index — S1-05 complete"
```

---

## Self-Review

### Spec coverage

Sprint plan S1-05 nói: *"Viết module `notification/` (consumer `stock.low`, `stock.near_expiry`; template; idempotent)"*

| Yêu cầu | Task |
|---|---|
| consumer `stock.low` | Task 3 (consumer-design.md) + Task 1 (UC-N04) |
| consumer `stock.near_expiry` | Task 3 (consumer-design.md) + Task 1 (UC-N05) |
| template | Task 4 (template-design.md) |
| idempotent | Task 5 (idempotency.md) |

**Không có gaps.** Ngoài ra plan còn phủ thêm: UC-N01/N02/N03 (đã code hoặc cần code), no-DB design decision, FCM design, env variables, test strategy.

### Placeholder scan

Không có "TBD", "TODO", "implement later", hay "similar to Task N" trong code blocks. Mỗi task có nội dung Markdown đầy đủ.

### Type consistency

- Payload types nhất quán với `libs/events/src/events.ts`: `StockLowPayload`, `StockNearExpiryPayload`, `PaymentSuccessPayload`, `CustomerEmailActionPayload`
- `EVENTS.STOCK_LOW`, `EVENTS.STOCK_NEAR_EXPIRY`, v.v. nhất quán với `events.ts`
- `QUEUES.NOTIFICATION` dùng xuyên suốt
