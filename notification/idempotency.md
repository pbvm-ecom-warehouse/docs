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

> **Lưu ý S4-04:** `EmailService.send()` hiện tại chỉ `logger.error` khi Resend trả lỗi — không throw. Để BullMQ retry hoạt động, S4-04 cần sửa `email.service.ts` để throw khi `error` truthy (sau khi `resend.emails.send()` trả về).

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
