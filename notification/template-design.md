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
