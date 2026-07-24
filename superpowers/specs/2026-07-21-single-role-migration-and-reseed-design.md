# Chuyển sang single-role (1 account = 1 role) + drop DB + reseed — Design

**Ngày:** 2026-07-21
**App:** `libs/auth`, `apps/wms`, `apps/ecommerce`
**Trạng thái:** Chờ duyệt

## Bối cảnh

Toàn hệ thống hiện mô hình hoá quyền nhân viên/khách hàng bằng `roles: string[]` (multi-role) xuyên suốt: `JwtPayload.roles`, `RolesGuard` (giao mảng), `User.roles` (WMS), `Customer.roles` (Ecommerce). Thực tế:

- **WMS `User`**: mỗi nhân viên chỉ nên có đúng 1 vai trò (`ADMIN`/`MANAGER`/`RECEIVER`/`PICKER`/`PRINTER`/`COUNTER`/`SHIPPER`) — không có ca nghiệp vụ nào cần 1 người vừa `PICKER` vừa `COUNTER`.
- **Ecommerce `Customer.roles`**: hoàn toàn phái sinh, trùng lặp với field `type: 'customer'|'admin'` đã có sẵn (`roles=['customer']` khi `type='customer'`, `roles=[ECOM_MANAGER]` khi `type='admin'`) — không mang thêm thông tin, chỉ là tàn dư của việc dùng chung `RolesGuard`/`JwtPayload` với WMS.

Đồng thời cần drop sạch `wms_db` + `ecom_db` hiện tại (dữ liệu test cũ không còn giá trị) và chạy lại seed WMS cho khớp cấu trúc single-role.

## Mục tiêu

1. Đổi `roles: string[]` → `role: string` (single) xuyên suốt: `libs/auth`, WMS `User`, Ecommerce `Customer`, và điểm dùng còn lại (`SupplierService.changeStatus`).
2. Sửa seed script WMS (`apps/wms/src/seed/seed.ts`) cho khớp field mới, bổ sung `seed_shipper` (role `SHIPPER` hiện thiếu trong seed).
3. Drop `wms_db` + `ecom_db` thật, chạy lại seed WMS sau khi code + test pass.

## Quyết định thiết kế

### 1. `libs/auth` — hợp đồng dùng chung, phải đổi trước tiên

- `JwtPayload.roles?: string[]` → `JwtPayload.role?: string`. Comment cập nhật: field này chứa role duy nhất của user (WMS) hoặc suy từ `type` (Ecommerce).
- `RolesGuard.canActivate`: đọc `req.user?.role` (string, có thể undefined), bypass nếu `role === WmsRole.ADMIN || role === EcomRole.ECOM_MANAGER`, ngược lại `required.includes(role)` (role undefined → không match, guard throw Forbidden — đúng hành vi cũ khi mảng rỗng).
- **KHÔNG đổi** `@Roles(...roles: string[])` decorator — đây là danh sách role được phép truy cập route (whitelist), khái niệm khác với role của user, và 1 route hợp lệ cho nhiều role là bình thường (`@Roles(ADMIN, MANAGER)`).
- `AuthUser = JwtPayload` (type alias) không đổi.

### 2. WMS `User` — schema/DTO/Service/Controller

- `apps/wms/src/users/schemas/user.schema.ts`: `@Prop({ type: [String], enum: WmsRole, default: [] }) roles: string[]` → `@Prop({ type: String, enum: WmsRole, required: true }) role: WmsRole`. Không còn default — role luôn phải được set tường minh lúc tạo (repository sẽ default `RECEIVER` nếu DTO không truyền, xem dưới).
- `UserRepository.create(data: CreateUserInput)`: `CreateUserInput.roles?: string[]` → `role?: WmsRole`; `this.model.create({ ...data, role: data.role ?? WmsRole.RECEIVER })` (thay vì `roles: data.roles ?? [WmsRole.RECEIVER]`).
- `UserRepository.updateRoles(id, roles, updatedBy)` → đổi tên `updateRole(id, role: WmsRole, updatedBy)`, `$set: { role, updatedBy }`.
- `UserRepository.findAll` filter: `if (query.role) filter['roles'] = query.role` → `filter['role'] = query.role` (so trực tiếp, không cần match trong mảng nữa).
- DTO:
  - `CreateUserDto.roles?: string[]` → `role?: WmsRole` (bỏ `@IsArray`/`@ArrayNotEmpty`, giữ `@IsIn(Object.values(WmsRole))`/`@IsOptional()`).
  - `UpdateUserRolesDto` (file `update-user-roles.dto.ts`) → đổi tên class `UpdateUserRoleDto`, field `role!: WmsRole` (bỏ mảng). Đổi tên file thành `update-user-role.dto.ts` cho khớp.
  - `UserResponseDto`/`CreateUserResponseDto` (`user.response.dto.ts`): `@ApiProperty({ enum: WmsRole, isArray: true }) roles!: string[]` → `@ApiProperty({ enum: WmsRole }) role!: string`.
  - `QueryUsersDto`: field `role?: WmsRole` đã sẵn là single — không đổi (đã đúng từ trước, filter dùng `IsEnum` chứ không phải mảng).
- `UsersService`:
  - `Actor.roles: string[]` → `Actor.role: string` (actor luôn là 1 nhân viên với đúng 1 role).
  - `assertManagerCanActOnTarget(actor, targetRole: string)`: `if (actor.role === WmsRole.ADMIN) return; if (targetRole === WmsRole.ADMIN) throw ...`.
  - `create(dto, actor)`: gọi `assertManagerCanActOnTarget(actor, dto.role ?? WmsRole.RECEIVER)` (kiểm tra role đích sẽ được gán, không phải mảng).
  - `update/lock/unlock/resetPassword/remove`: gọi `assertManagerCanActOnTarget(actor, target.role)` (so 1 giá trị).
  - `updateRoles(id, roles, actor)` → đổi tên `updateRole(id, role: WmsRole, actor)`, kiểm tra escalation trên **cả role hiện tại lẫn role mới**: `assertManagerCanActOnTarget(actor, target.role); assertManagerCanActOnTarget(actor, role);` (2 lệnh gọi, vì single-role không còn cách gộp `[...current, ...new]` như bản mảng cũ — phải chặn cả 2 chiều: không cho gỡ role ADMIN của người khác, không cho gán role ADMIN cho ai).
- `UsersController`: route `PATCH /users/:id/roles` → `PATCH /users/:id/role` (số ít, khớp field mới); handler `updateRoles(id, dto: UpdateUserRoleDto, actor)` → gọi `svc.updateRole(id, dto.role, actor)`.
- `AuthService.issueTokens`: `roles: user.roles` (trong `JwtPayload`) → `role: user.role`. `bootstrapAdmin`'s actor giả: `{ sub: '', roles: [WmsRole.ADMIN] }` → `{ sub: '', role: WmsRole.ADMIN }`.
- `apps/wms/src/seed/seed.ts`: `usersService.create(dto, { sub: adminId, roles: [WmsRole.ADMIN] })` → `{ sub: adminId, role: WmsRole.ADMIN }`; `dto.roles = [u.role]` → `dto.role = u.role`. Thêm `{ username: 'seed_shipper', role: WmsRole.SHIPPER, name: 'Seed Shipper' }` vào `SEED_USERS`.

### 3. WMS `SupplierService` — điểm dùng `roles` mảng còn sót ngoài `users/`

- `SupplierController.changeStatus`: `@CurrentUser('roles') roles: string[]` → `@CurrentUser('role') role: string`, truyền `role` xuống service.
- `SupplierService.changeStatus(id, dto, actorId, role: string)`: `!roles.includes(WmsRole.ADMIN)` → `role !== WmsRole.ADMIN`.

### 4. Ecommerce `Customer` — bỏ hẳn field `roles` (phái sinh từ `type`)

- `apps/ecommerce/src/auth/schemas/user.schema.ts`: xoá hẳn `@Prop({ type: [String], default: ['customer'] }) roles: string[]`. Giữ nguyên `type: 'customer' | 'admin'`.
- `AuthService.register`: bỏ `roles: ['customer']` khỏi object truyền vào `userRepo.create`.
- `AuthService.createEcomManager`: bỏ `roles: [EcomRole.ECOM_MANAGER]` khỏi object truyền vào `userRepo.create`.
- `AuthService.issueTokens(user)`: bỏ `roles: user.roles` khỏi `JwtPayload`; thêm `role: user.type === 'admin' ? EcomRole.ECOM_MANAGER : EcomRole.CUSTOMER` (suy từ `type`, không đọc DB field nữa).
- `CustomerResponseDto` (`auth.dto.ts`): xoá field `roles!: string[]` (dòng ~294-296) khỏi response — `type` đã đủ thể hiện.
- `UserRepository` (Ecom) `CreateUserInput`-tương-đương: xoá `roles?: string[]` khỏi interface nếu có khai báo tường minh.

### 5. Drop DB + reseed — thứ tự thực hiện

Thứ tự đã chốt với user (2026-07-21): code xong → xoá DB → chạy seed. Không hỏi lại xác nhận drop ở bước thực thi — nhưng vẫn báo cáo rõ trước khi chạy lệnh drop thật (đây là thao tác không thể hoàn tác) để user có cơ hội chặn nếu môi trường sai (vd nhầm URI production).

1. Code xong tất cả các mục trên, chạy `pnpm build` (3 app) + `pnpm test -- apps/wms apps/ecommerce` (đảm bảo không còn tham chiếu `roles` mảng nào sót — build sẽ tự bắt lỗi type nếu sót).
2. Đọc `WMS_DATABASE_URL`/`ECOM_DATABASE_URL` thật từ `.env` của user (KHÔNG hard-code, không đoán tên DB) — xác nhận đúng là môi trường local/dev trước khi drop.
3. Drop 2 database: `mongosh <uri> --eval 'db.dropDatabase()'` cho `wms_db` và `ecom_db`.
4. Chạy `pnpm seed:wms` (hoặc lệnh tương ứng trong `package.json`) để tạo lại `seed_admin` + 6 seed user role (bao gồm `seed_shipper` mới) + warehouse/item/supplier mẫu.
5. Ecommerce: không có seed script trong phạm vi lần này (đã xác nhận với user) — DB Ecom sẽ trống sau khi drop, user tự tạo dữ liệu qua API khi cần.

## Ngoài phạm vi

- Không viết seed script mới cho Ecommerce.
- Không đổi `@Roles(...)` decorator (vẫn nhận nhiều role — whitelist route, không phải role của user).
- Không thêm khả năng multi-role trở lại dưới bất kỳ hình thức nào (không thêm "role phụ", không thêm bảng phân quyền chi tiết hơn).
- Không đổi cấu trúc `EcomRole`/`WmsRole` enum hiện có (chỉ đổi kiểu field chứa chúng từ mảng sang đơn).
- Không đổi hành vi `RolesGuard` cho phép nhiều role/route (`@Roles(ADMIN, MANAGER)` vẫn hợp lệ).
