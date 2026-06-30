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
// Snippet này mô tả thiết kế mục tiêu sau khi S4-04 mở rộng constructor với FirebaseService.
// Hiện tại (S1-05): constructor chỉ nhận EmailService.
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
