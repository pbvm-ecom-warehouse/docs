# Planning: Auth WMS + Auth Ecom

> Ngay truoc khi code 2 phan auth, can bam theo tai lieu `docs/auth-wms`, `docs/auth-ecom` va rule kien truc trong `be-wms-ecom/.codex/rules`.

## 1. Nguon doc da doc

- `docs/auth-wms/use-cases.md`, `workflow.md`, `data-model.md`
- `docs/auth-ecom/use-cases.md`, `workflow.md`, `data-model.md`
- `be-wms-ecom/.codex/rules/architecture.md`
- `be-wms-ecom/.codex/rules/auth-and-modules.md`
- `be-wms-ecom/.codex/rules/data-and-mongoose.md`
- `be-wms-ecom/.codex/rules/events.md`
- Code hien co trong `be-wms-ecom/apps/wms/src/auth`, `be-wms-ecom/apps/ecommerce/src/auth`, `libs/auth`, `libs/events`

## 2. Nguyen tac kien truc bat buoc

- Monorepo NestJS, tach app:
  - WMS: `apps/wms`, prefix `/api/wms`, DB `wms_db`, env `WMS_DATABASE_URL`.
  - Ecommerce: `apps/ecommerce`, prefix `/api/shop`, DB `ecom_db`, env `ECOM_DATABASE_URL`.
- Khong doc cheo DB, khong HTTP cheo app. Neu can dong bo/thong bao thi di qua `libs/events` + BullMQ/Redis.
- Auth tach rieng moi app:
  - WMS staff dung collection `users`, `user_refresh_tokens`, JWT secret `WMS_JWT_SECRET`, claim `type = user`.
  - Ecom customer dung `customers`, `customer_refresh_tokens`, `customer_auth_tokens`, JWT secret `ECOM_JWT_SECRET`, claim `type = customer`.
  - Ecom admin/back-office neu lam thi dung `admin_users`, `admin_refresh_tokens` trong `ecom_db`, khong dung `wms_db.users`.
- `libs/auth` chi chua utility chung: `JwtAuthGuard`, `RolesGuard`, decorator, JWT payload interface. Business logic phai nam trong auth module cua tung app.
- Mongoose schema dat trong `apps/<app>/src/<domain>/schemas`, collection dung snake_case cu, token collection co `createdAt` + `revokedAt`/`usedAt`.
- Refresh token phai la opaque token, DB chi luu hash, refresh phai rotate token va revoke token cu.

## 3. Trang thai code hien co

### WMS auth da co

- `login(username, password)` cap `accessToken`, `refreshToken`, tra `mustChangePassword`.
- `refresh(refreshToken)` validate hash, rotate refresh.
- `logout(refreshToken)` revoke refresh hien tai.
- `me(userId)` doc user active.
- `bootstrap-admin` chi cho phep khi DB chua co user.
- `createUser` cho ADMIN tao user co roles.
- Schema da co `User`, `UserRefreshToken`; repository da co.

### WMS auth con thieu/nen sua

- DTO/schema `CreateUserDto` chua expose `email`; data model co `email`.
- `createUser` dang khong set `mustChangePassword = true` theo UC-AW01.
- Chua co UC-AW02: gan/sua roles.
- Chua co UC-AW03: khoa/mo khoa user va revoke tat ca refresh khi khoa.
- Chua co UC-AW04: admin reset mat khau tam, set `mustChangePassword = true`, revoke tat ca refresh.
- Chua co UC-AW07: nhan vien doi mat khau, set `mustChangePassword = false`.
- Chua co endpoint/list/detail user cho admin neu can quan tri.
- Guard hien tai can kiem tra token `type = user` cho WMS route, tranh token customer cua Ecom di nham neu secret/config sai.

### Ecom auth da co

- `register(email, password, name, phone)` tao customer, phat `customer.verify_requested`, cap access/refresh.
- `login(email, password)` cap access/refresh, tra `emailVerified`.
- `refresh(refreshToken)` rotate refresh.
- `logout(refreshToken)` revoke refresh hien tai.
- `me(customerId)` doc customer active.
- Schema da co `Customer`, `CustomerRefreshToken`, `CustomerAuthToken`; repository da co.
- Event contract da co:
  - `customer.verify_requested`
  - `customer.password_reset_requested`

### Ecom auth con thieu/nen sua

- Chua co UC-AE05: verify email bang token, set `emailVerified = true`, set `usedAt`.
- Chua co resend verify email khi token het han/chua verify.
- Chua co UC-AE06: forgot password, tao token `RESET_PASSWORD`, phat event trung tinh.
- Chua co UC-AE07: reset password bang token, set `usedAt`, doi `passwordHash`, revoke tat ca refresh cua customer.
- Chua co UC-AE08: doi mat khau khi da login.
- Chua co UC-AE09: address book embedded trong `customers.addresses`.
- Schema `Customer` chua co `addresses`.
- Guard hien tai can kiem tra token `type = customer` cho Ecom customer route.
- Neu lam Ecom admin/back-office trong cung lan code thi can them rieng `admin_users`, `admin_refresh_tokens`; tuy nhien docs auth-ecom customer la phan uu tien, nen nen tach task admin-ecom neu user khong yeu cau.

## 4. Pham vi de code trong lan toi

### Phase 1: Chot utility chung va bao ve route

- Cap nhat JWT payload/type guard:
  - WMS route chi chap nhan `type = user`.
  - Ecom customer route chi chap nhan `type = customer`.
- Giu `RolesGuard` cho WMS role: `ADMIN` bypass, user co it nhat mot role yeu cau thi pass.
- Dam bao response khong bao gio tra `passwordHash` hoac token hash.

### Phase 2: Hoan thien Auth-WMS

- DTO:
  - Them `email` vao `CreateUserDto`.
  - Them `UpdateUserRolesDto`.
  - Them `UpdateUserStatusDto` hoac endpoint lock/unlock rieng.
  - Them `ResetUserPasswordDto`.
  - Them `ChangePasswordDto`.
- Service:
  - `createUser`: set `mustChangePassword = true`, luu email neu co.
  - `updateRoles(userId, roles, actorId)`.
  - `lockUser(userId, actorId)`: set `status = LOCKED`, `updatedBy`, revoke all refresh.
  - `unlockUser(userId, actorId)`: set `status = ACTIVE`.
  - `resetTemporaryPassword(userId, temporaryPassword, actorId)`: hash password, set `mustChangePassword = true`, revoke all refresh.
  - `changePassword(userId, oldPassword, newPassword)`: verify old password, doi hash, set `mustChangePassword = false`.
- Repository:
  - Them update roles/status/password.
  - Them revoke all refresh tokens by user.
- Controller:
  - `PATCH /auth/users/:id/roles` ADMIN.
  - `POST /auth/users/:id/lock` ADMIN.
  - `POST /auth/users/:id/unlock` ADMIN.
  - `POST /auth/users/:id/reset-password` ADMIN.
  - `POST /auth/change-password` JWT user.
- Test:
  - Login thanh cong/sai password.
  - Refresh rotate va token cu khong dung lai duoc.
  - Locked user khong login/refresh duoc.
  - Reset password revoke refresh cu va bat `mustChangePassword`.
  - Change password ha `mustChangePassword`.

### Phase 3: Hoan thien Auth-Ecom

- Schema:
  - Them embedded `addresses` vao `Customer`.
  - Dam bao address co `label`, `recipientName`, `phone`, `line`, `ward`, `district`, `province`, `isDefault`.
- DTO:
  - `VerifyEmailDto` hoac token route param/body.
  - `ForgotPasswordDto`.
  - `ResetPasswordDto`.
  - `ChangePasswordDto`.
  - `CreateAddressDto`, `UpdateAddressDto`, `SetDefaultAddressDto`.
- Service:
  - `verifyEmail(token)`: hash token, tim valid `VERIFY_EMAIL`, set customer verified, set `usedAt`.
  - `resendVerifyEmail(customerId/email)`: chi gui neu chua verified.
  - `forgotPassword(email)`: neu email ton tai tao `RESET_PASSWORD`, emit `customer.password_reset_requested`; luon tra message trung tinh.
  - `resetPassword(token, newPassword)`: validate token, doi hash, set `usedAt`, revoke all refresh.
  - `changePassword(customerId, oldPassword, newPassword)`.
  - Address book CRUD, giu invariant toi da 1 default; neu dia chi dau tien thi auto default.
- Repository:
  - Find auth token by hash/type and valid state.
  - Mark token used.
  - Revoke all customer refresh tokens.
  - Address update atomic theo customer.
- Controller:
  - `POST /auth/verify-email`.
  - `POST /auth/resend-verify-email`.
  - `POST /auth/forgot-password`.
  - `POST /auth/reset-password`.
  - `POST /auth/change-password`.
  - `GET/POST/PATCH/DELETE /auth/addresses...` hoac tach `customer` module neu muon sach domain hon.
- Test:
  - Register phat verify event va token DB chi luu hash.
  - Verify email dung token mot lan.
  - Forgot password khong lo email ton tai.
  - Reset password revoke refresh cu.
  - Address default invariant.

## 5. Thu tu code de it rui ro

1. Them/cung co repository method cho revoke-all, token lookup, update user/customer.
2. Them DTO + schema field con thieu.
3. Implement service method truoc, giu transaction cuc bo trong tung DB neu can.
4. Them controller endpoint va Swagger decorator.
5. Cap nhat guard/strategy de check dung `type`.
6. Them unit/e2e tests cho duong token va revoke.
7. Chay:
   - `pnpm test`
   - `pnpm test:e2e` neu env Mongo/Redis san sang
   - `pnpm build wms`
   - `pnpm build ecommerce`

## 6. Cau hoi can chot truoc khi code

- Auth-Ecom lan nay chi lam customer auth hay lam luon admin/back-office `admin_users`?
- Address book nen nam trong `auth` controller theo docs UC-AE09, hay tach module `customers` de sau nay de mo rong profile?
- TTL thuc te cho access/refresh token se theo env hien co; docs noi access ngan, refresh 7-30 ngay. Can giu env hay doi default?
- Reset password customer trong docs co noi 15 phut o use-case va 1 gio o workflow/data-model. Nen chot 1 gia tri, de xuat: 1 gio theo data-model/workflow.

## 7. Definition of Done

- WMS cover UC-AW01 den UC-AW07.
- Ecom customer cover UC-AE01 den UC-AE09, tru admin-ecom neu duoc tach scope.
- Token rotate/revoke dung, DB khong luu plaintext refresh/reset/verify token.
- Token WMS va Ecom khong dung cheo route.
- Event email verify/reset chi di qua `QUEUES.NOTIFICATION`, khong gui email truc tiep trong auth service.
- Build/test auth lien quan pass hoac neu khong chay duoc thi ghi ro ly do/env thieu.
