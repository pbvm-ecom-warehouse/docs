# WMS Auth — Cookie Support + Response DTOs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Thêm cookie support (Bearer hoặc cookie đều được) và Response DTOs chuẩn cho toàn bộ WMS auth endpoints.

**Architecture:** `cookie-parser` middleware nạp ở `main.ts`; `JwtStrategy` dùng `fromExtractors` để thử Bearer trước, fallback cookie; controller inject `@Res({ passthrough: true })` để set/clear cookie đồng thời trả token trong body; 3 Response DTOs (`AuthTokenResponseDto`, `UserResponseDto`, `CreateUserResponseDto`) wrap output bằng `plainToInstance`.

**Tech Stack:** NestJS, `cookie-parser` + `@types/cookie-parser` (dependency mới), `passport-jwt` `ExtractJwt.fromExtractors`, `class-transformer` `plainToInstance`/`@Expose`, TypeScript strict.

## Global Constraints

- TypeScript strict — không dùng `any`, không implicit any.
- Import `AppException` từ `@app/common`. Không throw NestJS exception thô trong service/controller.
- Comment tiếng Việt giải thích *vì sao*, không giải thích *cái gì*.
- Không sửa `apps/ecommerce/`, `libs/auth/`, `apps/wms/src/auth/auth.service.ts`.
- `@Res({ passthrough: true })` bắt buộc — không dùng `@Res()` thường (sẽ phá interceptor pipeline).
- Cookie `access_token`: path `/api/wms`, HttpOnly, SameSite=Lax, Secure khi prod.
- Cookie `refresh_token`: path `/api/wms/auth`, HttpOnly, SameSite=Lax, Secure khi prod.
- `Secure` = `true` khi `NODE_ENV === 'production'`, `false` khi dev.
- Chạy test: `pnpm test` từ thư mục `be/`.
- Chạy build check: `pnpm build 2>&1 | grep "error TS"` từ `be/`.

---

## File Map

| File | Trạng thái | Vai trò |
|---|---|---|
| `apps/wms/src/main.ts` | Modify | Thêm `cookieParser()` middleware |
| `apps/wms/src/auth/jwt.strategy.ts` | Modify | Thêm cookie extractor vào `fromExtractors` |
| `apps/wms/src/auth/dto/auth.dto.ts` | Modify | Thêm 3 Response DTOs; `refreshToken` optional trong RefreshDto/LogoutDto |
| `apps/wms/src/auth/auth.controller.ts` | Modify | Set/clear cookie, wrap DTO, inject `@Res` + `ConfigService` + `@Req` |

---

### Task 1: Cài dependency + middleware cookie-parser

**Files:**
- Modify: `apps/wms/src/main.ts`

**Interfaces:**
- Produces: `req.cookies` available trong mọi request của WMS app — dùng bởi Task 2 (JwtStrategy) và Task 3 (controller).

*Task này không có unit test — middleware là infrastructure, verify bằng integration (build pass + kiểm tra thủ công).*

- [ ] **Bước 1: Cài dependency**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm add cookie-parser
pnpm add -D @types/cookie-parser
```

Expected output: `dependencies: + cookie-parser`, `devDependencies: + @types/cookie-parser`

- [ ] **Bước 2: Thêm cookieParser vào main.ts**

Thay toàn bộ nội dung `apps/wms/src/main.ts`:

```ts
import cookieParser from 'cookie-parser';
import { ConfigService, ConfigType } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import { setupApp, setupSwagger } from '@app/common';
import { AppModule } from './app.module';
import { appConfig } from './config/app.config';

async function bootstrap() {
  const app = await NestFactory.create(AppModule, { bufferLogs: true });
  const config = app.get(ConfigService);
  const appCfg = config.get<ConfigType<typeof appConfig>>('app')!;

  // cookieParser phải chạy trước mọi guard để req.cookies sẵn sàng cho JwtStrategy.
  app.use(cookieParser());

  setupApp(app, {
    corsOrigins: appCfg.corsOrigins,
    isProd: appCfg.env === 'production',
    globalPrefix: 'api/wms',
  });

  setupSwagger(app, {
    title: 'WMS API',
    description:
      'Quản lý kho: auth nhân viên, tồn kho, xuất nhập, in ly, vận đơn',
    docsPath: 'api/wms/docs',
    isProd: appCfg.env === 'production',
  });

  await app.listen(appCfg.port);
}
void bootstrap();
```

- [ ] **Bước 3: Build check**

```bash
cd /home/hoaiphuong/code/wms-ecom/be && pnpm build 2>&1 | grep "error TS"
```

Expected: không có output (0 lỗi TypeScript).

- [ ] **Bước 4: Commit**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
git add apps/wms/src/main.ts package.json pnpm-lock.yaml
git commit -m "feat(wms): cài cookie-parser middleware cho WMS app"
```

---

### Task 2: JwtStrategy — cookie extractor fallback

**Files:**
- Modify: `apps/wms/src/auth/jwt.strategy.ts`
- Test: `apps/wms/src/auth/jwt.strategy.spec.ts` (tạo mới)

**Interfaces:**
- Consumes: `req.cookies['access_token']` — có sẵn sau Task 1.
- Produces: Strategy vẫn tên `'jwt'`, `JwtAuthGuard` không cần sửa. Token extract theo thứ tự: Bearer → cookie.

- [ ] **Bước 1: Tạo test file**

Tạo `apps/wms/src/auth/jwt.strategy.spec.ts`:

```ts
import { Test } from '@nestjs/testing';
import { ConfigModule } from '@nestjs/config';
import { authConfig } from '../config/auth.config';
import { JwtStrategy } from './jwt.strategy';

describe('JwtStrategy', () => {
  let strategy: JwtStrategy;

  beforeEach(async () => {
    process.env['WMS_JWT_SECRET'] = 'a'.repeat(32);
    process.env['WMS_JWT_EXPIRES_IN'] = '8h';
    process.env['WMS_REFRESH_EXPIRES_IN'] = '30d';

    const module = await Test.createTestingModule({
      imports: [ConfigModule.forFeature(authConfig)],
      providers: [JwtStrategy],
    }).compile();

    strategy = module.get(JwtStrategy);
  });

  it('validate trả payload khi type=user', () => {
    const payload = { sub: 'id1', type: 'user' as const, roles: ['ADMIN'], username: 'admin' };
    expect(strategy.validate(payload)).toEqual(payload);
  });

  it('validate throw khi type≠user', () => {
    const payload = { sub: 'id1', type: 'customer' as const, email: 'x@x.com' };
    // @ts-expect-error — kiểm tra runtime guard
    expect(() => strategy.validate(payload)).toThrow();
  });
});
```

- [ ] **Bước 2: Chạy test — xác nhận pass (test chỉ cover validate, không cover extractor)**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm test --testPathPatterns="apps/wms/src/auth/jwt.strategy.spec"
```

Expected: PASS 2 tests.

- [ ] **Bước 3: Sửa JwtStrategy — thêm cookie extractor**

Thay toàn bộ `apps/wms/src/auth/jwt.strategy.ts`:

```ts
import { Inject, Injectable, UnauthorizedException } from '@nestjs/common';
import type { ConfigType } from '@nestjs/config';
import { PassportStrategy } from '@nestjs/passport';
import type { AuthUser, JwtPayload } from '@app/auth';
import type { Request } from 'express';
import { ExtractJwt, Strategy } from 'passport-jwt';
import { authConfig } from '../config/auth.config';

/**
 * Strategy 'jwt' của WMS — verify token bằng WMS_JWT_SECRET (RIÊNG, khác Ecommerce).
 * Thứ tự extract: Authorization Bearer trước, fallback cookie access_token.
 * Cho phép web dùng cookie HttpOnly mà không cần JS đọc token.
 */
@Injectable()
export class JwtStrategy extends PassportStrategy(Strategy) {
  constructor(@Inject(authConfig.KEY) auth: ConfigType<typeof authConfig>) {
    super({
      jwtFromRequest: ExtractJwt.fromExtractors([
        ExtractJwt.fromAuthHeaderAsBearerToken(),
        (req: Request) => (req?.cookies as Record<string, string> | undefined)?.['access_token'] ?? null,
      ]),
      ignoreExpiration: false,
      secretOrKey: auth.jwtSecret,
    });
  }

  // Giá trị trả về được gắn vào request.user.
  validate(payload: JwtPayload): AuthUser {
    if (payload.type !== 'user') {
      throw new UnauthorizedException('Token không phải của nhân viên WMS');
    }
    return payload;
  }
}
```

- [ ] **Bước 4: Build check**

```bash
cd /home/hoaiphuong/code/wms-ecom/be && pnpm build 2>&1 | grep "error TS"
```

Expected: không có output.

- [ ] **Bước 5: Commit**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
git add apps/wms/src/auth/jwt.strategy.ts apps/wms/src/auth/jwt.strategy.spec.ts
git commit -m "feat(wms-auth): JwtStrategy hỗ trợ cookie fallback cho access_token"
```

---

### Task 3: DTOs — Response DTOs + RefreshDto/LogoutDto optional

**Files:**
- Modify: `apps/wms/src/auth/dto/auth.dto.ts`
- Test: `apps/wms/src/auth/dto/auth.dto.spec.ts` (tạo mới)

**Interfaces:**
- Produces:
  - `AuthTokenResponseDto` — dùng trong Task 4 cho login/google-login/refresh
  - `UserResponseDto` — dùng trong Task 4 cho me/updateRoles/lockUser/unlockUser
  - `CreateUserResponseDto` — dùng trong Task 4 cho createUser/bootstrapAdmin
  - `RefreshDto.refreshToken?: string` — optional (có thể đến từ cookie)
  - `LogoutDto.refreshToken?: string` — optional (có thể đến từ cookie)

- [ ] **Bước 1: Tạo test file cho Response DTOs**

Tạo `apps/wms/src/auth/dto/auth.dto.spec.ts`:

```ts
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { AuthTokenResponseDto, UserResponseDto, CreateUserResponseDto, RefreshDto, LogoutDto } from './auth.dto';

describe('AuthTokenResponseDto', () => {
  it('expose accessToken, refreshToken, mustChangePassword — không expose field lạ', () => {
    const raw = { accessToken: 'at', refreshToken: 'rt', mustChangePassword: true, passwordHash: 'secret' };
    const dto = plainToInstance(AuthTokenResponseDto, raw, { excludeExtraneousValues: true });
    expect(dto.accessToken).toBe('at');
    expect(dto.refreshToken).toBe('rt');
    expect(dto.mustChangePassword).toBe(true);
    expect((dto as Record<string, unknown>)['passwordHash']).toBeUndefined();
  });
});

describe('UserResponseDto', () => {
  it('expose id từ _id, không expose passwordHash/firebaseUid/deletedAt', () => {
    const raw = {
      _id: { toString: () => 'user-id-123' },
      username: 'admin',
      email: 'admin@example.com',
      name: 'Admin',
      roles: ['ADMIN'],
      status: 'ACTIVE',
      mustChangePassword: false,
      warehouseId: { toString: () => 'wh-id-456' },
      createdAt: new Date('2025-01-01'),
      updatedAt: new Date('2025-01-02'),
      passwordHash: 'secret',
      firebaseUid: 'fb-uid',
      deletedAt: null,
    };
    const dto = plainToInstance(UserResponseDto, raw, { excludeExtraneousValues: true });
    expect(dto.id).toBe('user-id-123');
    expect(dto.username).toBe('admin');
    expect(dto.warehouseId).toBe('wh-id-456');
    expect((dto as Record<string, unknown>)['passwordHash']).toBeUndefined();
    expect((dto as Record<string, unknown>)['firebaseUid']).toBeUndefined();
    expect((dto as Record<string, unknown>)['deletedAt']).toBeUndefined();
  });
});

describe('CreateUserResponseDto', () => {
  it('expose id, username, email, roles, mustChangePassword', () => {
    const raw = { _id: { toString: () => 'id-1' }, username: 'user1', email: 'u@x.com', roles: ['RECEIVER'], mustChangePassword: true, passwordHash: 'x' };
    const dto = plainToInstance(CreateUserResponseDto, raw, { excludeExtraneousValues: true });
    expect(dto.id).toBe('id-1');
    expect((dto as Record<string, unknown>)['passwordHash']).toBeUndefined();
  });
});

describe('RefreshDto — refreshToken optional', () => {
  it('pass validation khi không có refreshToken', async () => {
    const dto = plainToInstance(RefreshDto, {});
    const errors = await validate(dto);
    expect(errors).toHaveLength(0);
  });

  it('pass validation khi có refreshToken', async () => {
    const dto = plainToInstance(RefreshDto, { refreshToken: 'abc' });
    const errors = await validate(dto);
    expect(errors).toHaveLength(0);
  });
});

describe('LogoutDto — refreshToken optional', () => {
  it('pass validation khi không có refreshToken', async () => {
    const dto = plainToInstance(LogoutDto, {});
    const errors = await validate(dto);
    expect(errors).toHaveLength(0);
  });
});
```

- [ ] **Bước 2: Chạy test — xác nhận fail**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm test --testPathPatterns="apps/wms/src/auth/dto/auth.dto.spec"
```

Expected: FAIL — `AuthTokenResponseDto`, `UserResponseDto`, `CreateUserResponseDto` chưa tồn tại.

- [ ] **Bước 3: Thêm Response DTOs và sửa RefreshDto/LogoutDto**

Thay toàn bộ `apps/wms/src/auth/dto/auth.dto.ts`:

```ts
import {
  ArrayNotEmpty,
  IsArray,
  IsEmail,
  IsIn,
  IsOptional,
  IsString,
  MinLength,
} from 'class-validator';
import { Expose, Transform } from 'class-transformer';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { WmsRole } from '@app/auth';
import { Types } from 'mongoose';

export class LoginDto {
  @ApiProperty({ example: 'admin' })
  @IsString()
  username!: string;

  @ApiProperty({ example: 'P@ssw0rd!', minLength: 1 })
  @IsString()
  @MinLength(1)
  password!: string;
}

export class GoogleLoginDto {
  @ApiProperty({ description: 'Firebase ID token lấy từ Google sign-in' })
  @IsString()
  idToken!: string;
}

export class RefreshDto {
  @ApiPropertyOptional({ description: 'Refresh token nhận được lúc login — bỏ qua nếu dùng cookie mode' })
  @IsOptional()
  @IsString()
  refreshToken?: string;
}

export class LogoutDto {
  @ApiPropertyOptional({ description: 'Refresh token cần thu hồi — bỏ qua nếu dùng cookie mode' })
  @IsOptional()
  @IsString()
  refreshToken?: string;
}

export class CreateUserDto {
  @ApiProperty({ example: 'nguyen.van.a', minLength: 3 })
  @IsString()
  @MinLength(3)
  username!: string;

  @ApiProperty({ example: 'P@ssw0rd123!', minLength: 8 })
  @IsString()
  @MinLength(8)
  password!: string;

  @ApiPropertyOptional({ example: 'staff@example.com' })
  @IsOptional()
  @IsEmail()
  email?: string;

  @ApiPropertyOptional({ example: 'Nguyễn Văn A' })
  @IsOptional()
  @IsString()
  name?: string;

  @ApiPropertyOptional({
    example: [WmsRole.RECEIVER],
    enum: WmsRole,
    isArray: true,
  })
  @IsOptional()
  @IsArray()
  @ArrayNotEmpty()
  @IsIn(Object.values(WmsRole), { each: true })
  roles?: string[];
}

export class UpdateUserRolesDto {
  @ApiProperty({ example: [WmsRole.RECEIVER], enum: WmsRole, isArray: true })
  @IsArray()
  @ArrayNotEmpty()
  @IsIn(Object.values(WmsRole), { each: true })
  roles!: string[];
}

export class ResetUserPasswordDto {
  @ApiProperty({ example: 'TempP@ssw0rd123!', minLength: 8 })
  @IsString()
  @MinLength(8)
  temporaryPassword!: string;
}

export class ChangePasswordDto {
  @ApiProperty({ example: 'OldP@ssw0rd123!' })
  @IsString()
  @MinLength(1)
  oldPassword!: string;

  @ApiProperty({ example: 'NewP@ssw0rd123!', minLength: 8 })
  @IsString()
  @MinLength(8)
  newPassword!: string;
}

// ─── Response DTOs ────────────────────────────────────────────────────────────

/** Response cho login / google-login / refresh. */
export class AuthTokenResponseDto {
  @Expose()
  @ApiProperty()
  accessToken!: string;

  @Expose()
  @ApiProperty()
  refreshToken!: string;

  @Expose()
  @ApiProperty()
  mustChangePassword!: boolean;
}

/** Response cho GET /me, PATCH /users/:id/roles, POST /users/:id/lock|unlock. */
export class UserResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId | { toString(): string } } }) =>
    obj._id?.toString(),
  )
  @ApiProperty()
  id!: string;

  @Expose()
  @ApiProperty()
  username!: string;

  @Expose()
  @ApiPropertyOptional()
  email?: string;

  @Expose()
  @ApiPropertyOptional()
  name?: string;

  @Expose()
  @ApiProperty({ type: [String] })
  roles!: string[];

  @Expose()
  @ApiProperty({ enum: ['ACTIVE', 'LOCKED'] })
  status!: string;

  @Expose()
  @ApiProperty()
  mustChangePassword!: boolean;

  @Expose()
  @Transform(({ obj }: { obj: { warehouseId?: Types.ObjectId | { toString(): string } | null } }) =>
    obj.warehouseId?.toString() ?? undefined,
  )
  @ApiPropertyOptional()
  warehouseId?: string;

  @Expose()
  @ApiProperty()
  createdAt!: Date;

  @Expose()
  @ApiProperty()
  updatedAt!: Date;
}

/** Response cho POST /users và POST /bootstrap-admin. */
export class CreateUserResponseDto {
  @Expose()
  @Transform(({ obj }: { obj: { _id?: Types.ObjectId | { toString(): string } } }) =>
    obj._id?.toString(),
  )
  @ApiProperty()
  id!: string;

  @Expose()
  @ApiProperty()
  username!: string;

  @Expose()
  @ApiPropertyOptional()
  email?: string;

  @Expose()
  @ApiProperty({ type: [String] })
  roles!: string[];

  @Expose()
  @ApiProperty()
  mustChangePassword!: boolean;
}
```

- [ ] **Bước 4: Chạy test — xác nhận pass**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm test --testPathPatterns="apps/wms/src/auth/dto/auth.dto.spec"
```

Expected: PASS tất cả.

- [ ] **Bước 5: Build check**

```bash
cd /home/hoaiphuong/code/wms-ecom/be && pnpm build 2>&1 | grep "error TS"
```

Expected: không có output.

- [ ] **Bước 6: Commit**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
git add apps/wms/src/auth/dto/auth.dto.ts apps/wms/src/auth/dto/auth.dto.spec.ts
git commit -m "feat(wms-auth): thêm Response DTOs và optional refreshToken cho cookie mode"
```

---

### Task 4: Controller — set/clear cookie + wrap Response DTOs

**Files:**
- Modify: `apps/wms/src/auth/auth.controller.ts`
- Test: `apps/wms/src/auth/auth.controller.spec.ts` (tạo mới)

**Interfaces:**
- Consumes:
  - `AuthTokenResponseDto`, `UserResponseDto`, `CreateUserResponseDto` từ Task 3
  - `RefreshDto.refreshToken?: string`, `LogoutDto.refreshToken?: string` từ Task 3
  - `req.cookies['refresh_token']` — có sẵn sau Task 1
- Produces: Toàn bộ endpoints trả đúng Response DTO + set/clear cookie.

- [ ] **Bước 1: Tạo test file**

Tạo `apps/wms/src/auth/auth.controller.spec.ts`:

```ts
import { Test, TestingModule } from '@nestjs/testing';
import { ConfigService } from '@nestjs/config';
import { plainToInstance } from 'class-transformer';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { AuthTokenResponseDto, UserResponseDto } from './dto/auth.dto';

const mockAuthService = {
  login: jest.fn(),
  googleLogin: jest.fn(),
  refresh: jest.fn(),
  logout: jest.fn(),
  me: jest.fn(),
  bootstrapAdmin: jest.fn(),
  createUser: jest.fn(),
  updateRoles: jest.fn(),
  lockUser: jest.fn(),
  unlockUser: jest.fn(),
  resetTemporaryPassword: jest.fn(),
  changePassword: jest.fn(),
};

const mockConfigService = {
  get: jest.fn().mockReturnValue({ env: 'development' }),
};

const makeMockRes = () => ({
  cookie: jest.fn(),
  clearCookie: jest.fn(),
});

const makeMockReq = (cookies: Record<string, string> = {}) => ({ cookies });

describe('AuthController', () => {
  let controller: AuthController;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      controllers: [AuthController],
      providers: [
        { provide: AuthService, useValue: mockAuthService },
        { provide: ConfigService, useValue: mockConfigService },
      ],
    }).compile();
    controller = module.get(AuthController);
    jest.clearAllMocks();
  });

  describe('login', () => {
    it('set cookie và trả AuthTokenResponseDto', async () => {
      const tokens = { accessToken: 'at', refreshToken: 'rt', mustChangePassword: false };
      mockAuthService.login.mockResolvedValue(tokens);
      const res = makeMockRes();

      const result = await controller.login({ username: 'admin', password: 'pass' }, res as never);

      expect(res.cookie).toHaveBeenCalledWith('access_token', 'at', expect.objectContaining({ httpOnly: true, path: '/api/wms' }));
      expect(res.cookie).toHaveBeenCalledWith('refresh_token', 'rt', expect.objectContaining({ httpOnly: true, path: '/api/wms/auth' }));
      expect(result).toMatchObject({ accessToken: 'at', refreshToken: 'rt', mustChangePassword: false });
    });
  });

  describe('refresh', () => {
    it('ưu tiên body refreshToken', async () => {
      mockAuthService.refresh.mockResolvedValue({ accessToken: 'at2', refreshToken: 'rt2', mustChangePassword: false });
      const res = makeMockRes();
      const req = makeMockReq({ refresh_token: 'cookie-token' });

      await controller.refresh({ refreshToken: 'body-token' }, res as never, req as never);

      expect(mockAuthService.refresh).toHaveBeenCalledWith('body-token');
    });

    it('fallback cookie khi body không có refreshToken', async () => {
      mockAuthService.refresh.mockResolvedValue({ accessToken: 'at2', refreshToken: 'rt2', mustChangePassword: false });
      const res = makeMockRes();
      const req = makeMockReq({ refresh_token: 'cookie-token' });

      await controller.refresh({}, res as never, req as never);

      expect(mockAuthService.refresh).toHaveBeenCalledWith('cookie-token');
    });
  });

  describe('logout', () => {
    it('clear cookie sau khi revoke', async () => {
      mockAuthService.logout.mockResolvedValue({ success: true });
      const res = makeMockRes();
      const req = makeMockReq({ refresh_token: 'rt' });

      await controller.logout({}, res as never, req as never);

      expect(res.clearCookie).toHaveBeenCalledWith('access_token', { path: '/api/wms' });
      expect(res.clearCookie).toHaveBeenCalledWith('refresh_token', { path: '/api/wms/auth' });
    });
  });

  describe('me', () => {
    it('trả UserResponseDto — không có passwordHash', async () => {
      mockAuthService.me.mockResolvedValue({
        _id: { toString: () => 'uid' },
        username: 'admin',
        roles: ['ADMIN'],
        status: 'ACTIVE',
        mustChangePassword: false,
        passwordHash: 'secret',
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      const result = await controller.me('uid');
      expect(result).toBeInstanceOf(UserResponseDto);
      expect((result as Record<string, unknown>)['passwordHash']).toBeUndefined();
      expect((result as UserResponseDto).id).toBe('uid');
    });
  });
});
```

- [ ] **Bước 2: Chạy test — xác nhận fail**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm test --testPathPatterns="apps/wms/src/auth/auth.controller.spec"
```

Expected: FAIL — controller chưa có cookie logic và Response DTO.

- [ ] **Bước 3: Thay toàn bộ auth.controller.ts**

```ts
import {
  Body,
  Controller,
  Get,
  HttpCode,
  Param,
  Patch,
  Post,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiBody,
  ApiParam,
  ApiCreatedResponse,
  ApiForbiddenResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
  ApiUnauthorizedResponse,
} from '@nestjs/swagger';
import {
  CurrentUser,
  JwtAuthGuard,
  Roles,
  RolesGuard,
  WmsRole,
} from '@app/auth';
import { AppException, AuthThrottle } from '@app/common';
import { ConfigService } from '@nestjs/config';
import { plainToInstance } from 'class-transformer';
import type { Request, Response } from 'express';
import { AuthService } from './auth.service';
import {
  AuthTokenResponseDto,
  ChangePasswordDto,
  CreateUserDto,
  CreateUserResponseDto,
  GoogleLoginDto,
  LoginDto,
  LogoutDto,
  RefreshDto,
  ResetUserPasswordDto,
  UpdateUserRolesDto,
  UserResponseDto,
} from './dto/auth.dto';

@ApiTags('auth')
@Controller('auth')
export class AuthController {
  private readonly isProd: boolean;

  constructor(
    private readonly auth: AuthService,
    private readonly config: ConfigService,
  ) {
    this.isProd = this.config.get<string>('NODE_ENV') === 'production';
  }

  // Cookie access_token: path rộng để dùng mọi route WMS.
  // Cookie refresh_token: path hẹp /api/wms/auth để browser chỉ gửi lên auth endpoints.
  private setAuthCookies(
    res: Response,
    tokens: { accessToken: string; refreshToken: string },
  ): void {
    const base = { httpOnly: true, sameSite: 'lax' as const, secure: this.isProd };
    res.cookie('access_token', tokens.accessToken, { ...base, path: '/api/wms' });
    res.cookie('refresh_token', tokens.refreshToken, { ...base, path: '/api/wms/auth' });
  }

  private clearAuthCookies(res: Response): void {
    res.clearCookie('access_token', { path: '/api/wms' });
    res.clearCookie('refresh_token', { path: '/api/wms/auth' });
  }

  // Ưu tiên body, fallback cookie — để API client và web browser đều dùng được.
  private extractRefreshToken(dto: RefreshDto | LogoutDto, req: Request): string {
    const cookies = req.cookies as Record<string, string> | undefined;
    const token = dto.refreshToken ?? cookies?.['refresh_token'];
    if (!token) throw new AppException('AUTH_TOKEN_INVALID');
    return token;
  }

  @Post('login')
  @HttpCode(200)
  @AuthThrottle()
  @ApiOperation({ summary: 'Đăng nhập nhân viên' })
  @ApiBody({
    type: LoginDto,
    examples: {
      admin: {
        summary: 'Admin',
        value: { username: 'admin', password: 'P@ssw0rd123!' },
      },
    },
  })
  @ApiOkResponse({
    type: AuthTokenResponseDto,
    description: 'Trả token trong body VÀ set cookie access_token + refresh_token',
  })
  @ApiUnauthorizedResponse({ description: 'Sai tài khoản hoặc mật khẩu' })
  async login(
    @Body() dto: LoginDto,
    @Res({ passthrough: true }) res: Response,
  ): Promise<AuthTokenResponseDto> {
    const tokens = await this.auth.login(dto.username, dto.password);
    this.setAuthCookies(res, tokens);
    return plainToInstance(AuthTokenResponseDto, tokens, { excludeExtraneousValues: true });
  }

  @Post('google-login')
  @HttpCode(200)
  @AuthThrottle()
  @ApiOperation({ summary: 'Đăng nhập bằng Google/Firebase' })
  @ApiBody({
    type: GoogleLoginDto,
    examples: {
      google: { value: { idToken: 'paste-firebase-id-token-here' } },
    },
  })
  @ApiOkResponse({
    type: AuthTokenResponseDto,
    description: 'Trả token trong body VÀ set cookie access_token + refresh_token',
  })
  @ApiUnauthorizedResponse({ description: 'Firebase token không hợp lệ hoặc nhân viên chưa khởi tạo' })
  async googleLogin(
    @Body() dto: GoogleLoginDto,
    @Res({ passthrough: true }) res: Response,
  ): Promise<AuthTokenResponseDto> {
    const tokens = await this.auth.googleLogin(dto.idToken);
    this.setAuthCookies(res, tokens);
    return plainToInstance(AuthTokenResponseDto, tokens, { excludeExtraneousValues: true });
  }

  @Post('refresh')
  @HttpCode(200)
  @AuthThrottle()
  @ApiOperation({ summary: 'Đổi access token mới bằng refresh token (body hoặc cookie)' })
  @ApiBody({
    type: RefreshDto,
    examples: {
      bearer: { summary: 'Bearer mode', value: { refreshToken: 'paste-refresh-token-here' } },
      cookie: { summary: 'Cookie mode', value: {} },
    },
  })
  @ApiOkResponse({
    type: AuthTokenResponseDto,
    description: 'Trả token mới trong body VÀ set cookie mới (rotate)',
  })
  async refresh(
    @Body() dto: RefreshDto,
    @Res({ passthrough: true }) res: Response,
    @Req() req: Request,
  ): Promise<AuthTokenResponseDto> {
    const refreshToken = this.extractRefreshToken(dto, req);
    const tokens = await this.auth.refresh(refreshToken);
    this.setAuthCookies(res, tokens);
    return plainToInstance(AuthTokenResponseDto, tokens, { excludeExtraneousValues: true });
  }

  @Post('logout')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Đăng xuất và thu hồi refresh token' })
  @ApiBody({
    type: LogoutDto,
    examples: {
      bearer: { summary: 'Bearer mode', value: { refreshToken: 'paste-refresh-token-here' } },
      cookie: { summary: 'Cookie mode', value: {} },
    },
  })
  async logout(
    @Body() dto: LogoutDto,
    @Res({ passthrough: true }) res: Response,
    @Req() req: Request,
  ): Promise<{ success: boolean }> {
    const refreshToken = this.extractRefreshToken(dto, req);
    const result = await this.auth.logout(refreshToken);
    this.clearAuthCookies(res);
    return result;
  }

  @Get('me')
  @UseGuards(JwtAuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Thông tin nhân viên đang đăng nhập' })
  @ApiOkResponse({ type: UserResponseDto })
  async me(@CurrentUser('sub') userId: string): Promise<UserResponseDto> {
    const user = await this.auth.me(userId);
    return plainToInstance(UserResponseDto, user, { excludeExtraneousValues: true });
  }

  @Post('bootstrap-admin')
  @ApiOperation({
    summary: 'Khởi tạo admin đầu tiên khi hệ thống chưa có user',
  })
  @ApiBody({
    type: CreateUserDto,
    examples: {
      bootstrap: {
        value: {
          username: 'admin',
          password: 'P@ssw0rd123!',
          email: 'admin@example.com',
          name: 'System Admin',
        },
      },
    },
  })
  @ApiCreatedResponse({ type: CreateUserResponseDto })
  @ApiForbiddenResponse({ description: 'Đã có nhân viên trong hệ thống' })
  async bootstrapAdmin(@Body() dto: CreateUserDto): Promise<CreateUserResponseDto> {
    const user = await this.auth.bootstrapAdmin(dto);
    return plainToInstance(CreateUserResponseDto, user, { excludeExtraneousValues: true });
  }

  @Post('users')
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles(WmsRole.ADMIN)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Tạo nhân viên mới — chỉ ADMIN' })
  @ApiBody({
    type: CreateUserDto,
    examples: {
      receiver: {
        value: {
          username: 'receiver01',
          password: 'TempP@ssw0rd123!',
          email: 'receiver01@example.com',
          name: 'Receiver 01',
          roles: ['RECEIVER'],
        },
      },
    },
  })
  @ApiCreatedResponse({ type: CreateUserResponseDto })
  async createUser(
    @Body() dto: CreateUserDto,
    @CurrentUser('sub') by: string,
  ): Promise<CreateUserResponseDto> {
    const user = await this.auth.createUser(dto, by);
    return plainToInstance(CreateUserResponseDto, user, { excludeExtraneousValues: true });
  }

  @Patch('users/:id/roles')
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles(WmsRole.ADMIN)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Gán/sửa roles nhân viên — chỉ ADMIN' })
  @ApiParam({ name: 'id', description: 'Mongo ObjectId của user' })
  @ApiBody({
    type: UpdateUserRolesDto,
    examples: { roles: { value: { roles: ['RECEIVER', 'PICKER'] } } },
  })
  @ApiOkResponse({ type: UserResponseDto })
  async updateRoles(
    @Param('id') id: string,
    @Body() dto: UpdateUserRolesDto,
    @CurrentUser('sub') by: string,
  ): Promise<UserResponseDto> {
    const user = await this.auth.updateRoles(id, dto.roles, by);
    return plainToInstance(UserResponseDto, user, { excludeExtraneousValues: true });
  }

  @Post('users/:id/lock')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles(WmsRole.ADMIN)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Khóa tài khoản và revoke tất cả refresh token' })
  @ApiParam({ name: 'id', description: 'Mongo ObjectId của user' })
  @ApiOkResponse({ type: UserResponseDto })
  async lockUser(
    @Param('id') id: string,
    @CurrentUser('sub') by: string,
  ): Promise<UserResponseDto> {
    const user = await this.auth.lockUser(id, by);
    return plainToInstance(UserResponseDto, user, { excludeExtraneousValues: true });
  }

  @Post('users/:id/unlock')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles(WmsRole.ADMIN)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Mở khóa tài khoản' })
  @ApiParam({ name: 'id', description: 'Mongo ObjectId của user' })
  @ApiOkResponse({ type: UserResponseDto })
  async unlockUser(
    @Param('id') id: string,
    @CurrentUser('sub') by: string,
  ): Promise<UserResponseDto> {
    const user = await this.auth.unlockUser(id, by);
    return plainToInstance(UserResponseDto, user, { excludeExtraneousValues: true });
  }

  @Post('users/:id/reset-password')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles(WmsRole.ADMIN)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Reset mật khẩu tạm và bắt đổi mật khẩu' })
  @ApiParam({ name: 'id', description: 'Mongo ObjectId của user' })
  @ApiBody({
    type: ResetUserPasswordDto,
    examples: { reset: { value: { temporaryPassword: 'TempP@ssw0rd123!' } } },
  })
  @ApiOkResponse({ description: '{ success: true, mustChangePassword: true }' })
  resetPassword(
    @Param('id') id: string,
    @Body() dto: ResetUserPasswordDto,
    @CurrentUser('sub') by: string,
  ): Promise<{ success: boolean; mustChangePassword: boolean }> {
    return this.auth.resetTemporaryPassword(id, dto.temporaryPassword, by);
  }

  @Post('change-password')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Nhân viên đổi mật khẩu' })
  @ApiBody({
    type: ChangePasswordDto,
    examples: {
      change: {
        value: {
          oldPassword: 'TempP@ssw0rd123!',
          newPassword: 'NewP@ssw0rd123!',
        },
      },
    },
  })
  @ApiOkResponse({ description: '{ success: true, mustChangePassword: false }' })
  changePassword(
    @CurrentUser('sub') userId: string,
    @Body() dto: ChangePasswordDto,
  ): Promise<{ success: boolean; mustChangePassword: boolean }> {
    return this.auth.changePassword(userId, dto);
  }
}
```

- [ ] **Bước 4: Chạy test**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm test --testPathPatterns="apps/wms/src/auth/auth.controller.spec"
```

Expected: PASS tất cả tests.

- [ ] **Bước 5: Chạy toàn bộ test suite**

```bash
cd /home/hoaiphuong/code/wms-ecom/be && pnpm test
```

Expected: PASS tất cả — không có regression.

- [ ] **Bước 6: Build check**

```bash
cd /home/hoaiphuong/code/wms-ecom/be && pnpm build 2>&1 | grep "error TS"
```

Expected: không có output.

- [ ] **Bước 7: Commit**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
git add apps/wms/src/auth/auth.controller.ts apps/wms/src/auth/auth.controller.spec.ts
git commit -m "feat(wms-auth): cookie support + Response DTOs cho tất cả auth endpoints"
```

---

## Checklist Tự Kiểm Tra Sau Hoàn Thành

- [ ] `pnpm test` PASS
- [ ] `pnpm build` không có lỗi TypeScript
- [ ] `POST /api/wms/auth/login` → response body có `accessToken`, `refreshToken`, `mustChangePassword`; Set-Cookie header có `access_token` và `refresh_token`
- [ ] `GET /api/wms/auth/me` với cookie `access_token` → trả `UserResponseDto` (có `id`, không có `passwordHash`)
- [ ] `POST /api/wms/auth/refresh` với body trống + cookie `refresh_token` → nhận token mới
- [ ] `POST /api/wms/auth/logout` với body trống + cookie → cookie bị clear
- [ ] Swagger UI tại `/api/wms/docs` hiển thị schema đúng cho `AuthTokenResponseDto`, `UserResponseDto`
