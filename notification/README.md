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
