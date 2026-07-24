# User CRUD cho Admin/Manager (WMS) — Design

**Ngày:** 2026-07-21
**App:** `apps/wms`
**Trạng thái:** Approved (chờ implementation plan)

## Bối cảnh

Quản lý tài khoản nhân viên (`users` collection, `apps/wms/src/auth/schemas/user.schema.ts`) hiện nằm gọn trong `AuthModule`. Đã có sẵn:

- `POST /api/wms/auth/users` — tạo user
- `PATCH /api/wms/auth/users/:id/roles` — đổi roles
- `POST /api/wms/auth/users/:id/lock` / `unlock` — khóa/mở khóa
- `POST /api/wms/auth/users/:id/reset-password` — admin đặt lại mật khẩu

Tất cả các route trên đang `@Roles(WmsRole.ADMIN)` **only**. Không có: list, get by id, sửa profile (name/email/warehouseId), xóa. `UserRepository` không có `findAll`/`count`. Field `deletedAt` đã khai báo trên schema nhưng chưa có chỗ nào set.

## Mục tiêu

Bổ sung đầy đủ CRUD user cho ADMIN + MANAGER, tách thành module riêng đúng convention "1 domain = 1 module" của dự án.

## Quyết định thiết kế

### 1. Tách `UsersModule` khỏi `AuthModule`

Tạo `apps/wms/src/users/` (module/controller/service/repository/dto). Di chuyển từ `AuthModule` sang:
- `UserRepository`, `User`/`UserRefreshToken` schema registration
- `CreateUserDto`, `UpdateUserRolesDto`, `ResetUserPasswordDto`, `UserResponseDto`, `CreateUserResponseDto`
- Các endpoint `users/*` hiện có (create, roles, lock, unlock, reset-password)

`AuthModule` **giữ lại**: login, google-login, refresh, logout, bootstrap-admin, `GET /me`, `POST change-password` (self-service). `AuthModule` import `UsersModule` để dùng `UserRepository`/`UsersService` phục vụ login/me — tránh đăng ký `User` schema ở 2 module.

### 2. Phân quyền: ADMIN + MANAGER ngang nhau, trừ thao tác với tài khoản ADMIN

- Class-level: `@UseGuards(JwtAuthGuard, RolesGuard)` + `@Roles(WmsRole.ADMIN, WmsRole.MANAGER)`.
- Rule chặn leo thang quyền, tập trung trong `UsersService` (1 helper dùng lại ở mọi method ghi):
  - MANAGER không được **tạo** user với `roles` chứa `ADMIN`.
  - MANAGER không được **sửa** (update/roles/lock/unlock/reset-password/delete) một user mà **hiện tại** có role `ADMIN`, kể cả khi thao tác đó không đổi role.
  - Không ai được tự xóa chính mình (`DELETE /users/:id` với `id === actor.sub`) → 403, kể cả ADMIN.
- ADMIN luôn bypass mọi `@Roles` (hành vi sẵn có của `RolesGuard`), không cần thêm gì cho phía ADMIN.

### 3. Endpoints

Prefix: `api/wms/users` (global prefix `api/wms` + controller `users`).

| Method | Route | Việc làm | Rule leo thang quyền |
|---|---|---|---|
| GET | `/users` | List, offset pagination + filter | — |
| GET | `/users/:id` | Chi tiết | — |
| POST | `/users` | Tạo user | Chặn nếu `dto.roles` có `ADMIN` và actor là MANAGER |
| PATCH | `/users/:id` | Sửa `name`/`email`/`warehouseId` | Chặn nếu target có role `ADMIN` và actor là MANAGER |
| PATCH | `/users/:id/roles` | Đổi roles (di chuyển) | Chặn nếu target hoặc roles mới có `ADMIN` và actor là MANAGER |
| POST | `/users/:id/lock` | Khóa (di chuyển) | Cùng rule target-ADMIN |
| POST | `/users/:id/unlock` | Mở khóa (di chuyển) | Cùng rule target-ADMIN |
| POST | `/users/:id/reset-password` | Admin đặt lại mật khẩu (di chuyển) | Cùng rule target-ADMIN |
| DELETE | `/users/:id` | Soft-delete | Cùng rule target-ADMIN + chặn tự xóa |

Tất cả response (trừ 204/không nội dung) bọc qua `plainToInstance(UserResponseDto, ..., { excludeExtraneousValues: true })`. List trả `PaginatedResult` (cross-cutting `ResponseInterceptor` tự gộp `items`→`data`, `pagination`→`meta`).

### 4. List — filter & pagination

`QueryUsersDto extends OffsetPaginationQuery` (từ `@app/common`, convention "màn admin dùng offset"):

```ts
export class QueryUsersDto extends OffsetPaginationQuery {
  @IsOptional() @IsEnum(WmsRole) role?: WmsRole;
  @IsOptional() @IsEnum(UserStatus) status?: UserStatus;
  @IsOptional() @IsString() warehouseId?: string;
  @IsOptional() @IsString() search?: string; // match username/name/email
}
```

`UserRepository.findAll(query)` filter mặc định `deletedAt: null`, build Mongo filter từ các field trên (search dùng `$or` regex case-insensitive trên `username`/`name`/`email`), trả `{ items, totalItems }`. `UsersService` build `buildOffsetMeta(items.length, page, limit, totalItems)`.

### 5. Update profile (`PATCH /users/:id`)

`UpdateUserDto`: `name?`, `email?`, `warehouseId?` — tất cả optional. **Không** đổi `username` (immutable, theo quyết định đã chốt) và **không** đổi `roles`/`status` qua route này (đã có route riêng, giữ nguyên convention hiện có). Trùng `email` với user khác → `AUTH_EMAIL_CONFLICT` (tái dùng code cross-cutting có sẵn).

### 6. Delete = soft-delete

`DELETE /users/:id`:
- Set `deletedAt = new Date()`, `updatedBy = actor.sub`.
- Không hard-delete — chứng từ tham chiếu `createdBy`/`approvedBy`/... giữ nguyên (đúng nguyên tắc "chứng từ giao dịch không xóa, actor id vẫn còn giá trị tham chiếu lịch sử").
- `UserRepository` (và `findByUsername`/`findById` dùng cho login) phải filter `deletedAt: null` — user đã xóa không login được nữa (tự nhiên vì `findByUsername` trả null → `AUTH_INVALID_CREDENTIALS` hoặc tương đương).
- Không cần "undelete" trong scope này.

### 7. Error codes mới — đặt vào `ERROR_CATALOG` (`libs/common/src/errors/error-codes.ts`), KHÔNG phải `WMS_ERRORS`

`.claude/rules/error-handling.md` nói mã domain-riêng đặt ở `apps/<app>/src/common/error-codes.ts`, nhưng **`AppException` constructor chỉ fallback status/message từ `ERROR_CATALOG`** (`libs/common/src/errors/app.exception.ts:25-28`) — không merge với `WMS_ERRORS`. Toàn bộ code lỗi WMS thêm gần đây (`WAREHOUSE_*`, `SUPPLIER_*`, `PO_*`, `GRN_*`) đều đã nằm ở `ERROR_CATALOG`, không phải `WMS_ERRORS`. Code mới đi theo quy ước thực tế đang chạy — đặt cả 3 code sau vào `ERROR_CATALOG`, mục `// ── WMS — Users ──`:

- `USER_NOT_FOUND` — 404, "Không tìm thấy nhân viên"
- `USER_FORBIDDEN_ADMIN_TARGET` — 403, "Không đủ quyền thao tác với tài khoản có vai trò ADMIN"
- `USER_CANNOT_DELETE_SELF` — 403, "Không thể tự xóa tài khoản của chính mình"

Trùng email khi update tái dùng `AUTH_EMAIL_CONFLICT` (cross-cutting, đã có).

### 8. Swagger

- Mọi endpoint có `@Roles` → `@ApiOperation({ summary: '... — [ADMIN, MANAGER]' })` theo `dto-conventions.md`.
- `role`/`status` trong `QueryUsersDto` và mọi field enum trong DTO → `@ApiProperty({ enum: ... })`.

## Ngoài phạm vi (out of scope)

- Không thêm "undelete"/restore user.
- Không đổi `username` qua update.
- Không thêm audit log riêng cho thao tác quản lý user (ngoài `createdBy`/`updatedBy` sẵn có trên schema).
- Không đổi cơ chế `GET /me` / `change-password` (self-service, ở lại `AuthModule`).

## Testing

- Unit test `UsersService`: rule leo thang quyền MANAGER×ADMIN-target, chặn tự xóa, idempotency của lock/unlock trên user đã ở đúng trạng thái.
- E2E (nếu môi trường Mongo/Redis sẵn sàng theo `apps/wms/test/`): CRUD happy path + 403 cases theo bảng rule ở mục 3.
