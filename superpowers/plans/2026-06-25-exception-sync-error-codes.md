# Exception Đồng Bộ — Mã Lỗi + Catalog Theo App

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate toàn bộ exception trong `auth.service.ts` của cả WMS và Ecommerce sang `AppException` có mã lỗi ổn định, đồng thời lập catalog lỗi theo 2 tầng (cross-cutting + app-domain) và thêm rule bắt buộc.

**Architecture:** `AppException` (đã có trong `libs/common`) nhận một `code` string + optional message override. `ERROR_CATALOG` (cross-cutting) mở rộng thêm 10 auth codes. Mỗi app có file `src/common/error-codes.ts` riêng cho domain codes. `AllExceptionsFilter` (đã có) bắt `AppException` và trả `{ error: { code, message } }` — không cần thay đổi filter.

**Tech Stack:** NestJS, TypeScript strict, Jest 30, `@app/common` path alias.

## Global Constraints

- TypeScript strict — không dùng `any`, không implicit any.
- Import `AppException` từ `@app/common` (không import trực tiếp từ đường dẫn file).
- Comment tiếng Việt giải thích *vì sao*, không giải thích *cái gì*.
- Tên code ALL_CAPS_SNAKE_CASE.
- Không sửa `jwt.strategy.ts`, guard, filter — chúng là infrastructure, được phép dùng NestJS exception thô.
- Chạy test: `pnpm test` từ thư mục `be/`.

---

## File Map

| File | Trạng thái | Vai trò |
|---|---|---|
| `libs/common/src/errors/error-codes.ts` | Modify | Thêm 10 auth codes vào `ERROR_CATALOG` |
| `libs/common/src/errors/app.exception.spec.ts` | Modify | Thêm test cho auth codes mới |
| `apps/ecommerce/src/common/error-codes.ts` | Create | `ECOM_ERRORS` — khung rỗng cho domain codes |
| `apps/wms/src/common/error-codes.ts` | Create | `WMS_ERRORS` — khung rỗng cho domain codes |
| `apps/ecommerce/src/auth/auth.service.ts` | Modify | Migrate 12 exception sang `AppException` |
| `apps/wms/src/auth/auth.service.ts` | Modify | Migrate 10 exception sang `AppException` |
| `be/.claude/rules/error-handling.md` | Create | Rule bắt buộc dùng `AppException` trong service |

---

### Task 1: Mở rộng ERROR_CATALOG với auth codes

**Files:**
- Modify: `libs/common/src/errors/error-codes.ts`
- Modify: `libs/common/src/errors/app.exception.spec.ts`

**Interfaces:**
- Produces: 10 code keys mới trong `ERROR_CATALOG` — `AUTH_INVALID_CREDENTIALS`, `AUTH_TOKEN_INVALID`, `AUTH_ACCOUNT_INACTIVE`, `AUTH_FIREBASE_NO_EMAIL`, `AUTH_FIREBASE_UID_MISMATCH`, `AUTH_FIREBASE_LOGIN_FAILED`, `AUTH_OTP_INVALID`, `AUTH_EMAIL_CONFLICT`, `AUTH_WMS_NOT_INITIALIZED`, `AUTH_BOOTSTRAP_FORBIDDEN` — dùng trong Task 3 và Task 4.

- [ ] **Bước 1: Viết failing test cho auth codes**

Thêm vào cuối `libs/common/src/errors/app.exception.spec.ts`:

```ts
describe('auth error codes', () => {
  it.each([
    ['AUTH_INVALID_CREDENTIALS', 401],
    ['AUTH_TOKEN_INVALID', 401],
    ['AUTH_ACCOUNT_INACTIVE', 401],
    ['AUTH_FIREBASE_NO_EMAIL', 401],
    ['AUTH_FIREBASE_UID_MISMATCH', 401],
    ['AUTH_FIREBASE_LOGIN_FAILED', 401],
    ['AUTH_OTP_INVALID', 400],
    ['AUTH_EMAIL_CONFLICT', 409],
    ['AUTH_WMS_NOT_INITIALIZED', 401],
    ['AUTH_BOOTSTRAP_FORBIDDEN', 403],
  ] as const)('AppException(%s) → status %i', (code, expectedStatus) => {
    const ex = new AppException(code);
    expect(ex.getStatus()).toBe(expectedStatus);
    const body = ex.getResponse() as { code: string; message: string };
    expect(body.code).toBe(code);
    expect(typeof body.message).toBe('string');
    expect(body.message.length).toBeGreaterThan(0);
  });

  it('override message giữ nguyên status từ catalog', () => {
    const ex = new AppException('AUTH_INVALID_CREDENTIALS', 'Mật khẩu cũ không đúng');
    expect(ex.getStatus()).toBe(401);
    const body = ex.getResponse() as { code: string; message: string };
    expect(body.message).toBe('Mật khẩu cũ không đúng');
  });
});
```

- [ ] **Bước 2: Chạy test — xác nhận fail**

```bash
cd be && pnpm test --testPathPattern="app.exception.spec"
```

Expected: FAIL — `AppException('AUTH_INVALID_CREDENTIALS')` → status 400 (fallback), không phải 401.

- [ ] **Bước 3: Thêm auth codes vào ERROR_CATALOG**

Thay toàn bộ nội dung `libs/common/src/errors/error-codes.ts`:

```ts
import { HttpStatus } from '@nestjs/common';

/**
 * Catalog mã lỗi CHUNG cho mọi app. Mỗi code có HTTP status + message mặc định.
 * App tự thêm mã miền (vd STOCK_INSUFFICIENT) ở apps/<app>/src/common/error-codes.ts —
 * AppException nhận mọi chuỗi code, không bắt buộc nằm trong catalog này.
 */
export const ERROR_CATALOG = {
  // ── Cross-cutting ────────────────────────────────────────────────────────
  VALIDATION_FAILED: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Dữ liệu không hợp lệ',
  },
  UNAUTHENTICATED: {
    status: HttpStatus.UNAUTHORIZED,
    message: 'Chưa xác thực',
  },
  FORBIDDEN: {
    status: HttpStatus.FORBIDDEN,
    message: 'Không đủ quyền truy cập',
  },
  NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy tài nguyên',
  },
  CONFLICT: { status: HttpStatus.CONFLICT, message: 'Xung đột trạng thái' },
  RATE_LIMITED: {
    status: HttpStatus.TOO_MANY_REQUESTS,
    message: 'Quá nhiều yêu cầu, thử lại sau',
  },
  INTERNAL: {
    status: HttpStatus.INTERNAL_SERVER_ERROR,
    message: 'Lỗi hệ thống',
  },

  // ── Auth (dùng chung cả WMS lẫn Ecommerce) ──────────────────────────────
  AUTH_INVALID_CREDENTIALS: {
    status: HttpStatus.UNAUTHORIZED,
    message: 'Sai tài khoản hoặc mật khẩu',
  },
  AUTH_TOKEN_INVALID: {
    status: HttpStatus.UNAUTHORIZED,
    message: 'Token không hợp lệ hoặc đã hết hạn',
  },
  AUTH_ACCOUNT_INACTIVE: {
    status: HttpStatus.UNAUTHORIZED,
    message: 'Tài khoản không còn hiệu lực',
  },
  AUTH_FIREBASE_NO_EMAIL: {
    status: HttpStatus.UNAUTHORIZED,
    message: 'Firebase token không chứa email',
  },
  AUTH_FIREBASE_UID_MISMATCH: {
    status: HttpStatus.UNAUTHORIZED,
    message: 'Tài khoản đã liên kết với Firebase account khác',
  },
  AUTH_FIREBASE_LOGIN_FAILED: {
    status: HttpStatus.UNAUTHORIZED,
    message: 'Không thể đăng nhập bằng Firebase',
  },
  AUTH_OTP_INVALID: {
    status: HttpStatus.BAD_REQUEST,
    message: 'Mã không đúng hoặc đã hết hạn',
  },
  AUTH_EMAIL_CONFLICT: {
    status: HttpStatus.CONFLICT,
    message: 'Email đã được đăng ký',
  },
  // Chỉ WMS dùng — đặt ở cross-cutting vì Firebase auth logic nằm trong libs/common
  AUTH_WMS_NOT_INITIALIZED: {
    status: HttpStatus.UNAUTHORIZED,
    message: 'Nhân viên chưa được khởi tạo trong WMS',
  },
  AUTH_BOOTSTRAP_FORBIDDEN: {
    status: HttpStatus.FORBIDDEN,
    message: 'Đã có nhân viên trong hệ thống',
  },
} as const;

export type CommonErrorCode = keyof typeof ERROR_CATALOG;
```

- [ ] **Bước 4: Chạy test — xác nhận pass**

```bash
cd be && pnpm test --testPathPattern="app.exception.spec"
```

Expected: PASS — tất cả auth code test cases pass.

- [ ] **Bước 5: Commit**

```bash
git add libs/common/src/errors/error-codes.ts libs/common/src/errors/app.exception.spec.ts
git commit -m "feat(common): thêm auth error codes vào ERROR_CATALOG"
```

---

### Task 2: Tạo khung app-level error codes + rule

**Files:**
- Create: `apps/ecommerce/src/common/error-codes.ts`
- Create: `apps/wms/src/common/error-codes.ts`
- Create: `be/.claude/rules/error-handling.md`

**Interfaces:**
- Produces: `ECOM_ERRORS` object (rỗng, typed) — domain codes ecommerce thêm vào đây sau.
- Produces: `WMS_ERRORS` object (rỗng, typed) — domain codes WMS thêm vào đây sau.

*Task này không có test vì file khung rỗng + rule là docs — không có logic để test.*

- [ ] **Bước 1: Tạo `apps/ecommerce/src/common/error-codes.ts`**

```ts
import { HttpStatus } from '@nestjs/common';

/**
 * Mã lỗi nghiệp vụ của Ecommerce app.
 * Thêm code theo domain tại đây — không thêm vào libs/common.
 * Xem pattern: libs/common/src/errors/error-codes.ts
 *
 * Ví dụ domain sau:
 *   CATALOG_PRODUCT_NOT_FOUND: { status: HttpStatus.NOT_FOUND, message: '...' }
 *   ORDER_NOT_CANCELLABLE:     { status: HttpStatus.CONFLICT, message: '...' }
 *   PAYMENT_FAILED:            { status: HttpStatus.BAD_REQUEST, message: '...' }
 */
export const ECOM_ERRORS = {
  // domain codes sẽ thêm vào đây khi implement từng module
} as const satisfies Record<string, { status: number; message: string }>;

export type EcomErrorCode = keyof typeof ECOM_ERRORS;
```

- [ ] **Bước 2: Tạo `apps/wms/src/common/error-codes.ts`**

```ts
import { HttpStatus } from '@nestjs/common';

/**
 * Mã lỗi nghiệp vụ của WMS app.
 * Thêm code theo domain tại đây — không thêm vào libs/common.
 * Xem pattern: libs/common/src/errors/error-codes.ts
 *
 * Ví dụ domain sau:
 *   STOCK_INSUFFICIENT:     { status: HttpStatus.CONFLICT, message: '...' }
 *   SHIPMENT_ALREADY_SENT:  { status: HttpStatus.CONFLICT, message: '...' }
 *   PRINT_JOB_NOT_PENDING:  { status: HttpStatus.BAD_REQUEST, message: '...' }
 */
export const WMS_ERRORS = {
  // domain codes sẽ thêm vào đây khi implement từng module
} as const satisfies Record<string, { status: number; message: string }>;

export type WmsErrorCode = keyof typeof WMS_ERRORS;
```

- [ ] **Bước 3: Tạo `be/.claude/rules/error-handling.md`**

```markdown
# Rule: Exception handling — dùng AppException, không throw NestJS exception thô

## Quy tắc bắt buộc

**Service** (bất kỳ file `*.service.ts`) **PHẢI dùng `AppException`** từ `@app/common`.
Không được throw `BadRequestException`, `NotFoundException`, `UnauthorizedException`, `ConflictException`, `ForbiddenException` trực tiếp trong service.

```ts
// ❌ Sai — FE nhận code không ổn định (map từ HTTP status)
throw new UnauthorizedException('Sai email hoặc mật khẩu');

// ✅ Đúng — FE nhận code ổn định để switch-case
throw new AppException('AUTH_INVALID_CREDENTIALS');

// ✅ Đúng — override message khi ngữ cảnh khác default
throw new AppException('AUTH_INVALID_CREDENTIALS', 'Mật khẩu cũ không đúng');
```

**Filter, guard, strategy** (`*.filter.ts`, `*.guard.ts`, `*.strategy.ts`) được phép dùng NestJS exception — chúng là infrastructure, `AllExceptionsFilter` sẽ wrap lại.

## Catalog 2 tầng

### Tầng 1 — Cross-cutting (`libs/common/src/errors/error-codes.ts`)
Codes dùng chung mọi app: UNAUTHENTICATED, NOT_FOUND, VALIDATION_FAILED, CONFLICT, RATE_LIMITED, INTERNAL + tất cả AUTH_* codes.

### Tầng 2 — App-domain
- Ecommerce: `apps/ecommerce/src/common/error-codes.ts` → `ECOM_ERRORS`
- WMS: `apps/wms/src/common/error-codes.ts` → `WMS_ERRORS`

Lý do tách: giữ `libs/common` không biết về business domain của từng app.

## Khi thêm code mới

1. **Xác định tầng**: cross-cutting (auth/rate-limit/validation) → `libs/common`; domain cụ thể → `apps/<app>/src/common/error-codes.ts`
2. **Thêm vào catalog**: `CODE: { status: HttpStatus.XXX, message: 'Tiếng Việt' }`
3. **Dùng trong service**: `throw new AppException('CODE')` hoặc `throw new AppException('CODE', 'override message')`

Override message chỉ khi cùng một code nhưng ngữ cảnh cần message khác nhau (vd `AUTH_INVALID_CREDENTIALS` dùng cho cả login lẫn change-password nhưng message khác).

## Output chuẩn (do AllExceptionsFilter tạo)

```json
{
  "error": {
    "code": "AUTH_INVALID_CREDENTIALS",
    "message": "Sai email hoặc mật khẩu"
  },
  "meta": {
    "requestId": "...",
    "timestamp": "...",
    "path": "/api/shop/auth/login"
  }
}
```

FE switch theo `error.code` — ổn định qua mọi lần refactor message.
```

- [ ] **Bước 4: Thêm rule vào CLAUDE.md**

Mở `be/CLAUDE.md`, tìm block `@.claude/rules/` (dòng 42-45) và thêm dòng mới:

```
@.claude/rules/architecture.md
@.claude/rules/data-and-mongoose.md
@.claude/rules/events.md
@.claude/rules/auth-and-modules.md
@.claude/rules/dto-conventions.md
@.claude/rules/error-handling.md
```

(`dto-conventions.md` đã tồn tại nhưng chưa được import — thêm luôn.)

- [ ] **Bước 5: Commit**

```bash
git add apps/ecommerce/src/common/error-codes.ts apps/wms/src/common/error-codes.ts .claude/rules/error-handling.md CLAUDE.md
git commit -m "feat: tạo khung app-level error codes + rule error-handling, wired vào CLAUDE.md"
```

---

### Task 3: Migrate auth.service.ts — Ecommerce

**Files:**
- Modify: `apps/ecommerce/src/auth/auth.service.ts`

**Interfaces:**
- Consumes: `AppException` từ `@app/common`, các codes từ `ERROR_CATALOG` (Task 1).
- Consumes: Không import `ECOM_ERRORS` — auth codes nằm ở cross-cutting.

- [ ] **Bước 1: Xem lại test file hiện tại**

```bash
cat be/apps/ecommerce/src/auth/auth.service.spec.ts
```

Ghi nhớ các test case đang cover exception nào để xác nhận sau migrate vẫn pass.

- [ ] **Bước 2: Thay toàn bộ import exception NestJS trong auth.service.ts**

Tìm dòng import hiện tại (dòng 1-10):
```ts
import {
  BadRequestException,
  ConflictException,
  Inject,
  Injectable,
  NotFoundException,
  UnauthorizedException,
} from '@nestjs/common';
```

Thay thành:
```ts
import {
  Inject,
  Injectable,
} from '@nestjs/common';
import { AppException } from '@app/common';
```

- [ ] **Bước 3: Migrate từng exception — theo bảng mapping**

Thay thế lần lượt (dùng editor hoặc sed):

| Tìm | Thay bằng |
|---|---|
| `throw new ConflictException('Email da duoc dang ky')` | `throw new AppException('AUTH_EMAIL_CONFLICT')` |
| `throw new UnauthorizedException('Sai email hoac mat khau')` | `throw new AppException('AUTH_INVALID_CREDENTIALS', 'Sai email hoặc mật khẩu')` |
| `throw new UnauthorizedException('Firebase token khong chua email')` | `throw new AppException('AUTH_FIREBASE_NO_EMAIL')` |
| `throw new UnauthorizedException(\n                'Tai khoan da duoc lien ket Firebase khac',\n              )()` | `throw new AppException('AUTH_FIREBASE_UID_MISMATCH')` |
| `throw new UnauthorizedException(\n                'Khong the dang nhap bang Firebase',\n              )` | `throw new AppException('AUTH_FIREBASE_LOGIN_FAILED')` |
| `throw new UnauthorizedException(\n        'Refresh token khong hop le hoac da het han',\n      )` | `throw new AppException('AUTH_TOKEN_INVALID')` |
| `throw new UnauthorizedException('Tai khoan khong con hieu luc')` | `throw new AppException('AUTH_ACCOUNT_INACTIVE')` |
| `throw new BadRequestException('Ma khong dung hoac da het han')` (×2 — `verifyEmail` và `resetPassword`) | `throw new AppException('AUTH_OTP_INVALID')` |
| `throw new UnauthorizedException('Mat khau cu khong dung')` | `throw new AppException('AUTH_INVALID_CREDENTIALS', 'Mật khẩu cũ không đúng')` |
| `throw new UnauthorizedException()` (generic, xuất hiện nhiều lần trong `me`, `resendVerifyEmail`, `listAddresses`, `addAddress`, `updateAddress`, `deleteAddress`, `setDefaultAddress`, `saveAddresses`) | `throw new AppException('UNAUTHENTICATED')` |
| `throw new NotFoundException('Customer not found')` (trong `objectId`) | `throw new AppException('NOT_FOUND', 'Customer not found')` |
| `throw new NotFoundException('Address not found')` (×2 — `updateAddress`, `deleteAddress`, `setDefaultAddress`) | `throw new AppException('NOT_FOUND', 'Địa chỉ không tồn tại')` |

- [ ] **Bước 4: Kiểm tra không còn import NestJS exception thô**

```bash
grep -n "BadRequestException\|NotFoundException\|UnauthorizedException\|ConflictException\|ForbiddenException" be/apps/ecommerce/src/auth/auth.service.ts
```

Expected: không có output (0 dòng).

- [ ] **Bước 5: Chạy test**

```bash
cd be && pnpm test --testPathPattern="apps/ecommerce/src/auth/auth.service.spec"
```

Expected: PASS tất cả. Nếu test mock `UnauthorizedException` → cần cập nhật mock sang `AppException` cùng code tương ứng.

- [ ] **Bước 6: Build kiểm tra type**

```bash
cd be && pnpm build 2>&1 | grep -E "error TS|apps/ecommerce/src/auth"
```

Expected: không có lỗi TypeScript trong auth.service.ts.

- [ ] **Bước 7: Commit**

```bash
git add apps/ecommerce/src/auth/auth.service.ts apps/ecommerce/src/auth/auth.service.spec.ts
git commit -m "feat(ecom-auth): migrate exception sang AppException có mã lỗi ổn định"
```

---

### Task 4: Migrate auth.service.ts — WMS

**Files:**
- Modify: `apps/wms/src/auth/auth.service.ts`

**Interfaces:**
- Consumes: `AppException` từ `@app/common`, các codes từ `ERROR_CATALOG` (Task 1).

- [ ] **Bước 1: Xem lại test file hiện tại**

```bash
cat be/apps/wms/src/auth/auth.service.spec.ts 2>/dev/null || echo "no spec file"
```

- [ ] **Bước 2: Thay import exception NestJS**

Tìm dòng import hiện tại (dòng 1-8):
```ts
import {
  ForbiddenException,
  Inject,
  Injectable,
  NotFoundException,
  UnauthorizedException,
} from '@nestjs/common';
```

Thay thành:
```ts
import {
  Inject,
  Injectable,
} from '@nestjs/common';
import { AppException } from '@app/common';
```

- [ ] **Bước 3: Migrate từng exception — theo bảng mapping**

| Tìm | Thay bằng |
|---|---|
| `throw new UnauthorizedException('Sai tai khoan hoac mat khau')` | `throw new AppException('AUTH_INVALID_CREDENTIALS', 'Sai tài khoản hoặc mật khẩu')` |
| `throw new UnauthorizedException('Firebase token khong chua email')` | `throw new AppException('AUTH_FIREBASE_NO_EMAIL')` |
| `throw new UnauthorizedException('Nhan vien chua duoc khoi tao trong WMS')` (×2) | `throw new AppException('AUTH_WMS_NOT_INITIALIZED')` |
| `throw new UnauthorizedException(\n            'Tai khoan da duoc lien ket Firebase khac',\n          )()` | `throw new AppException('AUTH_FIREBASE_UID_MISMATCH')` |
| `throw new UnauthorizedException(\n        'Refresh token khong hop le hoac da het han',\n      )` | `throw new AppException('AUTH_TOKEN_INVALID')` |
| `throw new UnauthorizedException('Tai khoan khong con hieu luc')` | `throw new AppException('AUTH_ACCOUNT_INACTIVE')` |
| `throw new UnauthorizedException()` (generic, trong `me`) | `throw new AppException('UNAUTHENTICATED')` |
| `throw new ForbiddenException('Da co nhan vien trong he thong')` | `throw new AppException('AUTH_BOOTSTRAP_FORBIDDEN')` |
| `throw new NotFoundException('User not found')` (×4 — `objectId`, `updateRoles`, `lockUser`, `unlockUser`, `resetTemporaryPassword`) | `throw new AppException('NOT_FOUND', 'User not found')` |
| `throw new UnauthorizedException('Mat khau cu khong dung')` | `throw new AppException('AUTH_INVALID_CREDENTIALS', 'Mật khẩu cũ không đúng')` |

- [ ] **Bước 4: Kiểm tra không còn import NestJS exception thô**

```bash
grep -n "BadRequestException\|NotFoundException\|UnauthorizedException\|ConflictException\|ForbiddenException" be/apps/wms/src/auth/auth.service.ts
```

Expected: không có output.

- [ ] **Bước 5: Chạy toàn bộ test suite**

```bash
cd be && pnpm test
```

Expected: PASS tất cả. Cập nhật spec file nếu có test đang mock NestJS exception cụ thể.

- [ ] **Bước 6: Build kiểm tra type**

```bash
cd be && pnpm build 2>&1 | grep "error TS"
```

Expected: không có lỗi.

- [ ] **Bước 7: Commit**

```bash
git add apps/wms/src/auth/auth.service.ts
git commit -m "feat(wms-auth): migrate exception sang AppException có mã lỗi ổn định"
```

---

## Checklist Tự Kiểm Tra Sau Hoàn Thành

- [ ] `grep -rn "throw new BadRequestException\|throw new UnauthorizedException\|throw new ConflictException\|throw new ForbiddenException\|throw new NotFoundException" be/apps/*/src/auth/auth.service.ts` → 0 kết quả
- [ ] `pnpm test` từ `be/` → PASS
- [ ] `pnpm build` từ `be/` → không có lỗi TypeScript
- [ ] `be/.claude/rules/error-handling.md` đã tồn tại và được import qua `CLAUDE.md`
