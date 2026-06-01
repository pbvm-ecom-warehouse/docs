# NestJS Monorepo — Kiến trúc & Auth

## 1. NestJS Monorepo Mode

Kiến trúc này là **NestJS Monorepo mode** — được NestJS hỗ trợ native, không cần tool bên ngoài (không cần Nx, Turborepo...).

### Cách hoạt động

```
nest-cli.json khai báo nhiều "projects"
       ↓
Mỗi app có main.ts riêng → build & deploy độc lập
Mỗi lib được map thành path alias → các app import dùng chung
```

### Path alias (tsconfig.json)

```json
{
  "compilerOptions": {
    "paths": {
      "@app/auth":         ["libs/auth/src"],
      "@app/database":     ["libs/database/src"],
      "@app/shared-types": ["libs/shared-types/src"],
      "@app/common":       ["libs/common/src"]
    }
  }
}
```

Import trong code:

```typescript
import { JwtAuthGuard } from '@app/auth';
import { PrismaService } from '@app/database';
import { CreateProductDto } from '@app/shared-types';
```

### Build & Run từng app riêng

```bash
# Build
nest build wms
nest build ecommerce
nest build notification

# Chạy development
nest start --watch wms
nest start --watch ecommerce

# Chạy production
node dist/apps/wms/main
node dist/apps/ecommerce/main
```

---

## 2. Auth Architecture

### Nguyên tắc: mỗi app có auth module riêng, chỉ share utilities

```
libs/auth/                            ← Utilities dùng chung (không có business logic)
├── decorators/
│   └── current-user.decorator.ts     ← @CurrentUser()
├── guards/
│   └── roles.guard.ts                ← @Roles() decorator + guard
└── interfaces/
    └── jwt-payload.interface.ts      ← Interface JWT payload

apps/wms/src/modules/auth/            ← Auth riêng cho Staff / Manager / Admin
├── auth.controller.ts
├── auth.service.ts
└── strategies/
    └── jwt.strategy.ts               ← Dùng WMS_JWT_SECRET

apps/ecommerce/src/modules/auth/      ← Auth riêng cho Khách hàng
├── auth.controller.ts
├── auth.service.ts
└── strategies/
    └── jwt.strategy.ts               ← Dùng ECOM_JWT_SECRET
```

### Phân loại user & collection

| Loại | App | Collection | JWT Secret |
|---|---|---|---|
| Staff / Manager / Admin | WMS | `users` | `WMS_JWT_SECRET` |
| Khách hàng | Ecommerce | `customers` | `ECOM_JWT_SECRET` |

> Dùng secret khác nhau → token của khách hàng không thể dùng được trong WMS và ngược lại.

### JWT Payload

```typescript
// WMS token — nhân viên nội bộ
type WmsRole = 'ADMIN' | 'MANAGER' | 'RECEIVER' | 'PICKER' | 'PRINTER' | 'COUNTER';

interface WmsJwtPayload {
  sub: string;      // userId
  roles: WmsRole[]; // user giữ nhiều role
  type: 'WMS';
}

// Ecommerce token — Khách hàng
interface EcomJwtPayload {
  sub: string;      // customerId
  email: string;
  type: 'CUSTOMER';
}
```

### Luồng login tách biệt

```
Staff/Manager  →  POST /api/wms/auth/login   →  WMS App    →  users collection
Khách hàng     →  POST /api/shop/auth/login  →  Ecommerce  →  customers collection
```

### Biến môi trường (.env)

```bash
# apps/wms/.env
WMS_JWT_SECRET=<secret_riêng_cho_wms>
WMS_JWT_EXPIRES_IN=8h

# apps/ecommerce/.env
ECOM_JWT_SECRET=<secret_riêng_cho_ecom>
ECOM_JWT_EXPIRES_IN=30d
```

> WMS dùng thời hạn ngắn (8h) vì là hệ thống nội bộ, nhân viên login mỗi ca.
> Ecommerce dùng thời hạn dài hơn (30d) để khách hàng không phải login lại thường xuyên.

### Cách dùng Guard trong WMS app

```typescript
// apps/wms/src/modules/warehouse/warehouse.controller.ts
import { JwtAuthGuard } from './strategies/jwt-auth.guard';
import { RolesGuard } from '@app/auth';
import { Roles } from '@app/auth';

@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('MANAGER', 'ADMIN')
@Post('purchase-orders')
createPurchaseOrder(@Body() dto: CreatePurchaseOrderDto) { ... }

// RolesGuard cho qua nếu user.roles chứa ít nhất một role liệt kê (ADMIN luôn bypass)
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('RECEIVER')
@Post('grn')
createGRN(@Body() dto: CreateGRNDto) { ... }
```

```typescript
// apps/ecommerce/src/modules/order/order.controller.ts
import { JwtAuthGuard } from './strategies/jwt-auth.guard';
import { CurrentUser } from '@app/auth';

@UseGuards(JwtAuthGuard)
@Post('orders')
createOrder(
  @CurrentUser() customer: EcomJwtPayload,
  @Body() dto: CreateOrderDto
) { ... }
```
