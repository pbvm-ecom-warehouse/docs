# WMS Auth — Cookie Support + Response DTOs

**Ngày:** 2026-06-25
**Phạm vi:** `apps/wms/src/auth/` — controller, strategy, DTOs, main.ts

---

## Bối cảnh

WMS auth đang trả token thô từ Mongoose document, không có Response DTO, và chỉ hỗ trợ Bearer token. Cần bổ sung:
1. **Cookie support**: client web hoặc API đều dùng được (Bearer hoặc cookie, chọn 1 trong 2)
2. **Response DTOs**: controller không trả Mongoose document thô, tuân theo `dto-conventions.md`

---

## Yêu cầu chức năng

### Cookie behavior

- Login / google-login / refresh: **set cả 2 cookie** `access_token` và `refresh_token` **đồng thời trả trong body**
- Client tự chọn dùng cookie hay Bearer — server chấp nhận cả hai
- Logout: **clear cả 2 cookie** + revoke refresh token (dù client dùng cookie hay bearer)

### Token extraction order

1. `Authorization: Bearer <token>` — ưu tiên 1
2. Cookie `access_token` — fallback

### RefreshToken extraction order (cho `/refresh` và `/logout`)

1. `dto.refreshToken` trong body — ưu tiên 1 (nếu có và không rỗng)
2. Cookie `refresh_token` — fallback

---

## Cookie Config

| Cookie | Value | Path | HttpOnly | SameSite | Secure |
|---|---|---|---|---|---|
| `access_token` | JWT access token | `/api/wms` | `true` | `Lax` | `true` (prod) |
| `refresh_token` | opaque refresh token | `/api/wms/auth` | `true` | `Lax` | `true` (prod) |

`refresh_token` path giới hạn `/api/wms/auth` — browser chỉ gửi cookie này lên các endpoint auth (`/refresh`, `/logout`), không lộ sang mọi request khác của WMS.

`Secure` bật khi `NODE_ENV === 'production'`. Dev mode không cần HTTPS.

**Không dùng signed cookie** — token đã tự ký bằng JWT secret, không cần thêm cookie secret.

---

## Response DTOs

### `AuthTokenResponseDto` — login / google-login / refresh

```ts
class AuthTokenResponseDto {
  @Expose() accessToken: string
  @Expose() refreshToken: string
  @Expose() mustChangePassword: boolean
}
```

### `UserResponseDto` — me / updateRoles / lockUser / unlockUser

```ts
class UserResponseDto {
  @Expose() id: string           // _id.toString()
  @Expose() username: string
  @Expose() email?: string
  @Expose() name?: string
  @Expose() roles: string[]
  @Expose() status: string       // 'ACTIVE' | 'LOCKED'
  @Expose() mustChangePassword: boolean
  @Expose() warehouseId?: string // scalar ObjectId string
  @Expose() createdAt: Date
  @Expose() updatedAt: Date
  // KHÔNG expose: passwordHash, firebaseUid, deletedAt, __v
}
```

### `CreateUserResponseDto` — createUser / bootstrapAdmin

```ts
class CreateUserResponseDto {
  @Expose() id: string
  @Expose() username: string
  @Expose() email?: string
  @Expose() roles: string[]
  @Expose() mustChangePassword: boolean
}
```

Tất cả controller dùng `plainToInstance(XxxDto, data, { excludeExtraneousValues: true })`. Swagger dùng `@ApiOkResponse({ type: XxxDto })`.

---

## Request DTO thay đổi

`RefreshDto.refreshToken` và `LogoutDto.refreshToken` trở thành **optional**:
```ts
@IsOptional()
@IsString()
refreshToken?: string;
```
Vì cookie mode không cần truyền body. Validation: nếu cả cookie lẫn body đều không có → throw `AppException('AUTH_TOKEN_INVALID')`.

---

## Architecture

### `JwtStrategy` — cookie extractor

```ts
super({
  jwtFromRequest: ExtractJwt.fromExtractors([
    ExtractJwt.fromAuthHeaderAsBearerToken(),
    (req) => req?.cookies?.['access_token'] ?? null,
  ]),
  ignoreExpiration: false,
  secretOrKey: auth.jwtSecret,
});
```

### Controller — set cookie helper

Controller inject `@Res({ passthrough: true }) res: Response` chỉ ở các method cần set/clear cookie. `passthrough: true` giữ NestJS interceptor pipeline hoạt động bình thường (không mất `ResponseInterceptor`).

```ts
private setAuthCookies(res: Response, tokens: { accessToken: string; refreshToken: string }, isProd: boolean) {
  const base = { httpOnly: true, sameSite: 'lax' as const, secure: isProd };
  res.cookie('access_token', tokens.accessToken, { ...base, path: '/api/wms' });
  res.cookie('refresh_token', tokens.refreshToken, { ...base, path: '/api/wms/auth' });
}

private clearAuthCookies(res: Response) {
  res.clearCookie('access_token', { path: '/api/wms' });
  res.clearCookie('refresh_token', { path: '/api/wms/auth' });
}
```

`isProd` lấy từ `ConfigService` inject vào constructor.

### Controller — extractRefreshToken helper

```ts
private extractRefreshToken(dto: RefreshDto | LogoutDto, req: Request): string {
  const token = dto.refreshToken ?? (req.cookies?.['refresh_token'] as string | undefined);
  if (!token) throw new AppException('AUTH_TOKEN_INVALID');
  return token;
}
```

---

## Files thay đổi

| File | Thay đổi |
|---|---|
| `apps/wms/src/main.ts` | Thêm `app.use(cookieParser())` |
| `apps/wms/src/auth/jwt.strategy.ts` | Dùng `fromExtractors` thay `fromAuthHeaderAsBearerToken` |
| `apps/wms/src/auth/dto/auth.dto.ts` | Thêm 3 Response DTOs; `refreshToken` optional trong Refresh/LogoutDto |
| `apps/wms/src/auth/auth.controller.ts` | Set/clear cookie, wrap response DTO, inject `@Res`, inject `ConfigService` |
| `apps/wms/src/auth/auth.module.ts` | Không đổi (cookie-parser là global middleware) |

**Dependency mới:**
```bash
pnpm add cookie-parser
pnpm add -D @types/cookie-parser
```

---

## Không thay đổi

- `apps/wms/src/auth/auth.service.ts` — logic giữ nguyên hoàn toàn
- `libs/auth/` — guard/decorator dùng chung không biết về cookie
- `apps/ecommerce/` — không trong scope
- `apps/wms/src/config/env.validation.ts` — không cần thêm env mới (không dùng signed cookie)

---

## Swagger

Các endpoint login/refresh thêm note về cookie:
```ts
@ApiOkResponse({
  type: AuthTokenResponseDto,
  description: 'Trả token trong body VÀ set cookie access_token + refresh_token',
})
```

Swagger UI không tự test cookie (browser security), nhưng Bearer vẫn dùng bình thường qua Swagger.

---

## Luồng hoạt động

### Web browser (cookie mode)
```
POST /auth/login   → server set cookie access_token + refresh_token
GET  /auth/me      → browser tự gửi cookie access_token → JwtStrategy đọc cookie
POST /auth/refresh → browser tự gửi cookie refresh_token (path match) → server rotate, set cookie mới
POST /auth/logout  → server clear cookie, revoke token
```

### API client (Bearer mode)
```
POST /auth/login   → nhận body { accessToken, refreshToken }
GET  /auth/me      → gửi Authorization: Bearer <accessToken>
POST /auth/refresh → gửi body { refreshToken } → nhận token mới trong body
POST /auth/logout  → gửi body { refreshToken }
```

### Mixed (Postman có cookie)
```
POST /auth/login   → Postman lưu cookie tự động VÀ có token trong body
GET  /auth/me      → dùng Bearer hoặc để Postman tự gửi cookie — cả 2 đều work
```
