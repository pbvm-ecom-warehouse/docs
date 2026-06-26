# Tài Liệu Bàn Giao & Giải Thích Chi Tiết Hệ Thống Ecommerce APIs

Tài liệu này tổng hợp toàn bộ các tính năng, cấu trúc thư mục, quy trình nghiệp vụ và các cơ chế xử lý kỹ thuật đã được triển khai cho ứng dụng **Ecommerce** (nằm trong dự án `be-wms-ecom`).

---

## 1. Kiến Trúc Tổng Quan & Quy Tắc Thiết Kế

Hệ thống tuân thủ mô hình **Decoupled Architecture** và **DB-per-app**:
- **Tách Biệt Database**: Ứng dụng Ecommerce sử dụng cơ sở dữ liệu `ecom_db` độc lập, trong khi WMS sử dụng `wms_db`. Không thực hiện truy vấn chéo dữ liệu trực tiếp hoặc dùng populate liên database.
- **Giao Tiếp Bất Đồng Bộ**: Mọi tương tác đồng bộ dữ liệu tồn kho và điều phối đơn hàng giữa Ecommerce và WMS đều được thực hiện thông qua **BullMQ / Redis** (`libs/events`).
- **Xử Lý Lỗi Tập Trung**: Các Services không trực tiếp ném ra NestJS HTTP Exceptions. Thay vào đó, chúng ném `AppException` với các mã lỗi nghiệp vụ ổn định (Domain Error Codes) được cấu hình tại `apps/ecommerce/src/common/error-codes.ts` để phía Gateways/Controllers tự động map thành mã lỗi HTTP phù hợp.

---

## 2. Phân Hệ Đã Triển Khai & Giải Thích Chi Tiết

### Phân Hệ 1: Danh Mục Sản Phẩm (Catalog)
Quản lý các danh mục (Categories), sản phẩm tiếp thị (Products), biến thể sản phẩm (Product Variants), và thư viện thiết kế của khách hàng (Designs).

#### Cấu Trúc File & Thư Mục:
- [design.schema.ts](file:///c:/wdp/be-wms-ecom/apps/ecommerce/src/catalog/schemas/design.schema.ts): Lưu trữ thiết kế do khách hàng tải lên để phục vụ in ấn.
- [product-variant.schema.ts](file:///c:/wdp/be-wms-ecom/apps/ecommerce/src/catalog/schemas/product-variant.schema.ts): Mở rộng biến thể sản phẩm liên kết với SKU của WMS, bổ sung trường `availableQty` (đồng bộ từ WMS) và `fulfillmentType` (`STANDARD` | `CUSTOM_PRINT`).
- [catalog.repository.ts](file:///c:/wdp/be-wms-ecom/apps/ecommerce/src/catalog/catalog.repository.ts): Chứa các truy vấn CRUD. Đặc biệt, hàm `applyStockDeltaOnce` tích hợp cơ chế:
  > [!NOTE]
  > **Stock Delta Clamping**: Khi cập nhật tồn kho từ event WMS, nếu xảy ra hiện tượng lệch thứ tự sự kiện làm tồn kho khả dụng bị âm, hệ thống tự động clamp (giới hạn) `availableQty` về tối thiểu là `0`.

---

### Phân Hệ 2: Cô Lập Xác Thực & Phân Quyền (Auth Isolation)
Ecommerce và WMS hoạt động với 2 hệ thống tài khoản và Secret Keys riêng biệt (`ECOM_JWT_SECRET` và `WMS_JWT_SECRET`).

#### Giải thích cơ chế bảo vệ Route:
1. **JwtStrategy của Ecommerce**:
   - Được cấu hình sử dụng `ECOM_JWT_SECRET`.
   - Chấp nhận token của cả khách hàng (`type: 'customer'`) và quản trị viên Ecom (`type: 'admin'`).
2. **CustomerGuard**:
   - Bảo vệ các API dành riêng cho khách hàng (Giỏ hàng, đặt hàng, thư viện thiết kế).
   - Chỉ cho phép các token có `type === 'customer'` đi qua.
3. **RolesGuard & `@Roles(EcomRole.ECOM_MANAGER)`**:
   - Bảo vệ các API quản trị của Ecommerce (thêm/sửa sản phẩm, danh mục).
   - Chỉ cho phép tài khoản quản trị viên Ecom (`type === 'admin'`) sở hữu role `ECOM_MANAGER` truy cập.

---

### Phân Hệ 3: Giỏ Hàng (Cart)
Giúp khách hàng quản lý danh sách sản phẩm chuẩn bị mua trước khi chốt đơn.

- **[CartController](file:///c:/wdp/be-wms-ecom/apps/ecommerce/src/cart/cart.controller.ts)**: Cung cấp API xem giỏ hàng (`GET /cart`), thêm sản phẩm (`POST /cart/items`), cập nhật số lượng (`PUT /cart/items/:sku`), và xóa sản phẩm (`DELETE /cart/items/:sku`).
- **Kiểm Tra Hợp Lệ**: Khi thêm sản phẩm in custom (`CUSTOM_PRINT`), hệ thống bắt buộc kiểm tra xem khách hàng có truyền lên `designFile` hoặc liên kết `designId` hợp lệ hay không.

---

### Phân Hệ 4: Đặt Hàng & Quy Trình Saga (Order & Checkout Saga)
Quản lý trạng thái đơn hàng thông qua mô hình 3 trục: `orderStatus` (Trạng thái đơn), `paymentStatus` (Trạng thái thanh toán), và `fulfillmentStatus` (Trạng thái xử lý kho).

#### Quy Trình Checkout Saga (Sử dụng BullMQ):

```mermaid
sequenceDiagram
    autonumber
    actor Customer as Khách hàng
    participant Ecom as Ecommerce App
    participant Redis as BullMQ (Redis)
    participant WMS as WMS App

    Customer->>Ecom: Gọi POST /orders/checkout (paymentMethod: ONLINE/COD)
    Note over Ecom: Khóa giỏ hàng & tạo Đơn hàng tạm thời (PLACED, UNPAID)<br/>Chặn COD nếu có sản phẩm in ấn (CUSTOM_PRINT)
    Ecom->>Redis: Phát sự kiện STOCK_RESERVE_REQUESTED
    Ecom->>Redis: (Nếu ONLINE) Đăng ký delayed job 'auto.cancel' sau 30 phút
    Ecom-->>Customer: Trả về Đơn hàng tạm thời thành công
    
    Note over Redis: WMS lắng nghe STOCK_RESERVE_REQUESTED
    Redis->>WMS: Xử lý kiểm kho và giữ tồn kho vật lý
    
    alt Giữ kho thành công
        WMS->>Redis: Phát sự kiện STOCK_RESERVED
        Note over Redis: Ecom lắng nghe STOCK_RESERVED
        Redis->>Ecom: Cập nhật đơn hàng (đã giữ kho ở kho trung tâm)
        alt Đơn hàng COD
            Note over Ecom: Đơn COD -> CONFIRMED & READY_TO_PICK
            Ecom->>Redis: Phát lệnh ORDER_READY_TO_FULFILL sang WMS để đóng gói xuất hàng
        alt Đơn hàng ONLINE
            Note over Ecom: Chờ khách hàng thực hiện thanh toán trực tuyến
        end
    else Giữ kho thất bại (Hết hàng)
        WMS->>Redis: Phát sự kiện STOCK_RESERVE_FAILED
        Note over Redis: Ecom lắng nghe STOCK_RESERVE_FAILED
        Redis->>Ecom: Hủy đơn hàng tạm thời (CANCELLED)
        Note over Ecom: Phục hồi lại toàn bộ mặt hàng vào giỏ hàng cho khách
    end
```

#### Chi Tiết Tự Động Hủy Đơn:
Đối với đơn hàng thanh toán trực tuyến (ONLINE), nếu sau 30 phút khách hàng không thanh toán, delayed job `'auto.cancel'` trong BullMQ sẽ kích hoạt. `ReserveConsumer` kiểm tra đơn hàng, nếu trạng thái vẫn là `UNPAID` thì sẽ tự động hủy đơn và giải phóng kho (gửi sự kiện `ORDER_CANCELLED` sang WMS).

---

### Phân Hệ 5: Tích Hợp VNPay Sandbox & Chống Ghi Trùng (Idempotency)
Phục vụ việc thanh toán đơn hàng trực tuyến một cách an toàn và tin cậy.

- **[PaymentService](file:///c:/wdp/be-wms-ecom/apps/ecommerce/src/order/payment.service.ts)**:
  - Tạo URL thanh toán VNPay Sandbox với mã hash SHA-512.
  - Tiếp nhận và xác thực chữ ký của IPN Webhook gửi về từ VNPay.
- **[PaymentController](file:///c:/wdp/be-wms-ecom/apps/ecommerce/src/order/payment.controller.ts)**:
  - `/vnpay/create-url/:orderId` (Cần đăng nhập): Sinh link chuyển hướng sang VNPay.
  - `/vnpay/ipn` (Công khai): Tiếp nhận kết quả thanh toán server-to-server từ VNPay.
  - `/vnpay/return` (Công khai): Điểm tự động chuyển hướng trình duyệt của khách hàng sau khi thanh toán.

> [!IMPORTANT]
> **Cơ chế chống ghi trùng (Idempotency) trong Thanh Toán**:
> Giao dịch thanh toán được lưu trữ tại bảng append-only `PaymentTransaction` với trường `providerTxnId` (Mã giao dịch duy nhất từ VNPay). Bảng này được cấu hình **Unique Sparse Index** trên `providerTxnId`.
> Khi VNPay gọi Webhook IPN nhiều lần cho cùng một giao dịch (do timeout mạng), cơ chế ghi đè của Mongoose sẽ ném lỗi trùng khóa (Duplicate Key - 11000). Hệ thống sẽ chủ động bắt lỗi này, bỏ qua xử lý và trả về kết quả thành công cho VNPay mà không làm nhân đôi số tiền hay thay đổi trạng thái đơn hàng sai lệch.

---

### Phân Hệ 6: API Đơn Hàng & Đổi Trả (RMA)
Khách hàng có thể tương tác với đơn hàng qua các API tại `/api/shop/orders`:

- **Hủy Đơn Hàng**: Khách hàng được phép hủy đơn hàng nếu trạng thái xử lý kho chưa chuyển sang đóng gói/xuất kho (chỉ cho phép khi trạng thái fulfillment là `NONE`, `AWAITING_PRINT`, hoặc `READY_TO_PICK`). Đặc biệt, ly in custom đã chuyển xuống xưởng in (`AWAITING_PRINT`) thì **không** được phép hủy.
- **Đổi Trả Hàng (RMA)**:
  - Chỉ cho phép đối với các mặt hàng chuẩn (không in custom).
  - Chỉ cho phép trong vòng **7 ngày** kể từ khi đơn hàng giao thành công (`fulfillmentStatus === 'DELIVERED'`).
  - Khi yêu cầu được chấp nhận, hệ thống chuyển trạng thái đơn sang `RETURNED` và phát sự kiện `ORDER_RETURNED` sang WMS để tiến hành hoàn nhập kho vật lý.

---

## 3. Cấu Hình Biến Môi Trường (Environments)

Các biến môi trường phục vụ VNPay sandbox và đặt hạn hủy đơn được định nghĩa tại file `.env`:

```env
# ---- VNPay Payment Config ----
VNPAY_TMN_CODE=your_tmn_code_here                     # Mã terminal code được VNPay cấp
VNPAY_SECRET_KEY=your_secret_key_here                 # Chuỗi khóa bí mật dùng để ký HMAC
VNPAY_RETURN_URL=http://localhost:3002/api/shop/payment/vnpay/return  # URL redirect client
PAYMENT_DEADLINE_MINUTES=30                           # Thời gian giới hạn thanh toán đơn trực tuyến (phút)
```

---

## 4. Tối Ưu Hóa Cơ Sở Dữ Liệu (Mongoose Indices)

Để phục vụ truy vấn tải cao và lọc tìm kiếm mượt mà, các chỉ mục phức hợp (Compound Indices) sau đã được thiết lập:

1. **Bảng `orders`**:
   - `OrderSchema.index({ customerId: 1, orderStatus: 1 })`: Tối ưu hóa việc lọc danh sách đơn hàng theo trạng thái của từng khách hàng.
   - `OrderSchema.index({ customerId: 1, createdAt: -1 })`: Tối ưu hóa truy vấn lịch sử mua hàng (đưa đơn mới nhất lên đầu).
2. **Bảng `product_variants`**:
   - `ProductVariantSchema.index({ productId: 1, isActive: 1 })`: Tối ưu hóa việc lấy danh sách các biến thể đang hoạt động của một sản phẩm trên Storefront.
3. **Bảng `payment_transactions`**:
   - `PaymentTransactionSchema.index({ providerTxnId: 1 }, { unique: true, sparse: true })`: Phục vụ cơ chế Idempotency chống ghi trùng giao dịch.

---

## 5. Tuân Thủ DTO Conventions & Strict TypeScript

Để đồng bộ với các tiêu chuẩn phát triển của dự án được quy định trong `.claude/rules/dto-conventions.md`:
- **Tách Biệt Request và Response DTO**: Tạo file [payment.dto.ts](file:///c:/wdp/be-wms-ecom/apps/ecommerce/src/order/dto/payment.dto.ts) định nghĩa Response DTO cho các endpoint thanh toán. Đồng thời bổ sung các decorator `@ApiProperty()` và `@ApiPropertyOptional()` vào toàn bộ các trường exposed trong [order.dto.ts](file:///c:/wdp/be-wms-ecom/apps/ecommerce/src/order/dto/order.dto.ts) nhằm phục vụ xuất tài liệu Swagger API đầy đủ.
- **Biến Đổi Dữ Liệu Qua Controller**: Các controllers dùng `plainToInstance(..., { excludeExtraneousValues: true })` trước khi trả kết quả về cho client.
- **Strict Types (Không Dùng `any`)**: Loại bỏ hoàn toàn kiểu `any` và ép kiểu `as any` tại [order.service.ts](file:///c:/wdp/be-wms-ecom/apps/ecommerce/src/order/order.service.ts) và [order.repository.ts](file:///c:/wdp/be-wms-ecom/apps/ecommerce/src/order/order.repository.ts). Các lỗi kiểm tra mã lỗi trong catch block đã được cast về `{ code?: number }` hoặc các interface tương thích thay vì dùng `any`.

