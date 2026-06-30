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
