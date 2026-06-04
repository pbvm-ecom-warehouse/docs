# Supplier — Use Cases

> Trạng thái: 🔄 Đang phân tích

## Tổng quan

| # | Tên | Actor | Trạng thái |
|---|---|---|---|
| UC-S01 | CRUD thông tin NCC | MANAGER/ADMIN | 🔄 Đang phân tích |
| UC-S02 | Quản lý trạng thái NCC | MANAGER/ADMIN | 🔄 Đang phân tích |
| UC-S03 | Gán NCC chính + giá nhập cho SKU | MANAGER | 🔄 Đang phân tích |
| UC-S04 | Gợi ý NCC & đơn giá khi tạo PO + guard blacklist | MANAGER | 🔄 Đang phân tích |

---

## UC-S01: CRUD thông tin NCC

**Actor:** MANAGER/ADMIN
**Mục đích:** Quản lý thông tin liên hệ, MST, mã NCC.

### Luồng chính
1. Tạo NCC: nhập `name`, `code` (unique), liên hệ, `taxCode`, `note` → mặc định `status = ACTIVE`
2. Sửa thông tin. `code` đã được PO tham chiếu → **không cho đổi** (giữ tham chiếu)
3. **Không xóa cứng** NCC đã có PO — chuyển `INACTIVE` thay vì xóa (xem [UC-S02](#uc-s02-quản-lý-trạng-thái-ncc))

---

## UC-S02: Quản lý trạng thái NCC

**Actor:** MANAGER/ADMIN
**Mục đích:** Bật/tắt khả năng đặt hàng từ một NCC.

### Luồng chính
1. `ACTIVE ⇄ INACTIVE` (MANAGER): ngừng/khôi phục hợp tác tạm thời
2. `→ BLACKLIST` (MANAGER): chặn vĩnh viễn tạo PO mới. **Gỡ blacklist chỉ ADMIN**
3. Đổi trạng thái **không ảnh hưởng PO đang dở** (`DRAFT`/`SENT`/`PARTIALLY_RECEIVED`) — các PO này vẫn nhận hàng (GRN) bình thường

> Sơ đồ vòng đời: [WF-S01](./workflow.md#wf-s01-vòng-đời-trạng-thái-ncc).

---

## UC-S03: Gán NCC chính + giá nhập cho SKU

**Actor:** MANAGER
**Mục đích:** Lập danh mục giá nhập (`SupplierItem`) — 1 NCC chính / SKU.

### Luồng chính
1. Chọn SKU (`WarehouseItem`) → gán NCC chính + `purchasePrice`, `supplierItemCode`, `leadTimeDays`, `minOrderQty`
2. **1 SKU ↔ 1 dòng** (`SupplierItem.itemId` unique). Đổi NCC chính = cập nhật dòng hiện có
3. `isActive = false` → báo giá hết hiệu lực, không gợi ý khi tạo PO

---

## UC-S04: Gợi ý NCC & đơn giá khi tạo PO + guard blacklist

**Actor:** MANAGER
**Trigger:** Tạo PO (tích hợp [UC-01](../warehouse/use-cases.md#uc-01-tạo-purchase-order)).

### Luồng chính
1. Khi tạo PO, chọn SKU → hệ tra `SupplierItem` theo `itemId` → **gợi ý NCC chính + `purchasePrice`** (sửa tay được)
2. **Guard tại `DRAFT → CONFIRMED`:** nếu `supplier.status ≠ ACTIVE` ⇒ **chặn**, báo lý do (`INACTIVE`/`BLACKLIST`)
3. PO của NCC vừa bị chặn nhưng đã `CONFIRMED`/`SENT` trước đó → vẫn nhận hàng (GRN) bình thường, không bị guard

> Sơ đồ: [WF-S02](./workflow.md#wf-s02-tạo-po-có-gợi-ý-giá--guard-blacklist).
