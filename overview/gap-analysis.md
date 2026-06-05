# Gap Analysis — Nghiệp vụ còn thiếu toàn hệ thống

> Trạng thái: 🔄 Đang phân tích — la bàn cho các lần thiết kế module tiếp theo.
> 3 module đã chín: [warehouse](../warehouse/), [catalog](../catalog/), [order](../order/). 5 vùng dưới đây còn thiếu tài liệu.

## Bảng ưu tiên

| Hạng | Module | Hiện trạng | Phụ thuộc |
|---|---|---|---|
| 1 | **Shipping** ✅ | **Đã thiết kế** — xem [shipping/](../shipping/) | Order (đã có) |
| 2 | **Auth** ✅ | **Đã thiết kế** — [auth-wms/](../auth-wms/) (nhân viên) + [auth-ecom/](../auth-ecom/) (khách) | — |
| 3 | **Supplier** ✅ | **Đã thiết kế** — xem [supplier/](../supplier/) | Warehouse (đã có) |
| 4 | Notification | App :3003 trong [system-context](./system-context.md#các-ứng-dụng), thiếu docs | Order/WMS events |
| 5 | Report | [README](../README.md) liệt kê, trống | Tất cả (đọc-only) |

---

## 1. Shipping (Vận chuyển) — Hạng 1

- **Hiện trạng:** ✅ Đã thiết kế — module thuộc WMS (`wms_db`): [shipping/use-cases](../shipping/use-cases.md), [data-model](../shipping/data-model.md), [workflow](../shipping/workflow.md).
- **Đã có:** master data `carriers`; vận đơn `shipments` auto sinh sau `goods.issued` (1 đơn = 1 vận đơn); enum `shipmentStatus` 7 trạng thái; 3 event `shipment.shipped`/`shipment.delivered`/`shipment.returned` về Order; COD flip `PAID` khi `DELIVERED`; giao thất bại → retry/return-to-sender nối UC-09.
- **Chưa làm (YAGNI):** tích hợp API hãng (chỉ chừa interface `apiConfig`), tự tính `shippingFee`, đối soát dòng tiền COD/remittance, partial fulfillment / split nhiều vận đơn.

## 2. Auth & User — Hạng 2 ✅ Đã thiết kế

- **Hiện trạng:** ✅ Tách 2 module — [auth-wms](../auth-wms/use-cases.md) (nhân viên, `users`) + [auth-ecom](../auth-ecom/use-cases.md) (khách, `customers`). Spec: [2026-06-05-auth-design](../superpowers/specs/2026-06-05-auth-design.md).
- **Đã có:** access ngắn + refresh lưu DB (thu hồi được); claim `type=user|customer`; **back-office shop dùng chung `users`** qua shared JWT (làm rõ Actor "Admin" của [catalog UC-C05](../catalog/use-cases.md)); đăng ký + verify email + quên/đặt lại mật khẩu (khách); ADMIN tạo/khóa/reset nhân viên; sổ địa chỉ `customers.addresses[]`.
- **Event mới:** Auth-Ecom phát `customer.verify_requested` & `customer.password_reset_requested` → Notification (xem [data-ownership](./data-ownership.md#các-event-đồng-bộ-giữa-wms-và-ecommerce)).
- **Chưa làm (YAGNI):** role chuyên biệt back-office (`CATALOG_MANAGER`/`ORDER_MANAGER` — tạm dùng ADMIN/MANAGER), SSO/OAuth social, 2FA, verify-email cho nhân viên.

## 3. Supplier (Nhà cung cấp) — Hạng 3 ✅ Đã thiết kế

- **Hiện trạng:** entity cơ bản đã tách thành module riêng — xem [supplier/use-cases](../supplier/use-cases.md), [data-model](../supplier/data-model.md), [workflow](../supplier/workflow.md).
- **Đã có:** CRUD NCC, trạng thái/blacklist, danh mục giá (`SupplierItem` 1 NCC/SKU), gợi ý giá + guard khi tạo PO.
- **Chưa làm (YAGNI):** công nợ phải trả, đánh giá NCC, đa-NCC/SKU.

## 4. Notification — Hạng 4

- **Hiện trạng:** [system-context](./system-context.md#các-ứng-dụng) định nghĩa app :3003 (email/sms/push), chưa có docs.
- **Nghiệp vụ thiếu:** consumer các event (`payment.success`, `goods.issued`, `stock.low`, `stock.near_expiry`), template theo kênh, retry/idempotent.
- **Event liên quan:** consumer của nhiều event đã có nguồn phát (xem [data-ownership](./data-ownership.md#các-event-đồng-bộ-giữa-wms-và-ecommerce)).
- **Đề xuất:** làm sau khi Order/Shipping ổn định nguồn event.

## 5. Report (Báo cáo) — Hạng 5

- **Hiện trạng:** [README](../README.md) liệt kê, thư mục trống.
- **Nghiệp vụ thiếu:** báo cáo tồn kho (theo SKU/kho/lô), doanh thu, đơn hàng, hiệu suất kho (nhập/xuất/kiểm).
- **Event liên quan:** đọc-only từ collection sẵn có (`stock_movements`, `orders`...).
- **Đề xuất:** làm cuối — cần dữ liệu giao dịch đủ.

---

## 6. YAGNI hoãn (ghi nhận, chưa thiết kế)

> Theo [spec ecom-review 2026-06-04](../superpowers/specs/2026-06-04-ecom-review-design.md).

- **Khuyến mãi/voucher/discount (Order):** chưa mô hình hóa; `Order` giữ `subtotal/shippingFee/total`.
- **`shippingFee`:** nguồn tính phí phụ thuộc module **Shipping** (Hạng 1); checkout tạm chưa tự tính.
- **RMA từng phần, partial fulfillment, guest checkout, thuế/VAT:** ngoài phạm vi hiện tại.
- **Sổ cái tiền `payment_transactions` (append-only)** ✅ Đã thiết kế — thay `payments` ghi-đè bằng sổ cái bất biến (CHARGE/REFUND/COD_COLLECT, gồm FAILED); `Order.paymentStatus` thành cache dẫn xuất. Spec: [payment-ledger-design](../superpowers/specs/2026-06-05-payment-ledger-design.md). *(Đối soát remittance COD/hãng vẫn YAGNI.)*
