# Chuyển sang single-role (1 account = 1 role) + drop DB + reseed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Đổi toàn bộ hệ thống từ `roles: string[]` (multi-role) sang `role: string` (single-role) — WMS `User`, Ecommerce `Customer`, `libs/auth` (JwtPayload/RolesGuard) — sửa seed WMS cho khớp, sau đó drop `wms_db` + `ecom_db` thật và chạy lại seed.

**Architecture:** `libs/auth` (dùng chung 2 app) đổi trước: `JwtPayload.role?: string` thay `roles?: string[]`, `RolesGuard` so khớp 1 giá trị. WMS `User` schema/DTO/Service/Controller đổi field `roles`→`role` (bắt buộc, không mảng). `SupplierService.changeStatus` (điểm dùng roles mảng duy nhất ngoài `users/`) đổi theo. Ecommerce `Customer` bỏ hẳn field `roles` (dư thừa, phái sinh từ `type` có sẵn), JWT payload suy `role` từ `type` lúc login. Seed WMS sửa field mới + thêm `seed_shipper`. Cuối cùng: build+test toàn bộ pass → drop 2 DB thật → chạy seed.

**Tech Stack:** NestJS, Mongoose, `class-validator`/`class-transformer`, `@app/auth` (`WmsRole`, `EcomRole`, `RolesGuard`, `JwtPayload`), Jest, `mongosh` (drop DB).

## Global Constraints

- KHÔNG đổi `@Roles(...roles: string[])` decorator (`libs/auth/src/decorators/roles.decorator.ts`) — đây là whitelist role được phép cho 1 route (`@Roles(ADMIN, MANAGER)` vẫn hợp lệ), khác khái niệm với role của user.
- Mọi service throw lỗi dùng `AppException(code)` — không throw NestJS exception thô.
- `@Transform`/callback không dùng `any` — khai type tường minh.
- Field enum trong DTO → `@ApiProperty({ enum: XxxEnum })`.
- Comment (nếu cần) viết tiếng Việt, chỉ giải thích *vì sao*.
- Không transaction xuyên DB, không đọc chéo DB.
- Thứ tự đã chốt với user: code xong + test pass → drop DB thật → chạy seed. Không hỏi lại xác nhận ở bước drop, nhưng báo rõ trước khi chạy (thao tác không thể hoàn tác).

---

## File Structure

```
libs/auth/src/jwt-payload.interface.ts        (SỬA — roles?: string[] → role?: string)
libs/auth/src/guards/roles.guard.ts           (SỬA — so 1 giá trị thay vì giao mảng)

apps/wms/src/users/schemas/user.schema.ts     (SỬA — roles: string[] → role: WmsRole)
apps/wms/src/users/repositories/user.repository.ts        (SỬA — CreateUserInput.role, findAll filter, updateRoles→updateRole)
apps/wms/src/users/repositories/user.repository.spec.ts   (SỬA — test theo field mới)
apps/wms/src/users/dto/create-user.dto.ts     (SỬA — roles?: string[] → role?: WmsRole)
apps/wms/src/users/dto/update-user-roles.dto.ts            (XÓA — thay bằng update-user-role.dto.ts)
apps/wms/src/users/dto/update-user-role.dto.ts             (MỚI — UpdateUserRoleDto, field role: WmsRole)
apps/wms/src/users/dto/user.response.dto.ts   (SỬA — roles!: string[] → role!: string, cả 2 class)
apps/wms/src/users/users.service.ts           (SỬA — Actor.role, assertManagerCanActOnTarget(actor, targetRole: string), updateRoles→updateRole)
apps/wms/src/users/users.service.spec.ts      (SỬA — actor/target dùng role đơn)
apps/wms/src/users/users.controller.ts        (SỬA — route /roles→/role, dto/service theo field mới)
apps/wms/src/users/users.controller.spec.ts   (SỬA — actor/mock theo field mới)

apps/wms/src/auth/auth.service.ts             (SỬA — issueTokens dùng role, bootstrapAdmin actor giả)
apps/wms/src/auth/auth.controller.spec.ts     (SỬA — mock actor role đơn)
apps/wms/src/auth/jwt.strategy.spec.ts        (SỬA — payload role đơn)

apps/wms/src/supplier/supplier.controller.ts  (SỬA — @CurrentUser('role') role: string)
apps/wms/src/supplier/supplier.service.ts     (SỬA — changeStatus nhận role: string)
apps/wms/src/supplier/supplier.service.spec.ts (SỬA — test gọi changeStatus với role đơn)

apps/wms/src/seed/seed.ts                     (SỬA — dto.role thay roles, actor role đơn, thêm seed_shipper)

apps/ecommerce/src/auth/schemas/user.schema.ts             (SỬA — xóa field roles)
apps/ecommerce/src/auth/repositories/user.repository.ts    (SỬA — CreateUserInput bỏ roles?)
apps/ecommerce/src/auth/auth.service.ts       (SỬA — register/createEcomManager bỏ roles, issueTokens suy role từ type)
apps/ecommerce/src/auth/dto/auth.dto.ts       (SỬA — CustomerResponseDto bỏ field roles)
```

---

## Task 1: `libs/auth` — `JwtPayload`/`RolesGuard` sang single-role

**Files:**
- Modify: `libs/auth/src/jwt-payload.interface.ts`
- Modify: `libs/auth/src/guards/roles.guard.ts`

**Interfaces:**
- Produces: `JwtPayload.role?: string` (thay `roles?: string[]`) — mọi nơi build/đọc JWT payload ở Task 2-6 dùng field này.

- [ ] **Step 1: Sửa `JwtPayload` interface**

```ts
// libs/auth/src/jwt-payload.interface.ts
/**
 * Hợp đồng payload JWT dùng chung cho cả 2 app (nhưng KÝ bằng secret RIÊNG mỗi app
 * nên token chéo nhau không verify được — luật #4).
 *
 * - `user`     : nhân viên WMS (collection `users`), có `role` (single).
 * - `customer` : khách Ecommerce (collection `users` bên Ecom), role suy từ `type`.
 */
export type UserType = 'user' | 'customer' | 'admin';

export interface JwtPayload {
  sub: string; // id (_id) của user/customer
  type: UserType; // phân biệt token WMS vs Ecommerce
  role?: string; // 1 nhân viên/khách chỉ có đúng 1 role
  username?: string; // WMS
  email?: string; // Ecommerce
}

/** Object gắn vào `request.user` sau khi JwtStrategy.validate trả về. */
export type AuthUser = JwtPayload;
```

- [ ] **Step 2: Sửa `RolesGuard`**

```ts
// libs/auth/src/guards/roles.guard.ts
import {
  CanActivate,
  ExecutionContext,
  Injectable,
  ForbiddenException,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { Request } from 'express';
import { ROLES_KEY } from '../decorators/roles.decorator';
import { WmsRole, EcomRole } from '../roles';
import { AuthUser } from '../jwt-payload.interface';

/**
 * Kiểm tra role nhân viên WMS. Đặt SAU JwtAuthGuard (cần request.user đã có).
 *
 * - Route không khai @Roles → cho qua (chỉ cần đăng nhập).
 * - ADMIN/ECOM_MANAGER luôn bypass.
 * - Còn lại: cho qua nếu user.role nằm trong danh sách role yêu cầu của route.
 */
@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    const required = this.reflector.getAllAndOverride<string[]>(ROLES_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (!required || required.length === 0) return true;

    const req = context
      .switchToHttp()
      .getRequest<Request & { user?: AuthUser }>();
    const role = req.user?.role;

    if (role === WmsRole.ADMIN || role === EcomRole.ECOM_MANAGER) return true;
    if (role !== undefined && required.includes(role)) return true;

    throw new ForbiddenException('Không đủ quyền truy cập tài nguyên này');
  }
}
```

- [ ] **Step 3: Build kiểm tra lỗi type dự kiến ở nơi khác (chưa sửa)**

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json 2>&1 | head -30`
Expected: Lỗi tại `apps/wms/src/auth/auth.service.ts` (`roles: user.roles` không khớp `JwtPayload.role`), `apps/wms/src/users/*`, `apps/wms/src/supplier/*` — đúng như dự kiến, sẽ sửa ở Task 2-4.

- [ ] **Step 4: Commit**

```bash
git add libs/auth/src/jwt-payload.interface.ts libs/auth/src/guards/roles.guard.ts
git commit -m "refactor(auth): JwtPayload/RolesGuard chuyển sang single-role (role thay roles)"
```

---

## Task 2: WMS `User` schema + `UserRepository` sang single-role

**Files:**
- Modify: `apps/wms/src/users/schemas/user.schema.ts`
- Modify: `apps/wms/src/users/repositories/user.repository.ts`
- Modify: `apps/wms/src/users/repositories/user.repository.spec.ts`

**Interfaces:**
- Consumes: `WmsRole` từ `@app/auth`.
- Produces: `User.role: WmsRole` (required, không default). `CreateUserInput.role?: WmsRole`. `UserRepository.updateRole(id, role: WmsRole, updatedBy)` (đổi tên từ `updateRoles`). `FindAllUsersQuery.role?: string` (đã có sẵn, không đổi tên field, chỉ đổi cách filter).

- [ ] **Step 1: Sửa schema — `roles: string[]` → `role: WmsRole` (required)**

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
 * Mỗi nhân viên chỉ có ĐÚNG 1 role (không multi-role).
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

  @Prop({ type: String, enum: WmsRole, required: true })
  role: WmsRole;

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

- [ ] **Step 2: Sửa `UserRepository`**

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
  role?: WmsRole;
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

// Escape regex đặc biệt trước khi nhồi vào $regex — tránh lỗi compile pattern
// và ReDoS (catastrophic backtracking) từ input free-text của caller.
function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

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
      role: data.role ?? WmsRole.RECEIVER,
    });
  }

  async findAll(
    query: FindAllUsersQuery,
  ): Promise<{ items: UserDocument[]; total: number }> {
    const filter: Record<string, unknown> = { ...SOFT_DELETE_FILTER };
    if (query.role) filter['role'] = query.role;
    if (query.status) filter['status'] = query.status;
    if (query.warehouseId) filter['warehouseId'] = query.warehouseId;
    if (query.search) {
      const escapedSearch = escapeRegExp(query.search);
      filter['$or'] = [
        { username: { $regex: escapedSearch, $options: 'i' } },
        { name: { $regex: escapedSearch, $options: 'i' } },
        { email: { $regex: escapedSearch, $options: 'i' } },
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

  updateRole(
    id: string | Types.ObjectId,
    role: WmsRole,
    updatedBy: Types.ObjectId,
  ) {
    return this.model
      .findOneAndUpdate(
        { _id: id, ...SOFT_DELETE_FILTER },
        { $set: { role, updatedBy } },
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

- [ ] **Step 3: Sửa test repository — `findAll` filter theo `role` (không phải mảng), `updateRole`**

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
          role: 'PICKER',
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

      await expect(repo.softDelete('u1', 'actor1' as never)).resolves.toBe(
        true,
      );
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
git add apps/wms/src/users/schemas/user.schema.ts apps/wms/src/users/repositories/user.repository.ts apps/wms/src/users/repositories/user.repository.spec.ts
git commit -m "refactor(wms): User schema/UserRepository chuyển roles[] sang role đơn"
```

---

## Task 3: WMS `users/dto` sang single-role

**Files:**
- Modify: `apps/wms/src/users/dto/create-user.dto.ts`
- Delete: `apps/wms/src/users/dto/update-user-roles.dto.ts`
- Create: `apps/wms/src/users/dto/update-user-role.dto.ts`
- Modify: `apps/wms/src/users/dto/user.response.dto.ts`

**Interfaces:**
- Consumes: `WmsRole` từ `@app/auth`.
- Produces: `CreateUserDto.role?: WmsRole`; `UpdateUserRoleDto.role: WmsRole`; `UserResponseDto.role!: string`; `CreateUserResponseDto.role!: string` — dùng ở Task 4 (service) và Task 5 (controller).

- [ ] **Step 1: Sửa `create-user.dto.ts`**

```ts
// apps/wms/src/users/dto/create-user.dto.ts
import { IsEmail, IsIn, IsOptional, IsString, MinLength } from 'class-validator';
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

  @ApiPropertyOptional({ example: WmsRole.RECEIVER, enum: WmsRole })
  @IsOptional()
  @IsIn(Object.values(WmsRole))
  role?: WmsRole;
}
```

- [ ] **Step 2: Xóa `update-user-roles.dto.ts`, tạo `update-user-role.dto.ts`**

```bash
rm apps/wms/src/users/dto/update-user-roles.dto.ts
```

```ts
// apps/wms/src/users/dto/update-user-role.dto.ts
import { IsIn } from 'class-validator';
import { ApiProperty } from '@nestjs/swagger';
import { WmsRole } from '@app/auth';

export class UpdateUserRoleDto {
  @ApiProperty({ example: WmsRole.RECEIVER, enum: WmsRole })
  @IsIn(Object.values(WmsRole))
  role!: WmsRole;
}
```

- [ ] **Step 3: Sửa `user.response.dto.ts` — cả 2 class `roles!: string[]` → `role!: string`**

```ts
// apps/wms/src/users/dto/user.response.dto.ts
import { Expose, Transform } from 'class-transformer';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { WmsRole } from '@app/auth';
import { Types } from 'mongoose';

/** Response cho GET /me, GET /users, GET /users/:id, PATCH /users/:id(/role), POST /users/:id/lock|unlock. */
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
  @ApiProperty({ enum: WmsRole })
  role!: string;

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
  @ApiProperty({ enum: WmsRole })
  role!: string;

  @Expose()
  @ApiProperty()
  mustChangePassword!: boolean;
}
```

- [ ] **Step 4: Build kiểm tra DTO tự-đứng-độc-lập biên dịch được**

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json 2>&1 | grep "users/dto" || echo "no errors in users/dto"`
Expected: `no errors in users/dto`

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/users/dto/
git commit -m "refactor(wms): DTO users module chuyển roles[] sang role đơn"
```

---

## Task 4: WMS `UsersService` sang single-role

**Files:**
- Modify: `apps/wms/src/users/users.service.ts`
- Modify: `apps/wms/src/users/users.service.spec.ts`

**Interfaces:**
- Consumes: `UserRepository.updateRole` (Task 2), `CreateUserDto.role?`/`UpdateUserRoleDto.role` (Task 3).
- Produces: `Actor { sub: string; role: string }` (thay `roles: string[]`); `UsersService.updateRole(id, role: WmsRole, actor)` (đổi tên từ `updateRoles`) — dùng ở Task 5 (controller), Task 6 (`AuthService.bootstrapAdmin`), Task 7 (seed).

- [ ] **Step 1: Sửa `users.service.ts`**

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
  role: string;
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
  private assertManagerCanActOnTarget(actor: Actor, targetRole: string): void {
    if (actor.role === WmsRole.ADMIN) return;
    if (targetRole === WmsRole.ADMIN) {
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
    this.assertManagerCanActOnTarget(actor, dto.role ?? WmsRole.RECEIVER);
    const passwordHash = await bcrypt.hash(dto.password, BCRYPT_ROUNDS);
    return this.userRepo.create({
      username: dto.username,
      email: dto.email,
      name: dto.name,
      role: dto.role,
      passwordHash,
      mustChangePassword: true,
      createdBy:
        actor.sub && Types.ObjectId.isValid(actor.sub)
          ? this.objectId(actor.sub)
          : undefined,
    });
  }

  async update(
    id: string,
    dto: UpdateUserDto,
    actor: Actor,
  ): Promise<UserDocument> {
    const target = await this.getById(id);
    this.assertManagerCanActOnTarget(actor, target.role);
    const updated = await this.userRepo.updateProfile(
      target._id,
      dto,
      this.objectId(actor.sub),
    );
    if (!updated) throw new AppException('USER_NOT_FOUND');
    return updated;
  }

  async updateRole(
    id: string,
    role: WmsRole,
    actor: Actor,
  ): Promise<UserDocument> {
    const target = await this.getById(id);
    // Chặn cả 2 chiều: không cho gỡ role ADMIN của người khác, không cho gán role ADMIN.
    this.assertManagerCanActOnTarget(actor, target.role);
    this.assertManagerCanActOnTarget(actor, role);
    const updated = await this.userRepo.updateRole(
      target._id,
      role,
      this.objectId(actor.sub),
    );
    if (!updated) throw new AppException('USER_NOT_FOUND');
    return updated;
  }

  async lock(id: string, actor: Actor): Promise<UserDocument> {
    const target = await this.getById(id);
    this.assertManagerCanActOnTarget(actor, target.role);
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
    this.assertManagerCanActOnTarget(actor, target.role);
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
    this.assertManagerCanActOnTarget(actor, target.role);
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
    this.assertManagerCanActOnTarget(actor, target.role);
    const deleted = await this.userRepo.softDelete(
      target._id,
      this.objectId(actor.sub),
    );
    if (!deleted) throw new AppException('USER_NOT_FOUND');
  }
}
```

- [ ] **Step 2: Sửa toàn bộ test — actor/target dùng `role` đơn thay vì `roles` mảng**

```ts
// apps/wms/src/users/users.service.spec.ts
import { UsersService } from './users.service';
import { UserStatus } from './schemas/user.schema';

const makeUserRepo = () => ({
  findAll: jest.fn(),
  findActiveById: jest.fn(),
  create: jest.fn(),
  updateProfile: jest.fn(),
  updateRole: jest.fn(),
  updateStatus: jest.fn(),
  updatePassword: jest.fn(),
  softDelete: jest.fn(),
});

const makeRefreshRepo = () => ({
  revokeAllForUser: jest.fn(),
});

// Id giả nhưng hợp lệ dạng Mongo ObjectId (24 hex char) — bắt buộc vì
// UsersService.objectId() validate id bằng Types.ObjectId.isValid() TRƯỚC
// khi gọi vào repo (kể cả repo đã mock), string tùy ý như 'admin1' sẽ bị
// chặn ở bước validate và không bao giờ chạm tới mock.
const ADMIN_ACTOR_ID = '6a5f13c791e8fea26de53bac';
const MANAGER_ACTOR_ID = '6a5f13c791e8fea26de53bad';
const TARGET_ID = '6a5f13c791e8fea26de53bae';
const OTHER_TARGET_ID = '6a5f13c791e8fea26de53baf';
const MISSING_ID = '6a5f13c791e8fea26de53bb0';

const adminActor = { sub: ADMIN_ACTOR_ID, role: 'ADMIN' };
const managerActor = { sub: MANAGER_ACTOR_ID, role: 'MANAGER' };

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
    it('MANAGER tạo user với role ADMIN → throw USER_FORBIDDEN_ADMIN_TARGET', async () => {
      await expect(
        svc.create(
          { username: 'x', password: 'p', role: 'ADMIN' } as never,
          managerActor,
        ),
      ).rejects.toMatchObject({ code: 'USER_FORBIDDEN_ADMIN_TARGET' });
      expect(userRepo.create).not.toHaveBeenCalled();
    });

    it('MANAGER tạo user role thường → OK', async () => {
      userRepo.create.mockResolvedValue({ _id: 'u1' });
      await expect(
        svc.create(
          { username: 'x', password: 'p', role: 'PICKER' } as never,
          managerActor,
        ),
      ).resolves.toMatchObject({ _id: 'u1' });
    });

    it('ADMIN tạo user role ADMIN → OK', async () => {
      userRepo.create.mockResolvedValue({ _id: 'u1' });
      await expect(
        svc.create(
          { username: 'x', password: 'p', role: 'ADMIN' } as never,
          adminActor,
        ),
      ).resolves.toMatchObject({ _id: 'u1' });
    });
  });

  describe('update/lock/unlock/resetPassword — chặn MANAGER thao tác target ADMIN', () => {
    const adminTarget = {
      _id: TARGET_ID,
      role: 'ADMIN',
      username: 'admin2',
    };

    it('update: MANAGER sửa user hiện có role ADMIN → throw', async () => {
      userRepo.findActiveById.mockResolvedValue(adminTarget);
      await expect(
        svc.update(TARGET_ID, { name: 'x' }, managerActor),
      ).rejects.toMatchObject({ code: 'USER_FORBIDDEN_ADMIN_TARGET' });
      expect(userRepo.updateProfile).not.toHaveBeenCalled();
    });

    it('lock: MANAGER khóa user ADMIN → throw', async () => {
      userRepo.findActiveById.mockResolvedValue(adminTarget);
      await expect(svc.lock(TARGET_ID, managerActor)).rejects.toMatchObject({
        code: 'USER_FORBIDDEN_ADMIN_TARGET',
      });
      expect(userRepo.updateStatus).not.toHaveBeenCalled();
    });

    it('resetPassword: MANAGER reset password user ADMIN → throw', async () => {
      userRepo.findActiveById.mockResolvedValue(adminTarget);
      await expect(
        svc.resetPassword(TARGET_ID, 'TempP@ss123!', managerActor),
      ).rejects.toMatchObject({ code: 'USER_FORBIDDEN_ADMIN_TARGET' });
    });

    it('ADMIN khóa user ADMIN khác → OK, revoke token', async () => {
      userRepo.findActiveById.mockResolvedValue(adminTarget);
      userRepo.updateStatus.mockResolvedValue({
        _id: TARGET_ID,
        status: UserStatus.LOCKED,
      });
      await svc.lock(TARGET_ID, adminActor);
      expect(refreshRepo.revokeAllForUser).toHaveBeenCalledWith(TARGET_ID);
    });
  });

  describe('lock/unlock — idempotency (gọi lại khi user đã ở đúng trạng thái)', () => {
    const pickerTarget = { _id: TARGET_ID, role: 'PICKER' };

    it('lock user đã LOCKED sẵn → vẫn OK, không throw, vẫn revoke token', async () => {
      userRepo.findActiveById.mockResolvedValue({
        ...pickerTarget,
        status: UserStatus.LOCKED,
      });
      userRepo.updateStatus.mockResolvedValue({
        _id: TARGET_ID,
        status: UserStatus.LOCKED,
      });

      await expect(svc.lock(TARGET_ID, adminActor)).resolves.toMatchObject({
        status: UserStatus.LOCKED,
      });
      expect(userRepo.updateStatus).toHaveBeenCalledWith(
        TARGET_ID,
        UserStatus.LOCKED,
        expect.anything(),
      );
      expect(refreshRepo.revokeAllForUser).toHaveBeenCalledWith(TARGET_ID);
    });

    it('unlock user đã ACTIVE sẵn → vẫn OK, không throw', async () => {
      userRepo.findActiveById.mockResolvedValue({
        ...pickerTarget,
        status: UserStatus.ACTIVE,
      });
      userRepo.updateStatus.mockResolvedValue({
        _id: TARGET_ID,
        status: UserStatus.ACTIVE,
      });

      await expect(svc.unlock(TARGET_ID, adminActor)).resolves.toMatchObject({
        status: UserStatus.ACTIVE,
      });
      expect(userRepo.updateStatus).toHaveBeenCalledWith(
        TARGET_ID,
        UserStatus.ACTIVE,
        expect.anything(),
      );
    });
  });

  describe('updateRole — chặn cả gán mới lẫn target hiện có ADMIN', () => {
    it('MANAGER gán role ADMIN cho user thường → throw', async () => {
      userRepo.findActiveById.mockResolvedValue({
        _id: OTHER_TARGET_ID,
        role: 'PICKER',
      });
      await expect(
        svc.updateRole(OTHER_TARGET_ID, 'ADMIN' as never, managerActor),
      ).rejects.toMatchObject({ code: 'USER_FORBIDDEN_ADMIN_TARGET' });
    });

    it('MANAGER gỡ role ADMIN của user hiện có role ADMIN → throw (chặn chiều target hiện tại)', async () => {
      userRepo.findActiveById.mockResolvedValue({
        _id: TARGET_ID,
        role: 'ADMIN',
      });
      await expect(
        svc.updateRole(TARGET_ID, 'PICKER' as never, managerActor),
      ).rejects.toMatchObject({ code: 'USER_FORBIDDEN_ADMIN_TARGET' });
      expect(userRepo.updateRole).not.toHaveBeenCalled();
    });

    it('ADMIN đổi role bất kỳ → OK', async () => {
      userRepo.findActiveById.mockResolvedValue({
        _id: TARGET_ID,
        role: 'PICKER',
      });
      userRepo.updateRole.mockResolvedValue({ _id: TARGET_ID, role: 'ADMIN' });
      await expect(
        svc.updateRole(TARGET_ID, 'ADMIN' as never, adminActor),
      ).resolves.toMatchObject({ role: 'ADMIN' });
    });
  });

  describe('remove', () => {
    it('tự xóa chính mình → throw USER_CANNOT_DELETE_SELF, không query DB', async () => {
      await expect(
        svc.remove(ADMIN_ACTOR_ID, adminActor),
      ).rejects.toMatchObject({ code: 'USER_CANNOT_DELETE_SELF' });
      expect(userRepo.findActiveById).not.toHaveBeenCalled();
    });

    it('MANAGER xóa user ADMIN → throw USER_FORBIDDEN_ADMIN_TARGET', async () => {
      userRepo.findActiveById.mockResolvedValue({
        _id: TARGET_ID,
        role: 'ADMIN',
      });
      await expect(svc.remove(TARGET_ID, managerActor)).rejects.toMatchObject({
        code: 'USER_FORBIDDEN_ADMIN_TARGET',
      });
      expect(userRepo.softDelete).not.toHaveBeenCalled();
    });

    it('xóa hợp lệ → gọi softDelete', async () => {
      userRepo.findActiveById.mockResolvedValue({
        _id: TARGET_ID,
        role: 'PICKER',
      });
      userRepo.softDelete.mockResolvedValue(true);
      await svc.remove(TARGET_ID, managerActor);
      expect(userRepo.softDelete).toHaveBeenCalledWith(
        TARGET_ID,
        expect.anything(),
      );
    });
  });

  describe('getById', () => {
    it('throw USER_NOT_FOUND khi không tìm thấy', async () => {
      userRepo.findActiveById.mockResolvedValue(null);
      await expect(svc.getById(MISSING_ID)).rejects.toMatchObject({
        code: 'USER_NOT_FOUND',
      });
    });
  });
});
```

- [ ] **Step 3: Chạy test**

Run: `pnpm test -- apps/wms/src/users/users.service.spec.ts`
Expected: PASS (16 tests — 14 cũ + 2 test mới cho `updateRole` chặn 2 chiều)

- [ ] **Step 4: Commit**

```bash
git add apps/wms/src/users/users.service.ts apps/wms/src/users/users.service.spec.ts
git commit -m "refactor(wms): UsersService chuyển roles[] sang role đơn, updateRoles→updateRole"
```

---

## Task 5: WMS `UsersController` sang single-role

**Files:**
- Modify: `apps/wms/src/users/users.controller.ts`
- Modify: `apps/wms/src/users/users.controller.spec.ts`

**Interfaces:**
- Consumes: `UpdateUserRoleDto` (Task 3), `UsersService.updateRole` (Task 4).
- Produces: route `PATCH /users/:id/role` (đổi từ `/roles`), handler `updateRole`.

- [ ] **Step 1: Sửa controller**

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
import { UpdateUserRoleDto } from './dto/update-user-role.dto';
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
    @CurrentUser() actor: { sub: string; role: string },
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
    @CurrentUser() actor: { sub: string; role: string },
  ): Promise<UserResponseDto> {
    const user = await this.svc.update(id, dto, actor);
    return plainToInstance(UserResponseDto, user, TO_OPTS);
  }

  @Patch(':id/role')
  @ApiOperation({ summary: 'Đổi role nhân viên — [ADMIN, MANAGER]' })
  @ApiParam({ name: 'id', description: 'Mongo ObjectId của user' })
  @ApiOkResponse({ type: UserResponseDto })
  async updateRole(
    @Param('id') id: string,
    @Body() dto: UpdateUserRoleDto,
    @CurrentUser() actor: { sub: string; role: string },
  ): Promise<UserResponseDto> {
    const user = await this.svc.updateRole(id, dto.role, actor);
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
    @CurrentUser() actor: { sub: string; role: string },
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
    @CurrentUser() actor: { sub: string; role: string },
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
    @CurrentUser() actor: { sub: string; role: string },
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
    @CurrentUser() actor: { sub: string; role: string },
  ): Promise<void> {
    await this.svc.remove(id, actor);
  }
}
```

- [ ] **Step 2: Sửa test controller**

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
  updateRole: jest.fn(),
  lock: jest.fn(),
  unlock: jest.fn(),
  resetPassword: jest.fn(),
  remove: jest.fn(),
};

const actor = { sub: 'admin1', role: 'ADMIN' };

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
            role: 'PICKER',
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
        role: 'PICKER',
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
        role: 'PICKER',
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

  describe('updateRole', () => {
    it('gọi service.updateRole với id/role/actor', async () => {
      mockUsersService.updateRole.mockResolvedValue({
        _id: { toString: () => 'u1' },
        username: 'staff1',
        role: 'MANAGER',
        status: 'ACTIVE',
        mustChangePassword: false,
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      await controller.updateRole('u1', { role: 'MANAGER' } as never, actor);

      expect(mockUsersService.updateRole).toHaveBeenCalledWith(
        'u1',
        'MANAGER',
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

- [ ] **Step 3: Chạy test**

Run: `pnpm test -- apps/wms/src/users/users.controller.spec.ts`
Expected: PASS (5 tests — 4 cũ + 1 test mới cho `updateRole`)

- [ ] **Step 4: Commit**

```bash
git add apps/wms/src/users/users.controller.ts apps/wms/src/users/users.controller.spec.ts
git commit -m "refactor(wms): UsersController route /roles → /role, dùng UpdateUserRoleDto"
```

---

## Task 6: WMS `AuthService`/`AuthController` spec + `jwt.strategy.spec.ts` sang single-role

**Files:**
- Modify: `apps/wms/src/auth/auth.service.ts`
- Modify: `apps/wms/src/auth/auth.controller.spec.ts`
- Modify: `apps/wms/src/auth/jwt.strategy.spec.ts`

**Interfaces:**
- Consumes: `JwtPayload.role` (Task 1), `UsersService.create` với `Actor.role` (Task 4).
- Produces: `AuthService.issueTokens` build `JwtPayload` với `role: user.role`.

- [ ] **Step 1: Sửa `auth.service.ts` — `issueTokens`, `bootstrapAdmin`**

```ts
// apps/wms/src/auth/auth.service.ts — chỉ phần thay đổi, còn lại giữ nguyên
  private async issueTokens(
    userId: Types.ObjectId,
    role: string,
    username: string,
  ) {
    const payload: JwtPayload = {
      sub: userId.toString(),
      type: 'user',
      role,
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
```

Đổi mọi lời gọi `this.issueTokens(user._id, user.roles, user.username)` → `this.issueTokens(user._id, user.role, user.username)` (2 chỗ: `login`, `googleLogin`, `refresh`).

`bootstrapAdmin`:
```ts
  async bootstrapAdmin(dto: CreateUserDto) {
    const count = await this.userRepo.countAll();
    if (count > 0) {
      throw new AppException('AUTH_BOOTSTRAP_FORBIDDEN');
    }
    return this.usersService.create(
      { ...dto, role: WmsRole.ADMIN },
      { sub: '', role: WmsRole.ADMIN },
    );
  }
```

- [ ] **Step 2: Sửa `auth.controller.spec.ts` dòng 163 (mock actor)**

Tìm dòng `roles: ['ADMIN'],` (dòng ~163) trong context test `me` — đổi thành `role: 'ADMIN',` (field `roles` trên mock user document trả về từ `AuthService.me`, không phải trên JWT payload — vẫn cần đổi vì `AuthService.me` trả `UserDocument` giờ có field `role`).

- [ ] **Step 3: Sửa `jwt.strategy.spec.ts` dòng 26**

Tìm dòng `roles: ['ADMIN'],` trong payload test JwtStrategy — đổi thành `role: 'ADMIN',`.

- [ ] **Step 4: Chạy test**

Run: `pnpm test -- apps/wms/src/auth`
Expected: PASS toàn bộ (auth.controller.spec.ts, auth.service không có spec riêng, jwt.strategy.spec.ts)

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/auth/auth.service.ts apps/wms/src/auth/auth.controller.spec.ts apps/wms/src/auth/jwt.strategy.spec.ts
git commit -m "refactor(wms): AuthService issueTokens/bootstrapAdmin dùng role đơn"
```

---

## Task 7: WMS `SupplierService`/`SupplierController` sang single-role

**Files:**
- Modify: `apps/wms/src/supplier/supplier.controller.ts`
- Modify: `apps/wms/src/supplier/supplier.service.ts`
- Modify: `apps/wms/src/supplier/supplier.service.spec.ts`

**Interfaces:**
- Consumes: `@CurrentUser('role')` (từ `JwtPayload.role`, Task 1).
- Produces: `SupplierService.changeStatus(id, dto, actorId, role: string)`.

- [ ] **Step 1: Sửa `supplier.controller.ts` — chỉ đoạn `changeStatus`**

```ts
  @Patch(':id/status')
  @Roles(WmsRole.MANAGER, WmsRole.ADMIN)
  @ApiOperation({
    summary: 'Đổi trạng thái NCC — [MANAGER, ADMIN] (gỡ BLACKLIST: chỉ ADMIN)',
  })
  @ApiOkResponse({ type: SupplierResponseDto })
  async changeStatus(
    @Param('id') id: string,
    @Body() dto: ChangeSupplierStatusDto,
    @CurrentUser('sub') actorId: string,
    @CurrentUser('role') role: string,
  ): Promise<SupplierResponseDto> {
    const doc = await this.svc.changeStatus(id, dto, actorId, role);
    return plainToInstance(SupplierResponseDto, doc.toObject(), TO_OPTS);
  }
```

- [ ] **Step 2: Sửa `supplier.service.ts` — `changeStatus`**

```ts
  /**
   * Đổi trạng thái NCC.
   * Quy tắc chuyển trạng thái: gỡ BLACKLIST → trạng thái khác chỉ ADMIN làm được.
   * role = role hiện tại của actor (lấy từ JWT payload).
   */
  async changeStatus(
    id: string,
    dto: ChangeSupplierStatusDto,
    actorId: string,
    role: string,
  ): Promise<SupplierDocument> {
    const supplier = await this.repo.findSupplierById(id);
    if (!supplier) throw new AppException('SUPPLIER_NOT_FOUND');

    // Gỡ BLACKLIST → trạng thái khác: chỉ ADMIN mới được phép
    if (
      supplier.status === SupplierStatus.BLACKLIST &&
      dto.status !== SupplierStatus.BLACKLIST &&
      role !== WmsRole.ADMIN
    ) {
      throw new AppException('SUPPLIER_BLACKLISTED');
    }

    const doc = await this.repo.changeSupplierStatus(id, dto.status, actorId);
    if (!doc) throw new AppException('SUPPLIER_NOT_FOUND');
    return doc;
  }
```

- [ ] **Step 3: Sửa test — 2 chỗ gọi `changeStatus` với mảng `['MANAGER']`/`['ADMIN']` → string đơn**

Trong `apps/wms/src/supplier/supplier.service.spec.ts`, sửa:
```ts
        svc.changeStatus(
          supplierId,
          { status: SupplierStatus.ACTIVE },
          actorId,
          'MANAGER',
        ),
```
và
```ts
        svc.changeStatus(
          supplierId,
          {
            status: SupplierStatus.ACTIVE,
          },
          actorId,
          'ADMIN',
        ),
```
(chỉ đổi tham số cuối từ `['MANAGER']`/`['ADMIN']` thành chuỗi `'MANAGER'`/`'ADMIN'`, giữ nguyên toàn bộ phần còn lại của 2 test case).

- [ ] **Step 4: Chạy test**

Run: `pnpm test -- apps/wms/src/supplier`
Expected: PASS toàn bộ

- [ ] **Step 5: Commit**

```bash
git add apps/wms/src/supplier/supplier.controller.ts apps/wms/src/supplier/supplier.service.ts apps/wms/src/supplier/supplier.service.spec.ts
git commit -m "refactor(wms): SupplierService.changeStatus dùng role đơn thay vì roles[]"
```

---

## Task 8: Seed WMS — sửa field mới, thêm `seed_shipper`

**Files:**
- Modify: `apps/wms/src/seed/seed.ts`

**Interfaces:**
- Consumes: `CreateUserDto.role?` (Task 3), `UsersService.create` với `Actor.role` (Task 4).

- [ ] **Step 1: Sửa `SEED_USERS` — thêm `seed_shipper`, và `seedUsers` — `dto.role`/actor role đơn**

```ts
// apps/wms/src/seed/seed.ts — chỉ phần thay đổi
const SEED_USERS: { username: string; role: WmsRole; name: string }[] = [
  { username: 'seed_manager', role: WmsRole.MANAGER, name: 'Seed Manager' },
  { username: 'seed_receiver', role: WmsRole.RECEIVER, name: 'Seed Receiver' },
  { username: 'seed_picker', role: WmsRole.PICKER, name: 'Seed Picker' },
  { username: 'seed_printer', role: WmsRole.PRINTER, name: 'Seed Printer' },
  { username: 'seed_counter', role: WmsRole.COUNTER, name: 'Seed Counter' },
  { username: 'seed_shipper', role: WmsRole.SHIPPER, name: 'Seed Shipper' },
];
```

Trong `seedUsers`, đoạn vòng lặp:
```ts
  for (const u of SEED_USERS) {
    const existing = await userModel.findOne({ username: u.username }).exec();
    if (existing) {
      logger.log(`${u.username} đã tồn tại — bỏ qua.`);
      continue;
    }
    const dto: CreateUserDto = {
      username: u.username,
      password: SEED_PASSWORD,
      name: u.name,
      role: u.role,
    };
    await usersService.create(dto, { sub: adminId, role: WmsRole.ADMIN });
    logger.log(`Tạo ${u.username} (${u.role}) / ${SEED_PASSWORD}`);
  }
```

(Toàn bộ phần còn lại của file — `seed()`, `seedWarehouseAndItems`, guard `require.main === module` — giữ nguyên 100%, không đổi.)

- [ ] **Step 2: Build kiểm tra**

Run: `pnpm exec tsc --noEmit -p apps/wms/tsconfig.app.json 2>&1 | grep "seed.ts" || echo "no errors in seed.ts"`
Expected: `no errors in seed.ts`

- [ ] **Step 3: Commit**

```bash
git add apps/wms/src/seed/seed.ts
git commit -m "feat(wms): seed dùng role đơn, thêm seed_shipper"
```

---

## Task 9: Ecommerce `Customer` — bỏ field `roles` dư thừa

**Files:**
- Modify: `apps/ecommerce/src/auth/schemas/user.schema.ts`
- Modify: `apps/ecommerce/src/auth/repositories/user.repository.ts`
- Modify: `apps/ecommerce/src/auth/auth.service.ts`
- Modify: `apps/ecommerce/src/auth/dto/auth.dto.ts`

**Interfaces:**
- Consumes: `JwtPayload.role` (Task 1), `EcomRole` từ `@app/auth`.
- Produces: `Customer` schema không còn field `roles`; `issueTokens` build `role` từ `user.type`.

- [ ] **Step 1: Xóa field `roles` khỏi schema**

```ts
// apps/ecommerce/src/auth/schemas/user.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

export enum UserStatus {
  ACTIVE = 'ACTIVE',
  LOCKED = 'LOCKED',
}

@Schema({ _id: true })
export class UserAddress {
  _id?: Types.ObjectId;

  @Prop({ required: true })
  label: string;

  @Prop({ required: true })
  recipientName: string;

  @Prop({ required: true })
  phone: string;

  @Prop({ required: true })
  line: string;

  @Prop({ required: true })
  ward: string;

  @Prop({ required: true })
  district: string;

  @Prop({ required: true })
  province: string;

  @Prop({ default: false })
  isDefault: boolean;
}

export const UserAddressSchema = SchemaFactory.createForClass(UserAddress);

@Schema({ collection: 'users', timestamps: true })
export class User {
  @Prop({ required: true, unique: true })
  email: string;

  @Prop({ unique: true, sparse: true })
  firebaseUid?: string;

  @Prop({ required: true, select: false })
  passwordHash: string;

  @Prop()
  name?: string;

  @Prop()
  phone?: string;

  @Prop({ default: false })
  emailVerified: boolean;

  @Prop({ enum: UserStatus, default: UserStatus.ACTIVE })
  status: UserStatus;

  @Prop({ type: [UserAddressSchema], default: [] })
  addresses: UserAddress[];

  @Prop({ type: String, enum: ['customer', 'admin'], default: 'customer' })
  type: 'customer' | 'admin';

  @Prop({ type: Date, default: null })
  deletedAt?: Date | null;
}

export type UserDocument = HydratedDocument<User>;
export const UserSchema = SchemaFactory.createForClass(User);
```

- [ ] **Step 2: Xóa `roles?` khỏi `CreateUserInput` (repository)**

```ts
// apps/ecommerce/src/auth/repositories/user.repository.ts — chỉ interface thay đổi
export interface CreateUserInput {
  email: string;
  firebaseUid?: string;
  passwordHash: string;
  name?: string;
  phone?: string;
  type?: 'customer' | 'admin';
  emailVerified?: boolean;
}
```

(Phần còn lại của file giữ nguyên 100%.)

- [ ] **Step 3: Sửa `auth.service.ts` — bỏ `roles` khi tạo user, suy `role` từ `type` trong `issueTokens`**

Trong `register()`, bỏ dòng `roles: ['customer'],` khỏi object truyền vào `userRepo.create`:
```ts
    const user = await this.userRepo.create({
      email: dto.email,
      passwordHash,
      name: dto.name,
      phone: dto.phone,
      type: 'customer',
    });
```

Trong `createEcomManager()`, bỏ dòng `roles: [EcomRole.ECOM_MANAGER],`:
```ts
    const user = await this.userRepo.create({
      email: dto.email,
      passwordHash,
      name: dto.name,
      phone: dto.phone,
      type: 'admin',
      emailVerified: true,
    });
```

Trong `googleLogin()`, đoạn tạo user mới (dòng ~163-171), bỏ `roles: ['customer'],`:
```ts
          const newUser = await this.userRepo.create({
            email,
            firebaseUid: decoded.uid,
            passwordHash: hash,
            name: typeof decoded.name === 'string' ? decoded.name : undefined,
            phone: decoded.phone_number ?? undefined,
            type: 'customer',
          });
```

Sửa `issueTokens` — suy `role` từ `user.type`:
```ts
  private async issueTokens(user: UserDocument) {
    const payload: JwtPayload = {
      sub: user._id.toString(),
      type: user.type,
      email: user.email,
      role: user.type === 'admin' ? EcomRole.ECOM_MANAGER : EcomRole.CUSTOMER,
    };
    const accessToken = await this.jwt.signAsync(payload, {
      secret: this.auth.jwtSecret,
      expiresIn: this.auth.jwtExpiresIn as MsDuration,
    });

    const refreshToken = generateOpaqueToken();
    const ttl = durationToMs(this.auth.refreshExpiresIn);
    await this.refreshRepo.create(
      user._id,
      hashToken(refreshToken),
      new Date(Date.now() + ttl),
    );

    return { accessToken, refreshToken };
  }
```

(`EcomRole` đã có sẵn trong import ở đầu file — `import { EcomRole } from '@app/auth';` — không cần thêm import mới.)

- [ ] **Step 4: Sửa `CustomerResponseDto` — bỏ field `roles`**

Trong `apps/ecommerce/src/auth/dto/auth.dto.ts`, xóa đoạn:
```ts
  @Expose()
  @ApiProperty({ type: [String], example: [] })
  roles!: string[];

```
(3 dòng ngay trước field `addresses!: AddressResponseDto[];` trong `CustomerResponseDto`, giữ nguyên `type!: string;` phía trên và `addresses` phía dưới.)

- [ ] **Step 5: Build kiểm tra**

Run: `pnpm exec tsc --noEmit -p apps/ecommerce/tsconfig.app.json 2>&1 | head -30`
Expected: 0 lỗi (không còn tham chiếu `roles` nào trong `apps/ecommerce/src/auth/`).

- [ ] **Step 6: Chạy test Ecommerce**

Run: `pnpm test -- apps/ecommerce`
Expected: PASS toàn bộ (không có spec nào tham chiếu `roles` theo rà soát ở bước brainstorm).

- [ ] **Step 7: Commit**

```bash
git add apps/ecommerce/src/auth/
git commit -m "refactor(ecom): bỏ field roles dư thừa trên Customer, suy role JWT từ type"
```

---

## Task 10: Kiểm tra toàn cục — build, lint, test suite đầy đủ

**Files:** không tạo/sửa file mới — chỉ chạy kiểm tra.

- [ ] **Step 1: Build toàn bộ 3 app**

Run: `pnpm exec nest build wms && pnpm exec nest build ecommerce && pnpm exec nest build notification`
Expected: cả 3 app build thành công, không lỗi TypeScript.

- [ ] **Step 2: Lint**

Run: `pnpm exec eslint apps/wms/src apps/ecommerce/src libs/auth/src`
Expected: 0 lỗi trong phạm vi các file đã sửa (bỏ qua lỗi tiền tồn tại ở file không liên quan như `scripts/test-checkout-paths.ts`, `apps/ecommerce/src/auth/auth.module.ts` FCM token — đã biết từ trước, không thuộc phạm vi plan này).

- [ ] **Step 3: Test toàn bộ 2 app**

Run: `pnpm test -- apps/wms apps/ecommerce`
Expected: PASS toàn bộ suite, không còn test nào tham chiếu `roles: string[]`/`roles: [...]` trên `User`/`Customer`/`Actor`.

- [ ] **Step 4: Grep xác nhận không còn sót field `roles` mảng nào trong scope**

Run: `grep -rn "roles" apps/wms/src apps/ecommerce/src libs/auth/src --include="*.ts" | grep -v ".spec.ts"`
Expected: Không còn kết quả nào (mọi field đã đổi sang `role` đơn). Nếu còn sót — quay lại task tương ứng sửa trước khi sang Task 11.

- [ ] **Step 5: Không commit gì ở task này (chỉ verification) — nếu phát hiện lỗi, sửa ở task tương ứng rồi mới sang Task 11**

---

## Task 11: Drop `wms_db` + `ecom_db` thật, chạy lại seed WMS

**Files:** không có file code — thao tác trực tiếp trên database qua `mongosh`.

> ⚠️ Thao tác này XÓA DỮ LIỆU THẬT, không thể hoàn tác. Chỉ chạy sau khi Task 10 xác nhận build+test+lint sạch.

- [ ] **Step 1: Đọc URI thật từ `.env`**

```bash
grep -E "WMS_DATABASE_URL|ECOM_DATABASE_URL" .env
```

Lấy 2 giá trị URI thật (không hard-code, không đoán). Nếu `.env` không tồn tại hoặc thiếu 1 trong 2 biến — DỪNG, báo lại cho user thay vì tự suy đoán connection string.

- [ ] **Step 2: Xác nhận đây là URI local/dev (không phải production)**

Kiểm tra bằng mắt: URI chứa `localhost`/`127.0.0.1`/tên host nội bộ quen thuộc — nếu URI trỏ tới cluster lạ hoặc có dấu hiệu production (tên domain công khai, cluster Atlas dùng chung với môi trường live), DỪNG và hỏi lại user trước khi drop.

- [ ] **Step 3: Drop `wms_db`**

```bash
mongosh "<WMS_DATABASE_URL>" --eval "db.dropDatabase()"
```

Expected output: `{ ok: 1, dropped: 'wms_db' }` (tên DB theo URI thật).

- [ ] **Step 4: Drop `ecom_db`**

```bash
mongosh "<ECOM_DATABASE_URL>" --eval "db.dropDatabase()"
```

Expected output: `{ ok: 1, dropped: 'ecom_db' }` (tên DB theo URI thật).

- [ ] **Step 5: Chạy seed WMS**

```bash
pnpm seed:wms
```

(Nếu script `seed:wms` chưa tồn tại trong `package.json`, kiểm tra tên script thật bằng `grep -n "seed" package.json` trước khi chạy — dùng đúng tên script đã khai báo, không đoán.)

Expected: log xuất hiện `Tạo admin: seed_admin / Seed@12345`, `Tạo seed_manager (MANAGER) / Seed@12345`, ... `Tạo seed_shipper (SHIPPER) / Seed@12345`, kết thúc bằng `Seed hoàn tất.`.

- [ ] **Step 6: Xác nhận nhanh qua `mongosh` — đếm số user trong `wms_db.users`**

```bash
mongosh "<WMS_DATABASE_URL>" --eval "db.users.countDocuments()"
```

Expected: `7` (1 admin + 6 role — manager/receiver/picker/printer/counter/shipper).

- [ ] **Step 7: Báo cáo lại user — không commit gì ở task này (thao tác DB, không phải code)**

---

## Self-Review Checklist (đã chạy khi viết plan)

1. **Spec coverage:** `libs/auth` (Task 1) → WMS `User`/`UserRepository` (Task 2) → WMS DTO (Task 3) → `UsersService` (Task 4) → `UsersController` (Task 5) → `AuthService`/specs liên quan (Task 6) → `SupplierService` (Task 7, điểm dùng `roles` mảng duy nhất ngoài `users/`) → seed WMS + `seed_shipper` (Task 8) → Ecommerce bỏ field `roles` dư thừa (Task 9) → kiểm tra toàn cục (Task 10) → drop DB + reseed (Task 11). Khớp đầy đủ với 5 mục "Quyết định thiết kế" trong spec.
2. **Placeholder scan:** không còn "TBD"/"tương tự Task N mà không kèm code". Mọi step code đều có nội dung đầy đủ (trừ vài chỗ trích đoạn rõ ràng ghi chú "chỉ phần thay đổi" kèm code cụ thể, không phải placeholder).
3. **Type consistency:** `Actor { sub: string; role: string }` nhất quán từ `UsersService` (Task 4) → `UsersController` (Task 5, khai inline cùng shape) → `AuthService.bootstrapAdmin` (Task 6) → seed (Task 8). `UserRepository.updateRole` (Task 2) khớp cách `UsersService.updateRole` gọi (Task 4) khớp cách `UsersController.updateRole` gọi (Task 5). `JwtPayload.role` (Task 1) khớp cách `AuthService.issueTokens` (WMS, Task 6) và Ecommerce `issueTokens` (Task 9) build payload, khớp cách `RolesGuard`/`@CurrentUser('role')` đọc (Task 1, Task 7).
