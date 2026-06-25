# Ecommerce Week 1 — Catalog Full + Cart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Xây dựng Catalog API đầy đủ (Category/Product/ProductVariant/Design) + Cart, giữ nguyên consumer `stock.changed` đang hoạt động.

**Architecture:** Mở rộng `CatalogModule` hiện có (đang là stub consumer) thêm schemas Category/Product/Design + services + controllers. Tạo `CartModule` mới song song. Events lib (`libs/events`) đã đủ — không cần thêm. Không dùng Prisma, chỉ Mongoose per-app.

**Tech Stack:** NestJS, Mongoose (`@nestjs/mongoose`), BullMQ (`@nestjs/bullmq`), `@nestjs/swagger`, class-validator, `@app/auth` (JwtAuthGuard + CurrentUser), `@app/common` (AuthThrottle)

## Global Constraints

- App prefix: `api/shop` (xem `apps/ecommerce/src/main.ts`)
- Mọi schema đặt trong `apps/ecommerce/src/<module>/schemas/*.schema.ts`
- `@Schema({ collection: 'snake_case_name', timestamps: true })`
- Không import chéo giữa apps — chỉ dùng `@app/*` libs
- Comment tiếng Việt giải thích *vì sao* (không chỉ *cái gì*)
- Mỗi module phải có `MongooseModule.forFeature([...])` riêng
- Admin routes bắt buộc guard `JwtAuthGuard` + kiểm `type === 'admin'` trong JWT payload
- Public routes không cần auth (browse catalog)
- Cart routes bắt buộc `JwtAuthGuard` (đã đăng nhập mới có giỏ)

---

## File Structure (tạo mới / sửa)

```
apps/ecommerce/src/
├── catalog/
│   ├── schemas/
│   │   ├── product-variant.schema.ts   [SỬA — bổ sung fields đầy đủ]
│   │   ├── category.schema.ts          [TẠO MỚI]
│   │   ├── product.schema.ts           [TẠO MỚI]
│   │   └── design.schema.ts            [TẠO MỚI]
│   ├── dto/
│   │   ├── category.dto.ts             [TẠO MỚI]
│   │   ├── product.dto.ts              [TẠO MỚI]
│   │   └── design.dto.ts               [TẠO MỚI]
│   ├── catalog.repository.ts           [SỬA — thêm methods cho Category/Product/Design]
│   ├── catalog.service.ts              [TẠO MỚI]
│   ├── catalog.controller.ts           [TẠO MỚI — public + admin routes]
│   ├── stock.consumer.ts               [GIỮ NGUYÊN]
│   └── catalog.module.ts               [SỬA — đăng ký schemas mới + service + controller]
├── cart/
│   ├── schemas/
│   │   └── cart.schema.ts              [TẠO MỚI]
│   ├── dto/
│   │   └── cart.dto.ts                 [TẠO MỚI]
│   ├── cart.repository.ts              [TẠO MỚI]
│   ├── cart.service.ts                 [TẠO MỚI]
│   ├── cart.controller.ts              [TẠO MỚI]
│   └── cart.module.ts                  [TẠO MỚI]
└── ecommerce.module.ts                 [SỬA — import CartModule]
```

---

## Task E1-01: Mở rộng Schema ProductVariant + Tạo Category/Product/Design schemas

**Files:**
- Modify: `apps/ecommerce/src/catalog/schemas/product-variant.schema.ts`
- Create: `apps/ecommerce/src/catalog/schemas/category.schema.ts`
- Create: `apps/ecommerce/src/catalog/schemas/product.schema.ts`
- Create: `apps/ecommerce/src/catalog/schemas/design.schema.ts`

**Interfaces:**
- Produces: `Category`, `Product`, `ProductVariant` (mở rộng), `Design` — schemas Mongoose để các task sau dùng

- [ ] **Step 1: Mở rộng ProductVariant schema**

Hiện tại schema chỉ có `sku` + `availableQty`. Bổ sung đầy đủ theo spec:

```typescript
// apps/ecommerce/src/catalog/schemas/product-variant.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

export enum FulfillmentType {
  STANDARD = 'STANDARD',
  PRINTED_TEMPLATE = 'PRINTED_TEMPLATE',
  CUSTOM_PRINT = 'CUSTOM_PRINT',
}

/**
 * Biến thể sản phẩm — mỗi variant gắn với 1 SKU WMS duy nhất.
 * `availableQty` là bản copy WMS sync qua event `stock.changed` (match theo sku).
 * `fulfillmentType` quyết định luồng đặt hàng: STANDARD/PRINTED_TEMPLATE mua như hàng thường,
 * CUSTOM_PRINT bắt buộc kèm design (make-to-order, chỉ thanh toán ONLINE).
 */
@Schema({ collection: 'product_variants', timestamps: true })
export class ProductVariant {
  @Prop({ required: true, unique: true, index: true })
  sku: string;

  @Prop({ required: true, type: Types.ObjectId, index: true })
  productId: Types.ObjectId;

  /** Phân biệt biến thể, ví dụ: { size: 'M' } */
  @Prop({ type: Object, default: {} })
  attributes: Record<string, string>;

  @Prop({ required: true, min: 0 })
  price: number;

  /** Bản copy WMS — cập nhật qua consumer stock.changed */
  @Prop({ default: 0 })
  availableQty: number;

  @Prop({ enum: FulfillmentType, default: FulfillmentType.STANDARD })
  fulfillmentType: FulfillmentType;

  @Prop({ default: true })
  isActive: boolean;
}

export type ProductVariantDocument = HydratedDocument<ProductVariant>;
export const ProductVariantSchema = SchemaFactory.createForClass(ProductVariant);
```

- [ ] **Step 2: Tạo Category schema**

```typescript
// apps/ecommerce/src/catalog/schemas/category.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

/**
 * Cây danh mục — tự tham chiếu qua parentId.
 * Null parentId = danh mục gốc (root). position dùng sắp thứ tự hiển thị.
 */
@Schema({ collection: 'categories', timestamps: true })
export class Category {
  @Prop({ required: true })
  name: string;

  /** URL-friendly, unique trên toàn bộ categories */
  @Prop({ required: true, unique: true, index: true })
  slug: string;

  /** Null = root category */
  @Prop({ type: Types.ObjectId, default: null, index: true })
  parentId: Types.ObjectId | null;

  /** Thứ tự hiển thị giữa các siblings */
  @Prop({ default: 0 })
  position: number;
}

export type CategoryDocument = HydratedDocument<Category>;
export const CategorySchema = SchemaFactory.createForClass(Category);
```

- [ ] **Step 3: Tạo Product schema**

```typescript
// apps/ecommerce/src/catalog/schemas/product.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

export enum ProductStatus {
  DRAFT = 'DRAFT',
  ACTIVE = 'ACTIVE',
  HIDDEN = 'HIDDEN',
}

class SeoMeta {
  title: string;
  description: string;
  keywords: string[];
}

/**
 * Entity marketing — là "bìa sách" cho các ProductVariant.
 * Chỉ status=ACTIVE mới hiện ở storefront. DRAFT để soạn thảo, HIDDEN để ẩn tạm.
 */
@Schema({ collection: 'products', timestamps: true })
export class Product {
  @Prop({ required: true })
  name: string;

  @Prop({ required: true, unique: true, index: true })
  slug: string;

  @Prop({ default: '' })
  description: string;

  @Prop({ type: [String], default: [] })
  images: string[];

  @Prop({ required: true, type: Types.ObjectId, index: true })
  categoryId: Types.ObjectId;

  @Prop({ enum: ProductStatus, default: ProductStatus.DRAFT, index: true })
  status: ProductStatus;

  @Prop({ type: Object, default: {} })
  seo: SeoMeta;
}

export type ProductDocument = HydratedDocument<Product>;
export const ProductSchema = SchemaFactory.createForClass(Product);
```

- [ ] **Step 4: Tạo Design schema**

```typescript
// apps/ecommerce/src/catalog/schemas/design.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

/**
 * Thư viện design của khách — upload 1 lần, tái dùng nhiều đơn.
 * Khi khách chọn variant CUSTOM_PRINT: upload mới hoặc chọn từ thư viện này.
 * lastUsedAt cập nhật mỗi lần tái dùng → sắp xếp "dùng gần đây" khi hiển thị.
 */
@Schema({ collection: 'designs', timestamps: true })
export class Design {
  /** Chỉ chủ sở hữu mới thấy/dùng design này */
  @Prop({ required: true, type: Types.ObjectId, index: true })
  customerId: Types.ObjectId;

  @Prop({ required: true })
  name: string;

  /** URL file gốc (artwork) — lưu sau khi upload thành công */
  @Prop({ required: true })
  file: string;

  /** URL ảnh xem trước (thumbnail) */
  @Prop({ default: '' })
  thumbnail: string;

  /** Cập nhật mỗi lần khách dùng lại design → dùng để sort "gần đây nhất" */
  @Prop({ default: null })
  lastUsedAt: Date | null;
}

export type DesignDocument = HydratedDocument<Design>;
export const DesignSchema = SchemaFactory.createForClass(Design);
```

- [ ] **Step 5: Verify TypeScript compile**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm build 2>&1 | head -50
```
Expected: Không có lỗi TypeScript liên quan đến catalog/schemas.

- [ ] **Step 6: Commit**

```bash
git add apps/ecommerce/src/catalog/schemas/
git commit -m "feat(ecom-catalog): mở rộng ProductVariant + tạo Category/Product/Design schemas"
```

---

## Task E1-02: DTOs cho Catalog (Category, Product, Variant, Design)

**Files:**
- Create: `apps/ecommerce/src/catalog/dto/category.dto.ts`
- Create: `apps/ecommerce/src/catalog/dto/product.dto.ts`
- Create: `apps/ecommerce/src/catalog/dto/design.dto.ts`

**Interfaces:**
- Consumes: `FulfillmentType`, `ProductStatus` từ schemas
- Produces: DTOs dùng trong controller/service

- [ ] **Step 1: Tạo category.dto.ts**

```typescript
// apps/ecommerce/src/catalog/dto/category.dto.ts
import { ApiProperty, ApiPropertyOptional, PartialType } from '@nestjs/swagger';
import { IsNotEmpty, IsNumber, IsOptional, IsString, Matches } from 'class-validator';

export class CreateCategoryDto {
  @ApiProperty({ example: 'Ly nhựa' })
  @IsString()
  @IsNotEmpty()
  name: string;

  /** slug phải là lowercase-kebab, dùng cho URL */
  @ApiProperty({ example: 'ly-nhua' })
  @IsString()
  @Matches(/^[a-z0-9]+(?:-[a-z0-9]+)*$/, { message: 'slug phải là lowercase-kebab-case' })
  slug: string;

  @ApiPropertyOptional({ example: null, description: 'null = root category' })
  @IsOptional()
  @IsString()
  parentId?: string;

  @ApiPropertyOptional({ example: 0 })
  @IsOptional()
  @IsNumber()
  position?: number;
}

export class UpdateCategoryDto extends PartialType(CreateCategoryDto) {}
```

- [ ] **Step 2: Tạo product.dto.ts**

```typescript
// apps/ecommerce/src/catalog/dto/product.dto.ts
import { ApiProperty, ApiPropertyOptional, PartialType } from '@nestjs/swagger';
import {
  IsArray,
  IsEnum,
  IsNotEmpty,
  IsNumber,
  IsObject,
  IsOptional,
  IsString,
  Matches,
  Min,
} from 'class-validator';
import { FulfillmentType, ProductStatus } from '../schemas/product.schema';
import { FulfillmentType as FT } from '../schemas/product-variant.schema';

export class SeoDto {
  @IsString() @IsOptional() title?: string;
  @IsString() @IsOptional() description?: string;
  @IsArray() @IsOptional() keywords?: string[];
}

export class CreateProductDto {
  @ApiProperty({ example: 'Ly nhựa in custom' })
  @IsString() @IsNotEmpty()
  name: string;

  @ApiProperty({ example: 'ly-nhua-in-custom' })
  @IsString()
  @Matches(/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
  slug: string;

  @ApiPropertyOptional()
  @IsString() @IsOptional()
  description?: string;

  @ApiPropertyOptional({ type: [String] })
  @IsArray() @IsOptional()
  images?: string[];

  @ApiProperty({ example: '64abc...' })
  @IsString() @IsNotEmpty()
  categoryId: string;

  @ApiPropertyOptional({ enum: ProductStatus })
  @IsEnum(ProductStatus) @IsOptional()
  status?: ProductStatus;

  @ApiPropertyOptional()
  @IsObject() @IsOptional()
  seo?: SeoDto;
}

export class UpdateProductDto extends PartialType(CreateProductDto) {}

export class CreateVariantDto {
  @ApiProperty({ example: 'CUP-M-001' })
  @IsString() @IsNotEmpty()
  sku: string;

  @ApiProperty({ example: '64abc...' })
  @IsString() @IsNotEmpty()
  productId: string;

  @ApiPropertyOptional({ example: { size: 'M' } })
  @IsObject() @IsOptional()
  attributes?: Record<string, string>;

  @ApiProperty({ example: 15000 })
  @IsNumber() @Min(0)
  price: number;

  @ApiPropertyOptional({ enum: FT })
  @IsEnum(FT) @IsOptional()
  fulfillmentType?: FT;
}

export class UpdateVariantDto extends PartialType(CreateVariantDto) {}

export class ProductQueryDto {
  @ApiPropertyOptional({ example: 'ly' })
  @IsString() @IsOptional()
  q?: string;

  @ApiPropertyOptional({ example: '64abc...' })
  @IsString() @IsOptional()
  categoryId?: string;

  @ApiPropertyOptional({ example: 10000 })
  @IsNumber() @IsOptional() @Min(0)
  minPrice?: number;

  @ApiPropertyOptional({ example: 100000 })
  @IsNumber() @IsOptional()
  maxPrice?: number;

  /** Chỉ lấy sản phẩm còn hàng (availableQty > 0 ít nhất 1 variant) */
  @ApiPropertyOptional({ example: true })
  @IsOptional()
  inStock?: boolean;
}
```

- [ ] **Step 3: Tạo design.dto.ts**

```typescript
// apps/ecommerce/src/catalog/dto/design.dto.ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsNotEmpty, IsOptional, IsString } from 'class-validator';

export class CreateDesignDto {
  @ApiProperty({ example: 'Logo công ty ABC' })
  @IsString() @IsNotEmpty()
  name: string;

  /** URL file artwork sau khi đã upload lên storage */
  @ApiProperty({ example: 'https://storage.example.com/designs/abc.png' })
  @IsString() @IsNotEmpty()
  file: string;

  @ApiPropertyOptional({ example: 'https://storage.example.com/thumbnails/abc.jpg' })
  @IsString() @IsOptional()
  thumbnail?: string;
}
```

- [ ] **Step 4: Commit**

```bash
git add apps/ecommerce/src/catalog/dto/
git commit -m "feat(ecom-catalog): DTOs Category, Product, Variant, Design"
```

---

## Task E1-03: CatalogRepository — thêm CRUD methods

**Files:**
- Modify: `apps/ecommerce/src/catalog/catalog.repository.ts`

**Interfaces:**
- Consumes: `Category`, `Product`, `ProductVariant`, `Design` schemas
- Produces: Methods `createCategory`, `listCategories`, `createProduct`, `listProducts`, `getProductBySlug`, `createVariant`, `listVariantsByProduct`, `createDesign`, `listDesignsByCustomer`, `deleteDesign`

- [ ] **Step 1: Bổ sung toàn bộ repository**

Giữ nguyên `applyStockDeltaOnce` hiện có, thêm các methods mới:

```typescript
// apps/ecommerce/src/catalog/catalog.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectConnection, InjectModel } from '@nestjs/mongoose';
import { Connection, FilterQuery, Model, Types } from 'mongoose';
import { ProcessedEvent } from './schemas/processed-event.schema';
import { ProductVariant } from './schemas/product-variant.schema';
import { Category } from './schemas/category.schema';
import { Product, ProductStatus } from './schemas/product.schema';
import { Design } from './schemas/design.schema';
import { ProductQueryDto } from './dto/product.dto';

const DUPLICATE_KEY = 11000;

@Injectable()
export class CatalogRepository {
  constructor(
    @InjectConnection() private readonly conn: Connection,
    @InjectModel(ProductVariant.name) private readonly variantModel: Model<ProductVariant>,
    @InjectModel(ProcessedEvent.name) private readonly processedModel: Model<ProcessedEvent>,
    @InjectModel(Category.name) private readonly categoryModel: Model<Category>,
    @InjectModel(Product.name) private readonly productModel: Model<Product>,
    @InjectModel(Design.name) private readonly designModel: Model<Design>,
  ) {}

  // ── STOCK SYNC (giữ nguyên) ───────────────────────────────────────────────

  async applyStockDeltaOnce(
    jobId: string,
    eventName: string,
    sku: string,
    delta: number,
  ): Promise<boolean> {
    const session = await this.conn.startSession();
    try {
      await session.withTransaction(async () => {
        await this.processedModel.create([{ jobId, eventName }], { session });
        await this.variantModel.updateMany(
          { sku },
          { $inc: { availableQty: delta } },
          { session },
        );
      });
      return true;
    } catch (err: unknown) {
      if ((err as { code?: number })?.code === DUPLICATE_KEY) return false;
      throw err;
    } finally {
      await session.endSession();
    }
  }

  // ── CATEGORY ─────────────────────────────────────────────────────────────

  async createCategory(data: Partial<Category>) {
    return this.categoryModel.create(data);
  }

  async listCategories(parentId?: string | null) {
    const filter: FilterQuery<Category> = parentId !== undefined
      ? { parentId: parentId ? new Types.ObjectId(parentId) : null }
      : {};
    return this.categoryModel.find(filter).sort({ position: 1 }).lean();
  }

  async updateCategory(id: string, data: Partial<Category>) {
    return this.categoryModel.findByIdAndUpdate(id, data, { new: true }).lean();
  }

  async deleteCategory(id: string) {
    return this.categoryModel.findByIdAndDelete(id).lean();
  }

  // ── PRODUCT ───────────────────────────────────────────────────────────────

  async createProduct(data: Partial<Product>) {
    return this.productModel.create(data);
  }

  async listProducts(query: ProductQueryDto) {
    const filter: FilterQuery<Product> = { status: ProductStatus.ACTIVE };
    if (query.categoryId) filter.categoryId = new Types.ObjectId(query.categoryId);
    if (query.q) filter.name = { $regex: query.q, $options: 'i' };

    const products = await this.productModel.find(filter).lean();

    // Nếu lọc theo giá hoặc còn-hàng, cần join variants
    if (query.minPrice !== undefined || query.maxPrice !== undefined || query.inStock) {
      const productIds = products.map((p) => p._id);
      const variantFilter: FilterQuery<ProductVariant> = {
        productId: { $in: productIds },
        isActive: true,
      };
      if (query.minPrice !== undefined) variantFilter.price = { $gte: query.minPrice };
      if (query.maxPrice !== undefined) {
        variantFilter.price = { ...variantFilter.price, $lte: query.maxPrice };
      }
      if (query.inStock) variantFilter.availableQty = { $gt: 0 };

      const validVariants = await this.variantModel.find(variantFilter).select('productId').lean();
      const validProductIds = new Set(validVariants.map((v) => v.productId.toString()));
      return products.filter((p) => validProductIds.has(p._id.toString()));
    }

    return products;
  }

  async getProductBySlug(slug: string) {
    return this.productModel.findOne({ slug, status: ProductStatus.ACTIVE }).lean();
  }

  async getProductById(id: string) {
    return this.productModel.findById(id).lean();
  }

  async updateProduct(id: string, data: Partial<Product>) {
    return this.productModel.findByIdAndUpdate(id, data, { new: true }).lean();
  }

  // ── PRODUCT VARIANT ───────────────────────────────────────────────────────

  async createVariant(data: Partial<ProductVariant>) {
    return this.variantModel.create(data);
  }

  async listVariantsByProduct(productId: string) {
    return this.variantModel
      .find({ productId: new Types.ObjectId(productId), isActive: true })
      .lean();
  }

  async updateVariant(id: string, data: Partial<ProductVariant>) {
    return this.variantModel.findByIdAndUpdate(id, data, { new: true }).lean();
  }

  async findVariantBySku(sku: string) {
    return this.variantModel.findOne({ sku, isActive: true }).lean();
  }

  // ── DESIGN ────────────────────────────────────────────────────────────────

  async createDesign(data: Partial<Design>) {
    return this.designModel.create(data);
  }

  async listDesignsByCustomer(customerId: string) {
    return this.designModel
      .find({ customerId: new Types.ObjectId(customerId) })
      .sort({ lastUsedAt: -1, createdAt: -1 })
      .lean();
  }

  async findDesign(id: string, customerId: string) {
    return this.designModel
      .findOne({ _id: new Types.ObjectId(id), customerId: new Types.ObjectId(customerId) })
      .lean();
  }

  async deleteDesign(id: string, customerId: string) {
    return this.designModel
      .findOneAndDelete({ _id: new Types.ObjectId(id), customerId: new Types.ObjectId(customerId) })
      .lean();
  }

  async touchDesign(id: string) {
    return this.designModel.findByIdAndUpdate(id, { lastUsedAt: new Date() }).lean();
  }
}
```

- [ ] **Step 2: Compile check**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm build 2>&1 | grep -E "(ERROR|error TS)" | head -20
```
Expected: Không có lỗi TypeScript.

- [ ] **Step 3: Commit**

```bash
git add apps/ecommerce/src/catalog/catalog.repository.ts
git commit -m "feat(ecom-catalog): CatalogRepository bổ sung CRUD Category/Product/Variant/Design"
```

---

## Task E1-04: CatalogService + CatalogController (Public + Admin APIs)

**Files:**
- Create: `apps/ecommerce/src/catalog/catalog.service.ts`
- Create: `apps/ecommerce/src/catalog/catalog.controller.ts`
- Modify: `apps/ecommerce/src/catalog/catalog.module.ts`

**Interfaces:**
- Consumes: `CatalogRepository`, DTOs
- Produces: REST API tại `/api/shop/catalog/*` (public) và `/api/shop/admin/catalog/*` (admin)

- [ ] **Step 1: Tạo CatalogService**

```typescript
// apps/ecommerce/src/catalog/catalog.service.ts
import { ConflictException, ForbiddenException, Injectable, NotFoundException } from '@nestjs/common';
import { CatalogRepository } from './catalog.repository';
import { CreateCategoryDto, UpdateCategoryDto } from './dto/category.dto';
import { CreateProductDto, CreateVariantDto, ProductQueryDto, UpdateProductDto, UpdateVariantDto } from './dto/product.dto';
import { CreateDesignDto } from './dto/design.dto';
import { ProductStatus } from './schemas/product.schema';

@Injectable()
export class CatalogService {
  constructor(private readonly repo: CatalogRepository) {}

  // ── CATEGORY ─────────────────────────────────────────────────────────────

  async createCategory(dto: CreateCategoryDto) {
    return this.repo.createCategory({
      name: dto.name,
      slug: dto.slug,
      parentId: dto.parentId ? (dto.parentId as any) : null,
      position: dto.position ?? 0,
    });
  }

  async listCategories(parentId?: string) {
    // parentId='root' → lấy root (parentId=null); không truyền → lấy tất cả
    if (parentId === 'root') return this.repo.listCategories(null);
    return this.repo.listCategories(parentId);
  }

  async updateCategory(id: string, dto: UpdateCategoryDto) {
    const updated = await this.repo.updateCategory(id, dto as any);
    if (!updated) throw new NotFoundException('Danh mục không tồn tại');
    return updated;
  }

  async deleteCategory(id: string) {
    const deleted = await this.repo.deleteCategory(id);
    if (!deleted) throw new NotFoundException('Danh mục không tồn tại');
    return { message: 'Đã xóa danh mục' };
  }

  // ── PRODUCT ───────────────────────────────────────────────────────────────

  async createProduct(dto: CreateProductDto) {
    return this.repo.createProduct({
      name: dto.name,
      slug: dto.slug,
      description: dto.description ?? '',
      images: dto.images ?? [],
      categoryId: dto.categoryId as any,
      status: dto.status ?? ProductStatus.DRAFT,
      seo: dto.seo as any ?? {},
    });
  }

  async listProducts(query: ProductQueryDto) {
    return this.repo.listProducts(query);
  }

  async getProductDetail(slug: string) {
    const product = await this.repo.getProductBySlug(slug);
    if (!product) throw new NotFoundException('Sản phẩm không tồn tại');
    const variants = await this.repo.listVariantsByProduct(product._id.toString());
    return { ...product, variants };
  }

  async updateProduct(id: string, dto: UpdateProductDto) {
    const updated = await this.repo.updateProduct(id, dto as any);
    if (!updated) throw new NotFoundException('Sản phẩm không tồn tại');
    return updated;
  }

  async publishProduct(id: string) {
    const updated = await this.repo.updateProduct(id, { status: ProductStatus.ACTIVE } as any);
    if (!updated) throw new NotFoundException('Sản phẩm không tồn tại');
    return updated;
  }

  // ── VARIANT ───────────────────────────────────────────────────────────────

  async createVariant(dto: CreateVariantDto) {
    return this.repo.createVariant({
      sku: dto.sku,
      productId: dto.productId as any,
      attributes: dto.attributes ?? {},
      price: dto.price,
      fulfillmentType: dto.fulfillmentType as any,
    });
  }

  async updateVariant(id: string, dto: UpdateVariantDto) {
    const updated = await this.repo.updateVariant(id, dto as any);
    if (!updated) throw new NotFoundException('Variant không tồn tại');
    return updated;
  }

  // ── DESIGN ────────────────────────────────────────────────────────────────

  async createDesign(customerId: string, dto: CreateDesignDto) {
    return this.repo.createDesign({
      customerId: customerId as any,
      name: dto.name,
      file: dto.file,
      thumbnail: dto.thumbnail ?? '',
    });
  }

  async listMyDesigns(customerId: string) {
    return this.repo.listDesignsByCustomer(customerId);
  }

  async deleteMyDesign(customerId: string, designId: string) {
    const deleted = await this.repo.deleteDesign(designId, customerId);
    if (!deleted) throw new NotFoundException('Design không tồn tại hoặc không có quyền');
    return { message: 'Đã xóa design' };
  }

  /** Cập nhật lastUsedAt khi khách dùng lại design — gọi từ CartService */
  async touchDesign(designId: string) {
    return this.repo.touchDesign(designId);
  }

  async findVariantBySku(sku: string) {
    return this.repo.findVariantBySku(sku);
  }
}
```

- [ ] **Step 2: Tạo CatalogController**

```typescript
// apps/ecommerce/src/catalog/catalog.controller.ts
import {
  Body, Controller, Delete, Get, Param, Patch, Post, Put, Query, UseGuards,
} from '@nestjs/common';
import {
  ApiBearerAuth, ApiOkResponse, ApiOperation, ApiParam, ApiQuery, ApiTags,
} from '@nestjs/swagger';
import { CurrentUser, JwtAuthGuard } from '@app/auth';
import { CatalogService } from './catalog.service';
import { CreateCategoryDto, UpdateCategoryDto } from './dto/category.dto';
import { CreateDesignDto } from './dto/design.dto';
import {
  CreateProductDto, CreateVariantDto, ProductQueryDto,
  UpdateProductDto, UpdateVariantDto,
} from './dto/product.dto';

/** Public storefront — không cần auth */
@ApiTags('catalog')
@Controller('catalog')
export class CatalogPublicController {
  constructor(private readonly svc: CatalogService) {}

  @Get('categories')
  @ApiOperation({ summary: 'Lấy cây danh mục' })
  @ApiQuery({ name: 'parentId', required: false, description: '"root" để lấy danh mục gốc' })
  listCategories(@Query('parentId') parentId?: string) {
    return this.svc.listCategories(parentId);
  }

  @Get('products')
  @ApiOperation({ summary: 'Danh sách sản phẩm (có thể tìm kiếm/lọc)' })
  listProducts(@Query() query: ProductQueryDto) {
    return this.svc.listProducts(query);
  }

  @Get('products/:slug')
  @ApiOperation({ summary: 'Chi tiết sản phẩm kèm variants' })
  @ApiParam({ name: 'slug', example: 'ly-nhua-in-custom' })
  getProduct(@Param('slug') slug: string) {
    return this.svc.getProductDetail(slug);
  }
}

/** Admin routes — cần JWT + role ECOM_MANAGER (type='admin' trong payload) */
@ApiTags('admin-catalog')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Controller('admin/catalog')
export class CatalogAdminController {
  constructor(private readonly svc: CatalogService) {}

  // ── Categories ────────────────────────────────────────────────────────────

  @Post('categories')
  @ApiOperation({ summary: '[Admin] Tạo danh mục mới' })
  createCategory(@Body() dto: CreateCategoryDto) {
    return this.svc.createCategory(dto);
  }

  @Patch('categories/:id')
  @ApiOperation({ summary: '[Admin] Cập nhật danh mục' })
  updateCategory(@Param('id') id: string, @Body() dto: UpdateCategoryDto) {
    return this.svc.updateCategory(id, dto);
  }

  @Delete('categories/:id')
  @ApiOperation({ summary: '[Admin] Xóa danh mục' })
  deleteCategory(@Param('id') id: string) {
    return this.svc.deleteCategory(id);
  }

  // ── Products ──────────────────────────────────────────────────────────────

  @Post('products')
  @ApiOperation({ summary: '[Admin] Tạo sản phẩm (mặc định DRAFT)' })
  createProduct(@Body() dto: CreateProductDto) {
    return this.svc.createProduct(dto);
  }

  @Patch('products/:id')
  @ApiOperation({ summary: '[Admin] Cập nhật sản phẩm' })
  updateProduct(@Param('id') id: string, @Body() dto: UpdateProductDto) {
    return this.svc.updateProduct(id, dto);
  }

  @Put('products/:id/publish')
  @ApiOperation({ summary: '[Admin] Đưa sản phẩm lên kệ (status → ACTIVE)' })
  publishProduct(@Param('id') id: string) {
    return this.svc.publishProduct(id);
  }

  // ── Variants ──────────────────────────────────────────────────────────────

  @Post('variants')
  @ApiOperation({ summary: '[Admin] Tạo variant mới (gắn sku WMS + giá + fulfillmentType)' })
  createVariant(@Body() dto: CreateVariantDto) {
    return this.svc.createVariant(dto);
  }

  @Patch('variants/:id')
  @ApiOperation({ summary: '[Admin] Cập nhật variant' })
  updateVariant(@Param('id') id: string, @Body() dto: UpdateVariantDto) {
    return this.svc.updateVariant(id, dto);
  }
}

/** Design library — cần JWT (khách đã đăng nhập) */
@ApiTags('designs')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Controller('designs')
export class DesignController {
  constructor(private readonly svc: CatalogService) {}

  @Get()
  @ApiOperation({ summary: 'Thư viện design của tôi (sort mới dùng gần nhất)' })
  listMyDesigns(@CurrentUser('sub') customerId: string) {
    return this.svc.listMyDesigns(customerId);
  }

  @Post()
  @ApiOperation({ summary: 'Thêm design mới vào thư viện' })
  createDesign(@CurrentUser('sub') customerId: string, @Body() dto: CreateDesignDto) {
    return this.svc.createDesign(customerId, dto);
  }

  @Delete(':id')
  @ApiOperation({ summary: 'Xóa design khỏi thư viện' })
  deleteDesign(@CurrentUser('sub') customerId: string, @Param('id') id: string) {
    return this.svc.deleteMyDesign(customerId, id);
  }
}
```

- [ ] **Step 3: Cập nhật CatalogModule**

```typescript
// apps/ecommerce/src/catalog/catalog.module.ts
import { BullModule } from '@nestjs/bullmq';
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { QUEUES } from '@app/events';
import { ProcessedEvent, ProcessedEventSchema } from './schemas/processed-event.schema';
import { ProductVariant, ProductVariantSchema } from './schemas/product-variant.schema';
import { Category, CategorySchema } from './schemas/category.schema';
import { Product, ProductSchema } from './schemas/product.schema';
import { Design, DesignSchema } from './schemas/design.schema';
import { CatalogRepository } from './catalog.repository';
import { CatalogService } from './catalog.service';
import {
  CatalogAdminController,
  CatalogPublicController,
  DesignController,
} from './catalog.controller';
import { StockConsumer } from './stock.consumer';

@Module({
  imports: [
    BullModule.registerQueue({ name: QUEUES.STOCK }),
    MongooseModule.forFeature([
      { name: ProductVariant.name, schema: ProductVariantSchema },
      { name: ProcessedEvent.name, schema: ProcessedEventSchema },
      { name: Category.name, schema: CategorySchema },
      { name: Product.name, schema: ProductSchema },
      { name: Design.name, schema: DesignSchema },
    ]),
  ],
  controllers: [CatalogPublicController, CatalogAdminController, DesignController],
  providers: [CatalogRepository, CatalogService, StockConsumer],
  exports: [CatalogService], // Cart/Checkout sẽ dùng CatalogService.findVariantBySku
})
export class CatalogModule {}
```

- [ ] **Step 4: Build và chạy smoke test**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm start:ecom
```
Sau khi app khởi động, mở `http://localhost:3002/api/shop/docs` (Swagger).
Expected: Thấy tag `catalog`, `admin-catalog`, `designs` với đầy đủ endpoints.

- [ ] **Step 5: Commit**

```bash
git add apps/ecommerce/src/catalog/
git commit -m "feat(ecom-catalog): CatalogService + controllers public/admin + Design API"
```

---

## Task E1-05: Cart (schema + repository + service + controller)

**Files:**
- Create: `apps/ecommerce/src/cart/schemas/cart.schema.ts`
- Create: `apps/ecommerce/src/cart/dto/cart.dto.ts`
- Create: `apps/ecommerce/src/cart/cart.repository.ts`
- Create: `apps/ecommerce/src/cart/cart.service.ts`
- Create: `apps/ecommerce/src/cart/cart.controller.ts`
- Create: `apps/ecommerce/src/cart/cart.module.ts`
- Modify: `apps/ecommerce/src/ecommerce.module.ts`

**Interfaces:**
- Consumes: `CatalogService.findVariantBySku` (validate SKU + lấy availableQty), `JwtAuthGuard`
- Produces: `GET /cart`, `POST /cart/items`, `PUT /cart/items/:sku`, `DELETE /cart/items/:sku`, `DELETE /cart` — CartService.getActiveCart (cho Checkout dùng)

- [ ] **Step 1: Tạo Cart schema**

```typescript
// apps/ecommerce/src/cart/schemas/cart.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { HydratedDocument, Types } from 'mongoose';

export enum CartStatus {
  ACTIVE = 'ACTIVE',       // đang dùng
  CONVERTED = 'CONVERTED', // đã checkout thành công
  ABANDONED = 'ABANDONED', // bỏ không dùng nữa
}

class CartItem {
  sku: string;
  quantity: number;
  /** true khi variant là CUSTOM_PRINT — bắt buộc kèm designId + designFile */
  isPrintItem: boolean;
  designId?: string;   // ref Design._id (tùy chọn, để reuse)
  designFile?: string; // URL file artwork — snapshot tại thời điểm thêm giỏ
  /** Giá tại lúc thêm vào giỏ — dùng để hiển thị; giá chốt thật snapshot vào Order */
  unitPrice: number;
}

/**
 * Mỗi khách có đúng 1 giỏ ACTIVE. Giỏ KHÔNG giữ tồn — chỉ lưu ý định mua.
 * Tồn thật chỉ được reserve khi checkout (atomic qua saga BullMQ).
 */
@Schema({ collection: 'carts', timestamps: true })
export class Cart {
  @Prop({ required: true, type: Types.ObjectId, index: true })
  customerId: Types.ObjectId;

  @Prop({ enum: CartStatus, default: CartStatus.ACTIVE, index: true })
  status: CartStatus;

  @Prop({ type: [Object], default: [] })
  items: CartItem[];
}

export type CartDocument = HydratedDocument<Cart>;
export const CartSchema = SchemaFactory.createForClass(Cart);
```

- [ ] **Step 2: Tạo Cart DTOs**

```typescript
// apps/ecommerce/src/cart/dto/cart.dto.ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsInt, IsNotEmpty, IsOptional, IsString, Min } from 'class-validator';

export class AddCartItemDto {
  @ApiProperty({ example: 'CUP-M-001' })
  @IsString() @IsNotEmpty()
  sku: string;

  @ApiProperty({ example: 2 })
  @IsInt() @Min(1)
  quantity: number;

  /** Bắt buộc nếu variant là CUSTOM_PRINT — ID design trong thư viện */
  @ApiPropertyOptional({ example: '64abc...' })
  @IsString() @IsOptional()
  designId?: string;

  /** URL file artwork — upload trước khi add to cart (CUSTOM_PRINT) */
  @ApiPropertyOptional({ example: 'https://storage.example.com/designs/abc.png' })
  @IsString() @IsOptional()
  designFile?: string;
}

export class UpdateCartItemDto {
  @ApiProperty({ example: 3 })
  @IsInt() @Min(1)
  quantity: number;
}
```

- [ ] **Step 3: Tạo CartRepository**

```typescript
// apps/ecommerce/src/cart/cart.repository.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model, Types } from 'mongoose';
import { Cart, CartStatus } from './schemas/cart.schema';

@Injectable()
export class CartRepository {
  constructor(@InjectModel(Cart.name) private readonly cartModel: Model<Cart>) {}

  /** Lấy giỏ ACTIVE của khách, tạo mới nếu chưa có */
  async getOrCreateActive(customerId: string): Promise<Cart & { _id: Types.ObjectId }> {
    const existing = await this.cartModel
      .findOne({ customerId: new Types.ObjectId(customerId), status: CartStatus.ACTIVE })
      .lean();
    if (existing) return existing as any;
    return this.cartModel.create({ customerId: new Types.ObjectId(customerId) }) as any;
  }

  async saveCart(cartId: string, items: Cart['items']) {
    return this.cartModel.findByIdAndUpdate(cartId, { items }, { new: true }).lean();
  }

  async markConverted(cartId: string) {
    return this.cartModel
      .findByIdAndUpdate(cartId, { status: CartStatus.CONVERTED }, { new: true })
      .lean();
  }

  async clearCart(cartId: string) {
    return this.cartModel.findByIdAndUpdate(cartId, { items: [] }, { new: true }).lean();
  }
}
```

- [ ] **Step 4: Tạo CartService**

```typescript
// apps/ecommerce/src/cart/cart.service.ts
import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { CatalogService } from '../catalog/catalog.service';
import { FulfillmentType } from '../catalog/schemas/product-variant.schema';
import { CartRepository } from './cart.repository';
import { AddCartItemDto, UpdateCartItemDto } from './dto/cart.dto';

@Injectable()
export class CartService {
  constructor(
    private readonly repo: CartRepository,
    private readonly catalog: CatalogService,
  ) {}

  async getCart(customerId: string) {
    return this.repo.getOrCreateActive(customerId);
  }

  async addItem(customerId: string, dto: AddCartItemDto) {
    const variant = await this.catalog.findVariantBySku(dto.sku);
    if (!variant) throw new NotFoundException(`SKU ${dto.sku} không tồn tại`);
    if (!variant.isActive) throw new BadRequestException('Variant không còn bán');

    // CUSTOM_PRINT bắt buộc kèm designFile
    if (variant.fulfillmentType === FulfillmentType.CUSTOM_PRINT) {
      if (!dto.designFile) {
        throw new BadRequestException('CUSTOM_PRINT cần kèm designFile (URL artwork)');
      }
    }

    const cart = await this.repo.getOrCreateActive(customerId);
    const cartId = cart._id.toString();
    const items = [...(cart.items ?? [])];
    const idx = items.findIndex((i) => i.sku === dto.sku);

    const isPrintItem = variant.fulfillmentType === FulfillmentType.CUSTOM_PRINT;

    if (idx >= 0) {
      // Đã có trong giỏ → cộng dồn quantity
      items[idx] = { ...items[idx], quantity: items[idx].quantity + dto.quantity };
    } else {
      items.push({
        sku: dto.sku,
        quantity: dto.quantity,
        isPrintItem,
        designId: dto.designId,
        designFile: dto.designFile,
        unitPrice: variant.price,
      });
    }

    // Cập nhật lastUsedAt cho design nếu tái dùng
    if (dto.designId) await this.catalog.touchDesign(dto.designId);

    return this.repo.saveCart(cartId, items);
  }

  async updateItem(customerId: string, sku: string, dto: UpdateCartItemDto) {
    const cart = await this.repo.getOrCreateActive(customerId);
    const items = [...(cart.items ?? [])];
    const idx = items.findIndex((i) => i.sku === sku);
    if (idx < 0) throw new NotFoundException(`SKU ${sku} không có trong giỏ`);
    items[idx] = { ...items[idx], quantity: dto.quantity };
    return this.repo.saveCart(cart._id.toString(), items);
  }

  async removeItem(customerId: string, sku: string) {
    const cart = await this.repo.getOrCreateActive(customerId);
    const items = (cart.items ?? []).filter((i) => i.sku !== sku);
    return this.repo.saveCart(cart._id.toString(), items);
  }

  async clearCart(customerId: string) {
    const cart = await this.repo.getOrCreateActive(customerId);
    return this.repo.clearCart(cart._id.toString());
  }
}
```

- [ ] **Step 5: Tạo CartController**

```typescript
// apps/ecommerce/src/cart/cart.controller.ts
import {
  Body, Controller, Delete, Get, Param, Post, Put, UseGuards,
} from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiParam, ApiTags } from '@nestjs/swagger';
import { CurrentUser, JwtAuthGuard } from '@app/auth';
import { CartService } from './cart.service';
import { AddCartItemDto, UpdateCartItemDto } from './dto/cart.dto';

@ApiTags('cart')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Controller('cart')
export class CartController {
  constructor(private readonly svc: CartService) {}

  @Get()
  @ApiOperation({ summary: 'Xem giỏ hàng hiện tại' })
  getCart(@CurrentUser('sub') customerId: string) {
    return this.svc.getCart(customerId);
  }

  @Post('items')
  @ApiOperation({ summary: 'Thêm SKU vào giỏ (CUSTOM_PRINT cần kèm designFile)' })
  addItem(@CurrentUser('sub') customerId: string, @Body() dto: AddCartItemDto) {
    return this.svc.addItem(customerId, dto);
  }

  @Put('items/:sku')
  @ApiOperation({ summary: 'Cập nhật số lượng item trong giỏ' })
  @ApiParam({ name: 'sku', example: 'CUP-M-001' })
  updateItem(
    @CurrentUser('sub') customerId: string,
    @Param('sku') sku: string,
    @Body() dto: UpdateCartItemDto,
  ) {
    return this.svc.updateItem(customerId, sku, dto);
  }

  @Delete('items/:sku')
  @ApiOperation({ summary: 'Xóa SKU khỏi giỏ' })
  @ApiParam({ name: 'sku', example: 'CUP-M-001' })
  removeItem(@CurrentUser('sub') customerId: string, @Param('sku') sku: string) {
    return this.svc.removeItem(customerId, sku);
  }

  @Delete()
  @ApiOperation({ summary: 'Xóa toàn bộ giỏ' })
  clearCart(@CurrentUser('sub') customerId: string) {
    return this.svc.clearCart(customerId);
  }
}
```

- [ ] **Step 6: Tạo CartModule**

```typescript
// apps/ecommerce/src/cart/cart.module.ts
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { CatalogModule } from '../catalog/catalog.module';
import { CartRepository } from './cart.repository';
import { CartService } from './cart.service';
import { CartController } from './cart.controller';
import { Cart, CartSchema } from './schemas/cart.schema';

@Module({
  imports: [
    MongooseModule.forFeature([{ name: Cart.name, schema: CartSchema }]),
    CatalogModule, // để inject CatalogService
  ],
  controllers: [CartController],
  providers: [CartRepository, CartService],
  exports: [CartService], // Checkout dùng CartService.getCart + markConverted
})
export class CartModule {}
```

- [ ] **Step 7: Đăng ký CartModule vào EcommerceModule**

```typescript
// apps/ecommerce/src/ecommerce.module.ts — thêm CartModule vào imports[]
import { CartModule } from './cart/cart.module';

// Trong @Module({ imports: [...] }):
// Thêm: CartModule,   // giỏ hàng khách (POST /api/shop/cart/*)
```

- [ ] **Step 8: Smoke test toàn bộ**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm start:ecom
```

Kiểm tra Swagger `http://localhost:3002/api/shop/docs`:
- Tag `cart` có 5 endpoints
- Tag `catalog` có GET /products, GET /products/:slug, GET /categories
- Tag `admin-catalog` có POST /products, POST /variants, PUT /products/:id/publish

- [ ] **Step 9: Commit**

```bash
git add apps/ecommerce/src/cart/ apps/ecommerce/src/ecommerce.module.ts
git commit -m "feat(ecom-cart): CartModule đầy đủ (add/update/remove/clear) + wiring EcommerceModule"
```

---

## Task E1-06: Seed data script

**Files:**
- Create: `apps/ecommerce/src/seed.ts`

**Interfaces:**
- Produces: Script chạy một lần để tạo dữ liệu mẫu cho demo/test

- [ ] **Step 1: Tạo seed script**

```typescript
// apps/ecommerce/src/seed.ts
import { NestFactory } from '@nestjs/core';
import { EcommerceModule } from './ecommerce.module';
import { getModelToken } from '@nestjs/mongoose';
import { Model } from 'mongoose';
import { Category } from './catalog/schemas/category.schema';
import { Product, ProductStatus } from './catalog/schemas/product.schema';
import { ProductVariant, FulfillmentType } from './catalog/schemas/product-variant.schema';

async function seed() {
  const app = await NestFactory.createApplicationContext(EcommerceModule);

  const categoryModel: Model<Category> = app.get(getModelToken(Category.name));
  const productModel: Model<Product> = app.get(getModelToken(Product.name));
  const variantModel: Model<ProductVariant> = app.get(getModelToken(ProductVariant.name));

  // Xóa dữ liệu cũ
  await categoryModel.deleteMany({});
  await productModel.deleteMany({});
  await variantModel.deleteMany({});

  // Tạo categories
  const [catLy, catPK, catNL] = await categoryModel.insertMany([
    { name: 'Ly & Cốc', slug: 'ly-coc', parentId: null, position: 1 },
    { name: 'Bao bì & Phụ kiện', slug: 'bao-bi-phu-kien', parentId: null, position: 2 },
    { name: 'Nguyên liệu F&B', slug: 'nguyen-lieu-fb', parentId: null, position: 3 },
  ]);

  // Tạo products + variants
  const p1 = await productModel.create({
    name: 'Ly nhựa in custom', slug: 'ly-nhua-in-custom',
    description: 'Ly nhựa trắng cho khách in logo/design theo yêu cầu',
    images: ['https://placehold.co/400x400?text=Ly+Custom'],
    categoryId: catLy._id, status: ProductStatus.ACTIVE,
  });
  await variantModel.insertMany([
    { sku: 'CUP-BLANK-S', productId: p1._id, attributes: { size: 'S' }, price: 12000, fulfillmentType: FulfillmentType.CUSTOM_PRINT, availableQty: 50 },
    { sku: 'CUP-BLANK-M', productId: p1._id, attributes: { size: 'M' }, price: 15000, fulfillmentType: FulfillmentType.CUSTOM_PRINT, availableQty: 80 },
    { sku: 'CUP-BLANK-L', productId: p1._id, attributes: { size: 'L' }, price: 18000, fulfillmentType: FulfillmentType.CUSTOM_PRINT, availableQty: 60 },
  ]);

  const p2 = await productModel.create({
    name: 'Ly in logo Trà Sữa Phúc Long', slug: 'ly-in-tra-sua-phuc-long',
    description: 'Mẫu in sẵn logo Phúc Long',
    images: ['https://placehold.co/400x400?text=Ly+Phuc+Long'],
    categoryId: catLy._id, status: ProductStatus.ACTIVE,
  });
  await variantModel.insertMany([
    { sku: 'CUP-PRINTED-PL-M', productId: p2._id, attributes: { size: 'M' }, price: 25000, fulfillmentType: FulfillmentType.PRINTED_TEMPLATE, availableQty: 30 },
    { sku: 'CUP-PRINTED-PL-L', productId: p2._id, attributes: { size: 'L' }, price: 28000, fulfillmentType: FulfillmentType.PRINTED_TEMPLATE, availableQty: 20 },
  ]);

  const p3 = await productModel.create({
    name: 'Nắp ly nhựa S/M/L', slug: 'nap-ly-nhua',
    description: 'Nắp ly nhựa phù hợp các size S, M, L',
    images: ['https://placehold.co/400x400?text=Nap+Ly'],
    categoryId: catPK._id, status: ProductStatus.ACTIVE,
  });
  await variantModel.insertMany([
    { sku: 'LID-S', productId: p3._id, attributes: { size: 'S' }, price: 500, fulfillmentType: FulfillmentType.STANDARD, availableQty: 500 },
    { sku: 'LID-M', productId: p3._id, attributes: { size: 'M' }, price: 500, fulfillmentType: FulfillmentType.STANDARD, availableQty: 500 },
    { sku: 'LID-L', productId: p3._id, attributes: { size: 'L' }, price: 600, fulfillmentType: FulfillmentType.STANDARD, availableQty: 400 },
  ]);

  console.log('✅ Seed xong: 3 category, 3 product, 8 variant');
  await app.close();
}

seed().catch((e) => { console.error(e); process.exit(1); });
```

- [ ] **Step 2: Thêm script vào package.json**

Thêm vào `scripts` trong `apps/ecommerce` hoặc root `package.json`:
```json
"seed:ecom": "ts-node -r tsconfig-paths/register apps/ecommerce/src/seed.ts"
```

- [ ] **Step 3: Chạy seed**

```bash
cd /home/hoaiphuong/code/wms-ecom/be
pnpm seed:ecom
```
Expected: `✅ Seed xong: 3 category, 3 product, 8 variant`

- [ ] **Step 4: Verify qua Swagger**

`GET /api/shop/catalog/products` → trả về 3 products với đầy đủ thông tin.
`GET /api/shop/catalog/categories` → trả về 3 categories.

- [ ] **Step 5: Commit**

```bash
git add apps/ecommerce/src/seed.ts
git commit -m "feat(ecom): seed script 3 category / 3 product / 8 variant"
```

---

## ✅ Checklist Definition of Done — Tuần 1

- [ ] `GET /api/shop/catalog/categories` — trả cây danh mục
- [ ] `GET /api/shop/catalog/products?q=ly&inStock=true` — search + filter
- [ ] `GET /api/shop/catalog/products/:slug` — chi tiết + variants
- [ ] `POST /api/shop/admin/catalog/categories` — tạo category (cần Bearer token admin)
- [ ] `POST /api/shop/admin/catalog/products` + `PUT /publish` — tạo + publish product
- [ ] `POST /api/shop/admin/catalog/variants` — tạo variant với fulfillmentType
- [ ] `POST /api/shop/cart/items` — thêm vào giỏ (CUSTOM_PRINT cần designFile)
- [ ] `GET /api/shop/cart` — xem giỏ
- [ ] `PUT /api/shop/cart/items/:sku` — đổi số lượng
- [ ] `DELETE /api/shop/cart/items/:sku` — xóa item
- [ ] `POST /api/shop/designs` + `GET /api/shop/designs` — design library
- [ ] Consumer `stock.changed` vẫn chạy đúng (không bị break bởi changes)
