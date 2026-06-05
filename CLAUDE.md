# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Bản chất repo

Đây là repo **tài liệu phân tích nghiệp vụ** (markdown, tiếng Việt) cho hệ **WMS-ECOM** — không có mã nguồn, không build/test/lint. "Sản phẩm" là các file `.md` mô tả use-case, data-model, workflow. Mọi thay đổi là viết/sửa tài liệu.

**Không có lệnh build/test.** Thay vào đó, "verify" một thay đổi = kiểm tra **link & anchor phân giải đúng** và **nhất quán** với các file liên đới. Mẫu kiểm tra:

```bash
# Anchor nội bộ: heading có khớp slug được link tới không
grep -n "^## " <file>.md
# Link .md trỏ tới file tồn tại
grep -ohE '\]\(\.\.?/[^)#]+\.md' <file>.md
```

## Hệ thống được mô tả (big picture)

**2 app, 2 logical DB, 1 MongoDB cluster:** `wms` (nội bộ, `wms_db`) và `ecommerce` (public, `ecom_db`) + app `notification`. Đọc [overview/](overview/) trước khi sửa bất kỳ module nào — đặc biệt [main-flow.md](overview/main-flow.md) (luồng end-to-end P0→P7) và [data-ownership.md](overview/data-ownership.md).

**Các bất biến xuyên suốt — phải giữ đúng khi sửa bất kỳ file nào:**

- **Liên kết 2 app DUY NHẤT qua `sku`.** Không bao giờ đọc chéo collection giữa 2 app. Giao tiếp bất đồng bộ qua **event (BullMQ + Redis)**.
- **`availableQty` (Ecommerce) là bản COPY** sync từ WMS qua event `stock.changed`/`stock.expired`. Nguồn chân lý tồn = `wms_db.stock_balances`.
- **Chống oversell = reserve ATOMIC lúc checkout** trực tiếp trên `wms_db` (cùng cluster nên không cần Saga). `order.placed`/`stock.changed(−)` chỉ là hệ quả để sync hiển thị.
- **Reserve tách khỏi thanh toán** — giữ tồn ngay khi đặt (cả COD/online).
- **Tồn 2 lớp:** `StockBalance.onHand` (lớp tổng) = Σ `InventoryStock.quantity` mọi shelf; `available = onHand − reserved − expired`. Mọi biến động cập nhật **cả 2 lớp trong 1 transaction**. `StockMovement` là sổ cái append-only đối soát.
- **Đơn hàng 3 trục trạng thái độc lập:** `paymentStatus` / `orderStatus` / `fulfillmentStatus` (tránh state lai COD×online×make-to-order). Đơn **xuất nguyên kiện, chưa hỗ trợ partial fulfillment**.
- **Ly in (CUP_PRINTED) per-design:** mỗi mẫu in = 1 SKU riêng. Make-to-order **bắt buộc trả-trước ONLINE**. Chuỗi hold: tạo PrintJob giữ `CUP_BLANK` → in xong hold **chuyển** sang `CUP_PRINTED` cho đúng đơn.
- **Phân bổ 1 kho/đơn** (ưu tiên `CENTRAL`), lưu `fulfillWarehouseId`; không split đa kho — thiếu thì dùng Chuyển kho gom trước.

## Cấu trúc tài liệu

- **Mỗi module nghiệp vụ = 1 thư mục** với bộ 3 file: `use-cases.md` + `data-model.md` + `workflow.md`. Module đã chín: [warehouse/](warehouse/) (WMS), [catalog/](catalog/), [order/](order/), [supplier/](supplier/).
- **Vùng chưa làm:** xem [overview/gap-analysis.md](overview/gap-analysis.md) — bản đồ 5 vùng thiếu + thứ tự ưu tiên (shipping → auth → supplier ✅ → notification → report).
- **Ownership dữ liệu:** WMS sở hữu warehouse/inventory/suppliers... + `users` (module Auth-WMS); Ecommerce sở hữu catalog (module Catalog) + orders/carts/`payment_transactions` (module Order) + customers (module Auth-Ecom). Cập nhật [data-ownership.md](overview/data-ownership.md) mỗi khi thêm/đổi collection.
- [README.md](README.md) là mục lục — cập nhật bảng module khi thêm tài liệu mới.

## Quy ước khi sửa tài liệu

- **Giọng văn tiếng Việt**, khớp các file hiện có. Tên collection/enum/event phải khớp [data-ownership.md](overview/data-ownership.md) và [system-context.md](overview/system-context.md) — đây là nguồn chuẩn cho định danh.
- **Anchor slug kiểu GitHub tiếng Việt:** lowercase, **giữ dấu**, bỏ ký tự `: ( ) / + & —`, khoảng trắng → `-` (ký tự bị bỏ giữa 2 khoảng trắng tạo `--`). Khi link tới heading, đối chiếu chính xác slug.
- **Marker trạng thái** dùng `🔄 Đang phân tích` cho phần chưa chốt.
- **Nhất quán xuyên file:** sửa một quy tắc (vd luồng reserve, trạng thái đơn) phải rà các file tham chiếu chéo (`main-flow`, module liên quan) — không để mô tả mâu thuẫn giữa use-cases ↔ workflow ↔ data-model.
- Khi liên kết khái niệm còn thiếu schema (vd Customer), trỏ tới [gap-analysis.md](overview/gap-analysis.md) thay vì định nghĩa trùng địa hạt module khác.

## Quy trình thiết kế (superpowers)

Tài liệu thiết kế đi theo chuỗi **brainstorm → spec → plan**:

- Spec lưu ở [superpowers/specs/](superpowers/specs/) (`YYYY-MM-DD-<topic>-design.md`).
- Plan triển khai ở [superpowers/plans/](superpowers/plans/) (`YYYY-MM-DD-<feature>.md`).
- Module mới nên bắt đầu từ brainstorming, viết spec, rồi mới sinh các file `use-cases/data-model/workflow`.

## Git

- Commit tài liệu theo prefix `docs(<module>): ...`. Làm việc trên branch rồi merge fast-forward về `main`.
- **Push qua SSH** — remote HTTPS không có credential trong môi trường này:
  ```bash
  GIT_SSH_COMMAND='ssh -o BatchMode=yes' git push git@github.com:pbvm-ecom-warehouse/docs.git main
  ```
