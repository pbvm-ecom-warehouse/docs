# OTP verify/reset + email (Resend) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Đổi verify email / reset mật khẩu của khách sang **mã OTP 6 số nhập tay** (lưu Redis), và cho app **notification** gửi email thật bằng **Resend** (React Email).

**Architecture:** Ecom auth sinh OTP 6 số, lưu hash trong Redis qua `OtpStore` (TTL 10', 1 mã sống/khách, giới hạn 5 lần thử), emit `{customerId,email,code}`. Notification consumer nhận event → render React Email template hiện mã → gửi qua Resend (idempotency = job.id). Hai app phối hợp qua event `libs/events`, không đọc chéo DB.

**Tech Stack:** NestJS monorepo, BullMQ/Redis, ioredis (OtpStore), Resend SDK, @react-email/components, ts-jest.

## Global Constraints

- DB-per-app, không đọc chéo. OTP ở Redis keyspace `otp:*` của ecom; notification không có DB.
- Chỉ lưu `hashToken`/sha256 của mã, không lưu plaintext.
- Cross-cutting `@app/common`: `AppException`/throttle/Zod env; notification là consumer thuần (`@Processor`, không phát event).
- Comment tiếng Việt giải thích *vì sao*. Tên collection/event giữ nguyên.
- `OTP_TTL_SEC = 600`, `OTP_MAX_ATTEMPTS = 5`, mã 6 số.
- Test: `*.spec.ts` cạnh source; chạy `pnpm test`. E2E (cần Mongo/Redis) để `describe.skip`.

---

### Task 1: OtpStore — lưu/kiểm OTP trong Redis (ecom)

**Files:**
- Create: `apps/ecommerce/src/auth/otp.store.ts`
- Test: `apps/ecommerce/src/auth/otp.store.spec.ts`
- Modify: `package.json` (thêm `ioredis`, devDep `ioredis-mock`)

**Interfaces:**
- Produces: `OtpStore` với `issue(customerId: string, type: OtpType, code: string): Promise<void>` và `verify(customerId: string, type: OtpType, code: string): Promise<boolean>`; `type OtpType = 'verify_email' | 'reset_password'`.

- [ ] **Step 1: Cài deps**

```bash
pnpm add ioredis
pnpm add -D ioredis-mock @types/ioredis-mock
```

- [ ] **Step 2: Viết test thất bại** — `apps/ecommerce/src/auth/otp.store.spec.ts`

```ts
import { ConfigService } from '@nestjs/config';
import { OtpStore } from './otp.store';

jest.mock('ioredis', () => require('ioredis-mock'));

function makeStore() {
  const config = {
    getOrThrow: (k: string) => (k === 'REDIS_HOST' ? 'localhost' : 6379),
    get: () => undefined,
  } as unknown as ConfigService;
  return new OtpStore(config);
}

describe('OtpStore', () => {
  it('issue rồi verify đúng mã → true, và xóa key (verify lại false)', async () => {
    const store = makeStore();
    await store.issue('c1', 'verify_email', '123456');
    expect(await store.verify('c1', 'verify_email', '123456')).toBe(true);
    expect(await store.verify('c1', 'verify_email', '123456')).toBe(false);
  });

  it('mã sai → false; sai đủ 5 lần → mã bị vô hiệu', async () => {
    const store = makeStore();
    await store.issue('c1', 'verify_email', '123456');
    for (let i = 0; i < 5; i++) {
      expect(await store.verify('c1', 'verify_email', '000000')).toBe(false);
    }
    // hết lần thử → mã đúng cũng không còn dùng được
    expect(await store.verify('c1', 'verify_email', '123456')).toBe(false);
  });

  it('issue lần 2 ghi đè mã cũ', async () => {
    const store = makeStore();
    await store.issue('c1', 'reset_password', '111111');
    await store.issue('c1', 'reset_password', '222222');
    expect(await store.verify('c1', 'reset_password', '111111')).toBe(false);
    expect(await store.verify('c1', 'reset_password', '222222')).toBe(true);
  });
});
```

- [ ] **Step 3: Chạy test — kỳ vọng FAIL**

Run: `pnpm test -- otp.store`
Expected: FAIL ("Cannot find module './otp.store'").

- [ ] **Step 4: Hiện thực OtpStore** — `apps/ecommerce/src/auth/otp.store.ts`

```ts
import { Injectable, OnModuleDestroy } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash } from 'node:crypto';
import Redis from 'ioredis';

export type OtpType = 'verify_email' | 'reset_password';

// Mã 6 số entropy thấp → bù bằng hạn ngắn + giới hạn thử + dùng-một-lần.
const OTP_TTL_SEC = 600; // 10 phút (TTL gốc Redis tự hết hạn)
const OTP_MAX_ATTEMPTS = 5;

function hashCode(code: string): string {
  return createHash('sha256').update(code).digest('hex');
}

/**
 * Lưu OTP trong Redis (keyspace `otp:*` của ecom). Vì OTP là dữ liệu phù du,
 * dùng-một-lần nên Redis (TTL gốc) hợp hơn Mongo. Chỉ lưu HASH của mã.
 */
@Injectable()
export class OtpStore implements OnModuleDestroy {
  private readonly redis: Redis;

  constructor(config: ConfigService) {
    this.redis = new Redis({
      host: config.getOrThrow<string>('REDIS_HOST'),
      port: Number(config.getOrThrow('REDIS_PORT')),
      password: config.get<string>('REDIS_PASSWORD') || undefined,
      maxRetriesPerRequest: null,
    });
  }

  private key(customerId: string, type: OtpType) {
    return `otp:${type}:${customerId}`;
  }

  /** Cấp mã mới: ghi đè mã cũ + đặt TTL → mỗi khách/type chỉ 1 mã sống. */
  async issue(customerId: string, type: OtpType, code: string): Promise<void> {
    const key = this.key(customerId, type);
    await this.redis
      .multi()
      .del(key)
      .hset(key, { codeHash: hashCode(code), attempts: '0' })
      .expire(key, OTP_TTL_SEC)
      .exec();
  }

  /** Đúng → xóa key, true. Sai → attempts++, hết lần thì xóa, false. */
  async verify(customerId: string, type: OtpType, code: string): Promise<boolean> {
    const key = this.key(customerId, type);
    const data = await this.redis.hgetall(key);
    if (!data || !data.codeHash) return false;

    if (data.codeHash !== hashCode(code)) {
      const attempts = await this.redis.hincrby(key, 'attempts', 1);
      if (attempts >= OTP_MAX_ATTEMPTS) await this.redis.del(key);
      return false;
    }

    await this.redis.del(key);
    return true;
  }

  onModuleDestroy() {
    return this.redis.quit();
  }
}
```

- [ ] **Step 5: Chạy test — kỳ vọng PASS**

Run: `pnpm test -- otp.store`
Expected: PASS (3 test).

- [ ] **Step 6: Commit**

```bash
git add apps/ecommerce/src/auth/otp.store.ts apps/ecommerce/src/auth/otp.store.spec.ts package.json pnpm-lock.yaml
git commit -m "feat(ecom-auth): OtpStore lưu OTP trong Redis (TTL + giới hạn thử)"
```

---

### Task 2: Đổi luồng ecom auth sang OTP (event contract + DTO + service + controller)

**Files:**
- Modify: `libs/events/src/events.ts` (đổi `token` → `code`)
- Modify: `apps/ecommerce/src/auth/dto/auth.dto.ts` (DTO verify/reset)
- Modify: `apps/ecommerce/src/auth/auth.service.ts` (sinh/kiểm OTP qua OtpStore)
- Modify: `apps/ecommerce/src/auth/auth.controller.ts` (endpoint nhận email+code)
- Modify: `apps/ecommerce/src/auth/auth.module.ts` (provider OtpStore)
- Test: `apps/ecommerce/src/auth/auth.service.spec.ts`

**Interfaces:**
- Consumes: `OtpStore.issue/verify` (Task 1).
- Produces: `AuthService.verifyEmail(email: string, code: string)`, `AuthService.resetPassword(email: string, code: string, newPassword: string)`; payload `CustomerEmailActionPayload = { customerId: string; email: string; code: string }`.

- [ ] **Step 1: Đổi contract event** — `libs/events/src/events.ts`

Tìm interface `CustomerEmailActionPayload`, đổi field `token` → `code`:

```ts
export interface CustomerEmailActionPayload {
  customerId: string;
  email: string;
  code: string; // mã OTP 6 số (plaintext, chỉ để notification ghép vào email)
}
```

- [ ] **Step 2: Đổi DTO** — `apps/ecommerce/src/auth/dto/auth.dto.ts`

Thay class `TokenDto` và `ResetPasswordDto` bằng:

```ts
export class VerifyEmailDto {
  @ApiProperty({ example: 'khach@example.com' })
  @IsEmail()
  email!: string;

  @ApiProperty({ example: '123456', description: 'Mã OTP 6 số' })
  @IsString()
  @Length(6, 6)
  code!: string;
}

export class ResetPasswordDto {
  @ApiProperty({ example: 'khach@example.com' })
  @IsEmail()
  email!: string;

  @ApiProperty({ example: '123456', description: 'Mã OTP 6 số' })
  @IsString()
  @Length(6, 6)
  code!: string;

  @ApiProperty({ example: 'NewP@ssw0rd123!', minLength: 8 })
  @IsString()
  @MinLength(8)
  newPassword!: string;
}
```

Thêm `Length` vào import `class-validator` ở đầu file:

```ts
import {
  IsBoolean,
  IsEmail,
  IsOptional,
  IsString,
  Length,
  MinLength,
} from 'class-validator';
```

- [ ] **Step 3: Viết test thất bại** — `apps/ecommerce/src/auth/auth.service.spec.ts`

```ts
import { BadRequestException } from '@nestjs/common';
import { AuthService } from './auth.service';

function makeService(overrides: Partial<Record<string, any>> = {}) {
  const customer = { _id: { toString: () => 'c1' }, email: 'a@b.com' };
  const customerRepo = {
    findActiveByEmail: jest.fn().mockResolvedValue(customer),
    markEmailVerified: jest.fn().mockResolvedValue(customer),
    updatePassword: jest.fn().mockResolvedValue(customer),
    ...overrides.customerRepo,
  };
  const refreshRepo = { revokeAllForCustomer: jest.fn().mockResolvedValue(undefined) };
  const otpStore = {
    issue: jest.fn().mockResolvedValue(undefined),
    verify: jest.fn().mockResolvedValue(true),
    ...overrides.otpStore,
  };
  const notifyQueue = { add: jest.fn().mockResolvedValue(undefined) };
  const svc = new AuthService(
    customerRepo as any,
    refreshRepo as any,
    notifyQueue as any,
    {} as any, // jwt
    {} as any, // firebaseAdmin
    { jwtSecret: 's', jwtExpiresIn: '30d', refreshExpiresIn: '60d' } as any,
    otpStore as any,
  );
  return { svc, customerRepo, refreshRepo, otpStore };
}

describe('AuthService OTP', () => {
  it('verifyEmail mã đúng → markEmailVerified', async () => {
    const { svc, customerRepo, otpStore } = makeService();
    const res = await svc.verifyEmail('a@b.com', '123456');
    expect(otpStore.verify).toHaveBeenCalledWith('c1', 'verify_email', '123456');
    expect(customerRepo.markEmailVerified).toHaveBeenCalled();
    expect(res).toEqual({ success: true, emailVerified: true });
  });

  it('verifyEmail mã sai → BadRequest', async () => {
    const { svc } = makeService({ otpStore: { verify: jest.fn().mockResolvedValue(false) } });
    await expect(svc.verifyEmail('a@b.com', '000000')).rejects.toBeInstanceOf(BadRequestException);
  });

  it('resetPassword mã đúng → updatePassword + revoke refresh', async () => {
    const { svc, customerRepo, refreshRepo } = makeService();
    const res = await svc.resetPassword('a@b.com', '123456', 'NewP@ssw0rd123!');
    expect(customerRepo.updatePassword).toHaveBeenCalled();
    expect(refreshRepo.revokeAllForCustomer).toHaveBeenCalled();
    expect(res).toEqual({ success: true });
  });

  it('resetPassword email không tồn tại → BadRequest trung lập (không lộ)', async () => {
    const { svc } = makeService({ customerRepo: { findActiveByEmail: jest.fn().mockResolvedValue(null) } });
    await expect(svc.resetPassword('x@y.com', '123456', 'NewP@ssw0rd123!')).rejects.toBeInstanceOf(BadRequestException);
  });
});
```

- [ ] **Step 4: Chạy test — kỳ vọng FAIL**

Run: `pnpm test -- auth.service`
Expected: FAIL (constructor arg `otpStore` chưa có / signature cũ).

- [ ] **Step 5: Sửa AuthService** — `apps/ecommerce/src/auth/auth.service.ts`

5a. Constructor: bỏ `authTokenRepo`, thêm `otpStore`. Đổi block constructor:

```ts
  constructor(
    private readonly customerRepo: CustomerRepository,
    private readonly refreshRepo: CustomerRefreshTokenRepository,
    @InjectQueue(QUEUES.NOTIFICATION) private readonly notifyQueue: Queue,
    private readonly jwt: JwtService,
    private readonly firebaseAdmin: FirebaseAdminService,
    @Inject(authConfig.KEY)
    private readonly auth: ConfigType<typeof authConfig>,
    private readonly otpStore: OtpStore,
  ) {}
```

5b. Bỏ import/hằng không dùng: xóa import `CustomerAuthTokenRepository`, `AuthTokenType`, hằng `VERIFY_TOKEN_TTL_MS`, `RESET_TOKEN_TTL_MS`. Thêm import:

```ts
import { randomInt } from 'node:crypto';
import { OtpStore, type OtpType } from './otp.store';
```

5c. Thêm helper + đổi `sendEmailAction`:

```ts
  private generateOtp(): string {
    return randomInt(0, 1_000_000).toString().padStart(6, '0');
  }

  private async sendEmailAction(
    customerId: Types.ObjectId,
    email: string,
    type: OtpType,
    eventName:
      | typeof EVENTS.CUSTOMER_VERIFY_REQUESTED
      | typeof EVENTS.CUSTOMER_PASSWORD_RESET_REQUESTED,
  ) {
    const code = this.generateOtp();
    await this.otpStore.issue(customerId.toString(), type, code);
    const payload: CustomerEmailActionPayload = {
      customerId: customerId.toString(),
      email,
      code,
    };
    // removeOnComplete: xóa mã plaintext khỏi job data (Redis) sau khi gửi xong.
    await this.notifyQueue.add(eventName, payload, { removeOnComplete: true });
  }
```

5d. Cập nhật 3 call site `sendEmailAction` (bỏ tham số TTL, đổi type sang chuỗi):
- Trong `register`: `await this.sendEmailAction(customer._id, customer.email, 'verify_email', EVENTS.CUSTOMER_VERIFY_REQUESTED);`
- Trong `resendVerifyEmail`: `await this.sendEmailAction(customer._id, customer.email, 'verify_email', EVENTS.CUSTOMER_VERIFY_REQUESTED);`
- Trong `forgotPassword`: `await this.sendEmailAction(customer._id, customer.email, 'reset_password', EVENTS.CUSTOMER_PASSWORD_RESET_REQUESTED);`

5e. Thay `verifyEmail` và `resetPassword`:

```ts
  async verifyEmail(email: string, code: string) {
    const customer = await this.customerRepo.findActiveByEmail(email);
    const ok = customer
      ? await this.otpStore.verify(customer._id.toString(), 'verify_email', code)
      : false;
    if (!customer || !ok) {
      throw new BadRequestException('Ma khong dung hoac da het han');
    }
    await this.customerRepo.markEmailVerified(customer._id);
    return { success: true, emailVerified: true };
  }

  async resetPassword(email: string, code: string, newPassword: string) {
    const customer = await this.customerRepo.findActiveByEmail(email);
    const ok = customer
      ? await this.otpStore.verify(customer._id.toString(), 'reset_password', code)
      : false;
    if (!customer || !ok) {
      // Trung lap: khong lo email ton tai / ma sai.
      throw new BadRequestException('Ma khong dung hoac da het han');
    }
    const passwordHash = await bcrypt.hash(newPassword, BCRYPT_ROUNDS);
    await this.customerRepo.updatePassword(customer._id, passwordHash);
    await this.refreshRepo.revokeAllForCustomer(customer._id);
    return { success: true };
  }
```

- [ ] **Step 6: Sửa controller** — `apps/ecommerce/src/auth/auth.controller.ts`

6a. Đổi import DTO: bỏ `TokenDto`, thêm `VerifyEmailDto` (giữ `ResetPasswordDto`, `ForgotPasswordDto`).

6b. Endpoint `verify-email`:

```ts
  @Post('verify-email')
  @HttpCode(200)
  @AuthThrottle()
  @ApiOperation({ summary: 'Xac minh email bang ma OTP 6 so' })
  @ApiBody({
    type: VerifyEmailDto,
    examples: { verify: { value: { email: 'khach@example.com', code: '123456' } } },
  })
  verifyEmail(@Body() dto: VerifyEmailDto) {
    return this.auth.verifyEmail(dto.email, dto.code);
  }
```

6c. Endpoint `reset-password`:

```ts
  @Post('reset-password')
  @HttpCode(200)
  @AuthThrottle()
  @ApiOperation({ summary: 'Dat lai mat khau bang ma OTP 6 so' })
  @ApiBody({
    type: ResetPasswordDto,
    examples: {
      reset: {
        value: { email: 'khach@example.com', code: '123456', newPassword: 'NewP@ssw0rd123!' },
      },
    },
  })
  resetPassword(@Body() dto: ResetPasswordDto) {
    return this.auth.resetPassword(dto.email, dto.code, dto.newPassword);
  }
```

- [ ] **Step 7: Đăng ký OtpStore** — `apps/ecommerce/src/auth/auth.module.ts`

Thêm import `import { OtpStore } from './otp.store';` và thêm `OtpStore` vào mảng `providers`.

- [ ] **Step 8: Chạy test — kỳ vọng PASS**

Run: `pnpm test -- auth.service`
Expected: PASS (4 test).

- [ ] **Step 9: Build ecom — kỳ vọng không lỗi TS**

Run: `pnpm exec nest build ecommerce`
Expected: "compiled successfully".

- [ ] **Step 10: Commit**

```bash
git add libs/events/src/events.ts apps/ecommerce/src/auth
git commit -m "feat(ecom-auth): verify/reset bằng OTP 6 số (email+code) qua OtpStore"
```

---

### Task 3: EmailService — gửi email qua Resend (notification)

**Files:**
- Create: `apps/notification/src/email/email.service.ts`
- Create: `apps/notification/src/email/email.module.ts`
- Test: `apps/notification/src/email/email.service.spec.ts`
- Modify: `apps/notification/src/config/env.validation.ts` (RESEND_*)
- Modify: `.env.example`, `.env.production.example`
- Modify: `package.json` (thêm `resend`)

**Interfaces:**
- Produces: `EmailService.send({ to: string; subject: string; react: ReactElement; idempotencyKey: string }): Promise<void>`; `EmailModule` export `EmailService`.

- [ ] **Step 1: Cài dep**

```bash
pnpm add resend react
```

- [ ] **Step 2: Thêm env Zod** — `apps/notification/src/config/env.validation.ts`

Thêm vào schema (gần block FIREBASE):

```ts
  // Email qua Resend. Thiếu RESEND_API_KEY/RESEND_FROM → email tắt mềm.
  RESEND_API_KEY: z.string().min(1).optional(),
  RESEND_FROM: z.string().min(1).optional(),
```

- [ ] **Step 3: Viết test thất bại** — `apps/notification/src/email/email.service.spec.ts`

```ts
import { ConfigService } from '@nestjs/config';
import { EmailService } from './email.service';

const sendMock = jest.fn().mockResolvedValue({ data: { id: 'e1' }, error: null });
jest.mock('resend', () => ({
  Resend: jest.fn().mockImplementation(() => ({ emails: { send: sendMock } })),
}));

function makeService(env: Record<string, string | undefined>) {
  const config = { get: (k: string) => env[k] } as unknown as ConfigService;
  return new EmailService(config);
}

describe('EmailService', () => {
  beforeEach(() => sendMock.mockClear());

  it('có key → gọi Resend với idempotencyKey', async () => {
    const svc = makeService({ RESEND_API_KEY: 'k', RESEND_FROM: 'a@b.com' });
    await svc.send({ to: 'x@y.com', subject: 'Hi', react: {} as any, idempotencyKey: 'job-1' });
    expect(sendMock).toHaveBeenCalledWith(
      expect.objectContaining({ from: 'a@b.com', to: 'x@y.com', subject: 'Hi' }),
      { idempotencyKey: 'job-1' },
    );
  });

  it('thiếu API key → tắt mềm, không gọi Resend', async () => {
    const svc = makeService({ RESEND_FROM: 'a@b.com' });
    await svc.send({ to: 'x@y.com', subject: 'Hi', react: {} as any, idempotencyKey: 'job-1' });
    expect(sendMock).not.toHaveBeenCalled();
    expect(svc.isEnabled()).toBe(false);
  });
});
```

- [ ] **Step 4: Chạy test — kỳ vọng FAIL**

Run: `pnpm test -- email.service`
Expected: FAIL ("Cannot find module './email.service'").

- [ ] **Step 5: Hiện thực EmailService** — `apps/notification/src/email/email.service.ts`

```ts
import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Resend } from 'resend';
import type { ReactElement } from 'react';

interface SendArgs {
  to: string;
  subject: string;
  react: ReactElement;
  idempotencyKey: string; // = job.id → Resend dedupe khi BullMQ retry
}

/** Bọc Resend SDK. Tắt mềm khi thiếu config để dev không cần Resend vẫn chạy. */
@Injectable()
export class EmailService {
  private readonly logger = new Logger(EmailService.name);
  private readonly resend: Resend | null;
  private readonly from?: string;

  constructor(config: ConfigService) {
    const apiKey = config.get<string>('RESEND_API_KEY');
    this.from = config.get<string>('RESEND_FROM');
    this.resend = apiKey ? new Resend(apiKey) : null;
    if (!this.isEnabled()) {
      this.logger.warn('Email tat — can RESEND_API_KEY + RESEND_FROM.');
    }
  }

  isEnabled(): boolean {
    return this.resend !== null && !!this.from;
  }

  async send({ to, subject, react, idempotencyKey }: SendArgs): Promise<void> {
    if (!this.resend || !this.from) {
      this.logger.warn(`Bo gui email "${subject}" -> ${to} (email tat).`);
      return;
    }
    await this.resend.emails.send(
      { from: this.from, to, subject, react },
      { idempotencyKey },
    );
  }
}
```

- [ ] **Step 6: Tạo EmailModule** — `apps/notification/src/email/email.module.ts`

```ts
import { Global, Module } from '@nestjs/common';
import { EmailService } from './email.service';

@Global()
@Module({
  providers: [EmailService],
  exports: [EmailService],
})
export class EmailModule {}
```

- [ ] **Step 7: Thêm RESEND_* vào env mẫu**

Thêm vào `.env.example` và `.env.production.example` (sau block Firebase):

```
# ---- Email (Resend) — thiếu thì email tắt mềm ----
RESEND_API_KEY=
RESEND_FROM=WMS Shop <no-reply@your-domain.com>
```

- [ ] **Step 8: Chạy test — kỳ vọng PASS**

Run: `pnpm test -- email.service`
Expected: PASS (2 test).

- [ ] **Step 9: Commit**

```bash
git add apps/notification/src/email/email.service.ts apps/notification/src/email/email.module.ts apps/notification/src/email/email.service.spec.ts apps/notification/src/config/env.validation.ts .env.example .env.production.example package.json pnpm-lock.yaml
git commit -m "feat(notification): EmailService bọc Resend (idempotency + tắt mềm)"
```

---

### Task 4: React Email templates + cấu hình build TSX (notification)

**Files:**
- Create: `apps/notification/src/email/templates/verify-email.tsx`
- Create: `apps/notification/src/email/templates/reset-password.tsx`
- Test: `apps/notification/src/email/templates/templates.spec.ts`
- Modify: `apps/notification/tsconfig.app.json` (jsx cho nest build)
- Modify: `package.json` (jest transform jsx + moduleFileExtensions tsx; dep `@react-email/components`)

**Interfaces:**
- Produces: `VerifyEmail({ code }: { code: string }): ReactElement`, `ResetPasswordEmail({ code }: { code: string }): ReactElement`.

- [ ] **Step 1: Cài dep**

```bash
pnpm add @react-email/components
```

- [ ] **Step 2: Bật jsx cho nest build** — `apps/notification/tsconfig.app.json`

Thêm `"jsx": "react-jsx"` vào `compilerOptions` của file này (chỉ riêng notification).

- [ ] **Step 3: Cho jest hiểu tsx** — `package.json` field `jest`

Thêm `"tsx"` vào `moduleFileExtensions`, và đổi `transform` để bật jsx:

```json
"moduleFileExtensions": ["js", "json", "ts", "tsx"],
"transform": {
  "^.+\\.(t|j)sx?$": ["ts-jest", { "tsconfig": { "jsx": "react-jsx" } }]
}
```

- [ ] **Step 4: Viết test thất bại** — `apps/notification/src/email/templates/templates.spec.ts`

```ts
import { render } from '@react-email/components';
import { VerifyEmail } from './verify-email';
import { ResetPasswordEmail } from './reset-password';

describe('email templates', () => {
  it('VerifyEmail chứa mã', async () => {
    const html = await render(VerifyEmail({ code: '654321' }));
    expect(html).toContain('654321');
  });

  it('ResetPasswordEmail chứa mã', async () => {
    const html = await render(ResetPasswordEmail({ code: '987654' }));
    expect(html).toContain('987654');
  });
});
```

- [ ] **Step 5: Chạy test — kỳ vọng FAIL**

Run: `pnpm test -- templates`
Expected: FAIL ("Cannot find module './verify-email'").

- [ ] **Step 6: Tạo template verify** — `apps/notification/src/email/templates/verify-email.tsx`

```tsx
import {
  Body,
  Container,
  Heading,
  Html,
  Section,
  Text,
} from '@react-email/components';

export function VerifyEmail({ code }: { code: string }) {
  return (
    <Html lang="vi">
      <Body>
        <Container>
          <Heading>Xác minh email</Heading>
          <Text>Mã xác minh của bạn là:</Text>
          <Section>
            <Text style={{ fontSize: 32, letterSpacing: 6, fontWeight: 700 }}>
              {code}
            </Text>
          </Section>
          <Text>
            Mã hết hạn sau 10 phút. Nếu bạn không yêu cầu, hãy bỏ qua email này.
          </Text>
        </Container>
      </Body>
    </Html>
  );
}
```

- [ ] **Step 7: Tạo template reset** — `apps/notification/src/email/templates/reset-password.tsx`

```tsx
import {
  Body,
  Container,
  Heading,
  Html,
  Section,
  Text,
} from '@react-email/components';

export function ResetPasswordEmail({ code }: { code: string }) {
  return (
    <Html lang="vi">
      <Body>
        <Container>
          <Heading>Đặt lại mật khẩu</Heading>
          <Text>Mã đặt lại mật khẩu của bạn là:</Text>
          <Section>
            <Text style={{ fontSize: 32, letterSpacing: 6, fontWeight: 700 }}>
              {code}
            </Text>
          </Section>
          <Text>
            Mã hết hạn sau 10 phút. Nếu bạn không yêu cầu, hãy bỏ qua email này.
          </Text>
        </Container>
      </Body>
    </Html>
  );
}
```

- [ ] **Step 8: Chạy test — kỳ vọng PASS**

Run: `pnpm test -- templates`
Expected: PASS (2 test).

- [ ] **Step 9: Commit**

```bash
git add apps/notification/src/email/templates apps/notification/tsconfig.app.json package.json pnpm-lock.yaml
git commit -m "feat(notification): React Email templates verify/reset + build tsx"
```

---

### Task 5: Consumer gửi email thật + build cả 3 app

**Files:**
- Modify: `apps/notification/src/notification.consumer.ts`
- Modify: `apps/notification/src/notification.module.ts` (import EmailModule)
- Test: `apps/notification/src/notification.consumer.spec.ts`

**Interfaces:**
- Consumes: `EmailService.send` (Task 3), `VerifyEmail`/`ResetPasswordEmail` (Task 4), `CustomerEmailActionPayload` với `code` (Task 2).

- [ ] **Step 1: Viết test thất bại** — `apps/notification/src/notification.consumer.spec.ts`

```ts
import { EVENTS } from '@app/events';
import { NotificationConsumer } from './notification.consumer';

describe('NotificationConsumer', () => {
  function make() {
    const email = { send: jest.fn().mockResolvedValue(undefined) };
    const consumer = new NotificationConsumer(email as any);
    return { consumer, email };
  }

  it('verify_requested → gửi email verify với idempotencyKey = job.id', async () => {
    const { consumer, email } = make();
    await consumer.process({
      id: 'job-1',
      name: EVENTS.CUSTOMER_VERIFY_REQUESTED,
      data: { customerId: 'c1', email: 'x@y.com', code: '123456' },
    } as any);
    expect(email.send).toHaveBeenCalledWith(
      expect.objectContaining({ to: 'x@y.com', idempotencyKey: 'job-1' }),
    );
  });

  it('job lạ → không gửi email', async () => {
    const { consumer, email } = make();
    await consumer.process({ id: 'j', name: 'unknown.event', data: {} } as any);
    expect(email.send).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Chạy test — kỳ vọng FAIL**

Run: `pnpm test -- notification.consumer`
Expected: FAIL (constructor không nhận EmailService).

- [ ] **Step 3: Sửa consumer** — `apps/notification/src/notification.consumer.ts`

```ts
import { Processor, WorkerHost } from '@nestjs/bullmq';
import { Logger } from '@nestjs/common';
import { EVENTS, QUEUES, type CustomerEmailActionPayload } from '@app/events';
import { Job } from 'bullmq';
import { EmailService } from './email/email.service';
import { VerifyEmail } from './email/templates/verify-email';
import { ResetPasswordEmail } from './email/templates/reset-password';

/**
 * CONSUMER thông báo: verify/reset → gửi email OTP qua Resend.
 * Consumer THUẦN: không phát event, không DB. idempotencyKey = job.id chống gửi trùng.
 */
@Processor(QUEUES.NOTIFICATION)
export class NotificationConsumer extends WorkerHost {
  private readonly logger = new Logger(NotificationConsumer.name);

  constructor(private readonly email: EmailService) {
    super();
  }

  async process(job: Job): Promise<void> {
    const key = job.id ?? `${job.name}:${Date.now()}`;
    switch (job.name) {
      case EVENTS.CUSTOMER_VERIFY_REQUESTED: {
        const { email, code } = job.data as CustomerEmailActionPayload;
        await this.email.send({
          to: email,
          subject: 'Mã xác minh email',
          react: VerifyEmail({ code }),
          idempotencyKey: key,
        });
        break;
      }
      case EVENTS.CUSTOMER_PASSWORD_RESET_REQUESTED: {
        const { email, code } = job.data as CustomerEmailActionPayload;
        await this.email.send({
          to: email,
          subject: 'Mã đặt lại mật khẩu',
          react: ResetPasswordEmail({ code }),
          idempotencyKey: key,
        });
        break;
      }
      case EVENTS.PAYMENT_SUCCESS:
      case EVENTS.STOCK_LOW:
      case EVENTS.STOCK_NEAR_EXPIRY:
        // TODO: producer chưa build — tạm log để xác nhận đã nhận event.
        this.logger.log(`📨 ${job.name} → ${JSON.stringify(job.data)}`);
        break;
      default:
        this.logger.warn(`Bỏ qua job lạ trên notification-queue: ${job.name}`);
    }
  }
}
```

- [ ] **Step 4: Import EmailModule** — `apps/notification/src/notification.module.ts`

Thêm `import { EmailModule } from './email/email.module';` và thêm `EmailModule` vào mảng `imports`.

- [ ] **Step 5: Chạy test — kỳ vọng PASS**

Run: `pnpm test -- notification.consumer`
Expected: PASS (2 test).

- [ ] **Step 6: Build cả 3 app — verify không vỡ**

Run: `pnpm exec nest build wms && pnpm exec nest build ecommerce && pnpm exec nest build notification`
Expected: cả 3 "compiled successfully".

- [ ] **Step 7: Chạy toàn bộ test**

Run: `pnpm test`
Expected: tất cả suite PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/notification/src/notification.consumer.ts apps/notification/src/notification.consumer.spec.ts apps/notification/src/notification.module.ts
git commit -m "feat(notification): consumer gửi email OTP verify/reset qua Resend"
```

---

## Ghi chú thực thi

- Sau Task 2, build ecom có thể cảnh báo `CustomerAuthTokenRepository` không dùng — vô hại, để lại (spec §4.1). Không xóa schema/collection trong plan này.
- `react` để ở `dependencies` (không devDependencies) để image production build được.
- Nếu `render` của `@react-email/components` không export ở phiên bản đã cài, đổi import test Task 4 sang `import { render } from '@react-email/render'` và `pnpm add @react-email/render`.
