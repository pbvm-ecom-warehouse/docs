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
