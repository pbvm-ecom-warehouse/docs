# Exception Đồng Bộ — Mã Lỗi + Catalog Theo App

**Ngày:** 2026-06-25
**Phạm vi:** `libs/common`, `apps/ecommerce/src/auth`, `apps/wms/src/auth`, `.claude/rules`

---

## Bối cảnh

Hiện tại các service (đặc biệt `auth.service.ts`) throw NestJS exception thô (`BadRequestException`, `UnauthorizedException`, `ConflictException`...). `AllExceptionsFilter` đã có khả năng bắt và chuẩn hóa output, nhưng FE nhận `code` không ổn định (map từ HTTP status, không phải mã nghiệp vụ).

`AppException` + `ERROR_CATALOG` đã có trong `libs/common` nhưng chưa được dùng trong service nào.

**Mục tiêu:** Migrate toàn bộ exception trong `auth.service.ts` cả hai app sang `AppException`, đồng thời tạo khung catalog lỗi theo domain để các domain sau (stock, order, catalog...) thêm vào cùng pattern.

---

## Kiến trúc Catalog

### Tầng 1 — Cross-cutting (`libs/common`)

`libs/common/src/errors/error-codes.ts` giữ `ERROR_CATALOG` hiện tại và bổ sung auth codes dùng chung giữa hai app:

```ts
AUTH_INVALID_CREDENTIALS  401  "Sai tài khoản hoặc mật khẩu"
AUTH_TOKEN_INVALID        401  "Token không hợp lệ hoặc đã hết hạn"
AUTH_ACCOUNT_INACTIVE     401  "Tài khoản không còn hiệu lực"
AUTH_FIREBASE_NO_EMAIL    401  "Firebase token không chứa email"
AUTH_FIREBASE_UID_MISMATCH 401 "Tài khoản đã liên kết Firebase khác"
AUTH_FIREBASE_LOGIN_FAILED 401 "Không thể đăng nhập bằng Firebase"
AUTH_OTP_INVALID          400  "Mã không đúng hoặc đã hết hạn"
AUTH_EMAIL_CONFLICT       409  "Email đã được đăng ký"
AUTH_WMS_NOT_INITIALIZED  401  "Nhân viên chưa được khởi tạo trong WMS"
AUTH_BOOTSTRAP_FORBIDDEN  403  "Đã có nhân viên trong hệ thống"
```

Lý do đặt ở `libs/common` (không phải app-level): cả WMS lẫn Ecommerce đều có auth và dùng chung logic Firebase, OTP, token — tránh duplicate code giống nhau.

### Tầng 2 — App-level domain codes

**`apps/ecommerce/src/common/error-codes.ts`**

```ts
export const ECOM_ERRORS = {
  // placeholder cho domain sau: CATALOG_..., ORDER_..., PAYMENT_...
} as const;
export type EcomErrorCode = keyof typeof ECOM_ERRORS;
```

**`apps/wms/src/common/error-codes.ts`**

```ts
export const WMS_ERRORS = {
  // placeholder cho domain sau: STOCK_..., SHIPMENT_..., PRINT_...
} as const;
export type WmsErrorCode = keyof typeof WMS_ERRORS;
```

Các file này bắt đầu rỗng (chỉ có comment placeholder). Domain sau thêm vào đây thay vì inline trong service.

---

## Pattern Sử Dụng trong Service

### Option A — Dùng default từ catalog
```ts
throw new AppException('AUTH_EMAIL_CONFLICT');
// → { code: 'AUTH_EMAIL_CONFLICT', message: 'Email đã được đăng ký', status: 409 }
```

### Option C — Override message khi ngữ cảnh cần rõ hơn
```ts
throw new AppException('AUTH_INVALID_CREDENTIALS', 'Sai email hoặc mật khẩu');
// → { code: 'AUTH_INVALID_CREDENTIALS', message: 'Sai email hoặc mật khẩu', status: 401 }
```

Override chỉ dùng khi:
- Cùng một lỗi nhưng ngữ cảnh khác nhau (vd login vs google login vs change-password đều có thể là INVALID_CREDENTIALS)
- Message cần thêm chi tiết cụ thể hơn default

### Không được dùng trong service
```ts
// ❌ Không throw NestJS exception thô trong service
throw new BadRequestException('...');
throw new UnauthorizedException('...');
throw new ConflictException('...');

// ✅ Luôn dùng AppException
throw new AppException('AUTH_OTP_INVALID');
```

NestJS exception thô chỉ được `AllExceptionsFilter` wrap — không có `code` ổn định cho FE.

---

## Phạm vi Migrate Lần Này

| File | Thay đổi |
|---|---|
| `libs/common/src/errors/error-codes.ts` | Thêm 10 auth codes vào `ERROR_CATALOG` |
| `apps/ecommerce/src/common/error-codes.ts` | Tạo mới — `ECOM_ERRORS` rỗng (khung) |
| `apps/wms/src/common/error-codes.ts` | Tạo mới — `WMS_ERRORS` rỗng (khung) |
| `apps/ecommerce/src/auth/auth.service.ts` | Migrate toàn bộ exception sang `AppException` |
| `apps/wms/src/auth/auth.service.ts` | Migrate toàn bộ exception sang `AppException` |
| `.claude/rules/error-handling.md` | Tạo mới — rule bắt buộc dùng `AppException` |

---

## Rule `.claude/rules/error-handling.md`

Rule phải cover:
1. **Bắt buộc**: Service phải dùng `AppException`, không throw NestJS exception thô
2. **Catalog placement**: cross-cutting → `libs/common/error-codes.ts`; app-domain → `apps/<app>/src/common/error-codes.ts`
3. **Pattern override**: khi nào được phép override message
4. **Cách thêm code mới**: checklist 3 bước (thêm catalog → thêm type → dùng trong service)
5. **Exception trong filter/guard**: filter và guard vẫn được dùng NestJS exception (chúng là infrastructure, không phải service)

---

## Mapping Migration Chi Tiết

### `apps/ecommerce/src/auth/auth.service.ts`

| Dòng hiện tại | Code mới |
|---|---|
| `ConflictException('Email da duoc dang ky')` | `AppException('AUTH_EMAIL_CONFLICT')` |
| `UnauthorizedException('Sai email hoac mat khau')` | `AppException('AUTH_INVALID_CREDENTIALS', 'Sai email hoặc mật khẩu')` |
| `UnauthorizedException('Firebase token khong chua email')` | `AppException('AUTH_FIREBASE_NO_EMAIL')` |
| `UnauthorizedException('Tai khoan da duoc lien ket Firebase khac')` | `AppException('AUTH_FIREBASE_UID_MISMATCH')` |
| `UnauthorizedException('Khong the dang nhap bang Firebase')` | `AppException('AUTH_FIREBASE_LOGIN_FAILED')` |
| `UnauthorizedException('Refresh token khong hop le hoac da het han')` | `AppException('AUTH_TOKEN_INVALID')` |
| `UnauthorizedException('Tai khoan khong con hieu luc')` | `AppException('AUTH_ACCOUNT_INACTIVE')` |
| `BadRequestException('Ma khong dung hoac da het han')` (x2) | `AppException('AUTH_OTP_INVALID')` |
| `UnauthorizedException('Mat khau cu khong dung')` | `AppException('AUTH_INVALID_CREDENTIALS', 'Mật khẩu cũ không đúng')` |
| `UnauthorizedException()` (generic, nhiều chỗ) | `AppException('UNAUTHENTICATED')` |
| `NotFoundException('Customer not found')` | `AppException('NOT_FOUND', 'Customer not found')` |
| `NotFoundException('Address not found')` | `AppException('NOT_FOUND', 'Địa chỉ không tồn tại')` |

### `apps/wms/src/auth/auth.service.ts`

| Dòng hiện tại | Code mới |
|---|---|
| `UnauthorizedException('Sai tai khoan hoac mat khau')` | `AppException('AUTH_INVALID_CREDENTIALS', 'Sai tài khoản hoặc mật khẩu')` |
| `UnauthorizedException('Firebase token khong chua email')` | `AppException('AUTH_FIREBASE_NO_EMAIL')` |
| `UnauthorizedException('Nhan vien chua duoc khoi tao trong WMS')` (x2) | `AppException('AUTH_WMS_NOT_INITIALIZED')` |
| `UnauthorizedException('Tai khoan da duoc lien ket Firebase khac')` | `AppException('AUTH_FIREBASE_UID_MISMATCH')` |
| `UnauthorizedException('Refresh token khong hop le hoac da het han')` | `AppException('AUTH_TOKEN_INVALID')` |
| `UnauthorizedException('Tai khoan khong con hieu luc')` | `AppException('AUTH_ACCOUNT_INACTIVE')` |
| `UnauthorizedException()` (generic) | `AppException('UNAUTHENTICATED')` |
| `ForbiddenException('Da co nhan vien trong he thong')` | `AppException('AUTH_BOOTSTRAP_FORBIDDEN')` |
| `NotFoundException('User not found')` (x4) | `AppException('NOT_FOUND', 'User not found')` |
| `UnauthorizedException('Mat khau cu khong dung')` | `AppException('AUTH_INVALID_CREDENTIALS', 'Mật khẩu cũ không đúng')` |

---

## Không Nằm Trong Scope Lần Này

- `jwt.strategy.ts` — guard/strategy được phép dùng `UnauthorizedException` (infrastructure)
- Các service ngoài auth (stock, catalog, order...) — thêm dần khi implement domain đó
- `ECOM_ERRORS` / `WMS_ERRORS` cụ thể cho domain — chỉ tạo file khung, nội dung thêm sau
