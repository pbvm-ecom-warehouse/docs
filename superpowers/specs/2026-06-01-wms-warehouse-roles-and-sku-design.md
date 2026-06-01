# WMS — Thiết kế Phân quyền & SKU/Variant

> Ngày: 2026-06-01
> Trạng thái: Spec — chờ review trước khi viết plan
> Phạm vi: tài liệu (`docs/`) + mô hình dữ liệu WMS

## Bối cảnh

Mô hình hiện tại có 2 điểm cần điều chỉnh:

1. **Phân quyền**: chỉ có một role `STAFF` chung gánh toàn bộ thao tác kho (nhận hàng, put-away, in, xuất, kiểm, chuyển). Cần chia thành các role nghiệp vụ để **chặn quyền cứng** — mỗi người chỉ làm đúng phần việc của mình.
2. **SKU**: `sku` đang ở cấp `Product`, nhưng tồn kho lại đếm theo `Variant`. Lệch tầng → variant không có mã định danh khi thao tác kho. Cần đưa SKU xuống cấp Variant.

Quyết định thiết kế đã chốt qua brainstorming:
- Phân quyền: chặn cứng, chia theo từng nghiệp vụ, 1 user gán được nhiều role.
- SKU: ở cấp Variant, tự gợi ý từ thuộc tính + sửa được, unique.
- Thuộc tính variant: linh động dạng key-value.

---

## Phần 1 — Phân quyền WMS

### 1.1 Bộ role

Thay role `STAFF` đơn lẻ bằng bộ role nghiệp vụ (chung enum với `ADMIN`/`MANAGER`):

| Role | Phụ trách |
|---|---|
| `ADMIN` | Toàn quyền, bypass mọi guard |
| `MANAGER` | Tạo PO, tạo lệnh in/kiểm/chuyển, **duyệt** |
| `RECEIVER` | Nhận hàng + put-away (UC-02, UC-03, nhận của UC-07) |
| `PICKER` | Soạn & xuất hàng (UC-05, xuất của UC-07) |
| `PRINTER` | Vận hành in (UC-04) |
| `COUNTER` | Kiểm đếm (UC-06) |

### 1.2 Ma trận quyền thực hiện theo UC

| UC | Hành động | Role được phép |
|---|---|---|
| UC-01 PO | Tạo/xác nhận PO | `MANAGER` |
| UC-02 GRN | Tạo GRN, xác nhận nhận hàng | `RECEIVER` |
| UC-02 GRN | Duyệt GRN | `MANAGER` |
| UC-03 Put-away | Chỉ định vị trí | `RECEIVER` |
| UC-04 In ly | Tạo lệnh in | `MANAGER` |
| UC-04 In ly | Xác nhận in xong, nhập CUP_PRINTED | `PRINTER` |
| UC-05 Xuất kho | Pick/pack, xác nhận xuất | `PICKER` |
| UC-06 Kiểm kho | Tạo phiếu, duyệt điều chỉnh | `MANAGER` |
| UC-06 Kiểm kho | Kiểm đếm thực tế | `COUNTER` |
| UC-07 Chuyển kho | Tạo lệnh, duyệt hoàn tất | `MANAGER` |
| UC-07 Chuyển kho | Xuất tại kho nguồn | `PICKER` |
| UC-07 Chuyển kho | Nhận tại kho đích | `RECEIVER` |

UC-07 dùng lại `PICKER` (xuất) + `RECEIVER` (nhận) — không tạo role chuyển kho riêng. Nhân viên làm trọn lệnh chuyển thì được gán cả 2 role.

### 1.3 Thay đổi User

- Hiện tại: `role` (1 giá trị, enum `ADMIN/MANAGER/STAFF`).
- Đổi thành: **`roles: String[]`** — mảng, mỗi phần tử ∈ `ADMIN | MANAGER | RECEIVER | PICKER | PRINTER | COUNTER`.
- 1 user giữ được nhiều role, vd `["RECEIVER","PICKER"]`.

### 1.4 Enforcement (RolesGuard)

- `RolesGuard` hiện so khớp 1 role (`@Roles('MANAGER')`).
- Đổi sang **kiểm tra giao**: cho qua nếu `user.roles` chứa **ít nhất một** role trong danh sách `@Roles(...)`.
- `ADMIN` bypass mặc định.

### 1.5 Truy vết thao tác (field mới)

| Bảng | Field | Mô tả |
|---|---|---|
| PrintJob | `confirmedBy: ObjectId` | PRINTER xác nhận in xong (tách khỏi MANAGER tạo lệnh) |
| StockCount | `countedBy: ObjectId` | COUNTER kiểm đếm (tách khỏi MANAGER tạo/duyệt) |

Các field `createdBy`/`approvedBy` hiện có giữ nguyên kiểu `ObjectId`, chỉ cập nhật ghi chú role cho khớp bộ role mới.

---

## Phần 2 — SKU ở cấp Variant & thuộc tính linh động

### 2.1 Product

- **Bỏ** `sku` (unique) ở cấp Product.
- **Thêm** `code: String` (unique) — mã nhóm, vd `CUP-PLA`. Dùng làm tiền tố gợi ý SKU.

### 2.2 ProductVariant

- **Bỏ** 3 cột cố định `size` / `material` / `color`.
- **Thêm** `attributes: [{ name: String, value: String }]` — danh sách thuộc tính linh động, vd `[{name:"ML",value:"500"},{name:"Màu",value:"Đỏ"}]`. Thêm thuộc tính mới không cần sửa schema.
- **Thêm** `sku: String` (unique, required) — đơn vị định danh lưu kho thật.
- Giữ: `name`, `price`, `isActive`, `productId`.

### 2.3 Quan hệ Product ↔ Variant ↔ SKU

- 1 Product có nhiều Variant.
- 1 Variant = một tổ hợp cụ thể của các thuộc tính (mỗi thuộc tính 1 giá trị).
- **Mỗi Variant ↔ đúng 1 SKU.** Không gộp nhiều variant vào 1 SKU.

```
Product "Ly nhựa" (code: CUP-PLA), thuộc tính { ML, Màu }
   ├ Variant (500ml, Đỏ)    → SKU CUP-PLA-500-RED
   ├ Variant (500ml, Trắng) → SKU CUP-PLA-500-WHT
   ├ Variant (250ml, Đỏ)    → SKU CUP-PLA-250-RED
   └ Variant (250ml, Trắng) → SKU CUP-PLA-250-WHT
```

### 2.4 Quy ước sinh SKU (linh động)

- Khi tạo variant, hệ thống **tự gợi ý**: `{Product.code}-{các attribute value ghép lại}` → vd `CUP-PLA-500-RED`.
- Nếu Product không có `code` → ghép thuần từ các attribute value.
- Field hiển thị sẵn giá trị gợi ý nhưng **cho sửa tay** trước khi lưu.
- Khi lưu: **validate unique** toàn hệ thống; trùng → báo lỗi.

### 2.5 Không đổi

`InventoryStock` và mọi bảng giao dịch (GRN, GoodsIssue, PutAway, StockCount, StockTransfer) đã trỏ `variantId` → **không sửa logic tồn kho**. Variant nay có thêm SKU để hiển thị/quét đúng món.

---

## Các file docs sẽ cập nhật

| File | Thay đổi |
|---|---|
| `overview/system-context.md` | Bảng roles `ADMIN/MANAGER/STAFF` → bộ 6 role; RolesGuard đổi sang kiểm-tra-trong-mảng; `User.roles[]` |
| `warehouse/use-cases.md` | Cột Actor + dòng "Actor:" mỗi UC: thay `STAFF` bằng role cụ thể |
| `warehouse/workflow.md` | Đổi nhãn cột "STAFF" trong từng sơ đồ thành role tương ứng; WF-05 tách rõ PICKER (xuất nguồn) / RECEIVER (nhận đích) |
| `warehouse/data-model.md` | `User.roles[]`; `PrintJob.confirmedBy`; `StockCount.countedBy`; `Product.code` (bỏ `Product.sku`); `Variant.attributes[]` + `Variant.sku` (bỏ size/material/color) |

## Ngoài phạm vi (YAGNI)

- Không làm permission/capability-based (giữ role phẳng).
- Không thêm bảng định nghĩa thuộc tính ở cấp Product (dùng key-value tự do trên variant).
- Không theo dõi lô/hạn dùng (lot/expiry) trong lần này.
- Không sinh SKU riêng cho từng design CUP_PRINTED trong lần này.
