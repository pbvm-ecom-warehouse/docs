# Supplier Module — Design Spec

> Ngày: 2026-06-04 · Trạng thái: ✅ Đã chốt brainstorm
> Phạm vi: (1) Bản đồ gap nghiệp vụ toàn hệ thống; (2) Thiết kế chi tiết module **Supplier**.

## 1. Bối cảnh & vấn đề

Hệ WMS-ECOM hiện có 3 module chín (warehouse, catalog, order) đã đồng bộ chéo qua event. Còn **5 vùng nghiệp vụ thiếu tài liệu**: auth, supplier, shipping, report, notification. Lần này:

- Lập **bản đồ gap toàn bộ** (`overview/gap-analysis.md`) làm la bàn cho các lần brainstorm sau.
- Thiết kế chi tiết **module Supplier** (use-cases + data-model + workflow) — vì độc lập, gọn, bổ trợ luồng nhập hàng P0.

`Supplier` hiện đang nằm lẫn trong `warehouse/data-model.md` (Nhóm 5) với field cơ bản và chỉ có `isActive` (boolean), chưa có module docs, chưa có danh mục giá, chưa có trạng thái BLACKLIST.

## 2. Deliverables

1. **`overview/gap-analysis.md`** — bản đồ 5 vùng thiếu, mỗi vùng: hiện trạng / nghiệp vụ thiếu / event liên quan / đề xuất; kèm thứ tự ưu tiên triển khai.
2. **`supplier/use-cases.md` + `supplier/data-model.md` + `supplier/workflow.md`** — module Supplier.
3. **Cập nhật liên đới:** `warehouse/data-model.md`, `overview/data-ownership.md`, `README.md`.

Quyết định phạm vi (chốt qua brainstorm):

- ✅ CRUD NCC + danh mục giá · ✅ Trạng thái & blacklist
- ❌ Công nợ phải trả (AP) · ❌ Đánh giá NCC *(YAGNI — để module sau nếu cần)*
- Danh mục giá: **1 NCC chính / SKU** (không đa-NCC ở v1)
- Liên kết SKU↔NCC: **bảng `SupplierItem` riêng** (Hướng A — giữ `WarehouseItem` tinh gọn, dễ nới đa-NCC sau)

## 3. Gap Analysis — nội dung & thứ tự ưu tiên

| Hạng | Module | Hiện trạng | Nghiệp vụ thiếu | Phụ thuộc |
|---|---|---|---|---|
| 1 | **Shipping** | Tham chiếu ở P7 main-flow & UC-E04 (`SHIPPED`/`DELIVERED`), gọi là "module sau" | Tạo vận đơn, gán đơn vị vận chuyển, cập nhật trạng thái giao, COD reconciliation, đóng đơn `CLOSED` | Order (đã có) |
| 2 | **Auth** | system-context mô tả JWT, `users`/`customers`, RolesGuard | UC đăng ký/đăng nhập khách, tài khoản nhân viên, refresh token, đổi/quên mật khẩu | — |
| 3 | **Supplier** ⟵ *làm lần này* | Entity cơ bản nằm trong warehouse Nhóm 5 | Module docs riêng, danh mục giá, trạng thái/blacklist | Warehouse (đã có) |
| 4 | **Notification** | App :3003 trong system-context (email/sms/push) | Consumer các event, template, retry/idempotent, kênh gửi | Order/WMS events |
| 5 | **Report** | README liệt kê, trống | Báo cáo tồn kho, doanh thu, đơn hàng, hiệu suất kho | Tất cả (đọc-only) |

> Mỗi vùng trong file là một đoạn ngắn theo khuôn *hiện trạng / nghiệp vụ thiếu / event liên quan / đề xuất*. Supplier được đánh dấu "đã thiết kế → trỏ tới spec & module docs".

## 4. Supplier — Use Cases

| # | Tên | Actor | Mục đích |
|---|---|---|---|
| **UC-S01** | CRUD thông tin NCC | MANAGER/ADMIN | Tạo/sửa thông tin liên hệ, MST, mã NCC |
| **UC-S02** | Quản lý trạng thái NCC | MANAGER/ADMIN | Chuyển `ACTIVE`/`INACTIVE`/`BLACKLIST` |
| **UC-S03** | Gán NCC chính + giá nhập cho SKU | MANAGER | Lập/sửa `SupplierItem` (danh mục giá 1 NCC/SKU) |
| **UC-S04** | Gợi ý NCC & đơn giá khi tạo PO + guard blacklist | MANAGER | Tích hợp UC-01: gợi ý NCC chính + `purchasePrice`; chặn PO cho NCC không `ACTIVE` |

### UC-S01 — CRUD NCC
1. MANAGER/ADMIN tạo NCC: `name`, `code` (unique), liên hệ, `taxCode`, `note`. Mặc định `status = ACTIVE`.
2. Sửa thông tin; `code` đã dùng trong PO → không cho đổi (giữ tham chiếu).
3. Không xóa cứng NCC đã có PO — chuyển `INACTIVE` thay vì xóa.

### UC-S02 — Trạng thái NCC
1. `ACTIVE ⇄ INACTIVE` (MANAGER): ngừng/khôi phục hợp tác tạm thời.
2. `→ BLACKLIST` (MANAGER): chặn vĩnh viễn tạo PO mới. **Gỡ blacklist chỉ ADMIN**.
3. Đổi trạng thái **không ảnh hưởng PO đang dở** (DRAFT/SENT/PARTIALLY_RECEIVED vẫn nhận hàng bình thường).

### UC-S03 — Danh mục giá (SupplierItem)
1. Chọn SKU (`WarehouseItem`) → gán NCC chính + `purchasePrice`, `supplierItemCode`, `leadTimeDays`, `minOrderQty`.
2. **1 SKU ↔ 1 dòng SupplierItem** (unique `itemId`). Đổi NCC chính = cập nhật dòng hiện có.
3. `isActive = false` → báo giá hết hiệu lực, không gợi ý khi tạo PO.

### UC-S04 — Tạo PO có gợi ý + guard
1. Khi tạo PO, MANAGER chọn SKU → hệ tra `SupplierItem` → **gợi ý NCC chính + `purchasePrice`** (sửa tay được).
2. **Guard tại `DRAFT → CONFIRMED`:** nếu `supplier.status ≠ ACTIVE` ⇒ chặn, báo lý do (INACTIVE/BLACKLIST).
3. PO của NCC vừa bị chặn nhưng đã `CONFIRMED`/`SENT` trước đó vẫn nhận hàng (GRN) bình thường.

## 5. Supplier — Data Model

### Supplier (chuyển khỏi warehouse Nhóm 5 → module supplier sở hữu)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| code | String | Mã NCC (unique) |
| name | String | Tên nhà cung cấp |
| contactName | String | Người liên hệ |
| phone | String | |
| email | String | |
| address | String | |
| taxCode | String | Mã số thuế |
| status | Enum | **`ACTIVE` / `INACTIVE` / `BLACKLIST`** (thay cho `isActive` boolean) |
| note | String | Ghi chú |
| createdAt | DateTime | |

### SupplierItem (mới — hồ sơ mua hàng, 1 dòng/SKU)

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| itemId | ObjectId | **unique** — WarehouseItem (SKU). 1 SKU ↔ 1 NCC chính |
| supplierId | ObjectId | NCC chính |
| supplierItemCode | String | Mã hàng phía NCC (đối chiếu `WarehouseItem.altBarcodes`) |
| purchasePrice | Number | Giá nhập gợi ý |
| leadTimeDays | Number | Thời gian giao dự kiến |
| minOrderQty | Number | Số lượng đặt tối thiểu (MOQ) |
| isActive | Boolean | Còn hiệu lực báo giá |
| updatedAt | DateTime | |

> **Ownership:** `suppliers` và `supplier_items` thuộc `wms_db`, do module **supplier** (app WMS) sở hữu. Không bán trên Ecommerce → không sync sang ecom.

## 6. Supplier — Workflow

### WF-S01 — Vòng đời trạng thái NCC
```
        tạo mới
          │
          ▼
       ACTIVE ◀────────── INACTIVE     (MANAGER toggle 2 chiều)
          │   ──────────▶
          │
          │ BLACKLIST (MANAGER)
          ▼
      BLACKLIST ───(gỡ: chỉ ADMIN)──▶ ACTIVE
```
- Chỉ NCC `ACTIVE` mới qua được guard tạo PO (`DRAFT→CONFIRMED`).

### WF-S02 — Tạo PO có gợi ý giá + guard blacklist
```
MANAGER                 SUPPLIER MODULE            WAREHOUSE (PO)
  |                          |                          |
  |-- chọn SKU ------------->| tra SupplierItem theo itemId
  |<-- gợi ý NCC + giá ------| (purchasePrice, leadTime, MOQ)
  |-- sửa/giữ giá ---------->|                          |
  |-- xác nhận PO (CONFIRM) ----------------------------▶| guard: supplier.status == ACTIVE?
  |                          |                  YES → CONFIRMED
  |                          |                  NO  → chặn + báo lý do (INACTIVE/BLACKLIST)
```
- PO đã `CONFIRMED`/`SENT` trước khi NCC bị chặn → GRN (UC-02) nhận hàng bình thường, không bị guard.

## 7. Cập nhật file liên đới

- **`warehouse/data-model.md`** — gỡ entity `Supplier` khỏi Nhóm 5, để lại dòng trỏ "→ xem supplier module"; đổi đầu mục Nhóm 5 thành "Người dùng" (chỉ còn `User`). Ghi chú `PurchaseOrderItem.unitPrice` = "mặc định gợi ý từ `SupplierItem.purchasePrice`, sửa tay được".
- **`overview/data-ownership.md`** — thêm `suppliers`, `supplier_items` vào danh sách collection WMS sở hữu.
- **`README.md`** — điền link cột Supplier (UC / Data Model / Workflow).

## 8. Ngoài phạm vi (YAGNI)

- Công nợ phải trả / thanh toán NCC.
- Đánh giá/chấm điểm NCC, lịch sử hiệu suất giao hàng.
- Đa NCC trên cùng 1 SKU, so sánh giá nhiều nguồn (đường nâng cấp đã chừa qua bảng `SupplierItem`).
- Hợp đồng, hạn mức tín dụng, đa tiền tệ.
