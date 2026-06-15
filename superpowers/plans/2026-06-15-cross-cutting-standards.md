# Chuẩn hóa cross-cutting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Chuẩn hóa response envelope, mã lỗi, logging có correlation id, throttle phân tầng và phân trang (cursor keyset + offset) dùng chung cho cả 3 app.

**Architecture:** Mọi tiện ích dùng chung đặt ở `libs/common` (`@app/common`). Filter + ResponseInterceptor + ValidationPipe đăng ký global qua DI trong `CommonModule` (APP_FILTER/APP_INTERCEPTOR/APP_PIPE) để inject được `Reflector`/`PinoLogger`. Logging dùng `nestjs-pino` cấu hình qua helper chung. Mỗi `main.ts` chỉ gọi 1 helper `setupApp()`.

**Tech Stack:** NestJS 11, `nestjs-pino` + `pino-http` + `pino-pretty`, `@nestjs/throttler` 6, `class-validator`/`class-transformer`, Zod (env), Jest + ts-jest.

**Spec:** `docs/superpowers/specs/2026-06-15-cross-cutting-standards-design.md`

---

## File Structure

**Tạo mới trong `libs/common/src/`:**
- `errors/error-codes.ts` — catalog mã lỗi chung + status/message mặc định
- `errors/app.exception.ts` — `AppException`
- `errors/index.ts` — re-export
- `filters/all-exceptions.filter.ts` — **viết lại** (đã tồn tại) → output `{ error, meta }`
- `interceptors/response.interceptor.ts` — bọc `{ data, meta }` + gộp pagination
- `decorators/raw-response.decorator.ts` — `@RawResponse()` opt-out
- `decorators/throttle.decorators.ts` — `@AuthThrottle()` + re-export `SkipThrottle`
- `pagination/cursor.ts` — `encodeCursor`/`decodeCursor`/`buildKeysetFilter`/`buildCursorPage`
- `pagination/offset.ts` — `buildOffsetMeta`
- `pagination/paginated-result.ts` — `PaginatedResult`, type meta
- `pagination/dto.ts` — `OffsetPaginationQuery`, `CursorPaginationQuery`
- `pagination/index.ts` — re-export
- `logging/pino.options.ts` — `buildPinoOptions(config)`
- `logging/sanitize.ts` — `sanitizeForLog` (redact + truncate response)
- `throttle/throttler.config.ts` — `buildThrottlerOptions(config)`
- `bootstrap/setup-app.ts` — `setupApp(app, opts)`

**Sửa:**
- `libs/common/src/common.module.ts` — provide APP_FILTER/APP_INTERCEPTOR/APP_PIPE
- `libs/common/src/index.ts` — export mọi thứ mới, bỏ `logging.interceptor`
- `libs/common/src/interceptors/logging.interceptor.ts` — **xóa**
- `apps/{wms,ecommerce,notification}/src/config/env.validation.ts` — thêm env logging/throttle
- `apps/wms/src/app.module.ts`, `apps/ecommerce/src/ecommerce.module.ts`, `apps/notification/src/notification.module.ts` — LoggerModule + throttler async + CommonModule
- `apps/{wms,ecommerce,notification}/src/main.ts` — dùng `setupApp`
- `apps/wms/src/auth/auth.controller.ts`, `apps/ecommerce/src/auth/auth.controller.ts` — `@AuthThrottle()` cho login/refresh/register/forgot
- `apps/{wms,ecommerce,notification}/src/health/health.controller.ts` — `@SkipThrottle()`
- `.env.example`, `package.json` (deps)

---

## Task 1: Cài dependencies logging

**Files:**
- Modify: `package.json`

- [ ] **Step 1: Cài nestjs-pino + pino**

Run:
```bash
pnpm add nestjs-pino pino-http && pnpm add -D pino-pretty
```
Expected: `package.json` thêm `nestjs-pino`, `pino-http` vào dependencies và `pino-pretty` vào devDependencies; `pnpm-lock.yaml` cập nhật.

- [ ] **Step 2: Verify build vẫn xanh**

Run: `pnpm build`
Expected: build thành công (chưa dùng package mới nên không lỗi).

- [ ] **Step 3: Commit**

```bash
git add package.json pnpm-lock.yaml
git commit -m "chore: thêm nestjs-pino cho structured logging"
```

---

## Task 2: Error codes catalog + AppException

**Files:**
- Create: `libs/common/src/errors/error-codes.ts`
- Create: `libs/common/src/errors/app.exception.ts`
- Create: `libs/common/src/errors/index.ts`
- Test: `libs/common/src/errors/app.exception.spec.ts`

- [ ] **Step 1: Viết catalog mã lỗi**

Create `libs/common/src/errors/error-codes.ts`:
```ts
import { HttpStatus } from '@nestjs/common';

/**
 * Catalog mã lỗi CHUNG cho mọi app. Mỗi code có HTTP status + message mặc định.
 * App tự thêm mã miền (vd STOCK_INSUFFICIENT) ở apps/<app>/src/common/error-codes.ts —
 * AppException nhận mọi chuỗi code, không bắt buộc nằm trong catalog này.
 */
export const ERROR_CATALOG = {
  VALIDATION_FAILED: { status: HttpStatus.BAD_REQUEST, message: 'Dữ liệu không hợp lệ' },
  UNAUTHENTICATED: { status: HttpStatus.UNAUTHORIZED, message: 'Chưa xác thực' },
  FORBIDDEN: { status: HttpStatus.FORBIDDEN, message: 'Không đủ quyền truy cập' },
  NOT_FOUND: { status: HttpStatus.NOT_FOUND, message: 'Không tìm thấy tài nguyên' },
  CONFLICT: { status: HttpStatus.CONFLICT, message: 'Xung đột trạng thái' },
  RATE_LIMITED: { status: HttpStatus.TOO_MANY_REQUESTS, message: 'Quá nhiều yêu cầu, thử lại sau' },
  INTERNAL: { status: HttpStatus.INTERNAL_SERVER_ERROR, message: 'Lỗi hệ thống' },
} as const;

export type CommonErrorCode = keyof typeof ERROR_CATALOG;
```

- [ ] **Step 2: Viết failing test cho AppException**

Create `libs/common/src/errors/app.exception.spec.ts`:
```ts
import { HttpStatus } from '@nestjs/common';
import { AppException } from './app.exception';

describe('AppException', () => {
  it('dùng status + message mặc định từ catalog khi chỉ truyền code', () => {
    const ex = new AppException('NOT_FOUND');
    expect(ex.getStatus()).toBe(HttpStatus.NOT_FOUND);
    expect(ex.getResponse()).toEqual({
      code: 'NOT_FOUND',
      message: 'Không tìm thấy tài nguyên',
    });
  });

  it('cho phép override message, status và details', () => {
    const ex = new AppException('STOCK_INSUFFICIENT', 'Không đủ tồn', 409, [
      { field: 'quantity', issue: 'available=3 < requested=5' },
    ]);
    expect(ex.getStatus()).toBe(409);
    expect(ex.code).toBe('STOCK_INSUFFICIENT');
    expect(ex.getResponse()).toEqual({
      code: 'STOCK_INSUFFICIENT',
      message: 'Không đủ tồn',
      details: [{ field: 'quantity', issue: 'available=3 < requested=5' }],
    });
  });

  it('mã miền không có trong catalog + không truyền status → mặc định 400', () => {
    const ex = new AppException('ORDER_NOT_CANCELLABLE', 'Đơn không thể hủy');
    expect(ex.getStatus()).toBe(HttpStatus.BAD_REQUEST);
  });
});
```

- [ ] **Step 3: Chạy test để xác nhận FAIL**

Run: `pnpm jest libs/common/src/errors/app.exception.spec.ts`
Expected: FAIL — `Cannot find module './app.exception'`.

- [ ] **Step 4: Viết AppException**

Create `libs/common/src/errors/app.exception.ts`:
```ts
import { HttpException, HttpStatus } from '@nestjs/common';
import { ERROR_CATALOG } from './error-codes';

/** 1 dòng lỗi chi tiết (vd lỗi field từ validate). */
export interface ErrorDetail {
  field?: string;
  issue: string;
}

/**
 * Exception nghiệp vụ chuẩn: mang `code` chuỗi ổn định (FE switch-case không phụ
 * thuộc message tiếng Việt), message, details và HTTP status.
 * Nếu code nằm trong ERROR_CATALOG và không truyền status/message → dùng mặc định.
 */
export class AppException extends HttpException {
  readonly code: string;
  readonly details?: unknown;

  constructor(code: string, message?: string, status?: number, details?: unknown) {
    const fallback = (ERROR_CATALOG as Record<string, { status: number; message: string }>)[code];
    const resolvedStatus = status ?? fallback?.status ?? HttpStatus.BAD_REQUEST;
    const resolvedMessage = message ?? fallback?.message ?? code;
    super(
      { code, message: resolvedMessage, ...(details !== undefined ? { details } : {}) },
      resolvedStatus,
    );
    this.code = code;
    this.details = details;
  }
}
```

- [ ] **Step 5: Viết errors/index.ts**

Create `libs/common/src/errors/index.ts`:
```ts
export * from './error-codes';
export * from './app.exception';
```

- [ ] **Step 6: Chạy test để xác nhận PASS**

Run: `pnpm jest libs/common/src/errors/app.exception.spec.ts`
Expected: PASS — 3 test.

- [ ] **Step 7: Commit**

```bash
git add libs/common/src/errors
git commit -m "feat(common): error catalog + AppException"
```

---

## Task 3: AllExceptionsFilter viết lại

**Files:**
- Modify (ghi đè toàn bộ): `libs/common/src/filters/all-exceptions.filter.ts`
- Test: `libs/common/src/filters/all-exceptions.filter.spec.ts`

- [ ] **Step 1: Viết failing test**

Create `libs/common/src/filters/all-exceptions.filter.spec.ts`:
```ts
import { BadRequestException, ArgumentsHost } from '@nestjs/common';
import { ThrottlerException } from '@nestjs/throttler';
import { AppException } from '../errors/app.exception';
import { AllExceptionsFilter } from './all-exceptions.filter';

function mockHost(): { host: ArgumentsHost; json: jest.Mock; status: jest.Mock } {
  const json = jest.fn();
  const status = jest.fn().mockReturnValue({ json });
  const req = { method: 'GET', url: '/api/wms/x', id: 'req-1', headers: {} };
  const res = { status };
  const host = {
    switchToHttp: () => ({ getResponse: () => res, getRequest: () => req }),
  } as unknown as ArgumentsHost;
  return { host, json, status };
}

describe('AllExceptionsFilter', () => {
  const filter = new AllExceptionsFilter();

  it('AppException → giữ nguyên code/message/details + status', () => {
    const { host, json, status } = mockHost();
    filter.catch(new AppException('STOCK_INSUFFICIENT', 'Không đủ tồn', 409, [{ issue: 'x' }]), host);
    expect(status).toHaveBeenCalledWith(409);
    expect(json).toHaveBeenCalledWith({
      error: { code: 'STOCK_INSUFFICIENT', message: 'Không đủ tồn', details: [{ issue: 'x' }] },
      meta: { requestId: 'req-1', timestamp: expect.any(String), path: '/api/wms/x' },
    });
  });

  it('ValidationPipe (message mảng) → VALIDATION_FAILED + details', () => {
    const { host, json } = mockHost();
    filter.catch(new BadRequestException(['name không được trống']), host);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: { code: 'VALIDATION_FAILED', message: 'Dữ liệu không hợp lệ', details: ['name không được trống'] },
      }),
    );
  });

  it('ThrottlerException → RATE_LIMITED 429', () => {
    const { host, json, status } = mockHost();
    filter.catch(new ThrottlerException(), host);
    expect(status).toHaveBeenCalledWith(429);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: 'RATE_LIMITED' }) }),
    );
  });

  it('lỗi lạ → INTERNAL 500, giấu chi tiết', () => {
    const { host, json, status } = mockHost();
    filter.catch(new Error('db down secret'), host);
    expect(status).toHaveBeenCalledWith(500);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: { code: 'INTERNAL', message: 'Lỗi hệ thống' } }),
    );
  });
});
```

- [ ] **Step 2: Chạy test để xác nhận FAIL**

Run: `pnpm jest libs/common/src/filters/all-exceptions.filter.spec.ts`
Expected: FAIL — output cũ là `{ statusCode, message, path, timestamp }`, không khớp shape mới.

- [ ] **Step 3: Ghi đè filter**

Overwrite `libs/common/src/filters/all-exceptions.filter.ts`:
```ts
import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { ThrottlerException } from '@nestjs/throttler';
import type { Request, Response } from 'express';
import { AppException } from '../errors/app.exception';

/** Map HTTP status (từ HttpException của Nest) → mã lỗi chuẩn. */
const STATUS_TO_CODE: Record<number, string> = {
  400: 'VALIDATION_FAILED',
  401: 'UNAUTHENTICATED',
  403: 'FORBIDDEN',
  404: 'NOT_FOUND',
  409: 'CONFLICT',
  429: 'RATE_LIMITED',
};

/**
 * Bắt MỌI exception → output chuẩn { error: { code, message, details? }, meta }.
 * Vì sao: FE switch theo error.code (ổn định) thay vì message; lỗi 5xx giấu chi tiết
 * khỏi client nhưng log full stack ở server kèm requestId để trace.
 */
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger('Exception');

  catch(exception: unknown, host: ArgumentsHost): void {
    const ctx = host.switchToHttp();
    const res = ctx.getResponse<Response>();
    const req = ctx.getRequest<Request & { id?: string }>();
    const requestId = req.id ?? (req.headers['x-request-id'] as string | undefined);

    let status = HttpStatus.INTERNAL_SERVER_ERROR;
    let code = 'INTERNAL';
    let message = 'Lỗi hệ thống';
    let details: unknown;

    if (exception instanceof AppException) {
      status = exception.getStatus();
      const body = exception.getResponse() as { code: string; message: string; details?: unknown };
      code = body.code;
      message = body.message;
      details = body.details;
    } else if (exception instanceof ThrottlerException) {
      status = HttpStatus.TOO_MANY_REQUESTS;
      code = 'RATE_LIMITED';
      message = 'Quá nhiều yêu cầu, thử lại sau';
    } else if (exception instanceof HttpException) {
      status = exception.getStatus();
      code = STATUS_TO_CODE[status] ?? 'INTERNAL';
      const body = exception.getResponse();
      if (typeof body === 'string') {
        message = body;
      } else {
        const b = body as { message?: unknown };
        if (Array.isArray(b.message)) {
          message = 'Dữ liệu không hợp lệ';
          details = b.message;
        } else if (typeof b.message === 'string') {
          message = b.message;
        }
      }
    }

    if (status >= 500) {
      this.logger.error(
        `${req.method} ${req.url} → ${status} [reqId=${requestId}]`,
        exception instanceof Error ? exception.stack : String(exception),
      );
    }

    res.status(status).json({
      error: { code, message, ...(details !== undefined ? { details } : {}) },
      meta: { requestId, timestamp: new Date().toISOString(), path: req.url },
    });
  }
}
```

- [ ] **Step 4: Chạy test để xác nhận PASS**

Run: `pnpm jest libs/common/src/filters/all-exceptions.filter.spec.ts`
Expected: PASS — 4 test.

- [ ] **Step 5: Commit**

```bash
git add libs/common/src/filters/all-exceptions.filter.ts libs/common/src/filters/all-exceptions.filter.spec.ts
git commit -m "feat(common): filter trả error envelope { error, meta } theo mã lỗi"
```

---

## Task 4: Pagination — cursor keyset

**Files:**
- Create: `libs/common/src/pagination/paginated-result.ts`
- Create: `libs/common/src/pagination/cursor.ts`
- Test: `libs/common/src/pagination/cursor.spec.ts`

- [ ] **Step 1: Viết types + PaginatedResult**

Create `libs/common/src/pagination/paginated-result.ts`:
```ts
export interface OffsetMeta {
  type: 'offset';
  page: number;
  limit: number;
  totalItems?: number;
  totalPages?: number;
  hasNext: boolean;
  hasPrev: boolean;
}

export interface CursorMeta {
  type: 'cursor';
  limit: number;
  nextCursor: string | null;
  hasNext: boolean;
}

/**
 * Marker để ResponseInterceptor nhận diện: trả về cái này từ controller thì
 * `items` thành `data` và `pagination` được gộp vào `meta`.
 */
export class PaginatedResult<T> {
  constructor(
    readonly items: T[],
    readonly pagination: OffsetMeta | CursorMeta,
  ) {}
}
```

- [ ] **Step 2: Viết failing test cho cursor**

Create `libs/common/src/pagination/cursor.spec.ts`:
```ts
import { AppException } from '../errors/app.exception';
import { buildCursorPage, buildKeysetFilter, decodeCursor, encodeCursor } from './cursor';

describe('cursor', () => {
  it('encode rồi decode trả lại payload ban đầu', () => {
    const c = encodeCursor({ sortValue: '2026-06-15T00:00:00.000Z', id: 'abc' });
    expect(typeof c).toBe('string');
    expect(decodeCursor(c)).toEqual({ sortValue: '2026-06-15T00:00:00.000Z', id: 'abc' });
  });

  it('cursor hỏng → AppException VALIDATION_FAILED', () => {
    expect(() => decodeCursor('@@@khong-phai-base64@@@')).toThrow(AppException);
  });

  it('buildKeysetFilter desc → $or so sánh (sortField,_id) bằng $lt', () => {
    const filter = buildKeysetFilter({
      sortField: 'createdAt',
      direction: 'desc',
      cursor: { sortValue: 'T', id: 'id1' },
    });
    expect(filter).toEqual({
      $or: [
        { createdAt: { $lt: 'T' } },
        { createdAt: 'T', _id: { $lt: 'id1' } },
      ],
    });
  });

  it('buildKeysetFilter không cursor → filter rỗng', () => {
    expect(buildKeysetFilter({ sortField: 'createdAt', direction: 'desc' })).toEqual({});
  });

  it('buildCursorPage: dư 1 bản ghi → hasNext=true, cắt còn limit, có nextCursor', () => {
    const rows = [
      { _id: 'a', createdAt: 't3' },
      { _id: 'b', createdAt: 't2' },
      { _id: 'c', createdAt: 't1' },
    ];
    const page = buildCursorPage(rows, 2, 'createdAt');
    expect(page.items).toHaveLength(2);
    expect(page.pagination).toMatchObject({ type: 'cursor', limit: 2, hasNext: true });
    expect((page.pagination as { nextCursor: string }).nextCursor).toBe(
      encodeCursor({ sortValue: 't2', id: 'b' }),
    );
  });

  it('buildCursorPage: không dư → hasNext=false, nextCursor=null', () => {
    const page = buildCursorPage([{ _id: 'a', createdAt: 't1' }], 2, 'createdAt');
    expect(page.items).toHaveLength(1);
    expect(page.pagination).toMatchObject({ hasNext: false, nextCursor: null });
  });
});
```

- [ ] **Step 3: Chạy test để xác nhận FAIL**

Run: `pnpm jest libs/common/src/pagination/cursor.spec.ts`
Expected: FAIL — `Cannot find module './cursor'`.

- [ ] **Step 4: Viết cursor.ts**

Create `libs/common/src/pagination/cursor.ts`:
```ts
import { AppException } from '../errors/app.exception';
import { PaginatedResult } from './paginated-result';

export type SortDirection = 'asc' | 'desc';

interface CursorPayload {
  sortValue: unknown;
  id: string;
}

/** Mã hóa cursor (keyset) thành chuỗi opaque base64url — không lộ field nội bộ. */
export function encodeCursor(payload: CursorPayload): string {
  return Buffer.from(JSON.stringify(payload)).toString('base64url');
}

/** Giải mã cursor; sai định dạng → VALIDATION_FAILED. */
export function decodeCursor(cursor: string): CursorPayload {
  try {
    const json = Buffer.from(cursor, 'base64url').toString('utf8');
    const parsed = JSON.parse(json) as CursorPayload;
    if (typeof parsed !== 'object' || parsed === null || !('id' in parsed)) {
      throw new Error('shape');
    }
    return parsed;
  } catch {
    throw new AppException('VALIDATION_FAILED', 'Cursor không hợp lệ');
  }
}

/**
 * Dựng filter Mongo theo keyset: lấy bản ghi NẰM SAU cursor theo (sortField, _id).
 * Không dùng skip → nhanh & ổn định khi data thay đổi giữa các trang.
 */
export function buildKeysetFilter(opts: {
  sortField: string;
  direction: SortDirection;
  cursor?: CursorPayload;
}): Record<string, unknown> {
  const { sortField, direction, cursor } = opts;
  if (!cursor) return {};
  const cmp = direction === 'asc' ? '$gt' : '$lt';
  return {
    $or: [
      { [sortField]: { [cmp]: cursor.sortValue } },
      { [sortField]: cursor.sortValue, _id: { [cmp]: cursor.id } },
    ],
  };
}

/**
 * Từ mảng rows đã query (nên query limit+1 để biết còn trang sau), dựng
 * PaginatedResult cursor: cắt còn `limit`, sinh nextCursor từ phần tử cuối.
 */
export function buildCursorPage<T extends { _id: unknown }>(
  rows: T[],
  limit: number,
  sortField: string,
): PaginatedResult<T> {
  const hasNext = rows.length > limit;
  const items = hasNext ? rows.slice(0, limit) : rows;
  let nextCursor: string | null = null;
  if (hasNext && items.length > 0) {
    const last = items[items.length - 1] as Record<string, unknown>;
    nextCursor = encodeCursor({ sortValue: last[sortField], id: String(last._id) });
  }
  return new PaginatedResult(items, { type: 'cursor', limit, nextCursor, hasNext });
}
```

- [ ] **Step 5: Chạy test để xác nhận PASS**

Run: `pnpm jest libs/common/src/pagination/cursor.spec.ts`
Expected: PASS — 6 test.

- [ ] **Step 6: Commit**

```bash
git add libs/common/src/pagination/paginated-result.ts libs/common/src/pagination/cursor.ts libs/common/src/pagination/cursor.spec.ts
git commit -m "feat(common): phân trang cursor keyset (opaque base64url)"
```

---

## Task 5: Pagination — offset meta + DTOs

**Files:**
- Create: `libs/common/src/pagination/offset.ts`
- Create: `libs/common/src/pagination/dto.ts`
- Create: `libs/common/src/pagination/index.ts`
- Test: `libs/common/src/pagination/offset.spec.ts`

- [ ] **Step 1: Viết failing test cho offset**

Create `libs/common/src/pagination/offset.spec.ts`:
```ts
import { buildOffsetMeta } from './offset';

describe('buildOffsetMeta', () => {
  it('có totalItems → tính totalPages/hasNext/hasPrev', () => {
    expect(buildOffsetMeta(20, 1, 20, 137)).toEqual({
      type: 'offset', page: 1, limit: 20, totalItems: 137, totalPages: 7, hasNext: true, hasPrev: false,
    });
  });

  it('trang cuối có totalItems → hasNext=false', () => {
    expect(buildOffsetMeta(17, 7, 20, 137)).toMatchObject({ hasNext: false, hasPrev: true });
  });

  it('không totalItems → hasNext suy từ số phần tử trả về (đầy limit)', () => {
    expect(buildOffsetMeta(20, 2, 20)).toEqual({
      type: 'offset', page: 2, limit: 20, hasNext: true, hasPrev: true,
    });
  });

  it('không totalItems, trả ít hơn limit → hasNext=false', () => {
    expect(buildOffsetMeta(5, 1, 20)).toMatchObject({ hasNext: false, hasPrev: false });
  });
});
```

- [ ] **Step 2: Chạy test để xác nhận FAIL**

Run: `pnpm jest libs/common/src/pagination/offset.spec.ts`
Expected: FAIL — `Cannot find module './offset'`.

- [ ] **Step 3: Viết offset.ts**

Create `libs/common/src/pagination/offset.ts`:
```ts
import { OffsetMeta } from './paginated-result';

/**
 * Dựng meta phân trang offset. `totalItems` OPTIONAL: chỉ truyền khi màn admin
 * cần số trang (tốn thêm 1 query count). Không có thì suy hasNext từ số phần tử.
 */
export function buildOffsetMeta(
  itemCount: number,
  page: number,
  limit: number,
  totalItems?: number,
): OffsetMeta {
  if (totalItems !== undefined) {
    const totalPages = Math.ceil(totalItems / limit);
    return {
      type: 'offset',
      page,
      limit,
      totalItems,
      totalPages,
      hasNext: page < totalPages,
      hasPrev: page > 1,
    };
  }
  return {
    type: 'offset',
    page,
    limit,
    hasNext: itemCount === limit,
    hasPrev: page > 1,
  };
}
```

- [ ] **Step 4: Chạy test để xác nhận PASS**

Run: `pnpm jest libs/common/src/pagination/offset.spec.ts`
Expected: PASS — 4 test.

- [ ] **Step 5: Viết DTOs query**

Create `libs/common/src/pagination/dto.ts`:
```ts
import { Type } from 'class-transformer';
import { IsInt, IsOptional, IsString, Max, Min } from 'class-validator';

/** Query phân trang offset (màn admin). limit có trần chống quét nặng. */
export class OffsetPaginationQuery {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  page = 1;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit = 20;
}

/** Query phân trang cursor (API chính). cursor là chuỗi opaque. */
export class CursorPaginationQuery {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit = 20;

  @IsOptional()
  @IsString()
  cursor?: string;
}
```

- [ ] **Step 6: Viết pagination/index.ts**

Create `libs/common/src/pagination/index.ts`:
```ts
export * from './paginated-result';
export * from './cursor';
export * from './offset';
export * from './dto';
```

- [ ] **Step 7: Commit**

```bash
git add libs/common/src/pagination
git commit -m "feat(common): phân trang offset meta + DTO query"
```

---

## Task 6: Sanitize log (redact + truncate)

**Files:**
- Create: `libs/common/src/logging/sanitize.ts`
- Test: `libs/common/src/logging/sanitize.spec.ts`

- [ ] **Step 1: Viết failing test**

Create `libs/common/src/logging/sanitize.spec.ts`:
```ts
import { sanitizeForLog } from './sanitize';

describe('sanitizeForLog', () => {
  it('che field nhạy cảm bất kể hoa/thường', () => {
    expect(sanitizeForLog({ username: 'a', password: 'secret', refreshToken: 'r' })).toEqual({
      username: 'a',
      password: '[REDACTED]',
      refreshToken: '[REDACTED]',
    });
  });

  it('che lồng sâu trong object', () => {
    expect(sanitizeForLog({ data: { user: { token: 'x', name: 'b' } } })).toEqual({
      data: { user: { token: '[REDACTED]', name: 'b' } },
    });
  });

  it('array dài hơn 50 → cắt thành mô tả', () => {
    const big = Array.from({ length: 51 }, (_, i) => i);
    expect(sanitizeForLog(big)).toBe('[Array(51) truncated]');
  });

  it('giữ nguyên giá trị primitive nhỏ', () => {
    expect(sanitizeForLog({ a: 1, b: 'x' })).toEqual({ a: 1, b: 'x' });
  });
});
```

- [ ] **Step 2: Chạy test để xác nhận FAIL**

Run: `pnpm jest libs/common/src/logging/sanitize.spec.ts`
Expected: FAIL — `Cannot find module './sanitize'`.

- [ ] **Step 3: Viết sanitize.ts**

Create `libs/common/src/logging/sanitize.ts`:
```ts
/** Field nhạy cảm bị che trong log (so khớp không phân biệt hoa/thường). */
const SENSITIVE_KEYS = new Set([
  'password',
  'currentpassword',
  'newpassword',
  'refreshtoken',
  'accesstoken',
  'token',
  'otp',
  'authorization',
  'cookie',
]);

const MAX_BYTES = 10 * 1024; // 10KB: response lớn hơn chỉ log mô tả
const MAX_ARRAY = 50; // array dài hơn không log full phần tử

/**
 * Làm sạch dữ liệu trước khi đưa vào log: che field nhạy cảm, cắt array/quá lớn.
 * Vì sao: log body request/response dễ rò mật khẩu/JWT và phình log.
 */
export function sanitizeForLog(value: unknown): unknown {
  const seen = new WeakSet<object>();

  function walk(v: unknown): unknown {
    if (Array.isArray(v)) {
      if (v.length > MAX_ARRAY) return `[Array(${v.length}) truncated]`;
      return v.map(walk);
    }
    if (v && typeof v === 'object') {
      if (seen.has(v)) return '[Circular]';
      seen.add(v);
      const out: Record<string, unknown> = {};
      for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
        out[k] = SENSITIVE_KEYS.has(k.toLowerCase()) ? '[REDACTED]' : walk(val);
      }
      return out;
    }
    return v;
  }

  const result = walk(value);
  const size = Buffer.byteLength(JSON.stringify(result) ?? '');
  if (size > MAX_BYTES) return `[Payload ${size} bytes truncated]`;
  return result;
}
```

- [ ] **Step 4: Chạy test để xác nhận PASS**

Run: `pnpm jest libs/common/src/logging/sanitize.spec.ts`
Expected: PASS — 4 test.

- [ ] **Step 5: Commit**

```bash
git add libs/common/src/logging/sanitize.ts libs/common/src/logging/sanitize.spec.ts
git commit -m "feat(common): sanitize log (redact field nhạy cảm + cắt payload lớn)"
```

---

## Task 7: Pino options helper

**Files:**
- Create: `libs/common/src/logging/pino.options.ts`

- [ ] **Step 1: Viết buildPinoOptions**

Create `libs/common/src/logging/pino.options.ts`:
```ts
import { randomUUID } from 'crypto';
import type { IncomingMessage, ServerResponse } from 'http';
import type { ConfigService } from '@nestjs/config';
import type { Params } from 'nestjs-pino';
import { sanitizeForLog } from './sanitize';

/**
 * Cấu hình nestjs-pino dùng chung cho mọi app:
 * - genReqId: đọc X-Request-Id của client hoặc sinh UUID, set lại vào response header.
 *   requestId này dùng cho envelope { meta.requestId } và error → trace 1 request.
 * - redact: che header/body nhạy cảm.
 * - serializer req: log method/url/body (đã sanitize).
 * - dev: pino-pretty; prod: JSON 1 dòng.
 */
export function buildPinoOptions(config: ConfigService): Params {
  const isProd = config.get<string>('NODE_ENV') === 'production';
  const level = config.get<string>('LOG_LEVEL') ?? 'info';

  return {
    pinoHttp: {
      level,
      genReqId: (req: IncomingMessage, res: ServerResponse) => {
        const existing =
          (req.headers['x-request-id'] as string | undefined) ?? randomUUID();
        res.setHeader('X-Request-Id', existing);
        return existing;
      },
      redact: {
        paths: [
          'req.headers.authorization',
          'req.headers.cookie',
          'req.body.password',
          'req.body.currentPassword',
          'req.body.newPassword',
          'req.body.refreshToken',
          'req.body.token',
          'req.body.otp',
        ],
        censor: '[REDACTED]',
      },
      serializers: {
        req(req: IncomingMessage & { id?: string; raw?: { body?: unknown } }) {
          return {
            id: req.id,
            method: req.method,
            url: req.url,
            body: sanitizeForLog(req.raw?.body),
          };
        },
      },
      transport: isProd
        ? undefined
        : { target: 'pino-pretty', options: { singleLine: true, translateTime: 'SYS:standard' } },
    },
  };
}
```

- [ ] **Step 2: Verify type-check**

Run: `pnpm exec tsc --noEmit -p libs/common/tsconfig.lib.json`
Expected: không lỗi type (nếu file tsconfig.lib.json không có sẵn target này, bỏ qua và dựa vào `pnpm build` ở Task 11).

- [ ] **Step 3: Commit**

```bash
git add libs/common/src/logging/pino.options.ts
git commit -m "feat(common): buildPinoOptions (correlation id + redact + pretty dev)"
```

---

## Task 8: ResponseInterceptor + decorators (RawResponse, AuthThrottle)

**Files:**
- Create: `libs/common/src/decorators/raw-response.decorator.ts`
- Create: `libs/common/src/decorators/throttle.decorators.ts`
- Create: `libs/common/src/interceptors/response.interceptor.ts`
- Test: `libs/common/src/interceptors/response.interceptor.spec.ts`

- [ ] **Step 1: Viết RawResponse decorator**

Create `libs/common/src/decorators/raw-response.decorator.ts`:
```ts
import { SetMetadata } from '@nestjs/common';

export const RAW_RESPONSE_KEY = 'raw_response';

/** Đánh dấu route KHÔNG bọc envelope (webhook/payment callback cần shape nguyên bản). */
export const RawResponse = () => SetMetadata(RAW_RESPONSE_KEY, true);
```

- [ ] **Step 2: Viết throttle decorators**

Create `libs/common/src/decorators/throttle.decorators.ts`:
```ts
import { Throttle, SkipThrottle } from '@nestjs/throttler';

/**
 * Throttle CHẶT cho route auth (login/register/refresh/forgot...) chống brute-force.
 * Giá trị là HẰNG (5 req/60s): decorator được đánh giá lúc import class — trước khi
 * ConfigModule nạp .env — nên không đọc env an toàn ở đây. Mức `default` mới lấy từ env.
 */
const AUTH_TTL_MS = 60_000;
const AUTH_LIMIT = 5;

export const AuthThrottle = () => Throttle({ default: { ttl: AUTH_TTL_MS, limit: AUTH_LIMIT } });

// Re-export để app chỉ import từ @app/common.
export { SkipThrottle };
```

- [ ] **Step 3: Viết failing test cho ResponseInterceptor**

Create `libs/common/src/interceptors/response.interceptor.spec.ts`:
```ts
import { ExecutionContext, CallHandler } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { lastValueFrom, of } from 'rxjs';
import { PaginatedResult } from '../pagination/paginated-result';
import { ResponseInterceptor } from './response.interceptor';

function ctx(handlerMeta = false): ExecutionContext {
  const req = { id: 'req-9', headers: {} };
  return {
    getType: () => 'http',
    getHandler: () => () => undefined,
    getClass: () => class {},
    switchToHttp: () => ({ getRequest: () => req }),
  } as unknown as ExecutionContext;
}

function reflectorWith(raw: boolean): Reflector {
  return { getAllAndOverride: () => raw } as unknown as Reflector;
}

describe('ResponseInterceptor', () => {
  it('bọc payload thường thành { data, meta }', async () => {
    const interceptor = new ResponseInterceptor(reflectorWith(false));
    const next: CallHandler = { handle: () => of({ id: 1 }) };
    const out = await lastValueFrom(interceptor.intercept(ctx(), next));
    expect(out).toEqual({
      data: { id: 1 },
      meta: { requestId: 'req-9', timestamp: expect.any(String) },
    });
  });

  it('PaginatedResult → data=items, meta.pagination', async () => {
    const interceptor = new ResponseInterceptor(reflectorWith(false));
    const paged = new PaginatedResult([{ id: 1 }], { type: 'cursor', limit: 20, nextCursor: null, hasNext: false });
    const next: CallHandler = { handle: () => of(paged) };
    const out = await lastValueFrom(interceptor.intercept(ctx(), next));
    expect(out).toEqual({
      data: [{ id: 1 }],
      meta: { requestId: 'req-9', timestamp: expect.any(String), pagination: paged.pagination },
    });
  });

  it('payload undefined → data=null', async () => {
    const interceptor = new ResponseInterceptor(reflectorWith(false));
    const next: CallHandler = { handle: () => of(undefined) };
    const out = await lastValueFrom(interceptor.intercept(ctx(), next));
    expect(out).toMatchObject({ data: null });
  });

  it('@RawResponse → trả nguyên payload, không bọc', async () => {
    const interceptor = new ResponseInterceptor(reflectorWith(true));
    const next: CallHandler = { handle: () => of({ raw: true }) };
    const out = await lastValueFrom(interceptor.intercept(ctx(), next));
    expect(out).toEqual({ raw: true });
  });
});
```

- [ ] **Step 4: Chạy test để xác nhận FAIL**

Run: `pnpm jest libs/common/src/interceptors/response.interceptor.spec.ts`
Expected: FAIL — `Cannot find module './response.interceptor'`.

- [ ] **Step 5: Viết ResponseInterceptor**

Create `libs/common/src/interceptors/response.interceptor.ts`:
```ts
import {
  CallHandler,
  ExecutionContext,
  Injectable,
  NestInterceptor,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { Request } from 'express';
import { Observable } from 'rxjs';
import { map } from 'rxjs/operators';
import { RAW_RESPONSE_KEY } from '../decorators/raw-response.decorator';
import { PaginatedResult } from '../pagination/paginated-result';

/**
 * Bọc MỌI response thành công thành { data, meta: { requestId, timestamp } }.
 * - PaginatedResult → data=items, gộp pagination vào meta.
 * - @RawResponse → bỏ qua (webhook/callback).
 */
@Injectable()
export class ResponseInterceptor implements NestInterceptor {
  constructor(private readonly reflector: Reflector) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    if (context.getType() !== 'http') return next.handle();

    const raw = this.reflector.getAllAndOverride<boolean>(RAW_RESPONSE_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (raw) return next.handle();

    const req = context.switchToHttp().getRequest<Request & { id?: string }>();
    const requestId = req.id ?? (req.headers['x-request-id'] as string | undefined);

    return next.handle().pipe(
      map((payload) => {
        const meta: Record<string, unknown> = {
          requestId,
          timestamp: new Date().toISOString(),
        };
        if (payload instanceof PaginatedResult) {
          meta.pagination = payload.pagination;
          return { data: payload.items, meta };
        }
        return { data: payload ?? null, meta };
      }),
    );
  }
}
```

- [ ] **Step 6: Chạy test để xác nhận PASS**

Run: `pnpm jest libs/common/src/interceptors/response.interceptor.spec.ts`
Expected: PASS — 4 test.

- [ ] **Step 7: Commit**

```bash
git add libs/common/src/decorators libs/common/src/interceptors/response.interceptor.ts libs/common/src/interceptors/response.interceptor.spec.ts
git commit -m "feat(common): ResponseInterceptor envelope + RawResponse/AuthThrottle decorators"
```

---

## Task 9: Throttler config helper + setupApp + CommonModule + index

**Files:**
- Create: `libs/common/src/throttle/throttler.config.ts`
- Create: `libs/common/src/bootstrap/setup-app.ts`
- Modify: `libs/common/src/common.module.ts`
- Modify: `libs/common/src/index.ts`
- Delete: `libs/common/src/interceptors/logging.interceptor.ts`

- [ ] **Step 1: Viết throttler config helper**

Create `libs/common/src/throttle/throttler.config.ts`:
```ts
import type { ConfigService } from '@nestjs/config';
import type { ThrottlerModuleOptions } from '@nestjs/throttler';

/**
 * 1 throttler `default` toàn cục, số lấy từ env. Route auth override chặt hơn
 * bằng @AuthThrottle() (xem throttle.decorators). Health bỏ qua bằng @SkipThrottle().
 */
export function buildThrottlerOptions(config: ConfigService): ThrottlerModuleOptions {
  return [
    {
      name: 'default',
      ttl: config.get<number>('THROTTLE_DEFAULT_TTL') ?? 60_000,
      limit: config.get<number>('THROTTLE_DEFAULT_LIMIT') ?? 100,
    },
  ];
}
```

- [ ] **Step 2: Viết setupApp**

Create `libs/common/src/bootstrap/setup-app.ts`:
```ts
import { INestApplication } from '@nestjs/common';
import { Logger } from 'nestjs-pino';
import helmet from 'helmet';
import { buildCorsOptions } from '../cors';

export interface SetupAppOptions {
  /** Danh sách origin CORS (CSV từ *_CORS_ORIGINS). */
  corsOrigins: string | undefined;
  isProd: boolean;
  /** Prefix toàn cục, vd 'api/wms'. */
  globalPrefix: string;
}

/**
 * Wiring chung mọi app: dùng pino làm logger Nest, helmet, CORS whitelist, prefix,
 * shutdown hooks. ValidationPipe/Filter/ResponseInterceptor đăng ký qua CommonModule
 * (cần DI) nên KHÔNG đặt ở đây.
 */
export function setupApp(app: INestApplication, opts: SetupAppOptions): void {
  app.useLogger(app.get(Logger)); // Nest log đi qua pino
  app.use(helmet());
  app.enableCors(buildCorsOptions(opts.corsOrigins, opts.isProd));
  app.setGlobalPrefix(opts.globalPrefix);
  app.enableShutdownHooks();
}
```

- [ ] **Step 3: Cập nhật CommonModule (global filter/interceptor/pipe qua DI)**

Overwrite `libs/common/src/common.module.ts`:
```ts
import { Module, ValidationPipe } from '@nestjs/common';
import { APP_FILTER, APP_INTERCEPTOR, APP_PIPE, Reflector } from '@nestjs/core';
import { AllExceptionsFilter } from './filters/all-exceptions.filter';
import { ResponseInterceptor } from './interceptors/response.interceptor';

/**
 * Đăng ký global qua DI (để inject Reflector/logger). App chỉ cần import CommonModule.
 * - APP_FILTER: chuẩn hóa error envelope.
 * - APP_INTERCEPTOR: bọc success envelope.
 * - APP_PIPE: ValidationPipe (whitelist + transform) cho mọi DTO.
 */
@Module({
  providers: [
    { provide: APP_FILTER, useClass: AllExceptionsFilter },
    {
      provide: APP_INTERCEPTOR,
      useFactory: (reflector: Reflector) => new ResponseInterceptor(reflector),
      inject: [Reflector],
    },
    {
      provide: APP_PIPE,
      useValue: new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
      }),
    },
  ],
})
export class CommonModule {}
```

- [ ] **Step 4: Xóa LoggingInterceptor cũ**

Run:
```bash
git rm libs/common/src/interceptors/logging.interceptor.ts
```
Expected: file bị xóa (pino-http thay thế).

- [ ] **Step 5: Cập nhật index.ts**

Overwrite `libs/common/src/index.ts`:
```ts
export * from './common.module';
export * from './common.service';
export * from './cors';
export * from './tokens';
export * from './errors';
export * from './pagination';
export * from './filters/all-exceptions.filter';
export * from './interceptors/response.interceptor';
export * from './decorators/raw-response.decorator';
export * from './decorators/throttle.decorators';
export * from './logging/pino.options';
export * from './logging/sanitize';
export * from './throttle/throttler.config';
export * from './bootstrap/setup-app';
```

- [ ] **Step 6: Verify build libs**

Run: `pnpm build`
Expected: build wms (mặc định) thành công — `@app/common` compile sạch.

- [ ] **Step 7: Commit**

```bash
git add libs/common/src
git commit -m "feat(common): CommonModule global (filter/interceptor/pipe) + setupApp + throttler helper, bỏ LoggingInterceptor"
```

---

## Task 10: Cập nhật env schema 3 app + .env.example

**Files:**
- Modify: `apps/wms/src/config/env.validation.ts`
- Modify: `apps/ecommerce/src/config/env.validation.ts`
- Modify: `apps/notification/src/config/env.validation.ts`
- Modify: `.env.example`

- [ ] **Step 1: Thêm block env chung vào WMS schema**

In `apps/wms/src/config/env.validation.ts`, thêm vào `z.object({ ... })` (sau `NODE_ENV`):
```ts
  // ---- Logging & throttle (chuẩn cross-cutting) ----
  LOG_LEVEL: z
    .enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace'])
    .default('info'),
  THROTTLE_DEFAULT_TTL: z.coerce.number().int().positive().default(60_000),
  THROTTLE_DEFAULT_LIMIT: z.coerce.number().int().positive().default(100),
```

- [ ] **Step 2: Lặp lại cho ecommerce schema**

In `apps/ecommerce/src/config/env.validation.ts`, thêm cùng block trên vào `z.object({ ... })` sau `NODE_ENV`.

- [ ] **Step 3: Lặp lại cho notification schema**

In `apps/notification/src/config/env.validation.ts`, thêm cùng block trên vào `z.object({ ... })` sau `NODE_ENV`.

- [ ] **Step 4: Cập nhật .env.example**

Append vào `.env.example`:
```bash
# ---- Logging & throttle (chuẩn cross-cutting, áp cho cả 3 app) ----
# LOG_LEVEL: fatal|error|warn|info|debug|trace
LOG_LEVEL=info
# Throttle mặc định toàn cục (route auth tự áp mức chặt 5/60s trong code).
THROTTLE_DEFAULT_TTL=60000
THROTTLE_DEFAULT_LIMIT=100
```

- [ ] **Step 5: Verify build**

Run: `pnpm build`
Expected: thành công.

- [ ] **Step 6: Commit**

```bash
git add apps/wms/src/config/env.validation.ts apps/ecommerce/src/config/env.validation.ts apps/notification/src/config/env.validation.ts .env.example
git commit -m "feat(config): thêm env LOG_LEVEL + THROTTLE_DEFAULT_* cho 3 app"
```

---

## Task 11: Wire WMS app (module + main)

**Files:**
- Modify: `apps/wms/src/app.module.ts`
- Modify: `apps/wms/src/main.ts`
- Modify: `apps/wms/src/auth/auth.controller.ts`
- Modify: `apps/wms/src/health/health.controller.ts`

- [ ] **Step 1: Cập nhật app.module.ts**

Overwrite `apps/wms/src/app.module.ts`:
```ts
import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { APP_GUARD } from '@nestjs/core';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { LoggerModule } from 'nestjs-pino';
import { CommonModule, buildPinoOptions, buildThrottlerOptions } from '@app/common';
import { DatabaseModule } from '@app/database';
import { EventsModule } from '@app/events';
import { AppController } from './app.controller';
import { AppService } from './app.service';
import { AuthModule } from './auth/auth.module';
import { HealthModule } from './health/health.module';
import { StockModule } from './stock/stock.module';
import { validateEnv } from './config/env.validation';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true, validate: validateEnv }),
    LoggerModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => buildPinoOptions(config),
    }),
    ThrottlerModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => buildThrottlerOptions(config),
    }),
    CommonModule, // global filter/interceptor/pipe
    DatabaseModule.forApp('WMS_DATABASE_URL'), // Mongoose → wms_db
    EventsModule, // BullMQ + Redis
    AuthModule, // đăng nhập nhân viên (users) + JWT
    HealthModule, // GET /api/wms/health
    StockModule, // producer mẫu: stock.changed
  ],
  controllers: [AppController],
  providers: [
    AppService,
    { provide: APP_GUARD, useClass: ThrottlerGuard }, // áp throttle cho mọi route
  ],
})
export class AppModule {}
```

- [ ] **Step 2: Cập nhật main.ts**

Overwrite `apps/wms/src/main.ts`:
```ts
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import { setupApp } from '@app/common';
import { AppModule } from './app.module';
import { Env } from './config/env.validation';

async function bootstrap() {
  const app = await NestFactory.create(AppModule, { bufferLogs: true });
  const config = app.get(ConfigService<Env, true>);

  setupApp(app, {
    corsOrigins: config.get('WMS_CORS_ORIGINS', { infer: true }),
    isProd: config.get('NODE_ENV', { infer: true }) === 'production',
    globalPrefix: 'api/wms',
  });

  await app.listen(config.get('WMS_PORT', { infer: true }));
}
void bootstrap();
```

- [ ] **Step 3: Thêm @AuthThrottle cho login/refresh**

In `apps/wms/src/auth/auth.controller.ts`:
- Thêm import: `import { AuthThrottle } from '@app/common';`
- Thêm `@AuthThrottle()` ngay trên `@Post('login')` (dưới dòng decorator hiện có, trước hàm `login`) và trên `@Post('refresh')`.

Ví dụ block login sau khi sửa:
```ts
  @Post('login')
  @HttpCode(200)
  @AuthThrottle()
  login(@Body() dto: LoginDto) {
    return this.auth.login(dto.username, dto.password);
  }
```
Và tương tự cho `refresh`:
```ts
  @Post('refresh')
  @HttpCode(200)
  @AuthThrottle()
  refresh(@Body() dto: RefreshDto) {
    return this.auth.refresh(dto.refreshToken);
  }
```

- [ ] **Step 4: Bỏ throttle cho health**

In `apps/wms/src/health/health.controller.ts`:
- Thêm import: `import { SkipThrottle } from '@app/common';`
- Thêm `@SkipThrottle()` ngay trên class `HealthController` (decorator cấp class).

- [ ] **Step 5: Build WMS**

Run: `pnpm build wms`
Expected: thành công.

- [ ] **Step 6: Smoke test khởi động (nếu Mongo/Redis sẵn)**

Run: `pnpm start:wms` (Ctrl-C sau khi thấy log)
Expected: log dạng pino-pretty 1 dòng; app lắng nghe `WMS_PORT`. Nếu không có Mongo/Redis local thì bỏ qua bước này (sẽ test ở e2e Task 14).

- [ ] **Step 7: Commit**

```bash
git add apps/wms/src
git commit -m "feat(wms): wire pino + throttler async + CommonModule + setupApp"
```

---

## Task 12: Wire Ecommerce app (module + main)

**Files:**
- Modify: `apps/ecommerce/src/ecommerce.module.ts`
- Modify: `apps/ecommerce/src/main.ts`
- Modify: `apps/ecommerce/src/auth/auth.controller.ts`
- Modify: `apps/ecommerce/src/health/health.controller.ts`

- [ ] **Step 1: Cập nhật ecommerce.module.ts**

Overwrite `apps/ecommerce/src/ecommerce.module.ts`:
```ts
import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { APP_GUARD } from '@nestjs/core';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { LoggerModule } from 'nestjs-pino';
import { CommonModule, buildPinoOptions, buildThrottlerOptions } from '@app/common';
import { DatabaseModule } from '@app/database';
import { EventsModule } from '@app/events';
import { AuthModule } from './auth/auth.module';
import { CatalogModule } from './catalog/catalog.module';
import { validateEnv } from './config/env.validation';
import { EcommerceController } from './ecommerce.controller';
import { EcommerceService } from './ecommerce.service';
import { HealthModule } from './health/health.module';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true, validate: validateEnv }),
    LoggerModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => buildPinoOptions(config),
    }),
    ThrottlerModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => buildThrottlerOptions(config),
    }),
    CommonModule, // global filter/interceptor/pipe
    DatabaseModule.forApp('ECOM_DATABASE_URL'), // Mongoose → ecom_db
    EventsModule, // BullMQ + Redis
    AuthModule, // đăng ký/đăng nhập khách (customers) + JWT
    HealthModule, // GET /api/shop/health
    CatalogModule, // consumer mẫu: stock.changed → availableQty
  ],
  controllers: [EcommerceController],
  providers: [
    EcommerceService,
    { provide: APP_GUARD, useClass: ThrottlerGuard },
  ],
})
export class EcommerceModule {}
```

- [ ] **Step 2: Cập nhật main.ts**

Overwrite `apps/ecommerce/src/main.ts`:
```ts
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import { setupApp } from '@app/common';
import { Env } from './config/env.validation';
import { EcommerceModule } from './ecommerce.module';

async function bootstrap() {
  const app = await NestFactory.create(EcommerceModule, { bufferLogs: true });
  const config = app.get(ConfigService<Env, true>);

  setupApp(app, {
    corsOrigins: config.get('ECOM_CORS_ORIGINS', { infer: true }),
    isProd: config.get('NODE_ENV', { infer: true }) === 'production',
    globalPrefix: 'api/shop',
  });

  await app.listen(config.get('ECOM_PORT', { infer: true }));
}
void bootstrap();
```

- [ ] **Step 3: Thêm @AuthThrottle cho route auth khách**

In `apps/ecommerce/src/auth/auth.controller.ts`:
- Thêm import `import { AuthThrottle } from '@app/common';`
- Thêm `@AuthThrottle()` lên các route nhạy cảm hiện có: login, register, refresh, và route quên/đặt-lại mật khẩu nếu có (forgot-password / reset-password / verify). Đặt decorator ngay trên dòng `@Post(...)` của từng route.

> Nếu không chắc tên route, mở file xem các `@Post(...)` và áp `@AuthThrottle()` cho login/register/refresh/forgot/reset. Các route đọc (GET) không cần.

- [ ] **Step 4: Bỏ throttle cho health**

In `apps/ecommerce/src/health/health.controller.ts`:
- Thêm import `import { SkipThrottle } from '@app/common';`
- Thêm `@SkipThrottle()` cấp class trên `HealthController`.

- [ ] **Step 5: Build ecommerce**

Run: `pnpm build ecommerce`
Expected: thành công.

- [ ] **Step 6: Commit**

```bash
git add apps/ecommerce/src
git commit -m "feat(ecommerce): wire pino + throttler async + CommonModule + setupApp"
```

---

## Task 13: Wire Notification app (module + main)

**Files:**
- Modify: `apps/notification/src/notification.module.ts`
- Modify: `apps/notification/src/main.ts`

- [ ] **Step 1: Cập nhật notification.module.ts**

Overwrite `apps/notification/src/notification.module.ts`:
```ts
import { BullModule } from '@nestjs/bullmq';
import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { LoggerModule } from 'nestjs-pino';
import { CommonModule, buildPinoOptions } from '@app/common';
import { EventsModule, QUEUES } from '@app/events';
import { validateEnv } from './config/env.validation';
import { NotificationConsumer } from './notification.consumer';
import { NotificationController } from './notification.controller';
import { NotificationService } from './notification.service';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true, validate: validateEnv }),
    LoggerModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => buildPinoOptions(config),
    }),
    CommonModule, // global filter/interceptor/pipe
    EventsModule, // BullMQ + Redis
    BullModule.registerQueue({ name: QUEUES.NOTIFICATION }),
  ],
  controllers: [NotificationController],
  providers: [NotificationService, NotificationConsumer],
})
export class NotificationModule {}
```

> Notification không có route public nhạy cảm nên KHÔNG thêm ThrottlerModule/Guard (tránh phụ thuộc thừa). Filter/interceptor/logging vẫn áp đồng nhất qua CommonModule + pino.

- [ ] **Step 2: Cập nhật main.ts**

Overwrite `apps/notification/src/main.ts`:
```ts
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import { setupApp } from '@app/common';
import { Env } from './config/env.validation';
import { NotificationModule } from './notification.module';

async function bootstrap() {
  const app = await NestFactory.create(NotificationModule, { bufferLogs: true });
  const config = app.get(ConfigService<Env, true>);

  setupApp(app, {
    corsOrigins: undefined, // consumer thuần, không có FE gọi CORS
    isProd: config.get('NODE_ENV', { infer: true }) === 'production',
    globalPrefix: 'api/notification',
  });

  await app.listen(config.get('NOTIFICATION_PORT', { infer: true }));
}
void bootstrap();
```

> `corsOrigins: undefined` + dev → `buildCorsOptions` phản chiếu mọi origin (ok cho consumer nội bộ); prod → ném lỗi yêu cầu khai báo. Vì notification không phục vụ FE, nếu prod vướng có thể bỏ `enableCors` riêng cho app này sau — ngoài phạm vi plan.

- [ ] **Step 3: Build notification**

Run: `pnpm build notification`
Expected: thành công.

- [ ] **Step 4: Commit**

```bash
git add apps/notification/src
git commit -m "feat(notification): wire pino + CommonModule + setupApp"
```

---

## Task 14: e2e smoke — envelope + error + header

**Files:**
- Modify: `apps/wms/test/app.e2e-spec.ts`

- [ ] **Step 1: Xem file e2e hiện tại**

Run: `cat apps/wms/test/app.e2e-spec.ts`
Expected: thấy test mặc định Nest (`GET /` → 'Hello World').

- [ ] **Step 2: Viết e2e khẳng định envelope + error**

Overwrite `apps/wms/test/app.e2e-spec.ts`:
```ts
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Logger } from 'nestjs-pino';
import request from 'supertest';
import { setupApp } from '@app/common';
import { AppModule } from '../src/app.module';

describe('Cross-cutting (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = moduleRef.createNestApplication({ bufferLogs: true });
    setupApp(app, { corsOrigins: undefined, isProd: false, globalPrefix: 'api/wms' });
    await app.init();
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /api/wms → bọc { data, meta } + header X-Request-Id', async () => {
    const res = await request(app.getHttpServer()).get('/api/wms').expect(200);
    expect(res.body).toEqual({
      data: expect.anything(),
      meta: { requestId: expect.any(String), timestamp: expect.any(String) },
    });
    expect(res.headers['x-request-id']).toBeDefined();
  });

  it('route không tồn tại → error envelope { error.code: NOT_FOUND }', async () => {
    const res = await request(app.getHttpServer()).get('/api/wms/khong-ton-tai').expect(404);
    expect(res.body).toMatchObject({
      error: { code: 'NOT_FOUND' },
      meta: { requestId: expect.any(String), path: expect.any(String) },
    });
  });
});
```

> Lưu ý: test này cần Mongo + Redis chạy (AppModule có DatabaseModule + EventsModule). Nếu CI chưa có, đánh dấu `describe.skip` và chạy thủ công khi có hạ tầng. Cấu hình jest-e2e nằm ở `apps/wms/test/jest-e2e.json`.

- [ ] **Step 3: Chạy e2e (nếu có Mongo/Redis)**

Run: `pnpm test:e2e`
Expected: PASS 2 test. Nếu thiếu hạ tầng → khởi động Mongo (`--replSet rs0`) + Redis qua `docker-compose.yml` rồi chạy lại.

- [ ] **Step 4: Commit**

```bash
git add apps/wms/test/app.e2e-spec.ts
git commit -m "test(wms): e2e khẳng định response/error envelope + X-Request-Id"
```

---

## Task 15: Verify toàn bộ

- [ ] **Step 1: Chạy toàn bộ unit test**

Run: `pnpm test`
Expected: PASS tất cả spec mới (errors, filter, cursor, offset, sanitize, response.interceptor) + spec cũ.

- [ ] **Step 2: Lint**

Run: `pnpm lint`
Expected: không lỗi (eslint --fix tự sửa format).

- [ ] **Step 3: Build cả 3 app**

Run: `pnpm build wms && pnpm build ecommerce && pnpm build notification`
Expected: cả 3 build thành công.

- [ ] **Step 4: Commit dọn (nếu lint sửa file)**

```bash
git add -A
git commit -m "chore: lint cross-cutting standards" || echo "không có thay đổi"
```

---

## Self-Review (đã rà)

- **Spec coverage:** §1 envelope → Task 8; §2 error → Task 2,3; §3 logging → Task 1,6,7,11-13; §4 throttle → Task 8,9,11,12; §5 pagination → Task 4,5; §6 wiring → Task 9-13; §7 testing → mỗi task + Task 14,15. ✅
- **Sai lệch có chủ đích so với spec:** auth throttle limit là HẰNG (5/60s) trong decorator, KHÔNG lấy env (lý do timing decorator) → đã bỏ `THROTTLE_AUTH_*` khỏi env (Task 10 chỉ thêm `THROTTLE_DEFAULT_*`). Ghi rõ ở Task 8 Step 2.
- **Type consistency:** `PaginatedResult.items/pagination`, `buildCursorPage(rows, limit, sortField)`, `buildOffsetMeta(itemCount, page, limit, totalItems?)`, `AppException(code, message?, status?, details?)`, `setupApp(app, { corsOrigins, isProd, globalPrefix })`, `buildPinoOptions(config)`, `buildThrottlerOptions(config)` — dùng nhất quán xuyên các task. ✅
- **Placeholder scan:** không có TODO/TBD; mọi step có code/lệnh cụ thể (Task 12 Step 3 hướng dẫn áp decorator theo route thực tế của controller auth ecom vì tên route chưa đọc — kèm danh sách rõ). ✅
