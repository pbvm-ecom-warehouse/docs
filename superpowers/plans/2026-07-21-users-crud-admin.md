# User CRUD cho Admin/Manager (WMS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tách quản lý user WMS (list/get/create/update/roles/lock/unlock/reset-password/soft-delete) ra `UsersModule` riêng, mở quyền cho cả ADMIN và MANAGER với rule chặn MANAGER thao tác lên tài khoản có role ADMIN.

**Architecture:** Module mới `apps/wms/src/users/` sở hữu `User`/`UserRefreshToken` schema + `UserRepository` (di chuyển từ `auth/`), `UsersService` (business logic + rule leo thang quyền), `UsersController` (`@Controller('users')`, class-level `@UseGuards(JwtAuthGuard, RolesGuard)` + `@Roles(ADMIN, MANAGER)`). `AuthModule` giữ login/register/refresh/logout/bootstrap-admin/`GET me`/`change-password`, import `UsersModule` để tái dùng `UserRepository`.

**Tech Stack:** NestJS, Mongoose (`@nestjs/mongoose`), `class-validator`/`class-transformer`, `@app/auth` (`WmsRole`, `RolesGuard`, `CurrentUser`), `@app/common` (`AppException`, `OffsetPaginationQuery`, `buildOffsetMeta`, `PaginatedResult`), Jest.

## Global Constraints

- Mã lỗi domain-riêng **PHẢI** đặt vào `ERROR_CATALOG` (`libs/common/src/errors/error-codes.ts`), KHÔNG đặt vào `WMS_ERRORS` (`apps/wms/src/common/error-codes.ts`) — `AppException` chỉ đọc `ERROR_CATALOG` để fallback status/message (xác nhận qua `coding-mistakes-log` 2026-07-02 và toàn bộ code lỗi WMS gần đây: `WAREHOUSE_*`, `SUPPLIER_*`, `PO_*`, `GRN_*`).
- Response DTO: `@Expose()` mọi field trả ra, controller luôn `plainToInstance(Dto, data, { excludeExtraneousValues: true })`. `_id` → `id` qua `@Transform`.
- Mọi service throw lỗi dùng `AppException(code)` — không throw `NotFoundException`/`ForbiddenException` trực tiếp trong service.
- Mọi `@Roles(...)` → `@ApiOperation({ summary: '... — [ROLE1, ROLE2]' })`.
- Mọi field enum trong DTO → `@ApiProperty({ enum: XxxEnum })`.
- Không dùng `any` — kể cả implicit any từ destructuring; `@Transform` callback phải khai type tường minh cho `obj`.
- Không transaction xuyên DB, không đọc chéo DB, không populate xuyên app.
- Comment (nếu cần) viết bằng tiếng Việt, chỉ giải thích *vì sao*, không giải thích *cái gì*.

---

## File Structure

```
apps/wms/src/users/                              (MỚI)
  users.module.ts
  users.controller.ts
  users.service.ts
  users.service.spec.ts
  users.controller.spec.ts
  repositories/
    user.repository.ts                            (di chuyển + mở rộng từ auth/)
    user.repository.spec.ts
  dto/
    create-user.dto.ts                             (di chuyển CreateUserDto, CreateUserResponseDto)
    update-user.dto.ts                              (MỚI)
    update-user-roles.dto.ts                        (di chuyển UpdateUserRolesDto)
    reset-user-password.dto.ts                      (di chuyển ResetUserPasswordDto)
    query-users.dto.ts                              (MỚI)
    user.response.dto.ts                            (di chuyển UserResponseDto)

apps/wms/src/auth/                                (SỬA — bớt trách nhiệm)
  auth.module.ts                                    (import UsersModule, bỏ User/UserRefreshToken registration của User model — giữ UserRefreshToken)
  auth.controller.ts                                (bỏ 5 endpoint users/*, giữ login/google-login/refresh/logout/me/bootstrap-admin/change-password)
  auth.service.ts                                   (bỏ createUser/updateRoles/lockUser/unlockUser/resetTemporaryPassword — dùng UsersService qua DI)
  auth.controller.spec.ts                           (bỏ mock các method đã chuyển)
  dto/auth.dto.ts                                    (bỏ CreateUserDto/UpdateUserRolesDto/ResetUserPasswordDto/UserResponseDto/CreateUserResponseDto — giữ Login/GoogleLogin/Refresh/Logout/ChangePassword/AuthTokenResponseDto)
  repositories/user.repository.ts                   (XÓA — di chuyển sang users/)
  schemas/user.schema.ts                            (XÓA — di chuyển sang users/schemas/, xem Task 1)

apps/wms/src/app.module.ts                         (SỬA — thêm UsersModule)
libs/common/src/errors/error-codes.ts               (SỬA — thêm 3 code USER_*)
```

**Quyết định vị trí schema:** `User`/`UserSchema`/`UserStatus` di chuyển sang `apps/wms/src/users/schemas/user.schema.ts` (module sở hữu entity phải chứa schema, đúng convention `data-and-mongoose.md`: "Mỗi entity = 1 file `apps/<app>/src/<domain>/schemas/<name>.schema.ts`"). `UserRefreshToken` **ở lại** `apps/wms/src/auth/schemas/` vì nó thuộc về phiên đăng nhập (domain của `AuthModule`), không phải quản lý hồ sơ nhân viên.

---

## Task 1: Di chuyển `User` schema sang `users/` module, thêm `USER_*` error codes

**Files:**
- Create: `apps/wms/src/users/schemas/user.schema.ts`
- Modify: `apps/wms/src/auth/schemas/user.schema.ts` (xóa file này sau khi di chuyển xong)
- Modify: `libs/common/src/errors/error-codes.ts`

**Interfaces:**
- Produces: `User` class, `UserSchema`, `UserDocument`, `UserStatus` enum — export từ `apps/wms/src/users/schemas/user.schema.ts`. Field: `username`, `firebaseUid?`, `email?`, `passwordHash` (`select:false`), `name?`, `roles: string[]`, `status: UserStatus`, `warehouseId?: Types.ObjectId`, `mustChangePassword: boolean`, `createdBy?`, `updatedBy?`, `deletedAt?: Date | null`.
- Produces: `ERROR_CATALOG` có thêm 3 key mới: `USER_NOT_FOUND`, `USER_FORBIDDEN_ADMIN_TARGET`, `USER_CANNOT_DELETE_SELF`.

- [ ] **Step 1: Tạo file schema mới tại vị trí `users/`**

Copy nguyên nội dung từ `apps/wms/src/auth/schemas/user.schema.ts` sang path mới (nội dung giữ nguyên 100%, không đổi field nào):

```ts
// apps/wms/src/users/schemas/user.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { WmsRole } from '@app/auth';
import { HydratedDocument, SchemaTypes, Types } from 'mongoose';

/** Trạng thái tài khoản nhân viên. */
export enum UserStatus {
  ACTIVE = 'ACTIVE',
  LOCKED = 'LOCKED',
}

/**
 * Nhân viên WMS — danh bạ nhân viên DUY NHẤT cho cả kho lẫn back-office shop.
 * Nhóm MASTER → audit đầy đủ + soft-delete (deletedAt). collection giữ tên 'users'.
 */
@Schema({ collection: 'users', timestamps: true })
export class User {
  @Prop({ required: true, unique: true })
  username: string;

  @Prop({ unique: true, sparse: true })
  firebaseUid?: string;

  @Prop()
  email?: string;

  // select:false → KHÔNG trả hash ra ngoài theo mặc định; login phải .select('+passwordHash').
  @Prop({ required: true, select: false })
  passwordHash: string;

  @Prop()
  name?: string;

  @Prop({ type: [String], enum: WmsRole, default: [] })
  roles: string[];

  @Prop({ enum: UserStatus, default: UserStatus.ACTIVE })
  status: UserStatus;

  @Prop({ type: SchemaTypes.ObjectId })
  warehouseId?: Types.ObjectId; // kho mặc định (ref scalar, không populate xuyên app)

  @Prop({ default: false })
  mustChangePassword: boolean;

  // ---- audit (master) ----
  @Prop({ type: SchemaTypes.ObjectId })
  createdBy?: Types.ObjectId;

  @Prop({ type: SchemaTypes.ObjectId })
  updatedBy?: Types.ObjectId;

  @Prop({ type: Date, default: null })
  deletedAt?: Date | null; // soft-delete: query luôn lọc deletedAt: null
}

export type UserDocument = HydratedDocument<User>;
export const UserSchema = SchemaFactory.createForClass(User);
```

- [ ] **Step 2: Xóa file schema cũ**

```bash
rm apps/wms/src/auth/schemas/user.schema.ts
```

- [ ] **Step 3: Thêm 3 error code mới vào `ERROR_CATALOG`**

Trong `libs/common/src/errors/error-codes.ts`, thêm block mới ngay trước dòng `} as const;` (sau block `GRN_*`):

```ts
  // ── WMS — Users ─────────────────────────────────────────────────────────
  USER_NOT_FOUND: {
    status: HttpStatus.NOT_FOUND,
    message: 'Không tìm thấy nhân viên',
  },
  USER_FORBIDDEN_ADMIN_TARGET: {
    status: HttpStatus.FORBIDDEN,
    message: 'Không đủ quyền thao tác với tài khoản có vai trò ADMIN',
  },
  USER_CANNOT_DELETE_SELF: {
    status: HttpStatus.FORBIDDEN,
    message: 'Không thể tự xóa tài khoản của chính mình',
  },
```

- [ ] **Step 4: Build kiểm tra chưa có gì tham chiếu sai (dự kiến FAIL vì auth.module.ts/user.repository.ts vẫn import path cũ)**

Run: `pnpm build wms 2>&1 | head -40`
Expected: lỗi `Cannot find module './schemas/user.schema'` ở `apps/wms/src/auth/repositories/user.repository.ts` và `apps/wms/src/auth/auth.module.ts` và `apps/wms/src/auth/auth.service.ts` — đúng như dự kiến, sẽ sửa ở Task 2.

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/users/schemas/user.schema.ts libs/common/src/errors/error-codes.ts
git rm apps/wms/src/auth/schemas/user.schema.ts
git commit -m "feat(wms): di chuyển User schema sang users module, thêm USER_* error codes"
```

---

## Task 2: Di chuyển `UserRepository` sang `users/`, mở rộng `findAll` + `softDelete`

**Files:**
- Create: `apps/wms/src/users/repositories/user.repository.ts`
- Create: `apps/wms/src/users/repositories/user.repository.spec.ts`
- Modify: `apps/wms/src/auth/repositories/user.repository.ts` (xóa sau khi di chuyển)

**Interfaces:**
- Consumes: `User`, `UserDocument`, `UserStatus` từ `../schemas/user.schema` (Task 1).
- Produces: `UserRepository` class với method:
  - `findActiveByUsername(username: string, includePasswordHash?: boolean)`
  - `findActiveByEmail(email: string, includePasswordHash?: boolean)`
  - `findByFirebaseUid(firebaseUid: string, includePasswordHash?: boolean)`
  - `linkFirebaseUid(id, firebaseUid: string)`
  - `findActiveById(id: string | Types.ObjectId)`
  - `findByIdWithPassword(id: string | Types.ObjectId)`
  - `countAll()`
  - `create(data: CreateUserInput)`
  - `updateRoles(id, roles: string[], updatedBy: Types.ObjectId)`
  - `updateStatus(id, status: UserStatus, updatedBy: Types.ObjectId)`
  - `updatePassword(id, passwordHash: string, mustChangePassword: boolean, updatedBy?: Types.ObjectId)`
  - **MỚI** `findAll(query: { page: number; limit: number; role?: string; status?: UserStatus; warehouseId?: string; search?: string }): Promise<{ items: UserDocument[]; total: number }>`
  - **MỚI** `findByIdIncludingRoles(id: string | Types.ObjectId): Promise<UserDocument | null>` — alias rõ nghĩa của `findActiveById`, dùng khi cần đọc `roles` để kiểm tra rule leo thang quyền trước khi update (thực chất gọi lại `findActiveById`, không thêm logic — dùng `findActiveById` trực tiếp, KHÔNG cần alias, xem Step 3).
  - **MỚI** `updateProfile(id, data: { name?: string; email?: string; warehouseId?: string }, updatedBy: Types.ObjectId): Promise<UserDocument | null>`
  - **MỚI** `softDelete(id: string | Types.ObjectId, updatedBy: Types.ObjectId): Promise<boolean>`
  - Export interface `CreateUserInput` (giữ nguyên từ bản cũ).

- [ ] **Step 1: Viết file repository mới (copy nguyên các method cũ, sửa import path, thêm 3 method mới)**

```ts
// apps/wms/src/users/repositories/user.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { WmsRole } from '@app/auth';
import { Model, Types } from 'mongoose';
import { UserStatus, User, UserDocument } from '../schemas/user.schema';

export interface CreateUserInput {
  username: string;
  firebaseUid?: string;
  passwordHash: string;
  email?: string;
  name?: string;
  roles?: string[];
  mustChangePassword?: boolean;
  createdBy?: Types.ObjectId;
}

export interface FindAllUsersQuery {
  page: number;
  limit: number;
  role?: string;
  status?: UserStatus;
  warehouseId?: string;
  search?: string;
}

export interface UpdateUserProfileInput {
  name?: string;
  email?: string;
  warehouseId?: string;
}

const SOFT_DELETE_FILTER = { deletedAt: null } as const;

@Injectable()
export class UserRepository {
  constructor(@InjectModel(User.name) private readonly model: Model<User>) {}

  findActiveByUsername(username: string, includePasswordHash = false) {
    const q = this.model.findOne({
      username,
      ...SOFT_DELETE_FILTER,
      status: UserStatus.ACTIVE,
    });
    return (includePasswordHash ? q.select('+passwordHash') : q).exec();
  }

  findActiveByEmail(email: string, includePasswordHash = false) {
    const q = this.model.findOne({
      email,
      ...SOFT_DELETE_FILTER,
      status: UserStatus.ACTIVE,
    });
    return (includePasswordHash ? q.select('+passwordHash') : q).exec();
  }

  findByFirebaseUid(firebaseUid: string, includePasswordHash = false) {
    const q = this.model.findOne({ firebaseUid, ...SOFT_DELETE_FILTER });
    return (includePasswordHash ? q.select('+passwordHash') : q).exec();
  }

  linkFirebaseUid(id: string | Types.ObjectId, firebaseUid: string) {
    return this.model
      .findOneAndUpdate(
        { _id: id, ...SOFT_DELETE_FILTER },
        { $set: { firebaseUid } },
        { new: true },
      )
      .exec();
  }

  findActiveById(id: string | Types.ObjectId) {
    return this.model.findOne({ _id: id, ...SOFT_DELETE_FILTER }).exec();
  }

  findByIdWithPassword(id: string | Types.ObjectId) {
    return this.model
      .findOne({ _id: id, ...SOFT_DELETE_FILTER, status: UserStatus.ACTIVE })
      .select('+passwordHash')
      .exec();
  }

  countAll() {
    return this.model.estimatedDocumentCount().exec();
  }

  create(data: CreateUserInput) {
    return this.model.create({
      ...data,
      roles: data.roles ?? [WmsRole.RECEIVER],
    });
  }

  async findAll(
    query: FindAllUsersQuery,
  ): Promise<{ items: UserDocument[]; total: number }> {
    const filter: Record<string, unknown> = { ...SOFT_DELETE_FILTER };
    if (query.role) filter['roles'] = query.role;
    if (query.status) filter['status'] = query.status;
    if (query.warehouseId) filter['warehouseId'] = query.warehouseId;
    if (query.search) {
      filter['$or'] = [
        { username: { $regex: query.search, $options: 'i' } },
        { name: { $regex: query.search, $options: 'i' } },
        { email: { $regex: query.search, $options: 'i' } },
      ];
    }

    const [items, total] = await Promise.all([
      this.model
        .find(filter)
        .sort({ createdAt: -1 })
        .skip((query.page - 1) * query.limit)
        .limit(query.limit)
        .exec(),
      this.model.countDocuments(filter).exec(),
    ]);
    return { items, total };
  }

  updateRoles(
    id: string | Types.ObjectId,
    roles: string[],
    updatedBy: Types.ObjectId,
  ) {
    return this.model
      .findOneAndUpdate(
        { _id: id, ...SOFT_DELETE_FILTER },
        { $set: { roles, updatedBy } },
        { new: true },
      )
      .exec();
  }

  updateStatus(
    id: string | Types.ObjectId,
    status: UserStatus,
    updatedBy: Types.ObjectId,
  ) {
    return this.model
      .findOneAndUpdate(
        { _id: id, ...SOFT_DELETE_FILTER },
        { $set: { status, updatedBy } },
        { new: true },
      )
      .exec();
  }

  updatePassword(
    id: string | Types.ObjectId,
    passwordHash: string,
    mustChangePassword: boolean,
    updatedBy?: Types.ObjectId,
  ) {
    return this.model
      .findOneAndUpdate(
        { _id: id, ...SOFT_DELETE_FILTER, status: UserStatus.ACTIVE },
        {
          $set: {
            passwordHash,
            mustChangePassword,
            ...(updatedBy ? { updatedBy } : {}),
          },
        },
        { new: true },
      )
      .exec();
  }

  updateProfile(
    id: string | Types.ObjectId,
    data: UpdateUserProfileInput,
    updatedBy: Types.ObjectId,
  ) {
    return this.model
      .findOneAndUpdate(
        { _id: id, ...SOFT_DELETE_FILTER },
        { $set: { ...data, updatedBy } },
        { new: true },
      )
      .exec();
  }

  async softDelete(
    id: string | Types.ObjectId,
    updatedBy: Types.ObjectId,
  ): Promise<boolean> {
    const res = await this.model
      .updateOne(
        { _id: id, ...SOFT_DELETE_FILTER },
        { $set: { deletedAt: new Date(), updatedBy } },
      )
      .exec();
    return res.modifiedCount > 0;
  }
}
```

- [ ] **Step 2: Xóa file repository cũ**

```bash
rm apps/wms/src/auth/repositories/user.repository.ts
```

- [ ] **Step 3: Viết test cho 3 method mới (`findAll` search filter, `softDelete`)**

```ts
// apps/wms/src/users/repositories/user.repository.spec.ts
import { UserRepository } from './user.repository';
import { UserStatus } from '../schemas/user.schema';

const makeModel = () => {
  const exec = jest.fn();
  const chain = {
    sort: jest.fn().mockReturnThis(),
    skip: jest.fn().mockReturnThis(),
    limit: jest.fn().mockReturnThis(),
    exec,
  };
  return {
    find: jest.fn().mockReturnValue(chain),
    countDocuments: jest.fn().mockReturnValue({ exec: jest.fn() }),
    updateOne: jest.fn().mockReturnValue({ exec: jest.fn() }),
    __chain: chain,
  };
};

describe('UserRepository', () => {
  describe('findAll', () => {
    it('build $or filter khi có search', async () => {
      const model = makeModel();
      model.__chain.exec.mockResolvedValue([]);
      (model.countDocuments({}).exec as jest.Mock).mockResolvedValue(0);
      const repo = new UserRepository(model as never);

      await repo.findAll({ page: 1, limit: 20, search: 'phuong' });

      expect(model.find).toHaveBeenCalledWith(
        expect.objectContaining({
          deletedAt: null,
          $or: [
            { username: { $regex: 'phuong', $options: 'i' } },
            { name: { $regex: 'phuong', $options: 'i' } },
            { email: { $regex: 'phuong', $options: 'i' } },
          ],
        }),
      );
    });

    it('filter theo role/status/warehouseId khi có truyền', async () => {
      const model = makeModel();
      model.__chain.exec.mockResolvedValue([]);
      (model.countDocuments({}).exec as jest.Mock).mockResolvedValue(0);
      const repo = new UserRepository(model as never);

      await repo.findAll({
        page: 2,
        limit: 10,
        role: 'PICKER',
        status: UserStatus.LOCKED,
        warehouseId: 'wh1',
      });

      expect(model.find).toHaveBeenCalledWith(
        expect.objectContaining({
          deletedAt: null,
          roles: 'PICKER',
          status: UserStatus.LOCKED,
          warehouseId: 'wh1',
        }),
      );
      expect(model.__chain.skip).toHaveBeenCalledWith(10); // (page-1)*limit
      expect(model.__chain.limit).toHaveBeenCalledWith(10);
    });
  });

  describe('softDelete', () => {
    it('trả true khi modifiedCount > 0', async () => {
      const model = makeModel();
      (model.updateOne({}, {}).exec as jest.Mock).mockResolvedValue({
        modifiedCount: 1,
      });
      const repo = new UserRepository(model as never);

      await expect(
        repo.softDelete('u1', 'actor1' as never),
      ).resolves.toBe(true);
    });

    it('trả false khi không tìm thấy user để xóa', async () => {
      const model = makeModel();
      (model.updateOne({}, {}).exec as jest.Mock).mockResolvedValue({
        modifiedCount: 0,
      });
      const repo = new UserRepository(model as never);

      await expect(
        repo.softDelete('missing', 'actor1' as never),
      ).resolves.toBe(false);
    });
  });
});
```

- [ ] **Step 4: Chạy test**

Run: `pnpm test -- apps/wms/src/users/repositories/user.repository.spec.ts`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/users/repositories/user.repository.ts apps/wms/src/users/repositories/user.repository.spec.ts
git rm apps/wms/src/auth/repositories/user.repository.ts
git commit -m "feat(wms): di chuyển UserRepository sang users module, thêm findAll/updateProfile/softDelete"
```

---

## Task 3: DTOs cho `UsersModule`

**Files:**
- Create: `apps/wms/src/users/dto/user.response.dto.ts`
- Create: `apps/wms/src/users/dto/create-user.dto.ts`
- Create: `apps/wms/src/users/dto/update-user.dto.ts`
- Create: `apps/wms/src/users/dto/update-user-roles.dto.ts`
- Create: `apps/wms/src/users/dto/reset-user-password.dto.ts`
- Create: `apps/wms/src/users/dto/query-users.dto.ts`

**Interfaces:**
- Consumes: `WmsRole` từ `@app/auth`; `OffsetPaginationQuery` từ `@app/common`; `UserStatus` từ `../schemas/user.schema` (Task 1).
- Produces: `UserResponseDto`, `CreateUserResponseDto`, `CreateUserDto`, `UpdateUserDto`, `UpdateUserRolesDto`, `ResetUserPasswordDto`, `QueryUsersDto` — dùng ở Task 4 (service) và Task 5 (controller).

- [ ] **Step 1: `user.response.dto.ts` (di chuyển `UserResponseDto` + `CreateUserResponseDto` nguyên trạng từ `auth/dto/auth.dto.ts`)**

```ts
// apps/wms/src/users/dto/user.response.dto.ts
import { Expose, Transform } from 'class-transformer';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { WmsRole } from '@app/auth';
import { Types } from 'mongoose';

/** Response cho GET /me, GET /users, GET /users/:id, PATCH /users/:id(/roles), POST /users/:id/lock|unlock. */
export class UserResponseDto {
  @Expose()
  @Transform(
    ({ obj }: { obj: { _id?: Types.ObjectId | { toString(): string } } }) =>
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
  @ApiProperty({ enum: WmsRole, isArray: true })
  roles!: string[];

  @Expose()
  @ApiProperty({ enum: ['ACTIVE', 'LOCKED'] })
  status!: string;

  @Expose()
  @ApiProperty()
  mustChangePassword!: boolean;

  @Expose()
  @Transform(
    ({
      obj,
    }: {
      obj: { warehouseId?: Types.ObjectId | { toString(): string } | null };
    }) => obj.warehouseId?.toString() ?? undefined,
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

/** Response cho POST /users và POST /auth/bootstrap-admin. */
export class CreateUserResponseDto {
  @Expose()
  @Transform(
    ({ obj }: { obj: { _id?: Types.ObjectId | { toString(): string } } }) =>
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
  @ApiProperty({ enum: WmsRole, isArray: true })
  roles!: string[];

  @Expose()
  @ApiProperty()
  mustChangePassword!: boolean;
}
```

- [ ] **Step 2: `create-user.dto.ts` (di chuyển `CreateUserDto` nguyên trạng)**

```ts
// apps/wms/src/users/dto/create-user.dto.ts
import {
  ArrayNotEmpty,
  IsArray,
  IsEmail,
  IsIn,
  IsOptional,
  IsString,
  MinLength,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { WmsRole } from '@app/auth';

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
```

- [ ] **Step 3: `update-user.dto.ts` (MỚI — name/email/warehouseId, không username/roles/status)**

```ts
// apps/wms/src/users/dto/update-user.dto.ts
import { IsEmail, IsMongoId, IsOptional, IsString } from 'class-validator';
import { ApiPropertyOptional } from '@nestjs/swagger';

export class UpdateUserDto {
  @ApiPropertyOptional({ example: 'Nguyễn Văn A' })
  @IsOptional()
  @IsString()
  name?: string;

  @ApiPropertyOptional({ example: 'staff@example.com' })
  @IsOptional()
  @IsEmail()
  email?: string;

  @ApiPropertyOptional({ description: 'Mongo ObjectId của kho mặc định' })
  @IsOptional()
  @IsMongoId()
  warehouseId?: string;
}
```

- [ ] **Step 4: `update-user-roles.dto.ts` (di chuyển `UpdateUserRolesDto` nguyên trạng)**

```ts
// apps/wms/src/users/dto/update-user-roles.dto.ts
import { ArrayNotEmpty, IsArray, IsIn } from 'class-validator';
import { ApiProperty } from '@nestjs/swagger';
import { WmsRole } from '@app/auth';

export class UpdateUserRolesDto {
  @ApiProperty({ example: [WmsRole.RECEIVER], enum: WmsRole, isArray: true })
  @IsArray()
  @ArrayNotEmpty()
  @IsIn(Object.values(WmsRole), { each: true })
  roles!: string[];
}
```

- [ ] **Step 5: `reset-user-password.dto.ts` (di chuyển `ResetUserPasswordDto` nguyên trạng)**

```ts
// apps/wms/src/users/dto/reset-user-password.dto.ts
import { IsString, MinLength } from 'class-validator';
import { ApiProperty } from '@nestjs/swagger';

export class ResetUserPasswordDto {
  @ApiProperty({ example: 'TempP@ssw0rd123!', minLength: 8 })
  @IsString()
  @MinLength(8)
  temporaryPassword!: string;
}
```

- [ ] **Step 6: `query-users.dto.ts` (MỚI — extends OffsetPaginationQuery)**

```ts
// apps/wms/src/users/dto/query-users.dto.ts
import { IsEnum, IsMongoId, IsOptional, IsString } from 'class-validator';
import { ApiPropertyOptional } from '@nestjs/swagger';
import { OffsetPaginationQuery } from '@app/common';
import { WmsRole } from '@app/auth';
import { UserStatus } from '../schemas/user.schema';

export class QueryUsersDto extends OffsetPaginationQuery {
  @ApiPropertyOptional({ enum: WmsRole })
  @IsOptional()
  @IsEnum(WmsRole)
  role?: WmsRole;

  @ApiPropertyOptional({ enum: UserStatus })
  @IsOptional()
  @IsEnum(UserStatus)
  status?: UserStatus;

  @ApiPropertyOptional({ description: 'Mongo ObjectId của kho' })
  @IsOptional()
  @IsMongoId()
  warehouseId?: string;

  @ApiPropertyOptional({ description: 'Tìm theo username, name hoặc email' })
  @IsOptional()
  @IsString()
  search?: string;
}
```

- [ ] **Step 7: Build kiểm tra DTO tự-đứng-độc-lập biên dịch được (chưa có consumer nên chỉ kiểm tra TS syntax)**

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json 2>&1 | grep "users/dto" || echo "no errors in users/dto"`
Expected: `no errors in users/dto`

- [ ] **Step 8: Commit**

```bash
git add apps/wms/src/users/dto/
git commit -m "feat(wms): thêm DTO cho users module (create/update/roles/reset-password/query/response)"
```

---

## Task 4: `UsersService` — business logic + rule chặn leo thang quyền

**Files:**
- Create: `apps/wms/src/users/users.service.ts`
- Create: `apps/wms/src/users/users.service.spec.ts`

**Interfaces:**
- Consumes: `UserRepository` (Task 2) — `findAll`, `findActiveById`, `create`, `updateRoles`, `updateStatus`, `updateProfile`, `softDelete`, `countAll`; `CreateUserInput` type. `UserRefreshTokenRepository.revokeAllForUser(userId)` từ `apps/wms/src/auth/repositories/user-refresh-token.repository.ts` (không đổi, vẫn ở `auth/`, import xuyên module qua export của `AuthModule`? — **KHÔNG**: `UsersService` không cần biết token, việc revoke token khi lock/reset-password thuộc về `AuthModule`/login concerns. Quyết định: `UsersService.lockUser`/`resetPassword` chỉ đổi status/password, **không** revoke token — việc revoke chuyển thành trách nhiệm gọi thêm ở nơi khác. Xem Step 2 ghi chú rõ lý do và cách xử lý thực tế bên dưới).
- Produces: `UsersService` với method:
  - `list(query: QueryUsersDto): Promise<{ items: UserDocument[]; total: number }>`
  - `getById(id: string): Promise<UserDocument>` — throw `USER_NOT_FOUND`
  - `create(dto: CreateUserDto, actor: { sub: string; roles: string[] }): Promise<UserDocument>`
  - `update(id: string, dto: UpdateUserDto, actor: { sub: string; roles: string[] }): Promise<UserDocument>`
  - `updateRoles(id: string, roles: string[], actor: { sub: string; roles: string[] }): Promise<UserDocument>`
  - `lock(id: string, actor: { sub: string; roles: string[] }): Promise<UserDocument>`
  - `unlock(id: string, actor: { sub: string; roles: string[] }): Promise<UserDocument>`
  - `resetPassword(id: string, temporaryPassword: string, actor: { sub: string; roles: string[] }): Promise<{ success: true; mustChangePassword: true }>`
  - `remove(id: string, actor: { sub: string; roles: string[] }): Promise<void>`
  - Private helper `assertManagerCanActOnTarget(actor, targetRolesBeforeAndAfter: string[])` — throw `USER_FORBIDDEN_ADMIN_TARGET` nếu actor không có role `ADMIN` và (target hiện có role `ADMIN` HOẶC roles mới muốn gán chứa `ADMIN`).

**Quyết định về revoke refresh-token khi lock/reset-password:** hành vi cũ trong `AuthService.lockUser`/`resetTemporaryPassword` có gọi `refreshRepo.revokeAllForUser`. Để giữ đúng hành vi bảo mật này sau khi tách module, `UsersModule` import `UserRefreshTokenRepository` làm provider bổ sung (không cần cả `AuthModule`, tránh vòng phụ thuộc `AuthModule → UsersModule → AuthModule`). `UserRefreshTokenRepository` không có business logic đặc thù của `AuthService`, chỉ là data-access, nên inject thẳng an toàn.

- [ ] **Step 1: Viết file service**

```ts
// apps/wms/src/users/users.service.ts
import { Injectable } from '@nestjs/common';
import { AppException } from '@app/common';
import { WmsRole } from '@app/auth';
import * as bcrypt from 'bcryptjs';
import { Types } from 'mongoose';
import { UserRefreshTokenRepository } from '../auth/repositories/user-refresh-token.repository';
import { CreateUserDto } from './dto/create-user.dto';
import { UpdateUserDto } from './dto/update-user.dto';
import { QueryUsersDto } from './dto/query-users.dto';
import { UserRepository } from './repositories/user.repository';
import { UserStatus, UserDocument } from './schemas/user.schema';

const BCRYPT_ROUNDS = 12;

export interface Actor {
  sub: string;
  roles: string[];
}

@Injectable()
export class UsersService {
  constructor(
    private readonly userRepo: UserRepository,
    private readonly refreshRepo: UserRefreshTokenRepository,
  ) {}

  private objectId(id: string) {
    if (!Types.ObjectId.isValid(id)) throw new AppException('USER_NOT_FOUND');
    return new Types.ObjectId(id);
  }

  /**
   * MANAGER không được tạo/sửa tài khoản ADMIN (chống leo thang quyền).
   * ADMIN luôn qua được — hàm chỉ gọi khi actor KHÔNG có role ADMIN.
   */
  private assertManagerCanActOnTarget(
    actor: Actor,
    targetRolesBeforeAndAfter: string[],
  ): void {
    if (actor.roles.includes(WmsRole.ADMIN)) return;
    if (targetRolesBeforeAndAfter.includes(WmsRole.ADMIN)) {
      throw new AppException('USER_FORBIDDEN_ADMIN_TARGET');
    }
  }

  async list(
    query: QueryUsersDto,
  ): Promise<{ items: UserDocument[]; total: number }> {
    return this.userRepo.findAll({
      page: query.page,
      limit: query.limit,
      role: query.role,
      status: query.status,
      warehouseId: query.warehouseId,
      search: query.search,
    });
  }

  async getById(id: string): Promise<UserDocument> {
    const user = await this.userRepo.findActiveById(this.objectId(id));
    if (!user) throw new AppException('USER_NOT_FOUND');
    return user;
  }

  async create(dto: CreateUserDto, actor: Actor): Promise<UserDocument> {
    this.assertManagerCanActOnTarget(actor, dto.roles ?? []);
    const passwordHash = await bcrypt.hash(dto.password, BCRYPT_ROUNDS);
    return this.userRepo.create({
      username: dto.username,
      email: dto.email,
      name: dto.name,
      roles: dto.roles ?? [],
      passwordHash,
      mustChangePassword: true,
      createdBy: this.objectId(actor.sub),
    });
  }

  async update(
    id: string,
    dto: UpdateUserDto,
    actor: Actor,
  ): Promise<UserDocument> {
    const target = await this.getById(id);
    this.assertManagerCanActOnTarget(actor, target.roles);
    const updated = await this.userRepo.updateProfile(
      target._id,
      dto,
      this.objectId(actor.sub),
    );
    if (!updated) throw new AppException('USER_NOT_FOUND');
    return updated;
  }

  async updateRoles(
    id: string,
    roles: string[],
    actor: Actor,
  ): Promise<UserDocument> {
    const target = await this.getById(id);
    this.assertManagerCanActOnTarget(actor, [...target.roles, ...roles]);
    const updated = await this.userRepo.updateRoles(
      target._id,
      roles,
      this.objectId(actor.sub),
    );
    if (!updated) throw new AppException('USER_NOT_FOUND');
    return updated;
  }

  async lock(id: string, actor: Actor): Promise<UserDocument> {
    const target = await this.getById(id);
    this.assertManagerCanActOnTarget(actor, target.roles);
    const updated = await this.userRepo.updateStatus(
      target._id,
      UserStatus.LOCKED,
      this.objectId(actor.sub),
    );
    if (!updated) throw new AppException('USER_NOT_FOUND');
    await this.refreshRepo.revokeAllForUser(updated._id);
    return updated;
  }

  async unlock(id: string, actor: Actor): Promise<UserDocument> {
    const target = await this.getById(id);
    this.assertManagerCanActOnTarget(actor, target.roles);
    const updated = await this.userRepo.updateStatus(
      target._id,
      UserStatus.ACTIVE,
      this.objectId(actor.sub),
    );
    if (!updated) throw new AppException('USER_NOT_FOUND');
    return updated;
  }

  async resetPassword(
    id: string,
    temporaryPassword: string,
    actor: Actor,
  ): Promise<{ success: true; mustChangePassword: true }> {
    const target = await this.getById(id);
    this.assertManagerCanActOnTarget(actor, target.roles);
    const passwordHash = await bcrypt.hash(temporaryPassword, BCRYPT_ROUNDS);
    const updated = await this.userRepo.updatePassword(
      target._id,
      passwordHash,
      true,
      this.objectId(actor.sub),
    );
    if (!updated) throw new AppException('USER_NOT_FOUND');
    await this.refreshRepo.revokeAllForUser(updated._id);
    return { success: true, mustChangePassword: true };
  }

  async remove(id: string, actor: Actor): Promise<void> {
    if (id === actor.sub) {
      throw new AppException('USER_CANNOT_DELETE_SELF');
    }
    const target = await this.getById(id);
    this.assertManagerCanActOnTarget(actor, target.roles);
    const deleted = await this.userRepo.softDelete(
      target._id,
      this.objectId(actor.sub),
    );
    if (!deleted) throw new AppException('USER_NOT_FOUND');
  }
}
```

- [ ] **Step 2: Viết test cho rule leo thang quyền + self-delete (phần quan trọng nhất, viết trước implementation nếu theo TDD nghiêm ngặt — ở đây service đã viết ở Step 1 cho rõ luồng, nay verify bằng test)**

```ts
// apps/wms/src/users/users.service.spec.ts
import { UsersService } from './users.service';
import { UserStatus } from './schemas/user.schema';

const makeUserRepo = () => ({
  findAll: jest.fn(),
  findActiveById: jest.fn(),
  create: jest.fn(),
  updateProfile: jest.fn(),
  updateRoles: jest.fn(),
  updateStatus: jest.fn(),
  updatePassword: jest.fn(),
  softDelete: jest.fn(),
});

const makeRefreshRepo = () => ({
  revokeAllForUser: jest.fn(),
});

const adminActor = { sub: 'admin1', roles: ['ADMIN'] };
const managerActor = { sub: 'mgr1', roles: ['MANAGER'] };

describe('UsersService', () => {
  let svc: UsersService;
  let userRepo: ReturnType<typeof makeUserRepo>;
  let refreshRepo: ReturnType<typeof makeRefreshRepo>;

  beforeEach(() => {
    userRepo = makeUserRepo();
    refreshRepo = makeRefreshRepo();
    svc = new UsersService(userRepo as never, refreshRepo as never);
  });

  describe('create — rule leo thang quyền', () => {
    it('MANAGER tạo user với roles chứa ADMIN → throw USER_FORBIDDEN_ADMIN_TARGET', async () => {
      await expect(
        svc.create(
          { username: 'x', password: 'p', roles: ['ADMIN'] } as never,
          managerActor,
        ),
      ).rejects.toMatchObject({ code: 'USER_FORBIDDEN_ADMIN_TARGET' });
      expect(userRepo.create).not.toHaveBeenCalled();
    });

    it('MANAGER tạo user role thường → OK', async () => {
      userRepo.create.mockResolvedValue({ _id: 'u1' });
      await expect(
        svc.create(
          { username: 'x', password: 'p', roles: ['PICKER'] } as never,
          managerActor,
        ),
      ).resolves.toMatchObject({ _id: 'u1' });
    });

    it('ADMIN tạo user role ADMIN → OK', async () => {
      userRepo.create.mockResolvedValue({ _id: 'u1' });
      await expect(
        svc.create(
          { username: 'x', password: 'p', roles: ['ADMIN'] } as never,
          adminActor,
        ),
      ).resolves.toMatchObject({ _id: 'u1' });
    });
  });

  describe('update/lock/unlock/resetPassword — chặn MANAGER thao tác target ADMIN', () => {
    const adminTarget = {
      _id: 'target1',
      roles: ['ADMIN'],
      username: 'admin2',
    };

    it('update: MANAGER sửa user hiện có role ADMIN → throw', async () => {
      userRepo.findActiveById.mockResolvedValue(adminTarget);
      await expect(
        svc.update('target1', { name: 'x' }, managerActor),
      ).rejects.toMatchObject({ code: 'USER_FORBIDDEN_ADMIN_TARGET' });
      expect(userRepo.updateProfile).not.toHaveBeenCalled();
    });

    it('lock: MANAGER khóa user ADMIN → throw', async () => {
      userRepo.findActiveById.mockResolvedValue(adminTarget);
      await expect(svc.lock('target1', managerActor)).rejects.toMatchObject({
        code: 'USER_FORBIDDEN_ADMIN_TARGET',
      });
      expect(userRepo.updateStatus).not.toHaveBeenCalled();
    });

    it('resetPassword: MANAGER reset password user ADMIN → throw', async () => {
      userRepo.findActiveById.mockResolvedValue(adminTarget);
      await expect(
        svc.resetPassword('target1', 'TempP@ss123!', managerActor),
      ).rejects.toMatchObject({ code: 'USER_FORBIDDEN_ADMIN_TARGET' });
    });

    it('ADMIN khóa user ADMIN khác → OK, revoke token', async () => {
      userRepo.findActiveById.mockResolvedValue(adminTarget);
      userRepo.updateStatus.mockResolvedValue({
        _id: 'target1',
        status: UserStatus.LOCKED,
      });
      await svc.lock('target1', adminActor);
      expect(refreshRepo.revokeAllForUser).toHaveBeenCalledWith('target1');
    });
  });

  describe('updateRoles — chặn cả gán mới lẫn target hiện có ADMIN', () => {
    it('MANAGER gán role ADMIN cho user thường → throw', async () => {
      userRepo.findActiveById.mockResolvedValue({
        _id: 'u1',
        roles: ['PICKER'],
      });
      await expect(
        svc.updateRoles('u1', ['ADMIN'], managerActor),
      ).rejects.toMatchObject({ code: 'USER_FORBIDDEN_ADMIN_TARGET' });
    });
  });

  describe('remove', () => {
    it('tự xóa chính mình → throw USER_CANNOT_DELETE_SELF, không query DB', async () => {
      await expect(
        svc.remove('admin1', adminActor),
      ).rejects.toMatchObject({ code: 'USER_CANNOT_DELETE_SELF' });
      expect(userRepo.findActiveById).not.toHaveBeenCalled();
    });

    it('MANAGER xóa user ADMIN → throw USER_FORBIDDEN_ADMIN_TARGET', async () => {
      userRepo.findActiveById.mockResolvedValue({
        _id: 'target1',
        roles: ['ADMIN'],
      });
      await expect(
        svc.remove('target1', managerActor),
      ).rejects.toMatchObject({ code: 'USER_FORBIDDEN_ADMIN_TARGET' });
      expect(userRepo.softDelete).not.toHaveBeenCalled();
    });

    it('xóa hợp lệ → gọi softDelete', async () => {
      userRepo.findActiveById.mockResolvedValue({
        _id: 'target1',
        roles: ['PICKER'],
      });
      userRepo.softDelete.mockResolvedValue(true);
      await svc.remove('target1', managerActor);
      expect(userRepo.softDelete).toHaveBeenCalledWith(
        'target1',
        expect.anything(),
      );
    });
  });

  describe('getById', () => {
    it('throw USER_NOT_FOUND khi không tìm thấy', async () => {
      userRepo.findActiveById.mockResolvedValue(null);
      await expect(svc.getById('missing')).rejects.toMatchObject({
        code: 'USER_NOT_FOUND',
      });
    });
  });
});
```

- [ ] **Step 3: Chạy test**

Run: `pnpm test -- apps/wms/src/users/users.service.spec.ts`
Expected: PASS (toàn bộ test case ở Step 2)

- [ ] **Step 4: Commit**

```bash
git add apps/wms/src/users/users.service.ts apps/wms/src/users/users.service.spec.ts
git commit -m "feat(wms): thêm UsersService với rule chặn MANAGER thao tác tài khoản ADMIN"
```

---

## Task 5: `UsersController` + `UsersModule`

**Files:**
- Create: `apps/wms/src/users/users.controller.ts`
- Create: `apps/wms/src/users/users.controller.spec.ts`
- Create: `apps/wms/src/users/users.module.ts`

**Interfaces:**
- Consumes: `UsersService` (Task 4); DTOs (Task 3); `JwtAuthGuard`, `RolesGuard`, `Roles`, `CurrentUser`, `WmsRole` từ `@app/auth`; `buildOffsetMeta`, `PaginatedResult` từ `@app/common`.
- Produces: `UsersController` (`@Controller('users')`), `UsersModule` (exports `UsersService`, `UserRepository`) — dùng ở Task 6 (`AuthModule` import).

- [ ] **Step 1: Viết controller**

```ts
// apps/wms/src/users/users.controller.ts
import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiCreatedResponse,
  ApiNoContentResponse,
  ApiOkResponse,
  ApiOperation,
  ApiParam,
  ApiTags,
} from '@nestjs/swagger';
import {
  CurrentUser,
  JwtAuthGuard,
  Roles,
  RolesGuard,
  WmsRole,
} from '@app/auth';
import { buildOffsetMeta, PaginatedResult } from '@app/common';
import { plainToInstance } from 'class-transformer';
import { UsersService } from './users.service';
import { CreateUserDto } from './dto/create-user.dto';
import { UpdateUserDto } from './dto/update-user.dto';
import { UpdateUserRolesDto } from './dto/update-user-roles.dto';
import { ResetUserPasswordDto } from './dto/reset-user-password.dto';
import { QueryUsersDto } from './dto/query-users.dto';
import {
  CreateUserResponseDto,
  UserResponseDto,
} from './dto/user.response.dto';

const TO_OPTS = { excludeExtraneousValues: true } as const;

@ApiTags('users')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles(WmsRole.ADMIN, WmsRole.MANAGER)
@Controller('users')
export class UsersController {
  constructor(private readonly svc: UsersService) {}

  @Get()
  @ApiOperation({ summary: 'Danh sách nhân viên — [ADMIN, MANAGER]' })
  @ApiOkResponse({ type: [UserResponseDto] })
  async list(
    @Query() query: QueryUsersDto,
  ): Promise<PaginatedResult<UserResponseDto>> {
    const { items, total } = await this.svc.list(query);
    const data = plainToInstance(UserResponseDto, items, TO_OPTS);
    return new PaginatedResult(
      data,
      buildOffsetMeta(data.length, query.page, query.limit, total),
    );
  }

  @Get(':id')
  @ApiOperation({ summary: 'Chi tiết nhân viên — [ADMIN, MANAGER]' })
  @ApiParam({ name: 'id', description: 'Mongo ObjectId của user' })
  @ApiOkResponse({ type: UserResponseDto })
  async getById(@Param('id') id: string): Promise<UserResponseDto> {
    const user = await this.svc.getById(id);
    return plainToInstance(UserResponseDto, user, TO_OPTS);
  }

  @Post()
  @ApiOperation({ summary: 'Tạo nhân viên mới — [ADMIN, MANAGER]' })
  @ApiCreatedResponse({ type: CreateUserResponseDto })
  async create(
    @Body() dto: CreateUserDto,
    @CurrentUser() actor: { sub: string; roles: string[] },
  ): Promise<CreateUserResponseDto> {
    const user = await this.svc.create(dto, actor);
    return plainToInstance(CreateUserResponseDto, user, TO_OPTS);
  }

  @Patch(':id')
  @ApiOperation({
    summary: 'Sửa hồ sơ nhân viên (name/email/warehouseId) — [ADMIN, MANAGER]',
  })
  @ApiParam({ name: 'id', description: 'Mongo ObjectId của user' })
  @ApiOkResponse({ type: UserResponseDto })
  async update(
    @Param('id') id: string,
    @Body() dto: UpdateUserDto,
    @CurrentUser() actor: { sub: string; roles: string[] },
  ): Promise<UserResponseDto> {
    const user = await this.svc.update(id, dto, actor);
    return plainToInstance(UserResponseDto, user, TO_OPTS);
  }

  @Patch(':id/roles')
  @ApiOperation({ summary: 'Gán/sửa roles nhân viên — [ADMIN, MANAGER]' })
  @ApiParam({ name: 'id', description: 'Mongo ObjectId của user' })
  @ApiOkResponse({ type: UserResponseDto })
  async updateRoles(
    @Param('id') id: string,
    @Body() dto: UpdateUserRolesDto,
    @CurrentUser() actor: { sub: string; roles: string[] },
  ): Promise<UserResponseDto> {
    const user = await this.svc.updateRoles(id, dto.roles, actor);
    return plainToInstance(UserResponseDto, user, TO_OPTS);
  }

  @Post(':id/lock')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Khóa tài khoản và revoke tất cả refresh token — [ADMIN, MANAGER]',
  })
  @ApiParam({ name: 'id', description: 'Mongo ObjectId của user' })
  @ApiOkResponse({ type: UserResponseDto })
  async lock(
    @Param('id') id: string,
    @CurrentUser() actor: { sub: string; roles: string[] },
  ): Promise<UserResponseDto> {
    const user = await this.svc.lock(id, actor);
    return plainToInstance(UserResponseDto, user, TO_OPTS);
  }

  @Post(':id/unlock')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Mở khóa tài khoản — [ADMIN, MANAGER]' })
  @ApiParam({ name: 'id', description: 'Mongo ObjectId của user' })
  @ApiOkResponse({ type: UserResponseDto })
  async unlock(
    @Param('id') id: string,
    @CurrentUser() actor: { sub: string; roles: string[] },
  ): Promise<UserResponseDto> {
    const user = await this.svc.unlock(id, actor);
    return plainToInstance(UserResponseDto, user, TO_OPTS);
  }

  @Post(':id/reset-password')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Reset mật khẩu tạm và bắt đổi mật khẩu — [ADMIN, MANAGER]',
  })
  @ApiParam({ name: 'id', description: 'Mongo ObjectId của user' })
  @ApiOkResponse({ description: '{ success: true, mustChangePassword: true }' })
  resetPassword(
    @Param('id') id: string,
    @Body() dto: ResetUserPasswordDto,
    @CurrentUser() actor: { sub: string; roles: string[] },
  ): Promise<{ success: boolean; mustChangePassword: boolean }> {
    return this.svc.resetPassword(id, dto.temporaryPassword, actor);
  }

  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  @ApiOperation({ summary: 'Xóa nhân viên (soft-delete) — [ADMIN, MANAGER]' })
  @ApiParam({ name: 'id', description: 'Mongo ObjectId của user' })
  @ApiNoContentResponse()
  async remove(
    @Param('id') id: string,
    @CurrentUser() actor: { sub: string; roles: string[] },
  ): Promise<void> {
    await this.svc.remove(id, actor);
  }
}
```

- [ ] **Step 2: Viết `UsersModule`**

```ts
// apps/wms/src/users/users.module.ts
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { UserRefreshTokenRepository } from '../auth/repositories/user-refresh-token.repository';
import {
  UserRefreshToken,
  UserRefreshTokenSchema,
} from '../auth/schemas/user-refresh-token.schema';
import { UsersController } from './users.controller';
import { UsersService } from './users.service';
import { UserRepository } from './repositories/user.repository';
import { User, UserSchema } from './schemas/user.schema';

/**
 * UserRefreshToken model đăng ký lại ở đây (KHÔNG di chuyển khỏi auth/) vì
 * UsersService cần revoke token khi lock/reset-password. Mongoose cho phép
 * forFeature cùng 1 schema ở nhiều module — dùng chung 1 connection.
 */
@Module({
  imports: [
    MongooseModule.forFeature([
      { name: User.name, schema: UserSchema },
      { name: UserRefreshToken.name, schema: UserRefreshTokenSchema },
    ]),
  ],
  controllers: [UsersController],
  providers: [UsersService, UserRepository, UserRefreshTokenRepository],
  exports: [UsersService, UserRepository],
})
export class UsersModule {}
```

- [ ] **Step 3: Viết test controller (theo style `auth.controller.spec.ts`)**

```ts
// apps/wms/src/users/users.controller.spec.ts
import { Test, TestingModule } from '@nestjs/testing';
import { UsersController } from './users.controller';
import { UsersService } from './users.service';
import { UserResponseDto } from './dto/user.response.dto';

const mockUsersService = {
  list: jest.fn(),
  getById: jest.fn(),
  create: jest.fn(),
  update: jest.fn(),
  updateRoles: jest.fn(),
  lock: jest.fn(),
  unlock: jest.fn(),
  resetPassword: jest.fn(),
  remove: jest.fn(),
};

const actor = { sub: 'admin1', roles: ['ADMIN'] };

describe('UsersController', () => {
  let controller: UsersController;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      controllers: [UsersController],
      providers: [{ provide: UsersService, useValue: mockUsersService }],
    }).compile();
    controller = module.get(UsersController);
    jest.clearAllMocks();
  });

  describe('list', () => {
    it('trả PaginatedResult với data map từ UserResponseDto', async () => {
      mockUsersService.list.mockResolvedValue({
        items: [
          {
            _id: { toString: () => 'u1' },
            username: 'staff1',
            roles: ['PICKER'],
            status: 'ACTIVE',
            mustChangePassword: false,
            createdAt: new Date(),
            updatedAt: new Date(),
          },
        ],
        total: 1,
      });

      const result = await controller.list({ page: 1, limit: 20 } as never);

      expect(result.items[0]).toBeInstanceOf(UserResponseDto);
      expect(result.pagination).toMatchObject({
        type: 'offset',
        page: 1,
        limit: 20,
        totalItems: 1,
      });
    });
  });

  describe('getById', () => {
    it('trả UserResponseDto — không lộ passwordHash', async () => {
      mockUsersService.getById.mockResolvedValue({
        _id: { toString: () => 'u1' },
        username: 'staff1',
        roles: ['PICKER'],
        status: 'ACTIVE',
        mustChangePassword: false,
        passwordHash: 'secret',
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      const result = await controller.getById('u1');
      expect(result).toBeInstanceOf(UserResponseDto);
      expect((result as Record<string, unknown>)['passwordHash']).toBeUndefined();
    });
  });

  describe('create', () => {
    it('gọi service.create với actor từ @CurrentUser', async () => {
      mockUsersService.create.mockResolvedValue({
        _id: { toString: () => 'u2' },
        username: 'new1',
        roles: ['PICKER'],
        mustChangePassword: true,
      });

      await controller.create(
        { username: 'new1', password: 'P@ss1234' } as never,
        actor,
      );

      expect(mockUsersService.create).toHaveBeenCalledWith(
        { username: 'new1', password: 'P@ss1234' },
        actor,
      );
    });
  });

  describe('remove', () => {
    it('gọi service.remove và không trả nội dung', async () => {
      mockUsersService.remove.mockResolvedValue(undefined);
      const result = await controller.remove('u3', actor);
      expect(result).toBeUndefined();
      expect(mockUsersService.remove).toHaveBeenCalledWith('u3', actor);
    });
  });
});
```

- [ ] **Step 4: Chạy test**

Run: `pnpm test -- apps/wms/src/users/users.controller.spec.ts`
Expected: PASS (4 test case)

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/users/users.controller.ts apps/wms/src/users/users.controller.spec.ts apps/wms/src/users/users.module.ts
git commit -m "feat(wms): thêm UsersController + UsersModule"
```

---

## Task 6: Cắt gọn `AuthModule` — bỏ endpoint `users/*`, dùng `UsersModule`

**Files:**
- Modify: `apps/wms/src/auth/auth.module.ts`
- Modify: `apps/wms/src/auth/auth.controller.ts`
- Modify: `apps/wms/src/auth/auth.service.ts`
- Modify: `apps/wms/src/auth/dto/auth.dto.ts`
- Modify: `apps/wms/src/auth/auth.controller.spec.ts`
- Modify: `apps/wms/src/app.module.ts`

**Interfaces:**
- Consumes: `UsersModule` export `UserRepository` (Task 5) — `AuthService` tiếp tục dùng `UserRepository` cho `login`/`googleLogin`/`refresh`/`me`/`bootstrapAdmin`/`changePassword` (không đổi các method này, chỉ đổi nguồn import).
- Produces: `AuthModule` gọn lại, `AppModule` có thêm `UsersModule`.

- [ ] **Step 1: Sửa `auth.module.ts` — bỏ `User` schema registration (giữ `UserRefreshToken`), import `UsersModule`**

```ts
// apps/wms/src/auth/auth.module.ts
import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { MongooseModule } from '@nestjs/mongoose';
import { PassportModule } from '@nestjs/passport';
import { FirebaseAdminModule } from '@app/common';
import { UsersModule } from '../users/users.module';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { JwtStrategy } from './jwt.strategy';
import { UserRefreshTokenRepository } from './repositories/user-refresh-token.repository';
import {
  UserRefreshToken,
  UserRefreshTokenSchema,
} from './schemas/user-refresh-token.schema';

/**
 * Module auth WMS. JwtModule đăng ký rỗng (secret/expiresIn truyền lúc sign trong
 * service từ ConfigService) — để 1 nơi quản secret. PassportModule nạp JwtStrategy.
 * UserRepository lấy từ UsersModule (không đăng ký User schema lại ở đây) — login
 * và quản lý user không nên tách rời 2 nguồn dữ liệu.
 */
@Module({
  imports: [
    PassportModule,
    JwtModule.register({}),
    FirebaseAdminModule,
    UsersModule,
    MongooseModule.forFeature([
      { name: UserRefreshToken.name, schema: UserRefreshTokenSchema },
    ]),
  ],
  controllers: [AuthController],
  providers: [AuthService, JwtStrategy, UserRefreshTokenRepository],
  exports: [AuthService],
})
export class AuthModule {}
```

- [ ] **Step 2: Sửa `auth.service.ts` — bỏ `createUser`/`updateRoles`/`lockUser`/`unlockUser`/`resetTemporaryPassword`, import `UserRepository` từ `../users/repositories/user.repository`**

```ts
// apps/wms/src/auth/auth.service.ts
import { Inject, Injectable } from '@nestjs/common';
import type { ConfigType } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import type { JwtSignOptions } from '@nestjs/jwt';
import { JwtPayload, WmsRole } from '@app/auth';
import {
  AppException,
  durationToMs,
  generateOpaqueToken,
  hashToken,
  FirebaseAdminService,
} from '@app/common';
import * as bcrypt from 'bcryptjs';
import { Types } from 'mongoose';
import { authConfig } from '../config/auth.config';
import { CreateUserDto } from '../users/dto/create-user.dto';
import { UserRepository } from '../users/repositories/user.repository';
import { UserStatus } from '../users/schemas/user.schema';
import { UsersService } from '../users/users.service';
import { ChangePasswordDto } from './dto/auth.dto';
import { UserRefreshTokenRepository } from './repositories/user-refresh-token.repository';

type MsDuration = Exclude<JwtSignOptions['expiresIn'], number | undefined>;

const BCRYPT_ROUNDS = 12;
const INVALID_BCRYPT_HASH = '$2a$12$invalidinvalidinvalidinvalidin';

@Injectable()
export class AuthService {
  constructor(
    private readonly userRepo: UserRepository,
    private readonly usersService: UsersService,
    private readonly refreshRepo: UserRefreshTokenRepository,
    private readonly jwt: JwtService,
    private readonly firebaseAdmin: FirebaseAdminService,
    @Inject(authConfig.KEY)
    private readonly auth: ConfigType<typeof authConfig>,
  ) {}

  private objectId(id: string) {
    if (!Types.ObjectId.isValid(id))
      throw new AppException('NOT_FOUND', 'User not found');
    return new Types.ObjectId(id);
  }

  private async validateUser(username: string, password: string) {
    const user = await this.userRepo.findActiveByUsername(username, true);
    const ok = user
      ? await bcrypt.compare(password, user.passwordHash)
      : await bcrypt.compare(password, INVALID_BCRYPT_HASH);
    if (!user || !ok) {
      throw new AppException(
        'AUTH_INVALID_CREDENTIALS',
        'Sai tài khoản hoặc mật khẩu',
      );
    }
    return user;
  }

  async login(username: string, password: string) {
    const user = await this.validateUser(username, password);
    const tokens = await this.issueTokens(user._id, user.roles, user.username);
    return { ...tokens, mustChangePassword: user.mustChangePassword };
  }

  async googleLogin(idToken: string) {
    const decoded = await this.firebaseAdmin.verifyIdToken(idToken);
    if (!decoded.email) {
      throw new AppException('AUTH_FIREBASE_NO_EMAIL');
    }

    const existingByUid = await this.userRepo.findByFirebaseUid(
      decoded.uid,
      true,
    );
    const existingByEmail = existingByUid
      ? existingByUid
      : await this.userRepo.findActiveByEmail(decoded.email, true);

    if (!existingByEmail) {
      throw new AppException('AUTH_WMS_NOT_INITIALIZED');
    }

    const user = existingByEmail.firebaseUid
      ? existingByEmail.firebaseUid === decoded.uid
        ? existingByEmail
        : (() => {
            throw new AppException('AUTH_FIREBASE_UID_MISMATCH');
          })()
      : await this.userRepo.linkFirebaseUid(existingByEmail._id, decoded.uid);

    if (!user) {
      throw new AppException('AUTH_WMS_NOT_INITIALIZED');
    }

    const tokens = await this.issueTokens(user._id, user.roles, user.username);
    return { ...tokens, mustChangePassword: user.mustChangePassword };
  }

  private async issueTokens(
    userId: Types.ObjectId,
    roles: string[],
    username: string,
  ) {
    const payload: JwtPayload = {
      sub: userId.toString(),
      type: 'user',
      roles,
      username,
    };
    const accessToken = await this.jwt.signAsync(payload, {
      secret: this.auth.jwtSecret,
      expiresIn: this.auth.jwtExpiresIn as MsDuration,
    });

    const refreshToken = generateOpaqueToken();
    const ttl = durationToMs(this.auth.refreshExpiresIn);
    await this.refreshRepo.create(
      userId,
      hashToken(refreshToken),
      new Date(Date.now() + ttl),
    );

    return { accessToken, refreshToken };
  }

  async refresh(refreshToken: string) {
    const doc = await this.refreshRepo.findValid(hashToken(refreshToken));
    if (!doc || doc.expiresAt.getTime() < Date.now()) {
      throw new AppException('AUTH_TOKEN_INVALID');
    }
    const user = await this.userRepo.findActiveById(doc.userId);
    if (!user || user.status !== UserStatus.ACTIVE) {
      throw new AppException('AUTH_ACCOUNT_INACTIVE');
    }

    doc.revokedAt = new Date();
    await doc.save();
    return this.issueTokens(user._id, user.roles, user.username);
  }

  async logout(refreshToken: string) {
    await this.refreshRepo.revoke(hashToken(refreshToken));
    return { success: true };
  }

  async me(userId: string) {
    const user = await this.userRepo.findActiveById(userId);
    if (!user || user.status !== UserStatus.ACTIVE)
      throw new AppException('UNAUTHENTICATED');
    return user;
  }

  async bootstrapAdmin(dto: CreateUserDto) {
    const count = await this.userRepo.countAll();
    if (count > 0) {
      throw new AppException('AUTH_BOOTSTRAP_FORBIDDEN');
    }
    return this.usersService.create(
      { ...dto, roles: [WmsRole.ADMIN] },
      { sub: '', roles: [WmsRole.ADMIN] },
    );
  }

  async changePassword(userId: string, dto: ChangePasswordDto) {
    const user = await this.userRepo.findByIdWithPassword(
      this.objectId(userId),
    );
    const ok = user
      ? await bcrypt.compare(dto.oldPassword, user.passwordHash)
      : await bcrypt.compare(dto.oldPassword, INVALID_BCRYPT_HASH);
    if (!user || !ok) {
      throw new AppException(
        'AUTH_INVALID_CREDENTIALS',
        'Mật khẩu cũ không đúng',
      );
    }

    const passwordHash = await bcrypt.hash(dto.newPassword, BCRYPT_ROUNDS);
    await this.userRepo.updatePassword(user._id, passwordHash, false, user._id);
    return { success: true, mustChangePassword: false };
  }
}
```

**Ghi chú về `bootstrapAdmin`:** gọi `usersService.create` với actor giả `{ sub: '', roles: [ADMIN] }` — hợp lệ vì `assertManagerCanActOnTarget` chỉ chặn khi actor **không** có role ADMIN; actor giả có `roles: [ADMIN]` nên qua được, và `sub: ''` không dùng để set `createdBy` sai lệch nghiêm trọng (trường hợp bootstrap, chưa có user nào tồn tại nên không có actor thật — hành vi này **giống hệt code cũ**: `createUser(dto, createdBy?: string)` cũ cũng gọi `this.createUser({ ...dto, roles: [WmsRole.ADMIN] })` không truyền `createdBy` → `undefined`. Ở bản mới, `objectId('')` sẽ throw vì `Types.ObjectId.isValid('')` là `false` — **cần sửa**: xem Step 2b.

- [ ] **Step 2b: Sửa `UsersService.create` để `createdBy` optional, tránh vỡ `bootstrapAdmin`**

Quay lại `apps/wms/src/users/users.service.ts` (Task 4), sửa signature `create` để actor có thể không có `sub` hợp lệ lúc bootstrap:

```ts
// Thay trong users.service.ts:
export interface Actor {
  sub: string;
  roles: string[];
}
```
giữ nguyên, nhưng sửa `create`:

```ts
  async create(dto: CreateUserDto, actor: Actor): Promise<UserDocument> {
    this.assertManagerCanActOnTarget(actor, dto.roles ?? []);
    const passwordHash = await bcrypt.hash(dto.password, BCRYPT_ROUNDS);
    return this.userRepo.create({
      username: dto.username,
      email: dto.email,
      name: dto.name,
      roles: dto.roles ?? [],
      passwordHash,
      mustChangePassword: true,
      createdBy:
        actor.sub && Types.ObjectId.isValid(actor.sub)
          ? this.objectId(actor.sub)
          : undefined,
    });
  }
```

Đây là cách xử lý đúng cho ca biên `bootstrapAdmin` (chưa có actor thật) mà không phá vỡ validate `objectId` dùng ở các method khác — chỉ nới lỏng ở `create` vì đây là method duy nhất có thể được gọi khi hệ thống chưa có user nào (nên chưa có JWT thật để lấy `sub` hợp lệ).

- [ ] **Step 3: Sửa `dto/auth.dto.ts` — bỏ 5 class đã di chuyển, giữ 5 class + response còn dùng**

```ts
// apps/wms/src/auth/dto/auth.dto.ts
import { IsOptional, IsString, MinLength } from 'class-validator';
import { Expose } from 'class-transformer';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

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
  @ApiPropertyOptional({
    description:
      'Refresh token nhận được lúc login — bỏ qua nếu dùng cookie mode',
  })
  @IsOptional()
  @IsString()
  refreshToken?: string;
}

export class LogoutDto {
  @ApiPropertyOptional({
    description: 'Refresh token cần thu hồi — bỏ qua nếu dùng cookie mode',
  })
  @IsOptional()
  @IsString()
  refreshToken?: string;
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
```

Cần thêm `CreateUserDto` cho `bootstrap-admin` body — import từ `../../users/dto/create-user.dto` trong `auth.controller.ts` (Step 4), không tái tạo trong `auth.dto.ts`.

- [ ] **Step 4: Sửa `auth.controller.ts` — bỏ 5 endpoint `users/*`, sửa import**

```ts
// apps/wms/src/auth/auth.controller.ts
import {
  Body,
  Controller,
  Get,
  HttpCode,
  Inject,
  Post,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiBody,
  ApiCreatedResponse,
  ApiForbiddenResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
  ApiUnauthorizedResponse,
} from '@nestjs/swagger';
import { CurrentUser, JwtAuthGuard } from '@app/auth';
import { AppException, AuthThrottle } from '@app/common';
import type { ConfigType } from '@nestjs/config';
import { plainToInstance } from 'class-transformer';
import type { Request, Response } from 'express';
import { appConfig } from '../config/app.config';
import { CreateUserDto } from '../users/dto/create-user.dto';
import {
  CreateUserResponseDto,
  UserResponseDto,
} from '../users/dto/user.response.dto';
import { AuthService } from './auth.service';
import {
  AuthTokenResponseDto,
  ChangePasswordDto,
  GoogleLoginDto,
  LoginDto,
  LogoutDto,
  RefreshDto,
} from './dto/auth.dto';

@ApiTags('auth')
@Controller('auth')
export class AuthController {
  private readonly isProd: boolean;

  constructor(
    private readonly auth: AuthService,
    @Inject(appConfig.KEY)
    private readonly appCfg: ConfigType<typeof appConfig>,
  ) {
    this.isProd = this.appCfg.env === 'production';
  }

  // Cookie access_token: path rộng để dùng mọi route WMS.
  // Cookie refresh_token: path hẹp /api/wms/auth để browser chỉ gửi lên auth endpoints.
  private setAuthCookies(
    res: Response,
    tokens: { accessToken: string; refreshToken: string },
  ): void {
    const base = {
      httpOnly: true,
      sameSite: 'lax' as const,
      secure: this.isProd,
    };
    res.cookie('access_token', tokens.accessToken, {
      ...base,
      path: '/api/wms',
    });
    res.cookie('refresh_token', tokens.refreshToken, {
      ...base,
      path: '/api/wms/auth',
    });
  }

  private clearAuthCookies(res: Response): void {
    res.clearCookie('access_token', { path: '/api/wms' });
    res.clearCookie('refresh_token', { path: '/api/wms/auth' });
  }

  // Ưu tiên body, fallback cookie — để API client và web browser đều dùng được.
  private extractRefreshToken(
    dto: RefreshDto | LogoutDto,
    req: Request,
  ): string {
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
    description:
      'Trả token trong body VÀ set cookie access_token + refresh_token',
  })
  @ApiUnauthorizedResponse({ description: 'Sai tài khoản hoặc mật khẩu' })
  async login(
    @Body() dto: LoginDto,
    @Res({ passthrough: true }) res: Response,
  ): Promise<AuthTokenResponseDto> {
    const tokens = await this.auth.login(dto.username, dto.password);
    this.setAuthCookies(res, tokens);
    return plainToInstance(AuthTokenResponseDto, tokens, {
      excludeExtraneousValues: true,
    });
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
    description:
      'Trả token trong body VÀ set cookie access_token + refresh_token',
  })
  @ApiUnauthorizedResponse({
    description: 'Firebase token không hợp lệ hoặc nhân viên chưa khởi tạo',
  })
  async googleLogin(
    @Body() dto: GoogleLoginDto,
    @Res({ passthrough: true }) res: Response,
  ): Promise<AuthTokenResponseDto> {
    const tokens = await this.auth.googleLogin(dto.idToken);
    this.setAuthCookies(res, tokens);
    return plainToInstance(AuthTokenResponseDto, tokens, {
      excludeExtraneousValues: true,
    });
  }

  @Post('refresh')
  @HttpCode(200)
  @AuthThrottle()
  @ApiOperation({
    summary: 'Đổi access token mới bằng refresh token (body hoặc cookie)',
  })
  @ApiBody({
    type: RefreshDto,
    examples: {
      bearer: {
        summary: 'Bearer mode',
        value: { refreshToken: 'paste-refresh-token-here' },
      },
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
    return plainToInstance(AuthTokenResponseDto, tokens, {
      excludeExtraneousValues: true,
    });
  }

  @Post('logout')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Đăng xuất và thu hồi refresh token — [ALL_ROLES]' })
  @ApiOkResponse({
    description: '{ success: true } — cookies cleared, token revoked',
  })
  @ApiBody({
    type: LogoutDto,
    examples: {
      bearer: {
        summary: 'Bearer mode',
        value: { refreshToken: 'paste-refresh-token-here' },
      },
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
  @ApiOperation({ summary: 'Thông tin nhân viên đang đăng nhập — [ALL_ROLES]' })
  @ApiOkResponse({ type: UserResponseDto })
  async me(@CurrentUser('sub') userId: string): Promise<UserResponseDto> {
    const user = await this.auth.me(userId);
    return plainToInstance(UserResponseDto, user, {
      excludeExtraneousValues: true,
    });
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
  async bootstrapAdmin(
    @Body() dto: CreateUserDto,
  ): Promise<CreateUserResponseDto> {
    const user = await this.auth.bootstrapAdmin(dto);
    return plainToInstance(CreateUserResponseDto, user, {
      excludeExtraneousValues: true,
    });
  }

  @Post('change-password')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Nhân viên đổi mật khẩu — [ALL_ROLES]' })
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
  @ApiOkResponse({
    description: '{ success: true, mustChangePassword: false }',
  })
  changePassword(
    @CurrentUser('sub') userId: string,
    @Body() dto: ChangePasswordDto,
  ): Promise<{ success: boolean; mustChangePassword: boolean }> {
    return this.auth.changePassword(userId, dto);
  }
}
```

- [ ] **Step 5: Sửa `auth.controller.spec.ts` — bỏ mock các method đã chuyển ra `UsersService`**

```ts
// apps/wms/src/auth/auth.controller.spec.ts
import { Test, TestingModule } from '@nestjs/testing';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { appConfig } from '../config/app.config';
import { UserResponseDto } from '../users/dto/user.response.dto';

const mockAuthService = {
  login: jest.fn(),
  googleLogin: jest.fn(),
  refresh: jest.fn(),
  logout: jest.fn(),
  me: jest.fn(),
  bootstrapAdmin: jest.fn(),
  changePassword: jest.fn(),
};

const mockAppConfig = { env: 'development' };

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
        { provide: appConfig.KEY, useValue: mockAppConfig },
      ],
    }).compile();
    controller = module.get(AuthController);
    jest.clearAllMocks();
  });

  describe('login', () => {
    it('set cookie và trả AuthTokenResponseDto', async () => {
      const tokens = {
        accessToken: 'at',
        refreshToken: 'rt',
        mustChangePassword: false,
      };
      mockAuthService.login.mockResolvedValue(tokens);
      const res = makeMockRes();

      const result = await controller.login(
        { username: 'admin', password: 'pass' },
        res as never,
      );

      expect(res.cookie).toHaveBeenCalledWith(
        'access_token',
        'at',
        expect.objectContaining({ httpOnly: true, path: '/api/wms' }),
      );
      expect(res.cookie).toHaveBeenCalledWith(
        'refresh_token',
        'rt',
        expect.objectContaining({ httpOnly: true, path: '/api/wms/auth' }),
      );
      expect(result).toMatchObject({
        accessToken: 'at',
        refreshToken: 'rt',
        mustChangePassword: false,
      });
    });
  });

  describe('googleLogin', () => {
    it('set cookie và trả AuthTokenResponseDto', async () => {
      const tokens = {
        accessToken: 'at',
        refreshToken: 'rt',
        mustChangePassword: false,
      };
      mockAuthService.googleLogin.mockResolvedValue(tokens);
      const res = makeMockRes();

      const result = await controller.googleLogin(
        { idToken: 'firebase-id-token' },
        res as never,
      );

      expect(res.cookie).toHaveBeenCalledWith(
        'access_token',
        'at',
        expect.objectContaining({ httpOnly: true, path: '/api/wms' }),
      );
      expect(res.cookie).toHaveBeenCalledWith(
        'refresh_token',
        'rt',
        expect.objectContaining({ httpOnly: true, path: '/api/wms/auth' }),
      );
      expect(result).toMatchObject({
        accessToken: 'at',
        refreshToken: 'rt',
        mustChangePassword: false,
      });
    });
  });

  describe('refresh', () => {
    it('ưu tiên body refreshToken', async () => {
      mockAuthService.refresh.mockResolvedValue({
        accessToken: 'at2',
        refreshToken: 'rt2',
        mustChangePassword: false,
      });
      const res = makeMockRes();
      const req = makeMockReq({ refresh_token: 'cookie-token' });

      await controller.refresh(
        { refreshToken: 'body-token' },
        res as never,
        req as never,
      );

      expect(mockAuthService.refresh).toHaveBeenCalledWith('body-token');
    });

    it('fallback cookie khi body không có refreshToken', async () => {
      mockAuthService.refresh.mockResolvedValue({
        accessToken: 'at2',
        refreshToken: 'rt2',
        mustChangePassword: false,
      });
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

      expect(res.clearCookie).toHaveBeenCalledWith('access_token', {
        path: '/api/wms',
      });
      expect(res.clearCookie).toHaveBeenCalledWith('refresh_token', {
        path: '/api/wms/auth',
      });
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
      expect(
        (result as Record<string, unknown>)['passwordHash'],
      ).toBeUndefined();
      expect(result.id).toBe('uid');
    });
  });
});
```

- [ ] **Step 6: Thêm `UsersModule` vào `app.module.ts`**

Trong `apps/wms/src/app.module.ts`, thêm import và đăng ký ngay sau `AuthModule` trong mảng `imports`:

```ts
import { UsersModule } from './users/users.module';
// ...
    AuthModule, // đăng nhập nhân viên + JWT
    UsersModule, // CRUD nhân viên cho ADMIN/MANAGER (list/get/create/update/roles/lock/unlock/reset-password/soft-delete)
    HealthModule,
```

- [ ] **Step 7: Chạy toàn bộ test WMS**

Run: `pnpm test -- apps/wms/src/auth apps/wms/src/users`
Expected: PASS toàn bộ — không còn method nào bị mock thiếu, không còn import path cũ nào sót lại.

- [ ] **Step 8: Build**

Run: `pnpm build wms`
Expected: build thành công, không lỗi TypeScript.

- [ ] **Step 9: Commit**

```bash
git add apps/wms/src/auth apps/wms/src/app.module.ts
git commit -m "refactor(wms): cắt gọn AuthModule, chuyển quản lý user sang UsersModule"
```

---

## Task 7: Kiểm tra toàn cục — lint, test suite đầy đủ, Swagger

**Files:** không tạo/sửa file mới — chỉ chạy kiểm tra.

- [ ] **Step 1: Lint toàn bộ**

Run: `pnpm lint`
Expected: 0 lỗi (đặc biệt chú ý `@typescript-eslint/no-explicit-any`, `no-unsafe-member-access` ở các `@Transform` callback đã copy).

- [ ] **Step 2: Test toàn bộ app WMS**

Run: `pnpm test -- apps/wms`
Expected: PASS toàn bộ suite, không có test nào còn tham chiếu `apps/wms/src/auth/repositories/user.repository.ts` hay `apps/wms/src/auth/schemas/user.schema.ts` (đã xóa).

- [ ] **Step 3: Build toàn repo**

Run: `pnpm build`
Expected: cả 3 app build thành công (wms/ecommerce/notification) — đảm bảo không phá vỡ gì ở app khác dù chỉ sửa `apps/wms`.

- [ ] **Step 4: Xác nhận thủ công route list bằng cách khởi động dev server và kiểm tra Swagger**

Run: `pnpm start:wms &` rồi mở `http://localhost:3001/api/wms/docs` (port theo `WMS_PORT` env, mặc định 3001).
Expected: thấy tag `users` với 9 endpoint (`GET /users`, `GET /users/:id`, `POST /users`, `PATCH /users/:id`, `PATCH /users/:id/roles`, `POST /users/:id/lock`, `POST /users/:id/unlock`, `POST /users/:id/reset-password`, `DELETE /users/:id`), tag `auth` chỉ còn 7 endpoint (login/google-login/refresh/logout/me/bootstrap-admin/change-password). Dừng server sau khi kiểm tra xong (`kill %1` hoặc Ctrl+C).

- [ ] **Step 5: Không commit gì ở task này (chỉ verification) — nếu lint/test phát hiện lỗi, quay lại task tương ứng sửa rồi mới sang Task 8**

---

## Task 8: Cập nhật GitHub issue #15

**Files:** không có file code — cập nhật issue qua `gh` CLI.

- [ ] **Step 1: Tick các checkbox đã hoàn thành trong issue #15**

Run:
```bash
gh issue view 15 --json body -q .body > /tmp/claude-1000/-home-hoaiphuong-code-wms-ecom-be/be01d817-6ab8-402e-988e-2b522ffa437d/scratchpad/issue-15-body.md
```
Sửa file (đổi `- [ ]` thành `- [x]` cho toàn bộ hạng mục đã implement), sau đó:
```bash
gh issue edit 15 --body-file /tmp/claude-1000/-home-hoaiphuong-code-wms-ecom-be/be01d817-6ab8-402e-988e-2b522ffa437d/scratchpad/issue-15-body.md
```

- [ ] **Step 2: Comment tóm tắt commit đã thực hiện**

```bash
gh issue comment 15 --body "Đã implement đầy đủ: tách UsersModule, 9 endpoint CRUD, rule chặn MANAGER thao tác tài khoản ADMIN, soft-delete, error codes USER_* trong ERROR_CATALOG. Xem plan chi tiết: docs/superpowers/plans/2026-07-21-users-crud-admin.md"
```

(Không đóng issue — để user tự đóng sau khi merge, theo nguyên tắc không tự ý thực hiện hành động không đảo ngược được / ảnh hưởng trạng thái chung mà chưa xác nhận.)

---

## Self-Review Checklist (đã chạy khi viết plan)

1. **Spec coverage:** 9 endpoint trong bảng spec mục 3 → Task 5 Step 1 implement đủ cả 9. Rule leo thang quyền → Task 4. Soft-delete → Task 2 (`softDelete`) + Task 4 (`remove`). Error codes → Task 1 Step 3. Module tách biệt → Task 6. Swagger `[ADMIN, MANAGER]` + `enum` → có trong mọi `@ApiOperation`/`@ApiProperty` ở Task 5. Filter list (role/status/warehouseId/search) → Task 3 Step 6 + Task 2 Step 1 `findAll`.
2. **Placeholder scan:** không còn "TBD"/"tương tự Task N mà không kèm code". Mọi step code đều đầy đủ nội dung thật.
3. **Type consistency:** `Actor` interface (`{ sub: string; roles: string[] }`) dùng nhất quán từ `UsersService` (Task 4) sang `UsersController` (Task 5, khai inline cùng shape) sang `AuthService.bootstrapAdmin` (Task 6). `UserRepository.findAll` trả `{ items, total }` — khớp cách `UsersService.list` và `UsersController.list` tiêu thụ. `softDelete` trả `boolean` — khớp cách `UsersService.remove` kiểm tra.
