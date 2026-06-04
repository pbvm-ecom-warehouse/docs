# Supplier Module + Gap Analysis — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tạo tài liệu module Supplier (use-cases + data-model + workflow) và bản đồ gap nghiệp vụ toàn hệ thống, đồng bộ các file liên đới.

**Architecture:** Đây là dự án **tài liệu** (markdown trong `docs/`). Không có code/test runtime — "verify" nghĩa là kiểm tra anchor/link phân giải đúng và nội dung nhất quán với [spec](../specs/2026-06-04-supplier-module-design.md) cùng các file hiện có. Nâng entity `Supplier` từ chỗ nằm lẫn trong `warehouse/data-model.md` (Nhóm 5) thành module riêng `supplier/`, thêm bảng `SupplierItem`, đổi `isActive`→`status` enum.

**Tech Stack:** Markdown (GitHub-flavored), giọng văn tiếng Việt khớp các module hiện có (warehouse/catalog/order). Anchor heading kiểu Vietnamese-slug (giữ dấu, lowercase, thay khoảng trắng `-`).

**Nguồn chân lý:** [spec](../specs/2026-06-04-supplier-module-design.md). Đọc spec trước khi bắt đầu.

---

## File Structure

| File | Trách nhiệm | Hành động |
|---|---|---|
| `supplier/data-model.md` | Entity `Supplier` (status enum) + `SupplierItem` | Create |
| `supplier/use-cases.md` | UC-S01..S04 | Create |
| `supplier/workflow.md` | WF-S01 (vòng đời trạng thái), WF-S02 (PO có gợi ý + guard) | Create |
| `overview/gap-analysis.md` | Bản đồ 5 vùng thiếu + thứ tự ưu tiên | Create |
| `warehouse/data-model.md` | Gỡ `Supplier` khỏi Nhóm 5; ghi chú `unitPrice` | Modify |
| `overview/data-ownership.md` | Thêm `suppliers`, `supplier_items` vào WMS | Modify |
| `README.md` | Điền link cột Supplier | Modify |

Thứ tự: data-model trước (định nghĩa entity được các file khác trỏ tới), rồi use-cases, workflow; sau đó các file liên đới; gap-analysis; cuối cùng verify tổng.

---

### Task 1: `supplier/data-model.md`

**Files:**
- Create: `supplier/data-model.md`

- [ ] **Step 1: Tạo file với nội dung đầy đủ**

````markdown
# Supplier — Data Model

> Trạng thái: 🔄 Đang phân tích
> **Ownership:** `suppliers` và `supplier_items` thuộc `wms_db`, do module **supplier** (app WMS) sở hữu. Không bán trên Ecommerce → không sync sang ecom. Xem [data-ownership](../overview/data-ownership.md).

## Supplier (Nhà cung cấp)

> Đích của `PurchaseOrder.supplierId` (xem [warehouse/data-model](../warehouse/data-model.md#purchaseorder-đơn-đặt-hàng-ncc--uc-01)). Trước đây nằm trong WMS Nhóm 5 — nay tách về module supplier.

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
| status | Enum | `ACTIVE` / `INACTIVE` / `BLACKLIST` |
| note | String | Ghi chú |
| createdAt | DateTime | |

> **Trạng thái thay cho `isActive` boolean cũ:** chỉ NCC `ACTIVE` mới qua được guard tạo PO (`DRAFT→CONFIRMED`). Vòng đời xem [WF-S01](./workflow.md#wf-s01-vòng-đời-trạng-thái-ncc).

## SupplierItem (Hồ sơ mua hàng — 1 dòng/SKU)

> Danh mục giá nhập: **1 SKU ↔ 1 NCC chính** (unique `itemId`). Đổi NCC chính = cập nhật dòng hiện có, không thêm dòng mới. *(Đường nâng cấp đa-NCC: bỏ ràng buộc unique `itemId` + thêm cờ `isPrimary` — chưa làm ở v1.)*

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| itemId | ObjectId | **unique** — WarehouseItem (SKU) |
| supplierId | ObjectId | NCC chính |
| supplierItemCode | String | Mã hàng phía NCC (đối chiếu `WarehouseItem.altBarcodes`) |
| purchasePrice | Number | Giá nhập gợi ý (dùng làm mặc định cho `PurchaseOrderItem.unitPrice`) |
| leadTimeDays | Number | Thời gian giao dự kiến |
| minOrderQty | Number | Số lượng đặt tối thiểu (MOQ) |
| isActive | Boolean | Báo giá còn hiệu lực? `false` → không gợi ý khi tạo PO |
| updatedAt | DateTime | |
````

- [ ] **Step 2: Verify nội dung khớp spec**

Run: `grep -c "SupplierItem\|status\|ACTIVE" supplier/data-model.md`
Expected: ≥ 3 (có đủ entity SupplierItem, field status, giá trị enum).

- [ ] **Step 3: Commit**

```bash
git add supplier/data-model.md
git commit -m "docs(supplier): data-model — Supplier status enum + SupplierItem"
```

---

### Task 2: `supplier/use-cases.md`

**Files:**
- Create: `supplier/use-cases.md`

- [ ] **Step 1: Tạo file với nội dung đầy đủ**

````markdown
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
````

- [ ] **Step 2: Verify 4 UC + anchor workflow**

Run: `grep -c "## UC-S0" supplier/use-cases.md`
Expected: 4

- [ ] **Step 3: Commit**

```bash
git add supplier/use-cases.md
git commit -m "docs(supplier): use-cases UC-S01..S04"
```

---

### Task 3: `supplier/workflow.md`

**Files:**
- Create: `supplier/workflow.md`

- [ ] **Step 1: Tạo file với nội dung đầy đủ**

````markdown
# Supplier — Workflow

> Trạng thái: 🔄 Đang phân tích

## Luồng tổng quan

```
[WF-S01 Vòng đời trạng thái NCC] ── quyết định ──▶ [WF-S02 Tạo PO có gợi ý + guard]
        ACTIVE / INACTIVE / BLACKLIST                  chỉ ACTIVE mới qua guard
```

---

## WF-S01: Vòng đời trạng thái NCC

```
        tạo mới
          │
          ▼
       ACTIVE  ◀──────────  INACTIVE        (MANAGER toggle 2 chiều)
          │    ──────────▶
          │
          │ BLACKLIST (MANAGER)
          ▼
      BLACKLIST  ──(gỡ: chỉ ADMIN)──▶  ACTIVE
```

> - Chỉ NCC `ACTIVE` qua được guard tạo PO ([WF-S02](#wf-s02-tạo-po-có-gợi-ý-giá--guard-blacklist)).
> - Đổi trạng thái **không** đụng tới PO đang dở — chúng vẫn nhận hàng (GRN) bình thường.

---

## WF-S02: Tạo PO có gợi ý giá + guard blacklist

```
MANAGER                 SUPPLIER MODULE            WAREHOUSE (PO)
  |                          |                          |
  |-- chọn SKU ------------->| tra SupplierItem theo itemId
  |<-- gợi ý NCC + giá ------| (purchasePrice, leadTime, MOQ)
  |-- sửa/giữ giá ---------->|                          |
  |-- xác nhận (CONFIRM) -------------------------------▶| guard: supplier.status == ACTIVE?
  |                          |                  YES → CONFIRMED
  |                          |                  NO  → chặn + báo lý do (INACTIVE/BLACKLIST)
```

> - `purchasePrice` chỉ là **gợi ý** — MANAGER sửa tay được; giá chốt lưu ở `PurchaseOrderItem.unitPrice`.
> - PO đã `CONFIRMED`/`SENT` trước khi NCC bị chặn → [GRN (UC-02)](../warehouse/use-cases.md#uc-02-good-receive-note-grn) nhận hàng bình thường, không qua guard.
````

- [ ] **Step 2: Verify 2 WF**

Run: `grep -c "## WF-S0" supplier/workflow.md`
Expected: 2

- [ ] **Step 3: Commit**

```bash
git add supplier/workflow.md
git commit -m "docs(supplier): workflow WF-S01 vòng đời + WF-S02 tạo PO có gợi ý"
```

---

### Task 4: Gỡ `Supplier` khỏi `warehouse/data-model.md` Nhóm 5

**Files:**
- Modify: `warehouse/data-model.md` (Nhóm 5 — quanh dòng 425-441)

- [ ] **Step 1: Đọc đoạn cần sửa**

Run: `grep -n "Nhóm 5\|### Supplier\|### User (Nhân viên" warehouse/data-model.md`
Expected: thấy heading "## Nhóm 5: Nhà cung cấp & Người dùng", "### Supplier (Nhà cung cấp — UC-01)", "### User (Nhân viên nội bộ WMS...)".

- [ ] **Step 2: Đổi tiêu đề Nhóm 5 và thay block Supplier bằng dòng trỏ**

Tìm đoạn (từ `## Nhóm 5: Nhà cung cấp & Người dùng` tới ngay trước `### User (Nhân viên nội bộ WMS`):

```markdown
## Nhóm 5: Nhà cung cấp & Người dùng

### Supplier (Nhà cung cấp — UC-01)

> Đích của `PurchaseOrder.supplierId`.

| Field | Type | Mô tả |
|---|---|---|
| id | ObjectId | |
| name | String | Tên nhà cung cấp |
| code | String | Mã NCC (unique) |
| contactName | String | Người liên hệ |
| phone | String | |
| email | String | |
| address | String | |
| taxCode | String | Mã số thuế |
| isActive | Boolean | |

```

Thay bằng:

```markdown
## Nhóm 5: Người dùng

> **`Supplier` đã tách sang module riêng** — xem [supplier/data-model](../supplier/data-model.md#supplier-nhà-cung-cấp). `PurchaseOrder.supplierId` trỏ tới collection `suppliers` (sở hữu bởi module supplier). Danh mục giá nhập (`SupplierItem`) cũng nằm ở đó.

```

- [ ] **Step 3: Ghi chú `unitPrice` mặc định từ SupplierItem**

Tìm dòng trong bảng `PurchaseOrderItem`:

```markdown
| unitPrice | Number | Giá đặt |
```

Thay bằng:

```markdown
| unitPrice | Number | Giá đặt — **mặc định gợi ý từ [`SupplierItem.purchasePrice`](../supplier/data-model.md#supplieritem-hồ-sơ-mua-hàng--1-dòngsku), sửa tay được** |
```

- [ ] **Step 4: Verify đã gỡ entity Supplier, còn link trỏ**

Run: `grep -n "### Supplier\|tách sang module\|## Nhóm 5" warehouse/data-model.md`
Expected: KHÔNG còn "### Supplier"; có "## Nhóm 5: Người dùng" và "tách sang module".

- [ ] **Step 5: Commit**

```bash
git add warehouse/data-model.md
git commit -m "docs(warehouse): tách Supplier sang module riêng, Nhóm 5 chỉ còn User"
```

---

### Task 5: Cập nhật `overview/data-ownership.md`

**Files:**
- Modify: `overview/data-ownership.md` (block "WMS sở hữu", quanh dòng 19-30)

- [ ] **Step 1: Đọc block ownership**

Run: `grep -n "WMS sở hữu\|stock_counts\|stock_transfers" overview/data-ownership.md`
Expected: thấy block code liệt kê collection WMS (warehouse_items, inventory_stocks, goods_receipts, goods_issues, print_jobs, stock_transfers, stock_counts).

- [ ] **Step 2: Thêm `suppliers` và `supplier_items` vào cột WMS**

Tìm:

```
stock_transfers                orders
stock_counts                   customers
```

Thay bằng:

```
stock_transfers                orders
stock_counts                   customers
suppliers                      carts
supplier_items                 payments
```

> Lưu ý: căn lại cột cho khớp — cột phải (`carts`/`payments`) vốn nằm dưới; chỉ cần đảm bảo `suppliers` và `supplier_items` xuất hiện ở cột WMS bên trái. Nếu layout 2 cột khó căn, để `suppliers`/`supplier_items` thành 2 dòng riêng cuối khối WMS là chấp nhận được.

- [ ] **Step 3: Verify**

Run: `grep -c "suppliers\|supplier_items" overview/data-ownership.md`
Expected: ≥ 2

- [ ] **Step 4: Commit**

```bash
git add overview/data-ownership.md
git commit -m "docs(overview): thêm suppliers + supplier_items vào collection WMS sở hữu"
```

---

### Task 6: Điền link cột Supplier trong `README.md`

**Files:**
- Modify: `README.md` (dòng 20 — hàng "Nhà cung cấp")

- [ ] **Step 1: Tìm dòng Supplier trong bảng module**

Run: `grep -n "Nhà cung cấp" README.md`
Expected: dòng `| [Nhà cung cấp](./supplier/)       | —                              | —                                       | —                                   |`

- [ ] **Step 2: Thay 3 dấu `—` bằng link**

Thay dòng đó bằng:

```markdown
| [Nhà cung cấp](./supplier/)       | [UC](./supplier/use-cases.md)  | [Data Model](./supplier/data-model.md)  | [Workflow](./supplier/workflow.md)  |
```

- [ ] **Step 3: Verify**

Run: `grep "supplier/use-cases" README.md`
Expected: có 1 dòng khớp.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(readme): điền link module Supplier"
```

---

### Task 7: `overview/gap-analysis.md`

**Files:**
- Create: `overview/gap-analysis.md`

- [ ] **Step 1: Tạo file với nội dung đầy đủ**

````markdown
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
````

- [ ] **Step 2: Verify 5 vùng + đánh dấu Supplier**

Run: `grep -c "^## [0-9]" overview/gap-analysis.md`
Expected: 5

Run: `grep "Đã thiết kế" overview/gap-analysis.md`
Expected: có dòng Supplier "✅ Đã thiết kế".

- [ ] **Step 3: Commit**

```bash
git add overview/gap-analysis.md
git commit -m "docs(overview): bản đồ gap nghiệp vụ 5 vùng + thứ tự ưu tiên"
```

---

### Task 8: Verify tổng — link & nhất quán

**Files:** không sửa — chỉ kiểm tra.

- [ ] **Step 1: Liệt kê file mới và đã sửa**

Run: `git log --oneline -8 && ls supplier/ overview/gap-analysis.md`
Expected: thấy 7 commit (Task 1-7) và 3 file trong `supplier/` + `gap-analysis.md`.

- [ ] **Step 2: Kiểm mọi link nội bộ trong file supplier phân giải tới file tồn tại**

Run:
```bash
grep -rhoE '\]\(\.\.?/[^)]+\.md' supplier/ overview/gap-analysis.md | sed -E 's/^\]\(//' | sort -u
```
Expected: in ra các đường dẫn tương đối. Kiểm tay từng đường dẫn tồn tại (vd `../warehouse/use-cases.md`, `../supplier/data-model.md`). Không có file nào thiếu.

- [ ] **Step 3: Kiểm không còn tham chiếu `isActive` cho Supplier ở warehouse**

Run: `grep -n "Supplier" warehouse/data-model.md`
Expected: chỉ còn dòng trỏ "tách sang module" + `supplierId` trong PurchaseOrder; KHÔNG còn bảng field `isActive` của Supplier.

- [ ] **Step 4: Kiểm README & data-ownership đã cập nhật**

Run: `grep -l "supplier/use-cases" README.md && grep -l "supplier_items" overview/data-ownership.md`
Expected: cả 2 lệnh in tên file (đều khớp).

- [ ] **Step 5: Commit (nếu có sửa lặt vặt khi verify; nếu không, bỏ qua)**

```bash
git add -A && git commit -m "docs(supplier): hoàn thiện link & nhất quán" || echo "Không có thay đổi — bỏ qua"
```

---

## Self-Review Notes (đã kiểm khi viết plan)

- **Spec coverage:** Phần 3 spec→Task 7; UC (Phần 4)→Task 2; data-model (Phần 5)→Task 1; workflow (Phần 6)→Task 3; file liên đới (Phần 7)→Task 4,5,6; YAGNI (Phần 8)→ghi trong Task 1 & 7.
- **Type consistency:** tên field (`status`, `purchasePrice`, `itemId` unique, `supplierItemCode`) khớp giữa Task 1 (data-model) và Task 2/3 (use-case/workflow tham chiếu).
- **Anchor consistency:** link `#wf-s01-vòng-đời-trạng-thái-ncc`, `#wf-s02-tạo-po-có-gợi-ý-giá--guard-blacklist`, `#supplieritem-hồ-sơ-mua-hàng--1-dòngsku` dùng slug tiếng Việt (giữ dấu, lowercase, `--` cho ký tự `&`/dấu phẩy). Nếu renderer khác slug, chỉnh anchor ở Task 8 Step 5.
