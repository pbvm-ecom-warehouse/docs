# Gap Analysis — Nghiệp vụ còn thiếu toàn hệ thống

> Trạng thái: 🔄 Đang phân tích — la bàn cho các lần thiết kế module tiếp theo.
> 3 module đã chín: [warehouse](../warehouse/), [catalog](../catalog/), [order](../order/). 5 vùng dưới đây còn thiếu tài liệu.

## Bảng ưu tiên

| Hạng | Module | Hiện trạng | Phụ thuộc |
|---|---|---|---|
| 1 | Shipping | Tham chiếu ở [main-flow P7](./main-flow.md) & UC-E04, gọi là "module sau" | Order (đã có) |
| 2 | Auth | [system-context](./system-context.md#auth) mô tả JWT/roles, thiếu UC | — |
| 3 | **Supplier** ✅ | **Đã thiết kế** — xem [supplier/](../supplier/) | Warehouse (đã có) |
| 4 | Notification | App :3003 trong [system-context](./system-context.md#các-ứng-dụng), thiếu docs | Order/WMS events |
| 5 | Report | [README](../README.md) liệt kê, trống | Tất cả (đọc-only) |

---

## 1. Shipping (Vận chuyển) — Hạng 1

- **Hiện trạng:** [main-flow P7](./main-flow.md#p7--giao-hàng--đóng-đơn) và [UC-E04](../order/use-cases.md#uc-e04-theo-dõi--fulfillment-đơn) tham chiếu `fulfillmentStatus = SHIPPED → DELIVERED`, ghi rõ "module sau".
- **Nghiệp vụ thiếu:** tạo vận đơn, gán đơn vị vận chuyển, cập nhật trạng thái giao, COD reconciliation (`paymentStatus = PAID` khi `DELIVERED`), đóng đơn `CLOSED`.
- **Event liên quan:** tiêu thụ `goods.issued`; cần phát trạng thái giao về Order.
- **Đề xuất:** làm trước — chặn happy-path end-to-end.

## 2. Auth & User — Hạng 2

- **Hiện trạng:** [system-context](./system-context.md#auth) đã mô tả JWT stateless, `users` (nhân viên) vs `customers` (khách), RolesGuard.
- **Nghiệp vụ thiếu:** đăng ký/đăng nhập khách, quản lý tài khoản nhân viên, refresh token, đổi/quên mật khẩu, khóa tài khoản.
- **Event liên quan:** không (đồng bộ trong từng app).
- **Đề xuất:** nền tảng — làm sớm, độc lập.

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
